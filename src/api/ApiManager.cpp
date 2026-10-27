#include "ApiManager.h"
#include "LoginManager.h"
#include "WbiSigner.h"
#include "AppSettings.h"
#include <QCryptographicHash>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QUrlQuery>
#include <QDateTime>
#include <QSslConfiguration>
#include <QSslSocket>
#include <QSslError>
#include <QSettings>
#include <QRandomGenerator>
#include <functional>

ApiManager::ApiManager(QObject *parent)
    : QObject(parent)
    , m_networkManager(new QNetworkAccessManager(this))
    , m_apiBaseUrl("https://api.bilibili.com")
    , m_appKey("1d8b6e7d45233436")
    , m_appSecret("560c52ccd288fed045859ed18bffd973")
{
}

// 生成 B站 web 端 _uuid（格式：XXXXXXXX-XXXX-4XXX-YXXX-XXXXXXXXXXXXinfoc）
QString ApiManager::genBrowserUuid()
{
    static const char chars[] = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    QString uuid;
    for (int i = 0; i < 36; i++) {
        if (i == 8 || i == 13 || i == 18 || i == 23) {
            uuid += '-';
        } else if (i == 14) {
            uuid += '4';
        } else if (i == 19) {
            uuid += chars[8 + (QRandomGenerator::global()->generate() % 4)];
        } else {
            uuid += chars[QRandomGenerator::global()->generate() % 36];
        }
    }
    return uuid + "infoc";
}

// 生成 B站 web 端 b_lsid（16位随机小写字母数字）
QString ApiManager::genBrowserLsid()
{
    static const char chars[] = "0123456789abcdefghijklmnopqrstuvwxyz";
    QString lsid;
    for (int i = 0; i < 16; i++) {
        lsid += chars[QRandomGenerator::global()->generate() % 36];
    }
    return lsid;
}

void ApiManager::getRecommendVideos(const QString &idx, bool pull)
{
    QString url = "https://app.bilibili.com/x/v2/feed/index";
    QString params = getMustParameters();
    params += QString("&flush=0&idx=%1&login_event=2&network=wifi&open_event=&pull=%2&qn=32&style=2")
                  .arg(idx)
                  .arg(pull ? "true" : "false");
    params += getSign(params);
    url += "?" + params;

    getRequest(url);
}

void ApiManager::getWbiRecommendVideos(int page, int pageSize, int freshType, int xNum, int yNum)
{
    // 使用与wiliwili相同的Web WBI推荐API：/x/web-interface/wbi/index/top/feed/rcmd
    QString baseUrl = "https://api.bilibili.com/x/web-interface/wbi/index/top/feed/rcmd";

    // 构建基础参数（对齐 wiliwili）
    QUrlQuery query;
    query.addQueryItem("fresh_idx", QString::number(page));       // 页码，从1开始
    query.addQueryItem("ps", QString::number(pageSize));          // 每页数量
    query.addQueryItem("feed_version", "V1");                     // 首页推荐固定 V1
    query.addQueryItem("fresh_type", QString::number(freshType)); // 初始加载0，手动刷新3，自动加载4
    query.addQueryItem("plat", "1");
    query.addQueryItem("x_num", QString::number(xNum));           // 固定3
    query.addQueryItem("y_num", QString::number(yNum));           // 根据屏幕列数，默认4

    QString params = query.query(QUrl::FullyEncoded);

    // 使用WBI签名
    WbiSigner *wbiSigner = WbiSigner::instance();
    QString signedParams = wbiSigner->signParams(params);

    QString url = baseUrl + "?" + signedParams;

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), QByteArray("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"));
    request.setRawHeader(QByteArray("Referer"), QByteArray("https://www.bilibili.com/"));
    request.setRawHeader(QByteArray("Origin"), QByteArray("https://www.bilibili.com"));
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));

    // 未登录时也需要 buvid3 等设备指纹，否则推荐接口可能返回重复数据或很快触底
    LoginManager *loginMgr = LoginManager::instance();
    QString cookies = loginMgr->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    QString buvid3 = loginMgr->getOrCreateBuvid3();
    if (!buvid3.isEmpty()) {
        request.setRawHeader(QByteArray("buvid"), buvid3.toUtf8());
    }

    request.setAttribute(QNetworkRequest::CacheLoadControlAttribute, QNetworkRequest::AlwaysNetwork);

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        if (reply->error() != QNetworkReply::NoError) {
            emit errorOccurred(reply->errorString());
            reply->deleteLater();
            return;
        }
        QByteArray data = reply->readAll();
        emit wbiRecommendVideosReceived(data);
        reply->deleteLater();
    });
}

void ApiManager::getHotsAll(int pn, int ps)
{
    QString baseUrl = "https://api.bilibili.com/x/web-interface/popular";
    QUrlQuery query;
    query.addQueryItem("pn", QString::number(pn));
    query.addQueryItem("ps", QString::number(ps));
    query.addQueryItem("web_location", "bilibili-electron");

    QString params = query.query(QUrl::FullyEncoded);
    QString signedParams = WbiSigner::instance()->signParams(params);
    QString url = baseUrl + "?" + signedParams;

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), QByteArray("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"));
    request.setRawHeader(QByteArray("Referer"), QByteArray("https://www.bilibili.com/"));
    request.setRawHeader(QByteArray("Origin"), QByteArray("https://www.bilibili.com"));
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));

    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        if (reply->error() != QNetworkReply::NoError) {
            emit errorOccurred(reply->errorString());
            reply->deleteLater();
            return;
        }
        QByteArray data = reply->readAll();
        emit hotsAllReceived(data);
        reply->deleteLater();
    });
}

void ApiManager::getHotsRank(int rid, const QString &type)
{
    QString baseUrl = "https://api.bilibili.com/x/web-interface/ranking/v2";
    QUrlQuery query;
    query.addQueryItem("rid", QString::number(rid));
    query.addQueryItem("type", type);
    query.addQueryItem("web_location", "bilibili-electron");

    QString params = query.query(QUrl::FullyEncoded);
    QString signedParams = WbiSigner::instance()->signParams(params);
    QString url = baseUrl + "?" + signedParams;

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), QByteArray("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"));
    request.setRawHeader(QByteArray("Referer"), QByteArray("https://www.bilibili.com/"));
    request.setRawHeader(QByteArray("Origin"), QByteArray("https://www.bilibili.com"));
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));

    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        if (reply->error() != QNetworkReply::NoError) {
            emit errorOccurred(reply->errorString());
            reply->deleteLater();
            return;
        }
        QByteArray data = reply->readAll();
        emit hotsRankReceived(data);
        reply->deleteLater();
    });
}

void ApiManager::getHotsWeeklyList()
{
    QString url = "https://api.bilibili.com/x/web-interface/popular/series/list?web_location=bilibili-electron";

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), QByteArray("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"));
    request.setRawHeader(QByteArray("Referer"), QByteArray("https://www.bilibili.com/"));
    request.setRawHeader(QByteArray("Origin"), QByteArray("https://www.bilibili.com"));
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));

    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        if (reply->error() != QNetworkReply::NoError) {
            emit errorOccurred(reply->errorString());
            reply->deleteLater();
            return;
        }
        QByteArray data = reply->readAll();
        emit hotsWeeklyListReceived(data);
        reply->deleteLater();
    });
}

void ApiManager::getHotsWeekly(int number)
{
    QString baseUrl = "https://api.bilibili.com/x/web-interface/popular/series/one";
    QUrlQuery query;
    query.addQueryItem("number", QString::number(number));
    query.addQueryItem("web_location", "bilibili-electron");

    QString params = query.query(QUrl::FullyEncoded);
    QString signedParams = WbiSigner::instance()->signParams(params);
    QString url = baseUrl + "?" + signedParams;

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), QByteArray("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"));
    request.setRawHeader(QByteArray("Referer"), QByteArray("https://www.bilibili.com/"));
    request.setRawHeader(QByteArray("Origin"), QByteArray("https://www.bilibili.com"));
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));

    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        if (reply->error() != QNetworkReply::NoError) {
            emit errorOccurred(reply->errorString());
            reply->deleteLater();
            return;
        }
        QByteArray data = reply->readAll();
        emit hotsWeeklyReceived(data);
        reply->deleteLater();
    });
}

void ApiManager::getHotsHistory()
{
    QString baseUrl = "https://api.bilibili.com/x/web-interface/popular/precious";
    QUrlQuery query;
    query.addQueryItem("web_location", "bilibili-electron");

    QString params = query.query(QUrl::FullyEncoded);
    QString signedParams = WbiSigner::instance()->signParams(params);
    QString url = baseUrl + "?" + signedParams;

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), QByteArray("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"));
    request.setRawHeader(QByteArray("Referer"), QByteArray("https://www.bilibili.com/"));
    request.setRawHeader(QByteArray("Origin"), QByteArray("https://www.bilibili.com"));
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));

    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        if (reply->error() != QNetworkReply::NoError) {
            emit errorOccurred(reply->errorString());
            reply->deleteLater();
            return;
        }
        QByteArray data = reply->readAll();
        emit hotsHistoryReceived(data);
        reply->deleteLater();
    });
}

// ===== 用户空间 =====

