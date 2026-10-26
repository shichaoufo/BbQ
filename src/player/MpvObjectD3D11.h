#ifndef MPVOBJECTD3D11_H
#define MPVOBJECTD3D11_H

#include <QQuickItem>
#include <QTimer>
#include <QVariant>
#include <QMutex>
#include <QRunnable>
#include <QPointer>
#include <QList>
#include <QElapsedTimer>

#include <atomic>

#include <private/qrhi_p.h>

struct mpv_handle;
struct mpv_render_context;

struct ID3D11Device;
struct ID3D11Texture2D;

QT_BEGIN_NAMESPACE
class QSGTexture;
class QQuickWindow;
QT_END_NAMESPACE

class MpvObjectD3D11 : public QQuickItem
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
    // 直播模式开关：true=直播（小cache低延迟），false=视频点播（大cache抗抖动）
    // 必须在 setSource 之前设置才生效（mpv 选项在 loadfile 前应用）
    Q_PROPERTY(bool liveMode READ liveMode WRITE setLiveMode NOTIFY liveModeChanged)

public:
    explicit MpvObjectD3D11(QQuickItem *parent = nullptr);
    ~MpvObjectD3D11();

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
    Q_INVOKABLE QVariantMap getVideoInfo();

    // 已渲染帧计数（单调递增）。
    // 给 QML 的"音频在走、画面卡住"看门狗用：只在 renderMpv() 里 +1，
    // 所以"数值不变"就等于"确实没有新画面输出"（暂停/正常播放都会变，
    // 卡在最后一帧则不变）。与 position 是否前进联合判断即可定位卡顿。
    Q_INVOKABLE qint64 renderedFrameCount() const;

    // ===== 字幕（外挂字幕轨）=====
    // 与 MpvObject 同签名同语义。B站字幕是独立的 bcc JSON 文件
    // （player/wbi/v2 响应 data.subtitle.subtitles[].subtitle_url），
    // mpv 不认这个格式，所以本方法负责下载 → 转 SRT → 落临时文件 →
    // sub-add，由 libmpv 原生渲染。详见 MpvObject.cpp 中同名方法的长注释。
    //
    // **两个实现类必须同步维护这两个方法**：Windows 用本类（D3D11），
    // Linux/macOS 用 MpvObject，QML 侧不做平台分支直接调用。
    // 曾因只改 MpvObject 导致 Windows 上点击字幕轨报
    // "Property 'addSubtitleTrack' ... is not a function"
    Q_INVOKABLE void addSubtitleTrack(const QString &url, const QString &title = QString());
    Q_INVOKABLE void setSubtitleVisible(bool visible);

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
    void fileLoaded();
    void errorOccurred(const QString &error);
    // 直播流自然结束（EOF）：主播推流中断/断流。仅 liveMode 下发出，
    // QML 层据此触发自动重连（视频点播的 EOF 无此语义）
    void liveStreamEof();
    // 跨窗口迁移后视频链 verify 存活时发出：QML 层据此恢复播放
    // （迁移期间整体暂停以避免音画错位，见 LivePlayerPage/VideoPlayerPage）
    void videoChainRestored();

protected:
    void geometryChange(const QRectF &newGeometry, const QRectF &oldGeometry) override;
    void itemChange(ItemChange change, const ItemChangeData &value) override;
    QSGNode *updatePaintNode(QSGNode *oldNode, UpdatePaintNodeData *data) override;

private slots:
    void onMpvEvents();

