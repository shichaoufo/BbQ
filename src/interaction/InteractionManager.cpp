#include "InteractionManager.h"
#include "LoginManager.h"
#include <QCryptographicHash>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QUrl>
#include <QUrlQuery>
#include <QHash>
#include <QDateTime>
#include <QDebug>


const QString InteractionManager::USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
const QString InteractionManager::REFERER = "https://www.bilibili.com";
const QString InteractionManager::ORIGIN = "https://www.bilibili.com";
const QString InteractionManager::ANDROID_USER_AGENT = "Mozilla/5.0 BiliDroid/5.44.2 (bbcallen@gmail.com)";
const QString InteractionManager::APP_KEY = "1d8b6e7d45233436";
const QString InteractionManager::APP_SECRET = "560c52ccd288fed045859ed18bffd973";

InteractionManager::InteractionManager(QObject *parent)
    : QObject(parent)
    , m_networkManager(new QNetworkAccessManager(this))
{
}

InteractionManager::~InteractionManager()
{
}

// 在成员函数内部使用：未登录时直接 emit actionFailed("请先登录") 并返回
#define ENSURE_LOGGED_IN(action) \
    if (!LoginManager::instance()->isLoggedIn()) { \
        qDebug() << "[InteractionManager]" << (action) << "failed: not logged in"; \
        emit actionFailed((action), "请先登录"); \
        return; \
    }

// 把 B 站接口常见的登录/权限错误文案统一为 "请先登录"
static QString normalizeErrorMessage(const QString &message)
{
    if (message.contains("未登录") ||
        message.contains("请先登录") ||
        message.contains("login", Qt::CaseInsensitive) ||
        message == "-101" ||
        message == "-401") {
        return "请先登录";
    }
    return message;
}

// 从登录管理器获取 CSRF Token（bili_jct）
QString InteractionManager::getCSRFToken()
{
    QString cookies = LoginManager::instance()->getCookies();
    QStringList parts = cookies.split(";", Qt::SkipEmptyParts);
    for (const QString &part : parts) {
        QString trimmed = part.trimmed();
        if (trimmed.startsWith("bili_jct=")) {
            return trimmed.mid(9);  // 去掉 "bili_jct=" 前缀
        }
    }
    return "";
}

// 为请求设置通用请求头（User-Agent, Referer, Cookie, Origin等）
void InteractionManager::setupRequest(QNetworkRequest &request)
{
    request.setRawHeader(QByteArray("User-Agent"), USER_AGENT.toUtf8());
    request.setRawHeader(QByteArray("Referer"), REFERER.toUtf8());
    request.setRawHeader(QByteArray("Origin"), ORIGIN.toUtf8());
    // 注意：不设置 Accept-Encoding，让 QNetworkAccessManager 自动处理解压
    // 如果服务器返回 gzip 压缩数据，Qt 会自动解压

    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        
        request.setRawHeader(QByteArray("Cookie"), cookies.toUtf8());
    } else {

    }
    QString csrf = getCSRFToken();

}

void InteractionManager::likeVideo(const QString &aid, int like)
{
    // like=1 点赞, like=2 取消, like=3 点踩（点踩走 web 端接口）
    QString action = (like == 3 || like == 4) ? "dislike" : "like";

    ENSURE_LOGGED_IN(action)

    QString url = "https://api.bilibili.com/x/web-interface/archive/like";

    QString postData = QString("aid=%1&like=%2&eab_x=%3&ramval=7&source=web_normal&ga=1&csrf=%4")
                           .arg(aid)
                           .arg(like)
                           .arg(like)
                           .arg(getCSRFToken());

    qDebug() << "[InteractionManager] likeVideo POST:" << url << postData;

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    setupRequest(request);
    request.setRawHeader(QByteArray("Content-Type"), QByteArray("application/x-www-form-urlencoded"));

    QNetworkReply *reply = m_networkManager->post(request, postData.toUtf8());
    m_replyActionMap[reply] = action;
    connect(reply, &QNetworkReply::finished, this, &InteractionManager::onReplyFinished);
}

