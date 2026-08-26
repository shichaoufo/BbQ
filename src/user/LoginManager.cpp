#include "LoginManager.h"
#include "QRCodeGenerator.h"
#include "WbiSigner.h"
#include <QCryptographicHash>
#include <QMessageAuthenticationCode>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QUrlQuery>
#include <QDateTime>

#include <QFile>
#include <QDir>
#include <QImage>
#include <QRegularExpression>
#include <QRandomGenerator>
#include <QStandardPaths>
#include <QUrl>
#include <QCoreApplication>
#include <QElapsedTimer>

const QString LoginManager::USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
const QString LoginManager::APP_KEY = "1d8b6e7d45233436";
const QString LoginManager::APP_SECRET = "560c52ccd288fed045859ed18bffd973";
const QString LoginManager::LOGIN_DATA_FILE = "login_data.json";

static LoginManager* s_loginManagerInstance = nullptr;

LoginManager* LoginManager::instance()
{
    if (!s_loginManagerInstance) {
        s_loginManagerInstance = new LoginManager();
    }
    return s_loginManagerInstance;
}

LoginManager::LoginManager(QObject *parent)
    : QObject(parent)
    , m_networkManager(new QNetworkAccessManager(this))
    , m_pollTimer(new QTimer(this))
    , m_loginStatusText("未登录")
    , m_isLoggedIn(false)
    , m_lastLoginStatus(StatusUnknown)
    , m_cookiesCacheValid(false)
    , m_buvid3FromServer(false)
    , m_bNutFromServer(false)
{
    // 必须在构造函数最开始设置 s_loginManagerInstance，避免构造期间调用 instance() 导致递归构造
    s_loginManagerInstance = this;

    connect(m_pollTimer, &QTimer::timeout, this, &LoginManager::onTimeout);

    // 定期刷新 WBI 签名密钥：signParams 只在 mixinKey 为空时才取新 key，
    // 一旦填充后不会自动刷新。长跑后服务端轮换 key 会导致签名失效 →
    // playurl 返回 -351 风控 → 视频降级到 480P（直播不受影响，因直播 API 不用 WBI）。
    // 每 30 分钟主动 forceRefreshKeys 一次，保持密钥新鲜。
    m_wbiRefreshTimer = new QTimer(this);
    m_wbiRefreshTimer->setInterval(30 * 60 * 1000);  // 30 分钟
    connect(m_wbiRefreshTimer, &QTimer::timeout, this, &LoginManager::onWbiRefreshTimer);
    m_wbiRefreshTimer->start();

    // 二维码生成后保存为本地图片，供 QML 显示
    connect(this, &LoginManager::qrCodeReady, this, [this](const QImage &image, const QString &) {
        QString tempPath = QStandardPaths::writableLocation(QStandardPaths::TempLocation) + "/biliqt_qrcode.png";
        if (image.save(tempPath)) {
            QString url = QUrl::fromLocalFile(tempPath).toString();
            // 追加时间戳，防止 QML Image 因 URL 相同而不重新加载
            url += "?t=" + QString::number(QDateTime::currentMSecsSinceEpoch());
            m_qrCodeSource = url;
            emit qrCodeSourceChanged();
        }
    });

    // 尝试加载已保存的用户信息（包含头像）
    loadUserInfoFromSavedData();

    // 确保 buvid3 已生成（即使未登录也需要）
    getOrCreateBuvid3();

    // 获取 bili_ticket（反爬虫验证 cookie）
    QTimer::singleShot(1000, this, &LoginManager::fetchBiliTicket);
}

LoginManager::~LoginManager()
{
    if (m_pollTimer->isActive()) {
        m_pollTimer->stop();
    }
    if (m_wbiRefreshTimer && m_wbiRefreshTimer->isActive()) {
        m_wbiRefreshTimer->stop();
    }
}

void LoginManager::getLoginQRCode()
{
    m_loginStatusText = "正在获取二维码...";
    emit loginStatusTextChanged();

    // 使用B站新的登录二维码API
    QString url = "https://passport.bilibili.com/x/passport-login/web/qrcode/generate";

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), USER_AGENT.toUtf8());
    request.setRawHeader(QByteArray("Referer"), QByteArray("https://passport.bilibili.com/"));

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, &LoginManager::onQRCodeReplyFinished);
}

void LoginManager::onQRCodeReplyFinished()
{
    QNetworkReply *reply = qobject_cast<QNetworkReply*>(sender());
    if (!reply) return;

    if (reply->error() != QNetworkReply::NoError) {
        QString errorMsg = QString("Network error: %1").arg(reply->errorString());
        emit errorOccurred(errorMsg);
        reply->deleteLater();
        return;
    }

    QByteArray data = reply->readAll();

    QJsonDocument doc = QJsonDocument::fromJson(data);

    if (!doc.isObject()) {
        emit errorOccurred("Invalid JSON format");
        reply->deleteLater();
        return;
    }

    QJsonObject root = doc.object();
    int code = root["code"].toInt();

    if (code != 0) {
        QString message = root["message"].toString();
        emit errorOccurred(QString("API error: %1 (code: %2)").arg(message).arg(code));
        reply->deleteLater();
        return;
    }

    QJsonObject dataObj = root["data"].toObject();

    m_oauthKey = dataObj["qrcode_key"].toString();
    m_qrCodeUrl = dataObj["url"].toString();

    // 使用本地二维码生成器生成二维码
    if (!m_qrCodeUrl.isEmpty()) {
        QImage qrImage = QRCodeGenerator::generate(m_qrCodeUrl, 280);
        if (qrImage.isNull()) {
            qrImage = QImage(280, 280, QImage::Format_RGB32);
            qrImage.fill(Qt::white);
        }
        emit qrCodeReady(qrImage, m_oauthKey);
    } else {
        QImage qrImage(280, 280, QImage::Format_RGB32);
        qrImage.fill(Qt::white);
        emit qrCodeReady(qrImage, m_oauthKey);
    }

    m_loginStatusText = "请扫描二维码登录";
    emit loginStatusTextChanged();

    if (m_lastLoginStatus != StatusWaiting) {
        m_lastLoginStatus = StatusWaiting;
        emit loginStatusChanged(StatusWaiting, "请扫描二维码登录");
    }

    // 开始轮询检查登录状态
    m_pollTimer->start(3000); // 每3秒检查一次

    reply->deleteLater();
}

