#include "DanmakuCanvas.h"
#include "FramePacer.h"
#include "EmoticonCache.h"

#include <QCoreApplication>
#include <QQuickWindow>
#include <QRunnable>
#include <QScreen>
#include <QDir>
#include <QFileInfo>
#include <QFontDatabase>
#include <QSGNode>
#include <QSGTransformNode>
#include <QSGSimpleTextureNode>
#include <QPainter>
#include <QFontMetrics>
#include <QTime>
#include <algorithm>
#include <utility>

#include <private/qrhi_p.h>

#ifdef Q_OS_WIN
// DWM vsync 网格查询（DwmGetCompositionTimingInfo）：qpcRefreshPeriod 提供
// 精确刷新周期、qpcVBlank 提供最近 vblank 的 QPC 时刻。windows.h 的宏污染
// 风险由 CMake 的 SKIP_UNITY_BUILD_IN 隔离（本文件不参与 unity 合并）。
#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <dwmapi.h>
#endif

// ---------------------------------------------------------------------------
// AtlasSubTexture：图集子区域纹理（实现见头文件注释）
// rhiTexture() 返回宿主纹理快照 m_hostTex（渲染线程回填，见 flushAtlasUploads）
// ---------------------------------------------------------------------------
QRectF AtlasSubTexture::normalizedTextureSubRect() const
{
    if (m_atlasSize.isEmpty() || m_subRect.isEmpty())
        return QRectF(0, 0, 1, 1);
    // UV 四边内缩半个纹素：quad 边缘的采样点从"子区域边界"（双线性会
    // 50/50 混合边界外邻区的纹素）收回到"最外圈 pad 纹素的中心"。
    // 图集空闲区残留着已释放弹幕的陈旧位图（部分上传不清空），不内缩
    // 时边界采样会混入邻区陈旧像素——表现为部分弹幕右缘出现随邻占
    // 变化闪烁的细竖条。代价是 pad 有效宽度从 2px 变 1.5px，防渗色
    // 能力不变（邻区内容最多渗到采样半径 0.5px 处，仍在 pad 内）
    return QRectF((qreal(m_subRect.x()) + 0.5) / m_atlasSize.width(),
                  (qreal(m_subRect.y()) + 0.5) / m_atlasSize.height(),
                  (qreal(m_subRect.width()) - 1.0) / m_atlasSize.width(),
                  (qreal(m_subRect.height()) - 1.0) / m_atlasSize.height());
}

qint64 AtlasSubTexture::comparisonKey() const
{
    // 同一画布内的全部子纹理共用一个 key → 材质 compare 相等 → 合批。
    // 不能用 m_atlasTex 指针：首帧宿主尚未创建（nullptr），前后创建的
    // 子纹理 key 会不一致导致批次分裂。画布指针进程内唯一且稳定
    return qint64(m_host);
}

// ---------------------------------------------------------------------------
// 纹理图集：行分配器 + 渲染线程上传
// ---------------------------------------------------------------------------
QRect DanmakuCanvas::atlasAlloc(int w, int h)
{
    if (w <= 0 || h <= 0 || w > m_atlasSize.width() || h > m_atlasSize.height())
        return QRect();

    // 行高精确匹配：同字号档的弹幕高度一致，命中率高、无碎片
    for (auto &row : m_atlasRows) {
        if (row.h != h)
            continue;
        for (int i = 0; i < row.free.size(); ++i) {
            AtlasRun &run = row.free[i];
            if (run.w < w)
                continue;
            const int x = run.x;
            if (run.w - w < 4) {           // 余量过小整块给出，防碎片
                row.free.removeAt(i);
            } else {
                run.x += w;
                run.w -= w;
            }
            return QRect(x, row.y, w, h);
        }
    }

    // 开新行（按 h 对齐到 2px，减少行高种类）
    const int rowH = (h + 1) & ~1;
    if (m_atlasNextY + rowH > m_atlasSize.height())
        return QRect();                     // 垂直方向也满 → 整图重排
    AtlasRow row;
    row.y = m_atlasNextY;
    row.h = h;
    m_atlasNextY += rowH;
    row.free.append({w, m_atlasSize.width() - w});
    m_atlasRows.append(row);
    return QRect(0, row.y, w, h);
}

void DanmakuCanvas::atlasFree(const QRect &r)
{
    if (!r.isValid())
        return;
    for (auto &row : m_atlasRows) {
        if (row.y != r.y() || row.h != r.height())
            continue;
        // 按左端插入并合并相邻区间
        int ins = 0;
        while (ins < row.free.size() && row.free[ins].x < r.x())
            ++ins;
        int x = r.x(), w = r.width();
        if (ins > 0 && row.free[ins - 1].x + row.free[ins - 1].w == x) {
            x = row.free[ins - 1].x;
            w += row.free[ins - 1].w;
            row.free.removeAt(ins - 1);
            --ins;
        }
        if (ins < row.free.size() && x + w == row.free[ins].x) {
            w += row.free[ins].w;
            row.free.removeAt(ins);
        }
        row.free.insert(ins, {x, w});
        return;
    }
    // 找不到所属行（整图已 reset）：区域本就作废，忽略
}

void DanmakuCanvas::atlasReset()
{
    m_atlasRows.clear();
    m_atlasNextY = 0;
    QMutexLocker lock(&m_uploadMutex);
    m_pendingUploads.clear();   // 旧区域的上传随 reset 一并作废
}

void AtlasSubTexture::commitTextureOperations(QRhi *rhi, QRhiResourceUpdateBatch *resourceUpdates)
{
    // 官方图集同款机制（QSGRhiAtlasTexture::TextureBase::commitTextureOperations）：
    // 批渲染器在材质准备阶段调用本方法（prepareRenderPass 内 prepareRenderBatch
    // → updateMaterialDynamicData → shader updateSampledImage → 此处），渲染器
    // 已备好 rhi 与当前帧的 resourceUpdate 批，并在 beginPass 之前统一提交，
    // 首帧上传即生效。合批后渲染器只对批次首个材质调用 commit，因此上传
    // 队列挂在画布层整体消费
    m_host->flushAtlasUploads(rhi, resourceUpdates);
}

void DanmakuCanvas::flushAtlasUploads(QRhi *rhi, QRhiResourceUpdateBatch *resourceUpdates)
{
    // 渲染线程（commitTextureOperations 触发）：惰性创建宿主纹理 +
    // 全部待上传位图作为部分上传并入渲染器的 resourceUpdate 批
    //（对齐 QSGRhiAtlasTexture::AtlasBase::commitTextureOperations）
    Q_ASSERT(rhi && resourceUpdates);
    QMutexLocker lock(&m_uploadMutex);
    if (m_atlasCreatePending.exchange(false)) {
        delete m_atlasTex.exchange(nullptr);   // 防御：异常路径残留的旧宿主
        QRhiTexture *tex = rhi->newTexture(QRhiTexture::RGBA8, m_atlasSize, 1,
                                           QRhiTexture::Flags{});
        if (!tex || !tex->create()) {
            qWarning() << "[DanmakuCanvas] atlas texture create failed";
            delete tex;
            m_pendingUploads.clear();
            return;
        }
        m_atlasTex.store(tex, std::memory_order_release);
    }
    QRhiTexture *atlas = m_atlasTex.load(std::memory_order_acquire);
    if (m_pendingUploads.isEmpty() || !atlas)
        return;

    for (const AtlasUpload &u : std::as_const(m_pendingUploads)) {
        // 部分上传：只写图集内目标区域，其余弹幕的位图不受影响。
        // QImage 为 RGBA8888_Premultiplied，与 QRhiTexture::RGBA8 匹配；
        // 数据在 resourceUpdate 提交时被 QRhi 拷贝，出锁后生命周期安全
        QRhiTextureSubresourceUploadDescription sud;
        sud.setImage(u.img);
        sud.setDestinationTopLeft(u.dst);
        resourceUpdates->uploadTexture(atlas, QRhiTextureUploadDescription(
                                                   QRhiTextureUploadEntry(0, 0, sud)));
        // 回填宿主快照：此后材质 rhiTexture() 持有效指针（渲染线程独占写）
        u.sub->setHostTexture(atlas);
    }
    m_pendingUploads.clear();
}

void DanmakuCanvas::purgePendingUploads(AtlasSubTexture *sub)
{
    // 槽位复用要删除旧子纹理；若其上传仍在队列中（当帧批次被剔除未消费，
    // 如整层透明度归零时 commitTextureOperations 未执行），渲染线程稍后
    // 消费队列会对已释放内存调用 setHostTexture——堆损坏的典型表现就是
    // 弹幕纹理内容随机错乱成其他弹幕的位图。删除前先摘除引用条目
    QMutexLocker lock(&m_uploadMutex);
    for (int i = m_pendingUploads.size() - 1; i >= 0; --i) {
        if (m_pendingUploads[i].sub == sub)
            m_pendingUploads.removeAt(i);
    }
}

DanmakuCanvas::DanmakuCanvas(QQuickItem *parent)
    : QQuickItem(parent)
{
    // 不设这个标志，updatePaintNode 永远不会被调用
    setFlag(ItemHasContents, true);
    setAcceptHoverEvents(false);

    // 帧节奏诊断：设置环境变量 DANMAKU_TRACE=1 后，每渲染一帧记录一行
    // "采样时刻ms, 第一条滚动弹幕x坐标" 到 exe 同目录 danmaku_trace.csv，
    // 用于分析逐帧位移是否均匀（抖动定位）。默认关闭，零开销。
    if (qEnvironmentVariableIsSet("DANMAKU_TRACE"))
        m_traceFile = fopen("danmaku_trace.csv", "w");

    m_clock.start();
    m_swapClock.start();   // 呈现时刻记录专用时钟：只 start 一次，此后跨线程只读
    m_lineHeight = calcLineHeight();

    // 表情图就绪 → 重试延迟激活的表情弹幕（未就绪时激活分支跳过烘焙）
    connect(EmoticonCache::instance(), &EmoticonCache::ready,
            this, [this]() { update(); });
}

