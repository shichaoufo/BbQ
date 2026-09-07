#include "CommentManager.h"
#include "LoginManager.h"
#include "WbiSigner.h"
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QUrlQuery>
#include <QUrl>
#include <QDebug>


const QString CommentManager::USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
const QString CommentManager::REFERER = "https://www.bilibili.com";

CommentManager::CommentManager(QObject *parent)
    : QObject(parent)
{
}

CommentManager::~CommentManager()
{
}

// 一次性 QNAM：每次请求新建网络管理器，用完即毁（详见 CommentManager.h 注释）。
// connect 顺序：先挂 onReplyFinished（读取响应、emit 结果），再挂 manager 销毁
QNetworkReply *CommentManager::postOneShot(const QNetworkRequest &request, const QByteArray &data, const ReplyContext &ctx)
{
    QNetworkAccessManager *manager = new QNetworkAccessManager(this);
    QNetworkReply *reply = manager->post(request, data);
    m_replyContextMap[reply] = ctx;
    connect(reply, &QNetworkReply::finished, this, &CommentManager::onReplyFinished);
    connect(reply, &QNetworkReply::finished, manager, &QObject::deleteLater);
    return reply;
}

QNetworkReply *CommentManager::getOneShot(const QNetworkRequest &request, const ReplyContext &ctx)
{
    QNetworkAccessManager *manager = new QNetworkAccessManager(this);
    QNetworkReply *reply = manager->get(request);
    m_replyContextMap[reply] = ctx;
    connect(reply, &QNetworkReply::finished, this, &CommentManager::onReplyFinished);
    connect(reply, &QNetworkReply::finished, manager, &QObject::deleteLater);
    return reply;
}

void CommentManager::getComments(const QString &oid, int type, int pn, int ps, int sort)
{
    qDebug() << "[CommentManager] getComments oid:" << oid << "type:" << type << "pn:" << pn << "ps:" << ps << "sort:" << sort;

    // 参照 biliuwp-lite：优先使用 /x/v2/reply/wbi/main，mode=3热度, mode=2时间
    int mode = (sort == 2) ? 3 : 2;
    QString offsetStr = (pn <= 1) ? "" : m_commentCursor.value(oid + "_" + QString::number(sort));
    QString paginationStr = QString("{\"offset\":\"%1\"}").arg(offsetStr);
    // 与 biliuwp-lite 的 CommentV2 保持完全一致：oid/ps/mode/type/pagination_str/(csrf)
    QString params = QString("oid=%1&ps=%2&mode=%3&type=%4&pagination_str=%5")
                         .arg(oid)
                         .arg(ps)
                         .arg(mode)
                         .arg(type)
                         .arg(QString::fromUtf8(QUrl::toPercentEncoding(paginationStr)));

    // 参照 biliuwp-lite：登录时把 csrf 也参与 WBI 签名
    QString csrf = getCSRFToken();
    if (!csrf.isEmpty()) {
        params += "&csrf=" + csrf;
    }

    QString signedParams = WbiSigner::instance()->signParams(params);
    QString url = "https://api.bilibili.com/x/v2/reply/wbi/main?" + signedParams;

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), USER_AGENT.toUtf8());
    request.setRawHeader(QByteArray("Referer"), REFERER.toUtf8());
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));
    request.setRawHeader(QByteArray("Origin"), QByteArray("https://www.bilibili.com"));

    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader(QByteArray("Cookie"), cookies.toUtf8());
    }

    ReplyContext ctx;
    ctx.action = "get_comments";
    ctx.type = type;
    ctx.sort = sort;
    ctx.oid = oid;
    getOneShot(request, ctx);
}

void CommentManager::getSubComments(const QString &oid, const QString &root, int pn, int ps, int type)
{
    // 子评论接口：与 biliuwp-lite 的 Reply 保持一致，使用 /x/v2/reply/reply，plat=2
    QString params = QString("type=%5&oid=%1&root=%2&pn=%3&ps=%4&plat=2")
                         .arg(oid)
                         .arg(root)
                         .arg(qMax(1, pn))
                         .arg(qBound(1, ps, 50))
                         .arg(type);

    QString url = "https://api.bilibili.com/x/v2/reply/reply?" + params;
    qDebug() << "[CommentManager] getSubComments GET:" << url;

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), USER_AGENT.toUtf8());
    request.setRawHeader(QByteArray("Referer"), REFERER.toUtf8());
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));
    request.setRawHeader(QByteArray("Origin"), QByteArray("https://www.bilibili.com"));

    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader(QByteArray("Cookie"), cookies.toUtf8());
    }

    ReplyContext ctx;
    ctx.action = "get_sub_comments";
    ctx.pendingRootRpid = root.toLongLong();
    getOneShot(request, ctx);
}

