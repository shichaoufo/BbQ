#ifndef COMMENTMANAGER_H
#define COMMENTMANAGER_H

#include <QObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QHash>
#include <QString>
#include <QList>
#include <QJsonObject>
#include <QJsonArray>
#include <QMap>
#include <QVariantMap>
#include <QVariantList>
#include <cstdint>

class CommentManager : public QObject
{
    Q_OBJECT

public:
    // 排序方式
    enum SortType {
        SortHot = 2,       // 按热度
        SortTimeAsc = 0,   // 按时间正序（旧到新）
        SortTimeDesc = 1   // 按时间倒序（新到旧）
    };

    struct EmoteInfo {
        QString text;        // 表情文本如 "[微笑]"
        QString url;         // 表情图片URL
        int type;            // 表情类型
        int width;           // 图片宽度
        int height;          // 图片高度
    };

    struct PictureInfo {
        QString imgSrc;      // 图片URL
        qreal width;         // 图片宽度
        qreal height;        // 图片高度
        bool isAnimated = false; // 是否为动图（gif/webp）
    };

    // 个性装扮 - 评论卡片背景
    struct UserSailingCardbg {
        QString image;       // 背景图片 URL
        QString fanNumDesc;  // 粉丝编号描述，如 "1234"
        QString fanColor;    // 粉丝编号颜色（十六进制字符串）
        bool show = false;   // 是否展示（依据 num_desc 是否非空）
    };

    struct UserSailing {
        UserSailingCardbg cardbg;
    };

    struct Comment {
        qint64 rpid;        // 评论ID（64位，避免溢出）
        qint64 oid;         // 视频aid
        int type;           // 类型
        qint64 mid;         // 用户mid
        QString uname;     // 用户名
        QString face;      // 头像URL
        int level;         // 用户等级（0-6）
        bool isVip;        // 是否大会员
        int platinfo;      // 大会员状态（0=非, 1=普通, 2=年度）
        QString content;   // 评论内容
        int64_t ctime;     // 发布时间（时间戳）
        QString timeDesc;  // 发布时间描述（来自 reply_control.time_desc）
        int like;          // 点赞数
        int count;         // 回复数
        QString root;      // 根评论ID（""=0）
        QString parent;    // 上一级评论ID
        bool isTop;        // 是否置顶
        int action;        // 点赞状态（0=未操作, 1=已点赞）
        QString ipLocation; // IP 属地（来自 reply_control.location）
        // 评论图片列表
        QList<PictureInfo> pictures;
        // 表情字典：表情文本 -> 表情信息
        QMap<QString, EmoteInfo> emotes;
        // 评论中的跳转链接：原文本 -> 显示标题（用于购物链接等）
        QMap<QString, QString> jumpUrls;
        // 正文 @提及的用户名列表（来自 content.members，仅@面板插入的
        // 真提及有数据；手打 @ 不在此列）
        QStringList atNames;
        // 个性装扮 - 评论卡片背景
        UserSailing userSailing;
        // 头像框
        QString pendantImage;
        // 认证类型（-1=无, 0=个人认证, 1=机构认证）
        int verifyType = -1;
    };

    explicit CommentManager(QObject *parent = nullptr);
    ~CommentManager();

    // 获取评论列表（sort=2按热度，sort=0按时间正序，sort=1按时间倒序）
    Q_INVOKABLE void getComments(const QString &oid, int type = 1, int pn = 1, int ps = 20, int sort = 2);

    // 预取下一页评论：显示第 N 页时后台先取第 N+1 页——
    // 1) 服务端 is_end/next_offset 在尾页边界不精确（最后一个有内容的页仍
    //    报"有下一页"），预取能在用户无感知时探明真实尾页并提前禁用"下一页"
    // 2) 预取结果入缓存，"下一页"命中时同步回放，零网络延迟
    // 结果只通过 prefetchReady 通知（携带 oid 归属），不发 commentsReady
    Q_INVOKABLE void prefetchComments(const QString &oid, int type = 1, int pn = 2, int ps = 20, int sort = 2);

    // 获取子评论（回复）
    Q_INVOKABLE void getSubComments(const QString &oid, const QString &root, int pn = 1, int ps = 10, int type = 1);

    // 发送评论（root和parent为空表示顶级评论，否则为回复）
    Q_INVOKABLE void sendComment(const QString &oid, const QString &content, int type = 1,
                     const QString &root = "", const QString &parent = "");

    // 删除评论
    Q_INVOKABLE void deleteComment(const QString &rpid, qint64 oid, int type = 1);