void LoginManager::downloadQRCode(const QString &url)
{
    QNetworkRequest request(url);
    request.setRawHeader(QByteArray("User-Agent"), USER_AGENT.toUtf8());
    request.setRawHeader(QByteArray("Referer"), QByteArray("https://passport.bilibili.com/"));

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, &LoginManager::onQRCodeImageFinished);
}

void LoginManager::onQRCodeImageFinished()
{
    QNetworkReply *reply = qobject_cast<QNetworkReply*>(sender());
    if (!reply) return;

    if (reply->error() != QNetworkReply::NoError) {

        // 失败时使用占位图
        QImage qrImage(200, 200, QImage::Format_RGB32);
        qrImage.fill(Qt::white);
        emit qrCodeReady(qrImage, m_oauthKey);
        reply->deleteLater();
        return;
    }

    QByteArray data = reply->readAll();
    QImage image;
    if (image.loadFromData(data)) {
        emit qrCodeReady(image, m_oauthKey);
    } else {
        QImage qrImage(200, 200, QImage::Format_RGB32);
        qrImage.fill(Qt::white);
        emit qrCodeReady(qrImage, m_oauthKey);
    }

    reply->deleteLater();
}

void LoginManager::checkLoginStatus()
{
    if (m_oauthKey.isEmpty()) {

        return;
    }

    QString url = QString("https://passport.bilibili.com/x/passport-login/web/qrcode/poll?qrcode_key=%1")
                      .arg(m_oauthKey);

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), USER_AGENT.toUtf8());
    request.setRawHeader(QByteArray("Referer"), QByteArray("https://passport.bilibili.com/"));

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, &LoginManager::onCheckStatusReplyFinished);
}

void LoginManager::onCheckStatusReplyFinished()
{
    QNetworkReply *reply = qobject_cast<QNetworkReply*>(sender());
    if (!reply) return;
    
    if (reply->error() != QNetworkReply::NoError) {
        reply->deleteLater();
        return;
    }
    
    QByteArray data = reply->readAll();
    QJsonDocument doc = QJsonDocument::fromJson(data);
    
    if (!doc.isObject()) {
        reply->deleteLater();
        return;
    }
    
    QJsonObject root = doc.object();
    int code = root["code"].toInt();
    
    LoginStatus status = StatusUnknown;
    QString message;

    QJsonObject dataObj = root["data"].toObject();
    int dataCode = dataObj["code"].toInt();

    switch (dataCode) {
        case 0:  // 登录成功
        {
            status = StatusConfirmed;
            m_pollTimer->stop();

            QString url = dataObj["url"].toString();

            // 新版 B站登录可能只在响应头 Set-Cookie 中下发 SESSDATA，URL 中可能没有。
            // 两处都提取，确保不会丢失登录 Cookie。
            extractCookiesFromUrl(url);
            extractCookiesFromHeaders(reply);
            qDebug() << "[LoginManager] after extract, sessData empty:" << m_currentUser.sessData.isEmpty()
                     << "biliJct empty:" << m_currentUser.biliJct.isEmpty()
                     << "dedeUserId empty:" << m_currentUser.dedeUserId.isEmpty();
            saveLoginData(dataObj);
            fetchUserInfo();

            break;
        }

        case 86038:  // 二维码已过期
            status = StatusExpired;
            message = "二维码已过期，请重新获取";
            m_pollTimer->stop();
            break;

        case 86090:  // 已扫描未确认
            status = StatusScanned;
            message = "请在手机端确认登录";
            break;

        case 86101:  // 未扫描
            status = StatusWaiting;
            message = "等待扫码...";
            break;

        default:
            status = StatusFailed;
            message = QString("状态码: %1").arg(dataCode);
            break;
    }

    if (status == StatusConfirmed) {
        message = "登录成功，正在获取用户信息...";
    }
    m_loginStatusText = message;
    emit loginStatusTextChanged();

    // 只在登录成功或退出登录时发出信号，轮询期间的状态变化不需要触发页面刷新
    // 注意：StatusConfirmed 状态的信号延后到 fetchUserInfo 完成后发出，
    // 确保 isLoggedIn() 返回 true 时再触发页面刷新
    if (m_lastLoginStatus != status && status == StatusUnknown) {
        m_lastLoginStatus = status;
        emit loginStatusChanged(status, message);
    }

    reply->deleteLater();
}

void LoginManager::logout()
{
    m_isLoggedIn = false;
    m_currentUser = UserInfo();
    m_buvid3FromServer = false;
    m_bNutFromServer = false;
    emit userInfoChanged();

    m_loginStatusText = "未登录";
    emit loginStatusTextChanged();

    // 删除保存的登录数据
    QFile loginFile(LOGIN_DATA_FILE);
    if (loginFile.exists()) {
        loginFile.remove();
    }
    
    // 删除保存的用户信息
    QFile userInfoFile("user_info.json");
    if (userInfoFile.exists()) {
        userInfoFile.remove();
    }
    
    if (m_lastLoginStatus != StatusUnknown) {
        m_lastLoginStatus = StatusUnknown;
        emit loginStatusChanged(StatusUnknown, "已退出登录");
    }

    invalidateCookieCache();
}

void LoginManager::onTimeout()
{
    checkLoginStatus();
}

void LoginManager::onWbiRefreshTimer()
{
    // 定期刷新 WBI 签名密钥，保持与服务端轮换同步。
    // forceRefreshKeys 内部是同步网络请求（processEvents 循环），最坏阻塞约 10s，
    // 但 30 分钟才触发一次，且 processEvents 期间 UI 仍可响应，可接受。
    WbiSigner::instance()->forceRefreshKeys();
}

void LoginManager::saveLoginData(const QJsonObject &data)
{
    QFile file(LOGIN_DATA_FILE);
    if (file.open(QIODevice::WriteOnly)) {
        QJsonDocument doc(data);
        file.write(doc.toJson());
        file.close();

    }
}

void LoginManager::loadLoginData()
{
    QFile file(LOGIN_DATA_FILE);
    if (!file.exists()) {
        return;
    }
    
    if (file.open(QIODevice::ReadOnly)) {
        QByteArray data = file.readAll();
        QJsonDocument doc = QJsonDocument::fromJson(data);
        
        if (doc.isObject()) {
            QJsonObject obj = doc.object();
            
            m_currentUser.uname = obj["uname"].toString();
            m_currentUser.mid = obj["mid"].toInt();
            m_currentUser.accessKey = obj["access_token"].toString();
            
            // 加载头像 URL
            if (obj.contains("url") && obj["url"].isString()) {
                m_currentUser.face = obj["url"].toString();
            } else if (obj.contains("face_url") && obj["face_url"].isString()) {
                m_currentUser.face = obj["face_url"].toString();
            }
            
            m_isLoggedIn = true;
            emit userInfoChanged();
        }
        
        file.close();
    }
}