void CommentManager::sendComment(const QString &oid, const QString &content, int type,
                                 const QString &root, const QString &parent)
{
    QString url = "https://api.bilibili.com/x/v2/reply/add";

    QUrlQuery query;
    query.addQueryItem("oid", oid);
    query.addQueryItem("type", QString::number(type));
    query.addQueryItem("message", content);
    query.addQueryItem("plat", "1");
    query.addQueryItem("csrf", getCSRFToken());
    if (!root.isEmpty() && root != "0") {
        query.addQueryItem("root", root);
    }
    if (!parent.isEmpty() && parent != "0") {
        query.addQueryItem("parent", parent);
    }
    QString postData = query.toString(QUrl::FullyEncoded);

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), USER_AGENT.toUtf8());
    request.setRawHeader(QByteArray("Referer"), REFERER.toUtf8());
    request.setRawHeader(QByteArray("Content-Type"), QByteArray("application/x-www-form-urlencoded"));

    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader(QByteArray("Cookie"), cookies.toUtf8());
    }

    ReplyContext ctx;
    ctx.action = "send_comment";
    postOneShot(request, postData.toUtf8(), ctx);
}

void CommentManager::deleteComment(const QString &rpid, qint64 oid, int type)
{

    QString url = "https://api.bilibili.com/x/v2/reply/del";

    QString postData = QString("oid=%1&type=%2&rpid=%3&csrf=%4")
                           .arg(oid)
                           .arg(type)
                           .arg(rpid)
                           .arg(getCSRFToken());

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), USER_AGENT.toUtf8());
    request.setRawHeader(QByteArray("Referer"), REFERER.toUtf8());
    request.setRawHeader(QByteArray("Content-Type"), QByteArray("application/x-www-form-urlencoded"));

    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader(QByteArray("Cookie"), cookies.toUtf8());
    }

    ReplyContext ctx;
    ctx.action = "delete_comment";
    ctx.pendingRootRpid = rpid.toLongLong();
    postOneShot(request, postData.toUtf8(), ctx);
}

void CommentManager::likeComment(const QString &rpid, qint64 oid, int type, int action)
{


    QString url = "https://api.bilibili.com/x/v2/reply/action";

    QString postData = QString("oid=%1&type=%2&rpid=%3&action=%4&csrf=%5")
                           .arg(oid)
                           .arg(type)
                           .arg(rpid)
                           .arg(action)
                           .arg(getCSRFToken());

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), USER_AGENT.toUtf8());
    request.setRawHeader(QByteArray("Referer"), REFERER.toUtf8());
    request.setRawHeader(QByteArray("Content-Type"), QByteArray("application/x-www-form-urlencoded"));

    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader(QByteArray("Cookie"), cookies.toUtf8());
    }

    ReplyContext ctx;
    ctx.action = (action == 1) ? "like_comment" : "unlike_comment";
    ctx.pendingRootRpid = rpid.toLongLong();
    postOneShot(request, postData.toUtf8(), ctx);
}

void CommentManager::hateComment(const QString &rpid, qint64 oid, int type, int action)
{


    QString url = "https://api.bilibili.com/x/v2/reply/hate";

    QString postData = QString("oid=%1&type=%2&rpid=%3&action=%4&csrf=%5")
                           .arg(oid)
                           .arg(type)
                           .arg(rpid)
                           .arg(action)
                           .arg(getCSRFToken());

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), USER_AGENT.toUtf8());
    request.setRawHeader(QByteArray("Referer"), REFERER.toUtf8());
    request.setRawHeader(QByteArray("Content-Type"), QByteArray("application/x-www-form-urlencoded"));

    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader(QByteArray("Cookie"), cookies.toUtf8());
    }

    ReplyContext ctx;
    ctx.action = (action == 1) ? "hate_comment" : "unhate_comment";
    ctx.pendingRootRpid = rpid.toLongLong();
    postOneShot(request, postData.toUtf8(), ctx);
}

