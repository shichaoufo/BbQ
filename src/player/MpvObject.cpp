#include "MpvObject.h"

#include "LoginManager.h"
#include <QDebug>
#include <QQuickWindow>
#include <QOpenGLContext>
#include <QOpenGLFramebufferObject>
#include <QOpenGLFunctions>
#include <QVariantMap>

#include <clocale>

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

            // 本次确实free 掉了一个已建立的 render context。
            // mpv_render_context_free() 内部 kill_video_async 会销毁
            // VO+解码链，而后续的 mpv_render_context_create() 不会自动
            // 重新挂接（vo_libmpv.c 无 reinit 逻辑）→ 需要重选视频轨。
            // 置位"曾 free 过"标志；createFramebufferObject() 里据此决定
            // 是否要重选视频链（首次创建时无此需求，必须跳过）。
            if (m_item) {
                m_item->m_renderContextFreed.store(true, std::memory_order_release);
            }
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

                // 只有"此前确实 free 过一个已建立的 render context"才需要
                // 重建视频链。首次创建走这里**不能**置位——此刻 mpv 里
                // 尚未 loadfile（setSource 还没调），video-params 必然取不到，
                // verifyVideoChainAlive 会判定死链并下发一次 vid no→auto，
                // 结果是刚起播就被无端重选视频轨（首帧闪黑 + 起播延迟）。
                // 这正是 Windows 版用 migrating && oldWindow 双重守卫挡掉的。
                bool wasFreed = m_item
                    && m_item->m_renderContextFreed.exchange(false, std::memory_order_acq_rel);
                // 另加"确实加载了文件"这一必要条件：没有文件就没有视频链，
                // 重选只会把 vid 打成 no 造成不必要的状态抖动。
                if (wasFreed && m_item && !m_item->m_source.isEmpty()) {
                    m_item->m_videoReinitPending.store(true, std::memory_order_release);
                }
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
    connect(m_renderTimer, &QTimer::timeout, this, [this]() {
        // 消费渲染线程置位的"渲染上下文已重建、需要重选视频轨"标记。
        // 置位者是 MpvRenderer::createFramebufferObject（渲染线程），
        // 消费放在 GUI 线程的定时器里，保证 mpv 命令与信号 emit 都在
        // 正确的线程上（mpv 命令本身线程安全，但 QML 信号必须 GUI 线程）。
        if (m_videoReinitPending.exchange(false, std::memory_order_acq_rel)) {
            verifyVideoChainAlive(3);
        }
        update();
    });
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
    // libmpv 硬性要求 LC_NUMERIC 为 "C"：它内部的数值解析（含 ffmpeg 依赖的
    // Chromium base）在非 C locale 下会直接拒绝初始化，mpv_create() 返回
    // nullptr。症状是日志里先出现
    //   Non-C locale detected. This is not supported.
    // 再出现 [MpvObject] failed to create mpv context，随后播放页空白并闪退。
    //
    // 为什么 Windows 上没事：MSVC 运行时默认就是 C locale，用户改系统语言
    // 也不影响 LC_NUMERIC。而 Linux 桌面环境的 LANG 通常是 zh_CN.UTF-8，
    // Qt 启动时会按用户 locale 调用 setlocale(LC_ALL, "")，把 LC_NUMERIC
    // 一并改成中文 —— 这就是"只有 Linux 崩"的原因。
    //
    // 放在 initMpv() 里就地修，而不是只在启动脚本里 export LC_NUMERIC=C：
    // 这样无论程序由 .desktop / bbqq 脚本 / tar.gz 脚本 / 直接执行哪条路径
    // 启动都能生效，不依赖外部环境变量是否被正确传递。
    //
    // 注意 LC_ALL 会被 Qt 覆盖，因此这里只单独设置 LC_NUMERIC —— 这也是
    // libmpv 官方文档明确要求的做法。
    const char *curNumeric = std::setlocale(LC_NUMERIC, nullptr);
    if (curNumeric && qstrcmp(curNumeric, "C") != 0
        && qstrcmp(curNumeric, "POSIX") != 0) {
        qWarning() << "[MpvObject] LC_NUMERIC is" << curNumeric
                   << "- resetting to C (required by libmpv)";
    }
    std::setlocale(LC_NUMERIC, "C");

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
    // 缓存配置：默认按视频点播模式应用，直播页会在 setSource 之前由 QML
    // 写 liveMode: true 触发 applyCacheOptions() 覆盖为直播档
    applyCacheOptions();

    if (mpv_initialize(m_mpv) < 0) {
        qWarning() << "[MpvObject] failed to initialize mpv";
        emit errorOccurred("Failed to initialize mpv");
        mpv_terminate_destroy(m_mpv);
        m_mpv = nullptr;
        return;
    }
    m_mpvInitialized = true;

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
    m_mpvInitialized = false;
}