QString LoginManager::getCookies() const
{
    // 只有在登录状态时才返回完整的 Cookie 字符串
    // 未登录时返回空字符串，避免API因无效cookie返回错误
    if (!isLoggedIn()) {
        return QString();
    }

    // ====== Cookie 字符串缓存（16 次调用 → 仅第一次拼接，后续直接返回）======
    if (m_cookiesCacheValid) {
        // 缓存命中：只打印一次调试日志（避免刷屏）
        static int hitCountDebug = 0;
        hitCountDebug++;
        if (hitCountDebug == 1) {
            qDebug() << "[LoginManager] getCookies - cache hit (subsequent hits silent)";
        }
        return m_cachedFullCookies;
    }

    // 返回完整的 Cookie 字符串（参考blbl项目的完整认证信息）
    QString cookie;
    if (!m_currentUser.sessData.isEmpty()) {
        cookie += QString("SESSDATA=%1; ").arg(m_currentUser.sessData);
    }
    if (!m_currentUser.biliJct.isEmpty()) {
        cookie += QString("bili_jct=%1; ").arg(m_currentUser.biliJct);
    }
    if (!m_currentUser.dedeUserId.isEmpty()) {
        cookie += QString("DedeUserID=%1; ").arg(m_currentUser.dedeUserId);
    }
    // buvid3 是 B站识别设备的关键 cookie
    if (!m_currentUser.buvid3.isEmpty()) {
        cookie += QString("buvid3=%1; ").arg(m_currentUser.buvid3);
    }
    // buvid4 是扩展的设备指纹
    if (!m_currentUser.buvid4.isEmpty()) {
        cookie += QString("buvid4=%1; ").arg(m_currentUser.buvid4);
    }
    // b_nut 是必须的 cookie（从首页获取）
    if (!m_currentUser.bNut.isEmpty()) {
        cookie += QString("b_nut=%1; ").arg(m_currentUser.bNut);
    }
    // bili_ticket 是反爬虫验证cookie
    if (!m_currentUser.biliTicket.isEmpty()) {
        cookie += QString("bili_ticket=%1; ").arg(m_currentUser.biliTicket);
    }
    // CURRENT_FNVAL 控制返回的流格式
    cookie += "CURRENT_FNVAL=4048; ";
    
    // 调试日志（只在首次构建 / 缓存失效时打印，避免频繁刷屏）
    qDebug() << "[LoginManager] getCookies - BUILD (cache miss) - buvid3:" << !m_currentUser.buvid3.isEmpty()
             << "buvid4:" << !m_currentUser.buvid4.isEmpty()
             << "b_nut:" << !m_currentUser.bNut.isEmpty()
             << "bili_ticket:" << !m_currentUser.biliTicket.isEmpty();

    // 缓存结果
    m_cachedFullCookies = cookie;
    m_cookiesCacheValid = true;

    return cookie;
}

void LoginManager::invalidateCookieCache()
{
    m_cookiesCacheValid = false;
    m_cachedFullCookies.clear();
    qDebug() << "[LoginManager] invalidateCookieCache - cookie cache cleared";
}

bool LoginManager::fetchBuvid3Sync()
{
    // 同步从 /x/frontend/finger/spi 获取服务器签发的真实 buvid3 和 buvid4。
    // 本地伪造的 buvid3（随机UUID+infoc）无法通过B站用户搜索的风控，
    // 服务器会返回 v_voucher 验证响应而非搜索结果。
    qDebug() << "[LoginManager] fetchBuvid3Sync called, current buvid3:" << !m_currentUser.buvid3.isEmpty();

    QNetworkRequest request(QUrl("https://api.bilibili.com/x/frontend/finger/spi"));
    request.setRawHeader("User-Agent", USER_AGENT.toUtf8());
    request.setRawHeader("Referer", "https://www.bilibili.com/");
    request.setRawHeader("Origin", "https://www.bilibili.com");

    QNetworkReply *reply = m_networkManager->get(request);

    // 使用 processEvents 同步等待（与 WbiSigner::fetchKeysSync 相同的模式）
    QElapsedTimer timer;
    timer.start();
    while (!reply->isFinished() && timer.elapsed() < 8000) {
        QCoreApplication::processEvents(QEventLoop::ExcludeUserInputEvents, 50);
    }

    bool success = false;
    if (reply->isFinished() && reply->error() == QNetworkReply::NoError) {
        QByteArray data = reply->readAll();
        qDebug() << "[LoginManager] fetchBuvid3Sync response:" << QString::fromUtf8(data.left(300));
        QJsonDocument doc = QJsonDocument::fromJson(data);
        if (doc.isObject()) {
            QJsonObject root = doc.object();
            if (root["code"].toInt() == 0 && root.contains("data")) {
                QJsonObject dataObj = root["data"].toObject();
                if (dataObj.contains("b_3")) {
                    QString realBuvid3 = dataObj["b_3"].toString();
                    if (!realBuvid3.isEmpty()) {
                        m_currentUser.buvid3 = realBuvid3;
                        qDebug() << "[LoginManager] fetchBuvid3Sync - got real buvid3 from server";
                        success = true;
                    }
                }
                if (dataObj.contains("b_4")) {
                    m_currentUser.buvid4 = dataObj["b_4"].toString();
                    qDebug() << "[LoginManager] fetchBuvid3Sync - got buvid4 from server";
                }
            }
        }
    } else {
        qDebug() << "[LoginManager] fetchBuvid3Sync failed:" << reply->error() << reply->errorString();
    }

    reply->deleteLater();

    // finger/spi 不返回 b_nut，需要访问 www.bilibili.com 首页获取真实的 b_nut
    // B站风控能识别伪造的 b_nut（如时间戳），必须从服务器获取真实值
    if (success) {
        fetchBNutFromHomepageSync();
        m_buvid3FromServer = true;
        invalidateCookieCache();
        saveUserInfo();
    }

    qDebug() << "[LoginManager] fetchBuvid3Sync result:" << success;
    return success;
}

