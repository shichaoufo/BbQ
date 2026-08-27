#ifndef DANMAKUCANVAS_H
#define DANMAKUCANVAS_H

#include <QQuickItem>
#include <QImage>
#include <QVector>
#include <QVarLengthArray>
#include <QList>
#include <QColor>
#include <QFont>
#include <QElapsedTimer>
#include <QPointer>
#include <QStringList>
#include <QVariantList>
#include <atomic>
#include <QSGTexture>
#include <QMutex>

class QSGNode;
class QSGTransformNode;
class QSGSimpleTextureNode;
class QQuickWindow;
class QRhi;
class QRhiTexture;
class QRhiResourceUpdateBatch;
class QPainter;
class QFontMetrics;

/**
 * @brief 图集子区域纹理：全部弹幕位图共存于一张大 QRhiTexture（图集），
 * 每条弹幕一个本类实例，通过 normalizedTextureSubRect() 把节点 UV 指向
 * 图集内的私有区域。
 *
 * 合批关键：comparisonKey() 返回宿主画布指针——同一画布内所有子纹理
 * key 相同，QSGTextureMaterial::compare() 视为同一材质 → 批处理器把
 * 全部弹幕 quad 合进一个批次（1 次纹理绑定 + 1 个 draw call），
 * 替代此前"每条弹幕一张独立纹理 → 80 个批次"的组织方式
 * （对齐 nanovg 字体图集的合批原理，见项目弹幕性能分析）。
 *
 * 线程模型：m_hostTex 是宿主纹理指针的快照——构造时为 null，由渲染线程
 * 在 flushAtlasUploads 上传该子纹理位图时回填（材质渲染时读，读写均在
 * 渲染线程，GUI 线程永不触碰，无竞态）。窗口迁移/场景图失效时子纹理
 * 整体重建，快照随之重新回填。subRect 在构造时固定；区域归还时由
 * markFreed() 显式置空（防二次归还）——归还后仅当节点 rect 为空
 * （顶点退化、零面积）时才会被渲染，无采样输出，安全。
 */
class AtlasSubTexture : public QSGTexture
{
public:
    AtlasSubTexture(class DanmakuCanvas *host, const QRect &subRect, const QSize &atlasSize)
        : m_host(host), m_subRect(subRect), m_atlasSize(atlasSize) {}

    QSize  textureSize() const override { return m_subRect.size(); }
    QRhiTexture *rhiTexture() const override { return m_hostTex; }
    bool   hasAlphaChannel() const override { return true; }
    bool   hasMipmaps() const override { return false; }
    QRectF normalizedTextureSubRect() const override;
    qint64 comparisonKey() const override;

    /// 官方图集同款上传机制（QSGRhiAtlasTexture::TextureBase::commitTextureOperations）：
    /// 批渲染器在材质绑定时调用本方法，渲染器已备好 rhi 与 resourceUpdate 批。
    /// 本类仅作触发器，转交宿主画布统一 flush 全部待上传位图（合批后渲染器
    /// 只对批次首个材质调用 commit，因此上传队列必须挂在画布层整体消费）
    void   commitTextureOperations(QRhi *rhi, QRhiResourceUpdateBatch *resourceUpdates) override;

    /// 渲染线程回填宿主纹理快照（随该子纹理的位图上传一并完成）
    void   setHostTexture(QRhiTexture *tex) { m_hostTex = tex; }

    /// 图集内像素区域（含 pad 环绕）
    const QRect &subRect() const { return m_subRect; }

    /// 区域已归还（槽位回收/清屏）：置空 subRect，防止槽位复用路径
    /// 对同一区域二次归还（双重 atlasFree 会产生重叠空闲区间，后续
    /// 分配区域重叠、上传互相覆盖 = 弹幕"变成其他字/被截断"）。
    /// atlasFree 对无效矩形自动忽略。对象保留：节点 rect 已置空 →
    /// 零面积 quad 无采样输出，安全
    void   markFreed() { m_subRect = QRect(); }

private:
    DanmakuCanvas *m_host;
    QRect m_subRect;
    QSize m_atlasSize;                   ///< 构造时快照：归一化 UV 用（图集尺寸恒定）
    QRhiTexture *m_hostTex = nullptr;   ///< 仅渲染线程读写（见类注释）
};