    // 点赞/取消点赞（action=1点赞, 0=取消点赞）
    Q_INVOKABLE void likeComment(const QString &rpid, qint64 oid, int type = 1, int action = 1);

    // 点踩/取消点踩（action=1点踩, 0=取消点踩）
    Q_INVOKABLE void hateComment(const QString &rpid, qint64 oid, int type = 1, int action = 1);

signals:
    // 评论列表获取成功（QML 友好的 QVariantList）
    // hasNextPage：来自 API cursor.is_end / next_offset 的权威判断。
    // 不能用 comments.length >= 20 判断——热度排序下服务端每页返回数量
    // 不固定（19/20/21 都有），数量判断会提前终止翻页导致评论读不全
    // oid：评论归属。视频播放页与动态详情页两处 Connections 监听同一信号，
    // 需用它过滤各自的响应，防止互相覆盖对方的评论模型
    void commentsReady(const QVariantList &comments, int page, int total, int sort, bool hasNextPage, const QString &oid);

    // 预取页就绪。hasContent=false 表示预取页为空 → 显示中的当前页即真实
    // 尾页（提前禁用"下一页"，无需用户点一次空页才发现）
    void prefetchReady(const QString &oid, int sort, int page, bool hasContent);

    // 子评论获取成功
    void subCommentsReady(qint64 rootRpid, const QVariantList &comments);

    // 评论发送成功（保留旧信号兼容）
    void commentSent(bool success, const QString &message);

    // 评论发送成功，附带服务端返回的评论数据
    void commentPosted(bool success, const QString &message, const QVariantMap &comment, const QString &root, const QString &parent);

    // 评论操作成功（点赞/点踩/删除等）
    void actionSuccess(const QString &action, qint64 rpid, bool success, const QString &message);

    // 错误
    void errorOccurred(const QString &error);

private:
    // 每个网络请求对应的上下文，避免并发请求时 m_currentAction 被覆盖。
    // 注意：须声明在 private slots 之前——parseCommentsData 槽签名用到它
    struct ReplyContext {
        QString action;
        int type = 1;
        int sort = 2;
        QString oid;
        qint64 pendingRootRpid = 0;
        bool isPrefetch = false; // 预取请求：只入缓存/发 prefetchReady，不发 commentsReady
        int page = 0;            // 请求页码（WBI 接口响应无 page.num，需请求侧自带）
        int ps = 20;             // 页大小（缓存键组成部分）
    };

private slots:
    void onReplyFinished();
    void parseCommentsData(const QByteArray &data, const ReplyContext &ctx);
    void parseSubCommentsData(const QByteArray &data, qint64 rootRpid);
    void parseActionData(const QByteArray &data, const QString &action, qint64 rpid);

private:
    Comment parseCommentObject(const QJsonObject &obj);
    QVariantMap commentToMap(const Comment &comment) const;
    QString getCSRFToken();

    // 一次性 QNAM 请求：每次请求新建网络管理器，用完即毁。
    // 不复用共享池连接——池内连接一旦被 B 站风控标记，
    // 复用它的请求会失败且重试仍落在同一条坏连接上，直到重启客户端。
    // 这些请求均为低频用户触发，每次多一次 TLS 握手无感知
    QNetworkReply *postOneShot(const QNetworkRequest &request, const QByteArray &data, const ReplyContext &ctx);
    QNetworkReply *getOneShot(const QNetworkRequest &request, const ReplyContext &ctx);

    // 主评论网络请求公共路径（getComments/prefetchComments 共用，仅 ctx.isPrefetch 不同）
    void requestComments(const QString &oid, int type, int pn, int ps, int sort, bool prefetch);
    static QString commentCacheKey(const QString &oid, int sort, int ps, int pn);

    QHash<QNetworkReply*, ReplyContext> m_replyContextMap;

    // WBI 主接口翻页游标：key = oid_sort
    QMap<QString, QString> m_commentCursor;

    // 主评论分页缓存（预取产物）：key = commentCacheKey()。
    // "下一页"命中时同步回放，零网络延迟；第 1 页显示请求（新会话）时清空
    struct CommentPageCache {
        QVariantList comments;
        int total = 0;
        bool hasNextPage = false;
        QString nextCursor;   // 本页解析后的游标；回放时恢复，保证偏移链正确
        bool valid = false;
    };
    QHash<QString, CommentPageCache> m_commentPageCache;

    // oid_sort 已接受解析的最后一页页码：丢弃乱序/过期响应
    //（如"首页"重置游标后姗姗来迟的旧预取响应，防止写坏游标链）
    QHash<QString, int> m_commentLastPage;

    static const QString USER_AGENT;
    static const QString REFERER;
};

#endif // COMMENTMANAGER_H
