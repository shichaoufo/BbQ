#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQmlEngine>
#include <qqml.h>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QPixmapCache>
#include <QTimer>
#include <QDebug>
#include <QDateTime>
#include <QTextStream>
#include <QMutex>
#include <cstdio>
#include <cstdarg>
#include <cstring>
#include <QSslConfiguration>
#include <QSslSocket>
#include <QWindow>
#include <QQuickWindow>
#include <QQuickItem>
#include <QMouseEvent>

#ifdef Q_OS_WIN
#include <windows.h>
#include <psapi.h>
// MiniDumpWriteDump 在 MinGW 下虽然可能有头文件但无对应导入库，
// 因此只在 MSVC 原生编译时用静态链接；其他环境统一走运行时动态加载。
#if defined(_MSC_VER) && __has_include(<dbghelp.h>)
#include <dbghelp.h>
#define BMQ_HAS_DBGHELP 1
#else
#define BMQ_HAS_DBGHELP 0
#endif
#endif

static QFile g_logFile;
static constexpr qint64 MAX_LOG_SIZE = 5 * 1024 * 1024; // 5 MB

// ============ Windows 崩溃转储与栈回溯 ============
#ifdef Q_OS_WIN

// MinGW 环境下没有 <dbghelp.h>，需要手动定义 MiniDumpWriteDump 所需的类型。
#if !BMQ_HAS_DBGHELP
typedef struct _MINIDUMP_EXCEPTION_INFORMATION {
    DWORD ThreadId;
    PEXCEPTION_POINTERS ExceptionPointers;
    BOOL ClientPointers;
} MINIDUMP_EXCEPTION_INFORMATION;
#endif

// MiniDumpWriteDump 的函数指针类型（dbghelp.dll 导出）
// 最后两个参数类型在 MinGW 下未定义，用 void* 代替（调用时传 NULL）
typedef BOOL (WINAPI *MiniDumpWriteDumpFn)(HANDLE hProcess, DWORD dwProcessId,
                                            HANDLE hFile, ULONG MiniDumpType,
                                            const MINIDUMP_EXCEPTION_INFORMATION *pExceptionInfo,
                                            const void *pUserStreamInfo,
                                            const void *pCallbackInfo);

// ---------- 崩溃报告输出（只用 CRT + Win32，不碰 Qt / 堆） ----------
// 崩溃发生时堆可能已损坏，全部缓冲区用 static（无堆分配），
// 同时输出到 stderr 和 exe 旁的 BbQ_crash.log。
static char g_crashLine[1024];

static void crashLog(HANDLE hFile, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_crashLine, sizeof(g_crashLine), fmt, ap);
    va_end(ap);
    fputs(g_crashLine, stderr);
    fflush(stderr);
    if (hFile != INVALID_HANDLE_VALUE) {
        DWORD written = 0;
        WriteFile(hFile, g_crashLine, (DWORD)strlen(g_crashLine), &written, NULL);
    }
}

// 把任意代码地址解析为 "模块名+偏移"。不需要符号文件，
// 足以判断崩溃发生在 BbQ.exe / Qt6*.dll / mpv-2.dll / 显卡驱动 哪个模块里。
static void formatModuleAddr(char *out, size_t outSize, const void *addr)
{
    HMODULE mod = NULL;
    if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS
                               | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           (LPCWSTR)addr, &mod)
        && mod) {
        static wchar_t wpath[MAX_PATH];
        GetModuleFileNameW(mod, wpath, MAX_PATH);
        const wchar_t *name = wcsrchr(wpath, L'\\');
        name = name ? name + 1 : wpath;
        static char modName[MAX_PATH];
        WideCharToMultiByte(CP_UTF8, 0, name, -1, modName, sizeof(modName), NULL, NULL);
        snprintf(out, outSize, "%s+0x%llX", modName,
                 (unsigned long long)((uintptr_t)addr - (uintptr_t)mod));
    } else {
        snprintf(out, outSize, "unknown(%p)", addr);
    }
}