void ApiManager::getUserSpaceInfo(const QString &mid)
{
    LoginManager *loginMgr = LoginManager::instance();

    // 未登录时 web API /x/space/wbi/acc/info 返回 -352 风控，改用 APP API
    if (!loginMgr->isLoggedIn()) {
        QString params = getMustParameters() + QString("&fnval=16&fnver=0&vmid=%1").arg(mid);
        QString sign = getSign(params);
        QString url = "https://app.bilibili.com/x/v2/space?" + params + sign;

        QNetworkRequest request{QUrl(url)};
        request.setRawHeader("User-Agent", "Mozilla/5.0 BiliDroid/5.44.2 (bbcallen@gmail.com)");

        QNetworkReply *reply = m_networkManager->get(request);
        connect(reply, &QNetworkReply::finished, this, [this, reply]() {
            if (reply->error() != QNetworkReply::NoError) {
                emit errorOccurred(reply->errorString());
                reply->deleteLater();
                return;
            }
            QByteArray data = reply->readAll();
            qDebug() << "[ApiManager] getUserSpaceInfo (APP) response:" << data.left(500);

            // 转换 APP API 响应为 web API 格式
            QJsonDocument doc = QJsonDocument::fromJson(data);
            QJsonObject root = doc.object();
            if (root["code"].toInt() == 0 && root.contains("data")) {
                QJsonObject appData = root["data"].toObject();
                QJsonObject card = appData["card"].toObject();

                QJsonObject webData;
                webData["mid"] = card["mid"];
                webData["name"] = card["name"];
                webData["face"] = card["face"];
                webData["sign"] = card["description"];

                // level
                QJsonObject levelObj = card["level_info"].toObject();
                QJsonObject webLevel;
                webLevel["current_level"] = levelObj["current_level"];
                webData["level"] = webLevel;

                // official_verify: APP API 用 official_verify.type（-1/127=无, 0=个人, 1=机构）
                // Web API 用 official.type（-1=无, 0=个人, 1=机构）
                QJsonObject webOfficial;
                QJsonObject offVerify = card["official_verify"].toObject();
                int offType = offVerify["type"].toInt(-1);
                if (offType == 127) offType = -1;  // 127 也表示无认证
                webOfficial["type"] = offType;
                webOfficial["desc"] = offVerify["desc"];
                webOfficial["title"] = offVerify["title"];
                webOfficial["role"] = offVerify["role"];
                webData["official"] = webOfficial;

                // vip: APP API 用 vipType/vipStatus，Web API 用 type/status
                QJsonObject appVip = card["vip"].toObject();
                QJsonObject webVip;
                webVip["type"] = appVip["vipType"];
                webVip["status"] = appVip["vipStatus"];
                webData["vip"] = webVip;

                // fans / attention
                webData["fans"] = card["fans"];
                webData["attention"] = card["attention"];

                QJsonObject webRoot;
                webRoot["code"] = 0;
                webRoot["data"] = webData;

                QJsonDocument webDoc(webRoot);
                emit userSpaceInfoReceived(webDoc.toJson());
            } else {
                emit userSpaceInfoReceived(data);
            }
            reply->deleteLater();
        });
        return;
    }

    // 已登录时使用 web API
    QString baseUrl = m_apiBaseUrl + "/x/space/wbi/acc/info";
    QUrlQuery query;
    query.addQueryItem("mid", mid);

    QString params = query.query(QUrl::FullyEncoded);
    QString signedParams = WbiSigner::instance()->signParams(params);
    QString url = baseUrl + "?" + signedParams;

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), QByteArray("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"));
    request.setRawHeader(QByteArray("Referer"), QString("https://space.bilibili.com/%1").arg(mid).toUtf8());
    request.setRawHeader(QByteArray("Origin"), QByteArray("https://space.bilibili.com"));
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));

    QString cookies = loginMgr->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        if (reply->error() != QNetworkReply::NoError) {
            emit errorOccurred(reply->errorString());
            reply->deleteLater();
            return;
        }
        QByteArray data = reply->readAll();
        qDebug() << "[ApiManager] getUserSpaceInfo response:" << data.left(500);
        emit userSpaceInfoReceived(data);
        reply->deleteLater();
    });
}

void ApiManager::getUserSpaceVideos(const QString &mid, int pn, int ps, const QString &order, bool forceApp)
{
    LoginManager *loginMgr = LoginManager::instance();

    // 未登录时 web API /x/space/wbi/arc/search 返回 -352 风控，改用 APP API；
    // forceApp：登录态但 web 返回错误/空列表时的兜底（部分官方账号会命中）
    if (!loginMgr->isLoggedIn() || forceApp) {
        // APP API 使用 cursor 分页，第一页不传 aid
        // fnval + fnver 为必需参数，缺失会导致 -3 签名错误
        QString orderStr = (order == "click") ? "click" : "pubdate";
        QString params = getMustParameters() + QString("&fnval=16&fnver=0&vmid=%1&ps=%2&order=%3")
                             .arg(mid)
                             .arg(QString::number(ps))
                             .arg(orderStr);
        QString sign = getSign(params);
        QString url = "https://app.bilibili.com/x/v2/space/archive/cursor?" + params + sign;

        QNetworkRequest request{QUrl(url)};
        request.setRawHeader("User-Agent", "Mozilla/5.0 BiliDroid/5.44.2 (bbcallen@gmail.com)");

        QNetworkReply *reply = m_networkManager->get(request);
        connect(reply, &QNetworkReply::finished, this, [this, reply, pn]() {
            if (reply->error() != QNetworkReply::NoError) {
                emit errorOccurred(reply->errorString());
                reply->deleteLater();
                return;
            }
            QByteArray data = reply->readAll();
            {
                const QJsonObject appRoot = QJsonDocument::fromJson(data).object();
                if (appRoot.value("code").toInt(-999) != 0)
                    qWarning() << "[SpaceVideos] APP failed. code:" << appRoot.value("code").toInt(-999)
                               << "msg:" << appRoot.value("message").toString();
            }

            // 转换 APP API 响应为 web API 格式
            QJsonDocument doc = QJsonDocument::fromJson(data);
            QJsonObject root = doc.object();
            if (root["code"].toInt() == 0 && root.contains("data")) {
                QJsonObject appData = root["data"].toObject();
                QJsonArray items = appData["item"].toArray();
                int total = appData["count"].toInt();
                bool hasNext = appData["has_next"].toBool();

                QJsonArray vlist;
                for (int i = 0; i < items.size(); i++) {
                    QJsonObject item = items[i].toObject();
                    QJsonObject v;
                    v["bvid"] = item["bvid"];
                    v["aid"] = item["param"];
                    v["title"] = item["title"];
                    v["pic"] = item["cover"];
                    v["play"] = item["play"];
                    v["video_review"] = item["danmaku"];
                    v["length"] = QString::number(item["duration"].toInt());
                    v["author"] = item["author"];
                    v["created"] = item["ctime"];
                    vlist.append(v);
                }

                QJsonObject webList;
                webList["vlist"] = vlist;

                QJsonObject webPage;
                webPage["count"] = total;
                webPage["pn"] = pn;

                QJsonObject webData;
                webData["list"] = webList;
                webData["page"] = webPage;

                QJsonObject webRoot;
                webRoot["code"] = 0;
                webRoot["data"] = webData;
                // 标记是否有下一页（APP API 用 has_next 而非 page 分页）
                webRoot["has_next"] = hasNext;

                QJsonDocument webDoc(webRoot);
                emit userSpaceVideosReceived(webDoc.toJson());
            } else {
                emit userSpaceVideosReceived(data);
            }
            reply->deleteLater();
        });
        return;
    }

    // 已登录时使用 web API
    QString baseUrl = m_apiBaseUrl + "/x/space/wbi/arc/search";
    QUrlQuery query;
    query.addQueryItem("mid", mid);
    query.addQueryItem("ps", QString::number(ps));
    query.addQueryItem("tid", "0");
    query.addQueryItem("pn", QString::number(pn));
    query.addQueryItem("keyword", "");
    query.addQueryItem("order", order);

    QString params = query.query(QUrl::FullyEncoded);
    QString signedParams = WbiSigner::instance()->signParams(params);
    QString url = baseUrl + "?" + signedParams;

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), QByteArray("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"));
    request.setRawHeader(QByteArray("Referer"), QString("https://space.bilibili.com/%1/video").arg(mid).toUtf8());
    request.setRawHeader(QByteArray("Origin"), QByteArray("https://space.bilibili.com"));
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));

    QString cookies = loginMgr->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, mid, pn, ps, order]() {
        if (reply->error() != QNetworkReply::NoError) {
            emit errorOccurred(reply->errorString());
            reply->deleteLater();
            return;
        }
        QByteArray data = reply->readAll();

        // Release 构建里 qDebug 被编译掉（QT_NO_DEBUG_OUTPUT），排障信息用 qWarning
        const QJsonObject root = QJsonDocument::fromJson(data).object();
        const int code = root.value("code").toInt(-999);
        const QJsonArray vlist = root.value("data").toObject()
                                     .value("list").toObject().value("vlist").toArray();
        // web 接口失败（风控/权限）或返回空列表时，回退 APP 接口再试一次
        if (code != 0 || vlist.isEmpty()) {
            qWarning() << "[SpaceVideos] web failed, fallback to APP. code:" << code
                       << "msg:" << root.value("message").toString() << "mid:" << mid;
            getUserSpaceVideos(mid, pn, ps, order, true);
            reply->deleteLater();
            return;
        }

        emit userSpaceVideosReceived(data);
        reply->deleteLater();
    });
}

void ApiManager::getUserSpaceDynamics(const QString &mid, const QString &offset, int ps)
{
    Q_UNUSED(ps)
    LoginManager *loginMgr = LoginManager::instance();

    // 无论登录与否，确保真实的设备指纹存在（bili_ticket / buvid3 / b_nut 缺失会导致 412 风控）
    loginMgr->ensureServerBuvid3();

    QString baseUrl = "https://api.bilibili.com/x/polymer/web-dynamic/v1/feed/space";
    QUrlQuery query;
    query.addQueryItem("host_mid", mid);
    query.addQueryItem("offset", offset);
    query.addQueryItem("timezone_offset", "-480");

    QString params = query.query(QUrl::FullyEncoded);
    QString signedParams = WbiSigner::instance()->signParams(params);
    QString url = baseUrl + "?" + signedParams;

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), QByteArray("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"));
    request.setRawHeader(QByteArray("Referer"), QString("https://space.bilibili.com/%1/dynamic").arg(mid).toUtf8());
    request.setRawHeader(QByteArray("Origin"), QByteArray("https://space.bilibili.com"));
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));

    // 合并登录 cookie + 设备指纹 cookie（登录时 getCookies 可能不含 bili_ticket/buvid3，需手动补充）
    QString cookies = loginMgr->getCookies();
    QString buvid3 = loginMgr->getOrCreateBuvid3();
    QString buvid4 = loginMgr->getBuvid4();
    QString bNut = loginMgr->getBNut();
    QString biliTicket = loginMgr->getBiliTicket();

    auto appendCookie = [&](const QString &key, const QString &val) {
        if (val.isEmpty()) return;
        // 如果登录 cookie 中已有该 key 则跳过
        if (!cookies.isEmpty() && cookies.contains(key + "=")) return;
        if (!cookies.isEmpty() && !cookies.endsWith("; ")) cookies += "; ";
        cookies += QString("%1=%2; ").arg(key, val);
    };
    appendCookie("buvid3", buvid3);
    appendCookie("buvid4", buvid4);
    appendCookie("b_nut", bNut);
    appendCookie("bili_ticket", biliTicket);
    appendCookie("CURRENT_FNVAL", "4048");
    appendCookie("buvid_fp", buvid3);

    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }
    if (!buvid3.isEmpty()) {
        request.setRawHeader(QByteArray("buvid"), buvid3.toUtf8());
    }

    qDebug() << "[ApiManager] getUserSpaceDynamics request URL:" << url
             << "loggedIn:" << loginMgr->isLoggedIn()
             << "bili_ticket:" << !biliTicket.isEmpty()
             << "buvid3:" << !buvid3.isEmpty()
             << "b_nut:" << !bNut.isEmpty();

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, loginMgr]() {
        bool netError = (reply->error() != QNetworkReply::NoError);
        // 412 风控（HTTP 层面表现为 UnknownContentError / ContentAccessDenied，或返回 HTML 页面）
        QByteArray data = reply->readAll();
        bool is412Html = false;
        if (!data.isEmpty()) {
            QByteArray first = data.trimmed().left(20).toLower();
            if (first.startsWith("<!doctype") || first.startsWith("<html")) {
                is412Html = true;
            }
        }

        if (netError || is412Html) {
            qDebug() << "[ApiManager] getUserSpaceDynamics blocked or error:"
                     << (netError ? reply->errorString() : "风控拦截(HTML response)")
                     << "fallback to code=-101";
            // 风控或网络错误：统一封装为 -101，QML 侧展示"请登录后查看动态"
            // （未登录缺 bili_ticket 时 412 无法绕过；登录态缺设备指纹也会 412）
            QJsonObject root;
            if (!loginMgr->isLoggedIn()) {
                root["code"] = -101;
                root["message"] = QStringLiteral("请登录后查看动态");
            } else {
                root["code"] = -101;
                root["message"] = QStringLiteral("动态加载失败（风控拦截），请尝试重新登录或稍后再试");
            }
            QJsonDocument doc(root);
            emit userSpaceDynamicsReceived(doc.toJson());
            reply->deleteLater();
            return;
        }
        qDebug() << "[ApiManager] getUserSpaceDynamics response size:" << data.size() << "preview:" << data.left(300);
        emit userSpaceDynamicsReceived(data);
        reply->deleteLater();
    });
    connect(reply, &QNetworkReply::sslErrors, this, [reply](const QList<QSslError> &errors) {
        qDebug() << "[ApiManager] getUserSpaceDynamics SSL errors:" << errors;
    });
}

