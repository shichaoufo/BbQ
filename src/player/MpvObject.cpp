#include "MpvObject.h"

#include "LoginManager.h"
#include <QDebug>
#include <QQuickWindow>
#include <QOpenGLContext>
#include <QOpenGLFramebufferObject>
#include <QOpenGLFunctions>
#include <QVariantMap>

extern "C" {
#include <mpv/client.h>
#include <mpv/render_gl.h>
}

static const QString MPV_USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
static const QString MPV_REFERER = "https://www.bilibili.com";
static const QString MPV_ORIGIN = "https://www.bilibili.com";

class MpvRenderer : public QQuickFramebufferObject::Renderer
{
public:
    explicit MpvRenderer(MpvObject *item, mpv_handle *mpv)
        : m_item(item)
        , m_mpv(mpv)
    {
    }

    ~MpvRenderer()
    {
        // 必须先释放 mpv render context，再终止 mpv 实例；
        // 否则 mpv_terminate_destroy 会等待/与仍在使用的渲染上下文冲突，
        // 导致主线程或渲染线程卡死/崩溃。
        if (m_mpvRender) {
            mpv_render_context_free(m_mpvRender);
            m_mpvRender = nullptr;
        }

        if (m_mpv) {
            mpv_terminate_destroy(m_mpv);
            m_mpv = nullptr;
        }
    }

    void render() override
    {
        if (!m_mpvRender) return;

        QOpenGLFramebufferObject *fbo = framebufferObject();
        if (!fbo) return;

        QOpenGLContext *ctx = QOpenGLContext::currentContext();
        if (!ctx) return;
        QOpenGLFunctions *f = ctx->functions();

        GLint oldViewport[4];
        f->glGetIntegerv(GL_VIEWPORT, oldViewport);

        mpv_opengl_fbo mpvFbo;
        mpvFbo.fbo = static_cast<int>(fbo->handle());
        mpvFbo.w = fbo->width();
        mpvFbo.h = fbo->height();
        mpvFbo.internal_format = 0;

        mpv_render_param params[] = {
            {MPV_RENDER_PARAM_OPENGL_FBO, &mpvFbo},
            {MPV_RENDER_PARAM_INVALID, nullptr}
        };

        mpv_render_context_render(m_mpvRender, params);

        // 注意：MPV_RENDER_PARAM_ADVANCED_CONTROL 要求 report_swap 在画面真正被 swap 到屏幕后调用。
        // 但 QQuickFramebufferObject::render() 只是渲染到 FBO，真正的窗口 swap 由 Qt 在更晚阶段完成，
        // 我们难以在正确的时机调用 report_swap。若在此处提前调用，mpv 的帧节奏控制会出错，
        // 导致打开视频时卡死/崩溃。因此不使用 advanced control，也不调用 report_swap。

        f->glViewport(oldViewport[0], oldViewport[1], oldViewport[2], oldViewport[3]);

        // 不在此处调用 update() 持续驱动 QSG 渲染。
        // 否则 QSG 渲染频率会被锁定在 mpv 视频帧率（通常 30fps），
        // 导致 Qt 场景图动画驱动器从 vsync(60fps) 切换到 timer mode(30fps)，
        // 进而让弹幕的 NumberAnimation 也降至 30fps。
        //
        // 渲染节奏改由以下方式共同维持 60fps：
        //   1) MpvObject 的 16ms QTimer：强制 QSG 以 60fps 调度 MpvObject 渲染。
        //   2) DanmakuOverlay.qml 中的 _renderDriver NumberAnimation：持续运行，
        //      使 QSG 动画驱动器尽量保持在 vsync mode。
        //   3) MpvObject::itemChange 中连接窗口的 frameSwapped 信号到 update()，
        //      在 QSG 每次成功 swap 后立即请求下一帧，形成稳定的 60fps 渲染闭环。
        // mpv item 的 render() 会随 QSG 的 60fps 帧率被调用，mpv 内部自动跳过重复帧，
        // 视频画面仍按视频帧率更新，而弹幕则按 60fps 滚动。
    }

