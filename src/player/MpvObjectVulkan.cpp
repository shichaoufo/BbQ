#include "MpvObjectVulkan.h"

#include "LoginManager.h"
#include <QDebug>
#include <QMetaObject>
#include <QQuickWindow>
#include <QRunnable>
#include <QSGSimpleTextureNode>
#include <QSGTexture>

#include <private/qrhi_p.h>

#include <d3d11.h>
#include <dxgi.h>

extern "C" {
#include <mpv/client.h>
#include <mpv/render.h>

#if __has_include(<mpv/render_d3d11.h>)
#include <mpv/render_d3d11.h>
#else
#define MPV_RENDER_API_TYPE_D3D11 "d3d11"

typedef struct mpv_d3d11_init_params {
    ID3D11Device *device;
} mpv_d3d11_init_params;

// 与 mpv 公开头文件 render_d3d11.h 保持一致字段名 { tex, w, h }
typedef struct mpv_d3d11_fbo {
    ID3D11Texture2D *tex;
    int w, h;
} mpv_d3d11_fbo;

#define MPV_RENDER_PARAM_D3D11_INIT_PARAMS 17
#define MPV_RENDER_PARAM_D3D11_FBO 18
#endif
}

static const QString MPV_USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
static const QString MPV_REFERER = "https://www.bilibili.com";
static const QString MPV_ORIGIN = "https://www.bilibili.com";

class MpvVulkanCleanupJob : public QRunnable
{
public:
    MpvVulkanCleanupJob(mpv_handle *mpv, mpv_render_context *render,
                        ID3D11Device *dev, ID3D11DeviceContext *ctx,
                        ID3D11Texture2D *tex, ID3D11Texture2D *staging,
                        QSGTexture *qsgTex, QRhiTexture *qrhiTex)
        : m_mpv(mpv)
        , m_render(render)
        , m_dev(dev)
        , m_ctx(ctx)
        , m_tex(tex)
        , m_staging(staging)
        , m_qsgTex(qsgTex)
        , m_qrhiTex(qrhiTex)
    {
    }

    void run() override
    {
        if (m_render) {
            mpv_render_context_free(m_render);
        }
        if (m_qsgTex) {
            delete m_qsgTex;
        }
        if (m_qrhiTex) {
            delete m_qrhiTex;
        }
        if (m_staging) {
            m_staging->Release();
        }
        if (m_tex) {
            m_tex->Release();
        }
        if (m_ctx) {
            m_ctx->Release();
        }
        if (m_dev) {
            m_dev->Release();
        }
        if (m_mpv) {
            mpv_terminate_destroy(m_mpv);
        }
    }

private:
    mpv_handle *m_mpv;
    mpv_render_context *m_render;
    ID3D11Device *m_dev;
    ID3D11DeviceContext *m_ctx;
    ID3D11Texture2D *m_tex;
    ID3D11Texture2D *m_staging;
    QSGTexture *m_qsgTex;
    QRhiTexture *m_qrhiTex;
};

MpvObjectVulkan::MpvObjectVulkan(QQuickItem *parent)
    : QQuickItem(parent)
{
    setFlag(ItemHasContents, true);
    initMpv();

    m_renderTimer = new QTimer(this);
    m_renderTimer->setInterval(16);
    m_renderTimer->setTimerType(Qt::PreciseTimer);
    connect(m_renderTimer, &QTimer::timeout, this, [this]() { update(); });
}

MpvObjectVulkan::~MpvObjectVulkan()
{
    stopRenderTimer();

    if (m_window) {
        disconnect(m_window, &QQuickWindow::frameSwapped, this, &MpvObjectVulkan::update);
    }

    if (m_mpv) {
        mpv_set_wakeup_callback(m_mpv, nullptr, nullptr);
    }

    if (m_window && (m_mpvRender || m_d3d11Device || m_d3d11Texture || m_qsgTexture || m_qrhiTexture)) {
        auto *job = new MpvVulkanCleanupJob(m_mpv, m_mpvRender, m_d3d11Device, m_d3d11Context,
                                            m_d3d11Texture, m_stagingTexture,
                                            m_qsgTexture, m_qrhiTexture);
        m_window->scheduleRenderJob(job, QQuickWindow::BeforeSynchronizingStage);
        m_mpv = nullptr;
        m_mpvRender = nullptr;
        m_d3d11Device = nullptr;
        m_d3d11Context = nullptr;
        m_d3d11Texture = nullptr;
        m_stagingTexture = nullptr;
        m_qsgTexture = nullptr;
        m_qrhiTexture = nullptr;
    } else {
        if (m_mpvRender) {
            mpv_render_context_free(m_mpvRender);
        }
        if (m_qsgTexture) {
            delete m_qsgTexture;
        }
        if (m_qrhiTexture) {
            delete m_qrhiTexture;
        }
        if (m_stagingTexture) {
            m_stagingTexture->Release();
        }
        if (m_d3d11Texture) {
            m_d3d11Texture->Release();
        }
        if (m_d3d11Context) {
            m_d3d11Context->Release();
        }
        if (m_d3d11Device) {
            m_d3d11Device->Release();
        }
        if (m_mpv) {
            mpv_terminate_destroy(m_mpv);
        }
    }
}