void ApiManager::searchVideos(const QString &keyword, int page, const QString &order, const QString &duration, int region)
{
    QString baseUrl = m_apiBaseUrl + "/x/web-interface/wbi/search/type";

    QUrlQuery query;
    query.addQueryItem("context", "");
    query.addQueryItem("search_type", "video");
    query.addQueryItem("page", QString::number(page));
    query.addQueryItem("order", order);
    query.addQueryItem("keyword", keyword);
    query.addQueryItem("duration", duration);
    query.addQueryItem("category_id", "");
    query.addQueryItem("tids_2", "");
    query.addQueryItem("__refresh__", "true");
    query.addQueryItem("tids", QString::number(region));
    query.addQueryItem("highlight", "1");
    query.addQueryItem("single_column", "0");

    QString params = query.query(QUrl::FullyEncoded);
    QString signedParams = WbiSigner::instance()->signParams(params);
    QString url = baseUrl + "?" + signedParams;

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), QByteArray("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"));
    request.setRawHeader(QByteArray("Referer"), QByteArray("https://search.bilibili.com/"));
    request.setRawHeader(QByteArray("Origin"), QByteArray("https://search.bilibili.com"));
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));

    LoginManager *loginMgr = LoginManager::instance();
    QString cookies = loginMgr->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    QString buvid3 = loginMgr->getOrCreateBuvid3();
    if (!buvid3.isEmpty()) {
        request.setRawHeader(QByteArray("buvid"), buvid3.toUtf8());
    }

    request.setAttribute(QNetworkRequest::CacheLoadControlAttribute, QNetworkRequest::AlwaysNetwork);

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        if (reply->error() != QNetworkReply::NoError) {
            emit errorOccurred(reply->errorString());
            reply->deleteLater();
            return;
        }
        QByteArray data = reply->readAll();
        emit searchResultsReceived(data);
        reply->deleteLater();
    });
}

void ApiManager::searchBangumi(const QString &keyword, int page, bool isMovie)
{
    // 对齐 biliuwp-lite SearchAPI.WebSearchAnime / WebSearchMovie
    // 番剧 search_type = media_bangumi；影视 search_type = media_ft
    QString baseUrl = m_apiBaseUrl + "/x/web-interface/wbi/search/type";

    QUrlQuery query;
    query.addQueryItem("context", "");
    query.addQueryItem("search_type", isMovie ? "media_ft" : "media_bangumi");
    query.addQueryItem("page", QString::number(page));
    query.addQueryItem("order", "");
    query.addQueryItem("keyword", keyword);
    query.addQueryItem("category_id", "");
    query.addQueryItem("__refresh__", "true");
    query.addQueryItem("highlight", "1");
    query.addQueryItem("single_column", "0");

    QString params = query.query(QUrl::FullyEncoded);
    QString signedParams = WbiSigner::instance()->signParams(params);
    QString url = baseUrl + "?" + signedParams;

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), QByteArray("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"));
    request.setRawHeader(QByteArray("Referer"), QByteArray("https://search.bilibili.com/"));
    request.setRawHeader(QByteArray("Origin"), QByteArray("https://search.bilibili.com"));
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));

    LoginManager *loginMgr = LoginManager::instance();
    QString cookies = loginMgr->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    QString buvid3 = loginMgr->getOrCreateBuvid3();
    if (!buvid3.isEmpty()) {
        request.setRawHeader(QByteArray("buvid"), buvid3.toUtf8());
    }

    request.setAttribute(QNetworkRequest::CacheLoadControlAttribute, QNetworkRequest::AlwaysNetwork);

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, isMovie]() {
        if (reply->error() != QNetworkReply::NoError) {
            emit errorOccurred(reply->errorString());
            reply->deleteLater();
            return;
        }
        QByteArray data = reply->readAll();
        emit searchBangumiReceived(data, isMovie);
        reply->deleteLater();
    });
}

void ApiManager::searchLive(const QString &keyword, int page)
{
    // 直播搜索 search_type = live_room（B站网页端搜索直播的接口）
    // 接口与番剧/影视相同，基础URL也是 /x/web-interface/wbi/search/type，WBI签名
    QString baseUrl = m_apiBaseUrl + "/x/web-interface/wbi/search/type";

    QUrlQuery query;
    query.addQueryItem("context", "");
    query.addQueryItem("search_type", "live_room");
    query.addQueryItem("page", QString::number(page));
    query.addQueryItem("order", "");
    query.addQueryItem("keyword", keyword);
    query.addQueryItem("category_id", "");
    query.addQueryItem("__refresh__", "true");
    query.addQueryItem("highlight", "1");
    query.addQueryItem("single_column", "0");

    QString params = query.query(QUrl::FullyEncoded);
    QString signedParams = WbiSigner::instance()->signParams(params);
    QString url = baseUrl + "?" + signedParams;

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), QByteArray("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"));
    request.setRawHeader(QByteArray("Referer"), QByteArray("https://search.bilibili.com/"));
    request.setRawHeader(QByteArray("Origin"), QByteArray("https://search.bilibili.com"));
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));

    LoginManager *loginMgr = LoginManager::instance();
    QString cookies = loginMgr->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    QString buvid3 = loginMgr->getOrCreateBuvid3();
    if (!buvid3.isEmpty()) {
        request.setRawHeader(QByteArray("buvid"), buvid3.toUtf8());
    }

    request.setAttribute(QNetworkRequest::CacheLoadControlAttribute, QNetworkRequest::AlwaysNetwork);

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        if (reply->error() != QNetworkReply::NoError) {
            emit errorOccurred(reply->errorString());
            reply->deleteLater();
            return;
        }
        QByteArray data = reply->readAll();
        emit searchLiveReceived(data);
        reply->deleteLater();
    });
}