DanmakuCanvas::~DanmakuCanvas()
{
    // 先退订统一帧心跳：订阅表持有本对象谓词，析构后不得再被 tick 调用
    FramePacer::instance()->unsubscribe(this);
    qWarning() << "[DanmakuCanvas] destructor: pool=" << m_pool.size()
               << "pendingFree=" << m_pendingFreeSlots.size()
               << "atlas=" << !!m_atlasTex.load();

    if (m_traceFile) {
        fclose(m_traceFile);
        m_traceFile = nullptr;
    }
    // 节点仍挂在场景图树上，随 Item 自动析构；
    // 纹理在场景图仍有效时手动释放（不再调用 setTexture，避免触发脏标记遍历）。
    // 子纹理无 GPU 资源直接删；图集宿主 QRhiTexture 是渲染线程资源，
    // 若 itemChange 路径未覆盖（极端时序）则交渲染线程 job 释放
    if (window() && window()->isSceneGraphInitialized()) {
        for (auto &s : m_pool) {
            if (s.texNode)
                delete s.texNode->texture();
        }
        if (m_atlasTex.load(std::memory_order_acquire)) {
            struct AtlasReleaseJob : public QRunnable {
                QRhiTexture *tex = nullptr;
                void run() override { delete tex; }
            };
            auto *job = new AtlasReleaseJob;
            job->tex = m_atlasTex.exchange(nullptr);
            window()->scheduleRenderJob(job, QQuickWindow::BeforeSynchronizingStage);
        }
    }
}

// ---------------------------------------------------------------------------
// 发射接口
// ---------------------------------------------------------------------------
void DanmakuCanvas::appendScroll(const QString &text, const QString &color,
                                 qreal yPos, qreal pixelSpeed, qint64 nowMs,
                                 qreal fontScale, qreal vCenterBase,
                                 const QString &emoticonUrl, int emoticonSize,
                                 const QVariantList &emoticons)
{
    // 混排表情列表 → InlineEmo（占位符须实际出现在文本中才有效）
    QVector<InlineEmo> inlineEmos;
    for (const QVariant &v : emoticons) {
        const QVariantMap m = v.toMap();
        InlineEmo ie;
        ie.key  = m.value(QStringLiteral("text")).toString();
        ie.url  = m.value(QStringLiteral("url")).toString();
        ie.size = m.value(QStringLiteral("size")).toInt() == 2 ? 2 : 1;
        if (!ie.key.isEmpty() && !ie.url.isEmpty() && text.contains(ie.key))
            inlineEmos.append(ie);
    }

    if ((text.isEmpty() && emoticonUrl.isEmpty() && inlineEmos.isEmpty())
            || !m_danmakuEnabled)
        return;
    if (m_live.size() >= m_maxItems)
        evictOldest();

    LiveItem it;
    it.type = 1;
    it.text = text;
    it.color = QColor(color);
    it.startMs = nowMs;
    it.startNs = nowMs * 1000000;
    it.yPos = yPos;
    it.pixelSpeed = pixelSpeed;
    it.vCenterBase = vCenterBase;
    it.emoticonUrl = emoticonUrl;
    it.emoticonSize = emoticonSize;
    it.inlineEmos = inlineEmos;
    // 反算 speedScale=1 的基准速度，供后续调速做进度保持
    it.baseSpeed = m_speedScale > 0 ? pixelSpeed / m_speedScale : pixelSpeed;
    it.fontScale = fontScale > 0 ? fontScale : 1.0;
    if (!emoticonUrl.isEmpty()) {
        // 纯表情弹幕：尺寸由图片纵横比决定（图未就绪先按方形估算）
        const QSizeF sz = emoticonLogicalSize(EmoticonCache::instance()->image(emoticonUrl),
                                              it.fontScale, emoticonSize);
        it.width = sz.width();
        it.height = sz.height();
    } else if (!inlineEmos.isEmpty()) {
        // 混排：文本段按字体度量、表情段按图尺寸累加（未就绪按方形估算）
        measureMixed(text, inlineEmos, it.fontScale, it.width, it.height);
    } else {
        measure(text, it.fontScale, it.width, it.height);
    }
    m_live.append(it);
    emit activeCountChanged();
    kickstart();
}

void DanmakuCanvas::appendFixed(const QString &text, const QString &color,
                                qreal yPos, qint64 durationMs, qint64 nowMs,
                                qreal fontScale, qreal vCenterBase)
{
    if (text.isEmpty() || !m_danmakuEnabled)
        return;
    if (m_live.size() >= m_maxItems)
        evictOldest();

    LiveItem it;
    it.type = 5;   // 顶部/底部在渲染上都是固定弹幕，仅 yPos 不同（由 QML 算好）
    it.text = text;
    it.color = QColor(color);
    it.startMs = nowMs;
    it.startNs = nowMs * 1000000;
    it.yPos = yPos;
    it.durationMs = durationMs;
    it.vCenterBase = vCenterBase;
    it.fontScale = fontScale > 0 ? fontScale : 1.0;
    measure(text, it.fontScale, it.width, it.height);
    m_live.append(it);
    emit activeCountChanged();
    kickstart();
}

qreal DanmakuCanvas::measureWidth(const QString &text, qreal fontScale,
                                  const QString &emoticonUrl, int emoticonSize,
                                  const QVariantList &emoticons) const
{
    // 三个分支与 appendScroll 的尺寸计算、以及激活期的实测口径一一对应，
    // 保证「轨道占用时长用的宽度」== 上屏后实际占用的宽度
    if (!emoticonUrl.isEmpty()) {
        // 纯表情：整条就是一张图，宽度由图片纵横比决定（图未就绪按方形估算）
        const QSizeF sz = emoticonLogicalSize(EmoticonCache::instance()->image(emoticonUrl),
                                              fontScale, emoticonSize);
        return sz.width();
    }
    if (!emoticons.isEmpty()) {
        QVector<InlineEmo> emos;
        emos.reserve(emoticons.size());
        for (const QVariant &v : emoticons) {
            const QVariantMap m = v.toMap();
            InlineEmo ie;
            ie.key  = m.value(QStringLiteral("text")).toString();
            ie.url  = m.value(QStringLiteral("url")).toString();
            ie.size = m.value(QStringLiteral("size")).toInt() == 2 ? 2 : 1;
            // 占位符必须实际出现在文本里才算行内表情（与 appendScroll 同判据）
            if (!ie.key.isEmpty() && !ie.url.isEmpty() && text.contains(ie.key))
                emos.append(ie);
        }
        if (!emos.isEmpty()) {
            qreal w = 0, h = 0;
            measureMixed(text, emos, fontScale, w, h);
            return w;
        }
    }
    qreal w = 0, h = 0;
    measure(text, fontScale, w, h);
    return w;
}

qint64 DanmakuCanvas::currentMs() const
{
    // 暂停期间返回冻结值：弹幕原地静止（与暂停补偿语义一致）
    return m_paused ? m_frozenMs : m_clock.elapsed() - m_offsetMs;
}

qint64 DanmakuCanvas::currentNs() const
{
    // currentMs 的 ns 精度版本（同一时间轴）。暂停冻结值沿用 ms 精度：
    // 冻结期间无步进，恢复瞬间的取整偏差 ≤1ms 且为一次性（弹幕位置一次
    // 跳 <0.1px），无视觉影响——逐帧步长均匀性才是不可以妥协的部分
    return m_paused ? m_frozenMs * 1000000
                    : m_clock.nsecsElapsed() - m_offsetMs * 1000000;
}

