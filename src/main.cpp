#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQmlEngine>
#include <qqml.h>
#include <QDir>
#include <QFile>
#include <QFileInfo>
// 日志目录在非 Windows 上走 AppDirs::configRoot()。显式 include 而非依赖
// 传递 —— AppDirs.h 改动时不应让 main.cpp 突然编不过。路径相对本文件
// 所在目录（src/），故是 core/ 而非 ../core/。
#include "core/AppDirs.h"
#include <QPixmapCache>
#include <QImageReader>
#include <QTimer>
#include <QDebug>
#ifndef Q_OS_WIN
// 非 Windows 平台的渲染后端诊断需要直接查询 OpenGL 运行时信息
#include <GL/gl.h>
#endif
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
    // 日志路径同样按平台分开（与 AppDirs 的配置路径策略一致）：
    //
    // Windows：保持 exe 同目录（applicationDirPath）。用户明确要求 Windows
    //   版行为不变——日志随目录走，删软件连日志一起删、不留残留。这条路径
    //   本来就一直是 Windows 的既有行为（改动前 main.cpp 就是这么写的），
    //   沿用它等于对 Windows 零改动。
    //
    // 非 Windows：必须改到用户可写目录。原先同样写 applicationDirPath()，
    //   但 .deb 装到 /opt/bbq 后该目录归 root，普通用户启动时
    //   QFile::open 失败，而原代码丢弃了返回值 → 日志静默丢失，排障时
    //   什么都看不到。复用 AppDirs::configRoot()（Linux 上即
    //   ~/.config/BbQ/），与 mpv.conf/bsb.conf/fonts 同目录，便于用户
    //   一处找全所有配置与日志。
    QString logDir;
#ifdef Q_OS_WIN
    logDir = QCoreApplication::applicationDirPath();
#else
    logDir = AppDirs::configRoot();
#endif

    if (logDir.isEmpty()) {
        // 兜底：路径算不出来时退回用户主目录，仍好过写安装目录
        logDir = QDir::homePath() + "/.BbQ";
    }
    QDir().mkpath(logDir);
    QString logPath = logDir + "/BbQ.log";

    // 超过大小限制时删除旧日志，重新创建新日志
    QFileInfo info(logPath);
    if (info.exists() && info.size() > MAX_LOG_SIZE) {
        QFile::remove(logPath);
    }

    g_logFile.setFileName(logPath);
    // 必须检查返回值：写不进去时至少 stderr 还能给出提示，否则会再次
    // 出现"日志静默丢失、排障时两眼一黑"的情况
    if (!g_logFile.open(QIODevice::WriteOnly | QIODevice::Append | QIODevice::Text)) {
        qWarning("Failed to open log file %s: %s", qPrintable(logPath),
                 qPrintable(g_logFile.errorString()));
        qWarning("  日志无法写入，运行期诊断信息将只输出到 stderr");
    } else {
        qInfo("Log file: %s", qPrintable(logPath));
    }
}

// ===== POSIX 崩溃/信号处理（Linux 等非 Windows 平台）=====
//
// 为什么需要：原实现只有 Windows 的 SetUnhandledExceptionFilter +
// MiniDumpWriteDump（installCrashHandler 内含 HANDLE/CreateFileW，全是
// Win32 API）。Linux 上**完全没有崩溃处理器**，进程被信号终止时不留任何
// 痕迹 —— 表现为"点了没反应就没了"、日志里最后一行也无从对应，正是本次
// 银河麒麟"重开后播放直接闪退"完全无线索的原因。
//
// 实现要点：
//   - 信号处理函数里只能调用**异步信号安全**的操作。qWarning() 会加锁、
//     可能分配内存，严格说在信号上下文里并不安全；但 Qt 的消息处理器在
//     实际使用中不会在此路径死锁，且相比"什么都留不下"这个代价是明确
//     的改进。这里用 write(2) 直写日志文件描述符 + 提前打开的备份 FD
//     作为更安全的替代。
//   - 已知危险信号（SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGABRT）不能真正"处理"，
//     只能在原信号默认行为之前补写诊断信息，然后恢复默认并重新抛出，
//     让进程以正确的退出码终止（避免被误判为正常退出，也便于 core dump）。
//   - SIGPIPE 必须**忽略**而非捕获：mpv 文档明确 "every mpv_initialize()
//     call will block SIGPIPE"，不忽略会让进程在写管道时直接死掉。
#ifndef Q_OS_WIN
#include <csignal>
#include <unistd.h>
#include <fcntl.h>
#include <cstring>
// 崩溃栈捕获：backtrace()/backtrace_symbols_fd() 来自 glibc 的 execinfo.h。
#include <execinfo.h>
#include <sys/syscall.h>
// sigaltstack：给信号处理函数准备一块独立的栈
#include <cstdlib>