void ApiManager::searchUser(const QString &keyword, int page, int orderType, int userType)
{
    LoginManager *loginMgr = LoginManager::instance();

    // 未登录时使用 APP API，避免 web 风控（v_voucher）
    if (!loginMgr->isLoggedIn()) {
        // order: APP API 对应的排序参数
        // 0 默认: 不传 order  / 1 粉丝高到低: fans / 2 粉丝低到高: fans_asc / 3 等级高到低: level / 4 等级低到高: level_asc
        QString orderStr;
        switch (orderType) {
        case 1: orderStr = "fans"; break;
        case 2: orderStr = "fans_asc"; break;
        case 3: orderStr = "level"; break;
        case 4: orderStr = "level_asc"; break;
        default: break;
        }

        QString params = getMustParameters() + QString("&from_source=app_search&highlight=0&keyword=%1&order=%2&pn=%3&ps=20&type=2")
                             .arg(QString(QUrl::toPercentEncoding(keyword)))
                             .arg(orderStr)
                             .arg(page);
        QString sign = getSign(params);
        QString url = "https://app.bilibili.com/x/v2/search/type?" + params + sign;

        QNetworkRequest request{QUrl(url)};
        request.setRawHeader("User-Agent", "Mozilla/5.0 BiliDroid/6.8.2 (bbcallen@gmail.com)");
        request.setAttribute(QNetworkRequest::CacheLoadControlAttribute, QNetworkRequest::AlwaysNetwork);

        QNetworkReply *reply = m_networkManager->get(request);
        connect(reply, &QNetworkReply::finished, this, [this, reply, page]() {
            if (reply->error() != QNetworkReply::NoError) {
                emit errorOccurred(reply->errorString());
                reply->deleteLater();
                return;
            }
            QByteArray data = reply->readAll();
            qDebug() << "[ApiManager] searchUser (APP) response size:" << data.size()
                     << "preview:" << QString::fromUtf8(data.left(500));

            // 转换 APP API 响应为 web API 格式，确保 QML 无需修改
            QJsonDocument doc = QJsonDocument::fromJson(data);
            QJsonObject root = doc.object();
            if (root["code"].toInt() == 0 && root.contains("data")) {
                QJsonObject appData = root["data"].toObject();
                QJsonArray appItems = appData["items"].toArray();
                int numPages = appData["pages"].toInt();

                QJsonArray result;
                for (int i = 0; i < appItems.size(); i++) {
                    QJsonObject item = appItems[i].toObject();
                    // 只取用户项：goto=author 或 author_new
                    QString gotoVal = item["goto"].toString();
                    if (gotoVal != "author" && gotoVal != "author_new" && !item.contains("mid")) {
                        continue;
                    }
                    QJsonObject r;
                    QString mid = QString::number(item["mid"].toVariant().toLongLong());
                    if (mid.isEmpty() || mid == "0") {
                        mid = item["param"].toString();
                    }
                    r["mid"] = mid;
                    r["uname"] = item["title"];
                    r["usign"] = item["sign"];
                    r["face"] = item["cover"];
                    r["fans"] = item["fans"].toInt();
                    r["level"] = item["level"].toInt();
                    r["videos"] = item["archives"].toInt();  // APP API 用 archives 表示投稿数，Web API 用 videos

                    // official_verify: APP {type, desc} -> Web {type, desc, role}
                    QJsonObject ov = item["official_verify"].toObject();
                    int ovType = ov["type"].toInt();
                    QJsonObject webOv;
                    webOv["role"] = ovType;   // -1 未认证 / 0 个人认证 / 1 机构认证
                    webOv["title"] = ov["desc"];
                    webOv["desc"] = ov["desc"];
                    webOv["type"] = ovType;   // 与 role 保持一致
                    r["official_verify"] = webOv;

                    // vip
                    QJsonObject vip = item["vip"].toObject();
                    int vipType = vip["type"].toInt();
                    int vipStatus = vip["status"].toInt();
                    QJsonObject webVip;
                    webVip["vipType"] = vipType;
                    webVip["vipStatus"] = vipStatus;
                    r["vip"] = webVip;

                    result.append(r);
                }

                QJsonObject webData;
                webData["result"] = result;
                webData["numPages"] = numPages;
                webData["page"] = page;

                QJsonObject webRoot;
                webRoot["code"] = 0;
                webRoot["message"] = "0";
                webRoot["data"] = webData;

                QJsonDocument webDoc(webRoot);
                emit searchUserReceived(webDoc.toJson());
            } else {
                emit searchUserReceived(data);
            }
            reply->deleteLater();
        });
        return;
    }

    // ===== 已登录：Web API =====
    // 用户搜索 search_type = bili_user（B站网页端搜索用户的接口）
    // 与 biliuwp-lite SearchAPI.WebSearchUser 一致，需 WBI 签名
    QString baseUrl = m_apiBaseUrl + "/x/web-interface/wbi/search/type";

    // order & order_sort 参数：
    // 0 默认: &order=&order_sort=
    // 1 粉丝由高到低: &order=fans&order_sort=0
    // 2 粉丝由低到高: &order=fans&order_sort=1
    // 3 LV等级由高到低: &order=level&order_sort=0
    // 4 LV等级由低到高: &order=level&order_sort=1
    QString order;
    QString orderSort;
    switch (orderType) {
    case 1: order = "fans";  orderSort = "0"; break;
    case 2: order = "fans";  orderSort = "1"; break;
    case 3: order = "level"; orderSort = "0"; break;
    case 4: order = "level"; orderSort = "1"; break;
    default: break;
    }
    // user_type 参数：0全部用户 / 1UP主 / 2普通用户 / 3认证用户
    QString userTypeStr = QString::number(userType);

    QUrlQuery query;
    query.addQueryItem("context", "");
    query.addQueryItem("search_type", "bili_user");
    query.addQueryItem("page", QString::number(page));
    query.addQueryItem("order", order);
    query.addQueryItem("order_sort", orderSort);
    query.addQueryItem("user_type", userTypeStr);
    query.addQueryItem("keyword", keyword);
    query.addQueryItem("__refresh__", "true");
    query.addQueryItem("changing", "mid");
    query.addQueryItem("highlight", "1");
    query.addQueryItem("single_column", "0");
    query.addQueryItem("category_id", "");

    QString params = query.query(QUrl::FullyEncoded);
    QString signedParams = WbiSigner::instance()->signParams(params);
    QString url = baseUrl + "?" + signedParams;

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), QByteArray("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"));
    request.setRawHeader(QByteArray("Referer"), QByteArray("https://search.bilibili.com/"));
    request.setRawHeader(QByteArray("Origin"), QByteArray("https://search.bilibili.com"));
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));

    // 用户搜索（search_type=bili_user）对风控更敏感，未登录时需要服务器签发的真实 buvid3，
    // 本地伪造的 buvid3 会导致B站返回 v_voucher 验证响应（code:0 但无搜索结果）。
    loginMgr->ensureServerBuvid3();
    QString cookies = loginMgr->getCookies();
    QString buvid3 = loginMgr->getOrCreateBuvid3();

    // 未登录时 getCookies() 返回空，需要手动补充所有设备 cookie 到请求中。
    // B站用户搜索风控需要：buvid3 + b_nut + bili_ticket（关键） + buvid4 + 其他浏览器指纹
    // 缺少 bili_ticket 会导致返回 v_voucher 风控响应
    if (cookies.isEmpty() && !buvid3.isEmpty()) {
        cookies = QString("buvid3=%1; ").arg(buvid3);
        // buvid4
        QString buvid4 = loginMgr->getBuvid4();
        if (!buvid4.isEmpty()) {
            cookies += QString("buvid4=%1; ").arg(buvid4);
        }
        // b_nut
        QString bNut = loginMgr->getBNut();
        if (!bNut.isEmpty()) {
            cookies += QString("b_nut=%1; ").arg(bNut);
        }
        // bili_ticket（未登录用户搜索风控必需）
        QString biliTicket = loginMgr->getBiliTicket();
        if (!biliTicket.isEmpty()) {
            cookies += QString("bili_ticket=%1; ").arg(biliTicket);
        }
        // CURRENT_FNVAL
        cookies += "CURRENT_FNVAL=4048; ";
        // buvid_fp（与 buvid3 一致）
        cookies += QString("buvid_fp=%1; ").arg(buvid3);
        qDebug() << "[ApiManager] searchUser - not logged in, built device cookies - buvid3:" << !buvid3.isEmpty()
                 << "buvid4:" << !buvid4.isEmpty() << "b_nut:" << !bNut.isEmpty()
                 << "bili_ticket:" << !biliTicket.isEmpty();
    }
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }
    if (!buvid3.isEmpty()) {
        request.setRawHeader(QByteArray("buvid"), buvid3.toUtf8());
    }

    request.setAttribute(QNetworkRequest::CacheLoadControlAttribute, QNetworkRequest::AlwaysNetwork);

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        if (reply->error() != QNetworkReply::NoError) {
            emit errorOccurred(reply->errorString());
            reply->deleteLater();
            return;
        }
        QByteArray data = reply->readAll();
        qDebug() << "[ApiManager] searchUser response size:" << data.size()
                 << "preview:" << QString::fromUtf8(data.left(500));
        emit searchUserReceived(data);
        reply->deleteLater();
    });
}

void ApiManager::getSearchSuggest(const QString &keyword)
{
    if (keyword.trimmed().isEmpty()) {
        emit searchSuggestReceived(QStringList());
        return;
    }

    QString url = QString("https://s.search.bilibili.com/main/suggest?term=%1&main_ver=v1")
                      .arg(QString(QUrl::toPercentEncoding(keyword)));

    qDebug() << "[ApiManager] getSearchSuggest url:" << url;

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), QByteArray("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"));
    request.setRawHeader(QByteArray("Referer"), QByteArray("https://search.bilibili.com/"));
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));
    request.setAttribute(QNetworkRequest::CacheLoadControlAttribute, QNetworkRequest::AlwaysNetwork);

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        QStringList words;
        if (reply->error() == QNetworkReply::NoError) {
            QByteArray data = reply->readAll();
            QJsonDocument doc = QJsonDocument::fromJson(data);
            if (doc.isObject()) {
                QJsonObject root = doc.object();
                QJsonObject resultObj = root.value("result").toObject();
                if (!resultObj.isEmpty()) {
                    // B站返回字段: result.tag（小写）
                    QJsonArray tagArr = resultObj.value("tag").toArray();
                    if (tagArr.isEmpty()) {
                        // 兼容：部分客户端可能返回 Tag（大写）
                        tagArr = resultObj.value("Tag").toArray();
                    }
                    for (const QJsonValue &v : tagArr) {
                        QJsonObject o = v.toObject();
                        QString w = o.value("value").toString();
                        if (!w.isEmpty()) words.append(w);
                    }
                } else {
                    // 另一种兼容: 顶层 data: [{"value":...}]
                    QJsonArray dataArr = root.value("data").toArray();
                    for (const QJsonValue &v : dataArr) {
                        QJsonObject o = v.toObject();
                        QString w = o.value("value").toString();
                        if (!w.isEmpty()) words.append(w);
                    }
                }
            }
            qDebug() << "[ApiManager] getSearchSuggest words count:" << words.size();
        } else {
            qWarning() << "[ApiManager] getSearchSuggest network error:" << reply->errorString();
        }
        emit searchSuggestReceived(words);
        reply->deleteLater();
    });
}

void ApiManager::getSearchSquare(int limit)
{
    // 搜索首页的「大家都在搜」。接口不需要 wbi 签名，未登录可直接拿；
    // 返回 data.trending.list[]，每项 { keyword, show_name, icon, heat_score }，
    // icon 就是「热/新」那类小角标图。这里原样把 JSON 丢给 QML，
    // 由界面决定切多少条给「大家都在搜」、多少条给「搜索发现」。
    QString url = QString("https://api.bilibili.com/x/web-interface/search/square?limit=%1")
                      .arg(qBound(1, limit, 50));

    QNetworkRequest request{QUrl(url)};
    request.setRawHeader(QByteArray("User-Agent"), QByteArray("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"));
    request.setRawHeader(QByteArray("Referer"), QByteArray("https://search.bilibili.com/"));
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));
    request.setAttribute(QNetworkRequest::CacheLoadControlAttribute, QNetworkRequest::AlwaysNetwork);

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        if (reply->error() == QNetworkReply::NoError) {
            emit searchSquareReceived(reply->readAll());
        } else {
            qWarning() << "[ApiManager] getSearchSquare network error:" << reply->errorString();
            emit searchSquareReceived(QByteArray());
        }
        reply->deleteLater();
    });
}

void ApiManager::getVideoDetailByBvid(const QString &bvid)
{
    QString url = m_apiBaseUrl + "/x/web-interface/view";
    QString params = QString("&bvid=%1").arg(bvid);
    url += "?" + params;
    
    getRequest(url);
}

void ApiManager::getVideoTags(const QString &bvid)
{
    // 视频标签（播放页标签墙用）。公开接口，无需 wbi 签名。
    QString url = QString("https://api.bilibili.com/x/tag/archive/tags?bvid=%1").arg(bvid);
    getRequest(url);
}