// 从 www.bilibili.com 首页获取 b_nut 和 buvid3（参考 biliuwp-lite BNut() 实现）
// 关键：buvid3 和 b_nut 必须来自同一次首页访问，否则B站风控会返回 v_voucher
void LoginManager::fetchBNutFromHomepageSync()
{
    qDebug() << "[LoginManager] fetchBNutFromHomepageSync called";

    QNetworkRequest request(QUrl("https://www.bilibili.com/"));
    request.setRawHeader("User-Agent", USER_AGENT.toUtf8());
    request.setRawHeader("Referer", "https://www.bilibili.com/");
    request.setRawHeader("Origin", "https://www.bilibili.com");

    QNetworkReply *reply = m_networkManager->get(request);

    QElapsedTimer timer;
    timer.start();
    while (!reply->isFinished() && timer.elapsed() < 8000) {
        QCoreApplication::processEvents(QEventLoop::ExcludeUserInputEvents, 50);
    }

    if (reply->isFinished() && reply->error() == QNetworkReply::NoError) {
        // 使用 rawHeaderPairs() 正确处理多个 Set-Cookie 头
        // 关键：buvid3 和 b_nut 必须来自同一次响应，互相配套
        bool gotBNut = false;
        bool gotBuvid3 = false;
        for (const QNetworkReply::RawHeaderPair &pair : reply->rawHeaderPairs()) {
            if (pair.first.toLower() == "set-cookie") {
                QString cookieStr = QString::fromUtf8(pair.second);
                // b_nut
                QRegularExpression nutRegex("b_nut=([^;]+)");
                QRegularExpressionMatch nutMatch = nutRegex.match(cookieStr);
                if (nutMatch.hasMatch()) {
                    m_currentUser.bNut = nutMatch.captured(1);
                    gotBNut = true;
                    m_bNutFromServer = true;
                    qDebug() << "[LoginManager] fetchBNutFromHomepageSync - got b_nut:" << m_currentUser.bNut;
                }
                // buvid3（与 b_nut 配套，覆盖 finger/spi 的值）
                QRegularExpression buvid3Regex("buvid3=([^;]+)");
                QRegularExpressionMatch buvid3Match = buvid3Regex.match(cookieStr);
                if (buvid3Match.hasMatch()) {
                    m_currentUser.buvid3 = buvid3Match.captured(1);
                    gotBuvid3 = true;
                    m_buvid3FromServer = true;
                    qDebug() << "[LoginManager] fetchBNutFromHomepageSync - got buvid3 (matched with b_nut):" << m_currentUser.buvid3;
                }
            }
        }
        if (!gotBNut) {
            qDebug() << "[LoginManager] fetchBNutFromHomepageSync - b_nut not found in Set-Cookie";
        }
        if (!gotBuvid3) {
            qDebug() << "[LoginManager] fetchBNutFromHomepageSync - buvid3 not found in Set-Cookie";
        }
    } else {
        qDebug() << "[LoginManager] fetchBNutFromHomepageSync failed:" << reply->error() << reply->errorString();
    }

    reply->deleteLater();
}

// 同步获取 bili_ticket（参考 biliuwp-lite BiliTicket() 和 blbl ensureBiliTicket 实现）
// 未登录时用户搜索风控必需 bili_ticket，否则返回 v_voucher
bool LoginManager::fetchBiliTicketSync()
{
    qDebug() << "[LoginManager] fetchBiliTicketSync called, current bili_ticket:" << !m_currentUser.biliTicket.isEmpty();

    if (!m_currentUser.biliTicket.isEmpty()) {
        qDebug() << "[LoginManager] fetchBiliTicketSync - already have bili_ticket, skip";
        return true;
    }

    const QString hmacKey = "XgwSnGZ1p";
    const QString keyId = "ec02";

    qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
    QString ts = QString::number(nowMs / 1000);

    // 计算 HMAC SHA256 签名
    QByteArray message = QString("ts%1").arg(ts).toUtf8();
    QByteArray keyBytes = hmacKey.toUtf8();
    QMessageAuthenticationCode mac(QCryptographicHash::Sha256);
    mac.setKey(keyBytes);
    mac.addData(message);
    QByteArray hexsign = mac.result().toHex();

    QString url = QString("https://api.bilibili.com/bapis/bilibili.api.ticket.v1.Ticket/GenWebTicket"
                         "?key_id=%1&hexsign=%2&context%5Bts%5D=%3")
                      .arg(keyId)
                      .arg(QString::fromUtf8(hexsign))
                      .arg(ts);

    qDebug() << "[LoginManager] fetchBiliTicketSync - url:" << url;

    QNetworkRequest request{QUrl(url)};
    request.setRawHeader("User-Agent", USER_AGENT.toUtf8());
    request.setRawHeader("Referer", "https://www.bilibili.com/");
    request.setRawHeader("Content-Type", "application/octet-stream");

    QNetworkReply *reply = m_networkManager->post(request, QByteArray());

    QElapsedTimer timer;
    timer.start();
    while (!reply->isFinished() && timer.elapsed() < 8000) {
        QCoreApplication::processEvents(QEventLoop::ExcludeUserInputEvents, 50);
    }

    bool success = false;
    if (reply->isFinished() && reply->error() == QNetworkReply::NoError) {
        QByteArray data = reply->readAll();
        qDebug() << "[LoginManager] fetchBiliTicketSync response:" << data.left(300);
        QJsonDocument doc = QJsonDocument::fromJson(data);
        if (doc.isObject()) {
            QJsonObject root = doc.object();
            if (root["code"].toInt() == 0 && root.contains("data")) {
                QJsonObject dataObj = root["data"].toObject();
                if (dataObj.contains("ticket")) {
                    m_currentUser.biliTicket = dataObj["ticket"].toString();
                    success = true;
                    qDebug() << "[LoginManager] fetchBiliTicketSync - got bili_ticket";
                    invalidateCookieCache();
                    saveUserInfo();
                }
            }
        }
    } else {
        qDebug() << "[LoginManager] fetchBiliTicketSync failed:" << reply->error() << reply->errorString();
    }

    reply->deleteLater();
    qDebug() << "[LoginManager] fetchBiliTicketSync result:" << success;
    return success;
}

void LoginManager::resetHttpConnections()
{
    qDebug() << "[LoginManager] resetHttpConnections - closing all idle HTTP connections";
    m_networkManager->clearConnectionCache();
}

