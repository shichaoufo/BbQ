#include "MpvObjectD3D11.h"
#include "FramePacer.h"

#include "LoginManager.h"
#include <QDebug>
#include <QCoreApplication>
#include <QMetaObject>
#include <QQuickWindow>
#include <QSGSimpleTextureNode>
#include <QSGTexture>
#include <QTime>
#include <QElapsedTimer>

#include <private/qrhi_p.h>
#include <private/qrhid3d11_p.h>

#include <d3d11.h>
#include <dxgi.h>

// 说明：__try/__except 是 MSVC 专属的 SEH 语法，GCC/MinGW 不支持。
// 这里用 _MSC_VER 做编译器检测，只有 MSVC 才走 SEH 路径；
// GCC/MinGW 下直接调用 Release()。SEH 的目的是在 D3D11va 驱动
// 极端异常时兜底，防止把 Qt Creator gdb 后端一起带崩。

extern "C" {
#include <mpv/client.h>
#include <mpv/render.h>

// mpv 的 D3D11 render API 在 PR #17764 中才加入公开头文件 render_d3d11.h。
// 这些宏和结构体在标准 render.h 中没有定义，需要自行提供。
#ifndef MPV_RENDER_API_TYPE_D3D11
#define MPV_RENDER_API_TYPE_D3D11 "d3d11"
#endif

#ifndef MPV_RENDER_PARAM_D3D11_INIT_PARAMS
#define MPV_RENDER_PARAM_D3D11_INIT_PARAMS 21
#endif

#ifndef MPV_RENDER_PARAM_D3D11_FBO
#define MPV_RENDER_PARAM_D3D11_FBO 22
#endif

// 若 mpv-dev 包未提供 render_d3d11.h，则使用本地定义结构体。
// 注意：device 和 tex 字段使用 void* 以匹配 mpv 官方头文件定义。
#if __has_include(<mpv/render_d3d11.h>)
#include <mpv/render_d3d11.h>
#else
typedef struct mpv_d3d11_init_params {
    void *device;
} mpv_d3d11_init_params;

typedef struct mpv_d3d11_fbo {
    void *tex;
    int w, h;
} mpv_d3d11_fbo;
#endif
}

static const QString MPV_USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
static const QString MPV_REFERER = "https://www.bilibili.com";
static const QString MPV_ORIGIN = "https://www.bilibili.com";

MpvObjectD3D11::MpvObjectD3D11(QQuickItem *parent)
    : QQuickItem(parent)
{
    setFlag(ItemHasContents, true);
    m_posThrottleClock.start();
    initMpv();

    // 订阅统一帧心跳（Phase 2）：高刷屏上视频帧的显示时机由 FramePacer
    // 网格节奏统一驱动（m_framePending 由 tick 消费）；60Hz 屏上 pacer
    // 不激活，订阅静默。wants 只读原子量，可在 GUI 线程 tick 内安全调用
    FramePacer::instance()->subscribe(this, [this]() {
        return m_framePending.load(std::memory_order_acquire);
    });

    // 100ms backup timer - catches missed frames if frameSwapped doesn't fire
    // (e.g., before first vsync or after window changes). frameSwapped at 60fps
    // is the primary driver; this is just a safety net.
    m_renderTimer = new QTimer(this);
    m_renderTimer->setInterval(100);
    m_renderTimer->setTimerType(Qt::CoarseTimer);
    connect(m_renderTimer, &QTimer::timeout, this, [this]() {
        // m_videoReinitPending：跨窗口迁移后渲染上下文尚未在新窗口重建。
        // 迁移中转时抵达窗口可能处于隐藏状态（退出小窗→主窗口未显示），
        // itemChange 里的 update() 请求会被渲染循环丢弃（未暴露窗口不渲染），
        // 需持续驱动 update() 确保 updatePaintNode→ensureD3D11Resources 执行，
        // 否则视频链死亡→黑屏（音频继续）。
        // 高刷屏节流模式：常规帧交付已由 FramePacer 心跳负责（mpv 回调会
        // poke），此处只保留 reinit 兜底，避免 off-grid 渲染打乱认领节奏
        if (!m_shuttingDown.load(std::memory_order_acquire)
            && (m_videoReinitPending
                || (!FramePacer::instance()->active()
                    && m_framePending.load(std::memory_order_acquire)))) {
            update();
        }
    });
}