void MpvObjectVulkan::initMpv()
{
    m_mpv = mpv_create();
    if (!m_mpv) {
        qWarning() << "[MpvObjectVulkan] failed to create mpv context";
        emit errorOccurred("Failed to create mpv context");
        return;
    }

    mpv_set_option_string(m_mpv, "vo", "libmpv");
    // Qt RHI 是 Vulkan，但 mpv 的渲染仍走独立 D3D11 设备，硬解继续用 d3d11va。
    mpv_set_option_string(m_mpv, "hwdec", "d3d11va");
    mpv_set_option_string(m_mpv, "keep-open", "yes");
    mpv_set_option_string(m_mpv, "force-window", "no");
    mpv_set_option_string(m_mpv, "input-default-bindings", "no");
    mpv_set_option_string(m_mpv, "input-vo-keyboard", "no");
    mpv_set_option_string(m_mpv, "ytdl", "no");
    mpv_set_option_string(m_mpv, "video-timing-offset", "0");
    mpv_set_option_string(m_mpv, "display-fps", "60");
    mpv_set_option_string(m_mpv, "override-display-fps", "60");
    mpv_set_option_string(m_mpv, "cache-secs", "15");
    mpv_set_option_string(m_mpv, "demuxer-max-bytes", "50M");
    mpv_set_option_string(m_mpv, "demuxer-max-back-bytes", "25M");
    mpv_set_option_string(m_mpv, "demuxer-readahead-secs", "15");
    mpv_set_option_string(m_mpv, "profile", "fast");
    mpv_set_option_string(m_mpv, "scale", "bilinear");
    mpv_set_option_string(m_mpv, "dscale", "bilinear");
    mpv_set_option_string(m_mpv, "dither", "no");
    mpv_set_option_string(m_mpv, "correct-downscaling", "no");
    mpv_set_option_string(m_mpv, "linear-downscaling", "no");
    mpv_set_option_string(m_mpv, "sigmoid-upscaling", "no");
    mpv_set_option_string(m_mpv, "hdr-compute-peak", "no");
    mpv_set_option_string(m_mpv, "vd-lavc-fast", "yes");
    mpv_set_option_string(m_mpv, "vd-lavc-skiploopfilter", "all");

    if (mpv_initialize(m_mpv) < 0) {
        qWarning() << "[MpvObjectVulkan] failed to initialize mpv";
        emit errorOccurred("Failed to initialize mpv");
        mpv_terminate_destroy(m_mpv);
        m_mpv = nullptr;
        return;
    }

    applyHttpHeaders();

    mpv_set_wakeup_callback(m_mpv, [](void *ctx) {
        QMetaObject::invokeMethod(static_cast<MpvObjectVulkan*>(ctx), &MpvObjectVulkan::onMpvEvents, Qt::QueuedConnection);
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

void MpvObjectVulkan::applyHttpHeaders()
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

QString MpvObjectVulkan::source() const
{
    return m_source;
}

void MpvObjectVulkan::setSource(const QString &source)
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

QString MpvObjectVulkan::audioSource() const
{
    return m_audioSource;
}

void MpvObjectVulkan::setAudioSource(const QString &audioSource)
{
    if (m_audioSource == audioSource) return;
    m_audioSource = audioSource;
    emit audioSourceChanged();
}

bool MpvObjectVulkan::playing() const
{
    return m_playing;
}

void MpvObjectVulkan::setPlaying(bool playing)
{
    if (!m_mpv) return;
    m_desiredPlaying = playing;
    if (m_playing == playing) return;
    const char *cmd[] = {"set", "pause", playing ? "no" : "yes", nullptr};
    mpv_command_async(m_mpv, 0, cmd);
}

int MpvObjectVulkan::position() const
{
    return m_position;
}

int MpvObjectVulkan::duration() const
{
    return m_duration;
}

qreal MpvObjectVulkan::volume() const
{
    return m_volume;
}

void MpvObjectVulkan::setVolume(qreal volume)
{
    if (!m_mpv) return;
    m_volume = qBound(0.0, volume, 1.0);
    double vol = m_volume * 100.0;
    mpv_set_property(m_mpv, "volume", MPV_FORMAT_DOUBLE, &vol);
    emit volumeChanged();
}

qreal MpvObjectVulkan::speed() const
{
    return m_speed;
}

void MpvObjectVulkan::setSpeed(qreal speed)
{
    if (!m_mpv) return;
    speed = qBound(0.25, speed, 4.0);
    if (qFuzzyCompare(m_speed, speed)) return;
    m_speed = speed;
    double s = speed;
    mpv_set_property(m_mpv, "speed", MPV_FORMAT_DOUBLE, &s);
    emit speedChanged();
}

bool MpvObjectVulkan::hasVideo() const
{
    return m_hasVideo;
}

bool MpvObjectVulkan::seekable() const
{
    return m_seekable;
}

void MpvObjectVulkan::itemChange(ItemChange change, const ItemChangeData &value)
{
    if (change == ItemSceneChange) {
        QQuickWindow *newWindow = value.window;
        if (newWindow != m_window) {
            if (m_window) {
                disconnect(m_window, &QQuickWindow::frameSwapped, this, &MpvObjectVulkan::update);
            }
            m_window = newWindow;
            if (m_window) {
                connect(m_window, &QQuickWindow::frameSwapped, this, &MpvObjectVulkan::update, Qt::UniqueConnection);
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
    QQuickItem::itemChange(change, value);
}

void MpvObjectVulkan::geometryChange(const QRectF &newGeometry, const QRectF &oldGeometry)
{
    if (newGeometry.size() != oldGeometry.size()) {
        m_resourcesDirty = true;
        update();
    }
    QQuickItem::geometryChange(newGeometry, oldGeometry);
}

void MpvObjectVulkan::play()
{
    setPlaying(true);
}

void MpvObjectVulkan::pause()
{
    setPlaying(false);
}

void MpvObjectVulkan::stop()
{
    if (!m_mpv) return;
    const char *pauseCmd[] = {"set", "pause", "yes", nullptr};
    mpv_command_async(m_mpv, 0, pauseCmd);
    const char *cmd[] = {"stop", nullptr};
    mpv_command_async(m_mpv, 0, cmd);
}

void MpvObjectVulkan::seek(int position)
{
    if (!m_mpv || !m_seekable) return;
    QByteArray posStr = QByteArray::number(position / 1000.0, 'f', 3);
    const char *cmd[] = {"seek", posStr.constData(), "absolute+exact", nullptr};
    mpv_command_async(m_mpv, 0, cmd);
}

void MpvObjectVulkan::updatePosition()
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

void MpvObjectVulkan::loadFile(const QString &file)
{
    if (!m_mpv || file.isEmpty()) return;

    applyHttpHeaders();
    
    // 加载新文件时，默认设置为播放状态
    m_desiredPlaying = true;

    const char *stopCmd[] = {"stop", nullptr};
    mpv_command_async(m_mpv, 0, stopCmd);

    QByteArray fileData = file.toUtf8();
    const char *cmd[] = {"loadfile", fileData.constData(), "replace", nullptr};
    mpv_command_async(m_mpv, 0, cmd);
}

QVariantMap MpvObjectVulkan::getVideoInfo()
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
    info["path"] = readString("path");
    return info;
}

void MpvObjectVulkan::onMpvEvents()
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
                qWarning() << "[MpvObjectVulkan] hwdec-current:" << (hw ? QString::fromUtf8(hw) : QString("none"));
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
                qWarning() << "[MpvObjectVulkan] playback error:" << err;
                emit errorOccurred(err);
            }
            break;
        }
        default:
            break;
        }
    }
}

