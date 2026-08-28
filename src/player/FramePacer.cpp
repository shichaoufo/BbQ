#include "FramePacer.h"

#include <QQuickItem>
#include <QMetaObject>

#include <QtMath>
#include <QtGlobal>
#include <cmath>

#ifdef Q_OS_WIN
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <dwmapi.h>
#endif

FramePacer *FramePacer::instance()
{
    // 故意不释放的进程级单例：避免退出期与 QApplication / QTimer 的析构
    // 顺序竞态（Q_GLOBAL_STATIC 会在 main 返回后析构，彼时事件循环已死）。
    // 首次调用发生在 GUI 线程（DanmakuCanvas / MpvObjectD3D11 构造）；
    // C++11 magic static 保证 mpv 渲染线程并发首次调用的线程安全。
    static FramePacer *inst = new FramePacer;
    return inst;
}

FramePacer::FramePacer()
    : QObject(nullptr)
{
    m_clock.start();
    m_timer.setSingleShot(true);
    m_timer.setTimerType(Qt::PreciseTimer);
    connect(&m_timer, &QTimer::timeout, this, &FramePacer::tick);
}

void FramePacer::poke()
{
    // 允许任意线程调用（mpv update 回调在 mpv 内部线程触发）：
    // 转排队投递到本对象所属线程（GUI）。已在转时为幂等轻操作。
    QMetaObject::invokeMethod(this, &FramePacer::ensureRunning,
                              Qt::QueuedConnection);
}

void FramePacer::setVideoFps(qreal fps)
{
    if (fps < 0 || fps > 1000)
        fps = 0.0;
    if (qFuzzyCompare(m_videoFps + 1.0, fps + 1.0))
        return;
    m_videoFps = fps;
    // 帧率档位变化（如 24fps 番剧 → 60fps 视频）即时重算节奏。
    // 正在转时下一拍直接按新间隔推进（至多一拍过渡，无位置错拍）。
    recomputeCadence();
}

void FramePacer::setTargetRate(qreal fps)
{
    if (fps < 0 || fps > 1000)
        fps = 0.0;
    // 网格未知（启动后从未有视频/弹幕活动）时主动查询一次：既让
    // recomputeCadence 有正确输入，也让 refreshRate 属性立即可用
    //（QML 档位下拉框的 enable 态/选项过滤依赖它）
    if (m_periodNs <= 0) {
        qint64 origin = 0, period = 0;
        if (refreshGrid(origin, period)) {
            m_periodNs = period;
            m_originNs = origin;
            updateRefreshRate(period);
        }
    }
    if (qFuzzyCompare(m_targetRate + 1.0, fps + 1.0))
        return;
    m_targetRate = fps;
    recomputeCadence();
    // 切到"不限制"（active→false）：若心跳在转，tick 顶部的失活保护
    // 下一拍自动停跳，frameSwapped 门控按 active() 实时判断无缝交还。
    // 切到其他档位且应激活时：poke 确保心跳起跳（幂等）
    poke();
}

void FramePacer::updateRefreshRate(qint64 periodNs)
{
    if (periodNs <= 0)
        return;
    const qreal rate = 1e9 / qreal(periodNs);
    if (qFuzzyCompare(m_refreshRate + 1.0, rate + 1.0))
        return;
    m_refreshRate = rate;
    emit refreshRateChanged();
}

void FramePacer::subscribe(QQuickItem *item, const std::function<bool()> &wants)
{
    if (!item)
        return;
    for (auto &s : m_subs) {
        if (s.item == item) {
            s.wants = wants;   // 重复订阅视为更新谓词（跨窗口迁移后重挂）
            return;
        }
    }
    m_subs.append({item, wants});
}

void FramePacer::unsubscribe(QQuickItem *item)
{
    for (int i = m_subs.size() - 1; i >= 0; --i) {
        if (m_subs[i].item == item || !m_subs[i].item)
            m_subs.removeAt(i);   // 顺带清理已悬空条目
    }
}

void FramePacer::ensureRunning()
{
    const qint64 now = m_clock.nsecsElapsed();
    if (m_running) {
        // poke 即活动：维持空转停跳的判活
        m_lastActivityNs = now;
        return;
    }

    qint64 origin = 0, period = 0;
    if (!refreshGrid(origin, period))
        return;   // 无 DWM 网格（非 Windows / 远程会话）→ 不节流
    m_periodNs = period;
    m_originNs = origin;
    updateRefreshRate(period);
    recomputeCadence();
    if (!m_active)
        return;   // 60Hz 屏等场景：交还原有 frameSwapped 驱动链

    // 游标对齐到网格上首个"来得及渲染"的边界
    m_nextBoundaryNs = nextGridFrom(origin, period, now + kArmLeadNs);
    m_running = true;
    m_lastActivityNs = now;
    arm();
}