void InteractionManager::unlikeVideo(const QString &aid)
{
    likeVideo(aid, 2); // 2表示取消点赞
}

void InteractionManager::dislikeVideo(const QString &aid, int targetDislike, int currentLike)
{
    QString action = "dislike";
    ENSURE_LOGGED_IN(action)

    QString accessKey = LoginManager::instance()->getCurrentUser().accessKey;

    // 优先使用 App 端接口（与 biliuwp-lite 一致）
    if (!accessKey.isEmpty()) {
        QString url = "https://app.biliapi.net/x/v2/view/dislike";
        QString ts = QString::number(QDateTime::currentDateTime().toSecsSinceEpoch());
        // App 端传当前状态，接口内部切换；这里用 targetDislike 反推 currentDislike
        int currentDislike = targetDislike == 1 ? 0 : 1;
        QString body = QString("access_key=%1&appkey=%2&build=6240300&mobi_app=android&platform=android&ts=%3&aid=%4&dislike=%5&from=7&like=%6")
                           .arg(accessKey)
                           .arg(APP_KEY)
                           .arg(ts)
                           .arg(aid)
                           .arg(currentDislike)
                           .arg(currentLike);
        body += getSign(body);

        qDebug() << "[InteractionManager] dislikeVideo app POST:" << url << body;

        QUrl qurl(url);
        QNetworkRequest request(qurl);
        request.setRawHeader(QByteArray("User-Agent"), ANDROID_USER_AGENT.toUtf8());
        request.setRawHeader(QByteArray("Referer"), REFERER.toUtf8());
        request.setRawHeader(QByteArray("Content-Type"), QByteArray("application/x-www-form-urlencoded"));

        QNetworkReply *reply = m_networkManager->post(request, body.toUtf8());
        m_replyActionMap[reply] = action;
        connect(reply, &QNetworkReply::finished, this, &InteractionManager::onReplyFinished);
        return;
    }

    // 未获取到 access_key 时回退 Web 端接口
    // Web 端：like=3 设置点踩，like=4 取消点踩
    QString url = "https://api.bilibili.com/x/web-interface/archive/like";
    int likeValue = targetDislike == 1 ? 3 : 4;
    QString postData = QString("aid=%1&like=%2&csrf=%3").arg(aid).arg(likeValue).arg(getCSRFToken());

    qDebug() << "[InteractionManager] dislikeVideo web POST:" << url << postData;

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    setupRequest(request);
    request.setRawHeader(QByteArray("Content-Type"), QByteArray("application/x-www-form-urlencoded"));

    QNetworkReply *reply = m_networkManager->post(request, postData.toUtf8());
    m_replyActionMap[reply] = action;
    connect(reply, &QNetworkReply::finished, this, &InteractionManager::onReplyFinished);
}

void InteractionManager::favoriteVideo(const QString &aid, const QString &fid, int addMedia)
{
    Q_UNUSED(addMedia)
    QString action = "favorite";
    ENSURE_LOGGED_IN(action)

    QString url = "https://api.bilibili.com/x/v3/fav/resource/deal";

    QString postData = QString("rid=%1&type=2&add_media_ids=%2&del_media_ids=&platform=web&csrf=%3")
                           .arg(aid)
                           .arg(fid)
                           .arg(getCSRFToken());

    qDebug() << "[InteractionManager] favoriteVideo POST:" << url << postData;

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    setupRequest(request);
    request.setRawHeader(QByteArray("Content-Type"), QByteArray("application/x-www-form-urlencoded"));

    QNetworkReply *reply = m_networkManager->post(request, postData.toUtf8());
    m_replyActionMap[reply] = action;
    connect(reply, &QNetworkReply::finished, this, &InteractionManager::onReplyFinished);
}