static LONG WINAPI crashHandler(EXCEPTION_POINTERS *pException)
{
    // 只处理真正的访问冲突，避免把正常的 SEH 也记录下来
    DWORD code = pException->ExceptionRecord->ExceptionCode;
    if (code != EXCEPTION_ACCESS_VIOLATION
        && code != EXCEPTION_STACK_OVERFLOW
        && code != EXCEPTION_INT_DIVIDE_BY_ZERO
        && code != EXCEPTION_PRIV_INSTRUCTION
        && code != STATUS_HEAP_CORRUPTION
        && code != 0x40000015 /* STATUS_FATAL_APP_EXIT */) {
        // 把其他异常交还给系统/调试器
        return EXCEPTION_CONTINUE_SEARCH;
    }

    // ===== 1. 先写文字版崩溃报告（最重要，任何情况下都要先落地） =====
    wchar_t exeDir[MAX_PATH];
    GetModuleFileNameW(NULL, exeDir, MAX_PATH);
    wchar_t *slash = wcsrchr(exeDir, L'\\');
    if (slash) slash[1] = L'\0';
    SYSTEMTIME st;
    GetLocalTime(&st);

    wchar_t crashLogPath[MAX_PATH];
    wsprintfW(crashLogPath, L"%sBbQ_crash.log", exeDir);
    HANDLE hReport = CreateFileW(crashLogPath, GENERIC_WRITE, FILE_SHARE_READ,
                                 NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hReport != INVALID_HANDLE_VALUE) {
        SetFilePointer(hReport, 0, NULL, FILE_END); // 追加模式，跨多次崩溃保留
    }

    crashLog(hReport, "\n================ CRASH ================\n");
    crashLog(hReport, "time: %04d-%02d-%02d %02d:%02d:%02d pid=%lu tid=%lu\n",
             st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond,
             GetCurrentProcessId(), GetCurrentThreadId());
    crashLog(hReport, "ExceptionCode=0x%08lX\n", (unsigned long)code);

    if (code == EXCEPTION_ACCESS_VIOLATION
        && pException->ExceptionRecord->NumberParameters >= 2) {
        ULONG_PTR avType = pException->ExceptionRecord->ExceptionInformation[0];
        ULONG_PTR avAddr = pException->ExceptionRecord->ExceptionInformation[1];
        const char *typeStr = (avType == 0) ? "read"
                              : (avType == 1) ? "write"
                              : (avType == 8) ? "dep-exec" : "?";
        crashLog(hReport, "AccessViolation: %s at 0x%p (target data address)\n",
                 typeStr, (void *)avAddr);
    }

    // 出错指令所在模块——定位崩溃的第一线索
    {
        char loc[MAX_PATH + 64];
        formatModuleAddr(loc, sizeof(loc), pException->ExceptionRecord->ExceptionAddress);
        crashLog(hReport, "FaultingIP: %p (%s)\n",
                 pException->ExceptionRecord->ExceptionAddress, loc);
    }

    // ===== 2. 调用栈（不需要符号，模块名+偏移即可大幅收窄范围） =====
    // 栈溢出时没有栈空间可用，跳过栈回溯。
    if (code != EXCEPTION_STACK_OVERFLOW) {
        typedef USHORT(WINAPI *CaptureStackBackTraceFn)(ULONG, ULONG, PVOID *, PUSHORT);
        static PVOID frames[64];
        USHORT n = 0;
        HMODULE hK32 = GetModuleHandleW(L"kernel32.dll");
        if (hK32) {
            CaptureStackBackTraceFn pCap =
                (CaptureStackBackTraceFn)GetProcAddress(hK32, "CaptureStackBackTrace");
            if (pCap) {
                n = pCap(0, 64, frames, NULL);
            }
        }
        crashLog(hReport, "---- stack (innermost first), %u frames ----\n", (unsigned)n);
        for (USHORT i = 0; i < n; ++i) {
            char loc[MAX_PATH + 64];
            formatModuleAddr(loc, sizeof(loc), frames[i]);
            crashLog(hReport, "  #%02u %p %s\n", (unsigned)i, frames[i], loc);
        }

        // ---- 兜底：手动栈扫描 ----
        // 堆腐蚀类崩溃常伴随栈帧元数据损坏，CaptureStackBackTrace 会
        // 立即失败（n=0）。此时从异常上下文的 Rsp 开始逐 8 字节扫描栈
        // 内存，凡指向已加载模块代码区的值都视为候选返回地址打印——
        // 不依赖 unwind 信息，通常仍能看出调用链的模块序列。
        // 全程只用 VirtualQuery / ReadProcessMemory（内核侧读，不触碰
        // 可能已损坏的 CRT 堆）。
#if defined(_M_X64) || defined(__x86_64__)
        CONTEXT *ctx = pException->ContextRecord;
        if (ctx && n == 0) {
            crashLog(hReport, "Rip=%p Rsp=%p\n",
                     (void *)ctx->Rip, (void *)ctx->Rsp);
            crashLog(hReport, "---- raw stack scan (candidate return addrs) ----\n");
            MEMORY_BASIC_INFORMATION mbi;
            uintptr_t p = (uintptr_t)ctx->Rsp;
            const uintptr_t scanEnd = p + 0x3000;
            int printed = 0;
            while (p < scanEnd && printed < 40) {
                if (VirtualQuery((LPCVOID)p, &mbi, sizeof(mbi)) == 0)
                    break;
                if (mbi.State != MEM_COMMIT) {
                    // 跳过整个未提交区域（按 8 字节对齐推进）
                    p = (((uintptr_t)mbi.BaseAddress + mbi.RegionSize) + 7) & ~(uintptr_t)7;
                    continue;
                }
                uintptr_t val = 0;
                SIZE_T got = 0;
                if (ReadProcessMemory(GetCurrentProcess(), (LPCVOID)p,
                                      &val, sizeof(val), &got) && got == sizeof(val)) {
                    HMODULE mod = NULL;
                    if (val > 0x10000
                        && GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS
                                                  | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                                              (LPCWSTR)val, &mod)
                        && mod) {
                        char loc[MAX_PATH + 64];
                        formatModuleAddr(loc, sizeof(loc), (void *)val);
                        crashLog(hReport, "  sp+0x%04llX %p %s\n",
                                 (unsigned long long)(p - (uintptr_t)ctx->Rsp),
                                 (void *)val, loc);
                        ++printed;
                    }
                }
                p += 8;
            }
        }
#endif
    }

    // ===== 3. 最后尝试写 minidump（可能因堆损坏失败，尽力而为） =====
    wchar_t dumpPath[MAX_PATH];
    wsprintfW(dumpPath, L"%sBbQ_crash_%04d%02d%02d_%02d%02d%02d.dmp",
              exeDir, st.wYear, st.wMonth, st.wDay,
              st.wHour, st.wMinute, st.wSecond);

    HANDLE hFile = CreateFileW(dumpPath, GENERIC_WRITE, 0, NULL,
                               CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);

    if (hFile != INVALID_HANDLE_VALUE) {
        MINIDUMP_EXCEPTION_INFORMATION mei;
        mei.ThreadId          = GetCurrentThreadId();
        mei.ClientPointers    = FALSE;
        mei.ExceptionPointers = pException;

        BOOL dumpOk = FALSE;
        // MiniDumpWithFullMemory 在 MinGW 的 dbghelp.h 中可能不存在，
        // 这里用数值 0（= MiniDumpNormal）作为兼容性最好的选项。
        // 注意：MiniDumpWriteDump 第一个参数是 HANDLE（进程句柄），
        // 不是 PID；传 GetCurrentProcess() 返回 -1 的伪句柄即可。
#if BMQ_HAS_DBGHELP
        dumpOk = MiniDumpWriteDump(GetCurrentProcess(), GetCurrentProcessId(), hFile,
                                    (MINIDUMP_TYPE)0 /*MiniDumpNormal*/, &mei, NULL, NULL);
#else
        // MinGW 环境下动态加载 dbghelp.dll
        HMODULE hDbghelp = LoadLibraryW(L"dbghelp.dll");
        if (hDbghelp) {
            MiniDumpWriteDumpFn pDump = (MiniDumpWriteDumpFn)GetProcAddress(hDbghelp, "MiniDumpWriteDump");
            if (pDump) {
                dumpOk = pDump(GetCurrentProcess(), GetCurrentProcessId(), hFile,
                               0 /*MiniDumpNormal*/, &mei, NULL, NULL);
            }
            FreeLibrary(hDbghelp);
        }
#endif
        CloseHandle(hFile);
        crashLog(hReport, "dump: %s (err=%lu)\n", dumpOk ? "written" : "failed",
                 dumpOk ? 0UL : GetLastError());
    } else {
        crashLog(hReport, "dump: failed to create file (err=%lu)\n", GetLastError());
    }

    crashLog(hReport, "=======================================\n");
    if (hReport != INVALID_HANDLE_VALUE) {
        CloseHandle(hReport);
    }

    return EXCEPTION_EXECUTE_HANDLER;
}

