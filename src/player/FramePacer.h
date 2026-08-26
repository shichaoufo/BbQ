#ifndef FRAMEPACER_H
#define FRAMEPACER_H

#include <QObject>
#include <QTimer>
#include <QElapsedTimer>
#include <QPointer>
#include <QList>

#include <atomic>
#include <functional>

class QQuickItem;

// FramePacer —— 窗口级统一帧心跳（B 站"各图层自主节奏"架构的 Qt Quick 翻译）。
//
// 问题：Qt Quick 场景图里任何一个 item 标脏都会触发整窗重新合成。弹幕层
// 若跟随屏幕刷新率驱动（frameSwapped 链），高刷屏（120/144/165/240Hz）上
// 整窗就以刷新率满频合成，GPU 占用远超 60Hz 屏基线。
//
// 方案：把弹幕层与视频层的帧驱动统一收敛到本心跳。心跳只在 DWM vsync
// 网格上以固定节奏（每 n 个 vsync 一次，n 由刷新率与视频帧率决定）触发
// update()，整窗合成率因此确定性封顶：
//   - 普通内容（视频 < 50fps 或无视频）：n = ceil(刷新率/60)，节奏 ≤60fps，
//     GPU 不高于 60Hz 屏基线；但节奏下限保 40fps，避免 75Hz 类屏幕被压到
//     过低反而肉眼可见掉帧。
//   - 高帧率内容（视频 ≥ 50fps，自适应心跳）：n = floor(刷新率/max(fps,60))，
//     保证视频帧不被饿死；此时 GPU 上涨属于用户主动选择高帧率内容。
//   - 刷新率 ≤ 63Hz（普通 60Hz 屏）或 DWM 网格不可用（远程会话等）：
//     心跳不激活，原有 frameSwapped 驱动链零改动运行，杜绝 60Hz 屏回归。
//
// 防抖关键（与 DanmakuCanvas 第 4 代认领机制配套）：
//   - 心跳 tick 严格对齐 DWM vsync 网格，游标每次推进整数个 vsync 周期，
//     呈现节奏与 60Hz 屏逐帧同款（均匀步进，无呼吸/抖动）；
//   - 弹幕认领步长从 1 个 vsync 周期放宽为本心跳间隔（见
//     DanmakuCanvas::presentationMs），认领序列与提交节奏严格同步等距；
//   - tick 用"边界 - 提前量"的单发精确定时器布防，游标为纯逻辑推进，
//     定时器误差不累积；每 tick 与 DWM 网格做相位吸附校正 ppm 漂移；
//   - 若某拍因系统卡顿错过边界，下一拍自然对齐回网格（一拍稍长步，
//     与丢帧同类，不产生位置错拍）。
//
// 生命周期：进程级单例。订阅者（DanmakuCanvas / MpvObjectD3D11）通过
// subscribe() 注册"是否需要本拍渲染"的谓词；任何一方有新帧/新弹幕时调
// poke() 唤醒心跳（幂等、线程安全）。连续 250ms 无人需要且无人 poke 时
// 心跳自动停跳（暂停/无弹幕时零渲染零唤醒，比旧链的 100ms 备用定时器更省）。
class FramePacer : public QObject
{
    Q_OBJECT
    Q_PROPERTY(qreal refreshRate READ refreshRate NOTIFY refreshRateChanged)
public:
    static FramePacer *instance();

    // 屏幕刷新率（DWM 权威值，Hz）。QML 的 Screen.refreshRate 在 Windows
    // 走 GetDeviceCaps(VREFRESH)，高刷屏常误报 60——设置面板的档位过滤
    // 与 enable 态以此为准。网格未知时为 0（首个视频/弹幕活动后即有效）
    qreal refreshRate() const { return m_refreshRate; }

    // 是否处于节流模式（高刷屏 + DWM 网格可用 + 计算出 n ≥ 2）。
    // 非激活时一切走原有 frameSwapped 驱动链，行为与改动前完全一致。
    // 原子量：渲染线程（frameSwapped DirectConnection lambda）也会读取。
    bool active() const { return m_active.load(std::memory_order_acquire); }

    // 节流模式下的心跳间隔（n × vsync 周期，ns）。active() 为 false 时
    // 无意义，调用方应退回单 vsync 周期。
    // 原子量：DanmakuCanvas::presentationMs 在渲染线程（updatePaintNode）
    // 中读取，recomputeCadence 在 GUI 线程写入。
    qint64 intervalNs() const { return m_intervalNs.load(std::memory_order_acquire); }