void InteractionManager::unfavoriteVideo(const QString &aid, const QString &fid)
{
    QString action = "unfavorite";
    ENSURE_LOGGED_IN(action)

    QString url = "https://api.bilibili.com/x/v3/fav/resource/deal";

    QString postData = QString("rid=%1&type=2&add_media_ids=&del_media_ids=%2&platform=web&csrf=%3")
                           .arg(aid)
                           .arg(fid)
                           .arg(getCSRFToken());

    qDebug() << "[InteractionManager] unfavoriteVideo POST:" << url << postData;

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    setupRequest(request);
    request.setRawHeader(QByteArray("Content-Type"), QByteArray("application/x-www-form-urlencoded"));

    QNetworkReply *reply = m_networkManager->post(request, postData.toUtf8());
    m_replyActionMap[reply] = action;
    connect(reply, &QNetworkReply::finished, this, &InteractionManager::onReplyFinished);
}

void InteractionManager::coinVideo(const QString &aid, const QString &bvid, int num, int selectLike)
{
    QString action = "coin";
    ENSURE_LOGGED_IN(action)

    // 当前登录方式为 Web 扫码登录，产生的是 Web cookie（SESSDATA/bili_jct），
    // 与 Web 端接口天然匹配。accessKey 仅来自历史遗留的 App 端 token（已过期或为空），
    // 使用 App 端接口会对部分视频返回"非法访问"。因此投币统一走 Web 端接口。
    coinVideoWeb(aid, bvid, num, selectLike);
}

void InteractionManager::coinVideoWeb(const QString &aid, const QString &bvid, int num, int selectLike)
{
    QString action = "coin";
    QString url = "https://api.bilibili.com/x/web-interface/coin/add";

    QUrlQuery query;
    query.addQueryItem("aid", aid);
    query.addQueryItem("multiply", QString::number(num));
    query.addQueryItem("select_like", QString::number(selectLike));
    query.addQueryItem("cross_domain", "true");
    query.addQueryItem("eab_x", QString::number(selectLike));
    query.addQueryItem("ramval", "7");
    query.addQueryItem("source", "web_normal");
    query.addQueryItem("ga", "1");
    query.addQueryItem("csrf", getCSRFToken());
    if (!bvid.isEmpty()) {
        query.addQueryItem("bvid", bvid);
    }
    QString postData = query.toString(QUrl::FullyEncoded);

    qDebug() << "[InteractionManager] coinVideo web POST:" << url << postData;

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    setupRequest(request);
    if (!bvid.isEmpty()) {
        request.setRawHeader(QByteArray("Referer"), (QString("https://www.bilibili.com/video/%1").arg(bvid)).toUtf8());
    }
    request.setRawHeader(QByteArray("Content-Type"), QByteArray("application/x-www-form-urlencoded"));
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));
    request.setRawHeader(QByteArray("X-Requested-With"), QByteArray("XMLHttpRequest"));

    QNetworkReply *reply = m_networkManager->post(request, postData.toUtf8());
    m_replyActionMap[reply] = action;
    connect(reply, &QNetworkReply::finished, this, &InteractionManager::onReplyFinished);
}

void InteractionManager::tripleAction(const QString &aid, const QString &bvid, bool like, bool favorite, bool coin)
{
    if (like) {
        likeVideo(aid);
    }
    if (coin) {
        coinVideo(aid, bvid);
    }
    // TODO: 收藏功能需要获取收藏夹列表让用户选择
}

void InteractionManager::followUser(const QString &mid, int act)
{
    // act=1 关注, act=2 取消关注
    QString action = (act == 2) ? "unfollow" : "follow";
    ENSURE_LOGGED_IN(action)

    // 参照 biliuwp-lite：使用 /x/relation/modify 接口，参数用 fid（不是 mid）
    QString url = "https://api.bilibili.com/x/relation/modify";

    // 参照 biliuwp-lite：参数使用 fid 而非 mid，re_src=32
    QUrlQuery query;
    query.addQueryItem("act", QString::number(act));
    query.addQueryItem("fid", mid);
    query.addQueryItem("re_src", "32");
    query.addQueryItem("extend_content", QString("{\"entity\":\"user\",\"entity_id\":%1}").arg(mid));
    query.addQueryItem("jsonp", "jsonp");
    query.addQueryItem("csrf", getCSRFToken());
    QString postData = query.toString(QUrl::FullyEncoded);

    qDebug() << "[InteractionManager] followUser POST:" << url << postData;

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    setupRequest(request);
    request.setRawHeader(QByteArray("Content-Type"), QByteArray("application/x-www-form-urlencoded"));

    QNetworkReply *reply = m_networkManager->post(request, postData.toUtf8());
    m_replyActionMap[reply] = action;
    connect(reply, &QNetworkReply::finished, this, &InteractionManager::onReplyFinished);
}