void LoginManager::ensureServerBuvid3()
{
    qDebug() << "[LoginManager] ensureServerBuvid3 - isLoggedIn:" << isLoggedIn()
             << "buvid3FromServer:" << m_buvid3FromServer
             << "bNutFromServer:" << m_bNutFromServer
             << "buvid3:" << !m_currentUser.buvid3.isEmpty()
             << "bili_ticket:" << !m_currentUser.biliTicket.isEmpty();
    // 已登录：Cookie 中已包含登录时获取的真实 buvid3，无需额外获取
    if (isLoggedIn()) return;
    // 未登录时需要确保 buvid3 + b_nut + bili_ticket 都从服务器获取
    // 缺少 bili_ticket 会导致用户搜索返回 v_voucher 风控响应
    if (!m_buvid3FromServer) {
        qDebug() << "[LoginManager] ensureServerBuvid3 - fetching real buvid3 for not-logged-in user";
        fetchBuvid3Sync();
    }
    if (!m_bNutFromServer) {
        qDebug() << "[LoginManager] ensureServerBuvid3 - refreshing b_nut from homepage";
        fetchBNutFromHomepageSync();
        if (m_bNutFromServer) {
            invalidateCookieCache();
            saveUserInfo();
        }
    }
    if (m_currentUser.biliTicket.isEmpty()) {
        qDebug() << "[LoginManager] ensureServerBuvid3 - fetching bili_ticket";
        fetchBiliTicketSync();
    }
}

QString LoginManager::getOrCreateBuvid3()
{
    if (!m_currentUser.buvid3.isEmpty()) {
        return m_currentUser.buvid3;
    }
    // 生成符合 B站 buvid3 格式的 UUID（带 infoc 后缀）
    // 正确格式：XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXXinfoc
    static const char hexChars[] = "0123456789abcdef";
    QString uuid;
    for (int i = 0; i < 36; i++) {
        if (i == 8 || i == 13 || i == 18 || i == 23) {
            uuid += '-';
        } else {
            uint32_t val = QRandomGenerator::global()->generate() % 16;
            uuid += QChar(hexChars[val]);
        }
    }
    QString buvid3 = uuid + "infoc";

    // 保存到当前用户信息中（即使未登录也需要）
    m_currentUser.buvid3 = buvid3;
    
    // 同时生成buvid4（格式：32位十六进制小写）
    m_currentUser.buvid4.clear();
    for (int i = 0; i < 32; i++) {
        uint32_t val = QRandomGenerator::global()->generate() % 16;
        m_currentUser.buvid4 += QChar(hexChars[val]);
    }

    // 同时生成 b_nut（格式：与时间戳相关的数字串）
    if (m_currentUser.bNut.isEmpty()) {
        m_currentUser.bNut = QString::number(QDateTime::currentSecsSinceEpoch());
    }

    // 保存到文件，确保下次启动时使用新的buvid3
    saveUserInfo();
    
    return buvid3;
}

void LoginManager::fetchBiliTicket()
{
    // 参考 blbl 项目的 ensureBiliTicket() 实现
    // 简化逻辑：如果没有 bili_ticket，直接用 HMAC 方式获取
    
    bool hasBuvid3 = !m_currentUser.buvid3.isEmpty();
    bool hasBNut = !m_currentUser.bNut.isEmpty();
    bool hasBuvid4 = !m_currentUser.buvid4.isEmpty();
    bool hasBiliTicket = !m_currentUser.biliTicket.isEmpty();
    
    qDebug() << "[LoginManager] fetchBiliTicket start - buvid3:" << hasBuvid3
             << "b_nut:" << hasBNut << "buvid4:" << hasBuvid4
             << "bili_ticket:" << hasBiliTicket;
    
    // 如果已经有 bili_ticket，就不需要再获取
    if (hasBiliTicket) {
        qDebug() << "[LoginManager] fetchBiliTicket - already have bili_ticket, skip";
        return;
    }
    
    // 步骤1: 如果缺少 buvid3 或 b_nut，访问首页获取
    if (!hasBuvid3 || !hasBNut) {
        qDebug() << "[LoginManager] fetchBiliTicket - fetching homepage for buvid3/b_nut";
        QNetworkRequest homeRequest(QUrl("https://www.bilibili.com/"));
        homeRequest.setRawHeader("User-Agent", USER_AGENT.toUtf8());
        homeRequest.setRawHeader("Referer", "https://www.bilibili.com/");
        
        QString cookies = getCookies();
        if (!cookies.isEmpty()) {
            homeRequest.setRawHeader("Cookie", cookies.toUtf8());
        }
        
        QNetworkReply *homeReply = m_networkManager->get(homeRequest);
        connect(homeReply, &QNetworkReply::finished, this, [this, homeReply]() {
            if (homeReply->error() != QNetworkReply::NoError) {
                qDebug() << "[LoginManager] fetchBiliTicket - homepage failed:" << homeReply->errorString();
                homeReply->deleteLater();
                // 即使首页失败，也继续尝试获取 bili_ticket
                fetchBiliTicketHmac();
                return;
            }
            
            // 从响应头提取所有 Set-Cookie
            QList<QByteArray> headers = homeReply->rawHeaderList();
            qDebug() << "[LoginManager] fetchBiliTicket - homepage response headers count:" << headers.size();
            
            for (const QByteArray &header : headers) {
                if (header.toLower() == "set-cookie") {
                    QByteArray cookieValue = homeReply->rawHeader(header);
                    QString cookieStr = QString::fromUtf8(cookieValue);
                    
                    // 提取 buvid3
                    QRegularExpression buvid3Regex("buvid3=([^;]+)");
                    QRegularExpressionMatch b3Match = buvid3Regex.match(cookieStr);
                    if (b3Match.hasMatch() && m_currentUser.buvid3.isEmpty()) {
                        m_currentUser.buvid3 = b3Match.captured(1);
                        qDebug() << "[LoginManager] fetchBiliTicket - got buvid3";
                    }
                    
                    // 提取 b_nut
                    QRegularExpression bNutRegex("b_nut=([^;]+)");
                    QRegularExpressionMatch bnMatch = bNutRegex.match(cookieStr);
                    if (bnMatch.hasMatch()) {
                        m_currentUser.bNut = bnMatch.captured(1);
                        qDebug() << "[LoginManager] fetchBiliTicket - got b_nut";
                    }
                    
                    // 提取 bili_ticket
                    QRegularExpression ticketRegex("bili_ticket=([^;]+)");
                    QRegularExpressionMatch ticketMatch = ticketRegex.match(cookieStr);
                    if (ticketMatch.hasMatch()) {
                        m_currentUser.biliTicket = ticketMatch.captured(1);
                        qDebug() << "[LoginManager] fetchBiliTicket - got bili_ticket from homepage";
                    }
                }
            }
            
            saveUserInfo();
            
            // 获取 buvid4（如果需要）
            if (m_currentUser.buvid4.isEmpty()) {
                fetchBuvid4();
            }
            
            // 如果还是没有 bili_ticket，直接用 HMAC 方式获取
            if (m_currentUser.biliTicket.isEmpty()) {
                qDebug() << "[LoginManager] fetchBiliTicket - still no bili_ticket, trying HMAC";
                fetchBiliTicketHmac();
            } else {
                qDebug() << "[LoginManager] fetchBiliTicket - got bili_ticket from homepage";
            }
            
            homeReply->deleteLater();
        });
    } else {
        // 已有 buvid3 和 b_nut，但没有 bili_ticket
        // 直接用 HMAC 方式获取
        qDebug() << "[LoginManager] fetchBiliTicket - has buvid3/b_nut but no bili_ticket, using HMAC";
        fetchBiliTicketHmac();
    }
}