qint64 DanmakuCanvas::presentationMs()
{
    // 采样时刻 → 呈现时刻外推：updatePaintNode（同步阶段）读到的时刻比这帧
    // 真正呈现早 0~一个刷新周期，直接使用会让逐帧 Δt 带上事件调度/渲染耗时
    // 抖动。这里把估计值对齐到稳定的 vsync 网格（origin + n·period），每个
    // 提交帧认领序列中的下一个网格边界，上屏步长恒等于一个刷新周期——与
    // 浏览器合成器的呈现时间戳模型一致。
    //
    // 网格来源（四代缺陷的教训，前三代见头文件注释）：
    //   第 3 代用 frameSwapped 的 Present 返回间隔估计网格，实测从未生效且
    //   被突发提交节奏污染——mpv 新帧回调与 frameSwapped 链造成"两帧相隔
    //   1~2ms 连发 + ~32ms 空档"的节奏，中位数周期塌缩到 2 倍周期；同时
    //   成对提交的两帧若认领同一网格边界，第二帧位置滞后一个周期，上屏
    //   步长变成"大-小-大-小"交替，即 30fps 频闪。
    //   第 4 代（现行）：Windows 上由 DwmGetCompositionTimingInfo 直接提供
    //   网格（qpcRefreshPeriod 精确周期 + qpcVBlank 相位，QElapsedTimer 与
    //   QPC 同源可无损映射到 m_swapClock 时间轴），完全不依赖 Present 返回；
    //   且每个提交帧强制认领下一个边界——连发的两帧各占相邻 vsync（翻转
    //   队列 FIFO 保证各自上屏一次），步长与提交节奏是否成对无关。
    const qint64 now = currentMs();
    if (m_paused) {
        m_nowNs = now * 1000000;         // 暂停冻结时钟，无需外推
        return now;
    }

    const qint64 nowNs = currentNs();

    // 高刷节流模式（120/240Hz，2026-08-25 决策）：退回老版的直接时间采样
    // ——位置 = 实际流逝时间 × 速度，跳过网格认领/固定步长/呈现外推全部
    // 机械。老版此方式在 240Hz 实测顺滑（用户认定的流畅度基准）；节流
    // 心跳已按 DWM 网格节奏触发，同步点采样间隔 ≈ 心跳间隔，残余毫秒级
    // 抖动仅表现为亚像素位置波动，与老版观感同级。60Hz/75Hz/100Hz 等
    // 非节流刷新率继续走下方网格认领（四代修复验证的抗抖动方案）——
    // 两代算法各用在各自验证过的档位
    if (FramePacer::instance()->active()) {
        m_lastTargetSwapNs = 0;   // 清锚点：节流中途关闭后防陈旧值干扰认领序列
        m_nowNs = nowNs;
        return m_nowNs / 1000000;
    }

    const qint64 swapNow = m_swapClock.nsecsElapsed();

    qint64 origin = 0;
    qint64 period = 0;
    bool haveGrid = false;

#ifdef Q_OS_WIN
    // 首选：DWM 合成器的真实 vsync 网格。每次采样即时查询（微秒级开销），
    // 自动跟随刷新率切换；窗口遮挡时 DWM 仍在合成桌面，返回值依然新鲜。
    {
        DWM_TIMING_INFO ti = {};
        ti.cbSize = sizeof(ti);
        LARGE_INTEGER freq = {}, qpc = {};
        if (SUCCEEDED(DwmGetCompositionTimingInfo(nullptr, &ti))
            && ti.qpcRefreshPeriod > 0
            && QueryPerformanceFrequency(&freq) && freq.QuadPart > 0
            && QueryPerformanceCounter(&qpc)) {
            const qint64 p = qint64(ti.qpcRefreshPeriod) * 1000000000LL / freq.QuadPart;
            if (p >= 1000000LL && p <= 100000000LL) {   // 1ms..100ms 合理性钳制
                period = p;
                // qpcVBlank 是刚过去的 vblank（QPC 纪元）：先做差再乘 1e9 换算
                // 避免溢出（QPC 全量值 ~1e13，乘后超 int64）。差值 ≤ 一个周期
                origin = swapNow
                       + (qint64(ti.qpcVBlank) - qint64(qpc.QuadPart)) * 1000000000LL
                         / freq.QuadPart;
                haveGrid = true;
                // 存入原子量：渲染线程 lead 采样门限使用；DWM 中途失效时
                // 回退路径也能拿到最后一次有效的网格。周期必须用 DWM 原值：
                // 曾用 QScreen::refreshRate() 做多屏混合刷新率校验，但 Qt 的
                // 报告值在运行中切换刷新率后可能滞后（实际 144Hz 仍报 60），
                // 把正确周期覆盖成 2.4 倍——弹幕整体快 2.4 倍。DWM 每帧实时
                // 查询、自动跟随真实合成节奏（含切换后的新刷新率），是唯一
                // 权威来源，不得被任何缓存值覆盖
                m_vsyncOriginNs.store(origin, std::memory_order_release);
                m_vsyncPeriodNs.store(period, std::memory_order_release);
            }
        }
    }
#endif

    if (!haveGrid) {
        // 回退（非 Windows / DWM 查询失败）：沿用 frameSwapped 呈现间隔的
        // 中位数网格（校准见 ensureFrameConnection）。要求最近 1 秒内有帧
        // 呈现——长时间遮挡后网格相位已不可信，退回裸采样时刻
        const qint64 lastSwap = m_lastSwapNs.load(std::memory_order_acquire);
        if (lastSwap >= 0) {
            const qint64 since = swapNow - lastSwap;
            if (since >= 0 && since <= 1000000000LL) {
                if (m_vsyncPeriodNs.load(std::memory_order_relaxed) <= 0) {
                    qreal rate = 0.0;
                    if (window() && window()->screen())
                        rate = window()->screen()->refreshRate();
                    m_vsyncPeriodNs.store(rate > 1.0 ? qMax<qint64>(1, qRound64(1000000000.0 / rate))
                                                     : 16666667LL,
                                          std::memory_order_release);
                }
                const qint64 o = m_vsyncOriginNs.load(std::memory_order_acquire);
                const qint64 p = m_vsyncPeriodNs.load(std::memory_order_acquire);
                if (o > 0 && p > 0) {
                    origin = o;
                    period = p;
                    haveGrid = true;
                }
            }
        }
    }

    if (!haveGrid) {
        m_nowNs = nowNs;                 // 无可用网格（首帧/DWM失败/遮挡）：裸采样
        return now;
    }

    // 本帧呈现时刻 = 同步时刻 + 渲染提前量（同步→提交耗时 EMA）之后的首个
    // 网格边界。origin 是刚过去的 vblank：rel ≤ 0 时下一个未到的边界是
    // origin + period；lead 预留不足时会提前认领赶不上的边界，该帧位置
    // 超前一个周期，下一帧又追回，形成整周期幅度的来回摆
    const qint64 lead = m_leadNs.load(std::memory_order_acquire);
    const qint64 rel = swapNow + lead - origin;
    qint64 k = rel > 0 ? (rel + period - 1) / period : 0;   // ceil(rel/period)
    if (k < 1)
        k = 1;
    qint64 target = origin + k * period;

    // 逐帧强制认领下一个边界（第 4 代修复的核心）：连发提交的两帧相隔
    // 1~2ms，翻转队列 FIFO 保证它们分别上屏到相邻两个 vsync；若第二帧仍
    // 认领与第一帧相同的边界，其位置滞后一个周期，上屏步长变成"大-小"
    // 交替的频闪。强制每个提交帧认领序列中的下一个边界后，步长恒等于
    // 刷新周期。真实丢帧（同步间隔 > 周期）时 calc 给出的边界本就领先
    // last+period，max 自然取 calc，不会过度顺延。
    // （高刷节流模式已在函数开头早退到直接时间采样，本块仅服务 60Hz/
    // 75Hz/100Hz 等非节流刷新率）
    if (m_lastTargetSwapNs > 0)
        target = qMax(target, m_lastTargetSwapNs + period);
    m_lastTargetSwapNs = target;

    // ns 精度外推：认领边界 target 与 swapNow 都在 swapClock 轴上（ns），
    // nowNs 与 swapNow 几乎同时读取（帧间差相互抵消），因此 m_nowNs 的
    // 逐帧差 ≈ 认领步长（固定步长推进下恒定）。返回 ms 截断值仅供存活
    // 判断等粗逻辑——位置计算必须用 m_nowNs：ms 截断会把认领的 ns 精度
    // 退化成 ±1ms 的逐帧步长噪声（240Hz 下实测三档步长 1.769/1.858/
    // 1.946px，即呼吸感的第二大来源）
    m_nowNs = nowNs + (target - swapNow);
    return m_nowNs / 1000000;
}

void DanmakuCanvas::setPaused(bool v)
{
    if (m_paused == v)
        return;
    if (v) {
        m_frozenMs = m_clock.elapsed() - m_offsetMs;   // 冻结当前时刻
    } else {
        m_offsetMs = m_clock.elapsed() - m_frozenMs;   // 补偿暂停时长
        kickstart();                                    // 恢复帧驱动链
    }
    m_paused = v;
    emit pausedChanged();
}