static void installCrashHandler()
{
    // SetUnhandledExceptionFilter 在所有未处理的异常上被调用
    SetUnhandledExceptionFilter(crashHandler);
}
#endif
// ============ end of crash handler ============

static void initLogFile()
{
    QString logDir = QCoreApplication::applicationDirPath();
    QString logPath = logDir + "/BbQ.log";

    // 超过大小限制时删除旧日志，重新创建新日志
    QFileInfo info(logPath);
    if (info.exists() && info.size() > MAX_LOG_SIZE) {
        QFile::remove(logPath);
    }

    g_logFile.setFileName(logPath);
    g_logFile.open(QIODevice::WriteOnly | QIODevice::Append | QIODevice::Text);
}

// 日志处理器会被任意线程并发调用（网络线程的 warning、主线程的日志等），
// g_logFile 的写入必须串行化，否则并发操作同一个 QIODevice 缓冲区会导致
// 内存损坏（表现为偶发启动闪退，AV 读野地址）。
static QMutex g_logMutex;

// 重入保护：日志处理过程中再次触发日志（如写文件失败产生的 warning）直接丢弃，
// 防止无限递归。
static thread_local bool g_inMessageHandler = false;

static void biliQtMessageHandler(QtMsgType type, const QMessageLogContext &context, const QString &msg)
{
    Q_UNUSED(context)

    if (g_inMessageHandler) {
        return;
    }
    g_inMessageHandler = true;

    const char *level = nullptr;
    switch (type) {
    case QtDebugMsg:    level = "DEBUG"; break;
    case QtInfoMsg:     level = "INFO";  break;
    case QtWarningMsg:  level = "WARN";  break;
    case QtCriticalMsg: level = "CRIT";  break;
    case QtFatalMsg:    level = "FATAL"; break;
    }

    QString text = QString("[%1] %2: %3")
                       .arg(QDateTime::currentDateTime().toString("yyyy-MM-dd hh:mm:ss"))
                       .arg(level)
                       .arg(msg);

    // 始终输出到 stderr（fputs，避免每次构造 QTextStream 触发额外内部逻辑）
    QByteArray utf8 = text.toUtf8();
    fputs(utf8.constData(), stderr);
    fputc('\n', stderr);
    fflush(stderr);

    // 警告及以上级别同时写入日志文件（互斥锁保护并发写）
    if (type >= QtWarningMsg && g_logFile.isOpen()) {
        QMutexLocker locker(&g_logMutex);
        g_logFile.write(utf8);
        g_logFile.write("\n");
        g_logFile.flush();
    }

    g_inMessageHandler = false;

    if (type == QtFatalMsg) {
        abort();
    }
}