void CommentManager::onReplyFinished()
{
    QNetworkReply *reply = qobject_cast<QNetworkReply*>(sender());
    if (!reply) return;

    ReplyContext ctx = m_replyContextMap.take(reply);
    qDebug() << "[CommentManager] onReplyFinished action:" << ctx.action;

    if (reply->error() != QNetworkReply::NoError) {
        QString errorMsg = QString("Network error: %1").arg(reply->errorString());
        qDebug() << "[CommentManager] network error:" << errorMsg;
        emit errorOccurred(errorMsg);
        reply->deleteLater();
        return;
    }

    QByteArray data = reply->readAll();
    qDebug() << "[CommentManager] reply data size:" << data.size() << "content:" << data.left(512);

    if (ctx.action == "get_comments") {
        parseCommentsData(data, ctx.sort, ctx.oid);
    } else if (ctx.action == "get_sub_comments") {
        parseSubCommentsData(data, ctx.pendingRootRpid);
    } else {
        parseActionData(data, ctx.action, ctx.pendingRootRpid);
    }

    reply->deleteLater();
}

void CommentManager::parseCommentsData(const QByteArray &data, int sort, const QString &oid)
{
    QList<Comment> commentList;

    QJsonDocument doc = QJsonDocument::fromJson(data);
    if (!doc.isObject()) {
        emit errorOccurred("Invalid JSON format");
        return;
    }

    QJsonObject root = doc.object();
    int code = root["code"].toInt();
    QString message = root["message"].toString();

    if (code != 0) {
        emit errorOccurred(QString("API error: %1").arg(message));
        return;
    }

    QJsonObject dataObj = root["data"].toObject();
    QJsonObject pageObj = dataObj["page"].toObject();
    QJsonObject cursorObj = dataObj["cursor"].toObject();

    int page = pageObj["num"].toInt();
    int total = pageObj["count"].toInt();
    int allCount = cursorObj["all_count"].toInt();

    // 解析 WBI 主接口翻标（pagination_reply.next_offset）
    QString cursorKey = oid + "_" + QString::number(sort);
    QJsonObject paginationReply = cursorObj["pagination_reply"].toObject();
    QString nextOffset = paginationReply["next_offset"].toString();
    if (nextOffset.isEmpty()) {
        nextOffset = cursorObj["next_offset"].toString();
    }
    if (!nextOffset.isEmpty()) {
        m_commentCursor[cursorKey] = nextOffset;
    }

    // 解析置顶评论（WBI 主接口没有 page.num，直接判断是否存在 top_replies）
    // 参照 wiliwili：将 top_replies 标记为置顶并插入列表最前面
    if (dataObj.contains("top_replies")) {
        QJsonArray topReplies = dataObj["top_replies"].toArray();
        for (const QJsonValue &val : topReplies) {
            if (val.isObject()) {
                Comment comment = parseCommentObject(val.toObject());
                comment.isTop = true;
                commentList.append(comment);
            }
        }
    }

    // 解析普通评论
    QJsonArray replies = dataObj["replies"].toArray();
    for (const QJsonValue &val : replies) {
        if (val.isObject()) {
            Comment comment = parseCommentObject(val.toObject());
            commentList.append(comment);
        }
    }

    // WBI 接口 page.count 为 0，没有直接返回主评论数。
    // 用当前页普通主评论数占总评论（主+子）的比例估算主评论总数。
    if (total <= 0 && allCount > 0) {
        int mainCount = replies.size();
        int subCount = 0;
        for (const QJsonValue &val : replies) {
            if (!val.isObject()) continue;
            subCount += val.toObject().value("count").toInt();
        }
        if (mainCount + subCount > 0) {
            total = static_cast<int>(allCount * static_cast<qreal>(mainCount) / (mainCount + subCount));
        } else {
            total = allCount;
        }
    }

    QVariantList result;
    result.reserve(commentList.size());
    for (const Comment &comment : commentList) {
        result.append(commentToMap(comment));
    }

    int ipEmptyCount = 0;
    for (const Comment &c : commentList) {
        if (c.ipLocation.isEmpty()) ipEmptyCount++;
    }
    QJsonArray repliesArr = dataObj["replies"].toArray();
    if (!repliesArr.isEmpty()) {
        QJsonObject firstReply = repliesArr.first().toObject();
        QJsonObject firstReplyControl = firstReply["reply_control"].toObject();
        QStringList replyControlKeys;
        for (auto it = firstReplyControl.begin(); it != firstReplyControl.end(); ++it) {
            replyControlKeys << it.key();
        }
        qDebug() << "[CommentManager] first comment reply_control keys:" << replyControlKeys;
        qDebug() << "[CommentManager] first comment reply_control location:"
                 << firstReplyControl.value("location").toString()
                 << "ip_location:" << firstReplyControl.value("ip_location").toString()
                 << "top ip_location:" << firstReply["ip_location"].toString();
    }
    qDebug() << "[CommentManager] parseCommentsData done, count:" << result.size() << "page:" << page << "total:" << total
             << "nextOffset:" << nextOffset << "ipEmptyCount:" << ipEmptyCount;
    emit commentsReady(result, page, total, sort);
}

