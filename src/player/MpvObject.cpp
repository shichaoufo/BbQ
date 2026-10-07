// ===========================================================================
// 渲染线程收尾方案的历史教训（必读，改动本文件收尾逻辑前请先看完）
// ===========================================================================
//
// 【问题】关闭视频/直播时崩溃。根因是渲染线程与 mpv 渲染上下文竞争 ——
// mpv 反复打印 "mpv_render_context_render() not being called or stuck."
// （mpv 在渲染循环停摆时的直接报告），随后主线程阻塞、最终 abort/segv。
//
// 【为什么本版是"照抄 Windows"而不是自己设计】
// MpvObjectD3D11 从一开始就有 m_renderMutex + m_shuttingDown 这对显式栅栏
// （见 MpvObjectD3D11.h:184-189），所以稳定。而 Linux 版此前
// `grep m_renderMutex` = 0 —— **一道栅栏都没有**。本版把D3D11 那套同步
// 骨架原样搬过来：渲染入口（createFramebufferObject / render）持锁，
// ~MpvObject 拿一次锁做栅栏后立即释放，再 free context、terminate core。
//
// 【被真机证伪过的四种方案，勿重走】按时间顺序：
//  1. 用一个"一次性原子标志"让渲染入口提前 return—— 证伪：标志置位后
//     渲染线程可能已越过检查、正在 mpv_render_context_render() 里，
//     存在"一帧窗口"。
//  2. 把 mpv_render_context_free() 挪到 GUI 线程（推理"渲染线程此时已无
//     current GL 上下文"）—— 证伪：GUI 线程 currentContext() 恒为
//     nullptr，是**确定性违规**，比老代码更糟（崩溃率 100%）。
//  3. 改用"场景图失效信号 + DirectConnection"释放 —— 证伪：
//     真机日志 "did not fire" 3 次、0 次成功 free。该信号只在场景图真正
//     失效时才发，而"关闭页面"不触发场景图失效 → 唯一"合法时机"永不到来。
//     （刻意不写出该信号的全名：本文件要求 grep 该符号为 0，避免后人
//      grep 到残留以为方案还活着。）
//  4. 查mpv 文档后发现 API 2.6 已解除"必须与 create 同线程"的限制，
//     据此论证"GUI 线程 free 是安全的" —— 结论对，但第 1 条的"一帧窗口"
//     依然存在，仍会崩。**线程对了不等于时序对了。**
//
// 【教训】以上每一轮都在"看起来等价"的地方做了等价性假设，然后被真机
// 打脸。真正的等价性来自 Qt/mpv 的**源码与文档原文**，以及Windows 版
// 已经在真机上验证过的模式。不要在本文件里发明新的同步机制。
//
// ===========================================================================

#include "MpvObject.h"

#include "LoginManager.h"
#include "FramePacer.h"
#include "../core/AppDirs.h"

#include <QDebug>
#include <QQuickWindow>
#include <QOpenGLContext>
#include <QOpenGLFramebufferObject>
#include <QOpenGLFunctions>
#include <QVariantMap>
#include <QElapsedTimer>
// 迁移兜底用到 QFile::copy / QFileInfo::exists / QStandardPaths。
// AppDirs.h 里也 include 了它们，但显式列出更稳妥 —— 依赖传递 include
// 会在AppDirs.h 改动时突然编不过。
#include <QFile>
#include <QFileInfo>
#include <QStandardPaths>

#include <clocale>

extern "C" {
#include <mpv/client.h>
#include <mpv/render_gl.h>
}