    QOpenGLFramebufferObject *createFramebufferObject(const QSize &size) override
    {
        QOpenGLFramebufferObjectFormat format;
        // 视频渲染不需要深度/模板缓冲，去掉可减少显存占用和带宽
        format.setAttachment(QOpenGLFramebufferObject::NoAttachment);
        format.setInternalTextureFormat(GL_RGBA8);
        format.setMipmap(false);

        QOpenGLFramebufferObject *fbo = new QOpenGLFramebufferObject(size, format);

        if (!m_mpvRender) {
            QOpenGLContext *glCtx = QOpenGLContext::currentContext();
            if (!glCtx) {
                qWarning() << "[MpvRenderer] no current OpenGL context";
                return fbo;
            }

            mpv_opengl_init_params glInitParams;
            glInitParams.get_proc_address = [](void *ctx, const char *name) -> void* {
                QOpenGLContext *glctx = static_cast<QOpenGLContext*>(ctx);
                return reinterpret_cast<void*>(glctx->getProcAddress(QByteArray(name)));
            };
            glInitParams.get_proc_address_ctx = glCtx;

            // 不使用 MPV_RENDER_PARAM_ADVANCED_CONTROL：
            // QQuickFramebufferObject::render() 只渲染到 FBO，真正的 swap 由 Qt 完成，
            // 无法保证 mpv_render_context_report_swap() 在正确时机调用，
            // 错误使用会导致视频打开时卡死/崩溃。
            mpv_render_param params[] = {
                {MPV_RENDER_PARAM_API_TYPE, const_cast<char*>(MPV_RENDER_API_TYPE_OPENGL)},
                {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &glInitParams},
                {MPV_RENDER_PARAM_INVALID, nullptr}
            };

            int rc = mpv_render_context_create(&m_mpvRender, m_mpv, params);
            if (rc < 0) {
                qWarning() << "[MpvRenderer] failed to create mpv OpenGL render context, error:" << rc << mpv_error_string(rc);
            } else {
                qDebug() << "[MpvRenderer] mpv OpenGL render context created";
                mpv_render_context_set_update_callback(m_mpvRender, [](void *ctx) {
                    MpvRenderer *renderer = static_cast<MpvRenderer*>(ctx);
                    renderer->onUpdate();
                }, this);
            }
        }

        return fbo;
    }

    void synchronize(QQuickFramebufferObject *item) override
    {
        // 可在此同步主线程状态到渲染线程，当前无需额外同步
        Q_UNUSED(item)
    }

    void onUpdate()
    {
        // 不调用 QQuickItem::update()。
        // mpv update callback 频率 = 视频/直播流出帧率，与 vsync(60fps) 不一致，
        // 会干扰 QSG 动画驱动器，导致其切换到 timer mode(~30fps)。
        //
        // QSG 的渲染节奏由 MpvObject 的 16ms QTimer、DanmakuOverlay._renderDriver
        // NumberAnimation 与 frameSwapped->update() 共同维持，
        // 使 QSG 尽量保持在 60fps。
        // mpv item 的 render() 会随 QSG 的 60fps 帧率被调用，画面正常更新。
    }

private:
    MpvObject *m_item = nullptr;
    mpv_handle *m_mpv = nullptr;
    mpv_render_context *m_mpvRender = nullptr;
};

MpvObject::MpvObject(QQuickItem *parent)
    : QQuickFramebufferObject(parent)
{
    initMpv();

    // 16ms 渲染定时器：强制 QSG 以 60fps 节奏调度 MpvObject 渲染。
    // 与 DanmakuOverlay 的 NumberAnimation、frameSwapped->update() 共同作用，
    // 避免视频/直播帧率把 QSG 拖入低帧率 timer mode。
    m_renderTimer = new QTimer(this);
    m_renderTimer->setInterval(16);
    m_renderTimer->setTimerType(Qt::PreciseTimer);
    connect(m_renderTimer, &QTimer::timeout, this, [this]() { update(); });
}

MpvObject::~MpvObject()
{
    stopRenderTimer();

    // 断开窗口信号，防止销毁过程中 frameSwapped 触发 update()
    if (m_window) {
        disconnect(m_window, &QQuickWindow::frameSwapped, this, &MpvObject::update);
        m_window = nullptr;
    }

    if (m_mpv) {
        // 禁用 mpv 唤醒回调，避免其排队调用到正在销毁的对象
        mpv_set_wakeup_callback(m_mpv, nullptr, nullptr);

        // 若已创建 Renderer，则把 mpv 生命周期交给 Renderer 析构处理；
        // Renderer 会先释放 render context 再 terminate_destroy，顺序正确。
        if (!m_rendererWillDestroyMpv) {
            destroyMpv();
        }
        m_mpv = nullptr;
    }
}