void CommentManager::parseSubCommentsData(const QByteArray &data, qint64 rootRpid)
{
    QList<Comment> commentList;

    QJsonDocument doc = QJsonDocument::fromJson(data);
    if (!doc.isObject()) return;

    QJsonObject root = doc.object();
    int code = root["code"].toInt();
    QString message = root["message"].toString();
    if (code != 0) {
        qDebug() << "[CommentManager] parseSubCommentsData error:" << code << message;
        emit errorOccurred(QString("get_sub_comments failed: %1").arg(message));
        return;
    }

    QJsonObject dataObj = root["data"].toObject();
    QJsonArray replies = dataObj["replies"].toArray();

    for (const QJsonValue &val : replies) {
        if (val.isObject()) {
            Comment comment = parseCommentObject(val.toObject());
            commentList.append(comment);
        }
    }

    QVariantList result;
    result.reserve(commentList.size());
    for (const Comment &comment : commentList) {
        result.append(commentToMap(comment));
    }

    emit subCommentsReady(rootRpid, result);
}

void CommentManager::parseActionData(const QByteArray &data, const QString &action, qint64 rpid)
{
    QJsonDocument doc = QJsonDocument::fromJson(data);
    if (!doc.isObject()) return;

    QJsonObject root = doc.object();
    int code = root["code"].toInt();
    QString message = root["message"].toString();

    if (action == "send_comment") {
        emit commentSent(code == 0, message);

        QVariantMap commentMap;
        QString rootStr, parentStr;
        if (code == 0) {
            QJsonObject dataObj = root["data"].toObject();
            QJsonObject replyObj = dataObj["reply"].toObject();
            if (!replyObj.isEmpty()) {
                Comment comment = parseCommentObject(replyObj);
                commentMap = commentToMap(comment);
                rootStr = comment.root;
                parentStr = comment.parent;
            }
        }
        emit commentPosted(code == 0, message, commentMap, rootStr, parentStr);
    } else {
        emit actionSuccess(action, rpid, code == 0, message);
    }
}