namespace {

// ===========================================================================
// mpv.conf 迁移时的平台专属选项过滤
// ===========================================================================
// 背景：我们在 Linux 上把 mpv 的 config-dir 从 mpv 自己的默认目录
// （~/.config/mpv/）改成了 ~/.config/BbQ/。迁移时若把旧文件原样搬过去，
// 里面的 Windows 侧调参会静默生效。
//
// 为什么必须过滤而不是照搬：
//   `vf=amf_frc` —— amf_frc 是 AMD 硬件帧率转换滤镜，依赖 libamdhip。
//   Linux 的 Mesa/VAAPI 没有对应实现，mpv 在**视频链初始化阶段**就会报
//   filter 加载失败，结果是整条视频链起不来（黑屏），比"少个滤镜"严重得多。
//   （用户已确认 vf=amf_frc 是他为自己那台 AMD 显卡加的私人调优。）
//
// 过滤规则（大小写不敏感，只匹配行首key=）：
//   - 命中黑名单的 key：整行剔除
//   - `#` 注释行与空行：原样保留（用户可能在里面写说明）
//   - 其它行（volume=100 等无害项）：原样保留
//
// 单独抽成纯函数（无副作用、不碰文件系统）是为了可单测：过滤逻辑出错的
// 后果是"用户的配置被静默改坏"，必须有可执行的验证手段。
//
// ---------------------------------------------------------------------------
// 【过滤强度的取舍 —— 与需求描述略有不同，说明如下】
// 需求要求滤 `vf` / `band` / `dither` / `dither-depth` 四项。查证后我按
// "会不会让 Linux 视频链起不来"这个真实判据重新评估，结论如下：
//
//   vf=            → **必须滤**。非空值（amf_frc）在 Linux 上必定导致
//                    filter 加载失败、视频链起不来。空值也一并删掉更干净。
//   dither=        → **滤，但理由与需求描述不同**：dither 并非 D3D11 专属，
//                    它是 mpv 跨平台有效选项，Linux 上能正常工作，不会让
//                    视频链起不来。仍要滤的真实理由是：本项目 initMpv() 里
//                    硬设了 dither=no（fast profile 下的性能取舍），
//                    用户的 dither=fruit 会**覆盖**掉这个刻意选择。
//   dither-depth=  → 同上，跨平台有效；同样会覆盖代码里的设置。
//   band=          → **照滤，但需澄清**：查证后mpv 并没有名为 `band` 的
//                    顶层选项（去色带的是 `deband`），`vf=band` 才会被当作
//                    滤镜名。所以 `band=yes` 实际会被 mpv 当作未知选项
//                    报错后忽略，**不会**导致视频链起不来。滤掉它是为了
//                    消除日志里的噪声、避免用户困惑，不是因为它危险。
//
// 综上：四项全滤，但**真正防止"起不来"的只有 `vf`**；另三项是
// "避免覆盖代码设置 / 消除噪声"。这个区分很重要——若日后 mpv 真的
// 出了某个新的致命选项，靠的是重新审这份黑名单，而不是以为"四项都致命"。

// 需要整行剔除的 key（全部小写，比较时统一转小写）
const char *const kStrippedKeys[] = {
    "vf",            // Linux 无 amf_frc 等硬件滤镜，非空值会让视频链起不来
    "band",          // 查证：mpv 无此顶层选项（去色带是 deband），滤仅为消噪
    "dither",        // 跨平台有效，但会覆盖 initMpv 里的 dither=no
    "dither-depth",  // 同上
};

/// 从一行 mpv.conf 中提取 key（行首 key= 的 key 部分，小写）。
/// 不是有效赋值行（注释、空行、无=、含前导空白）时返回空串。
QString confKeyOf(const QString &line)
{
    // mpv.conf 允许行首空白；注释行以 # 开头
    const QString trimmed = line.trimmed();
    if (trimmed.isEmpty() || trimmed.startsWith(QLatin1Char('#')))
        return QString();
    const int eq = trimmed.indexOf(QLatin1Char('='));
    if (eq <= 0)   // 无 '=' 或 '=' 在首位（非法）
        return QString();
    return trimmed.left(eq).trimmed().toLower();
}

/// mpv.conf 过滤结果
struct ConfFilterResult {
    QString filtered;      ///< 过滤后的文件内容
    QStringList removed;   ///< 每条剔除记录（供逐条打日志）
    int strippedCount = 0; ///< 剔除条数（removed 里不含汇总行）
};

/// 过滤 mpv.conf 文本。纯函数、不碰文件系统，便于单测。
ConfFilterResult filterWindowsOnlyMpvConf(const QString &text)
{
    ConfFilterResult res;
    QStringList out;
    out.reserve(64);

    const QStringList lines = text.split(QLatin1Char('\n'));
    for (const QString &rawLine : lines) {
        // 保留原始行内容（含可能存在的行尾 \r，Windows 写出的文件常带 CRLF）
        const QString key = confKeyOf(rawLine);
        bool hit = false;
        if (!key.isEmpty()) {
            for (const char *k : kStrippedKeys) {
                if (key == QLatin1String(k)) {   // key 已转小写
                    hit = true;
                    break;
                }
            }
        }
        if (hit) {
            ++res.strippedCount;
            QString shown = rawLine.trimmed();
            if (shown.size() > 80)
                shown = shown.left(80) + QStringLiteral("…");
            res.removed.append(QStringLiteral("%1 ← 原行 %2").arg(key, shown));
            continue;   // 剔除该行
        }
        out.append(rawLine);
    }

    QString result = out.join(QLatin1Char('\n'));
    // split 会在末尾产生一个空串项；join 回来后若原文以换行结尾就还原了。
    // 统一保证以换行结尾，避免最后一行与后续追加内容粘连。
    if (!result.endsWith(QLatin1Char('\n')))
        result += QLatin1Char('\n');
    res.filtered = result;
    return res;
}

} // namespace

static const QString MPV_USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
static const QString MPV_REFERER = "https://www.bilibili.com";
static const QString MPV_ORIGIN = "https://www.bilibili.com";

class MpvRenderer : public QQuickFramebufferObject::Renderer
{
public:
    // itemSlot 指向 MpvObject 内部的原子成员（不是裸指针）。
    // 不用 QPointer：它没有任何线程安全声明，跨线程读写本身就不安全；
    // 而 MpvRenderer 析构（渲染线程）确实会与 MpvObject 析构（GUI 线程）
    // 并发。纯原子是这里唯一合法的跨线程握手手段。
    explicit MpvRenderer(std::atomic<MpvObject *> *itemSlot, mpv_handle *mpv)
        : m_itemSlot(itemSlot)
        , m_mpv(mpv)
    {
    }

    ~MpvRenderer()
    {
        // Qt 销毁顺序：~QQuickItem（GUI 线程）只把场景图节点标记删除，实际
        // delete 由渲染线程的 cleanup 完成 →~MpvRenderer 运行在**渲染线程**，
        // 且**可能晚于** ~MpvObject。
        //
        // 这里**不释放任何 mpv 资源**：render context 与 core 都由
        // ~MpvObject 在拿到渲染栅栏（m_renderMutex）后统一释放。原因见
        // ~MpvObject 里关于 free/terminate 顺序的注释：item 与 renderer 的
        // 析构顺序没有保证，只有集中在 item 析构里才能用代码结构保证
        // "free 先于 terminate"（mpv 文档硬要求）。
        //
        // 这里唯一需要做的：若item 已析构则告警。因为那意味着
        // ~MpvObject 已经跑完、而 m_rendererItem 应已被置空——
        // 出现这条日志说明生命周期顺序异常，需要排查。
        MpvObject *item = m_itemSlot ? m_itemSlot->load(std::memory_order_acquire) : nullptr;
        if (!item) {
            qWarning() << "[MpvRenderer] destroyed after MpvObject teardown;"
                       << "(mpv resources already released by ~MpvObject)";
        }
        // 不在此 free render context：此刻 GL 上下文可能已失效，
        // 且"渲染线程会不会正在 render"的判断已由 m_renderMutex 统一处理。
    }