void InteractionManager::getVideoStatus(const QString &aid)
{
    // 重置状态
    m_statusLikeReceived = false;
    m_statusCoinReceived = false;
    m_statusFavReceived = false;
    m_statusLiked = false;
    m_statusCoined = 0;
    m_statusFavorited = false;

    QString cookies = LoginManager::instance()->getCookies();

    // 1. 点赞状态
    {
        QString url = QString("https://api.bilibili.com/x/web-interface/archive/has/like?aid=%1")
                          .arg(aid);
        QUrl qurl(url);
        QNetworkRequest request(qurl);
        request.setHeader(QNetworkRequest::UserAgentHeader, USER_AGENT);
        request.setRawHeader("Referer", REFERER.toUtf8());
        request.setRawHeader("Origin", ORIGIN.toUtf8());
        if (!cookies.isEmpty()) {
            request.setRawHeader("Cookie", cookies.toUtf8());
        }
        QNetworkReply *reply = m_networkManager->get(request);
        connect(reply, &QNetworkReply::finished, this, [this, reply]() {
            QByteArray data = reply->readAll();
            if (reply->error() == QNetworkReply::NoError) {
                QJsonDocument doc = QJsonDocument::fromJson(data);
                if (doc.isObject()) {
                    QJsonObject root = doc.object();
                    if (root["code"].toInt() == 0) {
                        QJsonValue dataVal = root["data"];
                        if (dataVal.isObject()) {
                            m_statusLiked = dataVal.toObject()["like"].toInt() == 1;
                        } else {
                            m_statusLiked = (dataVal.toInt() == 1);
                        }

                    }
                }
            }
            m_statusLikeReceived = true;
            checkAllStatusReady();
            reply->deleteLater();
        });
    }

    // 2. 投币状态
    {
        QString url = QString("https://api.bilibili.com/x/web-interface/archive/coins?aid=%1")
                          .arg(aid);
        QUrl qurl(url);
        QNetworkRequest request(qurl);
        request.setHeader(QNetworkRequest::UserAgentHeader, USER_AGENT);
        request.setRawHeader("Referer", REFERER.toUtf8());
        request.setRawHeader("Origin", ORIGIN.toUtf8());
        if (!cookies.isEmpty()) {
            request.setRawHeader("Cookie", cookies.toUtf8());
        }
        QNetworkReply *reply = m_networkManager->get(request);
        connect(reply, &QNetworkReply::finished, this, [this, reply]() {
            QByteArray data = reply->readAll();
            if (reply->error() == QNetworkReply::NoError) {
                QJsonDocument doc = QJsonDocument::fromJson(data);
                if (doc.isObject()) {
                    QJsonObject root = doc.object();
                    if (root["code"].toInt() == 0) {
                        QJsonObject dataObj = root["data"].toObject();
                        m_statusCoined = dataObj["multiply"].toInt();

                    }
                }
            }
            m_statusCoinReceived = true;
            checkAllStatusReady();
            reply->deleteLater();
        });
    }

    // 3. 收藏状态
    {
        QString url = QString("https://api.bilibili.com/x/v2/fav/video/favoured?aid=%1")
                          .arg(aid);
        QUrl qurl(url);
        QNetworkRequest request(qurl);
        request.setHeader(QNetworkRequest::UserAgentHeader, USER_AGENT);
        request.setRawHeader("Referer", REFERER.toUtf8());
        request.setRawHeader("Origin", ORIGIN.toUtf8());
        if (!cookies.isEmpty()) {
            request.setRawHeader("Cookie", cookies.toUtf8());
        }
        QNetworkReply *reply = m_networkManager->get(request);
        connect(reply, &QNetworkReply::finished, this, [this, reply]() {
            QByteArray data = reply->readAll();
            if (reply->error() == QNetworkReply::NoError) {
                QJsonDocument doc = QJsonDocument::fromJson(data);
                if (doc.isObject()) {
                    QJsonObject root = doc.object();
                    if (root["code"].toInt() == 0) {
                        QJsonObject dataObj = root["data"].toObject();
                        m_statusFavorited = dataObj["favoured"].toInt() == 1;

                    }
                }
            }
            m_statusFavReceived = true;
            checkAllStatusReady();
            reply->deleteLater();
        });
    }
}

