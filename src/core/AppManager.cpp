#include "AppManager.h"
#include <QGuiApplication>
#include <QCursor>
#include <QSettings>
#include <QDebug>
#include <QWindow>
#include <QQuickWindow>
#include <QQuickItem>
#include <QScreen>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QUrl>
#include <QStringList>

#ifdef Q_OS_WIN
#include <windows.h>
#include <dwmapi.h>
// flushWindowSystemEvents：setWindowState 后 Qt 几何变更事件仍在窗口系统
// 事件队列中未派发，需 flush 后 geometry() 才反映还原后的普通态几何
#include <qpa/qwindowsysteminterface.h>
// Win11 圆角 API 常量：SDK 头缺失时自行补定义（值来自 Win11 SDK 的 dwmapi.h）
#ifndef DWMWA_WINDOW_CORNER_PREFERENCE
#define DWMWA_WINDOW_CORNER_PREFERENCE 33
#endif
#ifndef DWMWCP_ROUND
#define DWMWCP_ROUND 2
#endif
#ifndef DWMWCP_DEFAULT
#define DWMWCP_DEFAULT 0
#endif
#endif

AppManager* AppManager::s_instance = nullptr;

AppManager::AppManager(QObject *parent)
    : QObject(parent)
    , m_vulkanEnabled(false)
{
    s_instance = this;
}

AppManager::~AppManager() = default;

AppManager* AppManager::instance()
{
    return s_instance;
}

void AppManager::setRecommendScrollY(qreal y)
{
    if (qFuzzyCompare(m_recommendScrollY, y))
        return;
    m_recommendScrollY = y;
    emit recommendScrollYChanged();
}

void AppManager::setPlayerCursorHidden(bool hidden)
{
    if (hidden == m_playerCursorHidden)
        return;
    m_playerCursorHidden = hidden;
    if (hidden)
        QGuiApplication::setOverrideCursor(QCursor(Qt::BlankCursor));
    else
        QGuiApplication::restoreOverrideCursor();
}

void AppManager::registerMainWindow(QObject *windowObj)
{
    m_mainWindow = qobject_cast<QQuickWindow *>(windowObj);
}

void AppManager::setMiniPlayerHost(QQuickItem *host)
{
    if (m_miniPlayerHost == host)
        return;
    m_miniPlayerHost = host;
    emit miniPlayerHostChanged();
}

// 小窗播放（单窗口变身）：主窗口自身收缩为置顶小窗。
// 与旧"独立小窗+跨窗口迁移"方案的本质区别：播放器始终留在同一 QQuickWindow，
// 无渲染上下文/场景图/视频链重建——切换只表现为一次窗口尺寸变化，
// 直播音画天然同步（无音频时钟漂移），无任何卡顿。
void AppManager::enterMiniPlayerMode(int initialWidth, int initialHeight)
{
    if (m_miniPlayerMode || !m_mainWindow)
        return;

    // 保存变身前的窗口状态、最小尺寸、置顶偏好
    m_miniSavedState = m_mainWindow->windowState();
    m_miniSavedMinimumSize = m_mainWindow->minimumSize();
#ifdef Q_OS_WIN
    HWND hwnd = reinterpret_cast<HWND>(m_mainWindow->winId());
    m_miniSavedTopmost = hwnd
        && (::GetWindowLong(hwnd, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0;
#else
    m_miniSavedTopmost = false;
#endif

    // 保存普通态几何：QWindow 没有 normalGeometry()（那是 QWidget 的），
    // 最大化/全屏时 geometry() 返回的是最大化矩形。先回普通态再取几何：
    // Windows 下 ShowWindow(SW_SHOWNORMAL) 原生同步完成还原，但 Qt 的
    // 几何变更事件经窗口系统事件队列异步派发，flush 后 geometry() 才是
    // 还原后的普通态几何（若误存最大化矩形，退出小窗后点"还原"会得到
    // 近全屏的错误普通态尺寸）
    if (m_miniSavedState != Qt::WindowNoState) {
        m_mainWindow->setWindowState(Qt::WindowNoState);
#ifdef Q_OS_WIN
        QWindowSystemInterface::flushWindowSystemEvents(
            QEventLoop::ExcludeUserInputEvents);
#endif
    }
    m_miniSavedGeometry = m_mainWindow->geometry();

    // 放宽最小尺寸后收缩为小窗，当前屏幕可用区居中
    m_mainWindow->setMinimumSize(QSize(160, 90));
    QScreen *screen = m_mainWindow->screen();
    if (!screen)
        screen = QGuiApplication::primaryScreen();
    const QRect avail = screen ? screen->availableGeometry() : QRect(0, 0, initialWidth, initialHeight);
    const int w = qBound(160, initialWidth, avail.width());
    const int h = qBound(90, initialHeight, avail.height());
    m_mainWindow->setGeometry(avail.x() + (avail.width() - w) / 2,
                              avail.y() + (avail.height() - h) / 2, w, h);

    m_miniPlayerMode = true;
    emit miniPlayerModeChanged();

#ifdef Q_OS_WIN
    // 置顶 + Win11 圆角：原生路径，不改 Qt flags、不重建窗口
    //（改 flags 会触发窗口销毁重建，场景图失效，违背单窗口方案初衷）
    if (hwnd) {
        ::SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                       SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        DWORD pref = DWMWCP_ROUND;
        DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE,
                              &pref, sizeof(pref));
    }
#endif
}

void AppManager::exitMiniPlayerMode()
{
    if (!m_miniPlayerMode || !m_mainWindow)
        return;

    m_miniPlayerMode = false;
    // 先通知 QML：页面把播放器 reparent 回页面布局、main.qml 恢复常规 UI
    //（绑定/Connections 同步求值，返回时界面结构已就位）
    emit miniPlayerModeChanged();

    // 恢复最小尺寸/几何/窗口状态（最大化等）。播放器已回页面布局，
    // 窗口放大后 anchors 同步 relayout，下一帧即完整画面
    m_mainWindow->setMinimumSize(m_miniSavedMinimumSize);
    m_mainWindow->setGeometry(m_miniSavedGeometry);
    if (m_miniSavedState != Qt::WindowNoState)
        m_mainWindow->setWindowState(m_miniSavedState);
    m_mainWindow->raise();
    m_mainWindow->requestActivate();

#ifdef Q_OS_WIN
    HWND hwnd = reinterpret_cast<HWND>(m_mainWindow->winId());
    if (hwnd) {
        // 置顶恢复：变身前已置顶（用户 stayTop 偏好）则保持，否则取消
        if (!m_miniSavedTopmost)
            ::SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0,
                           SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        DWORD pref = DWMWCP_DEFAULT;
        DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE,
                              &pref, sizeof(pref));
    }
#endif

    emit miniPlayerModeExited();
}