void DanmakuCanvas::itemChange(ItemChange change, const ItemChangeData &data)
{
    QQuickItem::itemChange(change, data);

    if (change == ItemSceneChange) {
        if (!data.window) {
            // 脱离场景（跨窗口迁移中转 / 父项被移出场景 / 页面销毁）统一按
            // "迁移"路径处理。不能用 parentItem()->window() 区分迁移中转：
            // Qt 6 的 derefWindow 先把自己的 window 置空再递归子项
            // （qquickitem.cpp derefWindow：window=nullptr 在子项循环之前），
            // 子项收到 nullptr 事件时父项 window 必为 null——小窗迁移时该判定
            // 恒为假，池内残留旧窗口节点指针，旧窗口恢复渲染删树后即为悬垂
            // 指针，updatePaintNode 再触碰即崩溃（退出小窗闪退的根因）。
            //
            // 统一路径对三种场景均正确：
            //  - 迁移：纹理交旧窗口渲染线程 job 释放，簿记清空后在新窗口重建；
            //  - 页面销毁（父项 ~QQuickItem 先 detach 仍存活的子项，本对象完整
            //    析构函数尚未运行）：同样释放纹理——此前析构函数因 window()
            //    已空而跳过删除，整池 QSGTexture 泄漏；
            //  - 节点一律不删：整棵节点树由 Qt 经 cleanup(itemNodeInstance) 移交
            //    旧窗口渲染线程延迟删除，texNode setOwnsTexture(false) 不碰纹理。
            QQuickWindow *oldWin = m_connWindow;
            qWarning() << "[DanmakuCanvas] leaving scene: pool=" << m_pool.size()
                       << "live=" << m_live.size() << "atlas=" << !!m_atlasTex.load()
                       << "connWin=" << !!oldWin;
            if (oldWin && (!m_pool.isEmpty() || m_atlasTex)) {
                // 池内子纹理与图集宿主纹理均属旧窗口场景图（各窗口独立
                // QRhi/D3D11 设备），既不能在新窗口渲染，也不能在新窗口线程
                // 释放。收集后交旧窗口渲染线程 job 删除（BeforeSynchronizingStage
                // job 在旧窗口下一次 sync 的 cleanupNodes 删节点树之前执行，
                // 顺序安全）。子纹理自身无 GPU 资源，一并进 job 保持释放
                // 时序统一（节点树删树前纹理先亡，材质不再被触碰）
                struct TexReleaseJob : public QRunnable {
                    QList<QSGTexture *> textures;
                    QRhiTexture *atlasTex = nullptr;
                    void run() override {
                        for (QSGTexture *t : textures) delete t;
                        delete atlasTex;
                        qWarning() << "[DanmakuCanvas] tex release job done:"
                                   << textures.size() << "sub + atlas" << !!atlasTex;
                    }
                };
                auto *job = new TexReleaseJob;
                for (auto &s : m_pool) {
                    if (s.texNode && s.texNode->texture())
                        job->textures.append(s.texNode->texture());
                }
                job->atlasTex = m_atlasTex.exchange(nullptr);
                if (!job->textures.isEmpty() || job->atlasTex)
                    oldWin->scheduleRenderJob(job, QQuickWindow::BeforeSynchronizingStage);
                else
                    delete job;
            }
            // 断开旧连接（脱离窗口：迁移中转 / 窗口重建 / 场景图失效等），
            // 重连接交给 ensureFrameConnection 自愈
            if (m_frameConn)
                disconnect(m_frameConn);
            if (m_sgConn)
                disconnect(m_sgConn);
            if (m_swapConn)
                disconnect(m_swapConn);
            m_frameConn = QMetaObject::Connection();
            m_sgConn = QMetaObject::Connection();
            m_swapConn = QMetaObject::Connection();
            m_connWindow = nullptr;
            // 图集分配器作废（新窗口重建时重新分配）；挂起的上传对应旧
            // 纹理，一并清空
            atlasReset();
            m_atlasResetPending = false;
            // 清簿记，绝不删节点（见上）。清空后 updatePaintNode 在新窗口为
            // 活跃弹幕重建节点与纹理；startMs 保留（m_clock 不重置），
            // 弹幕时间轴不中断
            m_pool.clear();
            m_pendingFreeSlots.clear();
            for (auto &it : m_live) {
                it.slot = -1;
                it.textureReady = false;
            }
        }
        ensureFrameConnection();
        kickstart();
    } else if (change == ItemVisibleHasChanged && data.boolValue) {
        kickstart();   // 重新可见时恢复帧驱动链
    }
}

void DanmakuCanvas::ensureFrameConnection()
{
    // 帧驱动链：frameSwapped（帧呈现完成）→ update() 调度下一帧
    // → 同步阶段 updatePaintNode 内读取 C++ 单调时钟计算位置。
    // 采样点在帧流水线内部，与 GUI 线程事件调度抖动（±3ms）完全隔离。
    // 暂停时门控断链：弹幕冻结且不空转渲染（曾实测暂停期空转 60fps）。
    // 不用自由定时器：采样时刻与帧呈现时刻的相位差（0~16.7ms 随机）
    // 在慢速弹幕下表现为 ±1px 的可见抖动。
    // 不用 afterAnimating：它处在同步阶段内，此时 update() 会被合并进
    // 当前帧，无法调度新帧，链条断裂（实测 10 秒仅触发 1 次）。
    QQuickWindow *win = window();
    if (!win)
        return;
    if (m_frameConn && m_connWindow == win)
        return;   // 连接健康
    if (m_frameConn)
        disconnect(m_frameConn);
    if (m_sgConn)
        disconnect(m_sgConn);
    if (m_swapConn)
        disconnect(m_swapConn);
    m_connWindow = win;
    m_frameConn = connect(win, &QQuickWindow::frameSwapped, this, [this]() {
        // 高刷屏节流模式：帧节奏已由 FramePacer 统一心跳按网格驱动，
        // 本链休眠（若不门控，本链会把整窗拖回刷新率满频，节流失效）。
        // 60Hz 屏 / 非 Windows：pacer 不激活，本链行为与改动前完全一致
        if (FramePacer::instance()->active())
            return;
        if (!m_live.isEmpty() && m_danmakuEnabled && !m_paused)
            update();
    });
    // 呈现时刻记录 + 渲染提前量测量：DirectConnection 在 frameSwapped 的发射
    // 线程（渲染线程）上同步执行，必须在 Present 返回的瞬间取值——排队连接
    // 会引入事件循环延迟，使记录到的时刻本身带抖动。Windows 上 vsync 网格由
    // DwmGetCompositionTimingInfo 直接提供（见 presentationMs），此处只测
    // 渲染提前量；非 Windows 回退路径的网格校准（PLL + 中位数周期）在此处。
    // 除原子量与渲染线程私有的间隔缓冲外，其余成员一概不碰。
    m_swapConn = connect(win, &QQuickWindow::frameSwapped, this, [this]() {
        const qint64 s = m_swapClock.nsecsElapsed();
        const qint64 last = m_lastSwapNs.load(std::memory_order_relaxed);
        m_lastSwapNs.store(s, std::memory_order_release);

        const qint64 period = m_vsyncPeriodNs.load(std::memory_order_relaxed);
        if (period <= 0)
            return;                      // 周期尚未就绪（GUI 线程 DWM 查询/懒初始化之后）

        // 渲染提前量 EMA：本帧同步（GUI 线程在 updatePaintNode 里记录）→
        // Present 返回的耗时，认领网格边界时预留。只在 Present 未被翻转队列
        // 阻塞时采样：连发提交的第二个 Present 会阻塞到上一帧被消费才返回，
        // 等待耗时不是真实提交延迟，混入会把 EMA 抬高、令认领过度顺延
        const qint64 lastSync = m_lastSyncNs.load(std::memory_order_acquire);
        if (lastSync > 0) {
            const qint64 lead = s - lastSync;
            const qint64 cur = m_leadNs.load(std::memory_order_relaxed);
            if (lead > 0 && lead < period - period / 4)
                m_leadNs.store(cur + (lead - cur) / 8, std::memory_order_release);
        }

        qint64 origin = m_vsyncOriginNs.load(std::memory_order_relaxed);
        if (origin <= 0) {
            m_vsyncOriginNs.store(s, std::memory_order_release);
            return;                      // DWM 从未提供过网格时（回退路径）以首次呈现时刻建原点
        }

#ifndef Q_OS_WIN
        // ---- 非 Windows 回退路径的网格校准。Windows 上不用：Present 返回的
        // 突发节奏（成对连发 + 空档）会把中位数周期污染到 2 倍周期 ----

        // 相位锁定（PLL）：Present 返回相对真实扫描存在恒定超前/滞后，但恒定
        // 相位差不影响步长均匀性——把网格以 α=1/8 缓慢拉向实际呈现相位即可
        const qint64 n = qRound64(qreal(s - origin) / qreal(period));
        const qint64 err = s - (origin + n * period);
        m_vsyncOriginNs.store(origin + err / 8, std::memory_order_release);

        // 周期估计：近期呈现间隔的中位数（ns 精度，能表达 16.68ms）。
        // 中位数对丢帧（2P/3P 间隔）与连发（<2ms 间隔）离群值免疫
        if (last < 0)
            return;
        const qint64 dt = s - last;
        if (dt <= 2000000LL || dt >= period * 4)
            return;                      // 异常间隔不参与统计
        m_swapIntervals.append(dt);
        if (m_swapIntervals.size() > 32)
            m_swapIntervals.remove(0);
        if (m_swapIntervals.size() < 8)
            return;                      // 样本不足，先不估计
        const auto mid = m_swapIntervals.begin() + m_swapIntervals.size() / 2;
        std::nth_element(m_swapIntervals.begin(), mid, m_swapIntervals.end());
        const qint64 median = *mid;
        if (qAbs(median - period) > period / 2)
            m_vsyncPeriodNs.store(median, std::memory_order_release);   // 刷新率切换：直接切换
        else
            m_vsyncPeriodNs.store(period + (median - period) / 8, std::memory_order_release);   // 缓慢贴合
#endif
    }, Qt::DirectConnection);
    // 图集上传不走窗口信号：由批渲染器在材质准备阶段经
    // AtlasSubTexture::commitTextureOperations 触发（官方图集同款时序，
    // 见该函数注释），上传随渲染器的 resourceUpdate 批在 beginPass 前提交
    // 场景图失效（D3D 设备丢失 TDR/窗口重建等）：节点与纹理已被场景图销毁，
    // 在 RHI 仍有效的此信号内删除自有纹理、丢弃全部节点指针，下帧重建
    m_sgConn = connect(win, &QQuickWindow::sceneGraphInvalidated, this, [this]() {
        for (auto &s : m_pool) {
            if (s.texNode && s.texNode->texture())
                delete s.texNode->texture();   // 不调用 setTexture(nullptr)：
                                               // 场景图拆毁期间触发脏标记遍历会空指针崩溃
            s.inUse = false;
        }
        m_pool.clear();
        m_pendingFreeSlots.clear();
        for (auto &it : m_live) {
            it.slot = -1;
            it.textureReady = false;
        }
        // 图集宿主纹理随场景图一起销毁（渲染线程，DirectConnection 时机
        // 安全）；分配器/上传队列作废，新窗口场景图建立后由首个子纹理
        // 触发重建（atlasCreatePending）
        delete m_atlasTex.exchange(nullptr);
        atlasReset();
    }, Qt::DirectConnection);

    // 订阅统一帧心跳：高刷屏上由 FramePacer 按网格节奏驱动 update()。
    // 谓词与上方 frameSwapped 门控条件一致（活跃弹幕 + 启用 + 未暂停）；
    // 60Hz 屏上 pacer 不激活，订阅为静默状态，零成本
    FramePacer::instance()->subscribe(this, [this]() {
        return !m_live.isEmpty() && m_danmakuEnabled && !m_paused;
    });
}