void MpvObject::initMpv()
{
    m_mpv = mpv_create();
    if (!m_mpv) {
        qWarning() << "[MpvObject] failed to create mpv context";
        emit errorOccurred("Failed to create mpv context");
        return;
    }

    mpv_set_option_string(m_mpv, "vo", "libmpv");
    // 开启 mpv 内部日志，便于排查播放失败、解码、渲染问题
    {
        QString mpvLogPath = QCoreApplication::applicationDirPath() + "/mpv.log";
        mpv_set_option_string(m_mpv, "log-file", mpvLogPath.toUtf8().constData());
        mpv_set_option_string(m_mpv, "msg-level", "all=debug");
    }
    // Windows 上明确指定 d3d11va（非 copy），避免 auto 落到 d3d11va-copy 产生 GPU->CPU->GPU 拷贝
#ifdef Q_OS_WIN
    mpv_set_option_string(m_mpv, "hwdec", "d3d11va");
#else
    mpv_set_option_string(m_mpv, "hwdec", "auto-safe");
#endif
    mpv_set_option_string(m_mpv, "keep-open", "yes");
    mpv_set_option_string(m_mpv, "force-window", "no");
    mpv_set_option_string(m_mpv, "input-default-bindings", "no");
    mpv_set_option_string(m_mpv, "input-vo-keyboard", "no");
    mpv_set_option_string(m_mpv, "ytdl", "no");
    // 与 wiliwili 保持一致，降低视频帧率对弹幕/渲染节奏的干扰
    mpv_set_option_string(m_mpv, "video-timing-offset", "0");
    // 明确告诉 mpv 显示器刷新率为 60fps，避免它按视频帧率自行降速
    mpv_set_option_string(m_mpv, "display-fps", "60");
    mpv_set_option_string(m_mpv, "override-display-fps", "60");
    // 限制 mpv 缓冲大小，降低内存占用（对 1080P 足够，4K 可适当放大）
    mpv_set_option_string(m_mpv, "cache-secs", "15");
    mpv_set_option_string(m_mpv, "demuxer-max-bytes", "50M");
    mpv_set_option_string(m_mpv, "demuxer-max-back-bytes", "25M");
    mpv_set_option_string(m_mpv, "demuxer-readahead-secs", "15");
    // 使用 mpv fast profile，降低缩放/后处理开销；对 bilibili 视频画质影响很小
    mpv_set_option_string(m_mpv, "profile", "fast");
    // 明确关闭高成本缩放与后处理选项（fast profile 通常已包含，显式设置更保险）
    mpv_set_option_string(m_mpv, "scale", "bilinear");
    mpv_set_option_string(m_mpv, "dscale", "bilinear");
    mpv_set_option_string(m_mpv, "dither", "no");
    mpv_set_option_string(m_mpv, "correct-downscaling", "no");
    mpv_set_option_string(m_mpv, "linear-downscaling", "no");
    mpv_set_option_string(m_mpv, "sigmoid-upscaling", "no");
    mpv_set_option_string(m_mpv, "hdr-compute-peak", "no");
    // 解码端也开启快速路径
    mpv_set_option_string(m_mpv, "vd-lavc-fast", "yes");
    mpv_set_option_string(m_mpv, "vd-lavc-skiploopfilter", "all");

    if (mpv_initialize(m_mpv) < 0) {
        qWarning() << "[MpvObject] failed to initialize mpv";
        emit errorOccurred("Failed to initialize mpv");
        mpv_terminate_destroy(m_mpv);
        m_mpv = nullptr;
        return;
    }

    applyHttpHeaders();

    mpv_set_wakeup_callback(m_mpv, [](void *ctx) {
        QMetaObject::invokeMethod(static_cast<MpvObject*>(ctx), &MpvObject::onMpvEvents, Qt::QueuedConnection);
    }, this);

    mpv_observe_property(m_mpv, 0, "time-pos", MPV_FORMAT_DOUBLE);
    mpv_observe_property(m_mpv, 0, "duration", MPV_FORMAT_DOUBLE);
    mpv_observe_property(m_mpv, 0, "pause", MPV_FORMAT_FLAG);
    mpv_observe_property(m_mpv, 0, "speed", MPV_FORMAT_DOUBLE);
    mpv_observe_property(m_mpv, 0, "video-params", MPV_FORMAT_NODE);
    mpv_observe_property(m_mpv, 0, "seekable", MPV_FORMAT_FLAG);
    mpv_observe_property(m_mpv, 0, "hwdec-current", MPV_FORMAT_STRING);

    double vol = 100.0;
    mpv_set_property(m_mpv, "volume", MPV_FORMAT_DOUBLE, &vol);
    int pauseFlag = 1;
    mpv_set_property(m_mpv, "pause", MPV_FORMAT_FLAG, &pauseFlag);
}