void ApiManager::getVideoDetailByAid(const QString &aid)
{
    QString url = m_apiBaseUrl + "/x/web-interface/view";
    QString params = QString("&aid=%1").arg(aid);
    url += "?" + params;

    getRequest(url);
}

void ApiManager::getUserUploadedVideos(const QString &mid, int pn, int ps)
{
    // 使用与 wiliwili 一致的 /x/space/arc/list 接口获取 UP 主全部投稿
    QString url = QString("https://api.bilibili.com/x/space/arc/list?mid=%1&pn=%2&ps=%3")
                      .arg(mid).arg(pn).arg(ps);

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), QByteArray("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"));
    request.setRawHeader(QByteArray("Referer"), QString("https://space.bilibili.com/%1/video").arg(mid).toUtf8());
    request.setRawHeader(QByteArray("Origin"), QByteArray("https://www.bilibili.com"));
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));

    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        if (reply->error() != QNetworkReply::NoError) {
            emit errorOccurred(reply->errorString());
            reply->deleteLater();
            return;
        }
        QByteArray data = reply->readAll();
        emit userUploadedVideosReceived(data);
        reply->deleteLater();
    });
}

void ApiManager::getRelatedVideos(const QString &aid)
{
    // 使用 /x/web-interface/view 接口，该接口的返回值中包含 related 字段
    QString url = m_apiBaseUrl + "/x/web-interface/view";
    QString params = QString("&aid=%1").arg(aid);
    url += "?" + params;

    getRequest(url);
}

void ApiManager::getHistoryList(int max, int viewAt, const QString &type, int ps)
{
    QString url = "https://api.bilibili.com/x/web-interface/history/cursor";
    // 参数名是 type 而不是 business：接口只认 type（business 会被忽略，
    // 传了也永远拉到全量）。取值 "all" 或服务端 data.tab 下发的分类标识。
    QString params = QString("max=%1&view_at=%2&type=%3&ps=%4")
                         .arg(max).arg(viewAt).arg(type).arg(ps);

    QUrl qurl(url + "?" + params);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), QByteArray("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"));
    request.setRawHeader(QByteArray("Referer"), QByteArray("https://www.bilibili.com/"));
    request.setRawHeader(QByteArray("Origin"), QByteArray("https://www.bilibili.com"));
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));

    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, type]() {
        if (reply->error() != QNetworkReply::NoError) {
            emit errorOccurred(reply->errorString());
            reply->deleteLater();
            return;
        }
        QByteArray data = reply->readAll();
        emit historyListReceived(data, type);
        reply->deleteLater();
    });
}

void ApiManager::getDynamicVideos(const QString &offset, int ps, uint64_t hostMid)
{
    QString url = "https://api.bilibili.com/x/polymer/web-dynamic/desktop/v1/feed/video";

    QUrlQuery query;
    query.addQueryItem("page", "1");
    query.addQueryItem("offset", offset);
    query.addQueryItem("ps", QString::number(ps));
    if (hostMid > 0) {
        query.addQueryItem("host_mid", QString::number(hostMid));
    }

    QString params = query.query(QUrl::FullyEncoded);
    QString signedParams = WbiSigner::instance()->signParams(params);

    url += "?" + signedParams;

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), QByteArray("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"));
    request.setRawHeader(QByteArray("Referer"), QByteArray("https://www.bilibili.com/"));
    request.setRawHeader(QByteArray("Origin"), QByteArray("https://www.bilibili.com"));
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));

    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        if (reply->error() != QNetworkReply::NoError) {
            qDebug() << "[ApiManager] getDynamicVideos network error:" << reply->errorString();
            emit errorOccurred(reply->errorString());
            reply->deleteLater();
            return;
        }
        QByteArray data = reply->readAll();
        qDebug() << "[ApiManager] getDynamicVideos response:" << data.left(500);
        emit dynamicVideosReceived(data);
        reply->deleteLater();
    });
}

void ApiManager::getDynamicUpList()
{
    QString url = "https://api.bilibili.com/x/polymer/web-dynamic/v1/uplist";

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), QByteArray("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"));
    request.setRawHeader(QByteArray("Referer"), QByteArray("https://www.bilibili.com/"));
    request.setRawHeader(QByteArray("Origin"), QByteArray("https://www.bilibili.com"));
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));

    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        if (reply->error() != QNetworkReply::NoError) {
            qDebug() << "[ApiManager] getDynamicUpList network error:" << reply->errorString();
            emit errorOccurred(reply->errorString());
            reply->deleteLater();
            return;
        }
        QByteArray data = reply->readAll();
        qDebug() << "[ApiManager] getDynamicUpList response:" << data.left(500);
        emit dynamicUpListReceived(data);
        reply->deleteLater();
    });
}

void ApiManager::getFollowings(int pn, int ps)
{
    // 使用 /x/relation/followings 接口获取完整关注列表（支持分页）
    // 相比 /x/polymer/web-dynamic/v1/uplist（只返回有动态更新的子集），此接口可获取全部关注对象
    int myMid = LoginManager::instance()->mid();
    if (myMid == 0) {
        qDebug() << "[ApiManager] getFollowings: not logged in";
        emit errorOccurred("未登录");
        return;
    }

    QString baseUrl = "https://api.bilibili.com/x/relation/followings";
    QUrlQuery query;
    query.addQueryItem("vmid", QString::number(myMid));
    query.addQueryItem("pn", QString::number(pn));
    query.addQueryItem("ps", QString::number(ps));
    query.addQueryItem("order", "desc");
    query.addQueryItem("order_type", "attention");

    QString params = query.query(QUrl::FullyEncoded);
    QString signedParams = WbiSigner::instance()->signParams(params);
    QString url = baseUrl + "?" + signedParams;

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), QByteArray("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"));
    request.setRawHeader(QByteArray("Referer"), QByteArray("https://www.bilibili.com/"));
    request.setRawHeader(QByteArray("Origin"), QByteArray("https://www.bilibili.com"));
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));

    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        if (reply->error() != QNetworkReply::NoError) {
            qDebug() << "[ApiManager] getFollowings network error:" << reply->errorString();
            emit errorOccurred(reply->errorString());
            reply->deleteLater();
            return;
        }
        QByteArray data = reply->readAll();
        qDebug() << "[ApiManager] getFollowings response:" << data.left(500);
        emit followingsReceived(data);
        reply->deleteLater();
    });
}

void ApiManager::getDynamicArticleList(const QString &offset, int ps, uint64_t hostMid)
{
    QString url = "https://api.bilibili.com/x/polymer/web-dynamic/desktop/v1/feed/all";

    QUrlQuery query;
    query.addQueryItem("page", "1");
    query.addQueryItem("offset", offset);
    if (hostMid > 0) {
        query.addQueryItem("host_mid", QString::number(hostMid));
    }

    QString params = query.query(QUrl::FullyEncoded);
    QString signedParams = WbiSigner::instance()->signParams(params);

    url += "?" + signedParams;

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), QByteArray("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"));
    request.setRawHeader(QByteArray("Referer"), QByteArray("https://www.bilibili.com/"));
    request.setRawHeader(QByteArray("Origin"), QByteArray("https://www.bilibili.com"));
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));

    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        if (reply->error() != QNetworkReply::NoError) {
            qDebug() << "[ApiManager] getDynamicArticleList network error:" << reply->errorString();
            emit errorOccurred(reply->errorString());
            reply->deleteLater();
            return;
        }
        QByteArray data = reply->readAll();
        qDebug() << "[ApiManager] getDynamicArticleList response:" << data.left(500);
        emit dynamicArticleListReceived(data);
        reply->deleteLater();
    });
}

void ApiManager::getDynamicDetail(const QString &id)
{
    QString url = "https://api.bilibili.com/x/polymer/web-dynamic/desktop/v1/detail";

    QUrlQuery query;
    query.addQueryItem("id", id);

    QString params = query.query(QUrl::FullyEncoded);
    QString signedParams = WbiSigner::instance()->signParams(params);

    url += "?" + signedParams;

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), QByteArray("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"));
    request.setRawHeader(QByteArray("Referer"), QByteArray("https://www.bilibili.com/"));
    request.setRawHeader(QByteArray("Origin"), QByteArray("https://www.bilibili.com"));
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));

    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        if (reply->error() != QNetworkReply::NoError) {
            qDebug() << "[ApiManager] getDynamicDetail network error:" << reply->errorString();
            emit errorOccurred(reply->errorString());
            reply->deleteLater();
            return;
        }
        QByteArray data = reply->readAll();
        qDebug() << "[ApiManager] getDynamicDetail response:" << data.left(500);
        emit dynamicDetailReceived(data);
        reply->deleteLater();
    });
}

void ApiManager::getOpusDetail(const QString &id)
{
    // 不需要 WBI 签名（实测普通 GET 即返回 code:0）。
    // 唯一会下发 live_url（实况照片的动态视频 mp4）的端点，
    // 详见 ApiManager.h 中该函数的注释。
    QString url = "https://api.bilibili.com/x/polymer/web-dynamic/v1/opus/detail";

    QUrlQuery query;
    query.addQueryItem("id", id);

    QUrl qurl(url + "?" + query.query(QUrl::FullyEncoded));
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), QByteArray("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"));
    request.setRawHeader(QByteArray("Referer"), QByteArray("https://www.bilibili.com/"));
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));

    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        if (reply->error() != QNetworkReply::NoError) {
            // 实况视频地址只是增强信息，拿不到不影响主流程，
            // 所以这里不向 QML 抛 errorOccurred（那会让页面以为整次请求失败了）
            qDebug() << "[ApiManager] getOpusDetail network error:" << reply->errorString();
            reply->deleteLater();
            return;
        }
        QByteArray data = reply->readAll();
        qDebug() << "[ApiManager] getOpusDetail response:" << data.left(500);
        emit opusDetailReceived(data);
        reply->deleteLater();
    });
}