void LoginManager::fetchBuvid4()
{
    // 调用 /x/frontend/finger/spi 获取 buvid4
    QString url = "https://api.bilibili.com/x/frontend/finger/spi";
    
    QNetworkRequest request(url);
    request.setRawHeader("User-Agent", USER_AGENT.toUtf8());
    request.setRawHeader("Referer", "https://www.bilibili.com/");
    request.setRawHeader("Origin", "https://www.bilibili.com");
    
    QString cookies = getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }
    
    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        if (reply->error() != QNetworkReply::NoError) {
            qDebug() << "[LoginManager] fetchBuvid4 failed:" << reply->errorString();
            reply->deleteLater();
            return;
        }
        
        QByteArray data = reply->readAll();
        QJsonDocument doc = QJsonDocument::fromJson(data);
        if (doc.isObject()) {
            QJsonObject root = doc.object();
            if (root["code"].toInt() == 0) {
                QJsonObject dataObj = root["data"].toObject();
                
                // 获取 buvid3（如果还没有的话）
                if (dataObj.contains("b_3") && m_currentUser.buvid3.isEmpty()) {
                    m_currentUser.buvid3 = dataObj["b_3"].toString();
                    qDebug() << "[LoginManager] fetchBuvid4 - got buvid3 from API";
                }
                
                // 获取 buvid4
                if (dataObj.contains("b_4")) {
                    m_currentUser.buvid4 = dataObj["b_4"].toString();
                    qDebug() << "[LoginManager] fetchBuvid4 - got buvid4 from API";
                }
                
                saveUserInfo();
            }
        }
        
        reply->deleteLater();
    });
}

void LoginManager::fetchBiliTicketFromApi()
{
    // 如果首页没获取到 bili_ticket，尝试其他方式
    // 通过访问 API 来获取 bili_ticket
    QNetworkRequest request(QUrl("https://api.bilibili.com/x/web-interface/ranking/v2?rid=0&type=all"));
    request.setRawHeader("User-Agent", USER_AGENT.toUtf8());
    request.setRawHeader("Referer", "https://www.bilibili.com/");
    
    QString cookies = getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }
    
    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        if (reply->error() == QNetworkReply::NoError) {
            QList<QByteArray> headers = reply->rawHeaderList();
            for (const QByteArray &header : headers) {
                if (header.toLower() == "set-cookie") {
                    QByteArray cookieValue = reply->rawHeader(header);
                    QString cookieStr = QString::fromUtf8(cookieValue);
                    
                    QRegularExpression ticketRegex("bili_ticket=([^;]+)");
                    QRegularExpressionMatch match = ticketRegex.match(cookieStr);
                    if (match.hasMatch()) {
                        m_currentUser.biliTicket = match.captured(1);
                        qDebug() << "[LoginManager] fetchBiliTicketFromApi - got bili_ticket";
                        saveUserInfo();
                        break;
                    }
                }
            }
        }
        reply->deleteLater();
    });
}

void LoginManager::fetchBiliTicketHmac()
{
    // 参考 blbl 的 ensureBiliTicket() 实现
    // 使用 HMAC SHA256 签名获取 bili_ticket
    
    const QString hmacKey = "XgwSnGZ1p";
    const QString keyId = "ec02";
    
    qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
    QString ts = QString::number(nowMs / 1000);
    
    // 计算 HMAC SHA256 签名
    QByteArray message = QString("ts%1").arg(ts).toUtf8();
    QByteArray keyBytes = hmacKey.toUtf8();
    
    // 使用 Qt 的 QMessageAuthenticationCode (Qt 5.11+)
    QByteArray hexsign;
    #if QT_VERSION >= QT_VERSION_CHECK(5, 11, 0)
    QMessageAuthenticationCode mac(QCryptographicHash::Sha256);
    mac.setKey(keyBytes);
    mac.addData(message);
    hexsign = mac.result().toHex();
    #else
    // 手动实现 HMAC-SHA256
    const int blockSize = 64;
    QByteArray keyBlock = keyBytes;
    if (keyBlock.size() > blockSize) {
        keyBlock = QCryptographicHash::hash(keyBlock, QCryptographicHash::Sha256);
    }
    keyBlock.resize(blockSize);
    
    QByteArray innerKey(blockSize, '\x36');
    QByteArray outerKey(blockSize, '\x5c');
    for (int i = 0; i < blockSize; i++) {
        innerKey[i] = innerKey[i] ^ keyBlock[i];
        outerKey[i] = outerKey[i] ^ keyBlock[i];
    }
    
    QByteArray innerHash = QCryptographicHash::hash(innerKey + message, QCryptographicHash::Sha256);
    QByteArray hmacHash = QCryptographicHash::hash(outerKey + innerHash, QCryptographicHash::Sha256);
    hexsign = hmacHash.toHex();
    #endif
    
    // 构建请求 URL（注意：参数名需要 URL 编码）
    QString csrf = m_currentUser.biliJct;
    QString url = QString("https://api.bilibili.com/bapis/bilibili.api.ticket.v1.Ticket/GenWebTicket"
                         "?key_id=%1&hexsign=%2&context%5Bts%5D=%3")
                      .arg(keyId)
                      .arg(QString::fromUtf8(hexsign))
                      .arg(ts);
    
    if (!csrf.isEmpty()) {
        url += QString("&csrf=%1").arg(csrf);
    }
    
    qDebug() << "[LoginManager] fetchBiliTicketHmac - url:" << url;
    qDebug() << "[LoginManager] fetchBiliTicketHmac - hexsign:" << QString::fromUtf8(hexsign);
    
    QNetworkRequest request{QUrl(url)};
    request.setRawHeader("User-Agent", USER_AGENT.toUtf8());
    request.setRawHeader("Referer", "https://www.bilibili.com/");
    request.setRawHeader("Content-Type", "application/octet-stream");
    
    QString cookies = getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }
    
    QNetworkReply *reply = m_networkManager->post(request, QByteArray());
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        if (reply->error() != QNetworkReply::NoError) {
            qDebug() << "[LoginManager] fetchBiliTicketHmac failed:" << reply->errorString();
            reply->deleteLater();
            return;
        }
        
        QByteArray data = reply->readAll();
        qDebug() << "[LoginManager] fetchBiliTicketHmac response:" << data.left(200);
        
        QJsonDocument doc = QJsonDocument::fromJson(data);
        if (doc.isObject()) {
            QJsonObject root = doc.object();
            int code = root["code"].toInt();
            
            if (code == 0) {
                QJsonObject dataObj = root["data"].toObject();
                QString ticket = dataObj["ticket"].toString();
                qint64 createdAt = dataObj["created_at"].toInteger();
                qint64 ttl = dataObj["ttl"].toInteger();
                
                if (!ticket.isEmpty() && createdAt > 0 && ttl > 0) {
                    m_currentUser.biliTicket = ticket;
                    qDebug() << "[LoginManager] fetchBiliTicketHmac - got bili_ticket, ttl:" << ttl;
                    saveUserInfo();
                } else {
                    qDebug() << "[LoginManager] fetchBiliTicketHmac - invalid ticket data";
                }
            } else {
                qDebug() << "[LoginManager] fetchBiliTicketHmac - API error:" << root["message"].toString()
                         << "code:" << code;
            }
        }
        
        reply->deleteLater();
    });
}

