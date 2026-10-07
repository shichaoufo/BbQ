#ifndef MPVOBJECT_H
#define MPVOBJECT_H

#include <QQuickFramebufferObject>
#include <QTimer>
#include <QVariantMap>
#include <QElapsedTimer>
#include <QMutex>
#include <QPointer>

#include <atomic>

struct mpv_handle;
struct mpv_render_context;

// MpvRenderer 在 .cpp 中定义（QQuickFramebufferObject::Renderer 的子类），
// 需要访问 m_videoReinitPending 以在渲染线程标记"渲染上下文已重建"
class MpvRenderer;

class MpvObject : public QQuickFramebufferObject
{
    Q_OBJECT
    Q_PROPERTY(QString source READ source WRITE setSource NOTIFY sourceChanged)
    Q_PROPERTY(QString audioSource READ audioSource WRITE setAudioSource NOTIFY audioSourceChanged)
    Q_PROPERTY(bool playing READ playing WRITE setPlaying NOTIFY playingChanged)
    Q_PROPERTY(int position READ position NOTIFY positionChanged)
    Q_PROPERTY(int duration READ duration NOTIFY durationChanged)
    Q_PROPERTY(qreal volume READ volume WRITE setVolume NOTIFY volumeChanged)
    Q_PROPERTY(qreal speed READ speed WRITE setSpeed NOTIFY speedChanged)
    Q_PROPERTY(bool hasVideo READ hasVideo NOTIFY hasVideoChanged)
    Q_PROPERTY(bool seekable READ seekable NOTIFY seekableChanged)
    // 直播模式开关：true=直播（小cache 低延迟），false=视频点播（大cache 抗抖动）
    // 与 MpvObjectD3D11 保持同一语义，QML 侧（LivePlayerPage）无平台分支地
    // 直接写 liveMode: true。必须在 setSource 之前设置才生效。
    Q_PROPERTY(bool liveMode READ liveMode WRITE setLiveMode NOTIFY liveModeChanged)

public:
    explicit MpvObject(QQuickItem *parent = nullptr);
    ~MpvObject();

    QString source() const;
    void setSource(const QString &source);

    QString audioSource() const;
    void setAudioSource(const QString &audioSource);

    bool playing() const;
    void setPlaying(bool playing);

    int position() const;
    int duration() const;

    qreal volume() const;
    void setVolume(qreal volume);

    qreal speed() const;
    void setSpeed(qreal speed);

    bool hasVideo() const;
    bool seekable() const;

    bool liveMode() const;
    void setLiveMode(bool liveMode);

    Q_INVOKABLE void play();
    Q_INVOKABLE void pause();
    Q_INVOKABLE void stop();
    Q_INVOKABLE void seek(int position);
    Q_INVOKABLE void updatePosition();
    // 获取实际播放的视频参数（宽、高、codec、fps、bitrate 等），用于验证当前流的真实画质
    Q_INVOKABLE QVariantMap getVideoInfo();

    Renderer *createRenderer() const override;

    mpv_handle *mpv() const { return m_mpv; }

signals:
    void sourceChanged();
    void audioSourceChanged();
    void playingChanged();
    void durationChanged();
    void positionChanged();
    void volumeChanged();
    void speedChanged();
    void hasVideoChanged();
    void seekableChanged();
    void liveModeChanged();
    // 文件加载完成（mpv MPV_EVENT_FILE_LOADED）：此时首帧已解码完成，
    // 画面已出。QML 侧用它重置播放级重试状态、启动弹幕 1s 延迟计时、
    // 触发空降助手片段查询（见 VideoPlayerPage.qml onFileLoaded）。
    // 该信号在 Linux 版曾缺失，导致 QML 组件链加载失败（首页白屏）。
    void fileLoaded();
    void errorOccurred(const QString &error);
    // 直播流自然结束（EOF）：主播推流中断/断流。仅 liveMode 下发出，
    // QML 层据此触发自动重连（视频点播的 EOF 无此语义）
    void liveStreamEof();
    // 渲染上下文重建后视频链 verify 存活时发出：QML 层据此恢复播放。
    // Linux 路径语义与 Windows 一致，只是触发点不同（见 .cpp 注释）
    void videoChainRestored();

protected:
    void geometryChange(const QRectF &newGeometry, const QRectF &oldGeometry) override;
    void itemChange(ItemChange change, const ItemChangeData &value) override;

private slots:
    void onMpvEvents();

private:
    void initMpv();
    // mpv 渲染资源（render context + core）的释放**全部集中在 ~MpvObject**
    // 内、GUI 线程、严格按"先 free context 后 terminate core"顺序执行。
    // 依据与顺序保证说明见 MpvObject.cpp 中 ~MpvObject 的长注释。
    void applyHttpHeaders();
    void loadFile(const QString &file);
    void startRenderTimer();
    void stopRenderTimer();
    // 根据 m_liveMode 应用 cache 配置：直播=小cache 低延迟，视频=大cache 抗抖动。
    // 与 D3D11 版同名同语义，但**不设置 vf**（D3D11 版的 vf=amf_frc 是
    // AMD 硬件帧率转换，Linux 走 Mesa/VAAPI 无对应滤镜，设了会报 filter 失败）
    void applyCacheOptions();