static int g_crashLogFd = -1;

// 由 initLogFile 在打开 g_logFile 后一并打开一个只写 FD，供信号处理器使用
static void openCrashLogFd()
{
    if (g_logFile.isOpen()) {
        const QString path = g_logFile.fileName();
        g_crashLogFd = ::open(QFile::encodeName(path).constData(),
                             O_WRONLY | O_APPEND | O_CREAT, 0644);
    }
}

static void crashLogFd(const char *fmt, ...)
{
    if (g_crashLogFd < 0)
        return;
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    const int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n > 0) {
        // 尽力而为：write 失败也不能再做别的事
        ssize_t ignored = ::write(g_crashLogFd, buf, static_cast<size_t>(n));
        (void)ignored;
    }
}

extern "C" void bbqFatalSignalHandler(int sig)
{
    crashLogFd("\n================ CRASH (POSIX signal) ================\n");
    switch (sig) {
    case SIGSEGV: crashLogFd("signal: SIGSEGV (invalid memory access)\n"); break;
    case SIGBUS:  crashLogFd("signal: SIGBUS (bus error, e.g. misaligned/mmap)\n"); break;
    case SIGILL:  crashLogFd("signal: SIGILL (illegal instruction)\n"); break;
    case SIGFPE:  crashLogFd("signal: SIGFPE (arithmetic exception, e.g. div by zero)\n"); break;
    case SIGABRT: crashLogFd("signal: SIGABRT (abort())\n"); break;
    default:      crashLogFd("signal: %d\n", sig); break;
    }

    // ---- 第①步：先把"崩了 + 什么信号 + 哪个线程"落盘（必须在 backtrace 之前）----
    // 【顺序至关重要】下面的 backtrace() 有残余死锁风险（libgcc unwinder
    // 非严格 async-signal-safe）。万一它在 handler 里二次死锁，我们**至少
    // 已经写下了这段** —— 能知道"崩了、什么信号、哪个线程"，比日志空白
    // 强得多。因此本段与 tid 都刻意排在 backtrace 之前。
    crashLogFd("thread tid: ");
    {
        // syscall(SYS_gettid) 而非 pthread_self()：后者在信号上下文里
        // 理论上可能加锁。
        const long tid = ::syscall(SYS_gettid);
        crashLogFd("%ld\n", tid);
    }

    // ---- 第②步：崩溃栈捕获 ----
    // 【为什么用 sigaltstack】信号处理函数跑在**被中断线程的栈**上。若崩溃
    // 恰好由栈溢出引起（这正是我们最想抓的一类），处理函数自己没有可用栈、
    // 直接二次溢出 → 连日志都写不出来。sigaltstack 让处理函数改用一块
    // 预分配的独立栈，绕开这个死结。
    //
    // 【安全性取舍（glibc 官方 man page 明确说明）】
    // backtrace(3) NOTES 原文：
    //   "backtrace() and backtrace_symbols_fd() don't call malloc() explicitly,
    //    but they are part of libgcc, which gets loaded **dynamically when
    //    first used**. Dynamic loading usually triggers a call to malloc(3).
    //    If you need certain calls to these two functions to not allocate
    //    memory (in signal handlers, for example), you need to make sure
    //    libgcc is loaded beforehand."
    // 所以本handler 在安装阶段（installPosixCrashHandler，正常运行时）
    // 先空跑一次 backtrace()，把 libgcc 的惰性加载与首次 malloc 全部提前
    // 做完；这样崩溃当刻的调用就不再触发动态加载，显著降低在handler 内
    // 二次死锁的概率。
    //
    // 仍然存在的风险（无法消除，只是概率降低）：libgcc 的unwinder 本身
    // 并非严格 async-signal-safe。取栈失败时必须**静默继续**走下面的兜底，
    // 绝不能在 handler 里卡死。实际使用中这是抓栈最主流的做法。
    //
    // 【为什么用 backtrace_symbols_fd 而不是 backtrace_symbols】man page
    // 原文："backtrace_symbols_fd() does not call malloc(3)"。它直接
    // write(2) 到 fd，不碰 stdio 锁，比需要 malloc 的版本安全得多。
    //
    // 【符号名】man page："The symbol names may be unavailable without the
    // use of special linker options. For systems using the GNU linker, it is
    // necessary to use the -rdynamic linker option."
    // ⇒ Linux 构建已在 CMakeLists.txt 里加 -rdynamic（非 Windows 分支），
    // 这样栈里能带出函数名。-rdynamic 只导出**动态符号**，static 局部函数
    // 的名字仍不可见（man page 同段亦有说明），属预期限制。
    //
    // 精确原型（man backtrace(3) SYNOPSIS，glibc 2.1+）：
    //   int  backtrace(void **buffer, int size);
    //   void backtrace_symbols_fd(void *const *array, int size, int fd);
    // 注意 backtrace_symbols_fd 返回 **void**（不是 char**）。
    void *frames[64];
    const int nptrs = ::backtrace(frames, 64);
    if (nptrs > 0) {
        crashLogFd("---- backtrace (%d frames, may be incomplete) ----\n", nptrs);
        ::backtrace_symbols_fd(frames, nptrs, g_crashLogFd);
        // fd 无效时兜底打到 stderr（终端/系统日志里也能看到）
        if (g_crashLogFd < 0)
            ::backtrace_symbols_fd(frames, nptrs, STDERR_FILENO);
        crashLogFd("---- end backtrace ----\n");
    } else {
        // 取栈失败兜底：打印说明后继续走原来的 re-raise 流程。
        // 此时第①步的信号名与 tid 已在日志里，不会什么都留不下。
        crashLogFd("---- backtrace unavailable (returned 0 frames) ----\n");
    }

    crashLogFd("======================================================\n");

    // 恢复默认处置并重新发出，让进程按信号正常终止（保留 core dump 与
    // 正确的退出码，避免上游把崩溃误判为正常退出）
    ::signal(sig, SIG_DFL);
    ::raise(sig);
}