// 获取 UP 主关注状态
void InteractionManager::getUserRelation(const QString &mid)
{
    QString action = "relation";

    QString url = QString("https://api.bilibili.com/x/relation?fid=%1")
                      .arg(mid);

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setHeader(QNetworkRequest::UserAgentHeader, USER_AGENT);
    request.setRawHeader("Referer", REFERER.toUtf8());
    request.setRawHeader("Origin", ORIGIN.toUtf8());

    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }



    QNetworkReply *reply = m_networkManager->get(request);
    m_replyActionMap[reply] = action;
    connect(reply, &QNetworkReply::finished, this, &InteractionManager::onReplyFinished);
}

void InteractionManager::getUserFollowers(const QString &mid)
{
    QString action = "user_followers";

    QString url = QString("https://api.bilibili.com/x/relation/stat?vmid=%1")
                      .arg(mid);

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setHeader(QNetworkRequest::UserAgentHeader, USER_AGENT);
    request.setRawHeader("Referer", REFERER.toUtf8());
    request.setRawHeader("Origin", ORIGIN.toUtf8());

    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    QNetworkReply *reply = m_networkManager->get(request);
    m_replyActionMap[reply] = action;
    connect(reply, &QNetworkReply::finished, this, &InteractionManager::onReplyFinished);
}

void InteractionManager::getDefaultFavoriteFolder(const QString &aid)
{
    QString action = "default_folder";

    ENSURE_LOGGED_IN(action)

    int mid = LoginManager::instance()->getCurrentUser().mid;
    if (mid <= 0) {
        qDebug() << "[InteractionManager] getDefaultFavoriteFolder failed: no valid mid";
        emit actionFailed(action, "请先登录");
        return;
    }

    QString url = QString("https://api.bilibili.com/x/v3/fav/folder/created/list-all?type=2&rid=%1&up_mid=%2&pn=1&ps=100")
                      .arg(aid)
                      .arg(mid);

    qDebug() << "[InteractionManager] getDefaultFavoriteFolder GET:" << url;

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setHeader(QNetworkRequest::UserAgentHeader, USER_AGENT);
    request.setRawHeader("Referer", REFERER.toUtf8());
    request.setRawHeader("Origin", ORIGIN.toUtf8());

    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    QNetworkReply *reply = m_networkManager->get(request);
    m_replyActionMap[reply] = action;
    connect(reply, &QNetworkReply::finished, this, &InteractionManager::onReplyFinished);
}

void InteractionManager::reportHistory(const QString &aid, const QString &cid, int progress)
{
    reportHistory(aid, cid, progress, 0);
}

void InteractionManager::reportHistory(const QString &aid, const QString &cid, int progress, int duration)
{
    QString action = "report_history";
    ENSURE_LOGGED_IN(action)

    QUrlQuery query;
    query.addQueryItem("aid", aid);
    query.addQueryItem("cid", cid);
    query.addQueryItem("progress", QString::number(progress));
    query.addQueryItem("realtime", QString::number(progress));
    query.addQueryItem("type", "3");
    if (duration > 0) {
        query.addQueryItem("duration", QString::number(duration));
    }
    query.addQueryItem("dt", "9");
    query.addQueryItem("csrf", getCSRFToken());
    QString postData = query.toString(QUrl::FullyEncoded);

    QString url = "https://api.bilibili.com/x/v2/history/report";
    qDebug() << "[InteractionManager] reportHistory POST:" << url << postData;

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    setupRequest(request);
    request.setRawHeader(QByteArray("Content-Type"), QByteArray("application/x-www-form-urlencoded"));

    QNetworkReply *reply = m_networkManager->post(request, postData.toUtf8());
    m_replyActionMap[reply] = action;
    connect(reply, &QNetworkReply::finished, this, &InteractionManager::onReplyFinished);
}

