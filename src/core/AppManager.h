#ifndef APP_MANAGER_H
#define APP_MANAGER_H

#include <QObject>
#include <QVariantMap>
#include <QElapsedTimer>
#include <QRect>
// Q_PROPERTY(QQuickItem*) 需要：QQuickItem 完整类型 + 指针元类型注册
//（仅有前置声明时 moc 生成的属性元调用代码在元类型系统注册处编译失败）
#include <QQuickItem>

class AppManager : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool vulkanEnabled READ vulkanEnabled CONSTANT)
    Q_PROPERTY(QString rendererBackend READ rendererBackend CONSTANT)
    Q_PROPERTY(qreal recommendScrollY READ recommendScrollY WRITE setRecommendScrollY NOTIFY recommendScrollYChanged)
    // 小窗播放模式（单窗口变身）：主窗口自身收缩为置顶小窗，播放器在
    // 同一窗口内 reparent 到 miniPlayerHost，不跨窗口、不重建渲染上下文
    Q_PROPERTY(bool miniPlayerMode READ miniPlayerMode NOTIFY miniPlayerModeChanged)
    // 小窗播放器宿主层（main.qml 中的全窗口顶层 Item），页面 reparent 挂载点
    Q_PROPERTY(QQuickItem* miniPlayerHost READ miniPlayerHost WRITE setMiniPlayerHost NOTIFY miniPlayerHostChanged)

public:
    explicit AppManager(QObject *parent = nullptr);
    ~AppManager();

    static AppManager* instance();

    bool vulkanEnabled() const { return m_vulkanEnabled; }
    QString rendererBackend() const { return m_rendererBackend; }
    qreal recommendScrollY() const { return m_recommendScrollY; }
    void setRecommendScrollY(qreal y);

    bool miniPlayerMode() const { return m_miniPlayerMode; }
    QQuickItem *miniPlayerHost() const { return m_miniPlayerHost; }
    void setMiniPlayerHost(QQuickItem *host);

    Q_INVOKABLE void detectRenderer();
    Q_INVOKABLE void openVideo(const QString &bvid, const QString &title);
    Q_INVOKABLE void openBangumi(const QString &bvid, const QString &epId, const QString &seasonId, const QString &title);
    Q_INVOKABLE void closeVideo();
    Q_INVOKABLE void openUserProfile(const QString &mid, const QString &name = "", const QString &face = "", int verify = -1);
    Q_INVOKABLE void closeUserProfile();
    Q_INVOKABLE void closeTab(int index);
    Q_INVOKABLE QVariantMap loadWindowGeometry() const;
    Q_INVOKABLE void saveWindowGeometry(int x, int y, int width, int height);
    // ===== 主题持久化 =====
    // dark=true 夜间主题。QSettings 写在 AppManager 侧（与窗口几何同一
    // 存储），QML 启动时 loadTheme 恢复、changeDark 时 saveTheme 落盘
    Q_INVOKABLE bool loadTheme() const;
    Q_INVOKABLE void saveTheme(bool dark);
    // 原生方式最小化窗口（走 WM_SYSCOMMAND，与任务栏最小化同路径，
    // 避免 Qt showMinimized 导致窗口最小化后仍持有前台焦点、任务栏图标点击无法还原）
    Q_INVOKABLE void minimizeWindow(QObject *windowObj);
    // 播放器鼠标指针自动隐藏：应用级 override cursor（Blank）。
    // 不用 QML MouseArea 的 cursorShape 实现——叠层顺序/visible 切换时
    // 窗口光标不会随静止鼠标重新求值，会出现残留可见光标。
    Q_INVOKABLE void setPlayerCursorHidden(bool hidden);
    // 主窗口注册（小窗模式窗口变身与系统原生移动都需要主窗口指针）
    Q_INVOKABLE void registerMainWindow(QObject *windowObj);
    // ===== 小窗播放（单窗口变身）=====
    // 进入：主窗口自身收缩为 initialWidth x initialHeight 的置顶小窗
    //（当前屏幕可用区居中），保存原几何/状态/最小尺寸；置顶与 Win11
    // 圆角走原生 SetWindowPos / DwmSetWindowAttribute，不改 Qt flags、
    // 不重建窗口、不影响场景图。miniPlayerModeChanged 发出后 main.qml
    // 隐藏导航/页面栈并显示宿主层，页面把播放器 reparent 过去（同窗口
    // reparent，播放/弹幕时间轴完全不中断）
    Q_INVOKABLE void enterMiniPlayerMode(int initialWidth, int initialHeight);
    // 退出：先发 miniPlayerModeChanged(false)（页面同步 reparent 回位、
    // main.qml 恢复常规 UI），再恢复最小尺寸/几何/窗口状态（最大化等）
    // 与置顶/圆角偏好。miniPlayerModeExited 在一切恢复完成后发出
    Q_INVOKABLE void exitMiniPlayerMode();
    // 系统原生移动（小窗拖动，作用于已注册的主窗口）：SC_MOVE 模态循环
    // 与真实标题栏拖动同路径，无逐事件 setGeometry 的中间态颤动
    Q_INVOKABLE bool startSystemMove();
    // 读进程环境变量（QML 侧 main.qml 的弹幕驱动链自动测试等使用）
    Q_INVOKABLE static QString environmentVariable(const QString &name);

signals:
    void videoOpenRequested(const QString &bvid, const QString &title);
    void bangumiOpenRequested(const QString &bvid, const QString &epId, const QString &seasonId, const QString &title);
    void videoCloseRequested();
    void userProfileOpenRequested(const QString &mid, const QString &name, const QString &face, int verify);
    void userProfileCloseRequested();
    void tabCloseRequested(int index);
    void recommendScrollYChanged();
    void miniPlayerModeChanged();
    void miniPlayerModeExited();
    void miniPlayerHostChanged();

private:
    static AppManager *s_instance;
    bool m_vulkanEnabled;
    QString m_rendererBackend;
    qreal m_recommendScrollY = 0;
    bool m_playerCursorHidden = false;
    class QQuickWindow *m_mainWindow = nullptr;
    // ===== 小窗播放（单窗口变身）=====
    bool m_miniPlayerMode = false;
    QQuickItem *m_miniPlayerHost = nullptr;
    QRect m_miniSavedGeometry;                 // 变身前的普通态几何（恢复用）
    Qt::WindowState m_miniSavedState = Qt::WindowNoState;  // 变身前的窗口状态（最大化等）
    QSize m_miniSavedMinimumSize;              // 变身前的最小尺寸（主窗口 1120x640）
    bool m_miniSavedTopmost = false;           // 变身前是否已置顶（保留用户 stayTop 偏好）
    QString m_lastOpenBvid;
    QElapsedTimer m_lastOpenTimer;
};

// QQuickItem* 作为 Q_PROPERTY 类型暴露给 QML 时的元类型声明
Q_DECLARE_METATYPE(QQuickItem*)

#endif