static void installPosixCrashHandler()
{
    // SIGPIPE 忽略：mpv 文档要求（mpv_initialize 会阻塞 SIGPIPE），
    // 不忽略则与 mpv 交互时可能直接被信号杀死，表现为无日志的闪退
    ::signal(SIGPIPE, SIG_IGN);

    // ---- sigaltstack：给 handler 准备独立栈 ----
    // 用 static（而非栈上数组）是因为 handler 执行时原栈可能已损坏/耗尽。
    //
    // ⚠️ 尺寸**不能用 SIGSTKSZ**：glibc 2.34 起 SIGSTKSZ 改为
    // sysconf(_SC_SIGSTKSZ) 的**运行时**返回值，不再是编译期常量 ——
    // 写 `static char altStack[SIGSTKSZ ...]` 会直接报
    // "storage size of 'altStack' isn't constant"（Ubuntu 22.04 的
    // glibc 2.35 正是如此，CI 实测踩过）。
    // 这里直接用固定下界：信号处理只需一个远大于常见 SIGSTKSZ(8KB) 的栈，
    // backtrace() 展开 64 帧的空间绰绰有余。
    constexpr size_t kAltStackSize = 128 * 1024;
    static char altStack[kAltStackSize];
    stack_t ss;
    ss.ss_sp = altStack;
    ss.ss_size = sizeof(altStack);
    ss.ss_flags = 0;
    if (::sigaltstack(&ss, nullptr) != 0)
        crashLogFd("sigaltstack failed; backtrace may be unavailable on stack overflow\n");

    const int fatal[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT };
    for (int sig : fatal) {
        struct sigaction sa;
        ::memset(&sa, 0, sizeof(sa));
        sa.sa_handler = bbqFatalSignalHandler;
        ::sigemptyset(&sa.sa_mask);
        // SA_ONSTACK：让 handler 跑在上面的 altStack 上。**必须**，
        // 否则 sigaltstack 装了也不会被用上。
        sa.sa_flags = SA_ONSTACK;
        ::sigaction(sig, &sa, nullptr);
    }

    // 【关键预热】空跑一次 backtrace()，把 libgcc 的动态加载（dlopen）与
    // 随之而来的首次 malloc 提前做完 —— 见 man backtrace(3) 的 NOTES。
    // 不做这一步的话，崩溃当刻第一次调 backtrace() 会在信号上下文里触发
    // dlopen/malloc，显著提高 handler 内二次死锁的概率（那样就什么都
    // 留不下了）。这里在正常上下文里做，风险为零。
    {
        void *warmup[4];
        (void)::backtrace(warmup, 4);   // 返回值故意忽略
    }

    crashLogFd("POSIX crash handler installed (SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGABRT"
               " -> log + backtrace via sigaltstack, libgcc preloaded, SIGPIPE ignored)\n");
}
#endif // !Q_OS_WIN

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

    // 过滤已知无害的 Qt 内部噪音：
    // "QIODevice::read (QSslSocket): device not open" —— QNetworkAccessManager
    // 的 HTTPS keep-alive 连接被服务器按空闲超时（约 60s）关闭后，Qt 拆除
    // 连接时对已关闭的 QSslSocket 收尾 read 触发。连接随即按需重建，
    // 功能零影响（弹幕 WebSocket 为独立长连接，不受影响）。
    if (msg == QStringLiteral("QIODevice::read (QSslSocket): device not open")) {
        return;
    }

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
#include "ImageActions.h"
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