    // ============ 关于"重选视频轨"机制的真实状态（重要，别被误导）============
    // 【修正此前注释里的错误前提】
    // 旧注释写"QQuickFramebufferObject 在窗口变化/尺寸变化时会销毁并重建
    // Renderer"——这是**错的**。Qt 源码注释明说 renderer "only goes away
    // when the scenegraph is invalidated or it is removed from the scene"：
    // 尺寸变化只重建 FBO、**复用同一个 renderer**，并不会触发下面的机制。
    //
    // 【现状：保留，但触发条件已改变】
    // 唯一还会置位 m_renderContextFreed 的地方是 ~MpvObject 里的
    // mpv_render_context_free() —— 而那之后紧接着就是 mpv_terminate_destroy()，
    // core 已死。所以正常"页面切换 / 窗口关闭"路径上，verifyVideoChainAlive()
    // 会在 `if (!m_mpv) return;` 处直接退出，什么也不做。
    //
    // 为什么仍然保留而不是删掉：
    //   FBO 失效/窗口重建时 Qt 会**重建 renderer 与 context，而 core 仍存活**
    //   ——那种场景下 mpv 不会自动把 VO 重新挂到新 context 上
    //   （mpv 源码 vo_libmpv.c 的 render_context_create() 无 reinit 逻辑），
    //   不重选视频轨就是黑屏。这条兜底正是为它准备的。
    //   删掉等于放弃这条已验证必要的兜底，将来有人遇到"重建后黑屏"会很难查。
    // 若要清理，应连同"FBO 重建后黑屏"一并验证后再删，单独删不安全。
    //
    // 原理仍然正确（见上），只是缺少一个"core 仍存活就重建"的真机实测
    // 场景来证明它工作——这一点尚未验证，不要当成已确认有效。
    void reinitVideoChain();
    // 延迟校验重建后视频链是否存活（video-params），死链则重试重选。
    // 【当前基本不生效】见上：收尾路径下 m_mpv 已空，会立即返回。
    void verifyVideoChainAlive(int attempts);

    mpv_handle *m_mpv = nullptr;

    QString m_source;
    QString m_audioSource;
    bool m_playing = false;
    bool m_desiredPlaying = true;  // 加载新文件后是否自动播放
    int m_position = 0;
    // positionChanged 信号节流：time-pos 以视频帧率上报（30fps 视频即
    // 30 次/秒），每次 emit 都驱动 QML 进度条绑定更新 → 整窗合成。
    // pacer tick 与 mpv 事件到达相位错开时各自触发独立呈现（关弹幕
    // 60fps 而非 30fps 的根因）。QML 消费端 200ms 粒度足够。
    // 与 MpvObjectD3D11 同名同语义，Linux 侧此前缺失。
    QElapsedTimer m_posThrottleClock;
    qint64 m_lastPosEmitMs = -1;
    int m_duration = 0;
    qreal m_volume = 1.0;
    qreal m_speed = 1.0;
    bool m_hasVideo = false;
    bool m_seekable = false;
    bool m_paused = true;
    bool m_liveMode = false;  // 默认视频点播模式（大cache 抗网络抖动）

    // mpv 初始化是否已完成：cache-secs 等属于启动期选项，initialize 前只能用
    // mpv_set_option_string，initialize 后必须改用 mpv_set_property_string。
    // 记录这个状态才能让 setLiveMode 在"QML 绑定晚于构造"时也真正生效。
    bool m_mpvInitialized = false;