    // 唤醒心跳（幂等）。线程安全：可在 mpv 渲染线程回调中直接调用，
    // 内部转排队投递到 GUI 线程执行。
    void poke();

    // 自适应心跳输入：当前视频容器帧率（0 = 未知/无视频）。GUI 线程调用。
    void setVideoFps(qreal fps);

    // 用户可配置的节流上限（fps）。60 = 默认（GPU 不高于 60Hz 屏基线）；
    // 100/120/144 = 高刷档位（GPU 相应上涨，弹幕更顺滑）；
    // 0 = 不限制（高刷屏满频，行为与老版一致）。GUI 线程调用。
    // QML 经 context property "FramePacer" 调用（见 main.cpp）。
    Q_INVOKABLE void setTargetRate(qreal fps);
    Q_INVOKABLE qreal targetRate() const { return m_targetRate; }

    // 订阅/退订。tick 时对每个订阅者调用 wants()，返回 true 则调其
    // item->update()。wants 在 GUI 线程（tick 内）执行。
    void subscribe(QQuickItem *item, const std::function<bool()> &wants);
    void unsubscribe(QQuickItem *item);

private:
    explicit FramePacer();

    void ensureRunning();          // GUI 线程：网格校准 + 启动定时器链
    void tick();                   // 单发定时器触发
    void arm();                    // 为下一边界布防定时器
    void stopPacer();
    void recomputeCadence();       // 由刷新率 + 视频帧率重算 n / interval / active
    // DWM 查询：成功时输出网格原点（m_clock 时间轴）与 vsync 周期（ns）
    bool refreshGrid(qint64 &originOut, qint64 &periodOut);
    // 网格上首个 ≥ minNs 的边界
    static qint64 nextGridFrom(qint64 origin, qint64 period, qint64 minNs);
    // 由 vsync 周期更新 refreshRate 属性（变化时发 NOTIFY，QML 档位
    // 过滤/enable 态随网格首次获知而自动刷新）
    void updateRefreshRate(qint64 periodNs);

signals:
    void refreshRateChanged();

private:
    // tick 提前量：覆盖事件循环跳转延迟 + 同步/渲染管线耗时。若实际管线
    // 超出该提前量，本拍错过边界、呈现顺延一个 vsync（认领已改为固定
    // 步长推进，位置步长不受影响）。5ms 偏紧：渲染链耗时波动 2~8ms 时
    // 会频繁错过边界，呈现节奏 ±1 vsync 抖动；放宽到 8ms 换取呈现节奏
    // 稳定，代价仅为一拍内 3ms 的额外显示延迟（无感）。
    static constexpr qint64 kArmLeadNs = 8000000;
    // 空转停跳阈值：既无订阅者要帧、也无人 poke 的持续时长
    static constexpr qint64 kIdleStopNs = 250000000;
    // 启用节流的最低刷新率（60Hz 屏走原链，零回归）
    static constexpr qreal kMinThrottledRefresh = 63.0;
    // 低帧率内容的心跳下限（防止 75Hz 屏被 ceil 压到 37.5fps）
    static constexpr qreal kMinTickRate = 40.0;
    // 判定"高帧率内容"（自适应升档）的阈值
    static constexpr qreal kHighMotionFps = 50.0;

    QTimer m_timer;                // 单发精确定时器，驱动 tick
    QElapsedTimer m_clock;         // 单调时钟（构造时 start 一次，仅 GUI 线程使用）

    qint64 m_periodNs = 0;         // vsync 周期（DWM 权威值）
    qint64 m_originNs = 0;         // 最近一次查询的网格原点（m_clock 轴）
    qint64 m_nextBoundaryNs = 0;   // 下一 tick 目标边界（逻辑游标，网格对齐）
    std::atomic<qint64> m_intervalNs{0};   // n × m_periodNs（渲染线程可读）
    qreal m_videoFps = 0.0;
    qreal m_targetRate = 60.0;     // 节流上限（fps），0 = 不限制
    qreal m_refreshRate = 0.0;     // DWM 刷新率（Hz），网格获知后有效
    int m_n = 1;

    std::atomic<bool> m_active{false};
    bool m_running = false;
    qint64 m_lastActivityNs = 0;   // 最近一次 wants 命中 / poke 时刻

    struct Sub {
        QPointer<QQuickItem> item; // 条目悬空自动失效，tick 时惰性清理
        std::function<bool()> wants;
    };
    QList<Sub> m_subs;
};

#endif // FRAMEPACER_H