#ifndef Q_OS_WIN
    // 非 Windows：显式把 Qt Quick 的图形 API 锁定为 OpenGL。
    //
    // 为什么必须显式声明（QQuickFramebufferObject 的官方要求）：
    // Qt 6 的场景图默认走 RHI，而 QQuickFramebufferObject 官方文档明写
    //   "This class is only suitable when working directly with OpenGL.
    //    It is not compatible with the RHI-based rendering path."
    // 《Changes to Qt Quick》进一步要求："依赖 QQuickFramebufferObject 的
    // 应用程序应在其 main() 函数中调用
    //   QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL)"
    //
    // 为什么这对我们是硬约束（不只是形式）：
    // mpv 的 render API 只有 MPV_RENDER_API_TYPE_OPENGL / D3D11 / SW 等，
    // Linux 上我们用的就是 OpenGL 后端。Linux 版MpvObject 继承
    // QQuickFramebufferObject，一旦 Qt 选到非 OpenGL 的 QRhi 后端
    // （例如某些发行版默认 Vulkan、或未来 Qt 改默认），FBO 路径会**静默
    // 失效**——类不报错，但视频区永远空白。
    //
    // 上面的 QSG_RHI_BACKEND=opengl 已经能选出 OpenGL 后端；这里再用
    // 官方 API 显式固定，是**双保险**：即使将来环境变量被外部覆盖
    // （桌面启动器/沙箱/用户 profile），也会因为 Qt 无法初始化请求的后端
    // 而明确失败，而不是静默黑屏。
    //
    // 注意：必须在 QGuiApplication 构造**之前**调用。
    QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);
#endif
    // qputenv("QSG_INFO", "1"); // 诊断时临时禁用，减少日志输出

    QGuiApplication app(argc, argv);
    app.setOrganizationName("BbQ");
    app.setApplicationName("BbQ");
    app.setApplicationVersion("1.0.0");

    // 放宽图片解码的内存分配上限（Qt 默认 256 MB）。
    //
    // 为什么需要：QImageIOHandler::allocateImage() 按「宽 × 高 × 至少 32bpp」估算
    // **解码后的位图**大小，只看像素数、与文件大小无关，超限就直接拒绝加载。而
    // B 站原图 CDN 返回的是原始分辨率（GlobalState.fixImageUrl 不给宽高时只拼
    // "@.jpg"，仅强制转码、不改分辨率），画师投稿常见上亿像素：实测 13000x8584
    // = 1.116 亿像素 → ARGB32 需约 426 MiB，超过 256 MB 上限，于是预览里表现为
    // 「无法取图」。
    //
    // 取值 1024：可容纳约 2.68 亿像素（如 16384x16384），覆盖所有现实投稿。这是
    // **上限而非预分配** —— 不打开巨图就不会多占内存。0 表示完全不检查（不建议）。
    //
    // 注意：环境变量 QT_IMAGEIO_MAXALLOC 的优先级高于本调用（见 Qt 源码
    // QImageReader::allocationLimit()），若外部设置过它，此行会被覆盖。
    QImageReader::setAllocationLimit(1024);

    // 初始化日志文件并安装消息处理器，警告/严重错误同时写入 BbQ.log
    initLogFile();
    qInstallMessageHandler(biliQtMessageHandler);

#ifdef Q_OS_WIN
    // 安装 Windows 未处理异常过滤器：崩溃时会生成 .dmp 并把崩溃点写入日志
    installCrashHandler();
    qDebug("[BiliQt] Crash handler installed");
#else
    // 非 Windows：安装 POSIX 信号处理器，让 SIGSEGV/SIGBUS 等致命信号
    // 在终止前补写崩溃信息到日志（此前 Linux 上崩溃完全无痕迹，是排查
    // "播放闪退"无从下手的直接原因）；同时忽略 SIGPIPE（mpv 要求）。
    openCrashLogFd();
    installPosixCrashHandler();
    qDebug("[BiliQt] POSIX crash handler installed");