void InteractionManager::reportBangumiHistory(const QString &aid, const QString &cid, int progress, int duration, const QString &epid, const QString &sid)
{
    QString action = "report_history";
    ENSURE_LOGGED_IN(action)

    QUrlQuery query;
    query.addQueryItem("aid", aid);
    query.addQueryItem("cid", cid);
    query.addQueryItem("progress", QString::number(progress));
    query.addQueryItem("realtime", QString::number(progress));
    query.addQueryItem("type", "4");  // 番剧使用 type=4
    query.addQueryItem("epid", epid);  // 番剧需要 epid
    query.addQueryItem("sid", sid);    // 番剧需要 sid
    if (duration > 0) {
        query.addQueryItem("duration", QString::number(duration));
    }
    query.addQueryItem("dt", "9");
    query.addQueryItem("csrf", getCSRFToken());
    QString postData = query.toString(QUrl::FullyEncoded);

    QString url = "https://api.bilibili.com/x/v2/history/report";
    qDebug() << "[InteractionManager] reportBangumiHistory POST:" << url << postData;

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    setupRequest(request);
    request.setRawHeader(QByteArray("Content-Type"), QByteArray("application/x-www-form-urlencoded"));

    QNetworkReply *reply = m_networkManager->post(request, postData.toUtf8());
    m_replyActionMap[reply] = action;
    connect(reply, &QNetworkReply::finished, this, &InteractionManager::onReplyFinished);
}

void InteractionManager::onReplyFinished()
{
    QNetworkReply *reply = qobject_cast<QNetworkReply*>(sender());
    if (!reply) return;

    QString action = m_replyActionMap.take(reply);

    QByteArray data = reply->readAll();

    qDebug() << "[InteractionManager] onReplyFinished action:" << action
             << "error:" << reply->error()
             << "data:" << data.left(512);

    if (reply->error() != QNetworkReply::NoError) {
        QString errorMsg = QString("Network error: %1").arg(reply->errorString());
        errorMsg = normalizeErrorMessage(errorMsg);

        emit actionFailed(action, errorMsg);
        emit errorOccurred(errorMsg);
        reply->deleteLater();
        return;
    }

    if (action == "status") {
        parseStatusData(data);
    } else if (action == "relation") {
        parseRelationData(data);
    } else if (action == "user_followers") {
        QJsonDocument doc = QJsonDocument::fromJson(data);
        if (doc.isObject()) {
            QJsonObject root = doc.object();
            if (root["code"].toInt() == 0) {
                QJsonObject dataObj = root["data"].toObject();
                int follower = dataObj["follower"].toInt();
                emit userFollowersReady(follower);
            }
        }
    } else if (action == "default_folder") {
        QJsonDocument doc = QJsonDocument::fromJson(data);
        if (!doc.isObject()) {
            emit actionFailed(action, "Invalid JSON format");
            reply->deleteLater();
            return;
        }

        QJsonObject root = doc.object();
        int code = root["code"].toInt();
        QString message = root["message"].toString();

        if (code == 0) {
            QJsonObject dataObj = root["data"].toObject();
            QJsonArray list = dataObj["list"].toArray();
            if (!list.isEmpty()) {
                QJsonObject folder = list.first().toObject();
                QString fid;
                if (folder.contains("media_id") && !folder["media_id"].isNull()) {
                    fid = QString::number(folder["media_id"].toVariant().toLongLong());
                } else {
                    fid = QString::number(folder["id"].toVariant().toLongLong());
                }
                QString name = folder["title"].toString();
                qDebug() << "[InteractionManager] default folder fid:" << fid << "name:" << name;
                emit defaultFavoriteFolderReady(fid, name);
            } else {
                // 未登录时 data 可能为 null，但 ensureLoggedIn 已拦截大部分情况；
                // 若已登录但没有任何收藏夹，给出更友好的中文提示
                if (!LoginManager::instance()->isLoggedIn()) {
                    emit actionFailed(action, "请先登录");
                } else {
                    emit actionFailed(action, "暂无收藏夹");
                }
            }
        } else {
            emit actionFailed(action, normalizeErrorMessage(message));
        }
    } else {
        QJsonDocument doc = QJsonDocument::fromJson(data);
        if (!doc.isObject()) {

            emit actionFailed(action, "Invalid JSON format");
            reply->deleteLater();
            return;
        }

        QJsonObject root = doc.object();
        int code = root["code"].toInt();
        QString message = root["message"].toString();

        if (code == 0) {
            QString successMsg = message;
            if (action == "coin") {
                QJsonObject dataObj = root["data"].toObject();
                if (!dataObj.isEmpty() && dataObj.contains("toast")) {
                    successMsg = dataObj["toast"].toString();
                }
                if (successMsg.isEmpty()) {
                    successMsg = "投币成功";
                }
            }
            emit actionSuccess(action, successMsg);
        } else {
            emit actionFailed(action, normalizeErrorMessage(message));
        }
    }

    reply->deleteLater();
}