void DanmakuCanvas::kickstart()
{
    // 链条只有在"有帧被渲染"时才能转起来；首次发射/恢复可见/重新启用时
    // 可能没有任何东西触发渲染，需要主动标脏踢一脚。
    // 暂停时也踢一帧：让新弹幕以静止姿态上屏，随后链条被暂停门控停下
    if (!m_live.isEmpty() && m_danmakuEnabled && isVisible() && window()) {
        // 高刷节流模式：直接 update() 会产生网格外呈现——每条新弹幕
        // 一次 off-grid 合成，实测把整窗合成率抬到 心跳60+弹幕30=90fps。
        // 改为只 poke 心跳：新弹幕最迟在下一个网格边界（≤16.7ms）上屏，
        // 从右边缘入场晚一拍不可感知。非节流（60Hz 屏 / 心跳未激活 /
        // 暂停后心跳已空闲停跳）维持直接 update() 踢链
        if (!FramePacer::instance()->active())
            update();
        FramePacer::instance()->poke();
    }
}

void DanmakuCanvas::clear()
{
    m_live.clear();
    m_clearRequested = true;   // 节点操作只能在 updatePaintNode 内做
    m_clock.restart();         // 时钟归零（seek/清屏后时间轴重新开始）
    m_offsetMs = 0;
    m_frozenMs = 0;
    m_now = 0;
    emit activeCountChanged();
    update();
}

void DanmakuCanvas::evictOldest()
{
    if (m_live.isEmpty())
        return;
    // 淘汰最早发射的一条（列表按发射顺序追加，头部即最旧）
    freeSlotDeferred(m_live.first().slot);
    m_live.removeFirst();
    emit activeCountChanged();
}

// ---------------------------------------------------------------------------
// 属性
// ---------------------------------------------------------------------------
void DanmakuCanvas::setBaseFontSize(int v)
{
    if (m_baseFontSize != v) {
        m_baseFontSize = v;
        markFontDirty();
        refreshLineHeight();
        emit baseFontSizeChanged();
    }
}

void DanmakuCanvas::setFontSizeScale(qreal v)
{
    if (!qFuzzyCompare(m_fontSizeScale, v)) {
        m_fontSizeScale = v;
        markFontDirty();
        refreshLineHeight();
        emit fontSizeScaleChanged();
    }
}

void DanmakuCanvas::setSpeedScale(qreal v)
{
    if (v <= 0 || qFuzzyCompare(m_speedScale, v))
        return;

    // 进度保持式调速：每条弹幕保持当前已完成进度，仅改变后续速度/时长
    // （逻辑与原 DanmakuOverlay._applySpeedScaleToItems 等价，但零 QML 遍历开销）
    const qreal W = width();
    for (auto &it : m_live) {
        const qint64 elapsed = qMax<qint64>(0, m_now - it.startMs);
        if (it.type == 1) {
            const qreal totalDist = W + it.width;
            const qreal oldDuration = totalDist / (it.baseSpeed * m_speedScale);
            qreal progress = oldDuration > 0 ? elapsed / oldDuration : 0;
            progress = qBound<qreal>(0, progress, 1);
            const qreal newDuration = totalDist / (it.baseSpeed * v);
            it.startMs = m_now - qint64(progress * newDuration);
            it.startNs = it.startMs * 1000000;
            it.pixelSpeed = it.baseSpeed * v;
        } else {
            const qreal oldDuration = 4000.0 / m_speedScale;
            qreal progress = oldDuration > 0 ? elapsed / oldDuration : 0;
            progress = qBound<qreal>(0, progress, 1);
            it.durationMs = qint64(4000.0 / v);
            it.startMs = m_now - qint64(progress * it.durationMs);
            it.startNs = it.startMs * 1000000;
        }
    }
    m_speedScale = v;
    emit speedScaleChanged();
}

void DanmakuCanvas::setTrackHeight(int v)
{
    if (m_trackHeight != v) {
        m_trackHeight = v;
        emit trackHeightChanged();
        update();
    }
}

void DanmakuCanvas::setDanmakuEnabled(bool v)
{
    if (m_danmakuEnabled != v) {
        m_danmakuEnabled = v;
        emit danmakuEnabledChanged();
        kickstart();
    }
}

void DanmakuCanvas::setMaxItems(int v)
{
    if (m_maxItems != v && v > 0) {
        m_maxItems = v;
        emit maxItemsChanged();
    }
}

void DanmakuCanvas::setOutlineStyle(int v)
{
    // 非法值钳到 0（描边）；切换后全部纹理需按新样式重建
    if (v < 0 || v > 2)
        v = 0;
    if (m_outlineStyle == v)
        return;
    m_outlineStyle = v;
    emit outlineStyleChanged();
    refreshLineHeight();  // 三档外扩量不同 → 轨道高度下限随之变化
    markFontDirty();      // 已在屏弹幕也按新样式重渲染（走现成的纹理重建链）
}



void DanmakuCanvas::markFontDirty()
{
    m_fontDirty = true;   // 在 updatePaintNode 内重建全部纹理
    update();
}