MpvObjectD3D11::~MpvObjectD3D11()
{
    qWarning() << "[MpvObjectD3D11] destructor called";

    QElapsedTimer totalTimer;
    totalTimer.start();

    // 1. Stop all update sources so the render thread won't call updatePaintNode again.
    stopRenderTimer();
    // 退订统一帧心跳：订阅表持有本对象谓词，析构后不得再被 tick 调用
    FramePacer::instance()->unsubscribe(this);
    m_shuttingDown.store(true, std::memory_order_release);

    if (m_window) {
        disconnect(m_window, &QQuickWindow::frameSwapped, this, nullptr);
    }

    // 2. Disable mpv wakeup callback to prevent queued callbacks.
    if (m_mpv) {
        mpv_set_wakeup_callback(m_mpv, nullptr, nullptr);
    }

    // 3. Lock the render mutex to wait for the render thread to finish any
    //    in-flight updatePaintNode/renderMpv call. After this returns we know
    //    the render thread is not using our resources anymore.
    qWarning() << "[MpvObjectD3D11] acquiring render mutex for sync cleanup";
    {
        QElapsedTimer t;
        t.start();
        QMutexLocker locker(&m_renderMutex);
        qWarning() << "[MpvObjectD3D11] render mutex acquired in" << t.elapsed() << "ms";
    }
    qWarning() << "[MpvObjectD3D11] render thread is out of updatePaintNode";

    // 4. 检查窗口是否仍然有效
    // 使用 QPointer::isNull() 来检查底层的 QQuickWindow 是否已被销毁
    bool windowAlive = m_window && !m_window.isNull();
    qWarning() << "[MpvObjectD3D11] window alive:" << windowAlive;

    if (windowAlive) {
        // 窗口仍然存活 - 通过 scheduleRenderJob 在渲染线程上安全释放 GPU 资源
        qWarning() << "[MpvObjectD3D11] scheduling cleanup job on render thread";
        struct CleanupJob : public QRunnable {
            mpv_handle *mpv;
            mpv_render_context *mpvRender;
            ID3D11Device *device;
            QSGTexture *qsgTex;
            QRhiTexture *qrhiTex;
            ID3D11Texture2D *d3d11Tex;
            QList<StaleTextureSet> staleTextures;
            CleanupJob(mpv_handle *m, mpv_render_context *mr, ID3D11Device *d,
                       QSGTexture *qt, QRhiTexture *rt, ID3D11Texture2D *dt,
                       const QList<StaleTextureSet> &stale)
                : mpv(m), mpvRender(mr), device(d), qsgTex(qt), qrhiTex(rt), d3d11Tex(dt)
                , staleTextures(stale) {}
            void run() override {
                QElapsedTimer t;
                t.start();
                qWarning() << "[MpvObjectD3D11] cleanup job: freeing render context";
                if (mpvRender) mpv_render_context_free(mpvRender);
                qWarning() << "[MpvObjectD3D11] cleanup job: terminating mpv";
                if (mpv) mpv_terminate_destroy(mpv);
                qWarning() << "[MpvObjectD3D11] cleanup job: freeing textures";
                // createTextureFromRhiTexture() transfers QRhiTexture ownership
                // to the returned QSGTexture. Deleting the QSGTexture will also
                // delete the underlying QRhiTexture, so we must NOT delete
                // qrhiTex ourselves here.
                delete qsgTex;
                if (d3d11Tex) d3d11Tex->Release();
                for (const StaleTextureSet &set : staleTextures) {
                    delete set.qsgTex;
                    if (set.d3d11Tex) set.d3d11Tex->Release();
                }
                if (device) device->Release();
                qWarning() << "[MpvObjectD3D11] cleanup job done in" << t.elapsed() << "ms";
            }
        };
        auto *job = new CleanupJob(m_mpv, m_mpvRender, m_d3d11Device,
                                   m_qsgTexture, m_qrhiTexture, m_d3d11Texture,
                                   m_staleTextures);
        m_window->scheduleRenderJob(job, QQuickWindow::BeforeSynchronizingStage);
        // Ownership transferred to the job; clear our pointers so we don't
        // touch them again after returning.
        m_mpv = nullptr;
        m_mpvRender = nullptr;
        m_d3d11Device = nullptr;
        m_qsgTexture = nullptr;
        m_qrhiTexture = nullptr;
        m_d3d11Texture = nullptr;
        m_staleTextures.clear();
    } else {
        // 窗口已被销毁（或从未设置）
        // 情况1（常规路径）：itemChange 已把全部资源移交给渲染线程 job
        //   （m_fullCleanupScheduled=true，所有指针已清空），此处无事可做，
        //   绝不能再 direct release——否则会重新引入"GUI 线程销毁 device、
        //   渲染线程延后释放 interop 纹理"的跨线程竞态（失焦切回死锁）。
        // 情况2（兜底）：item 从未进入过场景（指针非空），scheduleRenderJob 会
        //   被静默丢弃，只能直接释放。
        if (m_fullCleanupScheduled) {
            qWarning() << "[MpvObjectD3D11] full cleanup already scheduled on render thread, skip direct release";
        } else {
            qWarning() << "[MpvObjectD3D11] window already destroyed, releasing directly";
        }
        QElapsedTimer t;
        t.start();

        // 释放顺序：先释放 mpv render context（会释放内部 D3D11 资源），
        // 再释放 D3D11 纹理与 device（外部创建的纹理）。
        // 注意：这里不能在 GUI 线程 delete qsgTex / qrhiTex，因为它们属于
        // 场景图（scene graph），必须由渲染线程释放。窗口销毁时 Qt 会
        // 自动处理场景图的清理，所以我们只释放持有的 D3D11 原始资源。
        // 同时在每个 D3D11 Release 外面套一个 SEH 兜底——AMD/Intel 的
        // D3D11va 驱动在极端场景下可能在 Release() 内抛访问冲突，
        // 这会直接把 Qt Creator 的 gdb 后端带崩（主程序本身不会崩）。
        if (m_mpvRender) {
            qWarning() << "[MpvObjectD3D11] freeing mpv_render_context";
#ifdef _MSC_VER
            __try {
                mpv_render_context_free(m_mpvRender);
            } __except (EXCEPTION_EXECUTE_HANDLER) {
                qCritical() << "[MpvObjectD3D11] SEH caught in mpv_render_context_free";
            }
#else
            mpv_render_context_free(m_mpvRender);
#endif
            qWarning() << "[MpvObjectD3D11] mpv_render_context freed";
        }
        if (m_mpv) {
            qWarning() << "[MpvObjectD3D11] terminating mpv";
#ifdef _MSC_VER
            __try {
                mpv_terminate_destroy(m_mpv);
            } __except (EXCEPTION_EXECUTE_HANDLER) {
                qCritical() << "[MpvObjectD3D11] SEH caught in mpv_terminate_destroy";
            }
#else
            mpv_terminate_destroy(m_mpv);
#endif
            qWarning() << "[MpvObjectD3D11] mpv terminated";
        }
        // 纹理先于 device 释放，避免 GPU 驱动持有 device 时访问纹理
        if (m_d3d11Texture) {
            qWarning() << "[MpvObjectD3D11] releasing D3D11 texture";
#ifdef _MSC_VER
            __try { m_d3d11Texture->Release(); }
            __except (EXCEPTION_EXECUTE_HANDLER) {
                qCritical() << "[MpvObjectD3D11] SEH caught in texture->Release";
            }
#else
            m_d3d11Texture->Release();
#endif
        }
        for (const StaleTextureSet &set : m_staleTextures) {
            if (set.d3d11Tex) {
#ifdef _MSC_VER
                __try { set.d3d11Tex->Release(); }
                __except (EXCEPTION_EXECUTE_HANDLER) {
                    qCritical() << "[MpvObjectD3D11] SEH caught in stale->Release";
                }
#else
                set.d3d11Tex->Release();
#endif
            }
        }
        if (m_d3d11Device) {
            qWarning() << "[MpvObjectD3D11] releasing D3D11 device";
#ifdef _MSC_VER
            __try { m_d3d11Device->Release(); }
            __except (EXCEPTION_EXECUTE_HANDLER) {
                qCritical() << "[MpvObjectD3D11] SEH caught in device->Release";
            }
#else
            m_d3d11Device->Release();
#endif
        }
        qWarning() << "[MpvObjectD3D11] direct release done in" << t.elapsed() << "ms";

        m_mpvRender = nullptr;
        m_mpv = nullptr;
        m_d3d11Device = nullptr;
        m_qsgTexture = nullptr;
        m_qrhiTexture = nullptr;
        m_d3d11Texture = nullptr;
        m_staleTextures.clear();
    }

    qWarning() << "[MpvObjectD3D11] destructor done in" << totalTimer.elapsed() << "ms";
}