void ApiManager::getLiveList()
{
    // 使用 feedV2 接口获取推荐直播和关注主播
    QString url = "https://api.live.bilibili.com/xlive/app-interface/v2/index/feedV2";
    
    // 添加签名参数
    QString ts = QString::number(QDateTime::currentSecsSinceEpoch() * 1000);
    QString params = QString("parent_area_id=%1&area_id=%2&device=switch&page=%3&platform=web&scale=xxhdpi&source_name=pc&mobi_app=pc_electron&appkey=%4&build=%5&ts=%6")
                         .arg(m_currentParentArea).arg(m_currentSubArea).arg(m_currentPage)
                         .arg("aa1e74ee4874176e").arg("1001011000").arg(ts);
    
    // 计算签名
    QString sortedParams = params;
    QStringList paramList = sortedParams.split("&");
    paramList.sort();
    sortedParams = paramList.join("&");
    QString sign = QCryptographicHash::hash((sortedParams + "54e6a9a31b911cd5fc0daa66ebf94bc4").toUtf8(), QCryptographicHash::Md5).toHex();
    
    url += "?" + params + "&sign=" + sign;

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), QByteArray("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"));
    request.setRawHeader(QByteArray("Referer"), QByteArray("https://live.bilibili.com/"));
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));
    request.setRawHeader(QByteArray("Origin"), QByteArray("https://www.bilibili.com"));
    request.setRawHeader(QByteArray("buvid"), QByteArray("XY8D30F8-E10D-4B3A-B9C6-78D2E1C4F7A0"));
    request.setRawHeader(QByteArray("buvid_fp"), QByteArray("d9a5c7d8f2e1b4a6c3b9e7f1a2d4c6b8"));

    // 添加 Cookie
    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    QSslConfiguration config = QSslConfiguration::defaultConfiguration();
    config.setPeerVerifyMode(QSslSocket::VerifyNone);
    request.setSslConfiguration(config);

    m_networkManager->setRedirectPolicy(QNetworkRequest::NoLessSafeRedirectPolicy);

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        if (reply->error() != QNetworkReply::NoError) {
            emit errorOccurred(reply->errorString());
            reply->deleteLater();
            return;
        }

        QByteArray data = reply->readAll();
        qDebug() << "[ApiManager] getLiveList response:" << data.left(800);
        emit liveListReceived(data);
        reply->deleteLater();
    });
}

void ApiManager::getLiveAreaList()
{
    // 获取直播分区列表
    QString url = "https://api.live.bilibili.com/xlive/app-interface/v2/index/getAreaList?platform=web";

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), QByteArray("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"));
    request.setRawHeader(QByteArray("Referer"), QByteArray("https://live.bilibili.com/"));
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));

    QSslConfiguration config = QSslConfiguration::defaultConfiguration();
    config.setPeerVerifyMode(QSslSocket::VerifyNone);
    request.setSslConfiguration(config);

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        if (reply->error() != QNetworkReply::NoError) {
            emit errorOccurred(reply->errorString());
            reply->deleteLater();
            return;
        }

        QByteArray data = reply->readAll();
        qDebug() << "[ApiManager] getLiveAreaList response:" << data.left(800);
        emit liveAreaListReceived(data);
        reply->deleteLater();
    });
}

void ApiManager::getSubAreaLiveList(int parentAreaId, int areaId, int page)
{
    // 获取指定分区的直播列表（使用 second/getList 接口）
    QString ts = QString::number(QDateTime::currentSecsSinceEpoch() * 1000);
    QString params = QString("parent_area_id=%1&area_id=%2&page=%3&page_size=20&platform=web&device=switch&appkey=%4&build=%5&ts=%6")
                         .arg(parentAreaId).arg(areaId).arg(page)
                         .arg("aa1e74ee4874176e").arg("1001011000").arg(ts);
    
    // 计算签名
    QString sortedParams = params;
    QStringList paramList = sortedParams.split("&");
    paramList.sort();
    sortedParams = paramList.join("&");
    QString sign = QCryptographicHash::hash((sortedParams + "54e6a9a31b911cd5fc0daa66ebf94bc4").toUtf8(), QCryptographicHash::Md5).toHex();
    
    QString url = "https://api.live.bilibili.com/xlive/app-interface/v2/second/getList?" + params + "&sign=" + sign;

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), QByteArray("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"));
    request.setRawHeader(QByteArray("Referer"), QByteArray("https://live.bilibili.com/"));
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));
    request.setRawHeader(QByteArray("Origin"), QByteArray("https://www.bilibili.com"));
    request.setRawHeader(QByteArray("buvid"), QByteArray("XY8D30F8-E10D-4B3A-B9C6-78D2E1C4F7A0"));
    request.setRawHeader(QByteArray("buvid_fp"), QByteArray("d9a5c7d8f2e1b4a6c3b9e7f1a2d4c6b8"));

    // 添加 Cookie
    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    QSslConfiguration config = QSslConfiguration::defaultConfiguration();
    config.setPeerVerifyMode(QSslSocket::VerifyNone);
    request.setSslConfiguration(config);

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        if (reply->error() != QNetworkReply::NoError) {
            emit errorOccurred(reply->errorString());
            reply->deleteLater();
            return;
        }

        QByteArray data = reply->readAll();
        qDebug() << "[ApiManager] getSubAreaLiveList response:" << data.left(800);
        emit subAreaLiveListReceived(data);
        reply->deleteLater();
    });
}

void ApiManager::getFollowingLive()
{
    // 获取关注主播的直播列表
    // 正确接口：https://api.live.bilibili.com/xlive/web-ucenter/user/following
    QString url = "https://api.live.bilibili.com/xlive/web-ucenter/user/following?page=1&page_size=10&ignoreRecord=1&hit_ab=true";

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), QByteArray("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"));
    request.setRawHeader(QByteArray("Referer"), QByteArray("https://live.bilibili.com/"));
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));

    // 添加 Cookie（关注主播需要登录）
    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    QSslConfiguration config = QSslConfiguration::defaultConfiguration();
    config.setPeerVerifyMode(QSslSocket::VerifyNone);
    request.setSslConfiguration(config);

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        if (reply->error() != QNetworkReply::NoError) {
            emit errorOccurred(reply->errorString());
            reply->deleteLater();
            return;
        }

        QByteArray data = reply->readAll();
        emit followingLiveReceived(data);
        reply->deleteLater();
    });
}

void ApiManager::setLiveArea(int parentAreaId, int subAreaId)
{
    m_currentParentArea = parentAreaId;
    m_currentSubArea = subAreaId;
}

void ApiManager::setLivePage(int page)
{
    m_currentPage = page;
}

void ApiManager::getLiveStreamInfo(const QString &roomId, int qn, const QString &platform)
{
    // 获取直播流地址，使用 web 接口，返回 HLS/FLV 播放地址
    QString url = QString("https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo?room_id=%1&protocol=0,1&format=0,1,2&codec=0,1&qn=%2&platform=%3&ptype=8&dolby=5&panorama=1")
                      .arg(roomId).arg(qn).arg(platform);

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), QByteArray("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"));
    request.setRawHeader(QByteArray("Referer"), QByteArray("https://live.bilibili.com/"));
    request.setRawHeader(QByteArray("Origin"), QByteArray("https://live.bilibili.com"));
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));

    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    QSslConfiguration config = QSslConfiguration::defaultConfiguration();
    config.setPeerVerifyMode(QSslSocket::VerifyNone);
    request.setSslConfiguration(config);

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        if (reply->error() != QNetworkReply::NoError) {
            qDebug() << "[ApiManager] getLiveStreamInfo network error:" << reply->errorString();
            emit errorOccurred(reply->errorString());
            reply->deleteLater();
            return;
        }
        QByteArray data = reply->readAll();
        qDebug() << "[ApiManager] getLiveStreamInfo response:" << data.left(500);
        emit liveStreamInfoReceived(data);
        reply->deleteLater();
    });
}

void ApiManager::getLiveRoomInfo(const QString &roomId)
{
    // 获取直播间信息（getInfoByRoom），包含标题、主播、封面、人气等
    QString url = QString("https://api.live.bilibili.com/xlive/web-room/v1/index/getInfoByRoom?room_id=%1").arg(roomId);

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), QByteArray("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"));
    request.setRawHeader(QByteArray("Referer"), QByteArray("https://live.bilibili.com/"));
    request.setRawHeader(QByteArray("Origin"), QByteArray("https://live.bilibili.com"));
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));

    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    QSslConfiguration config = QSslConfiguration::defaultConfiguration();
    config.setPeerVerifyMode(QSslSocket::VerifyNone);
    request.setSslConfiguration(config);

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        if (reply->error() != QNetworkReply::NoError) {
            qDebug() << "[ApiManager] getLiveRoomInfo network error:" << reply->errorString();
            emit errorOccurred(reply->errorString());
            reply->deleteLater();
            return;
        }
        QByteArray data = reply->readAll();
        qDebug() << "[ApiManager] getLiveRoomInfo response:" << data.left(500);
        emit liveRoomInfoReceived(data);
        reply->deleteLater();
    });
}

void ApiManager::getLiveDanmuInfo(const QString &roomId)
{
    // 获取弹幕WebSocket连接信息（参考原项目 BiliQt_cmake_ela，使用WBI签名）
    QString params = QString("id=%1&type=0").arg(roomId);

    WbiSigner *signer = WbiSigner::instance();
    QString signedParams = signer->signParams(params);

    QString url = QString("https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo?%1")
                      .arg(signedParams);

    QUrl reqUrl(url);
    QNetworkRequest request(reqUrl);

    QString referer = QString("https://live.bilibili.com/%1").arg(roomId);

    LoginManager *loginMgr = LoginManager::instance();

    request.setRawHeader("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36");
    request.setRawHeader("Referer", referer.toUtf8());
    request.setRawHeader("Origin", "https://live.bilibili.com");
    request.setRawHeader("Accept", "application/json, text/plain, */*");
    request.setRawHeader("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8");
    request.setRawHeader("Cache-Control", "no-cache");
    request.setRawHeader("Pragma", "no-cache");

    QString buvid3 = loginMgr->getCurrentUser().buvid3;
    if (!buvid3.isEmpty()) {
        request.setRawHeader("buvid", buvid3.toUtf8());
    }

    QString cookies = loginMgr->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    QSslConfiguration config = QSslConfiguration::defaultConfiguration();
    config.setPeerVerifyMode(QSslSocket::VerifyNone);
    request.setSslConfiguration(config);

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        if (reply->error() != QNetworkReply::NoError) {
            qDebug() << "[ApiManager] getLiveDanmuInfo network error:" << reply->errorString();
            emit errorOccurred(reply->errorString());
            reply->deleteLater();
            return;
        }
        QByteArray data = reply->readAll();
        qDebug() << "[ApiManager] getLiveDanmuInfo response:" << data.left(500);
        emit liveDanmuInfoReceived(data);
        reply->deleteLater();
    });
}