// ---------------------------------------------------------------------------
// 场景图渲染
// ---------------------------------------------------------------------------
QSGNode *DanmakuCanvas::updatePaintNode(QSGNode *oldNode, UpdatePaintNodeData *)
{
    ensureFrameConnection();   // 帧驱动连接自愈（每次渲染检查一次，零成本）

    auto *root = static_cast<QSGNode *>(oldNode);
    if (!root)
        root = new QSGNode;

    // 跨窗口迁移的节点树/纹理池清理已在 itemChange 里完成（见该函数注释）：
    // 节点树由 Qt 在旧窗口渲染线程删除，此处无需也无法安全触碰。

    // 延迟槽位回收（clear/evict 时登记，统一在此处执行节点操作）
    for (int slot : m_pendingFreeSlots) {
        if (slot >= 0 && slot < m_pool.size()) {
            // 图集区域立即归还 + markFreed 防止复用路径二次归还（双重
            // atlasFree 会损坏空闲区间表，见 AtlasSubTexture::markFreed）。
            // 子纹理对象保留：节点材质仍持其指针，rect 已置空 →
            // 顶点退化零面积，无采样输出
            if (m_pool[slot].texNode && m_pool[slot].texNode->texture()) {
                auto *sub = static_cast<AtlasSubTexture *>(
                                 m_pool[slot].texNode->texture());
                atlasFree(sub->subRect());
                sub->markFreed();
            }
            m_pool[slot].texNode->setRect(QRectF());   // 置空即不可见，纹理留待复用
            m_pool[slot].inUse = false;
        }
    }
    m_pendingFreeSlots.clear();

    if (m_clearRequested) {
        for (auto &s : m_pool) {
            if (s.inUse) {
                if (s.texNode->texture()) {
                    auto *sub = static_cast<AtlasSubTexture *>(s.texNode->texture());
                    atlasFree(sub->subRect());
                    sub->markFreed();   // 同上：防二次归还
                }
                s.texNode->setRect(QRectF());
                s.inUse = false;
            }
        }
        m_clearRequested = false;
    }

    const qreal W = width();
    const qreal dpr = window() ? window()->effectiveDevicePixelRatio() : 1.0;

    // DPR 变化（跨屏拖动）也触发纹理重建
    if (dpr > 0 && !qFuzzyCompare(dpr, m_lastDpr)) {
        m_lastDpr = dpr;
        m_fontDirty = true;
    }

    // 图集整图重排（compact）。触发条件三合一：
    //  1. 分配失败（图集满/碎片化）；
    //  2. 字号/DPR 变化——旧区域尺寸与新位图不匹配，行高错配会碎片化；
    //  3. 两者都导致全部区域作废、所有活跃弹幕重烘焙。m_fontDirty=true
    //     豁免单帧激活预算，一帧完成（低频路径：图集容量 ~200 条平均弹幕）
    bool atlasResetThisFrame = false;
    if (m_atlasResetPending || m_fontDirty) {
        m_atlasResetPending = false;
        atlasResetThisFrame = true;
        atlasReset();
        // 整图作废时必须同步置空池内全部旧子纹理的 subRect：
        // 本帧重建循环边分配新区域边复用槽位（atlasFree 旧 subRect），
        // 而新布局与旧布局同为紧凑打包、行坐标大量重合——若旧坐标
        // 仍有效，会被误当作新布局的区域归还进空闲表 → 后续分配区域
        // 重叠 → 两条弹幕共用图集区域、上传互相覆盖 = "变成其他字/
        // 截断"（即 markFreed 注释所述失效模式，此前漏了重排这条路径）。
        // 置空后：重建循环的 atlasFree 自动忽略、下帧延迟回收路径
        // 同样安全；未被本帧重建的槽位零面积无采样
        for (auto &s : m_pool) {
            if (s.texNode && s.texNode->texture())
                static_cast<AtlasSubTexture *>(s.texNode->texture())->markFreed();
        }
        for (auto &it : m_live)
            it.textureReady = false;
        m_fontDirty = true;
    }

    if (!m_danmakuEnabled)
        return root;

    m_now = presentationMs();   // 渲染同步点采样 + 外推到帧呈现时刻（vsync 相位对齐）
    // 同步时刻记录：渲染线程在下一个 frameSwapped 里用它测"同步→Present"耗时
    // （渲染提前量 EMA），认领网格边界时预留，见 ensureFrameConnection
    m_lastSyncNs.store(m_swapClock.nsecsElapsed(), std::memory_order_release);

    bool countsDirty = false;
    int activations = 0;   // 本帧纹理激活计数（配合 kMaxActivationsPerFrame）

    for (int i = m_live.size() - 1; i >= 0; --i) {
        LiveItem &it = m_live[i];
        const qint64 elapsed = m_now - it.startMs;

        // ---- 位置/存活计算（原 QML _tick 的逻辑，零 JS 开销） ----
        // 滚动位置用 ns 精度时间轴：ms 版 elapsed 的逐帧截断误差 ±1ms
        // 直接进入位置（三档步长），ns 版的认领步长恒定（见 presentationMs
        // 尾部注释）。elapsed（ms）仅用于存活判断等粗逻辑
        qreal x = 0;
        if (it.type == 1) {
            x = W - it.pixelSpeed * (m_nowNs - it.startNs) / 1000000.0;
            if (x + it.width < -50) {          // 完全滚出左缘（沿用原 -50 阈值）
                freeSlotDeferred(it.slot);
                m_live.removeAt(i);
                countsDirty = true;
                continue;
            }
        } else {
            x = (W - it.width) / 2.0;          // 固定弹幕水平居中
            if (elapsed >= it.durationMs) {
                freeSlotDeferred(it.slot);
                m_live.removeAt(i);
                countsDirty = true;
                continue;
            }
        }

        // ---- 字号/DPR 变化：实测尺寸随之更新 ----
        if (m_fontDirty) {
            if (!it.emoticonUrl.isEmpty()) {
                const QSizeF sz = emoticonLogicalSize(
                            EmoticonCache::instance()->image(it.emoticonUrl),
                            it.fontScale, it.emoticonSize);
                it.width = sz.width();
                it.height = sz.height();
            } else if (!it.inlineEmos.isEmpty()) {
                measureMixed(it.text, it.inlineEmos, it.fontScale, it.width, it.height);
            } else {
                measure(it.text, it.fontScale, it.width, it.height);
            }
        }

        // ---- 首次上屏 / 纹理重建 ----
        if (!it.textureReady || m_fontDirty) {
            // 表情图就绪检查（纯表情 / 混排）。图未就绪 → 本帧不烘焙不占
            // 预算不占槽位（尚未绘制，无闪烁），等 EmoticonCache::ready
            // 触发 update() 重试；下载失败或等待超时 8s：
            //   纯表情 → 丢弃（表情是整条弹幕的全部内容，无文本可降级）
            //   混排   → 该表情降级为普通文本占位符，其余内容正常渲染
            if (!it.textureReady) {
                if (!it.emoticonUrl.isEmpty()) {
                    if (!EmoticonCache::instance()->isReady(it.emoticonUrl)) {
                        if (EmoticonCache::instance()->isFailed(it.emoticonUrl)
                                || m_now - it.startMs > 8000) {
                            m_live.removeAt(i);
                            countsDirty = true;
                        } else {
                            // 入队侧已 prefetch；此处兜底（幂等，磁盘命中会立即 ready）
                            EmoticonCache::instance()->prefetch(it.emoticonUrl);
                        }
                        continue;
                    }
                } else if (!it.inlineEmos.isEmpty()) {
                    bool waitingEmo = false;
                    for (auto &emo : it.inlineEmos) {
                        if (emo.failed || EmoticonCache::instance()->isReady(emo.url))
                            continue;
                        if (EmoticonCache::instance()->isFailed(emo.url)
                                || m_now - it.startMs > 8000) {
                            emo.failed = true;   // 降级：占位符按普通文本渲染
                        } else {
                            EmoticonCache::instance()->prefetch(emo.url);
                            waitingEmo = true;
                        }
                    }
                    if (waitingEmo)
                        continue;
                    // 全部就绪/降级 → 用实测图尺寸覆盖入队时的方形估算
                    measureMixed(it.text, it.inlineEmos, it.fontScale, it.width, it.height);
                }
            }

            // 单帧纹理激活预算：弹幕高峰（如直播高能时刻）分批上屏，
            // 避免一帧内多次烘焙造成尖刺帧
            if (!m_fontDirty && activations >= kMaxActivationsPerFrame)
                continue;                        // 本帧预算用尽，下一帧再上屏（尚未分配槽位，不绘制）

            if (it.slot < 0)
                it.slot = acquireSlot();
            if (it.slot < 0) {                 // 节点池耗尽 → 丢弃
                m_live.removeAt(i);
                countsDirty = true;
                continue;
            }

            // 烘焙（物理像素）+ pad 环绕：bilinear 采样半径 1px，防止
            // 图集内相邻弹幕位图边缘互相渗色
            QImage img;
            if (!it.emoticonUrl.isEmpty())
                img = renderEmoticonImage(EmoticonCache::instance()->image(it.emoticonUrl),
                                          dpr, it.fontScale, it.emoticonSize);
            else if (!it.inlineEmos.isEmpty())
                img = renderMixed(it.text, it.inlineEmos, it.color, dpr, it.fontScale);
            else
                img = renderImage(it.text, it.color, dpr, it.fontScale);
            QImage padded(img.width() + 2 * kAtlasPad, img.height() + 2 * kAtlasPad,
                          QImage::Format_RGBA8888_Premultiplied);
            padded.fill(Qt::transparent);
            {
                QPainter pp(&padded);
                pp.drawImage(kAtlasPad, kAtlasPad, img);
            }

            Slot &s = m_pool[it.slot];
            QRect sub = atlasAlloc(padded.width(), padded.height());
            if (!sub.isValid()) {
                if (padded.width() > m_atlasSize.width()
                        || padded.height() > m_atlasSize.height()
                        || atlasResetThisFrame) {
                    // 超图集尺寸（超长弹幕/超高 DPR），或重排后仍装不下
                    // （活跃弹幕总位图超出图集容量，如 400 条大字号高峰）
                    // —— 丢弃，防止逐帧 reset+全量重烘焙的烘焙风暴。
                    // 登记槽位回收：不登记则节点残留（冻结弹幕）且槽位永久泄漏
                    freeSlotDeferred(it.slot);
                    m_live.removeAt(i);
                    countsDirty = true;
                    continue;
                }
                // 图集满/碎片化：标记整图重排，本条下一帧重新激活。
                // 立即标记 inUse：槽位已绑定本条弹幕，若保持 false，
                // 跨帧窗口内会被其他弹幕的 acquireSlot 偷走（两条弹幕
                // 共用一个节点 = 弹幕内容互换/丢失）
                m_pool[it.slot].inUse = true;
                m_atlasResetPending = true;
                update();
                continue;
            }

            // 复用槽位：归还旧区域并替换子纹理（同步点内先 delete 后
            // setTexture，渲染线程此期间被 sync 屏障阻塞，无野指针窗口）
            if (s.texNode->texture()) {
                auto *oldSub = static_cast<AtlasSubTexture *>(s.texNode->texture());
                atlasFree(oldSub->subRect());
                purgePendingUploads(oldSub);   // 摘除可能残留的上传条目，防悬垂
                delete oldSub;
            }
            AtlasSubTexture *subTex = new AtlasSubTexture(this, sub, m_atlasSize);
            s.texNode->setTexture(subTex);

            // 入上传队列：渲染线程在材质准备阶段（commitTextureOperations）
            // 部分写入宿主纹理并回填快照。首个（或失效后的首个）子纹理
            // 触发宿主创建
            if (!m_atlasTex.load(std::memory_order_acquire))
                m_atlasCreatePending.store(true, std::memory_order_release);
            {
                QMutexLocker lock(&m_uploadMutex);
                m_pendingUploads.append({padded, sub.topLeft(), subTex});
            }

            // rect 含 pad 外扩：内容区精确对齐 (0,0)-(w,h) 逻辑像素，
            // 显示比例与无图集版本严格一致（1 物理像素 : 1 物理像素）
            const qreal pd = kAtlasPad / dpr;
            s.texNode->setRect(QRectF(-pd, -pd,
                                      padded.width() / dpr, padded.height() / dpr));
            if (!s.xform->parent())
                root->appendChildNode(s.xform);       // 纹理就绪后再挂树
            s.inUse = true;
            it.textureReady = true;
            ++activations;

            // 因激活预算延迟上屏的弹幕，从右缘准点进入，避免"跳入"屏幕
            if (!m_fontDirty) {
                it.startMs = m_now;
                it.startNs = m_nowNs;
                if (it.type == 1)
                    x = W;
            }
        }

        // ---- 每帧唯一开销：更新一个 4x4 平移矩阵 ----
        // 垂直方向沿用原版的轨道内居中：drawY = yPos + (基准高 - imgH)/2。
        // 基准高默认为轨道高；跨轨道的大字号弹幕（B站 2.0x 字号）由 QML
        // 传入 vCenterBase（span 条轨道总高），使其在占据区域内整体居中
        const qreal vBase = it.vCenterBase > 0 ? it.vCenterBase : qreal(m_trackHeight);
        QMatrix4x4 m;
        m.translate(float(x), float(it.yPos + (vBase - it.height) / 2.0));
        m_pool[it.slot].xform->setMatrix(m);
    }
    m_fontDirty = false;

    if (m_traceFile) {
        for (const auto &e : m_live) {
            if (e.type == 1 && e.textureReady) {
                const qreal x = W - e.pixelSpeed * (m_nowNs - e.startNs) / 1000000.0;
                fprintf(m_traceFile, "%lld,%.3f\n", (long long)m_now, double(x));
                fflush(m_traceFile);
                break;
            }
        }
    }

    if (countsDirty)
        emit activeCountChanged();
    return root;
}

