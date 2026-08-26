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
    void commentsReady(const QVariantList &comments, int page, int total, int sort);

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

private slots:
    void onReplyFinished();
    void parseCommentsData(const QByteArray &data, int sort, const QString &oid);
    void parseSubCommentsData(const QByteArray &data, qint64 rootRpid);
    void parseActionData(const QByteArray &data, const QString &action, qint64 rpid);

private:
    Comment parseCommentObject(const QJsonObject &obj);
    QVariantMap commentToMap(const Comment &comment) const;
    QString getCSRFToken();

    QNetworkAccessManager *m_networkManager;

    // 每个网络请求对应的上下文，避免并发请求时 m_currentAction 被覆盖
    struct ReplyContext {
        QString action;
        int type = 1;
        int sort = 2;
        QString oid;
        qint64 pendingRootRpid = 0;
    };
    QHash<QNetworkReply*, ReplyContext> m_replyContextMap;

    // WBI 主接口翻页游标：key = oid_sort
    QMap<QString, QString> m_commentCursor;

    static const QString USER_AGENT;
    static const QString REFERER;
};

#endif // COMMENTMANAGER_H