void MpvObjectVulkan::startRenderTimer()
{
    if (!m_renderTimer) return;
    if (!m_source.isEmpty() && m_window && isVisible() && !m_paused) {
        if (!m_renderTimer->isActive()) {
            m_renderTimer->start();
        }
    }
}

void MpvObjectVulkan::stopRenderTimer()
{
    if (m_renderTimer && m_renderTimer->isActive()) {
        m_renderTimer->stop();
    }
}

bool MpvObjectVulkan::ensureD3D11Resources()
{
    if (!m_d3d11Device) {
        D3D_FEATURE_LEVEL featureLevels[] = {
            D3D_FEATURE_LEVEL_11_1,
            D3D_FEATURE_LEVEL_11_0,
        };
        UINT createFlags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
#if defined(QT_DEBUG) && !defined(NDEBUG)
        createFlags |= D3D11_CREATE_DEVICE_DEBUG;
#endif
        D3D_FEATURE_LEVEL level;
        HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, createFlags,
                                       featureLevels, static_cast<UINT>(sizeof(featureLevels) / sizeof(featureLevels[0])),
                                       D3D11_SDK_VERSION, &m_d3d11Device, &level,
                                       &m_d3d11Context);
        if (FAILED(hr)) {
            qWarning() << "[MpvObjectVulkan] failed to create D3D11 device, hr:" << hr;
            return false;
        }
    }

    QSize size(static_cast<int>(width()), static_cast<int>(height()));
    if (size.width() <= 0 || size.height() <= 0) {
        return false;
    }

    if (m_resourcesDirty || m_textureSize != size) {
        if (m_qsgTexture) {
            delete m_qsgTexture;
            m_qsgTexture = nullptr;
        }
        if (m_qrhiTexture) {
            delete m_qrhiTexture;
            m_qrhiTexture = nullptr;
        }
        if (m_stagingTexture) {
            m_stagingTexture->Release();
            m_stagingTexture = nullptr;
        }
        if (m_d3d11Texture) {
            m_d3d11Texture->Release();
            m_d3d11Texture = nullptr;
        }
        m_pixelBuffer.clear();
        m_textureSize = size;
        m_resourcesDirty = false;
        m_textureUploaded = false;
    }

    if (!m_d3d11Texture) {
        D3D11_TEXTURE2D_DESC desc = {};
        desc.Width = static_cast<UINT>(size.width());
        desc.Height = static_cast<UINT>(size.height());
        desc.MipLevels = 1;
        desc.ArraySize = 1;
        desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        desc.SampleDesc.Count = 1;
        desc.Usage = D3D11_USAGE_DEFAULT;
        desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;

        HRESULT hr = m_d3d11Device->CreateTexture2D(&desc, nullptr, &m_d3d11Texture);
        if (FAILED(hr)) {
            qWarning() << "[MpvObjectVulkan] failed to create D3D11 render texture, hr:" << hr;
            return false;
        }
    }

    if (!m_mpvRender) {
        mpv_d3d11_init_params d3d11Init;
        d3d11Init.device = m_d3d11Device;

        mpv_render_param params[] = {
            {MPV_RENDER_PARAM_API_TYPE, const_cast<char*>(MPV_RENDER_API_TYPE_D3D11)},
            {static_cast<mpv_render_param_type>(MPV_RENDER_PARAM_D3D11_INIT_PARAMS), &d3d11Init},
            {MPV_RENDER_PARAM_INVALID, nullptr}
        };

        int ret = mpv_render_context_create(&m_mpvRender, m_mpv, params);
        if (ret < 0) {
            qWarning() << "[MpvObjectVulkan] failed to create mpv D3D11 render context:" << mpv_error_string(ret)
                       << "(requires libmpv with D3D11 render API)";
            return false;
        }

        mpv_render_context_set_update_callback(m_mpvRender, [](void *ctx) {
            Q_UNUSED(ctx)
        }, this);
    }

    return true;
}

