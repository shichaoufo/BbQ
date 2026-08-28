#ifndef APIMANAGER_H
#define APIMANAGER_H

#include <QObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QString>
#include <QUrl>

class ApiManager : public QObject
{
    Q_OBJECT
public:
    explicit ApiManager(QObject *parent = nullptr);

    Q_INVOKABLE void getRecommendVideos(const QString &idx = "0", bool pull = true);
    Q_INVOKABLE void searchVideos(const QString &keyword, int page = 1, const QString &order = "", const QString &duration = "", int region = 0);
    // 番剧/影视搜索（search_type=media_bangumi / media_ft），返回结构与 video 不同
    Q_INVOKABLE void searchBangumi(const QString &keyword, int page = 1, bool isMovie = false);
    // 直播搜索（search_type=live_room）
    Q_INVOKABLE void searchLive(const QString &keyword, int page = 1);
    // 用户搜索（search_type=bili_user）
    // orderType: 0=默认排序, 1=粉丝数由高到低, 2=粉丝数由低到高, 3=LV等级由高到低, 4=LV等级由低到高
    // userType: 0=全部用户, 1=UP主, 2=普通用户, 3=认证用户
    Q_INVOKABLE void searchUser(const QString &keyword, int page = 1, int orderType = 0, int userType = 0);
    Q_INVOKABLE void getSearchSuggest(const QString &keyword);
    void getVideoDetailByBvid(const QString &bvid);
    void getVideoDetailByAid(const QString &aid);
    Q_INVOKABLE void getUserUploadedVideos(const QString &mid, int pn = 1, int ps = 20);
    void getRelatedVideos(const QString &aid);

    // 获取用户历史记录（需要登录）
    Q_INVOKABLE void getHistoryList(int max = 0, int viewAt = 0, const QString &business = "", int ps = 20);

    // 获取动态视频（需要登录）
    Q_INVOKABLE void getDynamicVideos(const QString &offset = "", int ps = 20, uint64_t hostMid = 0);

    // 获取关注 UP 主列表（需要登录）
    Q_INVOKABLE void getDynamicUpList();

    // 获取完整关注列表（/x/relation/followings，支持分页，用于动态页左侧关注列表）
    // 内部自动从 LoginManager 获取当前用户 mid
    Q_INVOKABLE void getFollowings(int pn = 1, int ps = 50);

    // 获取综合动态列表（需要登录）
    Q_INVOKABLE void getDynamicArticleList(const QString &offset = "", int ps = 20, uint64_t hostMid = 0);

    // 获取动态详情（需要登录）
    Q_INVOKABLE void getDynamicDetail(const QString &id);

signals:
    void recommendVideosReceived(const QByteArray &data);
    void wbiRecommendVideosReceived(const QByteArray &data);
    void dynamicVideosReceived(const QByteArray &data);
    void dynamicUpListReceived(const QByteArray &data);
    void followingsReceived(const QByteArray &data);
    void dynamicArticleListReceived(const QByteArray &data);
    void dynamicDetailReceived(const QByteArray &data);
    void searchResultsReceived(const QByteArray &data);
    void searchBangumiReceived(const QByteArray &data, bool isMovie);
    void searchLiveReceived(const QByteArray &data);
    void searchUserReceived(const QByteArray &data);
    void searchSuggestReceived(const QStringList &words);
    void videoDetailReceived(const QByteArray &data);
    void liveListReceived(const QByteArray &data);
    void liveAreaListReceived(const QByteArray &data);
    void subAreaLiveListReceived(const QByteArray &data);
    void followingLiveReceived(const QByteArray &data);
    void liveStreamInfoReceived(const QByteArray &data);
    void liveRoomInfoReceived(const QByteArray &data);
    void liveDanmuInfoReceived(const QByteArray &data);
    void liveDanmakuSendResult(const QByteArray &data);      // 发送弹幕（文字/表情）响应
    void liveEmoticonsReceived(const QByteArray &data);      // 表情包列表响应
    void videoDanmakuSendResult(const QByteArray &data);     // 视频弹幕发送响应
    void userUploadedVideosReceived(const QByteArray &data);
    void relatedVideosReceived(const QByteArray &data);
    void historyListReceived(const QByteArray &data);
    void hotsAllReceived(const QByteArray &data);
    void hotsRankReceived(const QByteArray &data);
    void hotsWeeklyListReceived(const QByteArray &data);
    void hotsWeeklyReceived(const QByteArray &data);
    void hotsHistoryReceived(const QByteArray &data);
    // 用户空间信号
    void userSpaceInfoReceived(const QByteArray &data);
    void userSpaceVideosReceived(const QByteArray &data);
    void userSpaceDynamicsReceived(const QByteArray &data);
    void errorOccurred(const QString &error);

public:
    Q_INVOKABLE void getLiveList();
    Q_INVOKABLE void getLiveAreaList();
    Q_INVOKABLE void getSubAreaLiveList(int parentAreaId, int areaId, int page);
    Q_INVOKABLE void getFollowingLive();
    Q_INVOKABLE void setLiveArea(int parentAreaId, int subAreaId);
    Q_INVOKABLE void setLivePage(int page);
    // 获取直播流地址（playurl）
    Q_INVOKABLE void getLiveStreamInfo(const QString &roomId, int qn = 10000, const QString &platform = "web");
    // 获取直播间信息（标题、主播、封面、人气等）
    Q_INVOKABLE void getLiveRoomInfo(const QString &roomId);
    // 获取弹幕 token + host（用于 WebSocket 连接直播弹幕服务器）
    Q_INVOKABLE void getLiveDanmuInfo(const QString &roomId);