/**
 * @brief 高性能弹幕画布（场景图实现，替代原 QQuickPaintedItem 版本）
 *
 * 与原版本接口对应关系（QML 侧由 DanmakuOverlay 适配，页面零改动）：
 *   - 原 items(QVariantList) 每帧全量同步  →  appendScroll/appendFixed 增量发射
 *   - 原 repaint() + QML _tick 算位置      →  时钟与位置全在 C++（同步点采样，零 JS）
 *   - 原 QML _applySpeedScaleToItems       →  speedScale 属性绑定，C++ 进度保持式调速
 *
 * 性能要点：
 *   1. 所有弹幕挂在一个场景图根节点下，每帧仅一次场景图同步；
 *   2. 弹幕文本激活时一次性预渲染为纹理（沿用原版参数：SimHei/Black/四向描边），
 *      滚动期间每帧只更新 QSGTransformNode 的平移矩阵；
 *   3. 节点池复用，滚动结束只置空矩形归还池，运行时零 new/delete；
 *   4. 每帧零纹理上传（仅新弹幕激活时上传一次），零 CPU 重绘。
 */
class DanmakuCanvas : public QQuickItem
{
    Q_OBJECT
    Q_PROPERTY(int baseFontSize READ baseFontSize WRITE setBaseFontSize NOTIFY baseFontSizeChanged)
    Q_PROPERTY(qreal fontSizeScale READ fontSizeScale WRITE setFontSizeScale NOTIFY fontSizeScaleChanged)
    Q_PROPERTY(qreal speedScale READ speedScale WRITE setSpeedScale NOTIFY speedScaleChanged)
    Q_PROPERTY(int trackHeight READ trackHeight WRITE setTrackHeight NOTIFY trackHeightChanged)
    // 当前字号档（baseFontSize*fontSizeScale，dmScale=1）下单条弹幕的实际渲染高度
    // （含描边与行距）。QML 用它做轨道高度下限，防止字号调大后相邻轨道重叠
    Q_PROPERTY(qreal lineHeight READ lineHeight NOTIFY lineHeightChanged)
    Q_PROPERTY(bool danmakuEnabled READ danmakuEnabled WRITE setDanmakuEnabled NOTIFY danmakuEnabledChanged)
    Q_PROPERTY(int maxItems READ maxItems WRITE setMaxItems NOTIFY maxItemsChanged)
    Q_PROPERTY(int activeCount READ activeCount NOTIFY activeCountChanged)
    // 描边样式（对齐 B 站网页端）：0=描边 1=重墨 2=45°投影
    Q_PROPERTY(int outlineStyle READ outlineStyle WRITE setOutlineStyle NOTIFY outlineStyleChanged)
    // 暂停状态：true 时弹幕原地冻结、帧驱动链停转（不空耗渲染）
    Q_PROPERTY(bool paused READ paused WRITE setPaused NOTIFY pausedChanged)

public:
    explicit DanmakuCanvas(QQuickItem *parent = nullptr);
    ~DanmakuCanvas() override;