void LoginManager::refreshDeviceFingerprint()
{
    // 清空旧的 buvid 和 bili_ticket
    m_currentUser.buvid3.clear();
    m_currentUser.buvid4.clear();
    m_currentUser.bNut.clear();
    m_currentUser.biliTicket.clear();
    
    // 不再本地生成 buvid3，而是从 B站 API 获取
    fetchBiliTicket();
}

void LoginManager::extractCookiesFromUrl(const QString &url)
{
    // 从 URL 中提取 cookies
    // URL 格式类似: https://passport.bilibili.com/api/loginSuccess?...
    // 或者包含 DedeUserID=xxx&SESSDATA=xxx&bili_jct=xxx 等参数
    
    // 使用正则表达式提取 cookie 参数
    QRegularExpression sessRegex("SESSDATA=([^&]+)");
    QRegularExpression jctRegex("bili_jct=([^&]+)");
    QRegularExpression uidRegex("DedeUserID=([^&]+)");
    
    QRegularExpressionMatch sessMatch = sessRegex.match(url);
    QRegularExpressionMatch jctMatch = jctRegex.match(url);
    QRegularExpressionMatch uidMatch = uidRegex.match(url);
    
    if (sessMatch.hasMatch()) {
        m_currentUser.sessData = QUrl::fromPercentEncoding(sessMatch.captured(1).toUtf8());
    }
    
    if (jctMatch.hasMatch()) {
        m_currentUser.biliJct = QUrl::fromPercentEncoding(jctMatch.captured(1).toUtf8());
    }
    
    if (uidMatch.hasMatch()) {
        m_currentUser.dedeUserId = QUrl::fromPercentEncoding(uidMatch.captured(1).toUtf8());
    }
    invalidateCookieCache();
}

void LoginManager::extractCookiesFromHeaders(QNetworkReply *reply)
{
    // B站新版二维码登录可能不在 URL 中返回 SESSDATA，而是通过 Set-Cookie 响应头下发。
    // 需要从响应头中提取，否则 saveUserInfo() 会保存空的 sessData，
    // 导致下次启动后 Web API（playurl、archive/relation 等）因缺少登录 Cookie 而失败。
    if (!reply) return;

    const QList<QByteArray> headers = reply->rawHeaderList();
    for (const QByteArray &header : headers) {
        if (header.toLower() != "set-cookie") continue;

        QString cookieStr = QString::fromUtf8(reply->rawHeader(header));
        QRegularExpression sessRegex("SESSDATA=([^;]+)");
        QRegularExpression jctRegex("bili_jct=([^;]+)");
        QRegularExpression uidRegex("DedeUserID=([^;]+)");

        QRegularExpressionMatch sessMatch = sessRegex.match(cookieStr);
        QRegularExpressionMatch jctMatch = jctRegex.match(cookieStr);
        QRegularExpressionMatch uidMatch = uidRegex.match(cookieStr);

        if (sessMatch.hasMatch()) {
            m_currentUser.sessData = QUrl::fromPercentEncoding(sessMatch.captured(1).toUtf8());
        }
        if (jctMatch.hasMatch()) {
            m_currentUser.biliJct = QUrl::fromPercentEncoding(jctMatch.captured(1).toUtf8());
        }
        if (uidMatch.hasMatch()) {
            m_currentUser.dedeUserId = QUrl::fromPercentEncoding(uidMatch.captured(1).toUtf8());
        }
    }
    invalidateCookieCache();
}

void LoginManager::fetchUserInfo()
{
    // 调用 /x/web-interface/nav API 获取用户信息
    QString url = "https://api.bilibili.com/x/web-interface/nav";
    
    QNetworkRequest request(url);
    request.setRawHeader("User-Agent", USER_AGENT.toUtf8());
    request.setRawHeader("Referer", "https://www.bilibili.com/");
    
    // 直接构建 Cookie 字符串（此时 isLoggedIn() 可能返回 false，因为用户信息还没设置）
    QString cookie;
    if (!m_currentUser.sessData.isEmpty()) {
        cookie += QString("SESSDATA=%1; ").arg(m_currentUser.sessData);
    }
    if (!m_currentUser.biliJct.isEmpty()) {
        cookie += QString("bili_jct=%1; ").arg(m_currentUser.biliJct);
    }
    if (!m_currentUser.dedeUserId.isEmpty()) {
        cookie += QString("DedeUserID=%1; ").arg(m_currentUser.dedeUserId);
    }
    if (!m_currentUser.buvid3.isEmpty()) {
        cookie += QString("buvid3=%1; ").arg(m_currentUser.buvid3);
    }
    if (!m_currentUser.buvid4.isEmpty()) {
        cookie += QString("buvid4=%1; ").arg(m_currentUser.buvid4);
    }
    if (!m_currentUser.biliTicket.isEmpty()) {
        cookie += QString("bili_ticket=%1; ").arg(m_currentUser.biliTicket);
    }
    if (!cookie.isEmpty()) {
        request.setRawHeader("Cookie", cookie.toUtf8());

    } else {

    }
    
    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, &LoginManager::onNavReplyFinished);
}