bool MpvObjectVulkan::ensureStagingResources()
{
    if (!m_d3d11Device || m_textureSize.isEmpty()) {
        return false;
    }
    if (m_stagingTexture) {
        return true;
    }

    D3D11_TEXTURE2D_DESC desc = {};
    desc.Width = static_cast<UINT>(m_textureSize.width());
    desc.Height = static_cast<UINT>(m_textureSize.height());
    desc.MipLevels = 1;
    desc.ArraySize = 1;
    desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.Usage = D3D11_USAGE_STAGING;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;

    HRESULT hr = m_d3d11Device->CreateTexture2D(&desc, nullptr, &m_stagingTexture);
    if (FAILED(hr)) {
        qWarning() << "[MpvObjectVulkan] failed to create D3D11 staging texture, hr:" << hr;
        return false;
    }

    const int bytesPerPixel = 4;
    m_pixelBuffer.resize(m_textureSize.width() * m_textureSize.height() * bytesPerPixel);
    return true;
}

void MpvObjectVulkan::renderMpv()
{
    if (!m_mpvRender || !m_d3d11Texture || !m_d3d11Context) {
        return;
    }

    mpv_d3d11_fbo fbo;
    fbo.tex = m_d3d11Texture;
    fbo.w = m_textureSize.width();
    fbo.h = m_textureSize.height();

    mpv_render_param params[] = {
        {static_cast<mpv_render_param_type>(MPV_RENDER_PARAM_D3D11_FBO), &fbo},
        {MPV_RENDER_PARAM_INVALID, nullptr}
    };

    mpv_render_context_render(m_mpvRender, params);
    mpv_render_context_report_swap(m_mpvRender);
}