    // ---- 弹幕发射（增量接口，替代原 items 属性全量同步） ----
    /// 滚动弹幕：pixelSpeed 单位 px/ms（已含 speedScale），从右缘开始进入
    /// fontScale：单条弹幕字号缩放（B站 XML fontSize 字段换算，25 号字 = 1.0）
    /// vCenterBase：垂直居中基准高度（跨轨道占用时为 span 条轨道总高，
    ///              0 = 使用 trackHeight 属性，单轨道弹幕的默认）
    /// emoticonUrl：直播纯表情弹幕图（空 = 普通文本/混排弹幕；text 可为空）。
    ///              图未就绪时弹幕延迟激活（等 EmoticonCache::ready），
    ///              下载失败/超时 8s 丢弃
    /// emoticonSize：1=小表情（约 1.15 倍行高） 2=大表情（约 1.8 倍行高）
    /// emoticons：文本+表情混排（如 "1[哇]"），元素为 map{text,url,size}，
    ///            text 是文本内的占位符（会被图片替换）。任一图未就绪时
    ///            整条延迟激活；失败/超时的表情降级为普通文本占位符
    Q_INVOKABLE void appendScroll(const QString &text, const QString &color,
                                  qreal yPos, qreal pixelSpeed, qint64 nowMs,
                                  qreal fontScale = 1.0, qreal vCenterBase = 0.0,
                                  const QString &emoticonUrl = QString(),
                                  int emoticonSize = 1,
                                  const QVariantList &emoticons = QVariantList());
    /// 顶部/底部固定弹幕：durationMs 后消失，水平居中（vCenterBase 同上）
    Q_INVOKABLE void appendFixed(const QString &text, const QString &color,
                                 qreal yPos, qint64 durationMs, qint64 nowMs,
                                 qreal fontScale = 1.0, qreal vCenterBase = 0.0);
    /// 弹幕时钟（单调、暂停补偿）。QML 在 addDanmaku 的轨道分配中使用，
    /// 保证轨道时间戳与弹幕位置共用同一时钟
    Q_INVOKABLE qint64 currentMs() const;
    /// 清空所有弹幕并重置时钟
    Q_INVOKABLE void clear();

    /// 注册 exe 同目录 fonts/ 下的外接字体（幂等，进程级仅一次）。
    /// 需在 QGuiApplication 创建之后调用；main() 启动时已调用，
    /// 漏调时首次使用弹幕字体也会惰性加载
    static void loadExternalFonts();

    // ---- 属性 ----
    int baseFontSize() const { return m_baseFontSize; }
    void setBaseFontSize(int v);

    qreal fontSizeScale() const { return m_fontSizeScale; }
    void setFontSizeScale(qreal v);

    qreal speedScale() const { return m_speedScale; }
    void setSpeedScale(qreal v);   // 进度保持式调速（替代原 QML 逐条重算）

    int trackHeight() const { return m_trackHeight; }
    void setTrackHeight(int v);

    qreal lineHeight() const { return m_lineHeight; }

    bool danmakuEnabled() const { return m_danmakuEnabled; }
    void setDanmakuEnabled(bool v);

    int maxItems() const { return m_maxItems; }
    void setMaxItems(int v);

    bool paused() const { return m_paused; }
    void setPaused(bool v);

    int outlineStyle() const { return m_outlineStyle; }
    void setOutlineStyle(int v);

    int activeCount() const { return m_live.size(); }

signals:
    void baseFontSizeChanged();
    void fontSizeScaleChanged();
    void lineHeightChanged();
    void speedScaleChanged();
    void trackHeightChanged();
    void danmakuEnabledChanged();
    void maxItemsChanged();
    void activeCountChanged();
    void outlineStyleChanged();
    void pausedChanged();

protected:
    QSGNode *updatePaintNode(QSGNode *oldNode, UpdatePaintNodeData *data) override;
    void itemChange(ItemChange change, const ItemChangeData &data) override;

private:
    friend class AtlasSubTexture;   // commitTextureOperations → flushAtlasUploads

    /// 在屏弹幕（GUI 线程侧状态；QSG 节点只准在 updatePaintNode 内碰）
    /// 行内表情（文本+表情混排，如 "1[哇]"）：key 为文本占位符
    struct InlineEmo {
        QString key;      ///< 文本内的占位符（如 "[哇]"），渲染时被图片替换
        QString url;      ///< 表情图 URL（EmoticonCache 键）
        int     size = 1; ///< 1=小表情（1.15 倍行高） 2=大表情（1.8 倍行高）
        bool    failed = false;   ///< 下载失败/超时 → 占位符按普通文本渲染（降级）
    };
    struct LiveItem {
        QString text;
        QColor  color;
        int     type = 1;        ///< 1=滚动 4=底部 5=顶部
        qint64  startMs = 0;
        qint64  startNs = 0;     ///< = startMs×1e6（派生值）：位置计算用 ns 精度，
                                 ///< 起始时刻的 ms 量化只是一次性常量偏移，
                                 ///< 步长均匀性完全由逐帧的 m_nowNs 决定
        qreal   yPos = 0;
        qreal   pixelSpeed = 0;  ///< 滚动弹幕有效速度 px/ms
        qreal   baseSpeed = 0;   ///< speedScale=1 时的速度（调速反算用）
        qint64  durationMs = 0;  ///< 固定弹幕存活时长
        qreal   width = 0;       ///< 逻辑像素宽（实测）
        qreal   height = 0;      ///< 逻辑像素高（实测）
        qreal   fontScale = 1.0; ///< 单条字号缩放（B站 fontSize 字段）
        qreal   vCenterBase = 0; ///< 垂直居中基准高度（跨轨道 span 总高；0=用 trackHeight）
        QString emoticonUrl;     ///< 直播纯表情弹幕图 URL（空 = 文本/混排弹幕）
        int     emoticonSize = 1;///< 1=小表情 2=大表情（决定行内渲染高度）
        QVector<InlineEmo> inlineEmos;   ///< 文本+表情混排（空 = 非混排）
        int     slot = -1;       ///< 节点池槽位
        bool    textureReady = false;
    };