void InteractionManager::parseStatusData(const QByteArray &data)
{
    QJsonDocument doc = QJsonDocument::fromJson(data);
    if (!doc.isObject()) {

        return;
    }

    QJsonObject root = doc.object();
    int code = root["code"].toInt();


    if (code != 0) {

        // 即使失败也发送默认状态，避免界面卡死
        emit statusReady(false, false, 0);
        return;
    }

    // has/like 接口: data 字段直接是 0 或 1 (0=未点赞, 1=已点赞)
    bool liked = false;
    if (root.contains("data")) {
        QJsonValue dataVal = root["data"];
        if (dataVal.isObject()) {
            QJsonObject dataObj = dataVal.toObject();
            liked = dataObj["like"].toInt() == 1;
            bool favorited = dataObj["favorite"].toInt() == 1;
            int coined = dataObj["coin"].toInt();

            emit statusReady(liked, favorited, coined);
        } else {
            // data 是数字类型 (has/like 接口的返回格式)
            int likeStatus = dataVal.toInt();
            liked = (likeStatus == 1);

            emit statusReady(liked, false, 0);
        }
    } else {
        emit statusReady(false, false, 0);
    }
}

void InteractionManager::parseRelationData(const QByteArray &data)
{
    QJsonDocument doc = QJsonDocument::fromJson(data);
    if (!doc.isObject()) {

        return;
    }

    QJsonObject root = doc.object();
    int code = root["code"].toInt();


    if (code != 0) {

        emit relationReady(false, 0);
        return;
    }

    QJsonObject dataObj = root["data"].toObject();
    // attribute: 0=未关注, 2=已关注, 6=互相关注
    // 参考 biliuwp-lite 实现，仅 2 和 6 视为已关注
    int attribute = dataObj["attribute"].toInt();
    bool followed = (attribute == 2 || attribute == 6);

    emit relationReady(followed, attribute);
}

void InteractionManager::checkAllStatusReady()
{
    if (m_statusLikeReceived && m_statusCoinReceived && m_statusFavReceived) {

        emit statusReady(m_statusLiked, m_statusFavorited, m_statusCoined);
    }
}

QString InteractionManager::getSign(const QString &params)
{
    QString toSign = params;

    QStringList paramList = toSign.split("&");
    paramList.sort();
    QString sortedParams = paramList.join("&");

    QString signSource = sortedParams + APP_SECRET;

    QCryptographicHash hash(QCryptographicHash::Md5);
    hash.addData(signSource.toUtf8());
    QString sign = hash.result().toHex().toLower();

    return "&sign=" + sign;
}