void MpvObjectVulkan::uploadToVulkan()
{
    if (!m_window || !m_d3d11Texture || !m_d3d11Context) {
        return;
    }

    QRhi *rhi = m_window->rhi();
    if (!rhi) {
        return;
    }

    if (!ensureStagingResources()) {
        return;
    }

    // 把 GPU 上的渲染结果拷贝到 staging 纹理，再 Map 到 CPU。
    m_d3d11Context->CopyResource(m_stagingTexture, m_d3d11Texture);

    D3D11_MAPPED_SUBRESOURCE mapped = {};
    HRESULT hr = m_d3d11Context->Map(m_stagingTexture, 0, D3D11_MAP_READ, 0, &mapped);
    if (FAILED(hr)) {
        qWarning() << "[MpvObjectVulkan] failed to map staging texture, hr:" << hr;
        return;
    }

    const int w = m_textureSize.width();
    const int h = m_textureSize.height();
    const int dstPitch = w * 4;
    const int rowSize = qMin<int>(dstPitch, mapped.RowPitch);

    if (mapped.RowPitch == dstPitch) {
        memcpy(m_pixelBuffer.data(), mapped.pData, m_pixelBuffer.size());
    } else {
        quint8 *dst = reinterpret_cast<quint8*>(m_pixelBuffer.data());
        const quint8 *src = reinterpret_cast<const quint8*>(mapped.pData);
        for (int y = 0; y < h; ++y) {
            memcpy(dst + y * dstPitch, src + y * mapped.RowPitch, rowSize);
        }
    }

    m_d3d11Context->Unmap(m_stagingTexture, 0);

    // 上传到 QRhiTexture（Vulkan）。
    if (!m_qrhiTexture || m_qrhiTexture->pixelSize() != m_textureSize) {
        if (m_qsgTexture) {
            delete m_qsgTexture;
            m_qsgTexture = nullptr;
        }
        if (m_qrhiTexture) {
            delete m_qrhiTexture;
            m_qrhiTexture = nullptr;
        }
        m_qrhiTexture = rhi->newTexture(QRhiTexture::RGBA8, m_textureSize, 1, QRhiTexture::Flags{});
        if (!m_qrhiTexture || !m_qrhiTexture->create()) {
            qWarning() << "[MpvObjectVulkan] failed to create QRhiTexture";
            return;
        }
    }

    QRhiTextureSubresourceUploadDescription subresDesc;
    subresDesc.setData(m_pixelBuffer);
    subresDesc.setDataStride(dstPitch);

    QRhiTextureUploadDescription uploadDesc;
    uploadDesc.setLayer(0);
    uploadDesc.setMipLevel(0);
    uploadDesc.setSubresourceDescription(subresDesc);

    QRhiResourceUpdateBatch *batch = rhi->nextResourceUpdateBatch();
    batch->uploadTexture(m_qrhiTexture, uploadDesc);
    rhi->submitResourceUpdates(batch);

    m_textureUploaded = true;
}

QSGNode *MpvObjectVulkan::updatePaintNode(QSGNode *oldNode, UpdatePaintNodeData *)
{
    if (!ensureD3D11Resources()) {
        return oldNode;
    }

    renderMpv();
    uploadToVulkan();

    QSGSimpleTextureNode *node = static_cast<QSGSimpleTextureNode *>(oldNode);
    if (!node) {
        node = new QSGSimpleTextureNode();
    }

    if (m_textureUploaded && m_qrhiTexture && !m_qsgTexture) {
        m_qsgTexture = m_window->createTextureFromRhiTexture(m_qrhiTexture, QQuickWindow::TextureHasAlphaChannel);
    }

    if (m_qsgTexture) {
        node->setTexture(m_qsgTexture);
        node->setRect(boundingRect());
        node->setFiltering(QSGTexture::Linear);
    }

    return node;
}
