#ifndef INTERACTIONMANAGER_H
#define INTERACTIONMANAGER_H

#include <QObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QHash>
#include <QString>
#include <QJsonObject>

class InteractionManager : public QObject
{
    Q_OBJECT

public:
    explicit InteractionManager(QObject *parent = nullptr);
    ~InteractionManager();

    // 点赞视频（like=1 点赞, like=2 取消, like=3 点踩）
    Q_INVOKABLE void likeVideo(const QString &aid, int like = 1);

    // 取消点赞
    Q_INVOKABLE void unlikeVideo(const QString &aid);

    // 点踩/取消点踩（targetDislike 为期望达到的点踩状态：1=点踩, 0=取消；currentLike 为当前点赞状态）
    Q_INVOKABLE void dislikeVideo(const QString &aid, int targetDislike, int currentLike);

    // 收藏视频
    Q_INVOKABLE void favoriteVideo(const QString &aid, const QString &fid, int addMedia = 1);

    // 取消收藏
    Q_INVOKABLE void unfavoriteVideo(const QString &aid, const QString &fid);

    // 投币
    Q_INVOKABLE void coinVideo(const QString &aid, const QString &bvid, int num = 1, int selectLike = 0);

    // 三连（点赞+收藏+投币）
    Q_INVOKABLE void tripleAction(const QString &aid, const QString &bvid, bool like = true, bool favorite = true, bool coin = true);

    // 关注用户（act=1 关注, act=2 取消关注）
    Q_INVOKABLE void followUser(const QString &mid, int act = 1);

    // 获取视频状态（是否已点赞、收藏、投币）
    Q_INVOKABLE void getVideoStatus(const QString &aid);

    // 获取 UP 主关注状态
    Q_INVOKABLE void getUserRelation(const QString &mid);

    // 获取 UP 主粉丝数
    Q_INVOKABLE void getUserFollowers(const QString &mid);

    // 获取默认收藏夹（用于一键收藏）
    Q_INVOKABLE void getDefaultFavoriteFolder(const QString &aid);

    // 上报视频观看历史（普通视频，type=3）
    Q_INVOKABLE void reportHistory(const QString &aid, const QString &cid, int progress);
    Q_INVOKABLE void reportHistory(const QString &aid, const QString &cid, int progress, int duration);
    
    // 上报番剧观看历史（type=4，需要 epid 和 sid）
    Q_INVOKABLE void reportBangumiHistory(const QString &aid, const QString &cid, int progress, int duration, const QString &epid, const QString &sid);

signals:
    // 操作成功
    void actionSuccess(const QString &action, const QString &message);

    // 操作失败
    void actionFailed(const QString &action, const QString &error);

    // 视频状态获取成功（是否已点赞、已收藏、投币数）
    void statusReady(bool liked, bool favorited, int coined);

    // UP 主关注状态获取成功（attribute: 0=未关注, 1=悄悄关注, 2=已关注）
    void relationReady(bool followed, int attribute);

    // UP 主粉丝数获取成功
    void userFollowersReady(int count);

    // 默认收藏夹获取成功
    void defaultFavoriteFolderReady(const QString &fid, const QString &name);

    // 错误
    void errorOccurred(const QString &error);

private slots:
    void onReplyFinished();
    void parseStatusData(const QByteArray &data);
    void parseRelationData(const QByteArray &data);

private:
    QString getSign(const QString &params);
    QString getCSRFToken();
    void setupRequest(QNetworkRequest &request);
    void checkAllStatusReady();
    void coinVideoWeb(const QString &aid, const QString &bvid, int num, int selectLike);

    // 一次性 QNAM 请求：每次请求新建网络管理器，用完即毁。
    // 不复用共享池连接——池内连接一旦被 B 站风控标记（历史上报曾发生），
    // 复用它的请求会失败且重试仍落在同一条坏连接上，直到重启客户端。
    // 这些请求均为低频用户触发，每次多一次 TLS 握手无感知
    QNetworkReply *postOneShot(const QNetworkRequest &request, const QByteArray &data, const QString &action);
    QNetworkReply *getOneShot(const QNetworkRequest &request, const QString &action);

    // 每个网络请求对应的 action，避免并发请求时 m_currentAction 被覆盖
    QHash<QNetworkReply*, QString> m_replyActionMap;

    // 视频状态并行查询
    bool m_statusLikeReceived = false;
    bool m_statusCoinReceived = false;
    bool m_statusFavReceived = false;
    bool m_statusLiked = false;
    int m_statusCoined = 0;
    bool m_statusFavorited = false;
    
    static const QString USER_AGENT;
    static const QString REFERER;
    static const QString ORIGIN;
    static const QString ANDROID_USER_AGENT;
    static const QString APP_KEY;
    static const QString APP_SECRET;
};

#endif // INTERACTIONMANAGER_H