private:
    void initMpv();
    void destroyMpv();
    void applyHttpHeaders();
    void loadFile(const QString &file);
    void startRenderTimer();
    void stopRenderTimer();
    // 秒 → SRT 时间码 "HH:MM:SS,mmm"（bcc JSON 转 SRT 用）
    QString subtitleSrtTimestamp(double seconds) const;
    // 根据 m_liveMode 应用 cache 配置：直播=小cache低延迟，视频=大cache抗抖动
    void applyCacheOptions();

    bool ensureD3D11Resources();
    void releaseD3D11Resources();
    void renderMpv();
    void updateQSGTexture();
    // 跨窗口迁移后重选视频轨（vid no→auto）强制 mpv 重建视频链：
    // mpv_render_context_free 内部 kill_video_async 已销毁 VO+解码链，
    // 而 mpv_render_context_create 不会自动重新挂接（vo_libmpv.c 无 reinit 逻辑）
    void reinitVideoChain();
    // 延迟校验迁移后视频链是否存活（video-params），死链则重试重选：
    // kill_video_async 异步于核心线程执行，若其完成时机晚于首次重选，
    // 重建的视频链会被迟到的销毁再次杀死→黑屏
    void verifyVideoChainAlive(int attempts);

    mpv_handle *m_mpv = nullptr;
    mpv_render_context *m_mpvRender = nullptr;

    QString m_source;
    QString m_audioSource;
    bool m_playing = false;
    bool m_desiredPlaying = true;  // 加载新文件后是否自动播放
    int m_position = 0;
    // positionChanged 信号节流：time-pos 以视频帧率上报（30fps 视频即
    // 30 次/秒），每次 emit 都驱动 QML 进度条绑定更新 → 整窗合成。
    // pacer tick 与 mpv 事件到达相位错开时各自触发独立呈现（关弹幕
    // 60fps 而非 30fps 的根因）。QML 消费端 200ms 粒度足够
    QElapsedTimer m_posThrottleClock;
    qint64 m_lastPosEmitMs = -1;
    int m_duration = 0;
    qreal m_volume = 1.0;
    qreal m_speed = 1.0;
    bool m_hasVideo = false;
    bool m_seekable = false;
    bool m_paused = true;
    bool m_liveMode = false;  // 默认视频点播模式（大cache抗网络抖动）

    QPointer<QQuickWindow> m_window;
    QTimer *m_renderTimer = nullptr;

    // D3D11 resources, owned and used on the Qt render thread.
    ID3D11Device *m_d3d11Device = nullptr;
    ID3D11Texture2D *m_d3d11Texture = nullptr;
    QSGTexture *m_qsgTexture = nullptr;
    QRhiTexture *m_qrhiTexture = nullptr;
    QSize m_textureSize;
    bool m_resourcesDirty = true;

    // Video native resolution from mpv "video-params". D3D11 texture is created
    // at a size close to window display size to avoid GPU upscaling.
    // Atomic because it is written from GUI thread (mpv event handler) and read
    // from the Qt render thread (updatePaintNode / ensureD3D11Resources).
    std::atomic<int> m_videoWidth{0};
    std::atomic<int> m_videoHeight{0};

    // 渲染线程累加、GUI 线程读取的"真的画出去多少帧"计数。
    // 用于 QML 侧的画面卡死看门狗（见 renderedFrameCount()）。
    std::atomic<qint64> m_renderedFrames{0};

    // Stale textures from previous resizes. They are intentionally kept alive
    // until destruction to avoid releasing GPU resources while the D3D11
    // driver/Qt scene graph may still reference them.
    struct StaleTextureSet {
        QSGTexture *qsgTex = nullptr;
        QRhiTexture *qrhiTex = nullptr;
        ID3D11Texture2D *d3d11Tex = nullptr;
    };
    QList<StaleTextureSet> m_staleTextures;

    // Set by mpv's update callback when a new video frame is available.
    // updatePaintNode renders mpv only when this flag is true, while the
    // 60fps timer still drives QSG updates for danmaku animation.
    std::atomic<bool> m_framePending{false};

    // Synchronization between GUI thread (destructor) and render thread (updatePaintNode).
    // m_renderMutex protects renderMpv/mpv_render_context_render from concurrent free.
    // m_shuttingDown makes updatePaintNode return early during shutdown.
    QMutex m_renderMutex;
    std::atomic<bool> m_shuttingDown{false};

    // itemChange 已把全部资源（QSG/stale 纹理 + mpv + D3D11 纹理/device）
    // 移交给渲染线程 job 释放时置 true。析构函数据此跳过 direct release，
    // 消除"GUI 线程先销毁 device、渲染线程延后释放 interop 纹理"的跨线程
    // 释放顺序竞态（窗口失焦导致 job 积压时，切回窗口会触发驱动级死锁）。
    bool m_fullCleanupScheduled = false;

    // 跨窗口迁移（小窗播放）释放过 mpv 渲染上下文后置 true：
    // mpv_render_context_free 内部 kill_video_async 会销毁 VO+解码链，而
    // mpv_render_context_create 不会自动重新挂接视频链（mpv 源码 vo_libmpv.c
    // 的 create 无任何 reinit 逻辑）。新窗口 ensureD3D11Resources 重建上下文
    // 成功后消费该标记，在 GUI 线程重选视频轨道（vid no→auto）强制
    // reinit_video_chain 恢复画面，否则小窗内永久黑屏（音频继续播放）。
    bool m_videoReinitPending = false;
};

#endif // MPVOBJECTD3D11_H