void FramePacer::tick()
{
    if (!m_running)
        return;
    // 失活保护：setVideoFps 可能在心跳运转中把节奏降到 n=1（如 144Hz 屏
    // 换播 120fps 视频触发自适应升档）。此时若继续转，游标推进量为 0，
    // arm() 会退化为 0.1ms 紧循环——必须立即停跳，把驱动权交还原链
    //（frameSwapped 门控按 active() 实时判断，交接无缝）
    if (!m_active.load(std::memory_order_acquire)) {
        stopPacer();
        return;
    }
    const qint64 now = m_clock.nsecsElapsed();

    // ---- 网格维护 ----
    qint64 origin = 0, period = 0;
    if (refreshGrid(origin, period)) {
        const bool rateChanged = (m_periodNs > 0
                                  && qAbs(period - m_periodNs) > m_periodNs / 50);
        m_periodNs = period;
        m_originNs = origin;
        updateRefreshRate(period);
        if (rateChanged) {
            // 刷新率切换（如 144Hz ↔ 60Hz）：重算节奏并重建游标
            recomputeCadence();
            if (!m_active) {
                stopPacer();
                return;
            }
            m_nextBoundaryNs = nextGridFrom(origin, period, now + kArmLeadNs);
        } else {
            // 相位微校正：把游标吸附到最近网格点，消除 DWM 周期 ppm 级
            // 漂移的长期累积（只接受 < 1/4 周期的小幅校正，大偏移交给
            // 下面的"游标落后"硬重置，避免误伤正常推进）
            const qint64 k = qRound64(qreal(m_nextBoundaryNs - origin) / qreal(period));
            const qint64 snapped = origin + k * period;
            if (qAbs(snapped - m_nextBoundaryNs) < period / 4)
                m_nextBoundaryNs = snapped;
        }
    }

    // 游标已落后（系统休眠恢复/长卡顿导致定时器迟发超过提前量）：
    // 硬重置到网格上首个来得及的边界，避免连续追赶补拍
    if (now > m_nextBoundaryNs) {
        if (m_periodNs <= 0) {
            stopPacer();
            return;
        }
        m_nextBoundaryNs = nextGridFrom(m_originNs, m_periodNs, now + kArmLeadNs);
    }

    // ---- 通知订阅者 ----
    bool anyHit = false;
    for (int i = m_subs.size() - 1; i >= 0; --i) {
        Sub &s = m_subs[i];
        if (!s.item) {
            m_subs.removeAt(i);
            continue;
        }
        if (s.wants && s.wants()) {
            s.item->update();
            anyHit = true;
        }
    }
    if (anyHit)
        m_lastActivityNs = now;

    // ---- 空转停跳 ----
    if (!anyHit && now - m_lastActivityNs > kIdleStopNs) {
        stopPacer();
        return;
    }

    // ---- 推进游标并布防下一拍 ----
    m_nextBoundaryNs += m_intervalNs.load(std::memory_order_relaxed);
    arm();
}

void FramePacer::arm()
{
    // 短间隔场景（如 240Hz 屏 + 120fps 视频，interval 仅 8.33ms）：提前量
    // 收缩到"间隔 − kArmTailNs"，即 update 发出后至少留出尾部余量，保证
    // tick 链自洽（update 发出后仍有渲染裕量），否则提前量吃满间隔会每拍
    // 错过边界。此前取 2/3：interval=8.33ms 时 lead 仅 5.55ms，GUI 分发
    // 偶发阻塞 3~5ms + 渲染 2~4ms 即令提交越过目标 vblank——迟到帧被
    // 挤压成短帧，即用户感知的偶发弹幕抖动（方案 1，2026-08-28 调整）。
    // "间隔 − 0.8ms"在 8.33ms 档把分发+渲染预算从 5.55ms 提到 7.5ms，
    // 16.67ms 档从 11.1ms 提到 15.9ms；余量 0.8ms 足以隔开相邻 tick
    //（定时器到期 → update → 下一拍 arm 之间的最小链路），不会重叠。
    // 间隔不足 1.6ms 的极端档退回 2/3（interval<2×tail 时减法会自噬）
    qint64 leadNs = kArmLeadNs;
    const qint64 interval = m_intervalNs.load(std::memory_order_relaxed);
    if (interval > 0)
        leadNs = qMin(leadNs, interval * 2 / 3);
    if (interval > 2 * kArmTailNs)
        leadNs = qMax(leadNs, interval - kArmTailNs);
    qint64 delayNs = (m_nextBoundaryNs - leadNs) - m_clock.nsecsElapsed();
    if (delayNs < 100000)
        delayNs = 100000;   // 0.1ms 下限（int 毫秒粒度的保护）
    m_timer.start(int((delayNs + 500000) / 1000000));
}