CommentManager::Comment CommentManager::parseCommentObject(const QJsonObject &obj)
{
    Comment comment;
    comment.rpid = obj["rpid"].toVariant().toLongLong();
    comment.oid = obj["oid"].toVariant().toLongLong();
    comment.type = obj["type"].toInt();
    comment.mid = obj["mid"].toVariant().toLongLong();
    comment.like = obj["like"].toInt();
    comment.count = obj["rcount"].toInt();
    comment.ctime = obj["ctime"].toVariant().toLongLong();
    comment.root = QString::number(obj["root"].toVariant().toLongLong());
    comment.parent = QString::number(obj["parent"].toVariant().toLongLong());
    // 置顶状态：优先通过 reply_control.is_top_admin 判断，兼容 up_action
    QJsonObject replyControl = obj["reply_control"].toObject();
    comment.isTop = (replyControl.value("is_top_admin").toInt() == 1) ||
                    (replyControl.value("is_up_top").toInt() == 1) ||
                    ((obj["up_action"].toInt() & 1) != 0);
    comment.timeDesc = replyControl.value("time_desc").toString();
    // 参照 biliuwp-lite：IP 属地优先取 reply_control.location
    comment.ipLocation = replyControl.value("location").toString();
    if (comment.ipLocation.isEmpty()) {
        comment.ipLocation = replyControl.value("ip_location").toString();
    }
    // 部分接口直接把 ip_location 放在顶层
    if (comment.ipLocation.isEmpty()) {
        comment.ipLocation = obj["ip_location"].toString();
    }
    // 去掉 B 站返回的 “IP属地：” 前缀，只保留地名
    if (comment.ipLocation.startsWith("IP属地：")) {
        comment.ipLocation = comment.ipLocation.mid(5);
    } else if (comment.ipLocation.startsWith("IP属地:")) {
        comment.ipLocation = comment.ipLocation.mid(5);
    }
    comment.ipLocation = comment.ipLocation.trimmed();
    comment.action = obj["action"].toInt();

    QJsonObject member = obj["member"].toObject();
    comment.uname = member["uname"].toString();
    comment.face = member["avatar"].toString();
    if (comment.face.isEmpty()) {
        comment.face = member["face"].toString();
    }
    comment.level = member["level_info"].toObject()["current_level"].toInt();
    QJsonObject vip = member["vip"].toObject();
    comment.isVip = (vip["vipStatus"].toInt() == 1);
    comment.platinfo = vip["vipType"].toInt();

    // 解析个性装扮 - 评论卡片背景
    QJsonObject userSailing = member["user_sailing"].toObject();
    QJsonObject cardbg = userSailing["cardbg"].toObject();
    comment.userSailing.cardbg.image = cardbg["image"].toString();
    QJsonObject cardbgFan = cardbg["fan"].toObject();
    comment.userSailing.cardbg.fanNumDesc = cardbgFan["num_desc"].toString();
    comment.userSailing.cardbg.fanColor = cardbgFan["color"].toString();
    comment.userSailing.cardbg.show = !comment.userSailing.cardbg.fanNumDesc.isEmpty();

    // 解析头像框
    QJsonObject pendant = member["pendant"].toObject();
    comment.pendantImage = pendant["image"].toString();

    // 解析认证信息 official_verify.type（0=个人, 1=机构, -1/缺失=无）
    QJsonObject officialVerify = member["official_verify"].toObject();
    comment.verifyType = officialVerify["type"].toInt(-1);

    QJsonObject content = obj["content"].toObject();
    comment.content = content["message"].toString();

    // 解析评论图片 content.pictures
    if (content.contains("pictures")) {
        QJsonValue picsVal = content["pictures"];
        qDebug() << "[CommentManager] content has pictures field, type:" << picsVal.type()
                 << "size:" << (picsVal.isArray() ? picsVal.toArray().size() : 0)
                 << "message preview:" << comment.content.left(30);
        if (picsVal.isArray()) {
            QJsonArray picsArr = picsVal.toArray();
            for (const QJsonValue &picVal : picsArr) {
                if (!picVal.isObject()) continue;
                QJsonObject picObj = picVal.toObject();
                PictureInfo pic;
                pic.imgSrc = picObj["img_src"].toString();
                pic.width = picObj["img_width"].toDouble();
                pic.height = picObj["img_height"].toDouble();
                if (pic.width == 0 && picObj.contains("width")) {
                    pic.width = picObj["width"].toDouble();
                }
                if (pic.height == 0 && picObj.contains("height")) {
                    pic.height = picObj["height"].toDouble();
                }
                // 判断是否为动图：URL 以 .gif/.webp（不区分大小写）结尾
                QString lower = pic.imgSrc.toLower();
                pic.isAnimated = lower.endsWith(".gif") || lower.endsWith(".webp");
                if (!pic.imgSrc.isEmpty()) {
                    comment.pictures.append(pic);
                }
            }
        }
    }

    // 解析评论中的跳转链接 content.jump_url（用于购物链接、活动页等）
    if (content.contains("jump_url")) {
        QJsonValue jumpVal = content["jump_url"];
        if (jumpVal.isObject()) {
            QJsonObject jumpObj = jumpVal.toObject();
            for (auto it = jumpObj.begin(); it != jumpObj.end(); ++it) {
                QJsonObject detail = it.value().toObject();
                QString title = detail["title"].toString();
                QString key = it.key();
                // 没有 title 时回退到原文本
                comment.jumpUrls[key] = title.isEmpty() ? key : title;
            }
        }
    }

    // 解析正文 @提及用户 content.members（仅@面板插入的真提及，
    // 手打 @ 服务端不登记）
    if (content.contains("members")) {
        QJsonValue membersVal = content["members"];
        if (membersVal.isArray()) {
            for (const QJsonValue &mv : membersVal.toArray()) {
                QString uname = mv.toObject()["uname"].toString();
                if (!uname.isEmpty()) {
                    comment.atNames.append(uname);
                }
            }
        }
    }

    // 解析表情 content.emote（一个字典，key是表情文本如 "[微笑]")
    if (content.contains("emote")) {
        QJsonValue emoteVal = content["emote"];
        if (emoteVal.isObject()) {
            QJsonObject emoteObj = emoteVal.toObject();
            for (auto it = emoteObj.begin(); it != emoteObj.end(); ++it) {
                QString emoteText = it.key();
                QJsonObject emoteDetail = it.value().toObject();
                EmoteInfo info;
                info.text = emoteText;
                info.url = emoteDetail["url"].toString();
                info.type = emoteDetail["type"].toInt();
                if (emoteDetail.contains("meta")) {
                    QJsonObject meta = emoteDetail["meta"].toObject();
                    int sizeFlag = meta["size"].toInt();
                    // 参照 biliuwp-lite：size=1 对应 20px，size=2 对应 36px
                    int px = (sizeFlag == 1) ? 20 : (sizeFlag == 2) ? 36 : 24;
                    info.width = px;
                    info.height = px;
                } else {
                    info.width = 24;
                    info.height = 24;
                }
                if (!info.url.isEmpty()) {
                    comment.emotes.insert(info.text, info);
                }
            }
        }
    }

    return comment;
}