void ApiManager::reportLiveHistory(const QString &roomId)
{
    if (roomId.isEmpty()) return;

    QString url = "https://api.live.bilibili.com/xlive/web-room/v1/index/roomEntryAction";
    QString csrf = getCSRFToken();

    QUrlQuery query;
    query.addQueryItem("room_id", roomId);
    query.addQueryItem("platform", "pc");
    query.addQueryItem("csrf_token", csrf);
    query.addQueryItem("csrf", csrf);
    query.addQueryItem("visit_id", "");
    QByteArray postData = query.toString(QUrl::FullyEncoded).toUtf8();

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setHeader(QNetworkRequest::ContentTypeHeader, "application/x-www-form-urlencoded");
    request.setRawHeader("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36");
    request.setRawHeader("Referer", QString("https://live.bilibili.com/%1").arg(roomId).toUtf8());
    request.setRawHeader("Origin", "https://live.bilibili.com");
    request.setRawHeader("Accept", "application/json, text/plain, */*");

    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    QSslConfiguration config = QSslConfiguration::defaultConfiguration();
    config.setPeerVerifyMode(QSslSocket::VerifyNone);
    request.setSslConfiguration(config);

    QNetworkReply *reply = m_networkManager->post(request, postData);
    connect(reply, &QNetworkReply::finished, this, [reply, roomId]() {
        if (reply->error() != QNetworkReply::NoError) {
            qWarning() << "[ApiManager] reportLiveHistory failed for room" << roomId << ":" << reply->errorString();
        } else {
            QByteArray data = reply->readAll();
            qDebug() << "[ApiManager] reportLiveHistory success for room" << roomId << ":" << data;
        }
        reply->deleteLater();
    });
}

// ===== 直播间发送弹幕（Web 路线：cookie + csrf）=====
// 最初按 biliuwp-lite 走 App 签名路线（appkey + access_key），但本客户端
// 的 Web 扫码登录（passport-login/web/qrcode/poll）只下发 cookie、不产生
// access_token，空 access_key 导致服务器一律 -101。改走 Web 路线：
// 文字走 /msg/send（B 站网页直播原生接口），大表情走
// /xlive/app-room/v1/dM/sendmsg（网页端表情包同款，接受 cookie+csrf），
// 直播域带 cookie 的 POST 已由 reportLiveHistory 验证可用（同走
// m_networkManager，与 playurl 隔离）
void ApiManager::sendLiveDanmakuPost(const QString &url, const QUrlQuery &query,
                                     const QString &roomId)
{
    // 未登录/无 cookie 直接返回错误（QML 侧有前置拦截，此处兜底）
    QString cookies = LoginManager::instance()->getCookies();
    QString csrf = getCSRFToken();
    if (cookies.isEmpty() || csrf.isEmpty()) {
        emit liveDanmakuSendResult(QByteArray("{\"code\":-101,\"message\":\"未登录\"}"));
        return;
    }

    QByteArray postData = query.toString(QUrl::FullyEncoded).toUtf8();

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setHeader(QNetworkRequest::ContentTypeHeader, "application/x-www-form-urlencoded");
    request.setRawHeader("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36");
    request.setRawHeader("Referer", QString("https://live.bilibili.com/%1").arg(roomId).toUtf8());
    request.setRawHeader("Origin", "https://live.bilibili.com");
    request.setRawHeader("Accept", "application/json, text/plain, */*");
    request.setRawHeader("Cookie", cookies.toUtf8());

    QSslConfiguration config = QSslConfiguration::defaultConfiguration();
    config.setPeerVerifyMode(QSslSocket::VerifyNone);
    request.setSslConfiguration(config);

    QNetworkReply *reply = m_networkManager->post(request, postData);
    connect(reply, &QNetworkReply::finished, this, [this, reply, roomId]() {
        if (reply->error() != QNetworkReply::NoError) {
            qWarning() << "[ApiManager] sendLiveDanmaku network error room" << roomId
                       << ":" << reply->errorString();
            emit liveDanmakuSendResult(QByteArray("{\"code\":-1,\"message\":\"network error: "
                                                  + reply->errorString().toUtf8() + "\"}"));
            reply->deleteLater();
            return;
        }
        QByteArray data = reply->readAll();
        qDebug() << "[ApiManager] sendLiveDanmaku response:" << data.left(500);
        emit liveDanmakuSendResult(data);
        reply->deleteLater();
    });
}

void ApiManager::sendLiveDanmaku(const QString &roomId, const QString &text)
{
    // 文字弹幕：/msg/send，字段与 B 站网页端一致
    // color=16777215(白色) fontsize=25 mode=1(滚动) rnd=毫秒时间戳
    QString csrf = getCSRFToken();
    QUrlQuery query;
    query.addQueryItem("bubble", "0");
    query.addQueryItem("msg", text);
    query.addQueryItem("color", "16777215");
    query.addQueryItem("mode", "1");
    query.addQueryItem("fontsize", "25");
    query.addQueryItem("rnd", QString::number(QDateTime::currentMSecsSinceEpoch()));
    query.addQueryItem("roomid", roomId);
    query.addQueryItem("csrf_token", csrf);
    query.addQueryItem("csrf", csrf);

    sendLiveDanmakuPost("https://api.live.bilibili.com/msg/send", query, roomId);
}

void ApiManager::sendLiveDanmakuEmoticon(const QString &roomId, const QString &emoticonUnique,
                                         const QString &emoticonText)
{
    // 大表情：dM/sendmsg（网页端表情包同款端点，cookie+csrf 认证）。
    // 字段集与网页端/biliuwp 一致：msg=emoticon_unique，extra 内含
    // content/emoticon_unique/dm_type；mid 取当前登录用户（服务器也会
    // 从 cookie 校验）
    LoginManager *loginMgr = LoginManager::instance();
    QString csrf = getCSRFToken();
    qint64 ms = QDateTime::currentMSecsSinceEpoch();
    qint64 sec = QDateTime::currentSecsSinceEpoch();

    QJsonObject extraObj;
    extraObj["content"] = emoticonText;
    extraObj["emoticon_unique"] = emoticonUnique;
    extraObj["dm_type"] = 1;
    QString extra = QString::fromUtf8(QJsonDocument(extraObj).toJson(QJsonDocument::Compact));

    QUrlQuery query;
    query.addQueryItem("cid", roomId);
    query.addQueryItem("mid", QString::number(loginMgr->getCurrentUser().mid));
    query.addQueryItem("msg", emoticonUnique);
    query.addQueryItem("dm_type", "1");
    query.addQueryItem("extra", extra);
    query.addQueryItem("ts", QString::number(sec));
    query.addQueryItem("rnd", QString::number(ms));
    query.addQueryItem("mode", "1");
    query.addQueryItem("pool", "0");
    query.addQueryItem("type", "json");
    query.addQueryItem("color", "16777215");
    query.addQueryItem("fontsize", "25");
    query.addQueryItem("playTime", "0.0");
    query.addQueryItem("csrf_token", csrf);
    query.addQueryItem("csrf", csrf);

    sendLiveDanmakuPost("https://api.live.bilibili.com/xlive/app-room/v1/dM/sendmsg",
                        query, roomId);
}

// 天选时刻一键参与。
//
// 正确端点是 POST /xlive/lottery-interface/v1/Anchor/Join
//   表单：room_id / id / platform=pc / csrf
// （此前写成 /Anchor/JoinLottery，服务端没有这个路径，一直返回 404。
//  另外必须带 room_id 与 platform=pc，缺了也会被拒。）
//
// 条件不由服务端代做：require_type=1（关注主播）与 danmu（口令弹幕）都得
// 客户端先自己完成，官方网页端同样是「关注 → 发弹幕 → 参与」三步。
// 这里串行执行，前面一步失败也继续（已关注会返回 22014，弹幕有频率限制
// 也可能失败，但都不该挡住参与），只把最后 Join 的结果回给 QML。
void ApiManager::joinLiveLottery(const QString &roomId, const QString &lotteryId,
                                 const QString &anchorMid, int requireType,
                                 const QString &danmu)
{
    LoginManager *loginMgr = LoginManager::instance();
    QString cookies = loginMgr->getCookies();
    QString csrf = getCSRFToken();
    if (cookies.isEmpty() || csrf.isEmpty()) {
        emit anchorLotteryJoinResult(QByteArray("{\"code\":-101,\"message\":\"未登录\"}"));
        return;
    }

    // Anchor/Join 明确要求 cookie 里带 buvid3（设备指纹），而登录 cookie
    // 未必含它 —— 缺了会被风控挡下。与 getUserSpaceDynamics 同法补齐。
    auto appendCookie = [&cookies](const QString &key, const QString &val) {
        if (val.isEmpty()) return;
        if (!cookies.contains(key + "=")) {
            if (!cookies.endsWith("; ")) cookies += "; ";
            cookies += QString("%1=%2; ").arg(key, val);
        }
    };
    appendCookie("buvid3", loginMgr->getOrCreateBuvid3());
    appendCookie("buvid4", loginMgr->getBuvid4());
    appendCookie("b_nut", loginMgr->getBNut());
    appendCookie("bili_ticket", loginMgr->getBiliTicket());

    // 统一的表单 POST：Web 直播接口都是 cookie + csrf（bili_jct）
    auto postForm = [this, cookies, roomId](const QString &url, const QByteArray &body,
                                           std::function<void(const QByteArray &)> done) {
        QUrl qurl(url);
        QNetworkRequest request(qurl);
        request.setHeader(QNetworkRequest::ContentTypeHeader,
                          "application/x-www-form-urlencoded");
        request.setRawHeader("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                                           "AppleWebKit/537.36 (KHTML, like Gecko) "
                                           "Chrome/120.0.0.0 Safari/537.36");
        request.setRawHeader("Referer", QString("https://live.bilibili.com/%1").arg(roomId).toUtf8());
        request.setRawHeader("Origin", "https://live.bilibili.com");
        request.setRawHeader("Accept", "application/json, text/plain, */*");
        request.setRawHeader("Cookie", cookies.toUtf8());

        QSslConfiguration config = QSslConfiguration::defaultConfiguration();
        config.setPeerVerifyMode(QSslSocket::VerifyNone);
        request.setSslConfiguration(config);

        QNetworkReply *reply = m_networkManager->post(request, body);
        connect(reply, &QNetworkReply::finished, this, [reply, done]() {
            QByteArray data = reply->readAll();
            if (reply->error() != QNetworkReply::NoError) {
                qWarning() << "[ApiManager] anchor lottery step network error:"
                           << reply->url().toString() << reply->errorString();
                data = QByteArray("{\"code\":-1,\"message\":\"network error\"}");
            }
            reply->deleteLater();
            done(data);
        });
    };

    // 第三步：参与。这是唯一会把结果回给 QML 的请求
    auto doJoin = [this, postForm, roomId, lotteryId, csrf]() {
        QUrlQuery q;
        q.addQueryItem("room_id", roomId);
        q.addQueryItem("id", lotteryId);
        q.addQueryItem("platform", "pc");
        q.addQueryItem("csrf", csrf);
        qDebug() << "[ApiManager] anchor lottery join -> room" << roomId << "id" << lotteryId;
        postForm("https://api.live.bilibili.com/xlive/lottery-interface/v1/Anchor/Join",
                 q.toString(QUrl::FullyEncoded).toUtf8(),
                 [this](const QByteArray &resp) {
                     qDebug() << "[ApiManager] anchor lottery join response:" << resp.left(500);
                     emit anchorLotteryJoinResult(resp);
                 });
    };

    // 第二步：口令弹幕（无口令则跳过）
    std::function<void()> startJoin = doJoin;
    const QString danmuText = danmu.trimmed();
    if (!danmuText.isEmpty()) {
        auto next = doJoin;
        startJoin = [this, postForm, roomId, danmuText, csrf, next]() {
            QUrlQuery q;
            q.addQueryItem("bubble", "0");
            q.addQueryItem("msg", danmuText);
            q.addQueryItem("color", "16777215");
            q.addQueryItem("mode", "1");
            q.addQueryItem("fontsize", "25");
            q.addQueryItem("rnd", QString::number(QDateTime::currentMSecsSinceEpoch()));
            q.addQueryItem("roomid", roomId);
            q.addQueryItem("csrf_token", csrf);
            q.addQueryItem("csrf", csrf);
            qDebug() << "[ApiManager] anchor lottery: send required danmu" << danmuText;
            postForm("https://api.live.bilibili.com/msg/send",
                     q.toString(QUrl::FullyEncoded).toUtf8(),
                     [next](const QByteArray &resp) {
                         qDebug() << "[ApiManager] anchor lottery danmu response:"
                                  << resp.left(300);
                         next();
                     });
        };
    }

    // 第一步：关注主播（仅 require_type==1 且拿得到 mid）
    if (requireType == 1 && !anchorMid.isEmpty()) {
        QUrlQuery q;
        q.addQueryItem("act", "1");
        q.addQueryItem("fid", anchorMid);
        q.addQueryItem("re_src", "32");
        q.addQueryItem("csrf", csrf);
        auto next = startJoin;
        qDebug() << "[ApiManager] anchor lottery: follow anchor" << anchorMid;
        postForm("https://api.bilibili.com/x/relation/modify",
                 q.toString(QUrl::FullyEncoded).toUtf8(),
                 [next](const QByteArray &resp) {
                     qDebug() << "[ApiManager] anchor lottery follow response:" << resp.left(300);
                     next();
                 });
    } else {
        startJoin();
    }
}