void MpvObject::destroyMpv()
{
    if (m_mpv) {
        mpv_terminate_destroy(m_mpv);
        m_mpv = nullptr;
    }
}

void MpvObject::applyHttpHeaders()
{
    if (!m_mpv) return;

    QString cookies = LoginManager::instance()->getCookies();

    QStringList headers;
    headers.append(QString("Referer: %1").arg(MPV_REFERER));
    headers.append(QString("Origin: %1").arg(MPV_ORIGIN));
    headers.append(QString("User-Agent: %1").arg(MPV_USER_AGENT));
    if (!cookies.isEmpty()) {
        headers.append(QString("Cookie: %1").arg(cookies));
    }

    int num = headers.size();
    mpv_node *values = new mpv_node[num];
    for (int i = 0; i < num; ++i) {
        values[i].format = MPV_FORMAT_STRING;
        values[i].u.string = qstrdup(headers[i].toUtf8().constData());
    }

    mpv_node_list list;
    list.num = num;
    list.values = values;
    list.keys = nullptr;

    mpv_node node;
    node.format = MPV_FORMAT_NODE_ARRAY;
    node.u.list = &list;

    mpv_set_property(m_mpv, "http-header-fields", MPV_FORMAT_NODE, &node);

    for (int i = 0; i < num; ++i) {
        delete[] values[i].u.string;
    }
    delete[] values;
}

QQuickFramebufferObject::Renderer *MpvObject::createRenderer() const
{
    // Renderer 析构时会先释放 render context 再终止 mpv 实例，
    // 避免 render context 仍被使用时 terminate 导致阻塞/崩溃。
    m_rendererWillDestroyMpv = true;
    return new MpvRenderer(const_cast<MpvObject*>(this), m_mpv);
}

QString MpvObject::source() const
{
    return m_source;
}

void MpvObject::setSource(const QString &source)
{
    if (m_source == source) return;
    m_source = source;
    emit sourceChanged();
    if (source.isEmpty()) {
        stopRenderTimer();
        stop();
    } else {
        loadFile(source);
        startRenderTimer();
    }
}

QString MpvObject::audioSource() const
{
    return m_audioSource;
}

void MpvObject::setAudioSource(const QString &audioSource)
{
    if (m_audioSource == audioSource) return;
    m_audioSource = audioSource;
    emit audioSourceChanged();
}

bool MpvObject::playing() const
{
    return m_playing;
}

void MpvObject::setPlaying(bool playing)
{
    if (!m_mpv) return;
    m_desiredPlaying = playing;
    if (m_playing == playing) return;
    const char *cmd[] = {"set", "pause", playing ? "no" : "yes", nullptr};
    mpv_command_async(m_mpv, 0, cmd);
}

int MpvObject::position() const
{
    return m_position;
}

int MpvObject::duration() const
{
    return m_duration;
}

qreal MpvObject::volume() const
{
    return m_volume;
}

void MpvObject::setVolume(qreal volume)
{
    if (!m_mpv) return;
    m_volume = qBound(0.0, volume, 1.0);
    double vol = m_volume * 100.0;
    mpv_set_property(m_mpv, "volume", MPV_FORMAT_DOUBLE, &vol);
    emit volumeChanged();
}

qreal MpvObject::speed() const
{
    return m_speed;
}

void MpvObject::setSpeed(qreal speed)
{
    if (!m_mpv) return;
    speed = qBound(0.25, speed, 4.0);
    if (qFuzzyCompare(m_speed, speed)) return;
    m_speed = speed;
    double s = speed;
    mpv_set_property(m_mpv, "speed", MPV_FORMAT_DOUBLE, &s);
    emit speedChanged();
}

bool MpvObject::hasVideo() const
{
    return m_hasVideo;
}

bool MpvObject::seekable() const
{
    return m_seekable;
}