void MpvObjectD3D11::initMpv()
{
    m_mpv = mpv_create();
    if (!m_mpv) {
        qWarning() << "[MpvObjectD3D11] failed to create mpv context";
        emit errorOccurred("Failed to create mpv context");
        return;
    }
    mpv_set_option_string(m_mpv, "vo", "libmpv");
    mpv_set_option_string(m_mpv, "hwdec", "auto-safe");
    mpv_set_option_string(m_mpv, "vd-lavc-dr", "yes");
    mpv_set_option_string(m_mpv, "keep-open", "yes");
    mpv_set_option_string(m_mpv, "force-window", "no");
    mpv_set_option_string(m_mpv, "input-default-bindings", "no");
    mpv_set_option_string(m_mpv, "input-vo-keyboard", "no");
    mpv_set_option_string(m_mpv, "ytdl", "no");
    // 允许 mpv.conf 自定义播放器设置（免重编译调参）：
    // config-dir 指向 exe 同目录，mpv 从该目录读取 mpv.conf；
    // 禁止加载 Lua 脚本，避免第三方脚本崩进程；watch-later/缓存仍写到该目录。
    {
        QString cfgDir = QCoreApplication::applicationDirPath() + "/mpv-config";
        mpv_set_option_string(m_mpv, "config-dir", cfgDir.toUtf8().constData());
        mpv_set_option_string(m_mpv, "config", "yes");
        mpv_set_option_string(m_mpv, "load-scripts", "no");
    }
    // 让 mpv 严格按视频帧率渲染，不额外产生 60fps 重绘请求。
    mpv_set_option_string(m_mpv, "video-timing-offset", "0");
    // 以音频时钟为准进行同步
    mpv_set_option_string(m_mpv, "video-sync", "audio");
    // 帧丢弃策略：只在 VO 端丢帧（解码器不丢），降低 GPU 负载
    mpv_set_option_string(m_mpv, "framedrop", "vo");
    // 缩放/插值参数：mpv.conf（config=yes，优先级最高，会覆盖代码设置）
    // 已按用户需求启用 bilinear 系列 + dither=no；代码里保留 sigmoid/
    // correct 两项轻量化设置，其余交给 mpv.conf 管理
    //mpv_set_option_string(m_mpv, "scale", "bilinear");
    //mpv_set_option_string(m_mpv, "dscale", "bilinear");
    //mpv_set_option_string(m_mpv, "cscale", "bilinear");
    mpv_set_option_string(m_mpv, "sigmoid-upscaling", "no");
    mpv_set_option_string(m_mpv, "correct-downscaling", "no");
    //mpv_set_option_string(m_mpv, "dither", "no");
    // 缓存配置：默认按视频点播模式初始化（m_liveMode 默认 false）
    // 直播页会在 setSource 前通过 QML 设 liveMode=true 触发 applyCacheOptions() 覆盖
    applyCacheOptions();

    if (mpv_initialize(m_mpv) < 0) {
        qWarning() << "[MpvObjectD3D11] failed to initialize mpv";
        emit errorOccurred("Failed to initialize mpv");
        mpv_terminate_destroy(m_mpv);
        m_mpv = nullptr;
        return;
    }

    applyHttpHeaders();

    mpv_set_wakeup_callback(m_mpv, [](void *ctx) {
        QMetaObject::invokeMethod(static_cast<MpvObjectD3D11*>(ctx), &MpvObjectD3D11::onMpvEvents, Qt::QueuedConnection);
    }, this);

    mpv_observe_property(m_mpv, 0, "time-pos", MPV_FORMAT_DOUBLE);
    mpv_observe_property(m_mpv, 0, "duration", MPV_FORMAT_DOUBLE);
    mpv_observe_property(m_mpv, 0, "pause", MPV_FORMAT_FLAG);
    mpv_observe_property(m_mpv, 0, "speed", MPV_FORMAT_DOUBLE);
    mpv_observe_property(m_mpv, 0, "video-params", MPV_FORMAT_NODE);
    mpv_observe_property(m_mpv, 0, "seekable", MPV_FORMAT_FLAG);
    mpv_observe_property(m_mpv, 0, "hwdec-current", MPV_FORMAT_STRING);
    // 容器帧率：FramePacer 自适应心跳的输入（≥50fps 内容按需升档节奏）
    mpv_observe_property(m_mpv, 0, "container-fps", MPV_FORMAT_DOUBLE);
    // 用于计算瞬时码率
    mpv_observe_property(m_mpv, 0, "demuxer-cache-state", MPV_FORMAT_NODE);

    double vol = 100.0;
    mpv_set_property(m_mpv, "volume", MPV_FORMAT_DOUBLE, &vol);
    int pauseFlag = 1;
    mpv_set_property(m_mpv, "pause", MPV_FORMAT_FLAG, &pauseFlag);
}

void MpvObjectD3D11::applyCacheOptions()
{
    // cache 选项在 mpv_initialize 前用 mpv_set_option_string 设置；
    // initialize 后改 liveMode 不会再生效（cache-secs 等是启动期选项），
    // 但直播/视频页是不同的 MpvObject 实例，构造时 m_liveMode 已被 QML 绑定赋值，
    // 故此处按当前 m_liveMode 一次性应用即可。
    if (!m_mpv) return;
    if (m_liveMode) {
        // 直播：小 cache 低延迟，避免延迟累积（原配置）
        mpv_set_option_string(m_mpv, "cache", "yes");
        mpv_set_option_string(m_mpv, "cache-secs", "10");
        mpv_set_option_string(m_mpv, "demuxer-max-bytes", "16M");
        mpv_set_option_string(m_mpv, "demuxer-max-back-bytes", "8M");
        mpv_set_option_string(m_mpv, "demuxer-readahead-secs", "10");
        mpv_set_option_string(m_mpv, "vf", "");
    } else {
        // 视频点播：大 cache 抗网络抖动，避免 CDN 断流时 demuxer 缓存耗尽停住
        // 30s 前向 + 32M 字节上限（约 30-60s 1080p 视频数据）
        // 16M 回看缓冲（seek 后退时不需重新下载）
        mpv_set_option_string(m_mpv, "cache", "yes");
        mpv_set_option_string(m_mpv, "cache-secs", "30");
        mpv_set_option_string(m_mpv, "demuxer-max-bytes", "64M");
        mpv_set_option_string(m_mpv, "demuxer-max-back-bytes", "16M");
        mpv_set_option_string(m_mpv, "demuxer-readahead-secs", "30");
        mpv_set_option_string(m_mpv, "vf", "amf_frc");
    }
}

bool MpvObjectD3D11::liveMode() const
{
    return m_liveMode;
}

void MpvObjectD3D11::setLiveMode(bool liveMode)
{
    if (m_liveMode == liveMode) return;
    m_liveMode = liveMode;
    // 重新应用 cache 配置（仅 initialize 前有效；initialize 后此调用不会改变已生效的 cache，
    // 但保留调用以支持未来扩展，且 QML 绑定赋值发生在构造期 initMpv 之前/之后均安全）
    applyCacheOptions();
    emit liveModeChanged();
}

void MpvObjectD3D11::applyHttpHeaders()
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

QString MpvObjectD3D11::source() const
{
    return m_source;
}