void FramePacer::stopPacer()
{
    m_running = false;
    m_timer.stop();
}

void FramePacer::recomputeCadence()
{
    m_active.store(false, std::memory_order_release);
    m_intervalNs.store(0, std::memory_order_release);
    m_n = 1;
    if (m_periodNs <= 0)
        return;

    const qreal refresh = 1e9 / qreal(m_periodNs);
    if (refresh <= kMinThrottledRefresh)
        return;   // 60Hz 屏：不节流
    if (m_targetRate <= 0.0)
        return;   // 用户选"不限制"：高刷屏满频，交还原 frameSwapped 驱动链

    int n = 1;
    if (m_videoFps >= kHighMotionFps) {
        // 自适应档：高帧率内容不允许被饿死（用户主动选择，GPU 相应上涨）。
        // 上限取用户档位与视频帧率的较大者：60fps 视频在"120fps"档位下
        // 以 120 心跳交付，视频帧不丢拍
        const qreal target = qMax(m_videoFps, m_targetRate);
        n = int(refresh / target);   // floor
    } else {
        // 基础档：节奏 ≤ 用户档位（60 档 GPU 不高于 60Hz 屏基线），下限
        // 保 40fps。ceil 分母带 2% 容差：DWM 报告的刷新率常略超名义值
        // （240Hz 屏实测报 240.6Hz），无容差时 ceil(240.6/60)=5 直接跳档
        // 到 48fps——节奏低于目标，顺滑度反而下降（trace 实测帧间隔
        // 20.8ms 的根因）。容差后 240.6Hz → n=4（60.15fps，无感超标）
        int hi = int(std::ceil(refresh / (m_targetRate * 1.02)));
        int lo = int(refresh / kMinTickRate);   // floor
        n = qMin(hi, qMax(lo, 1));
    }
    if (n < 1)
        n = 1;

    m_n = n;
    if (n >= 2) {
        m_intervalNs.store(qint64(n) * m_periodNs, std::memory_order_release);
        m_active.store(true, std::memory_order_release);
    }
}

bool FramePacer::refreshGrid(qint64 &originOut, qint64 &periodOut)
{
#ifdef Q_OS_WIN
    DWM_TIMING_INFO ti = {};
    ti.cbSize = sizeof(ti);
    LARGE_INTEGER freq = {}, qpc = {};
    if (SUCCEEDED(DwmGetCompositionTimingInfo(nullptr, &ti))
        && ti.qpcRefreshPeriod > 0
        && QueryPerformanceFrequency(&freq) && freq.QuadPart > 0
        && QueryPerformanceCounter(&qpc)) {
        const qint64 period = qint64(ti.qpcRefreshPeriod) * 1000000000LL / freq.QuadPart;
        // 合理性护栏：1ms..100ms（10Hz..1000Hz），与 DanmakuCanvas 一致；
        // 必须覆盖 240Hz 屏（周期 4.17ms）
        if (period >= 1000000LL && period <= 100000000LL) {
            periodOut = period;
            // qpcVBlank 是最近一次 vblank 的 QPC 值，换算到 m_clock 单调轴
            originOut = m_clock.nsecsElapsed()
                      + (qint64(ti.qpcVBlank) - qint64(qpc.QuadPart)) * 1000000000LL / freq.QuadPart;
            return true;
        }
    }
#else
    Q_UNUSED(originOut);
    Q_UNUSED(periodOut);
#endif
    return false;
}

qint64 FramePacer::nextGridFrom(qint64 origin, qint64 period, qint64 minNs)
{
    Q_ASSERT(period > 0);
    qint64 k = minNs > origin ? (minNs - origin + period - 1) / period : 1;
    if (k < 1)
        k = 1;
    return origin + k * period;
}