void MpvObject::itemChange(ItemChange change, const ItemChangeData &value)
{
    if (change == ItemSceneChange) {
        QQuickWindow *newWindow = value.window;
        if (newWindow != m_window) {
            if (m_window) {
                disconnect(m_window, &QQuickWindow::frameSwapped, this, &MpvObject::update);
            }
            m_window = newWindow;
            if (m_window) {
                // 连接窗口的 frameSwapped 信号到 update()，
                // 与 16ms 渲染定时器、DanmakuOverlay 的 NumberAnimation 配合，
                // 使 QSG 渲染循环尽量保持在 60fps，
                // 避免被视频/直播帧率拖慢后退化为 timer mode。
                connect(m_window, &QQuickWindow::frameSwapped, this, &MpvObject::update, Qt::UniqueConnection);
                update();
            }
        }
        startRenderTimer();
    } else if (change == ItemVisibleHasChanged) {
        if (isVisible()) {
            startRenderTimer();
        } else {
            stopRenderTimer();
        }
    }
    QQuickFramebufferObject::itemChange(change, value);
}

void MpvObject::play()
{
    setPlaying(true);
}

void MpvObject::pause()
{
    setPlaying(false);
}

void MpvObject::stop()
{
    if (!m_mpv) return;
    // 使用异步命令，避免同步 set_property 在网络流卡住时阻塞主线程
    const char *pauseCmd[] = {"set", "pause", "yes", nullptr};
    mpv_command_async(m_mpv, 0, pauseCmd);
    const char *cmd[] = {"stop", nullptr};
    mpv_command_async(m_mpv, 0, cmd);
}

void MpvObject::seek(int position)
{
    if (!m_mpv || !m_seekable) return;
    QByteArray posStr = QByteArray::number(position / 1000.0, 'f', 3);
    const char *cmd[] = {"seek", posStr.constData(), "absolute+exact", nullptr};
    mpv_command_async(m_mpv, 0, cmd);
}

void MpvObject::updatePosition()
{
    if (!m_mpv) return;
    double pos = 0.0;
    if (mpv_get_property(m_mpv, "time-pos", MPV_FORMAT_DOUBLE, &pos) == 0) {
        int newPos = int(pos * 1000);
        if (m_position != newPos) {
            m_position = newPos;
            emit positionChanged();
        }
    }
}

void MpvObject::loadFile(const QString &file)
{
    if (!m_mpv || file.isEmpty()) return;

    qDebug() << "[MpvObject] loadFile:" << file;
    applyHttpHeaders();
    
    // 加载新文件时，默认设置为播放状态
    m_desiredPlaying = true;

    // 加载新文件前先停止当前播放，避免 mpv 在 stop/loadfile 之间状态混乱
    const char *stopCmd[] = {"stop", nullptr};
    mpv_command_async(m_mpv, 0, stopCmd);

    QByteArray fileData = file.toUtf8();
    const char *cmd[] = {"loadfile", fileData.constData(), "replace", nullptr};
    mpv_command_async(m_mpv, 0, cmd);
}

QVariantMap MpvObject::getVideoInfo()
{
    QVariantMap info;
    if (!m_mpv) return info;

    auto readString = [this](const char *name) -> QString {
        char *val = mpv_get_property_string(m_mpv, name);
        QString s = val ? QString::fromUtf8(val) : QString();
        if (val) mpv_free(val);
        return s;
    };
    auto readDouble = [this](const char *name) -> double {
        double val = 0.0;
        mpv_get_property(m_mpv, name, MPV_FORMAT_DOUBLE, &val);
        return val;
    };

    info["width"] = readDouble("width");
    info["height"] = readDouble("height");
    info["videoCodec"] = readString("video-codec");
    info["videoFormat"] = readString("video-format");
    info["containerFormat"] = readString("file-format");
    info["fps"] = readDouble("container-fps");
    info["videoBitrate"] = readDouble("video-bitrate");
    info["audioBitrate"] = readDouble("audio-bitrate");
    info["audioCodec"] = readString("audio-codec");
    // 当前播放 URL（可用于核对请求的 qn）
    info["path"] = readString("path");
    return info;
}

void MpvObject::geometryChange(const QRectF &newGeometry, const QRectF &oldGeometry)
{
    QQuickFramebufferObject::geometryChange(newGeometry, oldGeometry);
}