int DanmakuCanvas::acquireSlot()
{
    for (int i = 0; i < m_pool.size(); ++i) {
        if (!m_pool[i].inUse)
            return i;
    }
    if (m_pool.size() >= kMaxSlots)
        return -1;

    // 新槽位先保持游离（不挂树），待纹理设置完成后再 appendChildNode，
    // 避免空纹理节点挂树导致 software backend 崩溃
    Slot s;
    s.xform = new QSGTransformNode;
    s.texNode = new QSGSimpleTextureNode;
    s.texNode->setOwnsTexture(false);   // 纹理生命周期由弹幕逻辑管理
    // 采样过滤必须设在节点上：QSGSimpleTextureNode 的采样状态保存在其材质中，
    // 材质默认 Nearest，且仅 QSGTexture::setFiltering() 无法改变它。
    // Nearest 会把每帧 2~4px 位移中的亚像素部分吸附到整数像素，
    // 逐帧步进变成 4,4,3,4…… 的不均匀跳动感（滚动振动感的主因）。
    // Linear 允许亚像素平滑过渡，与 B 站网页端的子像素渲染观感一致。
    s.texNode->setFiltering(QSGTexture::Linear);
    s.xform->appendChildNode(s.texNode);
    m_pool.append(s);
    return m_pool.size() - 1;
}

void DanmakuCanvas::freeSlotDeferred(int slot)
{
    if (slot >= 0)
        m_pendingFreeSlots.append(slot);
}

// ---------------------------------------------------------------------------
// 外接字体：exe 同目录 fonts/ 下的 .ttf/.otf/.ttc 注册为进程内字体，
// 家族名进回退链最前端；目录不存在/文件损坏时静默落到系统雅黑/黑体
// ---------------------------------------------------------------------------
QStringList DanmakuCanvas::fontFamilies()
{
    // C++11 魔法静态：进程内首次调用时扫描注册一次，此后直接返回结果
    static const QStringList families = [] {
        QStringList chain;
        const QDir dir(QCoreApplication::applicationDirPath() + QStringLiteral("/fonts"));
        if (dir.exists()) {
            const auto files = dir.entryInfoList(
                {QStringLiteral("*.ttf"), QStringLiteral("*.otf"), QStringLiteral("*.ttc")},
                QDir::Files, QDir::Name);   // 按文件名排序：多个字体时排前的优先级高
            for (const QFileInfo &fi : files) {
                const int id = QFontDatabase::addApplicationFont(fi.absoluteFilePath());
                if (id < 0) {
                    qWarning() << "[DanmakuCanvas] 外接字体加载失败（已跳过）:" << fi.fileName();
                    continue;
                }
                chain.append(QFontDatabase::applicationFontFamilies(id));
            }
            if (!chain.isEmpty())
                qDebug() << "[DanmakuCanvas] 外接弹幕字体已启用:" << chain;
        }
        chain.append({QStringLiteral("Microsoft YaHei"), QStringLiteral("SimHei")});
        return chain;
    }();
    return families;
}

void DanmakuCanvas::loadExternalFonts()
{
    fontFamilies();   // 幂等：仅触发一次性扫描注册，重复调用零开销
}

// ---------------------------------------------------------------------------
// 描边样式参数（对齐 B 站网页端三档）：
//   0=描边   等宽黑边（半透明 217），粗细 fontSize/10
//   1=重墨   加粗描边（不透明），粗细 fontSize/12（8 方向偏移叠加后
//            边宽约为描边档的 1.5 倍，B 站同款的"稍厚+更黑"）
//   2=投影   无描边，右下 45° 半透明影，偏移 fontSize/12
// 三种样式的外扩量不同，measure/renderImage/calcLineHeight 共用此处参数
// ---------------------------------------------------------------------------
int DanmakuCanvas::outlineExtent(int fontSize) const
{
    switch (m_outlineStyle) {
    case 1:  return qMax(1, fontSize / 12);   // 重墨：稍厚的边
    case 2:  return qMax(1, fontSize / 12);   // 投影：右下偏移量（小偏移，影子隐约可辨）
    default: return qMax(1, fontSize / 10);   // 描边
    }
}

// ---------------------------------------------------------------------------
// 轨道行高：当前字号档下单条弹幕的实际渲染高度（QML 轨道高度下限的依据）
// ---------------------------------------------------------------------------
qreal DanmakuCanvas::calcLineHeight() const
{
    // 与 measure() 同参（dmScale=1）：ascent+descent+上下外扩，再加 2px 行距
    // 让相邻轨道肉眼可分。字体度量依赖已加载的弹幕字体链
    const int logicalSize = qMax(1, logicalFontSize());
    QFont font;
    font.setFamilies(fontFamilies());
    font.setPixelSize(logicalSize);
    const QFontMetrics fm(font);
    const int extent = outlineExtent(logicalSize);
    return fm.ascent() + fm.descent() + extent * 2 + 2;
}

void DanmakuCanvas::refreshLineHeight()
{
    const qreal h = calcLineHeight();
    if (!qFuzzyCompare(m_lineHeight, h)) {
        m_lineHeight = h;
        emit lineHeightChanged();
    }
}

// ---------------------------------------------------------------------------
// 文本测量与预渲染（参数与原 renderDanmakuImage 保持一致，观感无变化）
// ---------------------------------------------------------------------------
void DanmakuCanvas::measure(const QString &text, qreal fontScale, qreal &outW, qreal &outH) const
{
    const int logicalSize = qMax(1, qRound(logicalFontSize() * fontScale));
    QFont font;
    font.setFamilies(fontFamilies());   // 外接字体优先，雅黑/黑体兜底（与 renderImage 保持一致）
    font.setPixelSize(logicalSize);
    //font.setWeight(QFont::Black);

    const QFontMetrics fm(font);
    const int extent = outlineExtent(logicalSize);
    // 必须与 renderImage() 的位图分配严格一致（对称 extent*2）：
    // it.width/it.height 参与固定弹幕居中与垂直居中，两者不一致会导致
    // 位置偏移；曾试过投影档不对称测量（左侧只留 1px），与渲染位图
    // 尺寸脱节引发异常，已回退为全样式对称
    outW = fm.horizontalAdvance(text) + extent * 2;
    outH = fm.ascent() + fm.descent() + extent * 2;
}

QImage DanmakuCanvas::renderImage(const QString &text, const QColor &color, qreal dpr, qreal fontScale) const
{
    if (dpr <= 0) dpr = 1.0;
    const int physicalFontSize = qMax(1, qRound(logicalFontSize() * fontScale * dpr));

    QFont font;
    font.setFamilies(fontFamilies());   // 外接字体优先，雅黑/黑体兜底（与 measure 保持一致）
    font.setPixelSize(physicalFontSize);
    //font.setWeight(QFont::Black);

    const QFontMetrics fm(font);
    const int extent = outlineExtent(physicalFontSize);
    const int imgWidth  = fm.horizontalAdvance(text) + extent * 2;
    const int imgHeight = fm.ascent() + fm.descent() + extent * 2;

    // RGBA8888_Premultiplied：与 QRhiTexture::RGBA8 内存布局匹配，
    // 图集部分上传零转换（ARGB32 需逐像素重排）
    QImage image(imgWidth, imgHeight, QImage::Format_RGBA8888_Premultiplied);
    image.fill(Qt::transparent);

    QPainter p(&image);
    // 与原版一致：关闭抗锯齿换取速度
    p.setRenderHint(QPainter::TextAntialiasing, true);
    p.setRenderHint(QPainter::Antialiasing, false);

    drawStyledText(p, text, extent, extent + fm.ascent(), font, fm, color, extent, dpr);
    p.end();

    return image;
}

// ---------------------------------------------------------------------------
// 按当前描边样式绘制一段文本（renderImage 与混排 renderMixed 共用）
//
// 描边粗细与 DPR 的关系：本函数工作在物理像素位图上，文字随 dpr 放大，
// 但视觉上"1 逻辑像素"的描边 = dpr 物理像素。因此所有偏移量乘以 u(=dpr)：
//   - 描边档 4 方向偏移、投影档兜底细边：u
//   - 重墨档环形半径步进：u（第 r 环偏移 r*u）
//   - 投影档影子偏移：extent（按物理字号比例，天然含 dpr，无需再乘）
// 基准观感为 1080P@100%（dpr=1，偏移即 1 物理像素）；2K@125%/150% 等
// 屏幕上描边逻辑粗细与基准一致，不再随缩放变细。
// 重墨档"是否补第 2 环"按逻辑字号判断（物理 extent 跨屏恒等换算）。
// ---------------------------------------------------------------------------
void DanmakuCanvas::drawStyledText(QPainter &p, const QString &text, qreal x,
                                   qreal baseline, const QFont &font,
                                   const QFontMetrics &fm, const QColor &color,
                                   int extent, qreal dpr) const
{
    const qreal u = qMax(1.0, dpr);   // 1 逻辑像素对应的物理像素数
    p.setFont(font);
    switch (m_outlineStyle) {
    case 1: {
        // 重墨：环形描边——第 1 环（8 方向 u）恒画，大逻辑字号（extent≥3）
        // 补第 2 环。边宽小字号 ~1.5 逻辑px、大字号 ~2.5 逻辑px，纯黑不透明，
        // 对比描边档是"稍厚 + 更黑"（B 站同款观感，不夸张）
        p.setPen(QColor(0, 0, 0, 255));
        const int logicalSize = qMax(1, qRound(qreal(font.pixelSize()) / u));
        const int rings = outlineExtent(logicalSize) >= 3 ? 2 : 1;
        for (int r = 1; r <= rings; ++r) {
            for (int dx = -r; dx <= r; ++dx) {
                for (int dy = -r; dy <= r; ++dy) {
                    if ((dx == 0 && dy == 0) || qMax(qAbs(dx), qAbs(dy)) != r)
                        continue;   // 只画第 r 环（边框环），内环跳过
                    p.drawText(QPointF(x + dx * u, baseline + dy * u), text);
                }
            }
        }
        p.setPen(color);
        p.drawText(QPointF(x, baseline), text);
        break;
    }
    case 2: {
        // 45° 投影：本体 + 右下偏移半透明影（B 站网页端同款，无真模糊）。
        // 本体加最细 1 逻辑px 描边（半透明，同描边档配色）：浅色弹幕在亮
        // 画面上本体边缘易糊进背景，细边兜住轮廓，观感仍保持"轻"
        p.setPen(QColor(0, 0, 0, 160));
        p.drawText(QPointF(x + extent, baseline + extent), text);
        p.setPen(QColor(0, 0, 0, 217));
        p.drawText(QPointF(x, baseline - u), text);
        p.drawText(QPointF(x, baseline + u), text);
        p.drawText(QPointF(x - u, baseline), text);
        p.drawText(QPointF(x + u, baseline), text);
        p.setPen(color);
        p.drawText(QPointF(x, baseline), text);
        break;
    }
    default: {
        // 描边：4 方向偏移（偏移量随 dpr 缩放，基准 1080P@100% 为 1 物理px）
        const QColor outlineColor(0, 0, 0, 217);
        p.setPen(outlineColor);
        p.drawText(QPointF(x, baseline - u), text);
        p.drawText(QPointF(x, baseline + u), text);
        p.drawText(QPointF(x - u, baseline), text);
        p.drawText(QPointF(x + u, baseline), text);

        p.setPen(color);
        p.drawText(QPointF(x, baseline), text);
        break;
    }
    }
}