void MpvObject::applyCacheOptions()
{
    // cache 选项分两个阶段生效，必须区别对待：
    //   mpv_initialize 之前：mpv_set_option_string（启动期选项，写入后不可改）
    //   mpv_initialize 之后：mpv_set_option_string 会返回错误，必须用
    //                     mpv_set_property_string（运行时属性，可改）
    // QML 侧 liveMode 是普通属性绑定，其 setter 一定在构造函数（=initMpv）
    // 之后才被调用，因此"直播页恰好在 initialize 前设好"这一 D3D11 版注释里
    // 假定的时序在 Qt 属性绑定机制下并不成立。必须同时支持两条路径，
    // 否则直播页永远拿到视频档的大cache（30s/64M），延迟高且易积压。
    if (!m_mpv) return;

    const char *cacheSecs = nullptr;
    const char *maxBytes = nullptr;
    const char *maxBackBytes = nullptr;
    const char *readaheadSecs = nullptr;
    if (m_liveMode) {
        // 直播：小cache 低延迟，避免延迟随播放时长累积
        cacheSecs = "10";
        maxBytes = "16M";
        maxBackBytes = "8M";
        readaheadSecs = "10";
    } else {
        // 视频点播：大cache 抗网络抖动，避免 CDN 短暂断流时 demuxer 缓存
        // 耗尽而停住。30s 前向 + 64M 字节上限（约 30-60s 1080p 数据），
        // 16M 回看缓冲（seek 后退时不需重新下载）
        cacheSecs = "30";
        maxBytes = "64M";
        maxBackBytes = "16M";
        readaheadSecs = "30";
    }

    struct CacheOption { const char *name; const char *value; };
    const CacheOption options[] = {
        {"cache", "yes"},
        {"cache-secs", cacheSecs},
        {"demuxer-max-bytes", maxBytes},
        {"demuxer-max-back-bytes", maxBackBytes},
        {"demuxer-readahead-secs", readaheadSecs},
    };

    for (const CacheOption &opt : options) {
        if (m_mpvInitialized) {
            // `cache` 是启动期开关：mpv 0.23.0 起对应的运行时属性已被移除，
            // initialize 之后再设必然失败。直播页恰好总是走这条分支
            // （liveMode 绑定晚于构造 → setLiveMode 在 initialize 之后被调），
            // 不跳过就会每次开直播页都刷一条"failed to set cache=yes"的
            // 噪声 warning，掩盖真正有用的错误。其余 4 项是普通选项
            // （--cache-secs 语义），运行期改是有效的，故保留。
            if (strcmp(opt.name, "cache") == 0) {
                continue;
            }
            if (mpv_set_property_string(m_mpv, opt.name, opt.value) < 0) {
                qWarning() << "[MpvObject] failed to set" << opt.name << "=" << opt.value
                           << "after initialize";
            }
        } else {
            mpv_set_option_string(m_mpv, opt.name, opt.value);
        }
    }

    // 注：D3D11 版在视频档额外设了 vf=amf_frc（AMD 硬件帧率转换），
    // Linux 走 Mesa/VAAPI 没有对应滤镜，照抄会导致 mpv filter 加载失败
    // 而整个视频链起不来，故此处刻意不设 vf。

    qDebug() << "[MpvObject] cache options applied, liveMode =" << m_liveMode
             << "cache-secs =" << cacheSecs << "max-bytes =" << maxBytes
             << "initialized =" << m_mpvInitialized;
}

bool MpvObject::liveMode() const
{
    return m_liveMode;
}

void MpvObject::setLiveMode(bool liveMode)
{
    if (m_liveMode == liveMode) return;
    m_liveMode = liveMode;
    // 重新应用 cache 配置（initialize 前走 option，initialize 后走 property，
    // 详见 applyCacheOptions 内的注释）
    applyCacheOptions();
    emit liveModeChanged();
}

void MpvObject::reinitVideoChain()
{
    if (!m_mpv) return;
    // vid no→auto 重选视频轨，强制 mpv 以当前（新）渲染上下文重建
    // VO+解码链。两条命令异步提交给核心按序执行。
    // 纯 mpv 通用 API，与平台无关（D3D11 版用的也是同一段命令）。
    const char *vidOff[] = {"set", "vid", "no", nullptr};
    mpv_command_async(m_mpv, 0, vidOff);
    const char *vidOn[] = {"set", "vid", "auto", nullptr};
    mpv_command_async(m_mpv, 0, vidOn);
    qWarning() << "[MpvObject] video track reselected (vid no->auto) to"
               << "reinit video chain after render context recreation";
}

void MpvObject::verifyVideoChainAlive(int attempts)
{
    // 重建后需要校验视频链是否真的活着：kill_video_async 异步于核心线程，
    // 若其完成时机晚于首次重选，刚建好的视频链会被迟到的销毁再次杀死 → 黑屏
    if (!m_mpv || attempts <= 0) {
        //重试耗尽：交由 QML 侧既有的播放失败重试机制兜底
        return;
    }
    // video-params 仅在 VO 链存活时有效（暂停时同样有效，不依赖新帧）
    int64_t vw = 0;
    const int err = mpv_get_property(m_mpv, "video-params/w", MPV_FORMAT_INT64, &vw);
    const bool alive = (err >= 0 && vw > 0);
    qWarning() << "[MpvObject] verify video chain after context recreation: alive =" << alive
               << "attempts left =" << attempts;
    if (!alive) {
        reinitVideoChain();
        QTimer::singleShot(500, this, [this, attempts]() {
            verifyVideoChainAlive(attempts - 1);
        });
    } else {
        // 恢复完成：视频链存活，通知 QML 层恢复播放
        emit videoChainRestored();
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
            // 首帧解码完成、画面已出。QML 侧依赖此信号重置播放级重试状态、
            // 启动弹幕延迟计时与空降助手查询。Linux 版曾缺失该emit，
            // 导致 VideoPlayerPage 加载失败、首页组件链连锁失败。
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
                qWarning() << "[MpvObject] playback error:" << err;
                emit errorOccurred(err);
            } else if (ef && ef->reason == MPV_END_FILE_REASON_EOF && m_liveMode) {
                // 直播流自然结束：通常是主播推流中断（网络不稳）导致服务器侧终止流。
                // 用户主动 stop()/切换 source 产生的是 STOP reason，不会走到这里。
                // QML（LivePlayerPage）据此触发指数退避的自动重连。
                qWarning() << "[MpvObject] live stream EOF, notifying QML for reconnect";
                emit liveStreamEof();
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