bool AppManager::startSystemMove()
{
    return m_mainWindow ? m_mainWindow->startSystemMove() : false;
}

QString AppManager::environmentVariable(const QString &name)
{
    return qEnvironmentVariable(name.toUtf8().constData());
}

void AppManager::minimizeWindow(QObject *windowObj)
{
    QWindow *w = qobject_cast<QWindow *>(windowObj);
    if (!w)
        return;
#ifdef Q_OS_WIN
    // 走系统 WM_SYSCOMMAND/SC_MINIMIZE 路径（与任务栏最小化相同），
    // 由系统正确移交前台焦点；Qt 的 showMinimized() 最小化后窗口仍被视为
    // 前台活动窗口，导致再点任务栏图标被当作"最小化活动窗口"而不还原。
    HWND hwnd = reinterpret_cast<HWND>(w->winId());
    if (hwnd) {
        ::PostMessage(hwnd, WM_SYSCOMMAND, SC_MINIMIZE, 0);
    }
#else
    w->showMinimized();
#endif
}

void AppManager::detectRenderer()
{
    QByteArray backend = qgetenv("QSG_RHI_BACKEND");
    if (backend.isEmpty()) {
        m_rendererBackend = "default (auto)";
    } else {
        m_rendererBackend = QString::fromUtf8(backend);
    }
    m_vulkanEnabled = (backend == "vulkan");
}

void AppManager::openVideo(const QString &bvid, const QString &title)
{
    // 防止双击/多页面同时响应导致视频页被重复打开
    if (m_lastOpenBvid == bvid && m_lastOpenTimer.isValid() && m_lastOpenTimer.elapsed() < 800) {
        qDebug() << "[AppManager] ignore duplicate openVideo:" << bvid;
        return;
    }
    m_lastOpenBvid = bvid;
    m_lastOpenTimer.start();
    emit videoOpenRequested(bvid, title);
}

void AppManager::openBangumi(const QString &bvid, const QString &epId, const QString &seasonId, const QString &title)
{
    QString key = "bangumi_" + (epId.isEmpty() ? seasonId : epId);
    if (m_lastOpenBvid == key && m_lastOpenTimer.isValid() && m_lastOpenTimer.elapsed() < 800) {
        qDebug() << "[AppManager] ignore duplicate openBangumi:" << key;
        return;
    }
    m_lastOpenBvid = key;
    m_lastOpenTimer.start();
    emit bangumiOpenRequested(bvid, epId, seasonId, title);
}

void AppManager::closeVideo()
{
    emit videoCloseRequested();
}