    // 上报直播观看记录（进入直播间时调用）
    Q_INVOKABLE void reportLiveHistory(const QString &roomId);

    // ===== 直播间发送弹幕（Web 路线：cookie + csrf，经 /msg/send）=====
    // 发送文字弹幕
    Q_INVOKABLE void sendLiveDanmaku(const QString &roomId, const QString &text);
    // 发送大表情弹幕（msg=emoticon_unique + dm_type/extra）
    Q_INVOKABLE void sendLiveDanmakuEmoticon(const QString &roomId, const QString &emoticonUnique,
                                             const QString &emoticonText);
    // 获取直播间可用表情包列表（web-ucenter 接口，带 cookie）
    Q_INVOKABLE void getLiveEmoticons(const QString &roomId);

    // ===== 视频弹幕发送（Web 路线：cookie + csrf，经 /x/v2/dm/post）=====
    // colorDecimal: 十进制颜色值（如 16777215=白色）；progressMs: 当前播放进度（毫秒，弹幕落点）
    Q_INVOKABLE void sendVideoDanmaku(const QString &cid, const QString &bvid, const QString &text,
                                      int colorDecimal, int progressMs);

    // WBI签名推荐API（与wiliwili一致）
    Q_INVOKABLE void getWbiRecommendVideos(int page = 1, int pageSize = 30, int freshType = 0, int xNum = 3, int yNum = 4);

    // 主页热门 - 综合热门
    Q_INVOKABLE void getHotsAll(int pn = 1, int ps = 40);
    // 主页热门 - 排行榜（rid=0 全站，type=all/rookie/origin）
    Q_INVOKABLE void getHotsRank(int rid = 0, const QString &type = "all");
    // 主页热门 - 每周必看列表
    Q_INVOKABLE void getHotsWeeklyList();
    // 主页热门 - 每周必看某一期
    Q_INVOKABLE void getHotsWeekly(int number);
    // 主页热门 - 入站必刷
    Q_INVOKABLE void getHotsHistory();

    // ===== 用户空间 =====
    // 用户空间信息（头像、名称、签名、认证、粉丝数、关注数等）- WBI签名
    Q_INVOKABLE void getUserSpaceInfo(const QString &mid);
    // 用户投稿视频列表 - WBI签名
    // order: pubdate=最新发布, click=最多播放, stow=最多收藏
    Q_INVOKABLE void getUserSpaceVideos(const QString &mid, int pn = 1, int ps = 30, const QString &order = "pubdate");
    // 用户空间动态列表（与动态综合页相同的API，指定host_mid）
    Q_INVOKABLE void getUserSpaceDynamics(const QString &mid, const QString &offset = "", int ps = 20);

private slots:
    void onReplyFinished(QNetworkReply *reply);

private:
    QNetworkAccessManager *m_networkManager;
    QString m_apiBaseUrl;
    QString m_appKey;
    QString m_appSecret;
    
    // 直播分区状态
    int m_currentParentArea = 0;
    int m_currentSubArea = 0;
    int m_currentPage = 1;

    QString getSign(const QString &params);
    QString generateTimestamp();
    QString getMustParameters();
    QString getCSRFToken();
    void getRequest(const QString &url);

    // 直播弹幕发送：统一 POST 出口（带 cookie+csrf 的直播域请求）
    void sendLiveDanmakuPost(const QString &url, const QUrlQuery &query, const QString &roomId);

    // 浏览器指纹生成（未登录时模拟 web 端指纹，避免 v_voucher 风控）
    static QString genBrowserUuid();
    static QString genBrowserLsid();
};

#endif // APIMANAGER_H