#include "AppManager.h"
#include "CircularReveal.h"
#include "ApiManager.h"
#include "AppSettings.h"
#include "LoginManager.h"
#include "PlayUrlManager.h"
#include "SponsorBlockManager.h"
#include "CommentManager.h"
#include "InteractionManager.h"
#include "MediaDownloader.h"
#ifdef Q_OS_WIN
#include "MpvObjectD3D11.h"
#else
#include "MpvObject.h"
#endif
#include "WbiSigner.h"
#include "LiveDanmakuManager.h"
#include "VideoDanmakuManager.h"
#include "DanmakuCanvas.h"
#include "FramePacer.h"

// ============ 全局焦点释放过滤器 ============
// Qt Quick 的焦点只在可聚焦项（Controls/TextInput 等）之间转移：点击背景、
// 文本、Flickable 空白等不可聚焦区域时，焦点会原地滞留，表现为：
//   1. 评论框/搜索框激活后，点击页面其他地方输入框仍持有焦点；
//   2. Tab 键给按钮加的焦点框（FluFocusRectangle），点击其他地方不消失。
// 该过滤器装在 QQuickWindow 上，在鼠标按下派发到 QML 场景之前判断：
// 若按下位置不在当前焦点项范围内、也不在任何打开的 Popup（联想下拉、
// 右键菜单等挂在 Overlay 下）上，则先把焦点从该项上摘除。
// 必须在派发前摘：Popup 的开关常依赖焦点变化（如 FluAutoSuggestBox 失焦
// 即关联想下拉），若派发后才摘，Popup 会在点击命中前关闭、点击被吞掉。
class FocusReleaseFilter : public QObject
{
public:
    explicit FocusReleaseFilter(QObject *parent = nullptr) : QObject(parent) {}

protected:
    bool eventFilter(QObject *obj, QEvent *ev) override
    {
        if (ev->type() == QEvent::MouseButtonPress) {
            if (auto *window = qobject_cast<QQuickWindow *>(obj))
                handlePress(window, static_cast<QMouseEvent *>(ev));
        }
        return QObject::eventFilter(obj, ev);
    }

private:
    static void handlePress(QQuickWindow *window, QMouseEvent *event)
    {
        // 仅左键触发（与 Web/桌面惯例一致：右键菜单、中键不改变焦点）
        if (event->button() != Qt::LeftButton)
            return;

        QQuickItem *focusItem = window->activeFocusItem();
        if (!focusItem || focusItem == window->contentItem())
            return;

        const QPointF pos = event->position();

        // 边界判定项：若焦点项是 QQuickTextInput/QQuickTextEdit 原语
        // （QQC2 TextField/TextArea 的 contentItem），其可点击区域是外层
        // 控件（含 padding 与清除按钮），用外层控件的边界代替。
        QQuickItem *boundsItem = focusItem;
        if (isPrimitiveInput(focusItem)) {
            QQuickItem *p = focusItem->parentItem();
            if (p && isInputControlName(className(p)))
                boundsItem = p;
        }

        // 1) 按下位置在焦点项自身范围内 → 保留焦点
        if (sceneRect(boundsItem).contains(pos))
            return;

        // 2) 按下位置在打开的 Popup 上 → 保留焦点（点击联想词/菜单项等）
        QQuickItem *overlay = findOverlay(window);
        if (overlay) {
            const QList<QQuickItem *> overlayChildren = overlay->childItems();
            for (QQuickItem *c : overlayChildren) {
                if (c->isVisible() && sceneRect(c).contains(pos))
                    return;
            }
        }

        // 3) 按下落在其他位置 → 摘除焦点（输入框失焦、Tab 焦点框消失）；
        //    若按下目标本身可聚焦，后续正常派发时它会照常获得焦点
        focusItem->setFocus(false);
    }