    /// 节点池槽位：变换节点(父) + 纹理节点(子)
    struct Slot {
        QSGTransformNode     *xform = nullptr;
        QSGSimpleTextureNode *texNode = nullptr;
        bool inUse = false;
    };

    int    acquireSlot();
    void   freeSlotDeferred(int slot);      ///< 槽位回收登记（在 updatePaintNode 内执行）
    void   evictOldest();                   ///< maxItems 上限淘汰最旧一条
    void   kickstart();                     ///< 踢一脚帧驱动链（首帧启动/断链恢复）
    void   ensureFrameConnection();         ///< 帧驱动连接自愈（窗口重建/设备丢失后恢复）
    qint64 presentationMs();                ///< 采样时刻外推到帧呈现时刻（vsync 相位对齐）；
                                             ///< 同时更新 m_nowNs（ns 精度同值，位置计算专用）
    qint64 currentNs() const;               ///< currentMs 的 ns 精度版本（同一时间轴）
    static QStringList fontFamilies();      ///< 弹幕字体回退链（外接字体优先，雅黑/黑体兜底）
    void   measure(const QString &text, qreal fontScale, qreal &outW, qreal &outH) const;
    QImage renderImage(const QString &text, const QColor &color, qreal dpr, qreal fontScale) const;
    /// 按当前描边样式在 (x, baseline) 绘制一段文本（renderImage/renderMixed 共用）。
    /// dpr：设备缩放倍率——描边/细边的偏移量按 dpr 缩放（1 逻辑像素 = dpr 物理
    /// 像素），保证不同缩放倍率的屏幕上描边逻辑粗细一致（1080P@100% 为基准）
    void   drawStyledText(QPainter &p, const QString &text, qreal x, qreal baseline,
                          const QFont &font, const QFontMetrics &fm,
                          const QColor &color, int extent, qreal dpr) const;
    /// 文本+表情混排：把文本按占位符切分为 文本段/表情段 序列
    struct MixedRun { bool isEmo = false; QString text; int emoIdx = -1; };
    QVector<MixedRun> splitMixedRuns(const QString &text, const QVector<InlineEmo> &emos) const;
    void   measureMixed(const QString &text, const QVector<InlineEmo> &emos,
                        qreal fontScale, qreal &outW, qreal &outH) const;
    QImage renderMixed(const QString &text, const QVector<InlineEmo> &emos,
                       const QColor &color, qreal dpr, qreal fontScale) const;
    /// 表情弹幕逻辑尺寸（图未就绪时按方形估算，宽上限 4 倍高防超宽图集）
    QSizeF emoticonLogicalSize(const QImage &src, qreal fontScale, int emoticonSize) const;
    QImage renderEmoticonImage(const QImage &src, qreal dpr, qreal fontScale, int emoticonSize) const;
    int    logicalFontSize() const { return qRound(m_baseFontSize * m_fontSizeScale); }
    int    outlineExtent(int fontSize) const;  ///< 当前描边样式的外扩像素（随样式三档变化）
    qreal  calcLineHeight() const;          ///< 当前字号档下单条弹幕渲染高度（含描边行距）
    void   refreshLineHeight();             ///< 字号变化后重算缓存并通知 QML
    void   markFontDirty();                 ///< 字号/DPR 变化 → 重建全部纹理

