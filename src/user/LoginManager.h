#ifndef LOGINMANAGER_H
#define LOGINMANAGER_H

#include <QObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QString>
#include <QImage>
#include <QJsonObject>
#include <QTimer>

class LoginManager : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString userName READ userName NOTIFY userInfoChanged)
    Q_PROPERTY(QString userFace READ userFace NOTIFY userInfoChanged)
    Q_PROPERTY(bool isLoggedIn READ isLoggedIn NOTIFY userInfoChanged)
    Q_PROPERTY(QString qrCodeSource READ qrCodeSource NOTIFY qrCodeSourceChanged)
    Q_PROPERTY(QString loginStatusText READ loginStatusText NOTIFY loginStatusTextChanged)

public:
    explicit LoginManager(QObject *parent = nullptr);
    ~LoginManager();

    // 获取单例实例
    static LoginManager* instance();

    QString userName() const { return m_currentUser.uname; }
    QString userFace() const { return m_currentUser.face; }
    int mid() const { return m_currentUser.mid; }
    QString qrCodeSource() const { return m_qrCodeSource; }
    QString loginStatusText() const { return m_loginStatusText; }

    Q_INVOKABLE void getLoginQRCode();
    Q_INVOKABLE void logout();

    // 关闭本 manager 所有空闲 HTTP 连接，强制后续请求走全新 TCP/TLS 连接。
    // 用途：playurl 480P 降级状态绑定在连接层（重启客户端即恢复），
    // 关闭视频时复位连接 = 无需重启的"重启"。
    void resetHttpConnections();

    enum LoginStatus {
        StatusUnknown = 0,
        StatusWaiting = 1,      // 等待扫码
        StatusScanned = 2,       // 已扫码，待确认
        StatusConfirmed = 3,     // 已确认登录
        StatusExpired = 4,       // 二维码过期
        StatusFailed = 5         // 登录失败
    };
    Q_ENUM(LoginStatus)

    struct UserInfo {
        int mid;
        QString uname;
        QString face;
        bool isVIP;
        int vipType;
        int level;
        QString accessKey;
        QString sessData;    // SESSDATA cookie
        QString biliJct;     // bili_jct cookie (CSRF token)
        QString dedeUserId;  // DedeUserID cookie
        QString buvid3;      // buvid3 cookie (anti-crawler identification)
        QString buvid4;      // buvid4 cookie (extended fingerprint)
        QString bNut;        // b_nut cookie (fingerprint)
        QString acTimeValue;  // ac_time_value cookie
        QString biliTicket;   // bili_ticket cookie (anti-spider verification)
        QString gaiaVtoken;   // x-bili-gaia-vtoken cookie (PGC play auth)
    };

    // 下载二维码图片
    void downloadQRCode(const QString &url);

    // 检查登录状态
    void checkLoginStatus();

    // 获取当前用户信息
    UserInfo getCurrentUser() const { return m_currentUser; }
    
    // 是否已登录（通过标记位+用户名判断，避免依赖可能为空的 cookie 字段导致误判）
    bool isLoggedIn() const { return m_isLoggedIn && !m_currentUser.uname.isEmpty(); }
    
    // 获取Cookies
    QString getCookies() const;

    // 获取或生成 buvid3（B 站设备标识 cookie）
    QString getOrCreateBuvid3();

    // 获取 buvid4（设备指纹）
    QString getBuvid4() const { return m_currentUser.buvid4; }

    // 获取 b_nut（设备标识 cookie）
    QString getBNut() const { return m_currentUser.bNut; }

    // 获取 bili_ticket（反爬虫验证 cookie）
    QString getBiliTicket() const { return m_currentUser.biliTicket; }

    // 同步从 /x/frontend/finger/spi 获取服务器签发的真实 buvid3（未登录时必需）
    // 本地伪造的 buvid3 无法通过B站用户搜索的风控，会返回 v_voucher 验证响应。
    bool fetchBuvid3Sync();
    // 从 www.bilibili.com 首页获取真实的 b_nut（finger/spi 不返回 b_nut）
    void fetchBNutFromHomepageSync();
    // 同步获取 bili_ticket（未登录时用户搜索风控必需，没有会返回 v_voucher）
    bool fetchBiliTicketSync();

    // 确保拥有服务器签发的 buvid3（未登录时调用，已登录或已获取则跳过）
    void ensureServerBuvid3();

    // 获取 bili_ticket（反爬虫验证 cookie）
    void fetchBiliTicket();
    
    // 获取 buvid4（从 API）
    void fetchBuvid4();
    
    // 从 API 获取 bili_ticket（备选方式）
    void fetchBiliTicketFromApi();
    
    // 使用 HMAC 签名获取 bili_ticket（参考 blbl 项目）
    void fetchBiliTicketHmac();

    // 刷新 buvid 和 bili_ticket（用于风控绕过）
    void refreshDeviceFingerprint();

signals:
    // 二维码准备好
    void qrCodeReady(const QImage &image, const QString &oauthKey);

    // 登录状态更新
    void loginStatusChanged(LoginStatus status, const QString &message);

    // 登录成功
    void loginSuccess(const UserInfo &user);

    // 登录失败
    void loginFailed(const QString &error);

    // 获取失败
    void errorOccurred(const QString &error);

    // 用户信息变化
    void userInfoChanged();

    // 二维码图片源变化
    void qrCodeSourceChanged();

    // 登录状态提示文本变化
    void loginStatusTextChanged();

private slots:
    void onQRCodeReplyFinished();
    void onQRCodeImageFinished();
    void onCheckStatusReplyFinished();
    void onTimeout();
    void onNavReplyFinished();
    void onWbiRefreshTimer();  // 定期刷新 WBI 签名密钥，避免长跑后密钥过期 → playurl 风控降级 480P

private:
    void saveLoginData(const QJsonObject &data);
    void loadLoginData();
    void extractCookiesFromUrl(const QString &url);
    void extractCookiesFromHeaders(QNetworkReply *reply);
    void fetchUserInfo();
    void saveUserInfo();
    void loadUserInfoFromSavedData();
    // Cookie 缓存失效时重新拼接（UserInfo 任何字段变更 / 登录 / 登出 / 刷新指纹后 调一次）
    void invalidateCookieCache();

    QNetworkAccessManager *m_networkManager;
    QTimer *m_pollTimer;
    QTimer *m_wbiRefreshTimer;  // 定期刷新 WBI 密钥的定时器
    
    QString m_oauthKey;
    QString m_qrCodeUrl;
    QString m_qrCodeSource;
    QString m_loginStatusText;
    bool m_isLoggedIn;
    UserInfo m_currentUser;
    LoginStatus m_lastLoginStatus;
    
    static const QString USER_AGENT;
    static const QString APP_KEY;
    static const QString APP_SECRET;
    
    // 保存登录数据的文件路径
    static const QString LOGIN_DATA_FILE;

    // getCookies() 缓存（避免每次请求做十几次字符串 append）
    mutable bool m_cookiesCacheValid;
    mutable QString m_cachedFullCookies;

    // 标记 buvid3 是否来自服务器（本地伪造的 buvid3 无法通过用户搜索风控）
    bool m_buvid3FromServer;
    // 标记 b_nut 是否从 www.bilibili.com 首页获取（伪造的 b_nut 会触发 v_voucher 风控）
    bool m_bNutFromServer;
};

#endif // LOGINMANAGER_H