    static QByteArray className(const QObject *obj)
    {
        return obj ? QByteArray(obj->metaObject()->className()) : QByteArray();
    }

    // QQuickTextInput/QQuickTextEdit 原语类名；QML 组件实例的类名形如
    // "FluTextBox_QML_63"，不会命中
    static bool isPrimitiveInput(const QQuickItem *item)
    {
        const QByteArray cn = className(item);
        return cn == "QQuickTextInput" || cn == "QQuickTextEdit";
    }

    // 外层输入控件的类名特征（FluTextBox/FluAutoSuggestBox/QQuickTextField/
    // QQuickTextArea 等）
    static bool isInputControlName(const QByteArray &cn)
    {
        return cn.contains("TextBox") || cn.contains("TextField")
            || cn.contains("TextArea") || cn.contains("SuggestBox")
            || cn.contains("Input");
    }

    static QRectF sceneRect(QQuickItem *item)
    {
        return item->mapRectToScene(QRectF(0, 0, item->width(), item->height()));
    }

    // QQuickOverlay 挂在 contentItem 下，是所有 QQC2 Popup 内容的父节点；
    // 其可见子项即当前打开的 Popup
    static QQuickItem *findOverlay(QQuickWindow *window)
    {
        const QList<QQuickItem *> children = window->contentItem()->childItems();
        for (QQuickItem *c : children) {
            if (className(c) == "QQuickOverlay")
                return c;
        }
        return nullptr;
    }
};