void LoginManager::onNavReplyFinished()
{
    QNetworkReply *reply = qobject_cast<QNetworkReply*>(sender());
    if (!reply) return;
    
    if (reply->error() != QNetworkReply::NoError) {
        reply->deleteLater();
        return;
    }
    
    QByteArray data = reply->readAll();
    
    QJsonDocument doc = QJsonDocument::fromJson(data);
    if (!doc.isObject()) {
        reply->deleteLater();
        return;
    }
    
    QJsonObject root = doc.object();
    int code = root["code"].toInt();
    
    if (code != 0) {
        reply->deleteLater();
        return;
    }
    
    QJsonObject dataObj = root["data"].toObject();
    
    // 解析用户信息
    m_currentUser.mid = dataObj["mid"].toInt();
    m_currentUser.uname = dataObj["uname"].toString();
    m_currentUser.face = dataObj["face"].toString();
    m_currentUser.level = dataObj["level"].toInt();
    
    // VIP 信息
    QJsonObject vipObj = dataObj["vip"].toObject();
    m_currentUser.vipType = vipObj["type"].toInt();
    m_currentUser.isVIP = vipObj["status"].toInt() == 1;
    
    m_isLoggedIn = true;
    emit userInfoChanged();

    m_loginStatusText = "登录成功";
    emit loginStatusTextChanged();

    saveUserInfo();
    WbiSigner::instance()->forceRefreshKeys();
    fetchBiliTicket();

    // 用户信息获取完成后，发出登录状态变化信号，确保各页面刷新时 isLoggedIn() 返回 true
    if (m_lastLoginStatus != StatusConfirmed) {
        m_lastLoginStatus = StatusConfirmed;
        emit loginStatusChanged(StatusConfirmed, "登录成功");
    }
    
    emit loginSuccess(m_currentUser);
    
    reply->deleteLater();
}

void LoginManager::saveUserInfo()
{
    // 保存用户信息到单独的文件，方便启动时加载
    QFile file("user_info.json");
    if (file.open(QIODevice::WriteOnly)) {
        QJsonObject obj;
        obj["mid"] = m_currentUser.mid;
        obj["uname"] = m_currentUser.uname;
        obj["face"] = m_currentUser.face;
        obj["level"] = m_currentUser.level;
        obj["vipType"] = m_currentUser.vipType;
        obj["isVIP"] = m_currentUser.isVIP;
        obj["access_token"] = m_currentUser.accessKey;  // 【关键修复】之前漏写，重启后 accessKey 丢失
        obj["sessData"] = m_currentUser.sessData;
        obj["biliJct"] = m_currentUser.biliJct;
        obj["dedeUserId"] = m_currentUser.dedeUserId;
        obj["buvid3"] = m_currentUser.buvid3;
        obj["buvid4"] = m_currentUser.buvid4;
        obj["bNut"] = m_currentUser.bNut;
        obj["biliTicket"] = m_currentUser.biliTicket;
        obj["gaiaVtoken"] = m_currentUser.gaiaVtoken;
        obj["buvid3FromServer"] = m_buvid3FromServer;
        obj["bNutFromServer"] = m_bNutFromServer;

        QJsonDocument doc(obj);
        file.write(doc.toJson());
        file.close();
    }
    // cookies 相关字段可能已更新，同步失效缓存
    invalidateCookieCache();
}

void LoginManager::loadUserInfoFromSavedData()
{
    // 从 user_info.json 加载用户信息
    QFile file("user_info.json");
    if (!file.exists()) {

        return;
    }
    
    if (file.open(QIODevice::ReadOnly)) {
        QByteArray data = file.readAll();
        QJsonDocument doc = QJsonDocument::fromJson(data);
        
        if (doc.isObject()) {
            QJsonObject obj = doc.object();
            
            m_currentUser.mid = obj["mid"].toInt();
            m_currentUser.uname = obj["uname"].toString();
            m_currentUser.face = obj["face"].toString();
            m_currentUser.level = obj["level"].toInt();
            m_currentUser.vipType = obj["vipType"].toInt();
            m_currentUser.isVIP = obj["isVIP"].toBool();
            // 【关键修复】之前漏写 accessKey 加载，重启后 PGC 接口只能游客状态
            if (obj.contains("access_token")) {
                m_currentUser.accessKey = obj["access_token"].toString();
            }
            m_currentUser.sessData = obj["sessData"].toString();
            m_currentUser.biliJct = obj["biliJct"].toString();
            m_currentUser.dedeUserId = obj["dedeUserId"].toString();
            m_currentUser.buvid3 = obj["buvid3"].toString();
            m_currentUser.buvid4 = obj["buvid4"].toString();
            m_currentUser.bNut = obj["bNut"].toString();
            m_currentUser.biliTicket = obj["biliTicket"].toString();
            m_currentUser.gaiaVtoken = obj["gaiaVtoken"].toString();
            m_buvid3FromServer = obj["buvid3FromServer"].toBool();
            m_bNutFromServer = obj["bNutFromServer"].toBool();

            // 检查buvid3格式，B 站返回的 buvid3 格式是 XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXXinfoc
            // 但 B 站也可能返回其他格式，所以不再强制校验
            qDebug() << "[LoginManager] loaded user info - buvid3:" << !m_currentUser.buvid3.isEmpty()
                     << "buvid4:" << !m_currentUser.buvid4.isEmpty()
                     << "bNut:" << !m_currentUser.bNut.isEmpty()
                     << "biliTicket:" << !m_currentUser.biliTicket.isEmpty();
            
            m_isLoggedIn = true;
            emit userInfoChanged();

            // 刷新 WBI 签名密钥
            WbiSigner::instance()->forceRefreshKeys();

            // 同步登录状态
            m_lastLoginStatus = StatusConfirmed;

            // 发送登录成功信号，让界面显示头像
            emit loginSuccess(m_currentUser);

            invalidateCookieCache();
        }
        
        file.close();
    }
}