    // ---- 纹理图集（方案A：全部弹幕位图共存一张大纹理，合批为 1 个 draw call） ----
    /// 行分配器：在图集内分配 w×h 的矩形区域；失败返回空 QRect
    /// （行按高度精确匹配复用，行内空闲区间 first-fit，释放时相邻合并）
    QRect  atlasAlloc(int w, int h);
    void   atlasFree(const QRect &r);       ///< 归还区域（相邻区间合并）
    void   atlasReset();                    ///< 分配器整体作废（图集满/字号变化/窗口迁移）
    void   purgePendingUploads(AtlasSubTexture *sub);  ///< 删除子纹理前摘除其残留上传条目（防悬垂指针）
    /// 渲染线程消费（commitTextureOperations 触发，材质准备阶段）：
    /// 创建宿主 QRhiTexture（首次）+ 部分上传烘焙位图并入渲染器的
    /// resourceUpdate 批 + 回填子纹理宿主快照
    void   flushAtlasUploads(QRhi *rhi, QRhiResourceUpdateBatch *resourceUpdates);

    QList<LiveItem> m_live;
    QVector<Slot>   m_pool;
    QList<int>      m_pendingFreeSlots;
    QMetaObject::Connection m_frameConn;    ///< frameSwapped 连接（换窗口时断开）
    QPointer<QQuickWindow>  m_connWindow;   ///< 当前连接所属的窗口
    QMetaObject::Connection m_sgConn;       ///< sceneGraphInvalidated 连接
    QMetaObject::Connection m_swapConn;     ///< frameSwapped 呈现时刻记录连接（渲染线程直连）
    FILE *m_traceFile = nullptr;            ///< DANMAKU_TRACE 诊断输出

    // ---- 纹理图集状态 ----
    // 宿主大纹理：渲染线程创建/销毁（commitTextureOperations / sceneGraphInvalidated）；
    // GUI 线程仅在 itemChange（窗口迁移）时置空（此时子纹理快照仍持旧值，
    // 旧窗口最后一帧渲染安全，删除交旧窗口渲染线程 job）。原子量：
    // 写者跨线程，读者（flush 判空）在渲染线程
    std::atomic<QRhiTexture *> m_atlasTex{nullptr};
    QSize        m_atlasSize{2048, 2048};   ///< 物理像素；容量上限 ~200 条平均弹幕
    std::atomic<bool> m_atlasCreatePending{false};
    bool         m_atlasResetPending = false;  ///< 分配失败 → 下帧整图重排（compact）
    /// 行分配器状态（仅 GUI 线程同步点访问）
    struct AtlasRun { int x = 0, w = 0; };
    struct AtlasRow { int y = 0, h = 0; QList<AtlasRun> free; };
    QVector<AtlasRow> m_atlasRows;
    int m_atlasNextY = 0;                   ///< 下一个新行的 y
    /// 待上传队列：GUI 线程（同步点）生产，渲染线程（commitTextureOperations，
    /// 材质准备阶段）消费。携带目标子纹理指针：上传完成后由渲染线程回填
    /// 宿主纹理快照
    struct AtlasUpload { QImage img; QPoint dst; AtlasSubTexture *sub = nullptr; };
    QMutex m_uploadMutex;
    QList<AtlasUpload> m_pendingUploads;

    static constexpr int kAtlasPad = 2;     ///< 位图四周透明边（物理 px）：bilinear 防渗色

    // 单调时钟（暂停补偿）：采样点在 updatePaintNode（渲染同步阶段），
    // 与 GUI 线程事件调度抖动完全隔离
    QElapsedTimer m_clock;
    qint64        m_offsetMs = 0;
    qint64        m_frozenMs = 0;
    bool          m_paused = false;

    // 呈现时刻外推：渲染线程在 frameSwapped（DirectConnection）瞬间记录上一次
    // 帧呈现时刻。专用时钟只在构造时 start 一次、此后只读（nsecsElapsed），
    // 不会被 clear()/restart 触碰，因此跨线程只读是安全的
    QElapsedTimer          m_swapClock;
    std::atomic<qint64>    m_lastSwapNs{-1};