    // 用 QPointer 而非裸指针（与 MpvObjectD3D11.h:152 一致）：析构时需要
    // 判断"窗口是否还活着"来决定清理走投job 还是同步做，而裸指针在窗口
    // 先于本对象销毁时会是悬垂指针，isNull() 判断本身就会崩。
    // QPointer 在 QQuickWindow 被销毁时自动置空，可安全查询。
    QPointer<QQuickWindow> m_window;
    QTimer *m_renderTimer = nullptr;

    // ==================================================================
    // GUI 线程（析构）与渲染线程（createFramebufferObject/render）之间的
    // 同步。与 MpvObjectD3D11.h:184-189 完全同名同语义。
    //
    // m_renderMutex 保护 mpv_render_context_render / mpv_render_context_free
    //   不并发：析构函数用它做**栅栏**——拿一次锁即证明"渲染线程已不在
    //   临界区里"，随后立刻释放（不是持锁做清理，见 ~MpvObject）。
    // m_shuttingDown 让渲染入口在收尾期间提前 return，避免新的渲染进入。
    //
    // 为什么 Linux 版必须有这个、以及此处踩过的坑，见 MpvObject.cpp
    // 文件顶部的「渲染线程收尾方案的历史教训」注释块。
    // ==================================================================
    QMutex m_renderMutex;
    std::atomic<bool> m_shuttingDown{false};

    // "渲染上下文已被重建、需要重选视频轨"的标记。由 MpvRenderer 置位，
    // 下一次渲染定时器在 GUI 线程消费。渲染线程→GUI 线程，用 atomic 同步。
    std::atomic<bool> m_videoReinitPending{false};

    // renderer 与本对象之间的跨线程握手槽。
    // MpvRenderer 只持有**本成员的地址**，每帧重新 load，不缓存对象指针。
    // 为什么不用裸指针：Qt 的销毁顺序是 ~QQuickItem（GUI 线程，仅标记
    // 节点）→ 渲染线程 cleanup 才 delete renderer，故 ~MpvRenderer 可能
    // 晚于本析构，且解引用已析构对象是 UAF；更糟的是该地址可能已被
    // **另一个 MpvObject 实例**复用，render() 会读到别人的 mpv context。
    // 为什么不用 QPointer：它**没有任何线程安全声明**，跨线程读写本身
    // 就不是合法用法（这也是本项目上一版方案被否的原因之一）。
    std::atomic<MpvObject *> m_rendererItem{this};

    // mpv render context 指针：渲染线程 create，GUI 线程
    // 在 ~MpvObject 里经由"渲染栅栏"确认渲染线程已退出后 free
    // （顺序保证见 ~MpvObject 的注释）。
    // 原本该指针是 MpvRenderer 的成员，导致"谁创建谁销毁"被跨线程打破；
    // 现上移到 MpvObject，由 ~MpvObject 在拿到渲染栅栏后统一 free。
    // 用 atomic 是因为 createFramebufferObject（渲染线程）写、
    // ~MpvObject（GUI 线程）读+清。
    std::atomic<mpv_render_context *> m_mpvRender{nullptr};

    // "曾经 free 掉过一个已建立的 mpv render context"标记。在
    // releaseMpvRenderContext（渲染线程）置位，下一次 create 成功后清掉。
    // 为什么需要它：mpv_render_context_free() 内部 kill_video_async 会销毁
    // VO+解码链，而 mpv_render_context_create() 不会自动重新挂接
    // （vo_libmpv.c 无 reinit 逻辑）。但**首次创建**时根本不存在旧链，
    // 此时若也去重选视频轨，只会在起播瞬间下发一次无端的 vid no→auto，
    // 造成首帧闪黑与起播延迟。只有"确实 free 过旧链"才需要重建。
    std::atomic<bool> m_renderContextFreed{false};

    // mpv core 是否已终止。teardown 幂等守卫，防止析构与渲染线程回调
    // 两条路径重复 terminate。
    std::atomic<bool> m_mpvTerminated{false};

    // MpvRenderer 在 .cpp 中定义，需要置位上面的跨线程标记
    friend class MpvRenderer;
};

#endif // MPVOBJECT_H
