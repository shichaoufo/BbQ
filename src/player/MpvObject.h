#ifndef MPVOBJECT_H
#define MPVOBJECT_H

#include <QQuickFramebufferObject>
#include <QTimer>
#include <QVariantMap>

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
    void destroyMpv();
    void applyHttpHeaders();
    void loadFile(const QString &file);
    void startRenderTimer();
    void stopRenderTimer();
    // 根据 m_liveMode 应用 cache 配置：直播=小cache 低延迟，视频=大cache 抗抖动。
    // 与 D3D11 版同名同语义，但**不设置 vf**（D3D11 版的 vf=amf_frc 是
    // AMD 硬件帧率转换，Linux 走 Mesa/VAAPI 无对应滤镜，设了会报 filter 失败）
    void applyCacheOptions();

    // ---- 渲染上下文重建后的视频链恢复 ----
    // QQuickFramebufferObject 在窗口变化/尺寸变化时会销毁并重建 Renderer，
    // 而 Renderer 析构里调用的 mpv_render_context_free() 内部
    // kill_video_async 会销毁 VO+解码链；mpv_render_context_create()
    // 不会自动重新挂接（mpv 源码 vo_libmpv.c 的 create 无 reinit 逻辑），
    // 结果是新窗口内永久黑屏（音频继续播）。
    // 与 D3D11 版完全同一个根因，只是 Linux 无 D3D11 互操作纹理需要处理。
    // 修法同样只用 mpv 通用 API：vid no→auto 重选视频轨强制重建视频链。
    void reinitVideoChain();
    // 延迟校验重建后视频链是否存活（video-params），死链则重试重选：
    // kill_video_async 异步于核心线程执行，若其完成时机晚于首次重选，
    // 重建的视频链会被迟到的销毁再次杀死 → 黑屏
    void verifyVideoChainAlive(int attempts);

    mpv_handle *m_mpv = nullptr;
    mutable bool m_rendererWillDestroyMpv = false;

    QString m_source;
    QString m_audioSource;
    bool m_playing = false;
    bool m_desiredPlaying = true;  // 加载新文件后是否自动播放
    int m_position = 0;
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

    QQuickWindow *m_window = nullptr;
    QTimer *m_renderTimer = nullptr;

    // "渲染上下文需要重选视频轨"的标记。由 MpvRenderer 置位，
    // 下一次渲染定时器在 GUI 线程消费。渲染线程→GUI 线程，用 atomic 同步。
    std::atomic<bool> m_videoReinitPending{false};

    // "曾经 free 掉过一个已建立的 mpv render context"标记。在 ~MpvRenderer
    // 里 mpv_render_context_free() 真正发生时置位，在下一次 create 成功后
    // 被 exchange 清掉。
    // 为什么需要它：mpv_render_context_free() 内部 kill_video_async 会销毁
    // VO+解码链，而 mpv_render_context_create() 不会自动重新挂接
    // （vo_libmpv.c 无 reinit 逻辑）。但**首次创建**时根本不存在旧链，
    // 此时若也去重选视频轨，只会在起播瞬间下发一次无端的 vid no→auto，
    // 造成首帧闪黑与起播延迟。只有"确实 free 过旧链"才需要重建。
    std::atomic<bool> m_renderContextFreed{false};

    // MpvRenderer 在 .cpp 中定义，需要置位上面的跨线程标记
    friend class MpvRenderer;
};

#endif // MPVOBJECT_H