QVariantMap CommentManager::commentToMap(const Comment &comment) const
{
    QVariantMap map;
    map["rpid"] = QString::number(comment.rpid);
    map["oid"] = QString::number(comment.oid);
    map["type"] = comment.type;
    map["mid"] = QString::number(comment.mid);
    map["uname"] = comment.uname;
    map["face"] = comment.face;
    map["level"] = comment.level;
    map["isVip"] = comment.isVip;
    map["platinfo"] = comment.platinfo;
    map["content"] = comment.content;
    map["ctime"] = static_cast<qlonglong>(comment.ctime);
    map["timeDesc"] = comment.timeDesc;
    map["like"] = comment.like;
    map["count"] = comment.count;
    map["root"] = comment.root;
    map["parent"] = comment.parent;
    map["isTop"] = comment.isTop;
    map["action"] = comment.action;
    map["ipLocation"] = comment.ipLocation;

    QVariantList picList;
    for (const PictureInfo &pic : comment.pictures) {
        QVariantMap picMap;
        picMap["imgSrc"] = pic.imgSrc;
        picMap["width"] = pic.width;
        picMap["height"] = pic.height;
        picMap["isAnimated"] = pic.isAnimated;
        picList.append(picMap);
    }
    map["pictures"] = picList;

    QVariantMap jumpUrlMap;
    for (auto it = comment.jumpUrls.begin(); it != comment.jumpUrls.end(); ++it) {
        jumpUrlMap[it.key()] = it.value();
    }
    map["jumpUrls"] = jumpUrlMap;

    map["atNames"] = comment.atNames;

    QVariantMap emoteMap;
    for (auto it = comment.emotes.begin(); it != comment.emotes.end(); ++it) {
        QVariantMap e;
        e["text"] = it.value().text;
        e["url"] = it.value().url;
        e["type"] = it.value().type;
        e["width"] = it.value().width;
        e["height"] = it.value().height;
        emoteMap[it.key()] = e;
    }
    map["emotes"] = emoteMap;

    // 个性装扮 - 评论卡片背景
    QVariantMap cardbgMap;
    cardbgMap["image"] = comment.userSailing.cardbg.image;
    cardbgMap["fanNumDesc"] = comment.userSailing.cardbg.fanNumDesc;
    cardbgMap["fanColor"] = comment.userSailing.cardbg.fanColor;
    cardbgMap["show"] = comment.userSailing.cardbg.show;
    map["cardbg"] = cardbgMap;

    // 头像框
    map["pendantImage"] = comment.pendantImage;

    // 认证类型
    map["verifyType"] = comment.verifyType;

    return map;
}

QString CommentManager::getCSRFToken()
{
    // 从登录管理器的 cookies 中解析 bili_jct
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