void MpvObjectD3D11::setSource(const QString &source)
{
    if (m_source == source && !source.isEmpty()) return;
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

QString MpvObjectD3D11::audioSource() const
{
    return m_audioSource;
}

void MpvObjectD3D11::setAudioSource(const QString &audioSource)
{
    if (m_audioSource == audioSource) return;
    m_audioSource = audioSource;
    emit audioSourceChanged();
}

bool MpvObjectD3D11::playing() const
{
    return m_playing;
}

void MpvObjectD3D11::setPlaying(bool playing)
{
    if (!m_mpv) return;
    m_desiredPlaying = playing;
    if (m_playing == playing) return;
    const char *cmd[] = {"set", "pause", playing ? "no" : "yes", nullptr};
    mpv_command_async(m_mpv, 0, cmd);
}

int MpvObjectD3D11::position() const
{
    return m_position;
}

int MpvObjectD3D11::duration() const
{
    return m_duration;
}

qreal MpvObjectD3D11::volume() const
{
    return m_volume;
}

void MpvObjectD3D11::setVolume(qreal volume)
{
    if (!m_mpv) return;
    m_volume = qBound(0.0, volume, 1.0);
    double vol = m_volume * 100.0;
    mpv_set_property(m_mpv, "volume", MPV_FORMAT_DOUBLE, &vol);
    emit volumeChanged();
}

qreal MpvObjectD3D11::speed() const
{
    return m_speed;
}

void MpvObjectD3D11::setSpeed(qreal speed)
{
    if (!m_mpv) return;
    speed = qBound(0.25, speed, 4.0);
    if (qFuzzyCompare(m_speed, speed)) return;
    m_speed = speed;
    double s = speed;
    mpv_set_property(m_mpv, "speed", MPV_FORMAT_DOUBLE, &s);
    emit speedChanged();
}

bool MpvObjectD3D11::hasVideo() const
{
    return m_hasVideo;
}

bool MpvObjectD3D11::seekable() const
{
    return m_seekable;
}

void MpvObjectD3D11::itemChange(ItemChange change, const ItemChangeData &value)
{
    if (change == ItemSceneChange) {
        QQuickWindow *newWindow = value.window;
        qWarning() << "[MpvObjectD3D11] ItemSceneChange old:" << m_window << "new:" << newWindow;
        if (newWindow != m_window) {
            QQuickWindow *oldWindow = m_window;
            if (oldWindow) {
                disconnect(oldWindow, &QQuickWindow::frameSwapped, this, nullptr);
            }

            m_window = newWindow;

            // 跨窗口迁移判定（小窗播放）。Qt 6 的 setParentItem 跨窗口流程
            // （qquickitem.cpp）：先把 parentItem 更新为新父项，再 derefWindow
            // （itemChange 收到 nullptr），最后 refWindow（收到新窗口）。因此
            // nullptr 事件里 parentItem 已指向目标窗口中的新父项——以此区分
            // "迁移中转"与"彻底离开场景"。真删除/销毁时，祖先链的 derefWindow
            // 递归已把父项的 window 置空（或 parentItem 本身为 null）。
            const bool migrating = !newWindow && parentItem() && parentItem()->window();

            // 关键修复：item 从场景移除（Loader 销毁 / 窗口关闭）时，
            // oldWindow 通常仍存活——此时必须通过 scheduleRenderJob 把 QSG 资源
            // 交给渲染线程释放。否则析构函数会走"窗口已死"分支，只 Release D3D11
            // 原生资源而漏 delete QSGTexture/QRhiTexture，导致每次关直播都泄漏
            // 场景图包装对象（累积表现为进程堆内存持续上涨）。
            // 迁移中转（migrating）不走此路径——mpv 继续存活，见下方迁移分支。
            if (!newWindow && oldWindow && !migrating) {
                qWarning() << "[MpvObjectD3D11] item removed from scene, releasing QSG resources";
                m_shuttingDown.store(true, std::memory_order_release);
                stopRenderTimer();

                // 关键修复：全部资源统一移交给渲染线程 job 释放。
                //
                // 之前的分工是"渲染线程 job 释放 QSG/stale 纹理、析构函数 direct
                // release mpv/当前纹理/device"，存在跨线程释放顺序竞态：
                //   scheduleRenderJob 的 job 只在窗口渲染下一帧时执行。若关直播后
                //   窗口被其他软件遮挡（停止渲染），job 会积压；而 GUI 线程已把
                //   device Release。切回窗口恢复渲染时，job 里 delete QSGTexture
                //   （Vulkan 侧 D3D11 interop 外部内存）与已销毁 device 产生驱动级
                //   竞争 → 渲染线程在内核调用上挂死 → 全进程无响应。
                // 统一移交渲染线程后，所有释放按 FIFO 单线程按序执行，无竞态。
                //
                // 注意：若窗口持续不渲染，job 会推迟执行（mpv 实例暂存），但释放
                // 顺序绝对安全；窗口销毁时 Qt 会 drain 未执行的 render job。
                if (m_qsgTexture || !m_staleTextures.isEmpty() || m_mpv || m_mpvRender
                    || m_d3d11Texture || m_d3d11Device) {
                    // 禁用 wakeup 回调，避免 job 释放 mpv 期间回调再进来
                    if (m_mpv) {
                        mpv_set_wakeup_callback(m_mpv, nullptr, nullptr);
                    }

                    struct FullCleanupJob : public QRunnable {
                        mpv_handle *mpv = nullptr;
                        mpv_render_context *mpvRender = nullptr;
                        ID3D11Device *device = nullptr;
                        QSGTexture *qsgTex = nullptr;
                        ID3D11Texture2D *d3d11Tex = nullptr;
                        QList<StaleTextureSet> staleTextures;
                        void run() override {
                            QElapsedTimer t;
                            t.start();
                            // 释放顺序与原析构 direct release 一致：
                            // mpv render context → mpv → 当前 D3D11 纹理 → stale 纹理 → device。
                            // QSGTexture 晚于 mpv/D3D11 释放（Vulkan interop 包装对象
                            // 只引用指针不持有 COM 引用，先后均可，但保持固定顺序便于排查）。
                            if (mpvRender) {
#ifdef _MSC_VER
                                __try { mpv_render_context_free(mpvRender); }
                                __except (EXCEPTION_EXECUTE_HANDLER) {}
#else
                                mpv_render_context_free(mpvRender);
#endif
                            }
                            if (mpv) {
#ifdef _MSC_VER
                                __try { mpv_terminate_destroy(mpv); }
                                __except (EXCEPTION_EXECUTE_HANDLER) {}
#else
                                mpv_terminate_destroy(mpv);
#endif
                            }
                            // createTextureFromRhiTexture() 把 QRhiTexture 所有权转移给
                            // QSGTexture，delete QSGTexture 会连带释放 QRhiTexture。
                            if (qsgTex) delete qsgTex;
                            if (d3d11Tex) {
#ifdef _MSC_VER
                                __try { d3d11Tex->Release(); }
                                __except (EXCEPTION_EXECUTE_HANDLER) {}
#else
                                d3d11Tex->Release();
#endif
                            }
                            for (const StaleTextureSet &set : staleTextures) {
                                if (set.qsgTex) delete set.qsgTex;
                                if (set.d3d11Tex) {
#ifdef _MSC_VER
                                    __try { set.d3d11Tex->Release(); }
                                    __except (EXCEPTION_EXECUTE_HANDLER) {}
#else
                                    set.d3d11Tex->Release();
#endif
                                }
                            }
                            if (device) {
#ifdef _MSC_VER
                                __try { device->Release(); }
                                __except (EXCEPTION_EXECUTE_HANDLER) {}
#else
                                device->Release();
#endif
                            }
                            qWarning() << "[MpvObjectD3D11] full cleanup job done in"
                                       << t.elapsed() << "ms";
                        }
                    };
                    auto *job = new FullCleanupJob();
                    job->mpv = m_mpv;
                    job->mpvRender = m_mpvRender;
                    job->device = m_d3d11Device;
                    job->qsgTex = m_qsgTexture;
                    job->d3d11Tex = m_d3d11Texture;
                    job->staleTextures = m_staleTextures;
                    oldWindow->scheduleRenderJob(job, QQuickWindow::BeforeSynchronizingStage);

                    // 所有权已全部转移给 job，清空指针并标记，
                    // 析构函数据此跳过 direct release
                    m_mpv = nullptr;
                    m_mpvRender = nullptr;
                    m_d3d11Device = nullptr;
                    m_qsgTexture = nullptr;
                    m_qrhiTexture = nullptr;  // 所有权已随 QSGTexture 转移给 job
                    m_d3d11Texture = nullptr;
                    m_staleTextures.clear();
                    m_fullCleanupScheduled = true;
                }
            }

            // 跨窗口迁移（旧/新窗口都存活，如小窗播放），在 nullptr 中转事件里
            // 处理（Qt 6 源码确认此时 oldWindow 信息只在此刻可用）：
            //  1. QSG/QRhi 纹理绑定旧窗口场景图（各窗口独立 QRhi/D3D11 设备），
            //     交旧窗口渲染线程 job 释放（BeforeSynchronizingStage job 在旧窗口
            //     下一次 sync 的 cleanupNodes 删节点树之前执行，顺序安全）；
            //  2. m_d3d11Device 取自旧窗口 QRhi 的原生设备（ensureD3D11Resources
            //     里 AddRef），D3D11 不支持跨设备纹理引用——mpv 渲染上下文与
            //     D3D11 纹理必须整体释放。mpv 核心不受影响（音频连续、进度不丢），
            //     抵达新窗口后由 ensureD3D11Resources 的懒重建路径用新设备重建
            //     渲染上下文与纹理。mpv_render_context_free 在 GUI 线程调用安全：
            //     QSG sync 阶段会阻塞 GUI 线程，此刻旧窗口渲染线程必不在
            //     renderMpv 中（与析构函数同模式）。D3D11 Release 线程安全
            //     （运行时对在用资源延迟实际销毁）。
            if (migrating && oldWindow) {
                if (m_mpvRender) {
                    mpv_render_context_free(m_mpvRender);
                    m_mpvRender = nullptr;
                    // mpv_render_context_free 内部 kill_video_async 已销毁 VO+解码链，
                    // 重建渲染上下文不会自动恢复——标记待新上下文创建后重选视频轨
                    m_videoReinitPending = true;
                }
                QList<QSGTexture *> oldQsg;
                if (m_qsgTexture)
                    oldQsg.append(m_qsgTexture);
                for (auto &set : m_staleTextures) {
                    if (set.qsgTex) {
                        oldQsg.append(set.qsgTex);
                        set.qsgTex = nullptr;     // 已移交旧窗口 job，后续路径跳过
                        set.qrhiTex = nullptr;   // 所有权随 QSGTexture 走
                    }
                }
                if (!oldQsg.isEmpty()) {
                    struct QsgReleaseJob : public QRunnable {
                        QList<QSGTexture *> textures;
                        void run() override { for (QSGTexture *t : textures) delete t; }
                    };
                    auto *job = new QsgReleaseJob;
                    job->textures = oldQsg;
                    oldWindow->scheduleRenderJob(job, QQuickWindow::BeforeSynchronizingStage);
                }
                m_qsgTexture = nullptr;
                m_qrhiTexture = nullptr;
                if (m_d3d11Texture) {
                    m_d3d11Texture->Release();
                    m_d3d11Texture = nullptr;
                }
                for (auto &set : m_staleTextures) {
                    if (set.d3d11Tex) {
                        set.d3d11Tex->Release();
                        set.d3d11Tex = nullptr;
                    }
                }
                if (m_d3d11Device) {
                    m_d3d11Device->Release();   // 释放对旧窗口 QRhi 设备的 AddRef
                    m_d3d11Device = nullptr;
                }
                m_textureSize = QSize();
                m_resourcesDirty = true;   // 新窗口 updatePaintNode 全量重建
                qWarning() << "[MpvObjectD3D11] cross-window migration: resources released,"
                           << "will rebuild on arrival window";
            }

            if (m_window) {
                // 如果是从销毁恢复（不常见），重置关闭状态
                if (oldWindow && !newWindow) {
                    qWarning() << "[MpvObjectD3D11] window restored, resetting state";
                    m_shuttingDown.store(false, std::memory_order_release);
                }

                // 关键修复：连接 frameSwapped 信号。
                // frameSwapped 在渲染线程上（vsync 时）发射，用它来驱动渲染
                // 可以完全绕过 GUI 线程的繁忙事件循环，确保每帧都能按时渲染。
                // 渲染流程：
                //   1. mpv 产生新帧 -> callback 设置 m_framePending = true
                //   2. 下一帧 vsync -> frameSwapped 触发 -> 检查 m_framePending
                //   3. 如果有新帧 -> 调用 update() -> updatePaintNode -> renderMpv()
                //   4. 如果没有新帧 -> 跳过（不消耗 GPU）
                // 高刷屏节流模式（Phase 2）：常规帧交付改由 FramePacer 统一
                // 心跳驱动（mpv 回调 poke），此链的 framePending 驱动门控休眠，
                // 防止两条链相位交错把整窗合成率抬回刷新率；m_videoReinitPending
                // 兜底路径不受门控影响（隐藏窗口的上下文重建依赖持续 update）
                m_window->connect(m_window, &QQuickWindow::frameSwapped, this, [this]() {
                    // m_videoReinitPending 期间持续驱动 update()：迁移中转时抵达
                    // 窗口可能隐藏（退出小窗场景），itemChange 里的 update() 请求
                    // 会被渲染循环丢弃（未暴露窗口不渲染）。窗口恢复渲染的每一帧
                    // 都重发 update 请求，确保 updatePaintNode→ensureD3D11Resources
                    // 必定执行、渲染上下文在新窗口重建。
                    if (m_shuttingDown.load(std::memory_order_acquire))
                        return;
                    if (m_videoReinitPending) {
                        update();
                        return;
                    }
                    if (!FramePacer::instance()->active()
                        && m_framePending.load(std::memory_order_acquire)) {
                        update();
                    }
                });
                m_resourcesDirty = true;
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

void MpvObjectD3D11::geometryChange(const QRectF &newGeometry, const QRectF &oldGeometry)
{
    // 窗口尺寸变化时标记纹理需要重建：纹理会按新窗口显示尺寸重新创建，
    // 避免窗口变化后仍使用超大纹理造成 GPU 浪费。
    if (qAbs(newGeometry.width() - oldGeometry.width()) > 0.5
        || qAbs(newGeometry.height() - oldGeometry.height()) > 0.5) {
        m_resourcesDirty = true;
        update();
    }
    QQuickItem::geometryChange(newGeometry, oldGeometry);
}

void MpvObjectD3D11::play()
{
    setPlaying(true);
}

void MpvObjectD3D11::pause()
{
    setPlaying(false);
}

void MpvObjectD3D11::stop()
{
    if (!m_mpv) return;
    const char *pauseCmd[] = {"set", "pause", "yes", nullptr};
    mpv_command_async(m_mpv, 0, pauseCmd);
    const char *cmd[] = {"stop", nullptr};
    mpv_command_async(m_mpv, 0, cmd);
}

void MpvObjectD3D11::seek(int position)
{
    if (!m_mpv || !m_seekable) return;
    QByteArray posStr = QByteArray::number(position / 1000.0, 'f', 3);
    const char *cmd[] = {"seek", posStr.constData(), "absolute+exact", nullptr};
    mpv_command_async(m_mpv, 0, cmd);
}

void MpvObjectD3D11::updatePosition()
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

void MpvObjectD3D11::loadFile(const QString &file)
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

QVariantMap MpvObjectD3D11::getVideoInfo()
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

void MpvObjectD3D11::onMpvEvents()
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
                    // 信号节流（属性本体每次都更新，仅限制 emit 频率）：
                    // >1s 跳变（seek/切 P-位）立即放行保证 UI 响应
                    const bool jump = qAbs(newPos - m_position) > 1000;
                    m_position = newPos;
                    const qint64 nowMs = m_posThrottleClock.elapsed();
                    if (jump || m_lastPosEmitMs < 0
                            || nowMs - m_lastPosEmitMs >= 200) {
                        m_lastPosEmitMs = nowMs;
                        emit positionChanged();
                    }
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
                    // 暂停时停止备份定时器，恢复时启动
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
            } else if (strcmp(prop->name, "container-fps") == 0 && prop->format == MPV_FORMAT_DOUBLE) {
                // 自适应心跳输入：高帧率内容（≥50fps）在高刷屏上按需升档，
                // 保证视频帧不被 60fps 节奏饿死；换文件/卸载时 fps 回 0
                double fps = *static_cast<double*>(prop->data);
                FramePacer::instance()->setVideoFps(
                    (fps > 0.0 && fps < 1000.0) ? fps : 0.0);
            } else if (strcmp(prop->name, "video-params") == 0) {
                bool hasVideo = (prop->format == MPV_FORMAT_NODE);
                if (m_hasVideo != hasVideo) {
                    m_hasVideo = hasVideo;
                    emit hasVideoChanged();
                }
                // Extract video display resolution to size the D3D11 texture.
                // This avoids mpv doing per-frame scaling to window size.
                // 竖屏直播流常带旋转 metadata（编码 w/h 为横、rot=90）：
                // 必须取 dw/dh（旋转后的显示分辨率）建纹理，否则竖屏流
                // 会建出横纹理，mpv 渲染 letterbox 走歪（非常规路径）。
                if (hasVideo) {
                    mpv_node *node = static_cast<mpv_node*>(prop->data);
                    if (node && node->format == MPV_FORMAT_NODE_MAP) {
                        mpv_node_list *list = node->u.list;
                        int vw = 0, vh = 0, dw = 0, dh = 0;
                        for (int i = 0; i < list->num; ++i) {
                            const char *key = list->keys[i];
                            if (strcmp(key, "w") == 0 && list->values[i].format == MPV_FORMAT_INT64) {
                                vw = static_cast<int>(list->values[i].u.int64);
                            } else if (strcmp(key, "h") == 0 && list->values[i].format == MPV_FORMAT_INT64) {
                                vh = static_cast<int>(list->values[i].u.int64);
                            } else if (strcmp(key, "dw") == 0 && list->values[i].format == MPV_FORMAT_INT64) {
                                dw = static_cast<int>(list->values[i].u.int64);
                            } else if (strcmp(key, "dh") == 0 && list->values[i].format == MPV_FORMAT_INT64) {
                                dh = static_cast<int>(list->values[i].u.int64);
                            }
                        }
                        // 优先显示分辨率（dw/dh 含旋转），回退编码分辨率
                        int texW = (dw > 0) ? dw : vw;
                        int texH = (dh > 0) ? dh : vh;
                        if (texW > 0 && texH > 0
                            && (texW != m_videoWidth.load(std::memory_order_acquire)
                                || texH != m_videoHeight.load(std::memory_order_acquire))) {
                            m_videoWidth.store(texW, std::memory_order_release);
                            m_videoHeight.store(texH, std::memory_order_release);
                            m_resourcesDirty = true;
                            qWarning() << "[MpvObjectD3D11] video native resolution:" << texW << "x" << texH
                                       << "(coded" << vw << "x" << vh << "display" << dw << "x" << dh << ")";
                        }
                    }
                }
            } else if (strcmp(prop->name, "seekable") == 0 && prop->format == MPV_FORMAT_FLAG) {
                bool seekable = *static_cast<int*>(prop->data) != 0;
                if (m_seekable != seekable) {
                    m_seekable = seekable;
                    emit seekableChanged();
                }
            } else if (strcmp(prop->name, "hwdec-current") == 0 && prop->format == MPV_FORMAT_STRING) {
                char *hw = *static_cast<char**>(prop->data);
                qWarning() << "[MpvObjectD3D11] hwdec-current:" << (hw ? QString::fromUtf8(hw) : QString("none"));
            }
            break;
        }
        case MPV_EVENT_FILE_LOADED: {
            // 直播绿屏/雪花问题确诊日志：流的编码格式与硬解方法。
            // 已知 case：个别直播间（高清晰度）全屏绿屏+顶部雪花，调低
            // 清晰度恢复，其他 mpv 客户端正常——嫌疑 D3D11 零拷贝互操作
            // 对特定编码（HEVC/特殊 profile）的兼容性，此日志用于锁定
            char *vfmt = mpv_get_property_string(m_mpv, "video-format");
            char *vcodec = mpv_get_property_string(m_mpv, "video-codec");
            char *hwcur = mpv_get_property_string(m_mpv, "hwdec-current");
            qWarning() << "[MpvObjectD3D11] file loaded, video-format:" << (vfmt ? vfmt : "?")
                       << "video-codec:" << (vcodec ? vcodec : "?")
                       << "hwdec-current:" << (hwcur ? hwcur : "none");
            mpv_free(vfmt);
            mpv_free(vcodec);
            mpv_free(hwcur);
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
            emit fileLoaded();
            break;
        }
        case MPV_EVENT_END_FILE: {
            mpv_event_end_file *ef = static_cast<mpv_event_end_file*>(event->data);
            if (ef && ef->reason == MPV_END_FILE_REASON_ERROR) {
                QString err = QString::fromUtf8(mpv_error_string(ef->error));
                qWarning() << "[MpvObjectD3D11] playback error:" << err;
                emit errorOccurred(err);
            }
            break;
        }
        default:
            break;
        }
    }
}

