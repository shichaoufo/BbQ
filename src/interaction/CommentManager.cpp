#include "CommentManager.h"
#include "LoginManager.h"
#include "WbiSigner.h"
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QUrlQuery>
#include <QUrl>
#include <QDebug>

// 服务端 JSON 的布尔字段类型并不稳定：同一个 key 实测既出现过 JSON bool
// （true / false），也出现过数字 0 / 1。
//
// **QJsonValue::toInt() 对 Bool 返回默认值 0** —— 而词搜索热词的
// extra.is_word_search 恰好下发的是 bool。旧实现用 toInt() == 1 判断，结果
// 恒为 false：唯一判据整条失效，54 条 jump_url 全部被当成"可点可染的链接"
// （正文里的普通词语也被染蓝、点一下还往外跳）。match_once / underline
// 同理，都得按类型兼容。
static bool jsonFlag(const QJsonObject &obj, const QString &key, bool defaultValue = false)
{
    if (!obj.contains(key)) return defaultValue;
    const QJsonValue v = obj.value(key);
    if (v.isBool()) return v.toBool();
    if (v.isDouble()) return v.toInt() != 0;
    if (v.isString()) {
        const QString s = v.toString().trimmed().toLower();
        if (s == "true" || s == "1") return true;
        if (s == "false" || s == "0" || s.isEmpty()) return false;
    }
    return defaultValue;
}


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

    // 预取缓存命中：同步回放，零网络延迟。
    // 游标恢复到"本页之后"，保证后续预取/网络请求的偏移链正确
    const QString cKey = commentCacheKey(oid, sort, ps, pn);
    auto it = m_commentPageCache.constFind(cKey);
    if (it != m_commentPageCache.constEnd() && it->valid) {
        const QString cursorKey = oid + "_" + QString::number(sort);
        if (!it->nextCursor.isEmpty())
            m_commentCursor[cursorKey] = it->nextCursor;
        qDebug() << "[CommentManager] getComments cache hit, page:" << pn << "count:" << it->comments.size();
        emit commentsReady(it->comments, pn, it->total, sort, it->hasNextPage, oid);
        return;
    }
    requestComments(oid, type, pn, ps, sort, false);
}

void CommentManager::prefetchComments(const QString &oid, int type, int pn, int ps, int sort)
{
    // 缓存命中（如显示与预取并发请求了同一页）：无需网络，直接回告结果
    const QString cKey = commentCacheKey(oid, sort, ps, pn);
    auto it = m_commentPageCache.constFind(cKey);
    if (it != m_commentPageCache.constEnd() && it->valid) {
        emit prefetchReady(oid, sort, pn, !it->comments.isEmpty());
        return;
    }
    requestComments(oid, type, pn, ps, sort, true);
}

void CommentManager::requestComments(const QString &oid, int type, int pn, int ps, int sort, bool prefetch)
{
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
    ctx.isPrefetch = prefetch;
    ctx.page = pn;
    ctx.ps = ps;
    getOneShot(request, ctx);
}

QString CommentManager::commentCacheKey(const QString &oid, int sort, int ps, int pn)
{
    return QString("%1_%2_%3_%4").arg(oid).arg(sort).arg(ps).arg(pn);
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
        parseCommentsData(data, ctx);
    } else if (ctx.action == "get_sub_comments") {
        parseSubCommentsData(data, ctx.pendingRootRpid);
    } else {
        parseActionData(data, ctx.action, ctx.pendingRootRpid);
    }

    reply->deleteLater();
}