// ---------------------------------------------------------------------------
// 文本+表情混排（直播专有，如 "1[哇]"）：
//   文本按占位符切分为 文本段/表情段 序列，表情段渲染为行内图片
//   （小表情 1.15 倍行高、大表情 1.8 倍行高，垂直方向在总高内居中）
//   measureMixed 与 renderMixed 共用切分逻辑；逻辑/物理两套度量分别
//   计算（与文本弹幕 measure/renderImage 同样的对应关系）
// ---------------------------------------------------------------------------
QVector<DanmakuCanvas::MixedRun> DanmakuCanvas::splitMixedRuns(
        const QString &text, const QVector<InlineEmo> &emos) const
{
    QVector<MixedRun> runs;
    int segStart = 0;
    int pos = 0;
    while (pos < text.length()) {
        bool matched = false;
        for (int e = 0; e < emos.size(); ++e) {
            const InlineEmo &emo = emos[e];
            if (emo.failed || emo.key.isEmpty())
                continue;
            if (text.mid(pos, emo.key.length()) == emo.key) {
                if (pos > segStart)
                    runs.append({false, text.mid(segStart, pos - segStart), -1});
                runs.append({true, QString(), e});
                pos += emo.key.length();
                segStart = pos;
                matched = true;
                break;
            }
        }
        if (!matched)
            ++pos;
    }
    if (pos > segStart)
        runs.append({false, text.mid(segStart, pos - segStart), -1});
    return runs;
}

void DanmakuCanvas::measureMixed(const QString &text, const QVector<InlineEmo> &emos,
                                 qreal fontScale, qreal &outW, qreal &outH) const
{
    const int logicalSize = qMax(1, qRound(logicalFontSize() * fontScale));
    QFont font;
    font.setFamilies(fontFamilies());   // 与 renderMixed/measure 同链，防截断
    font.setPixelSize(logicalSize);
    const QFontMetrics fm(font);
    const int extent = outlineExtent(logicalSize);
    const qreal textH = fm.ascent() + fm.descent() + extent * 2;

    qreal w = extent * 2;   // 左右描边外扩（与 renderMixed 位图分配一致）
    qreal h = textH;
    const QVector<MixedRun> runs = splitMixedRuns(text, emos);
    for (const MixedRun &run : runs) {
        if (run.isEmo) {
            const InlineEmo &emo = emos[run.emoIdx];
            const QSizeF sz = emoticonLogicalSize(
                        EmoticonCache::instance()->image(emo.url), fontScale, emo.size);
            w += sz.width();
            h = qMax(h, sz.height());
        } else {
            w += fm.horizontalAdvance(run.text);
        }
    }
    outW = w;
    outH = h;
}

QImage DanmakuCanvas::renderMixed(const QString &text, const QVector<InlineEmo> &emos,
                                  const QColor &color, qreal dpr, qreal fontScale) const
{
    if (dpr <= 0) dpr = 1.0;
    const int physicalFontSize = qMax(1, qRound(logicalFontSize() * fontScale * dpr));

    QFont font;
    font.setFamilies(fontFamilies());
    font.setPixelSize(physicalFontSize);
    const QFontMetrics fm(font);
    const int extent = outlineExtent(physicalFontSize);
    const qreal textH = fm.ascent() + fm.descent() + extent * 2;

    // 布局（物理像素）：文本段按物理字体度量，表情段按逻辑尺寸×dpr
    // （与 renderEmoticonImage 同规则，节点 rect 以位图尺寸为准）
    const QVector<MixedRun> runs = splitMixedRuns(text, emos);
    QVector<QSizeF> emoSizes(emos.size());
    qreal w = extent * 2;
    qreal h = textH;
    for (const MixedRun &run : runs) {
        if (run.isEmo) {
            const InlineEmo &emo = emos[run.emoIdx];
            const QSizeF logical = emoticonLogicalSize(
                        EmoticonCache::instance()->image(emo.url), fontScale, emo.size);
            const QSizeF physical(logical.width() * dpr, logical.height() * dpr);
            emoSizes[run.emoIdx] = physical;
            w += physical.width();
            h = qMax(h, physical.height());
        } else {
            w += fm.horizontalAdvance(run.text);
        }
    }

    QImage image(qMax(1, qRound(w)), qMax(1, qRound(h)),
                 QImage::Format_RGBA8888_Premultiplied);
    image.fill(Qt::transparent);

    QPainter p(&image);
    p.setRenderHint(QPainter::TextAntialiasing, true);
    p.setRenderHint(QPainter::Antialiasing, false);
    p.setRenderHint(QPainter::SmoothPixmapTransform, true);

    // 文本在总高内垂直居中：大表情撑高整条时文本随之居中
    const qreal textY = (h - textH) / 2.0;
    const qreal baseline = textY + extent + fm.ascent();

    qreal x = extent;
    for (const MixedRun &run : runs) {
        if (run.isEmo) {
            const QSizeF sz = emoSizes[run.emoIdx];
            // 表情是裸图不描边（B 站同款），在总高内垂直居中
            p.drawImage(QRectF(x, (h - sz.height()) / 2.0, sz.width(), sz.height()),
                        EmoticonCache::instance()->image(emos[run.emoIdx].url));
            x += sz.width();
        } else {
            drawStyledText(p, run.text, x, baseline, font, fm, color, extent, dpr);
            x += fm.horizontalAdvance(run.text);
        }
    }
    p.end();
    return image;
}

// ---------------------------------------------------------------------------
// 表情弹幕：尺寸测量与预渲染（直播专有）
//   小表情：约 1.15 倍行高的行内图（B 站直播观感，略高于文字）
//   大表情：约 1.8 倍行高，跨轨道占用（QML 侧轨道 span 已按同比例计算）
//   宽度按原图纵横比等比缩放，上限 4 倍高（防超宽图撑爆图集/屏幕）
// ---------------------------------------------------------------------------
QSizeF DanmakuCanvas::emoticonLogicalSize(const QImage &src, qreal fontScale, int emoticonSize) const
{
    const int logicalSize = qMax(1, qRound(logicalFontSize() * fontScale));
    QFont font;
    font.setFamilies(fontFamilies());
    font.setPixelSize(logicalSize);
    const QFontMetrics fm(font);
    const int extent = outlineExtent(logicalSize);
    const qreal textH = fm.ascent() + fm.descent() + extent * 2;

    const qreal h = textH * (emoticonSize == 2 ? kEmoteScaleLarge : kEmoteScaleSmall);
    if (src.isNull() || src.height() <= 0)
        return QSizeF(h, h);   // 图未就绪：方形估算（就绪后由实测尺寸覆盖）
    qreal w = h * qreal(src.width()) / qreal(src.height());
    const qreal maxW = h * 4.0;
    if (w > maxW)
        w = maxW;
    return QSizeF(w, h);
}

QImage DanmakuCanvas::renderEmoticonImage(const QImage &src, qreal dpr, qreal fontScale, int emoticonSize) const
{
    if (dpr <= 0) dpr = 1.0;
    // 物理尺寸与 emoticonLogicalSize 严格一致（it.width/height 参与
    // 位置计算，measure/render 脱节会导致表情错位，同文本弹幕约束）
    const QSizeF logical = emoticonLogicalSize(src, fontScale, emoticonSize);

    QImage image(qMax(1, qRound(logical.width() * dpr)),
                 qMax(1, qRound(logical.height() * dpr)),
                 QImage::Format_RGBA8888_Premultiplied);
    image.fill(Qt::transparent);

    // 表情是裸图不描边（B 站同款）；SmoothPixmapTransform 缩放平滑
    QPainter p(&image);
    p.setRenderHint(QPainter::SmoothPixmapTransform, true);
    p.drawImage(QRectF(0, 0, image.width(), image.height()), src);
    p.end();
    return image;
}