void AppManager::openUserProfile(const QString &mid, const QString &name, const QString &face, int verify)
{
    QString key = "up_" + mid;
    if (m_lastOpenBvid == key && m_lastOpenTimer.isValid() && m_lastOpenTimer.elapsed() < 800) {
        qDebug() << "[AppManager] ignore duplicate openUserProfile:" << mid;
        return;
    }
    m_lastOpenBvid = key;
    m_lastOpenTimer.start();
    emit userProfileOpenRequested(mid, name, face, verify);
}

void AppManager::closeUserProfile()
{
    emit userProfileCloseRequested();
}

// b23.tv 短链解析：GET 短链并跟随 302，把最终地址回传给 QML。
// 评论区里 `https://b23.tv/WW3i6Ml` 这类短链不含视频号，渲染阶段无法判断
// 目标类型，只能点开时解析；拿到最终地址后才能决定走应用内播放页还是浏览器。
// 一次性 QNAM：与 PlayUrlManager 同策略（不长期复用连接）。
// host 白名单 + 只允许 http(s)：不让调用方诱导本客户端请求任意地址。
void AppManager::resolveShortLink(const QString &url)
{
    const QUrl u(url);
    static const QStringList allowedHosts = {
        QStringLiteral("b23.tv"), QStringLiteral("bili23.cn"),
        QStringLiteral("bilibili.com"), QStringLiteral("www.bilibili.com"),
        QStringLiteral("m.bilibili.com")
    };
    const QString scheme = u.scheme().toLower();
    if (!u.isValid()
        || (scheme != QStringLiteral("http") && scheme != QStringLiteral("https"))
        || !allowedHosts.contains(u.host().toLower())) {
        qWarning() << "[AppManager] resolveShortLink rejected:" << url;
        emit shortLinkResolved(url, QString());
        return;
    }

    QNetworkRequest request(u);
    // 跟随重定向：NoLessSafeRedirectPolicy 只跟 http(s)→http(s)，拒绝被降级
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                         QNetworkRequest::NoLessSafeRedirectPolicy);
    // 10s 传输超时：短链服务正常 1s 内返回，超时按解析失败处理（回退浏览器）
    request.setTransferTimeout(10000);
    request.setRawHeader("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36");
    request.setRawHeader("Referer", "https://www.bilibili.com/");

    QNetworkAccessManager *manager = new QNetworkAccessManager(this);
    QNetworkReply *reply = manager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, manager, url]() {
        manager->deleteLater();
        // 跟随重定向后 reply->url() 即最终地址；失败给空串让 QML 回退浏览器
        QString finalUrl;
        if (reply->error() == QNetworkReply::NoError) {
            finalUrl = reply->url().toString();
        } else {
            qWarning() << "[AppManager] resolveShortLink error:" << reply->error()
                       << reply->errorString();
        }
        qDebug() << "[AppManager] resolveShortLink" << url << "->" << finalUrl;
        emit shortLinkResolved(url, finalUrl);
        reply->deleteLater();
    });
}

void AppManager::closeTab(int index)
{
    emit tabCloseRequested(index);
}

QVariantMap AppManager::loadWindowGeometry() const
{
    QSettings settings(QGuiApplication::organizationName(), QGuiApplication::applicationName());
    QVariantMap geom;

    // 当默认窗口尺寸策略发生变化时，递增此版本号，避免旧保存的几何覆盖新默认值
    const int currentGeometryVersion = 5;
    const int savedVersion = settings.value("window/geometryVersion", 0).toInt();
    if (savedVersion != currentGeometryVersion) {
        settings.setValue("window/geometryVersion", currentGeometryVersion);
        geom["x"] = 0;
        geom["y"] = 0;
        geom["width"] = 1136;
        geom["height"] = 700;
        return geom;
    }

    geom["x"] = settings.value("window/x", 0).toInt();
    geom["y"] = settings.value("window/y", 0).toInt();
    geom["width"] = settings.value("window/width", 1136).toInt();
    geom["height"] = settings.value("window/height", 700).toInt();
    return geom;
}

void AppManager::saveWindowGeometry(int x, int y, int width, int height)
{
    QSettings settings(QGuiApplication::organizationName(), QGuiApplication::applicationName());
    settings.setValue("window/geometryVersion", 5);
    settings.setValue("window/x", x);
    settings.setValue("window/y", y);
    settings.setValue("window/width", width);
    settings.setValue("window/height", height);
}

bool AppManager::loadTheme() const
{
    QSettings settings(QGuiApplication::organizationName(), QGuiApplication::applicationName());
    // 无历史记录（首次运行）默认白天主题
    return settings.value("theme/dark", false).toBool();
}

void AppManager::saveTheme(bool dark)
{
    QSettings settings(QGuiApplication::organizationName(), QGuiApplication::applicationName());
    settings.setValue("theme/dark", dark);
}