void MpvObject::onMpvEvents()
{
    if (!m_mpv) return;

    while (true) {
        mpv_event *event = mpv_wait_event(m_mpv, 0);
        if (event->event_id == MPV_EVENT_NONE) break;

        switch (event->event_id) {
        case MPV_EVENT_PROPERTY_CHANGE: {
            mpv_event_property *prop = static_cast<mpv_event_property*>(event->data);
            if (!prop || !prop->data) break;

            if (strcmp(prop->name, "time-pos") == 0 && prop->format == MPV_FORMAT_DOUBLE) {
                double pos = *static_cast<double*>(prop->data);
                int newPos = int(pos * 1000);
                if (m_position != newPos) {
                    m_position = newPos;
                    emit positionChanged();
                }
            } else if (strcmp(prop->name, "duration") == 0 && prop->format == MPV_FORMAT_DOUBLE) {
                double dur = *static_cast<double*>(prop->data);
                int newDur = int(dur * 1000);
                if (m_duration != newDur) {
                    m_duration = newDur;
                    emit durationChanged();
                }
            } else if (strcmp(prop->name, "pause") == 0 && prop->format == MPV_FORMAT_FLAG) {
                bool paused = *static_cast<int*>(prop->data) != 0;
                if (m_paused != paused) {
                    m_paused = paused;
                    if (m_playing == paused) {
                        m_playing = !paused;
                        emit playingChanged();
                    }
                    // 暂停时停止 60fps 强制渲染，减少 GPU 空转
                    if (paused) {
                        stopRenderTimer();
                    } else {
                        startRenderTimer();
                    }
                }
            } else if (strcmp(prop->name, "speed") == 0 && prop->format == MPV_FORMAT_DOUBLE) {
                double speed = *static_cast<double*>(prop->data);
                if (!qFuzzyCompare(m_speed, speed)) {
                    m_speed = speed;
                    emit speedChanged();
                }
            } else if (strcmp(prop->name, "video-params") == 0) {
                bool hasVideo = (prop->format == MPV_FORMAT_NODE);
                if (m_hasVideo != hasVideo) {
                    m_hasVideo = hasVideo;
                    emit hasVideoChanged();
                }
            } else if (strcmp(prop->name, "seekable") == 0 && prop->format == MPV_FORMAT_FLAG) {
                bool seekable = *static_cast<int*>(prop->data) != 0;
                if (m_seekable != seekable) {
                    m_seekable = seekable;
                    emit seekableChanged();
                }
            } else if (strcmp(prop->name, "hwdec-current") == 0 && prop->format == MPV_FORMAT_STRING) {
                char *hw = *static_cast<char**>(prop->data);
                qWarning() << "[MpvObject] hwdec-current:" << (hw ? QString::fromUtf8(hw) : QString("none"));
            }
            break;
        }
        case MPV_EVENT_FILE_LOADED: {
            if (!m_audioSource.isEmpty()) {
                QByteArray audioData = m_audioSource.toUtf8();
                const char *cmd[] = {"audio-add", audioData.constData(), nullptr};
                mpv_command_async(m_mpv, 0, cmd);
            }
            // 使用 m_desiredPlaying 而不是 m_playing，因为 loadFile 可能已将 m_playing 重置为 false
            if (m_desiredPlaying) {
                const char *cmd[] = {"set", "pause", "no", nullptr};
                mpv_command_async(m_mpv, 0, cmd);
            }
            break;
        }
        case MPV_EVENT_END_FILE: {
            mpv_event_end_file *ef = static_cast<mpv_event_end_file*>(event->data);
            if (ef && ef->reason == MPV_END_FILE_REASON_ERROR) {
                QString err = QString::fromUtf8(mpv_error_string(ef->error));
                qWarning() << "[MpvObject] playback error:" << err;
                emit errorOccurred(err);
            }
            break;
        }
        default:
            break;
        }
    }
}

void MpvObject::startRenderTimer()
{
    if (!m_renderTimer) return;
    // 仅在已加载视频、有窗口、可见且未暂停时启动 60fps 渲染定时器
    if (!m_source.isEmpty() && m_window && isVisible() && !m_paused) {
        if (!m_renderTimer->isActive()) {
            m_renderTimer->start();
        }
    }
}

void MpvObject::stopRenderTimer()
{
    if (m_renderTimer && m_renderTimer->isActive()) {
        m_renderTimer->stop();
    }
}