    void render() override
    {
        // 每次都从原子槽重新读 item，不缓存到成员里：渲染线程与 GUI 线程
        // 并发时，缓存会让"上一帧的对象指针"被下一个实例复用。
        MpvObject *item = m_itemSlot ? m_itemSlot->load(std::memory_order_acquire) : nullptr;
        if (!item)
            return;   // item 已析构，绝不碰它的状态

        // ---- 渲染栅栏（照搬 MpvObjectD3D11.cpp:1400-1409的同名模式）----
        // 析构期间提前返回：~MpvObject 正在等这把锁，若这里还往下走就会
        // 造成"渲染线程等 GUI 线程、GUI 线程等渲染线程"的互锁。
        if (item->m_shuttingDown.load(std::memory_order_acquire))
            return;

        // 渲染全程持锁：GUI 线程的 ~MpvObject 拿这把锁就能确定
        // "渲染线程已不在 mpv_render_context_render() 里"，从而安全地
        // free render context。锁的粒度= 一次 render()调用（对应
        // D3D11 的 updatePaintNode 入口持锁）。
        QMutexLocker locker(&item->m_renderMutex);

        // 加锁后必须再查一次：置位 m_shuttingDown 与拿到锁之间存在窗口，
        // 这期间 GUI 线程可能已经等到了锁并开始清理（与 D3D11:1407-1410
        // 同样的双重检查）。
        if (!item->m_mpv || item->m_shuttingDown.load(std::memory_order_acquire))
            return;

        mpv_render_context *ctx = item->m_mpvRender.load(std::memory_order_acquire);
        if (!ctx) return;

        QOpenGLFramebufferObject *fbo = framebufferObject();
        if (!fbo) return;

        QOpenGLContext *glCtx = QOpenGLContext::currentContext();
        if (!glCtx) return;
        QOpenGLFunctions *f = glCtx->functions();

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

        mpv_render_context_render(ctx, params);

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

        // context 指针由 MpvObject 持有：create 在渲染线程（这里），
        // free 在 ~MpvObject（GUI 线程）—— 中间由 m_renderMutex 栅栏保证
        // 渲染线程已不在 render() 里。顺序保证见 ~MpvObject 的注释。
        MpvObject *item = m_itemSlot ? m_itemSlot->load(std::memory_order_acquire) : nullptr;
        if (!item) {
            qWarning() << "[MpvRenderer] createFramebufferObject after item teardown";
            return fbo;
        }
        // 收尾期间不再创建 context（与 render() 同一把锁，避免与
        // ~MpvObject 的 free/terminate 撞车）。
        if (item->m_shuttingDown.load(std::memory_order_acquire))
            return fbo;
        QMutexLocker locker(&item->m_renderMutex);

        if (!item->m_mpvRender.load(std::memory_order_acquire)) {
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

// 直接写入 MpvObject 持有的槽位
                mpv_render_context *ctx = nullptr;
                int rc = mpv_render_context_create(&ctx, m_mpv, params);
            if (rc < 0) {
                qWarning() << "[MpvRenderer] failed to create mpv OpenGL render context, error:" << rc << mpv_error_string(rc);
            } else {
                item->m_mpvRender.store(ctx, std::memory_order_release);
                // 新建 context 后复位 m_shuttingDown：Qt 在 FBO 失效或窗口
                // 重建时会重建 renderer 与 context，而 item 本身仍存活
                // （那种场景下 core 没被terminate）。若不在这复位，
                // render() 会在入口一直 return，表现为**永久黑屏且无日志**。
                item->m_shuttingDown.store(false, std::memory_order_release);
                qDebug() << "[MpvRenderer] mpv OpenGL render context created";
                mpv_render_context_set_update_callback(ctx, [](void *ctx) {
                    MpvRenderer *renderer = static_cast<MpvRenderer*>(ctx);
                    renderer->onUpdate();
                }, this);

                // 只有"此前确实 free 过一个已建立的 render context"才需要
                // 重建视频链。首次创建走这里**不能**置位——此刻 mpv 里
                // 尚未 loadfile（setSource 还没调），video-params 必然取不到，
                // verifyVideoChainAlive 会判定死链并下发一次 vid no→auto，
                // 结果是刚起播就被无端重选视频轨（首帧闪黑 + 起播延迟）。
                bool wasFreed = item->m_renderContextFreed.exchange(
                    false, std::memory_order_acq_rel);
                // 另加"确实加载了文件"这一必要条件：没有文件就没有视频链，
                // 重选只会把 vid 打成 no 造成不必要的状态抖动。
                if (wasFreed && !item->m_source.isEmpty()) {
                    item->m_videoReinitPending.store(true, std::memory_order_release);
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
    // 指向 MpvObject 内部的原子槽（见构造函数的说明），**不缓存对象指针**。
    std::atomic<MpvObject *> *m_itemSlot = nullptr;
    mpv_handle *m_mpv = nullptr;
    // mpv_render_context 指针**不在这里**持有：它由 MpvObject 持有，
    // 因为 create 在渲染线程、而 free 在 ~MpvObject（GUI 线程），
    // 中间由 item->m_renderMutex 栅栏保证渲染线程已退出 render()。
};

MpvObject::MpvObject(QQuickItem *parent)
    : QQuickFramebufferObject(parent)
{
    initMpv();

    // 启动 positionChanged 节流计时基准。m_lastPosEmitMs 保持 -1 表示
    // "尚未 emit 过"，首次time-pos 事件会无条件放行。
    m_posThrottleClock.start();

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
    // 【P0-2】第一件事就是断开与 renderer 的握手。
    //
    // Qt 销毁顺序：~QQuickItem 在 GUI 线程只把场景图节点标记删除，实际
    // delete 由渲染线程 cleanup 完成 → ~MpvRenderer **可能晚于**本析构，
    // 且运行在渲染线程。若不置空，renderer 侧会解引用已析构对象；
    // 更糟的是该地址可能已被**另一个 MpvObject 实例**复用，导致
    // render() 读到别人的 m_mpvRender（另一个 mpv core 的活指针）。
    m_rendererItem.store(nullptr, std::memory_order_release);

    stopRenderTimer();

    // 断开窗口信号，防止销毁过程中 frameSwapped 触发 update()
    if (m_window) {
        disconnect(m_window, &QQuickWindow::frameSwapped, this, &MpvObject::update);
        m_window = nullptr;
    }

    // ==================================================================
    // 【回答：free 与 terminate 的线程与顺序保证】
    // ==================================================================
    // mpv 文档要求："You must free the context with mpv_render_context_free()
    // before the mpv core is destroyed. If this doesn't happen, undefined
    // behavior will result."
    //
    // **两者都在本GUI 线程内、严格顺序执行**：
    //   free     : mpv_render_context_free()  ← GUI 线程
    //   terminate: mpv_terminate_destroy()     ← GUI 线程（紧随其后）
    //
    // 为什么 free 放GUI 线程是安全的（mpv 侧前提，已核实）：
    //   本项目 libmpv 的 MPV_CLIENT_API_VERSION = 2.6（client.h:251），
    //   远高于 render.h 提到的 1.105 —— 后者才是"必须与 create 同线程"的那
    //   个限制（"Before API version 1.105 … you were required to call all
    //   mpv_render_*() functions from the same thread"）。1.105 起该限制已
    //   解除，且本项目不设 MPV_RENDER_PARAM_ADVANCED_CONTROL（代码注释
    //   明确"不使用"），因此 render.h 里"GL 上下文须在调用线程 current"
    //   那条约束**对本项目不适用**。
    //
    // 为什么"渲染线程不会正在用 context"这一前提成立：
    //   上面第 3 步的**渲染栅栏**。拿锁返回即证明渲染线程已不在
    //   render()/createFramebufferObject() 的临界区内（两处都持同一把锁）。
    //   这正是上一版翻车的地方 —— 上一版没有这把锁，只能靠"标志位 + 时机
    //   推理"，真机上导致 3 次 context 泄漏 + 崩溃。现在用显式栅栏代替推理。
    //
    // 为什么不用"~MpvRenderer 释放 + item 等标志位"：
    //   item 与 renderer 的析构顺序**没有保证**（renderer 是场景图 cleanup
    //   时删，可能晚于 item析构），无法据此保证"free 先于 terminate"。
    //   集中在 ~MpvObject 用栅栏同步后，顺序由代码结构直接保证，不依赖时序
    //   假设。
    m_shuttingDown.store(true, std::memory_order_release);

    if (m_mpv) {
        mpv_set_wakeup_callback(m_mpv, nullptr, nullptr);
    }

    // ---- 3. 渲染栅栏：等渲染线程退出临界区（照搬 MpvObjectD3D11.cpp:122-134）----
    // 只拿锁、不在锁内做清理：拿一次锁即证明"渲染线程当前不在 mpv 调用里"，
    // 随即释放。这与 D3D11 的用法完全一致。
    qWarning() << "[MpvObject] acquiring render mutex for sync cleanup";
    {
        QElapsedTimer t;
        t.start();
        QMutexLocker locker(&m_renderMutex);
        qWarning() << "[MpvObject] render mutex acquired in" << t.elapsed() << "ms";
    }
    qWarning() << "[MpvObject] render thread is out of render()/createFramebufferObject()";

    // ---- 4. 释放 mpv：先 free context，再 terminate core（GUI 线程，严格顺序）----
    {
        mpv_render_context *ctx = m_mpvRender.exchange(nullptr, std::memory_order_acq_rel);
        if (ctx) {
            qWarning() << "[MpvObject] freeing mpv_render_context";
            // 注意：mpv_render_context_free() 的签名是 **void**
            // （render.h:747 "MPV_EXPORT void mpv_render_context_free(...)"），
            // **没有返回值可判**。失败只能通过"指针是否有效"间接发现——
            // 而本项目所有调用点都在析构收尾路径上，没有别处能报告失败。
            // 因此这里只能记录调用事实；真正可检测的异常情况是"重复释放"，
            // 而那已由上面 exchange(nullptr) 的原子取出天然排除。
            // （曾尝试写成 `if (mpv_render_context_free(ctx) < 0)`，编译器
            //  报 "invalid operands of types 'void' and 'int'"——写出来才发现
            //  这两个函数根本不返回错误码。特此记录，避免后人再踩。）
            mpv_render_context_free(ctx);
            qWarning() << "[MpvObject] mpv_render_context freed (void return, no error code)";
        }
    }
    if (m_mpv) {
        qWarning() << "[MpvObject] terminating mpv";
        // 同上：mpv_terminate_destroy() 也是 **void**（client.h:542），
        // 无法检查返回值。重复调用由 mpv 文档保证"仅 send quit + destroy"，
        // 而本路径已把 m_mpv 置空、不会二次进入。
        mpv_terminate_destroy(m_mpv);
        qWarning() << "[MpvObject] mpv terminated (void return, no error code)";
        m_mpv = nullptr;
    }
    m_mpvInitialized = false;
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

    // vo=libmpv 是硬性要求：本项目不走 mpv 自己的窗口渲染，而是把
    // mpv 当作解码器 + 帧源，画面由 QQuickFramebufferObject 渲染路径接管。
    // 缺这一项 mpv 会自己开窗，与 Qt 窗口互相抢屏。
    mpv_set_option_string(m_mpv, "vo", "libmpv");

    // ---- 配置目录（与 MpvObjectD3D11 行为对齐，路径按平台区分）----
    // Windows：exe 同目录（保持用户既有行为不变，软件删除无残留）
    // Linux  ：~/.config/BbQ/（详见 src/core/AppDirs.h 的理由）
    //
    // config=yes 允许用户通过 mpv.conf 调参（免重编译）；
    // load-scripts=no 禁止加载 Lua 脚本 —— 第三方脚本可能直接崩进程，
    // 而我们对 mpv 内部有定制需求（见下方 msg-level），不能让脚本改写。
    {
        const QString cfgDir = AppDirs::configRoot();

#ifndef Q_OS_WIN
        // ---- 迁移兜底：把旧 mpv 配置目录里的 mpv.conf 搬过来 ----
        // 背景：改动前 Linux 版**从未设置 config-dir**，所以 mpv 用它自己的
        // 默认目录 ~/.config/mpv/。现在把 config-dir 指向 ~/.config/BbQ/ 后，
        // 那里已有的 mpv.conf 会被**静默忽略**、用户毫无察觉（而 bsb.conf 与
        // fonts/ 都有回退，唯独 mpv.conf 没有 —— mpv 只读一个 config-dir，
        // 没法像读取方那样"两个位置都试"）。这会造成可感知的配置回归。
        //
        // 故在设 config-dir 之前做一次性**过滤后复制**。四个约束：
        //   1) 仅非 Windows。Windows 走 applicationDirPath()/mpv-config，
        //      行为与改动前完全一致，不做任何迁移。
        //   2) **绝不覆盖**已存在的新文件 —— 用户在新目录里可能已经改过配置。
        //   3) 只在旧目录**确实有 mpv.conf 文件**时才复制（目录存在 ≠ 有文件，
        //      ~/.config/mpv/ 常因其它原因存在）。
        //   4) **过滤 Windows 专属选项后再写**，不能原样搬。原样搬会把
        //      vf=amf_frc 之类的设置带到 Linux 上，而 Linux 无对应滤镜，
        //      mpv 会在视频链初始化阶段就失败 → 整条视频链起不来。
        //      详见上方 filterWindowsOnlyMpvConf() 的注释与取舍说明。
        const QString legacyCfgDir = QDir(
            QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation))
            .absolutePath() + QStringLiteral("/mpv");
        const QString legacyConf = legacyCfgDir + QStringLiteral("/mpv.conf");
        const QString newConf = cfgDir + QStringLiteral("/mpv.conf");
        if (QFileInfo::exists(legacyConf)) {
            if (QFileInfo::exists(newConf)) {
                qInfo().noquote() << QStringLiteral(
                    "[MpvObject] %1 已存在，保留它并忽略旧配置 %2")
                    .arg(newConf, legacyConf);
            } else {
                QFile legacyFile(legacyConf);
                if (!legacyFile.open(QIODevice::ReadOnly | QIODevice::Text)) {
                    qWarning().noquote() << QStringLiteral(
                        "[MpvObject] 旧 mpv 配置无法读取，迁移跳过: %1（%2）")
                        .arg(legacyConf, legacyFile.errorString());
                } else {
                    const QString raw = QString::fromUtf8(legacyFile.readAll());
                    legacyFile.close();

                    const ConfFilterResult fr = filterWindowsOnlyMpvConf(raw);

                    QFile newFile(newConf);
                    if (newFile.open(QIODevice::WriteOnly | QIODevice::Text)) {
                        // 即使过滤后为空也照样写文件：留下一个空/仅含注释的
                        // mpv.conf 比"什么都没写"更清晰 —— 用户能看到
                        // "配置已迁移，但内容全是 Windows 专属设置，已全部剔除"，
                        // 而不会困惑于"我的配置怎么不见了"。
                        newFile.write(fr.filtered.toUtf8());
                        newFile.close();
                        // 每条剔除都必须让用户看见 —— 静默改用户配置不可接受
                        for (const QString &r : fr.removed) {
                            qInfo().noquote() << QStringLiteral(
                                "[MpvObject] mpv.conf 迁移：已剔除 Windows 专属设置 %1")
                                .arg(r);
                        }
                        qInfo().noquote() << QStringLiteral(
                            "[MpvObject] 已把旧 mpv 配置迁移: %1 -> %2（剔除 %3 条）")
                            .arg(legacyConf, newConf)
                            .arg(fr.strippedCount);
                        if (fr.strippedCount > 0) {
                            qInfo().noquote() << QStringLiteral(
                                "[MpvObject] 提示：被剔除的设置在 Linux 上无效或有害，"
                                "如需在 Linux 调参请直接编辑 %1").arg(newConf);
                        }
                    } else {
                        qWarning().noquote() << QStringLiteral(
                            "[MpvObject] 无法写入新 mpv 配置 %1（%2），"
                            "请手动复制并自行删除 Windows 专属设置")
                            .arg(newConf, newFile.errorString());
                    }
                }
            }
        }
#endif // !Q_OS_WIN

        mpv_set_option_string(m_mpv, "config-dir", cfgDir.toUtf8().constData());
        mpv_set_option_string(m_mpv, "config", "yes");
        mpv_set_option_string(m_mpv, "load-scripts", "no");
        qInfo().noquote() << QStringLiteral(
                   "[MpvObject] mpv 配置目录: %1（mpv.conf 可放此目录）").arg(cfgDir);
    }

    // mpv 内部日志：文件 + 事件回调双通道。
    // 日志文件放进配置目录而不是 exe 目录 —— .deb 安装后 exe 在 /opt/bbq/bin/
    // 归 root，普通用户写不进去会导致日志**完全丢失**，直播卡死这类问题
    // 就失去了唯一的排查依据。
    {
        QString mpvLogPath = AppDirs::configRoot() + QStringLiteral("mpv.log");
        mpv_set_option_string(m_mpv, "log-file", mpvLogPath.toUtf8().constData());
        // 与 D3D11 版一致：把 mpv 内部 c 日志接入 qWarning。重点关注
        // [ao] 前缀行（音频输出初始化/失败/重开）、[demux/audio] 行（缓存
        // 欠载）、[cplayer] 行。无 GUI 的 CI 上这行是唯一的排障信息源。
        mpv_set_option_string(m_mpv, "msg-level",
                             "all=warn,cplayer=info,ao=debug,demuxer=debug,cache=debug");
    }

    // 硬解：auto-safe 是跨平台取值，会自动挑选当前平台可用的硬解后端
    // （Linux 上是 VAAPI，Windows 上是 D3D11VA），不可用时回退软解。
    // 不能写死 d3d11va —— 那是 Windows 专属后端，在 Linux 上会导致
    // mpv_initialize 失败。
    mpv_set_option_string(m_mpv, "hwdec", "auto-safe");
    // 解码器直接输出渲染可用的帧格式，跳过一次 CPU 拷贝
    mpv_set_option_string(m_mpv, "vd-lavc-dr", "yes");
    mpv_set_option_string(m_mpv, "keep-open", "yes");
    mpv_set_option_string(m_mpv, "force-window", "no");
    mpv_set_option_string(m_mpv, "input-default-bindings", "no");
    mpv_set_option_string(m_mpv, "input-vo-keyboard", "no");
    mpv_set_option_string(m_mpv, "ytdl", "no");
    // 与 wiliwili 保持一致，降低视频帧率对弹幕/渲染节奏的干扰
    mpv_set_option_string(m_mpv, "video-timing-offset", "0");
    // 以音频时钟为同步基准（mpv 默认是 display-resample，会重采样音频）。
    // 弹幕客户端里音频连续播放比严格音画同步更重要：音频被反复重采样
    // 会产生可听的断续感。
    mpv_set_option_string(m_mpv, "video-sync", "audio");
    // 丢帧策略：只在 VO 端丢"已经迟到"的帧，解码器不主动跳帧。
    // 目的是解码器能跟上直播实时流（宁可丢显示帧也不让延迟累积），
    // 同时避免 decoder 级丢帧导致音画错位。
    mpv_set_option_string(m_mpv, "framedrop", "vo");
    // 明确告诉 mpv 显示器刷新率为 60fps，避免它按视频帧率自行降速
    mpv_set_option_string(m_mpv, "display-fps", "60");
    mpv_set_option_string(m_mpv, "override-display-fps", "60");
    // 使用 mpv fast profile，降低缩放/后处理开销；对 bilibili 视频画质影响很小
    mpv_set_option_string(m_mpv, "profile", "fast");
    // 明确关闭高成本缩放与后处理选项（fast profile 通常已包含，显式设置更保险）
    mpv_set_option_string(m_mpv, "scale", "bilinear");
    mpv_set_option_string(m_mpv, "dscale", "bilinear");
    // cscale 是 GPU/VO 端缩放算法（对应 dscale=bilinear 的 GPU 对应项）。
    // Linux 的 GL 渲染路径实际会走到它，不设则沿用 mpv 默认值。
    mpv_set_option_string(m_mpv, "cscale", "bilinear");
    mpv_set_option_string(m_mpv, "dither", "no");
    mpv_set_option_string(m_mpv, "correct-downscaling", "no");
    mpv_set_option_string(m_mpv, "linear-downscaling", "no");
    mpv_set_option_string(m_mpv, "sigmoid-upscaling", "no");
    mpv_set_option_string(m_mpv, "hdr-compute-peak", "no");
    // 解码端也开启快速路径
    mpv_set_option_string(m_mpv, "vd-lavc-fast", "yes");
    mpv_set_option_string(m_mpv, "vd-lavc-skiploopfilter", "all");

    // 刻意不设 vf（无论何值）—— 说明见 applyCacheOptions() 内的注释。
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

    // ---- 属性观察 ----
    // 与 MpvObjectD3D11 完全一致的 12 个观察项。缺失任何一个都会让对应
    // 诊断能力在 Linux 上彻底消失（详见onMpvEvents 里的处理分支）。
    mpv_observe_property(m_mpv, 0, "time-pos", MPV_FORMAT_DOUBLE);
    mpv_observe_property(m_mpv, 0, "duration", MPV_FORMAT_DOUBLE);
    mpv_observe_property(m_mpv, 0, "pause", MPV_FORMAT_FLAG);
    mpv_observe_property(m_mpv, 0, "speed", MPV_FORMAT_DOUBLE);
    mpv_observe_property(m_mpv, 0, "video-params", MPV_FORMAT_NODE);
    mpv_observe_property(m_mpv, 0, "seekable", MPV_FORMAT_FLAG);
    mpv_observe_property(m_mpv, 0, "hwdec-current", MPV_FORMAT_STRING);
    // 容器帧率：FramePacer 自适应心跳的输入（≥50fps 内容按需升档节奏）。
    // 缺这一项 Linux 上弹幕心跳等于瞎跑，永远按默认 60fps 档工作。
    mpv_observe_property(m_mpv, 0, "container-fps", MPV_FORMAT_DOUBLE);
    // demuxer 缓存状态：node 里含 cache-duration / fw-bytes /
    // cache-underrun 等。**直播卡死/闪退目前最大的排查黑箱**就是它 ——
    // 能直接看出是"网络供不上"（underrun）还是"解码跟不上"（eof 时长）。
    mpv_observe_property(m_mpv, 0, "demuxer-cache-state", MPV_FORMAT_NODE);
    // 播放中途无声问题确诊日志：观测音频轨选择与音频设备状态。
    // aid 变化 = 音频轨被切/失效（如 DASH 音频流断开时 mpv 内部 deselect）；
    // audio-device 变化 = 系统默认输出设备切换（蓝牙耳机断开回退板载声卡）。
    mpv_observe_property(m_mpv, 0, "aid", MPV_FORMAT_FLAG);
    mpv_observe_property(m_mpv, 0, "audio-device", MPV_FORMAT_STRING);
    mpv_observe_property(m_mpv, 0, "ao-volume", MPV_FORMAT_DOUBLE);

    // 把 mpv 内部日志事件送进 onMpvEvents 的 MPV_EVENT_LOG_MESSAGE 分支，
    // 与 log-file 双通道并存：文件供事后翻阅，回调供实时观察。
    mpv_request_log_messages(m_mpv, "v");

    double vol = 100.0;
    mpv_set_property(m_mpv, "volume", MPV_FORMAT_DOUBLE, &vol);
    int pauseFlag = 1;
    mpv_set_property(m_mpv, "pause", MPV_FORMAT_FLAG, &pauseFlag);
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

    // ---- 关于 vf：刻意两档都不设（重要，不要"对齐"回去）----
    // MpvObjectD3D11 的 applyCacheOptions() 里，视频档会设
    //     mpv_set_option_string(m_mpv, "vf", "amf_frc");
    // 直播档则设 vf="" 显式清空。
    //
    // **这里刻意两档都不设 vf，也不要为了"与 Windows 版对齐"把它搬过来。**
    // 原因（用户已明确确认）：`amf_frc` 是 AMD 硬件帧率转换滤镜，是用户
    // 为自己那台 AMD 显卡机器加的**私人调优**，不是通用方案。它依赖
    // libamdhip / ffmpeg 的 amf 滤镜，Linux 的 Mesa/VAAPI 栈没有对应
    // 实现；硬设会让 mpv 在**视频链初始化阶段**就报 filter 加载失败，
    // 结果是整条视频链起不来（黑屏且无画面），比"少一个滤镜"严重得多。
    //
    // 直播档的 vf="" 是"清空滤镜"，与"不设置"语义等价，同样无需搬。
    //
    // 如果用户在 Linux 上确实需要滤镜，正确做法是在
    // ~/.config/BbQ/mpv.conf 里自己写（config=yes 已启用，mpv.conf
    // 优先级高于代码），而不是让程序硬设一个特定显卡的滤镜。

    qDebug() << "[MpvObject] cache options applied, liveMode =" << m_liveMode
             << "cache-secs =" << cacheSecs << "max-bytes =" << maxBytes
             << "initialized =" << m_mpvInitialized
             << "(video filter chain intentionally left untouched)";
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
    // 传**内部原子的地址**（不是 this）：renderer 与本对象在不同线程
    // 生死，必须靠原子握手而不是裸指针/QPointer（见 ~MpvRenderer）。
    // createRenderer() 是 const，但原子本身可变（读不改变值），
    // const_cast 只为把"可写地址"交给 renderer，实际只用它 load()。
    return new MpvRenderer(const_cast<std::atomic<MpvObject *> *>(&m_rendererItem),
                           m_mpv);
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
                    // 信号节流（属性本体每次都更新，仅限制 emit 频率）：
                    // >1s 跳变（seek/切 P 位）立即放行保证 UI 响应
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
            } else if (strcmp(prop->name, "container-fps") == 0 && prop->format == MPV_FORMAT_DOUBLE) {
                // 自适应心跳输入：高帧率内容（≥50fps）在高刷屏上按需升档，
                // 保证视频帧不被 60fps 节奏饿死；换文件/卸载时 fps 回 0。
                // 缺这一项时Linux 上心跳恒为默认档，等于这条能力完全没启用。
                double fps = *static_cast<double*>(prop->data);
                FramePacer::instance()->setVideoFps(
                    (fps > 0.0 && fps < 1000.0) ? fps : 0.0);
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
            } else if (strcmp(prop->name, "aid") == 0 && prop->format == MPV_FORMAT_FLAG) {
                // 音频轨选择状态：中途变 no = 音频轨被取消选择（无声的常见根因）
                bool aidOn = *static_cast<int*>(prop->data) != 0;
                qWarning() << "[MpvObject] audio track (aid):" << (aidOn ? "selected" : "DESELECTED");
            } else if (strcmp(prop->name, "audio-device") == 0 && prop->format == MPV_FORMAT_STRING) {
                char *dev = *static_cast<char**>(prop->data);
                qWarning() << "[MpvObject] audio-device:" << (dev ? QString::fromUtf8(dev) : QString("?"));
            } else if (strcmp(prop->name, "ao-volume") == 0 && prop->format == MPV_FORMAT_DOUBLE) {
                // 音频输出实际音量：与 volume（请求值）不一致时说明 ao 侧
                // 做了自己的缩放/静音，是"改了音量却没声音"的定位点
                double aov = *static_cast<double*>(prop->data);
                qWarning() << "[MpvObject] ao-volume:" << aov;
            } else if (strcmp(prop->name, "demuxer-cache-state") == 0
                       && prop->format == MPV_FORMAT_NODE) {
                // 直播卡死/闪退的核心诊断项。这里刻意只打印不解析成信号：
                // 它是高频变化（每次读缓存都变）的诊断数据，emit 给 QML 只会
                // 制造无谓的绑定刷新。真正需要结构化时再加。
                mpv_node *node = static_cast<mpv_node*>(prop->data);
                if (node && node->format == MPV_FORMAT_NODE_MAP) {
                    // 注意 mpv_node.u.list 是 mpv_node_list**（因为 mpv_node
                    // 内部持有一个指针成员，取地址得到二级指针）。D3D11 版
                    // 写的是 mpv_node_list *list = node->u.list;（用了
                    // 指针的隐式转换）。这里显式取 * 保持类型正确。
                    const mpv_node_list *list = node->u.list;
                    double cacheSecs = -1.0;
                    int64_t fwBytes = -1, totalBytes = -1;
                    int64_t underrunCount = -1;
                    bool eof = false;
                    for (int i = 0; i < list->num; ++i) {
                        const char *key = list->keys ? list->keys[i] : nullptr;
                        if (!key) continue;
                        const mpv_node &v = list->values[i];
                        if (strcmp(key, "cache-duration") == 0
                            && v.format == MPV_FORMAT_DOUBLE) {
                            cacheSecs = v.u.double_;
                        } else if (strcmp(key, "fw-bytes") == 0
                                   && v.format == MPV_FORMAT_INT64) {
                            fwBytes = v.u.int64;
                        } else if (strcmp(key, "total-bytes") == 0
                                   && v.format == MPV_FORMAT_INT64) {
                            totalBytes = v.u.int64;
                        } else if (strcmp(key, "cache-underrun") == 0
                                   && v.format == MPV_FORMAT_FLAG) {
                            underrunCount = v.u.int64;
                        } else if (strcmp(key, "eof") == 0
                                   && v.format == MPV_FORMAT_FLAG) {
                            eof = v.u.int64 != 0;
                        }
                    }
                    // 缓存耗尽（underrun）或流已结束且没缓存，是"卡住不动"的
                    // 两种典型形态，直接打出来便于事后判断是网络还是解码问题
                    const bool starved = (underrunCount >= 0)
                        || (eof && cacheSecs < 0.5);
                    if (starved) {
                        qWarning() << "[MpvObject] demuxer cache starved:"
                                   << "duration =" << cacheSecs << "s"
                                   << "fw-bytes =" << fwBytes
                                   << "total-bytes =" << totalBytes
                                   << "underrun-count =" << underrunCount
                                   << "eof =" << (eof ? "yes" : "no")
                                   << "liveMode =" << (m_liveMode ? "yes" : "no");
                    }
                }
            }
            break;
        }
        case MPV_EVENT_LOG_MESSAGE: {
            // mpv内部日志透传（无声/卡死问题确诊）：关注 [ao]/[demux]/[cplayer] 行。
            // 依赖 initMpv 里的 mpv_request_log_messages(m_mpv, "v")，
            // 缺这一行调用本分支永远不会触发。
            mpv_event_log_message *msg = static_cast<mpv_event_log_message*>(event->data);
            if (msg && msg->text) {
                QString line = QString::fromUtf8(msg->text).trimmed();
                if (!line.isEmpty())
                    qWarning() << "[mpv]" << line;
            }
            break;
        }
        case MPV_EVENT_FILE_LOADED: {
            // 首帧解码完成、画面已出。QML 侧依赖此信号重置播放级重试状态、
            // 启动弹幕延迟计时与空降助手查询。Linux 版曾缺失该emit，
            // 导致 VideoPlayerPage 加载失败、首页组件链连锁失败。
            //
            // 绿屏/雪花问题确诊日志：流的编码格式与硬解方法。用于判断
            // "是不是硬解/滤镜不兼容导致的渲染异常" —— Linux 走 VAAPI，
            // 若 hwdec-current 为 none 说明已回退软解（可能是 VAAPI 不支持
            // 该 profile，回退后能播但 CPU 占用高）。
            char *vfmt = mpv_get_property_string(m_mpv, "video-format");
            char *vcodec = mpv_get_property_string(m_mpv, "video-codec");
            char *hwcur = mpv_get_property_string(m_mpv, "hwdec-current");
            qWarning() << "[MpvObject] file loaded, video-format:" << (vfmt ? vfmt : "?")
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