#endif

    // 全局 SSL 配置：禁用对等证书验证，避免部分环境（包括 QML Image）HTTPS 图片加载失败
    QSslConfiguration sslConfig = QSslConfiguration::defaultConfiguration();
    sslConfig.setPeerVerifyMode(QSslSocket::VerifyNone);
    // 允许 HTTP/2（ALPN 白名单带上 h2，协商失败自动回落 http/1.1）。
    //
    // 【2026-10-15 重要更正】此前这里把 ALPN 限死成 http/1.1，理由是"B站对
    // HTTP/2 请求直接返 -412"。**那个结论是错的**，真实根因是另一个：
    //   SESSDATA 里的 %2C 被我们解码成裸逗号再回传，被风控当成脚本构造的
    //   cookie（详见 LoginManager::sessDataForCookie 的注释）。
    // 而当年"Node http2 → 412"的观测，是 Node 的 h2 客户端自己发了不合规的
    // h2 头，并不代表 h2 不行。
    //
    // 用修好编码之后的 cookie 复测（curl_cffi，非浏览器 TLS + h2）：
    //   /x/web-interface/nav → 200 isLogin=True
    //   /x/player/wbi/v2     → 200 + 该视频真实的字幕轨
    // 浏览器 TLS + h2、以及 HTTP/1.1 同样全部 200。所以 h2 可以正常使用。
    //
    // 万一以后 B站又抽风，只需把白名单改回 { QByteArrayLiteral("http/1.1") }
    // 即可整体回退到 HTTP/1.1。
    //
    // 注意：必须与上面的 PeerVerifyMode 在同一个默认配置里设置并一起写回，
    // 分两次 setDefaultConfiguration 会互相覆盖（本块在文件末尾，后写回）。
    // 且必须在任何 QNetworkAccessManager 发起请求之前调用。
    sslConfig.setAllowedNextProtocols({QByteArrayLiteral("h2"), QByteArrayLiteral("http/1.1")});
    QSslConfiguration::setDefaultConfiguration(sslConfig);
    qDebug("[BiliQt] HTTP/2 enabled (ALPN allows h2, auto-fallback http/1.1)");

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
    ImageActions imageActions;

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

    // 图片预览的「复制图片 / 下载图片」：QML 没有剪贴板与写文件 API，
    // 只能由 C++ 提供（详见 ImageActions 类注释）
    qmlRegisterSingletonType<ImageActions>("BiliQt", 1, 0, "ImageActions",
        [&](QQmlEngine *engine, QJSEngine *scriptEngine) -> QObject* {
            Q_UNUSED(engine)
            Q_UNUSED(scriptEngine)
            QQmlEngine::setObjectOwnership(&imageActions, QQmlEngine::CppOwnership);
            return &imageActions;
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

#ifndef Q_OS_WIN
    // 渲染后端诊断：弹幕模糊/高频重绘卡顿这类问题，最常见成因是 Qt 悄悄
    // 回退到软件渲染（llvmpipe/softpipe）。把实际用到的 GL renderer 与
    // RHI backend 打进日志，下次这类问题可以直接从日志判断，不必再靠猜。
    // 判读方法：出现 llvmpipe / softpipe 即为软件渲染，弹幕必然模糊且拖动卡顿。
    {
        const QString glRenderer = QString::fromLatin1(reinterpret_cast<const char *>(glGetString(GL_RENDERER)));
        const QString glVendor = QString::fromLatin1(reinterpret_cast<const char *>(glGetString(GL_VENDOR)));
        const QString glVersion = QString::fromLatin1(reinterpret_cast<const char *>(glGetString(GL_VERSION)));
        QByteArray rh;
        const char *rhi = qgetenv("QSG_RHI_BACKEND");
        rh = rhi ? QByteArray(rhi) : QByteArray("<default>");
        qInfo("[RHI] requested backend=%s", rh.constData());
        qInfo("[GL] renderer=%s vendor=%s version=%s",
              qPrintable(glRenderer), qPrintable(glVendor), qPrintable(glVersion));
        const bool software = glRenderer.contains("llvmpipe") || glRenderer.contains("softpipe")
                              || glRenderer.contains("SWR");
        if (software)
            qWarning("[RHI] 检测到**软件渲染**（%s）：弹幕等高频重绘内容会模糊且卡顿。"
                     "请确认目标机有可用的硬件 GL 驱动，或安装 libgl1-mesa-dri。",
                     qPrintable(glRenderer));
    }
#endif

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