    // 稳定 vsync 网格（全部位于 m_swapClock 纳秒时间轴上）：网格点 = origin + n*period。
    // 历史教训（四代缺陷，勿回退）：
    //   1. 每帧重锚定到上次 frameSwapped：Present 返回不在 vsync 边界（翻转队列
    //      可提前返回，逐帧抖动 ±2ms），锚点噪声逐帧转化成位置微抖 + 跨周期
    //      量化跳变（60Hz"猛跳-冻结"式左右振动）；
    //   2. 整数毫秒时间戳：60Hz 真实周期 16.68ms 只能被估成 16 或 17ms，
    //      两种取值分别造成网格密 4%（周期性跳格双步长）与网格疏（冻结帧）；
    //   3. 用 Present 返回间隔的中位数估计周期：mpv 新帧回调与 frameSwapped 链
    //      造成"两帧相隔 1~2ms 连发 + ~32ms 空档"的突发提交节奏，中位数周期
    //      塌缩到 2 倍周期；且实测网格从未真正生效（trace 相邻帧认领差出现
    //      +1/+2ms，网格认领只可能是 0 或周期整数倍），位置按裸采样时刻计算，
    //      上屏步长"大-小-大-小"交替 = 30fps 频闪；
    //   4. 现行方案：Windows 上由 DwmGetCompositionTimingInfo 直接提供网格
    //      （qpcRefreshPeriod 精确周期 + qpcVBlank 相位，QElapsedTimer 与 QPC
    //      同源可映射到 m_swapClock 时间轴），不依赖 Present 返回；且每个提交
    //      帧强制认领下一个网格边界——连发的两帧各占相邻 vsync（翻转队列
    //      FIFO 保证各自上屏一次），上屏步长恒等于刷新周期。非 Windows 或
    //      DWM 不可用时回退到第 3 代的估计方式。
    //   - origin/period：DWM 路径 GUI 线程写（presentationMs 每帧查询）；
    //     回退路径渲染线程写（frameSwapped 校准）。均为原子量
    //   - m_swapIntervals：仅渲染线程访问（回退路径周期中位数估计的样本缓冲，ns）
    //   - m_lastTargetSwapNs：仅 GUI 线程访问（逐帧强制推进的认领游标）
    //   - m_lastSyncNs：仅 GUI 线程写（最近同步时刻，供渲染线程测渲染提前量）
    std::atomic<qint64>         m_vsyncOriginNs{0};
    std::atomic<qint64>         m_vsyncPeriodNs{0};
    QVarLengthArray<qint64, 32> m_swapIntervals;
    qint64                      m_lastTargetSwapNs = 0;
    std::atomic<qint64>         m_lastSyncNs{-1};
    std::atomic<qint64>         m_leadNs{0};   ///< 同步→Present 返回耗时 EMA（认领预留）

    qint64 m_now = 0;
    qint64 m_nowNs = 0;   ///< m_now 的 ns 精度版本（presentationMs 每帧更新）：
                          ///< 位置计算专用。ms 截断会让认领边界的 ns 精度退化为
                          ///< ±1ms 的逐帧步长噪声（三档步长/呼吸感的根源）
    bool   m_clearRequested = false;
    bool   m_fontDirty = false;
    qreal  m_lastDpr = 1.0;

    int   m_baseFontSize = 22;
    qreal m_fontSizeScale = 1.0;
    qreal m_lineHeight = 0;    ///< calcLineHeight() 缓存（字号变化时重算）
    qreal m_speedScale = 1.0;
    int   m_trackHeight = 32;
    bool  m_danmakuEnabled = true;
    int   m_maxItems = 80;
    int   m_outlineStyle = 0;  ///< 0=描边 1=重墨 2=45°投影（B站网页端三档）

    static constexpr int kMaxSlots = 400;   ///< 同屏弹幕硬上限
    static constexpr int kMaxActivationsPerFrame = 6;  ///< 单帧纹理激活预算（防高峰尖刺帧）
};

#endif // DANMAKUCANVAS_H