void ApiManager::getLiveEmoticons(const QString &roomId)
{
    QString cookies = LoginManager::instance()->getCookies();
    if (cookies.isEmpty()) {
        emit liveEmoticonsReceived(QByteArray("{\"code\":-101,\"message\":\"未登录\"}"));
        return;
    }

    // web-ucenter 接口本就是 Web 端使用，带 cookie 即可（无需 App 签名）。
    // platform=pc 为必带参数（不带时服务器返回空数据）；
    // room_id 必须为真实房间号（非短号），调用方已保证
    QString url = QString("https://api.live.bilibili.com/xlive/web-ucenter/v2/emoticon/GetEmoticons?platform=pc&room_id=%1")
                      .arg(roomId);

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36");
    request.setRawHeader("Referer", QString("https://live.bilibili.com/%1").arg(roomId).toUtf8());
    request.setRawHeader("Accept", "application/json, text/plain, */*");
    request.setRawHeader("Cookie", cookies.toUtf8());

    QSslConfiguration config = QSslConfiguration::defaultConfiguration();
    config.setPeerVerifyMode(QSslSocket::VerifyNone);
    request.setSslConfiguration(config);

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, roomId]() {
        if (reply->error() != QNetworkReply::NoError) {
            qWarning() << "[ApiManager] getLiveEmoticons network error room" << roomId
                       << ":" << reply->errorString();
            // 网络失败也发信号（code=-1），QML 侧据此结束"加载中"状态
            emit liveEmoticonsReceived(QByteArray("{\"code\":-1,\"message\":\"network error: "
                                                  + reply->errorString().toUtf8() + "\"}"));
            reply->deleteLater();
            return;
        }
        QByteArray data = reply->readAll();
        qDebug() << "[ApiManager] getLiveEmoticons response:" << data.left(500);
        emit liveEmoticonsReceived(data);
        reply->deleteLater();
    });
}

void ApiManager::sendVideoDanmaku(const QString &cid, const QString &bvid, const QString &text,
                                  int colorDecimal, int progressMs)
{
    // 视频弹幕：POST /x/v2/dm/post（B 站网页端原生接口，cookie+csrf）。
    // progress 为当前播放进度（毫秒，服务端以此定位弹幕落点）；
    // mode=1 滚动 / fontsize=25 / pool=0 普通 / type=1 普通弹幕
    QString cookies = LoginManager::instance()->getCookies();
    QString csrf = getCSRFToken();
    if (cookies.isEmpty() || csrf.isEmpty()) {
        emit videoDanmakuSendResult(QByteArray("{\"code\":-101,\"message\":\"未登录\"}"));
        return;
    }

    QUrlQuery query;
    query.addQueryItem("type", "1");
    query.addQueryItem("oid", cid);
    query.addQueryItem("msg", text);
    query.addQueryItem("bvid", bvid);
    query.addQueryItem("progress", QString::number(progressMs));
    query.addQueryItem("color", QString::number(colorDecimal));
    query.addQueryItem("fontsize", "25");
    query.addQueryItem("pool", "0");
    query.addQueryItem("mode", "1");
    query.addQueryItem("plat", "1");
    query.addQueryItem("csrf_token", csrf);
    query.addQueryItem("csrf", csrf);

    QUrl qurl("https://api.bilibili.com/x/v2/dm/post");
    QNetworkRequest request(qurl);
    request.setHeader(QNetworkRequest::ContentTypeHeader, "application/x-www-form-urlencoded");
    request.setRawHeader("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36");
    request.setRawHeader("Referer", QString("https://www.bilibili.com/video/%1").arg(bvid).toUtf8());
    request.setRawHeader("Origin", "https://www.bilibili.com");
    request.setRawHeader("Accept", "application/json, text/plain, */*");
    request.setRawHeader("Cookie", cookies.toUtf8());

    QSslConfiguration config = QSslConfiguration::defaultConfiguration();
    config.setPeerVerifyMode(QSslSocket::VerifyNone);
    request.setSslConfiguration(config);

    QNetworkReply *reply = m_networkManager->post(request, query.toString(QUrl::FullyEncoded).toUtf8());
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        if (reply->error() != QNetworkReply::NoError) {
            qWarning() << "[ApiManager] sendVideoDanmaku network error:" << reply->errorString();
            emit videoDanmakuSendResult(QByteArray("{\"code\":-1,\"message\":\"network error: "
                                                   + reply->errorString().toUtf8() + "\"}"));
            reply->deleteLater();
            return;
        }
        QByteArray data = reply->readAll();
        qDebug() << "[ApiManager] sendVideoDanmaku response:" << data.left(500);
        emit videoDanmakuSendResult(data);
        reply->deleteLater();
    });
}

QString ApiManager::getCSRFToken()
{
    QString cookies = LoginManager::instance()->getCookies();
    QStringList parts = cookies.split(";", Qt::SkipEmptyParts);
    for (const QString &part : parts) {
        QString trimmed = part.trimmed();
        if (trimmed.startsWith("bili_jct=")) {
            return trimmed.mid(9);
        }
    }
    return "";
}

QString ApiManager::getSign(const QString &params)
{
    QString toSign = params;
    
    int questionPos = toSign.indexOf("?");
    if (questionPos != -1) {
        toSign = toSign.mid(questionPos + 1);
    }
    
    QStringList paramList = toSign.split("&");
    paramList.sort();
    QString sortedParams = paramList.join("&");
    
    QString signSource = sortedParams + m_appSecret;
    
    QCryptographicHash hash(QCryptographicHash::Md5);
    hash.addData(signSource.toUtf8());
    QString sign = hash.result().toHex().toLower();
    
    return "&sign=" + sign;
}

QString ApiManager::generateTimestamp()
{
    return QString::number(QDateTime::currentSecsSinceEpoch());
}

QString ApiManager::getMustParameters()
{
    return QString("appkey=%1&build=5442100&mobi_app=android&platform=android&ts=%2")
        .arg(m_appKey, generateTimestamp());
}

void ApiManager::getRequest(const QString &url)
{
    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), QByteArray("Mozilla/5.0 BiliDroid/5.44.2 (bbcallen@gmail.com)"));
    request.setRawHeader(QByteArray("Referer"), QByteArray("https://www.bilibili.com/"));
    request.setRawHeader(QByteArray("x-bili-aurora-zone"), QByteArray("sh001"));
    request.setRawHeader(QByteArray("x-bili-aurora-eid"), QByteArray("UlMFQVcABlAH"));

    // 未登录时也发送 buvid3/buvid4 等设备指纹 cookie，让推荐接口能区分设备/会话
    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader(QByteArray("Cookie"), cookies.toUtf8());
    }

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        onReplyFinished(reply);
    });
}

void ApiManager::onReplyFinished(QNetworkReply *reply)
{
    if (reply->error() != QNetworkReply::NoError) {
        emit errorOccurred(reply->errorString());
        reply->deleteLater();
        return;
    }
    
    QByteArray data = reply->readAll();
    QString url = reply->url().toString();
    
    if (url.contains("x/v2/feed/index")) {
        emit recommendVideosReceived(data);
    } else if (url.contains("wbi/index/top/feed/rcmd")) {
        emit wbiRecommendVideosReceived(data);
    } else if (url.contains("search/type")) {
        emit searchResultsReceived(data);
    } else if (url.contains("x/tag/archive/tags")) {
        emit videoTagsReceived(data);
    } else if (url.contains("x/web-interface/view")) {
        emit videoDetailReceived(data);
    }
    
    reply->deleteLater();
}