int main(int argc, char *argv[])
{
#ifdef Q_OS_WIN
    // 将 mpv_runtime 子目录加入 DLL 搜索路径，使 libmpv-2.dll 及其全部依赖
    // （libcurl、libgcc_s_seh、libstdc++ 等）都从该目录加载，避免与 Qt 自带的
    // 旧版 MinGW 运行时冲突（如 curl_easy_header 缺失等问题）。
    {
        wchar_t exePath[MAX_PATH];
        GetModuleFileNameW(NULL, exePath, MAX_PATH);
        wchar_t *lastSlash = wcsrchr(exePath, L'\\');
        if (lastSlash) {
            *(lastSlash + 1) = L'\0';
            wchar_t mpvPath[MAX_PATH];
            wsprintfW(mpvPath, L"%smpv_runtime", exePath);
            DWORD attr = GetFileAttributesW(mpvPath);
            if (attr != INVALID_FILE_ATTRIBUTES && (attr & FILE_ATTRIBUTE_DIRECTORY)) {
                SetDllDirectoryW(mpvPath);
            }
        }
    }
#endif

    // Windows 下使用 D3D11 RHI，MPV 通过 DXGI render context 直接渲染到 D3D11 纹理，
    // 与 d3d11va 硬解零拷贝对接，可显著降低 GPU 占用。
    // 非 Windows 平台继续使用 OpenGL RHI + MPV_RENDER_API_TYPE_OPENGL。
#ifdef Q_OS_WIN
    qputenv("QSG_RHI_BACKEND", "d3d11");
#else
    qputenv("QSG_RHI_BACKEND", "opengl");
#endif
    // qputenv("QSG_INFO", "1"); // 诊断时临时禁用，减少日志输出

    QGuiApplication app(argc, argv);
    app.setOrganizationName("BbQ");
    app.setApplicationName("BbQ");
    app.setApplicationVersion("1.0.0");

    // 初始化日志文件并安装消息处理器，警告/严重错误同时写入 BbQ.log
    initLogFile();
    qInstallMessageHandler(biliQtMessageHandler);

#ifdef Q_OS_WIN
    // 安装 Windows 未处理异常过滤器：崩溃时会生成 .dmp 并把崩溃点写入日志
    installCrashHandler();
    qDebug("[BiliQt] Crash handler installed");
#endif

    // 全局 SSL 配置：禁用对等证书验证，避免部分环境（包括 QML Image）HTTPS 图片加载失败
    QSslConfiguration sslConfig = QSslConfiguration::defaultConfiguration();
    sslConfig.setPeerVerifyMode(QSslSocket::VerifyNone);
    QSslConfiguration::setDefaultConfiguration(sslConfig);

    // 限制 Qt 全局 pixmap 缓存，避免图片占用过多内存。
    // 评论区图片、表情包较多，适当提高到 80MB 以提升加载速度。
    QPixmapCache::setCacheLimit(80 * 1024);

    AppManager appManager;
    appManager.detectRenderer();

    AppSettings appSettings;
    ApiManager apiManager;
    PlayUrlManager playUrlManager;
    CommentManager commentManager;
    InteractionManager interactionManager;
    MediaDownloader mediaDownloader;

    QQmlApplicationEngine engine;

    // FramePacer 单例暴露给 QML：播放器设置面板的"弹幕帧率限制"下拉框
    // 调用 setTargetRate()（60/100/120/144/0=不限制）。单例本身由
    // DanmakuCanvas / MpvObjectD3D11 构造时首次创建，这里提前实例化到
    // GUI 线程（instance() 线程安全，幂等）
    engine.rootContext()->setContextProperty("FramePacer", FramePacer::instance());

    qmlRegisterSingletonType<AppManager>("BiliQt", 1, 0, "App",
        [&](QQmlEngine *engine, QJSEngine *scriptEngine) -> QObject* {
            Q_UNUSED(engine)
            Q_UNUSED(scriptEngine)
            QQmlEngine::setObjectOwnership(&appManager, QQmlEngine::CppOwnership);
            return &appManager;
        });

    qmlRegisterSingletonType<ApiManager>("BiliQt", 1, 0, "Api",
        [&](QQmlEngine *engine, QJSEngine *scriptEngine) -> QObject* {
            Q_UNUSED(engine)
            Q_UNUSED(scriptEngine)
            QQmlEngine::setObjectOwnership(&apiManager, QQmlEngine::CppOwnership);
            return &apiManager;
        });

    qmlRegisterSingletonType<LoginManager>("BiliQt", 1, 0, "Login",
        [&](QQmlEngine *engine, QJSEngine *scriptEngine) -> QObject* {
            Q_UNUSED(engine)
            Q_UNUSED(scriptEngine)
            LoginManager *loginManager = LoginManager::instance();
            QQmlEngine::setObjectOwnership(loginManager, QQmlEngine::CppOwnership);
            return loginManager;
        });

    qmlRegisterSingletonType<PlayUrlManager>("BiliQt", 1, 0, "PlayUrlManager",
        [&](QQmlEngine *engine, QJSEngine *scriptEngine) -> QObject* {
            Q_UNUSED(engine)
            Q_UNUSED(scriptEngine)
            QQmlEngine::setObjectOwnership(&playUrlManager, QQmlEngine::CppOwnership);
            return &playUrlManager;
        });

    // 空降助手（BilibiliSponsorBlock）：懒加载单例，bsb.conf 缺失时
    // available=false，整套功能静默关闭（详见类注释）
    qmlRegisterSingletonType<SponsorBlockManager>("BiliQt", 1, 0, "SponsorBlockManager",
        [&](QQmlEngine *engine, QJSEngine *scriptEngine) -> QObject* {
            Q_UNUSED(engine)
            Q_UNUSED(scriptEngine)
            QQmlEngine::setObjectOwnership(SponsorBlockManager::instance(), QQmlEngine::CppOwnership);
            return SponsorBlockManager::instance();
        });

    qmlRegisterSingletonType<CommentManager>("BiliQt", 1, 0, "CommentManager",
        [&](QQmlEngine *engine, QJSEngine *scriptEngine) -> QObject* {
            Q_UNUSED(engine)
            Q_UNUSED(scriptEngine)
            QQmlEngine::setObjectOwnership(&commentManager, QQmlEngine::CppOwnership);
            return &commentManager;
        });

    qmlRegisterSingletonType<InteractionManager>("BiliQt", 1, 0, "InteractionManager",
        [&](QQmlEngine *engine, QJSEngine *scriptEngine) -> QObject* {
            Q_UNUSED(engine)
            Q_UNUSED(scriptEngine)
            QQmlEngine::setObjectOwnership(&interactionManager, QQmlEngine::CppOwnership);
            return &interactionManager;
        });

    qmlRegisterSingletonType<MediaDownloader>("BiliQt", 1, 0, "MediaDownloader",
        [&](QQmlEngine *engine, QJSEngine *scriptEngine) -> QObject* {
            Q_UNUSED(engine)
            Q_UNUSED(scriptEngine)
            QQmlEngine::setObjectOwnership(&mediaDownloader, QQmlEngine::CppOwnership);
            return &mediaDownloader;
        });

    // 通用设置存储（QML 中通过 Settings.getBool/setBool 等访问）
    qmlRegisterSingletonType<AppSettings>("BiliQt", 1, 0, "Settings",
        [&](QQmlEngine *engine, QJSEngine *scriptEngine) -> QObject* {
            Q_UNUSED(engine)
            Q_UNUSED(scriptEngine)
            QQmlEngine::setObjectOwnership(&appSettings, QQmlEngine::CppOwnership);
            return &appSettings;
        });

    qmlRegisterType<CircularReveal>("BiliQt", 1, 0, "CircularReveal");
#ifdef Q_OS_WIN
    qmlRegisterType<MpvObjectD3D11>("BiliQt", 1, 0, "MpvObject");
#else
    qmlRegisterType<MpvObject>("BiliQt", 1, 0, "MpvObject");
#endif
    qmlRegisterType<LiveDanmakuManager>("BiliQt", 1, 0, "LiveDanmakuManager");
    qmlRegisterType<VideoDanmakuManager>("BiliQt", 1, 0, "VideoDanmakuManager");
    qmlRegisterType<DanmakuCanvas>("BiliQt", 1, 0, "DanmakuCanvas");

    // 提前获取 WBI 签名密钥，避免在 QML/C++ 网络回调中触发同步 QEventLoop 导致闪退
    qDebug() << "[BiliQt] Pre-fetching WBI keys...";
    bool wbiOk = WbiSigner::instance()->fetchKeysSync();
    qDebug() << "[BiliQt] WBI keys pre-fetch result:" << wbiOk;

    // 每 30 分钟刷新一次 WBI 密钥，防止运行过久后过期再次触发同步获取
    QTimer wbiRefreshTimer;
    wbiRefreshTimer.setInterval(30 * 60 * 1000);
    QObject::connect(&wbiRefreshTimer, &QTimer::timeout, []() {
        qDebug() << "[BiliQt] Refreshing WBI keys...";
        WbiSigner::instance()->fetchKeysSync();
    });
    wbiRefreshTimer.start();

    // 加载 QML：Debug 模式优先从本地文件加载（方便热重载），Release 从资源加载
    QUrl url;
#ifdef QT_DEBUG
    QString localQmlPath = QCoreApplication::applicationDirPath() + "/qml/main.qml";
    if (QFileInfo::exists(localQmlPath)) {
        url = QUrl::fromLocalFile(localQmlPath);
        qDebug("[BiliQt] Loading QML from local file: %s", qPrintable(localQmlPath));
    } else
#endif
    {
        url = QUrl(QStringLiteral("qrc:/BiliQt/qml/main.qml"));
        qDebug("[BiliQt] Loading QML from resource");
    }

    QObject::connect(&engine, &QQmlApplicationEngine::objectCreated,
                     &app, [url](QObject *obj, const QUrl &objUrl) {
        if (!obj && url == objUrl)
            QCoreApplication::exit(-1);
    }, Qt::QueuedConnection);

    engine.load(url);

    // 修复 FluentUI 无边框窗口缺少 WS_MINIMIZEBOX，导致点击任务栏图标无法最小化/还原的问题。
    // FluFrameless::componentComplete() 会在窗口初始化时重设窗口样式（Qt 6.7.2 还会移除 WS_MINIMIZEBOX），
    // 因此需要在窗口首次显示后再次确保该样式存在。
    auto ensureMinimizeBox = [](QWindow *window) {
        if (!window) {
            return;
        }
        window->winId(); // 确保原生窗口已创建
#ifdef Q_OS_WIN
        HWND hwnd = reinterpret_cast<HWND>(window->winId());
        if (!hwnd) {
            return;
        }
        DWORD style = static_cast<DWORD>(::GetWindowLongPtr(hwnd, GWL_STYLE));
        if ((style & WS_MINIMIZEBOX) == 0) {
            ::SetWindowLongPtr(hwnd, GWL_STYLE, style | WS_MINIMIZEBOX);
            ::SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                           SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_NOMOVE | SWP_NOSIZE | SWP_FRAMECHANGED);
            qDebug("[BiliQt] Added WS_MINIMIZEBOX to taskbar icon");
        }
#endif
    };

    QTimer::singleShot(0, [&engine, ensureMinimizeBox]() {
        QObject *rootObject = engine.rootObjects().value(0);
        QWindow *window = qobject_cast<QWindow *>(rootObject);
        if (!window && rootObject) {
            window = rootObject->findChild<QWindow *>();
        }
        if (window) {
            ensureMinimizeBox(window);
            // 安装全局焦点释放过滤器：点击焦点项之外的区域时摘除焦点，
            // 解决"输入框失焦不了 / Tab 焦点框点不掉"的问题
            if (auto *quickWindow = qobject_cast<QQuickWindow *>(window))
                quickWindow->installEventFilter(new FocusReleaseFilter(quickWindow));
            // 监听窗口显示事件，防止后续被 FluentUI 框架覆盖
            QObject::connect(window, &QWindow::visibleChanged, [window, ensureMinimizeBox]() {
                if (window->isVisible()) {
                    ensureMinimizeBox(window);
                }
            });
            // 延迟再检查一次，覆盖 FluFrameless::componentComplete() 完成后的状态
            QTimer::singleShot(500, [window, ensureMinimizeBox]() {
                ensureMinimizeBox(window);
            });
        }
    });

    int ret = app.exec();

    // 恢复默认消息处理器：engine 与各管理器是栈对象，在 return 时才析构。
    // 析构阶段 Qt 内部会发出 warning（如 ~QWebSocket 内部的 disconnect 警告），
    // 若仍走自定义处理器，会与网络线程的对象析构形成 AB-BA 死锁
    // （残留进程调用栈实测：主线程在 ~LiveDanmakuManager → ~QWebSocket →
    //  日志处理器内等锁，网络线程析构对象时等另一把锁，进程无法退出）。
    // 默认处理器仅 fprintf 到 stderr，不触碰 Qt 内部锁，可安全穿越析构阶段。
    qInstallMessageHandler(nullptr);

    return ret;
}