void MpvObjectD3D11::startRenderTimer()
{
    if (!m_renderTimer) return;
    // 备份定时器只在播放时运行。暂停时不需要检查帧，
    // 可以减少不必要的唤醒和 DWM 合成开销。
    if (m_window && isVisible() && !m_paused && !m_renderTimer->isActive()) {
        m_renderTimer->start();
    }
}

void MpvObjectD3D11::stopRenderTimer()
{
    if (m_renderTimer && m_renderTimer->isActive()) {
        m_renderTimer->stop();
    }
}

bool MpvObjectD3D11::ensureD3D11Resources()
{
    if (!m_window) {
        return false;
    }

    QRhi *rhi = m_window->rhi();
    if (!rhi || rhi->backend() != QRhi::D3D11) {
        qWarning() << "[MpvObjectD3D11] Qt RHI backend is not D3D11:" << (rhi ? rhi->backend() : -1);
        return false;
    }

    if (!m_d3d11Device) {
        auto *nativeHandles = static_cast<const QRhiD3D11NativeHandles *>(rhi->nativeHandles());
        if (!nativeHandles || !nativeHandles->dev) {
            qWarning() << "[MpvObjectD3D11] failed to get D3D11 device from QRhi";
            return false;
        }
        m_d3d11Device = static_cast<ID3D11Device *>(nativeHandles->dev);
        m_d3d11Device->AddRef();
    }

    // === 纹理尺寸策略 ===
    // 纹理尺寸取视频原始分辨率与窗口实际物理像素尺寸中较小的一个。
    // 经测试：mpv 内部下采样（渲染到较小的纹理）比 QSG/DWM 缩放更省 GPU。
    qreal dpr = m_window->effectiveDevicePixelRatio();
    int winW = qMax(1, static_cast<int>(width() * dpr));
    int winH = qMax(1, static_cast<int>(height() * dpr));
    int vw = m_videoWidth.load(std::memory_order_acquire);
    int vh = m_videoHeight.load(std::memory_order_acquire);
    QSize size;
    if (vw > 0 && vh > 0) {
        // 保持视频宽高比，取 min(视频, 窗口)
        int targetW = qMin(vw, winW);
        int targetH = qMin(vh, winH);
        double vRatio = double(vw) / double(vh);
        double tRatio = double(targetW) / double(targetH);
        if (vRatio > tRatio) {
            targetH = qMax(1, int(targetW / vRatio));
        } else {
            targetW = qMax(1, int(targetH * vRatio));
        }
        size = QSize(targetW, targetH);
    } else {
        size = QSize(winW, winH);
    }
    if (size.width() <= 0 || size.height() <= 0) {
        return false;
    }

    if (m_resourcesDirty || m_textureSize != size || !m_d3d11Texture) {
        // Keep the old textures alive in m_staleTextures instead of releasing
        // them immediately. The D3D11 driver / Qt scene graph can still hold
        // references to the underlying GPU resources across multiple frames,
        // and releasing them during resize causes access-violation crashes.
        // They will be freed together with mpv in the destructor's cleanup job.

        // Keep old QSGTexture alive as fallback — don't null it out until
        // we've created and rendered into the new texture. This prevents the
        // black flicker during resize when paused.
        QSGTexture *oldQsgTex = m_qsgTexture;
        QRhiTexture *oldQrhiTex = m_qrhiTexture;
        ID3D11Texture2D *oldD3d11Tex = m_d3d11Texture;

        if (oldQsgTex || oldQrhiTex || oldD3d11Tex) {
            // 限制 stale 纹理数量，防止快速切换房间/尺寸时 GPU 资源累积。
            // 超过数量时直接释放最老的一组，而不是无限保留。
            while (m_staleTextures.size() >= 4) {
                StaleTextureSet old = m_staleTextures.takeFirst();
                if (old.qsgTex) {
                    delete old.qsgTex;
                    old.qsgTex = nullptr;
                }
                if (old.d3d11Tex) {
                    old.d3d11Tex->Release();
                    old.d3d11Tex = nullptr;
                }
            }
            m_staleTextures.append({oldQsgTex, oldQrhiTex, oldD3d11Tex});
        }

        m_qsgTexture = nullptr;
        m_qrhiTexture = nullptr;
        m_d3d11Texture = nullptr;
        m_resourcesDirty = false;

        D3D11_TEXTURE2D_DESC desc = {};
        desc.Width = static_cast<UINT>(size.width());
        desc.Height = static_cast<UINT>(size.height());
        desc.MipLevels = 1;
        desc.ArraySize = 1;
        desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        desc.SampleDesc.Count = 1;
        desc.Usage = D3D11_USAGE_DEFAULT;
        // mpv 的 D3D11 render API 会直接写入该纹理作为 back_buffer，
        // 同时我们需要把它作为 shader resource 采样显示到 QSG。
        desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;

        HRESULT hr = m_d3d11Device->CreateTexture2D(&desc, nullptr, &m_d3d11Texture);
        if (FAILED(hr)) {
            qWarning() << "[MpvObjectD3D11] failed to create D3D11 texture, hr:" << hr;
            // Try to restore the most recent stale set so the next frame can
            // still render at the previous size instead of leaving black.
            if (!m_staleTextures.isEmpty()) {
                StaleTextureSet last = m_staleTextures.takeLast();
                m_qsgTexture = last.qsgTex;
                m_qrhiTexture = last.qrhiTex;
                m_d3d11Texture = last.d3d11Tex;
            }
            return false;
        }

        // New texture created successfully: commit the new size.
        m_textureSize = size;
        // 关键修复：资源重建后立即标记需要渲染，避免暂停时显示黑屏。
        // mpv 即使在暂停时也会渲染最后一帧到新纹理。
        m_framePending.store(true, std::memory_order_release);
    }

    if (!m_mpvRender) {
        mpv_d3d11_init_params d3d11Init;
        d3d11Init.device = m_d3d11Device;

        // 不启用 MPV_RENDER_PARAM_ADVANCED_CONTROL。
        // 高级控制模式要求宿主处理额外的渲染步骤，我们不需要 OSD/字幕等
        // 高级功能，禁用后 mpv 走更轻量的内部渲染路径。
        mpv_render_param params[] = {
            {MPV_RENDER_PARAM_API_TYPE, const_cast<char*>(MPV_RENDER_API_TYPE_D3D11)},
            {static_cast<mpv_render_param_type>(MPV_RENDER_PARAM_D3D11_INIT_PARAMS), &d3d11Init},
            {MPV_RENDER_PARAM_INVALID, nullptr}
        };

        int ret = mpv_render_context_create(&m_mpvRender, m_mpv, params);
        if (ret < 0) {
            qWarning() << "[MpvObjectD3D11] failed to create mpv D3D11 render context:" << mpv_error_string(ret)
                       << "(mpv D3D11 render API requires libmpv >= 2026-04 PR #17764)";
            return false;
        }
        // mpv 每产生一帧就会触发该回调。这里只设置 m_framePending 标记。
        // 真正的渲染由 frameSwapped 驱动（在渲染线程上，60fps vsync），
        // 它会检查 m_framePending 并调用 update()。
        // 这样就完全绕过了 GUI 线程的繁忙事件循环，确保帧的稳定交付。
        // Phase 2（高刷屏节流）：帧显示时机交给 FramePacer 统一心跳——
        // poke 唤醒后由 tick 在网格边界消费 m_framePending。渲染线程
        // （frameSwapped 链）与 GUI 线程（备份定时器）的直接驱动均已按
        // pacer 激活状态门控，视频与弹幕两条链合并为同一节奏，消除
        // 相位交错导致的合成率抬升。60Hz 屏上 pacer 不激活，保留原路径
        mpv_render_context_set_update_callback(m_mpvRender, [](void *ctx) {
            auto *self = static_cast<MpvObjectD3D11 *>(ctx);
            self->m_framePending.store(true, std::memory_order_release);
            // poke 线程安全（内部转排队），唤醒统一心跳
            FramePacer::instance()->poke();
            // 直接通过 QueuedConnection 调用 update()，打破对 frameSwapped 的循环依赖。
            // 这样即使 _renderDriver 停止（无弹幕时 QSG 退回 timer mode），
            // mpv 新帧仍能触发 QSG 渲染，避免卡顿。
            QMetaObject::invokeMethod(self, [self]() {
                if (!self->m_shuttingDown.load(std::memory_order_acquire)
                    && !FramePacer::instance()->active()) {
                    self->update();
                }
            }, Qt::QueuedConnection);
        }, this);

        // 跨窗口迁移恢复：旧渲染上下文释放时 mpv 已销毁 VO+解码链
        // （kill_video_async），mpv_render_context_create 不会自动重新挂接
        // 视频链（vo_libmpv.c 的 create 无 reinit 逻辑）。在 GUI 线程重选
        // 视频轨道（vid no→auto）触发 reinit_video_chain，视频画面在新窗口
        // 恢复（否则黑屏、仅音频）。mpv_command 非渲染线程安全，必须
        // QueuedConnection 回 GUI 线程执行（本函数运行在渲染线程 sync 阶段）。
        if (m_videoReinitPending) {
            m_videoReinitPending = false;
            QMetaObject::invokeMethod(this, [this]() {
                reinitVideoChain();
                // 延迟校验重试：kill_video_async 异步于 mpv 核心线程执行，若其
                // 完成时机晚于上面的重选（抵达窗口首帧很快时会发生竞争），
                // 重建的视频链会被迟到的销毁再次杀死→黑屏。500ms 后校验
                // video-params，死链则重选（此时 kill 必已完成），最多 3 次。
                // QTimer 在 GUI 线程内创建（本 lambda 已回到 GUI 线程）。
                QTimer::singleShot(500, this, [this]() {
                    verifyVideoChainAlive(3);
                });
            }, Qt::QueuedConnection);
        }
    }

    return true;
}