void CommentManager::parseCommentsData(const QByteArray &data, const ReplyContext &ctx)
{
    QList<Comment> commentList;
    const QString &oid = ctx.oid;
    const int sort = ctx.sort;
    const int page = ctx.page;

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

    int total = pageObj["count"].toInt();
    int allCount = cursorObj["all_count"].toInt();

    // 乱序/过期响应防御：响应必须按页序到达才接受。
    // 典型场景：预取第 N+1 页在途中用户点了"首页"（游标已重置回链头），
    // 旧预取响应随后才返回——若照常写游标会把偏移链拉回旧位置，
    // 后续"下一页"会取到错误的页
    const QString cursorKey = oid + "_" + QString::number(sort);
    const int lastPage = m_commentLastPage.value(cursorKey, 0);
    bool accept = ctx.isPrefetch
                      ? (page == lastPage + 1)
                      : (page == 1 || page == lastPage || page == lastPage + 1);
    // 显示响应额外允许 ==lastPage：预取与显示并发请求同一页时（用户在
    // 预取返回前点了"下一页"），两个响应先后到达均有效
    if (!accept) {
        qDebug() << "[CommentManager] stale comment response dropped:"
                 << "page" << page << "lastPage" << lastPage
                 << "prefetch" << ctx.isPrefetch;
        return;
    }
    m_commentLastPage[cursorKey] = page;

    // 第 1 页显示请求 = 新会话：清空该 oid_sort 的页缓存，
    // 避免重开视频/切回排序后回放陈旧页
    if (!ctx.isPrefetch && page == 1) {
        const QString prefix = cursorKey + "_";
        for (auto cit = m_commentPageCache.begin(); cit != m_commentPageCache.end();) {
            if (cit.key().startsWith(prefix))
                cit = m_commentPageCache.erase(cit);
            else
                ++cit;
        }
    }

    // 解析 WBI 主接口翻标（pagination_reply.next_offset）
    QJsonObject paginationReply = cursorObj["pagination_reply"].toObject();
    QString nextOffset = paginationReply["next_offset"].toString();
    if (nextOffset.isEmpty()) {
        nextOffset = cursorObj["next_offset"].toString();
    }
    if (!nextOffset.isEmpty()) {
        m_commentCursor[cursorKey] = nextOffset;
    }

    // 权威的"还有下一页"判断：cursor.is_end 与 next_offset。
    // 服务端热度排序下每页返回数量不固定（实测同一视频第1页21条、
    // 第2页19条），按数量判断会提前终止翻页导致评论读不全。
    // 注：尾页边界处 is_end 仍不精确——最后一个有内容的页可能仍报
    // "有下一页"，由 QML 侧的空尾页回退 + 预取机制兜底
    bool isEnd = cursorObj["is_end"].toBool();
    bool hasNextPage = !isEnd && !nextOffset.isEmpty();
    // 空页防御：API 说有下一页但本页一条都没有时按末页处理，避免死循环翻页
    if (hasNextPage && dataObj["replies"].toArray().isEmpty() && !dataObj.contains("top_replies")) {
        hasNextPage = false;
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

    // WBI 接口 page.count 为 0。评论总数直接用 cursor.all_count（主+子，
    // 与官方"XXXX 条评论"显示口径一致）。不要按当前页主/子比例估算——
    // 置顶热评带几千条子回复时估算值严重失真（实测 6003 条被估成 83 条）
    if (total <= 0 && allCount > 0) {
        total = allCount;
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
    // 页缓存：预取产物供"下一页"命中即时回放；显示响应同样入缓存
    //（预取与显示并发取同页的重复响应场景）。第 1 页不入缓存——
    // 每次进入都要最新数据，且上面新会话时已清空
    if (page > 1) {
        CommentPageCache entry;
        entry.comments = result;
        entry.total = total;
        entry.hasNextPage = hasNextPage;
        entry.nextCursor = m_commentCursor.value(cursorKey);
        entry.valid = true;
        m_commentPageCache[commentCacheKey(oid, sort, ctx.ps, page)] = entry;
    }

    qDebug() << "[CommentManager] parseCommentsData done, count:" << result.size() << "page:" << page << "total:" << total
             << "nextOffset:" << nextOffset << "hasNextPage:" << hasNextPage << "prefetch:" << ctx.isPrefetch << "ipEmptyCount:" << ipEmptyCount;
    if (ctx.isPrefetch) {
        // 预取结果不触发 commentsReady（不干扰当前显示页），只回告有无内容
        emit prefetchReady(oid, sort, page, !result.isEmpty());
    } else {
        emit commentsReady(result, page, total, sort, hasNextPage, oid);
    }
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

    // 解析评论中的跳转链接 content.jump_url
    // 实测该表里混着三类条目，必须靠 extra.is_word_search 区分：
    //   1) 词搜索热词（正文里的普通词语被登记成可跳转项）— 默认不染
    //   2) 商品/活动链接 — 可染可点
    //   3) 视频链接（key 可能直接是裸 BV 号，如 "BV1do5ezGEkR"）
    // 旧实现只取 title，判据全丢 → 一律染蓝，这是误染的主因
    if (content.contains("jump_url")) {
        QJsonValue jumpVal = content["jump_url"];
        if (jumpVal.isObject()) {
            QJsonObject jumpObj = jumpVal.toObject();
            for (auto it = jumpObj.begin(); it != jumpObj.end(); ++it) {
                const QString key = it.key();
                QJsonObject detail = it.value().toObject();
                QJsonObject extra = detail.value("extra").toObject();

                JumpUrlInfo info;
                info.key = key;
                info.title = detail.value("title").toString();
                if (info.title.isEmpty()) info.title = key;
                info.prefixIcon = detail.value("prefix_icon").toString();
                info.icon = detail.value("icon").toString();
                info.pcUrl = detail.value("pc_url").toString();
                info.appUrlSchema = detail.value("app_url_schema").toString();
                info.underline = jsonFlag(detail, "underline");
                // 缺省按 true 处理：同一 token 在正文里只渲一次可点链接
                //（与 PiliPlus 的 matchedUrls 注释"只显示一次"一致）；
                // 只有服务端明确下发 false 时才允许逐次渲染。
                info.matchOnce = jsonFlag(detail, "match_once", true);
                // 判据可能出现在 detail 顶层，也可能在 extra 里（两种都实测到过）
                info.isWordSearch = jsonFlag(extra, "is_word_search",
                                             jsonFlag(detail, "is_word_search", false));
                comment.jumpUrlInfos.insert(key, info);
                // 兼容旧字段（不含判据），旧调用点可继续工作
                comment.jumpUrls[key] = info.title;
            }
        }
    }

    // 解析正文话题标签 content.topic（服务端登记过的 #话题#）
    if (content.contains("topic")) {
        QJsonValue topicVal = content["topic"];
        if (topicVal.isObject()) {
            QJsonObject topicObj = topicVal.toObject();
            for (auto it = topicObj.begin(); it != topicObj.end(); ++it) {
                if (!it.key().isEmpty()) {
                    comment.topics.append(it.key());
                }
            }
        }
    }

    // 解析正文 @提及用户 content.members（仅@面板插入的真提及，
    // 手打 @ 服务端不登记）。mid 必须一起取——旧实现只取 uname，
    // 导致 @ 只能染蓝、点不动
    if (content.contains("members")) {
        QJsonValue membersVal = content["members"];
        if (membersVal.isArray()) {
            for (const QJsonValue &mv : membersVal.toArray()) {
                QJsonObject mObj = mv.toObject();
                QString uname = mObj["uname"].toString();
                if (uname.isEmpty()) continue;
                comment.atNames.append(uname);
                qint64 midVal = mObj["mid"].toVariant().toLongLong();
                QString mid = (midVal > 0) ? QString::number(midVal) : mObj["mid_str"].toString();
                if (!mid.isEmpty() && mid != "0") {
                    comment.atNameToMid.insert(uname, mid);
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
                // 动态表情：服务端额外下发 gif_url（实测为真 GIF，非 APNG/动图 WebP）。
                // 旧实现只读 url → 动态表情退化成静态 PNG。
                // 注意：这里只记录，是否用动图渲染由 UI 决定（Qt 富文本 <img>
                // 即便喂 gif 也只画第一帧，白白多下载几倍体积）
                info.gifUrl = emoteDetail["gif_url"].toString();
                info.isAnimated = !info.gifUrl.isEmpty();
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

    // 完整跳转信息（含判据字段）。QML 侧优先用它，jumpUrls 仅作旧数据兼容
    QVariantMap jumpUrlInfoMap;
    for (auto it = comment.jumpUrlInfos.begin(); it != comment.jumpUrlInfos.end(); ++it) {
        const JumpUrlInfo &j = it.value();
        QVariantMap jm;
        jm["key"] = j.key;
        jm["title"] = j.title;
        jm["prefixIcon"] = j.prefixIcon;
        jm["appUrlSchema"] = j.appUrlSchema;
        jm["pcUrl"] = j.pcUrl;
        jm["icon"] = j.icon;
        jm["underline"] = j.underline;
        jm["matchOnce"] = j.matchOnce;
        jm["isWordSearch"] = j.isWordSearch;
        jumpUrlInfoMap[it.key()] = jm;
    }
    map["jumpUrlInfos"] = jumpUrlInfoMap;
    // ListModel 存嵌套 map 时角色会失效（QML 侧 m.jumpUrlInfos[key] 取不到值），
    // 与既有 atNamesJson 同理：序列化成 JSON 字符串往返，QML 侧 JSON.parse
    map["jumpUrlInfosJson"] = QString::fromUtf8(
        QJsonDocument(QJsonObject::fromVariantMap(jumpUrlInfoMap)).toJson(QJsonDocument::Compact));

    map["atNames"] = comment.atNames;

    QVariantMap atMidMap;
    for (auto it = comment.atNameToMid.begin(); it != comment.atNameToMid.end(); ++it) {
        atMidMap[it.key()] = it.value();
    }
    map["atNameToMid"] = atMidMap;
    map["atNameToMidJson"] = QString::fromUtf8(
        QJsonDocument(QJsonObject::fromVariantMap(atMidMap)).toJson(QJsonDocument::Compact));

    map["topics"] = comment.topics;

    QVariantMap emoteMap;
    for (auto it = comment.emotes.begin(); it != comment.emotes.end(); ++it) {
        QVariantMap e;
        e["text"] = it.value().text;
        e["url"] = it.value().url;
        e["gifUrl"] = it.value().gifUrl;
        e["isAnimated"] = it.value().isAnimated;
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