void MpvObjectD3D11::renderMpv()
{
    if (!m_mpvRender || !m_d3d11Texture) {
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

void MpvObjectD3D11::reinitVideoChain()
{
    if (!m_mpv || m_shuttingDown.load(std::memory_order_acquire))
        return;
    // vid no→auto 重选视频轨，强制 mpv 以当前（新窗口）渲染上下文重建
    // VO+解码链。两条命令异步提交给核心按序执行。
    const char *vidOff[] = {"set", "vid", "no", nullptr};
    mpv_command_async(m_mpv, 0, vidOff);
    const char *vidOn[] = {"set", "vid", "auto", nullptr};
    mpv_command_async(m_mpv, 0, vidOn);
    qWarning() << "[MpvObjectD3D11] video track reselected (vid no->auto) to"
               << "reinit video chain after render context recreation";
}

void MpvObjectD3D11::verifyVideoChainAlive(int attempts)
{
    // 渲染上下文尚未重建（迁移中转/校验期间再次迁移）：交给抵达窗口的
    // ensureD3D11Resources 重建路径，不在此干预
    if (!m_mpv || !m_mpvRender || m_shuttingDown.load(std::memory_order_acquire)
        || attempts <= 0) {
        return;
    }
    // video-params 仅在 VO 链存活时有效（暂停时同样有效，不依赖新帧）
    int64_t vw = 0;
    const int err = mpv_get_property(m_mpv, "video-params/w", MPV_FORMAT_INT64, &vw);
    const bool alive = (err >= 0 && vw > 0);
    qWarning() << "[MpvObjectD3D11] verify video chain after migration: alive =" << alive
               << "attempts left =" << attempts;
    if (!alive) {
        reinitVideoChain();
        QTimer::singleShot(500, this, [this, attempts]() {
            verifyVideoChainAlive(attempts - 1);
        });
    } else {
        // 迁移恢复完成：视频链存活，通知 QML 层恢复播放
        // （迁移期间整体暂停，音频视频同停同续，保证音画不错位）
        emit videoChainRestored();
    }
}

void MpvObjectD3D11::updateQSGTexture()
{
    if (!m_window || !m_d3d11Texture) {
        return;
    }

    // QSGTexture 在底层 D3D11 纹理不变时可以复用，避免每帧重建带来的开销。
    if (m_qsgTexture) {
        return;
    }

    QRhi *rhi = m_window->rhi();
    if (!rhi) {
        return;
    }

    // createTextureFromRhiTexture() takes ownership of the QRhiTexture and
    // will delete it when the QSGTexture is destroyed. Therefore we create a
    // local QRhiTexture here and only store the pointer after ownership has
    // been successfully transferred.
    if (!m_qsgTexture) {
        QRhiTexture *qrhiTex = rhi->newTexture(QRhiTexture::RGBA8, m_textureSize, 1, QRhiTexture::Flags{});
        if (!qrhiTex) {
            qWarning() << "[MpvObjectD3D11] failed to create QRhiTexture";
            return;
        }
        QRhiTexture::NativeTexture src;
        src.object = reinterpret_cast<quint64>(m_d3d11Texture);
        src.layout = 0;
        if (!qrhiTex->createFrom(src)) {
            qWarning() << "[MpvObjectD3D11] failed to import D3D11 texture into QRhiTexture";
            delete qrhiTex;
            return;
        }

        m_qsgTexture = m_window->createTextureFromRhiTexture(qrhiTex, QQuickWindow::TextureHasAlphaChannel);
        if (!m_qsgTexture) {
            qWarning() << "[MpvObjectD3D11] failed to create QSGTexture from QRhiTexture";
            delete qrhiTex;
            return;
        }

        // Ownership transferred to QSGTexture. Keep the pointer for tracking
        // but never delete it directly.
        m_qrhiTexture = qrhiTex;
    }
}

QSGNode *MpvObjectD3D11::updatePaintNode(QSGNode *oldNode, UpdatePaintNodeData *)
{
    // Return early during shutdown — the destructor is waiting for this mutex.
    if (m_shuttingDown.load(std::memory_order_acquire)) {
        return oldNode;
    }

    QMutexLocker locker(&m_renderMutex);

    if (!m_mpv || m_shuttingDown.load(std::memory_order_acquire)) {
        return oldNode;
    }

    if (!ensureD3D11Resources()) {
        return oldNode;
    }

    // Render mpv only when it reports a new video frame.
    if (m_framePending.exchange(false, std::memory_order_acq_rel)) {
        renderMpv();
    }
    updateQSGTexture();

    QSGSimpleTextureNode *node = static_cast<QSGSimpleTextureNode *>(oldNode);
    if (!node) {
        node = new QSGSimpleTextureNode();
    }

    if (m_qsgTexture) {
        node->setTexture(m_qsgTexture);

        // renderRect 使用逻辑像素坐标。
        // QSGSimpleTextureNode::setRect() 接受 QML 场景坐标（逻辑像素），
        // 纹理本身已是设备像素分辨率（在 ensureD3D11Resources 中按 width()*dpr 创建），
        // QSG 渲染时会自动将纹理从设备像素映射到物理帧缓冲，无需在此手动乘 DPR。
        // 之前误用设备像素导致高分屏（如 150% 缩放）下渲染区域超出 Item 边界，
        // 视频只显示放大后的一小块。
        double iw = width();
        double ih = height();
        int texW = m_textureSize.width();
        int texH = m_textureSize.height();

        QRectF renderRect(0, 0, iw, ih);
        if (texW > 0 && texH > 0 && iw > 0 && ih > 0) {
            double videoRatio = double(texW) / double(texH);
            double itemRatio = iw / ih;
            if (videoRatio > itemRatio) {
                double newH = iw / videoRatio;
                double y = (ih - newH) / 2.0;
                renderRect = QRectF(0, y, iw, newH);
            } else {
                double newW = ih * videoRatio;
                double x = (iw - newW) / 2.0;
                renderRect = QRectF(x, 0, newW, ih);
            }
        }

        static int frameCount = 0;
        if ((frameCount++ % 60) == 0) {
            qDebug() << "[MpvObjectD3D11] item:" << width() << "x" << height()
                     << "dpr:" << m_window->effectiveDevicePixelRatio()
                     << "texture:" << texW << "x" << texH
                     << "renderRect:" << renderRect;
        }

        node->setRect(renderRect);
        node->setFiltering(QSGTexture::Linear);
    }

    return node;
}
