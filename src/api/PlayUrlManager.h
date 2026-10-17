#ifndef PLAYURLMANAGER_H
#define PLAYURLMANAGER_H

#include <QObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QString>
#include <QList>
#include <QMap>
#include <QVariantMap>
#include <QVariantList>

class PlayUrlManager : public QObject
{
    Q_OBJECT
public:
    explicit PlayUrlManager(QObject *parent = nullptr);
    ~PlayUrlManager();

    QString getQualityName(int qualityId);
    QString getQualityDescription(int qn);

    struct QualityInfo {
        int qualityId;
        QString qualityName;
        QString codec;
    };

    struct PlayUrlInfo {
        QString videoUrl;
        QString audioUrl;
        QString flvUrl;     // 合并音视频URL（durl格式），兼容性更好
        QList<QString> videoBackupUrls;  // 视频备选URL列表（用于CDN切换）
        QList<QString> audioBackupUrls;  // 音频备选URL列表
        QList<QString> flvBackupUrls;    // FLV备选URL列表
        int qualityId;
        QString qualityName;
        QString codec;
        QString mimeType;
        int duration;
        QString segmentBaseInitialization;
        QString segmentBaseIndexRange;
    };

    struct VideoUrlResult {
        QString flvUrl;
        QList<PlayUrlInfo> dashVideoUrls;
        QList<PlayUrlInfo> dashAudioUrls;
        int requestedQuality = 0;     // 用户请求的视频清晰度（0表示自动）
        int requestedAudioQuality = 0; // 用户请求的音频质量（0表示自动/最高码率）
    };

    // 直播清晰度信息
    struct LiveQualityInfo {
        int qn;               // 清晰度ID
        QString desc;         // 清晰度描述
        
        LiveQualityInfo() : qn(0) {}
        LiveQualityInfo(int q, const QString &d) : qn(q), desc(d) {}
        LiveQualityInfo(int q, const QString &d, const QString &) : qn(q), desc(d) {}
        LiveQualityInfo(const char*, int q, const char* d) : qn(q), desc(QString::fromUtf8(d)) {}
    };

    // 直播URL信息
    struct LiveUrlInfo {
        QString liveUrl;       // 直播流URL
        QString codecName;     // 编码名称
        int qualityId;        // 清晰度ID
        QString qualityDesc;   // 清晰度描述
        QList<LiveQualityInfo> qualityList;  // 所有可用清晰度
    };

    struct LiveRoomInfo {
        int roomId;
        int uid;
        QString title;
        QString uname;
        QString cover;
        QString areaName;
        int liveStatus;       // 1=直播中, 0=未开播
        int online;           // 在线观看人数
        QList<LiveUrlInfo> urls;  // 可用流列表
    };

    // 直播弹幕信息（包含WebSocket连接信息）
    struct LiveDanmakuInfo {
        QString host;         // WebSocket服务器地址
        int wsPort;          // WebSocket端口
        QString token;        // 弹幕认证token
    };

    // 获取直播弹幕WebSocket连接信息
    Q_INVOKABLE void getLiveDanmakuInfo(const QString &roomId);

    // 获取视频播放URL
    Q_INVOKABLE void getPlayUrl(const QString &aid, const QString &cid, int quality = 0);

    // 复位网络连接（关闭视频时由 QML 调用）：清空 HTTP 连接池，
    // 下次打开视频走全新连接，等价重启客户端的连接层效果，规避 480P 降级
    Q_INVOKABLE void resetConnectionState();

    // 通过aid获取视频播放URL（简化接口）
    Q_INVOKABLE void getVideoUrlByAid(const QString &aid, const QString &overrideCid = QString());

    // 通过bvid获取视频播放URL（简化接口）
    Q_INVOKABLE void getVideoUrlByBvid(const QString &bvid, const QString &overrideCid = QString(), bool skipPlayUrl = false);

    // 获取视频当前在线观看人数
    Q_INVOKABLE void getVideoOnlineCount(const QString &aid, const QString &cid, const QString &bvid);

    // 获取当前登录用户对视频的互动关系（web archive/relation 接口，用于补充 web view 接口未返回 req_user 的情况）
    Q_INVOKABLE void getArchiveRelation(const QString &aid, const QString &bvid);

    // 获取弹幕URL
    Q_INVOKABLE QUrl getDanmakuUrl(const QString &cid);

    // 获取支持的清晰度列表
    QList<QualityInfo> getQualityList() const { return m_qualityList; }

    // 获取直播房间信息
    Q_INVOKABLE void getLiveRoomInfo(const QString &roomId);

    // 获取直播URL
    Q_INVOKABLE void getLivePlayUrl(const QString &roomId, int quality = 0);

    // 通过uid获取用户信息（UP主名字等）
    Q_INVOKABLE void getUserInfoByUid(int uid);

    // 详细视频信息结构体（包含UP主、播放量等）
    struct VideoDetail {
        QString aid;
        QString bvid;
        QString cid;
        QString title;
        QString ownerName;
        QString ownerFace;       // 头像URL
        QString ownerPendant;    // 头像框图片URL
        qlonglong ownerMid;      // UP主mid
        int ownerVerify = -1;    // 认证类型（-1=无, 0=个人, 1=机构）
        qlonglong view;          // 播放量
        qlonglong danmaku;       // 弹幕数
        qlonglong reply;         // 评论数
        qlonglong favorite;      // 收藏数
        qlonglong coin;          // 硬币数
        qlonglong like;          // 点赞数
        qlonglong share;         // 分享数
        qlonglong pubdate;       // 发布时间戳
        QString pic;             // 视频封面URL
        QString description;     // 视频简介

        // req_user 字段（仅登录态下 web view 接口返回）
        // 表示当前登录用户对该视频的互动状态
        bool reqLike = false;       // 是否已点赞
        bool reqDislike = false;    // 是否已点踩
        bool reqCoin = false;       // 是否已投币
        bool reqFavorite = false;   // 是否已收藏
        int reqAttention = 0;       // 是否已关注 UP 主（2=已关注, 6=互相关注, 0=未关注）
        bool hasReqUser = false;    // 接口是否返回了 req_user 字段

        // 历史播放进度（登录态下 /x/web-interface/view 返回）
        int lastPlayTime = 0;       // 上次播放位置，单位：毫秒
        QString lastPlayCid;        // 上次播放的分P cid
        int progress = 0;           // 当前分P的播放进度，单位：秒（部分接口返回）
        
        // 合集/分集信息（ugc_season）
        bool hasUgcSeason = false;  // 是否有合集
        QString seasonTitle;        // 合集标题
        QString seasonCover;        // 合集封面
        int seasonCurrentIndex = -1; // 当前视频在合集中的索引
        QList<QVariantMap> episodes; // 所有分集列表（扁平化）
        
        // 分P信息（pages）
        bool hasPages = false;      // 是否有多个分P
        int pageCurrentIndex = -1;  // 当前分P索引
        QList<QVariantMap> pages;   // 分P列表

        // 分段章节（view_points，UP主设置的视频分段）
        // 每项: { title: 标题, from: 起始秒, to: 结束秒 }
        QList<QVariantMap> viewPoints;

        // 番剧信息（PGC）
        bool isBangumi = false;     // 是否为番剧
        QString seasonId;           // 番剧 season_id (ssid)
        QString epId;               // 番剧 ep_id (epid)
        int seasonType = 0;         // 番剧类型（1=番剧，2=电影等）
        QString bangumiTitle;       // 番剧标题
        QString bangumiCover;       // 番剧封面
        int bangumiTotalCount = 0;  // 番剧总集数
        QString bangumiIndexFormat; // 番剧序号格式
    };
    
    // 分集信息（用于 QML 传递）
    struct EpisodeInfo {
        QString aid;
        QString bvid;
        QString cid;
        QString title;
        int index;         // 在合集中的序号
        int duration;      // 时长（秒）
        QString part;       // 分P标题
        int sectionId;     // 所属 section ID
        QString sectionTitle; // 所属 section 标题
    };
    
    // 分P信息（用于 QML 传递）
    struct PageInfo {
        QString cid;
        int page;           // 分P序号
        QString part;       // 分P标题
        int duration;       // 时长（秒）
    };
    
    // 番剧分集信息
    struct BangumiEpisodeInfo {
        QString epId;        // 番剧 ep_id
        QString cid;         // cid
        QString title;       // 标题
        QString indexTitle;  // 集数标题（如 "第1集"）
        int duration;        // 时长（秒）
        QString cover;       // 封面
        bool isReleased;     // 是否已上线
        QString bvid;        // 对应的 bvid（如果有）
        QString aid;         // 对应的 aid（如果有）
    };

    // 视频卡片信息（用于相关视频和UP主投稿列表）
    struct VideoCardInfo {
        QString aid;
        QString bvid;
        QString title;
        QString pic;             // 封面URL
        QString author;          // 作者名
        qlonglong mid;           // 作者mid
        qlonglong play;          // 播放量
        qlonglong danmaku;       // 弹幕量
        qlonglong like;          // 点赞数
        qlonglong duration;      // 时长（秒）
        qlonglong pubdate;       // 发布时间戳
        QString badgeText;       // 特性标签（如"1万点赞""已关注"）
        QString epId;            // 番剧ep_id（用于番剧推荐跳转）
        QString seasonId;        // 番剧season_id（用于番剧推荐跳转）
        QString cid;             // 番剧cid（用于番剧播放）

        // ====== 番剧推荐卡片专用字段 ======
        bool isBangumiCard = false; // 是否为番剧推荐卡片
        double score = 0;           // 评分（如9.6，<=0 表示暂无评分）
        qlonglong follow = 0;       // 追番数
        QString seasonTitle;        // 番剧标题（备用，目前title就是）
        QString updateInfo;         // 更新进度描述（如"更新至第12话"、"全12话"）
    };

signals:
    // 播放URL获取成功（QML 友好的 QVariantMap）
    void playUrlLoaded(const QVariantMap &result);

    // 播放URL获取成功（QML 友好的 QVariantMap）
    void playUrlReady(const QVariantMap &info);

    // 获取失败（仅用于播放相关错误）
    void errorOccurred(const QString &error);

    // 清晰度列表已更新
    void qualityListReady(const QVariantList &list);

    // 视频信息已获取（包含cid，可用于加载弹幕等）
    void videoInfoReady(const QString &aid, const QString &bvid, const QString &cid, const QString &title);

    // 详细视频信息已获取
    void videoDetailReady(const QVariantMap &detail);

    // 可用字幕轨列表，每项 {lang, title, url, isAi}。
    // **已与 view 接口的权威列表 join 过**：只包含 id 能在 view
    // subtitle.list 里找到、且 player 接口提供了 URL 的轨道。
    // 空列表表示该视频没有（可用的）字幕，QML 据此隐藏字幕按钮。
    //
    // 为什么单独一个信号而不并进 playerDetailReady：后者在
    // last_play_time==0 的降级链里会**延迟甚至不发射**（先重试 legacy /
    // history/cursor），字幕却不需要那些重试，并进去会被进度降级逻辑拖住
    void subtitleListReady(const QVariantList &subtitles);

    // 视频当前在线观看人数已获取（已格式化的展示文本）。
    // 接口返回的 total 是带单位的字符串（千级 "999+"、万级 "2.4万+"、
    // 亿级 "1.2亿"），故此处文本已含单位，如 "2.4万+人正在看"
    void videoOnlineCountReady(const QString &text);

    // 当前用户对视频的互动关系（点赞/投币/收藏/点踩）已获取
    void archiveRelationReady(const QVariantMap &relation);

    // 相关视频列表已获取
    void relatedVideosReady(const QVariantList &videos);

    // UP主投稿列表已获取
    void userUploadedVideosReady(const QVariantList &videos, int currentPage, int totalPages);

    // 直播房间信息已获取
    void liveRoomInfoReady(const LiveRoomInfo &info);

    // 直播UP主名字已获取（用于更新界面显示）
    void liveUnameReady(const QString &uname);

    // UP 主身份信息已获取（vipType: 0=无, 1=月度/季度大会员, 2=年度大会员；
    // faceNft: 是否数字藏品(NFT)头像用户，头像钻石角标；
    // verifyType: 认证类型 -1=无, 0=个人认证, 1=机构认证。
    // 认证必须走 card 接口：view 接口的 owner 实测只有 mid/name/face，
    // 不下发 official_verify）
    void upVipReady(int vipType, bool faceNft, int verifyType);

    // UP 主头像框图片已获取
    void upPendantReady(const QString &pendantImage);

    // 视频分P详情已获取（含历史播放进度）
    void playerDetailReady(const QVariantMap &detail);

    // 视频分P列表已获取（/x/player/pagelist 接口返回）
    void videoPageListReady(const QVariantList &pages, const QString &currentCid, int currentIndex);

    // 直播弹幕信息已获取
    void liveDanmakuInfoReady(const LiveDanmakuInfo &info);

    // 直播URL已获取
    void livePlayUrlReady(const LiveUrlInfo &info);

    // 番剧详情已获取
    void seasonDetailReady(const QVariantMap &detail);

    // 番剧选集列表已获取
    void seasonEpisodesReady(const QVariantList &episodes, const QString &currentCid, int currentIndex);

public:
    // 获取相关视频
    Q_INVOKABLE void getRelatedVideos(const QString &aid);

    // 获取番剧推荐（通过 season_id）
    Q_INVOKABLE void getBangumiRecommendations(const QString &seasonId);

    // 获取UP主投稿列表
    Q_INVOKABLE void getUserUploadedVideos(const QString &mid, int pn = 1, int ps = 20);

    // 获取视频分P详情（含历史播放进度与分段章节）
    Q_INVOKABLE void getPlayerDetail(const QString &aid, const QString &cid, const QString &bvid);

    // 获取视频分P列表（/x/player/pagelist 接口，作为主接口的补充）
    Q_INVOKABLE void getVideoPageList(const QString &aid, const QString &bvid, const QString &currentCid = QString());

    // 降级方案：通过 /x/v2/history/list 获取观看进度
    // viewPoints：可选，游客重试成功后已解析的章节数据，降级 emit 时原样带回，
    // 避免二次 playerDetailReady 把 QML 侧章节覆盖成空列表
    void getHistoryProgress(const QString &aid, const QString &cid,
                            const QVariantList &viewPoints = QVariantList());

    // history/cursor 分页抓取（getHistoryProgress 内部用）：
    // 目标视频可能不在最近一页（ps=30），最多翻 maxPages 页
    void fetchHistoryCursorPage(const QString &aid, const QString &cid,
                                const QVariantList &viewPoints, qint64 max, qint64 viewAt, int page);

    // getPlayerDetail 内部实现；asGuest=true 时不带登录 Cookie（412 风控重试用，
    // view_points 章节数据游客身份也返回，仅放弃 last_play_time 历史进度）。
    // useLegacyEndpoint=true 时改走老 /x/player/v2（无需 WBI 签名，浏览器风格
    // 头+登录 Cookie）：wbi/v2 被 412 风控时的备选路径，同样返回 last_play_time。
    // fallbackViewPoints：调用链上游（游客 wbi/v2）已解析的章节，响应缺
    // view_points 字段时沿用，避免降级 emit 把 QML 侧章节覆盖为空
    void getPlayerDetailImpl(const QString &aid, const QString &cid, const QString &bvid, bool asGuest,
                             bool useLegacyEndpoint = false,
                             const QVariantList &fallbackViewPoints = QVariantList());

    // 只用 legacy /x/player/v2 补取字幕列表（wbi/v2 端点对已登录用户
    // 也可能返回空 subtitles）。不影响主链路，失败只是不发信号
    void requestSubtitleListViaLegacy(const QString &aid, const QString &cid, const QString &bvid);

    // 获取番剧详情（通过 season_id 或 ep_id）
    Q_INVOKABLE void getSeasonDetail(const QString &id, const QString &type = "season");

    // 获取番剧选集列表
    Q_INVOKABLE void getSeasonEpisodes(const QString &seasonId, const QString &currentCid = QString());

    // 获取番剧播放URL（使用 biliuwp-lite 方式）
    // cid: 视频CID
    // quality: 请求的清晰度（qn参数）
    // epId: 番剧EP ID（可选）
    // seasonType: 番剧类型（可选）
    // forceMaxQuality: true 时忽略 quality 参数，用 qn=120 请求（PGC Only-FLV 下只有 qn=120 语义是"给最高可用档"，
    //                  指定 quality=80/64 等 exact 值会触发"匹配不到就降级到 480P"逻辑）。
    //                  初始加载 / 切集 / 回退重试 → true；用户显式点击清晰度下拉 → false。
    Q_INVOKABLE void getSeasonPlayUrl(const QString &cid, int quality = 80,
                                      const QString &epId = QString(), int seasonType = 0,
                                      const QString &bvid = QString(), const QString &aid = QString(),
                                      bool forceMaxQuality = false,
                                      const QString &seasonId = QString());

    // 从缓存中切换清晰度（使用已获取的完整流列表）
    Q_INVOKABLE void switchQualityFromCache(int quality);

    // 清理缓存和状态（在切换视频前调用）
    Q_INVOKABLE void clearCache();

    // 通过 ep_id 获取番剧视频（简化接口）
    Q_INVOKABLE void getBangumiByEpId(const QString &epId);
    // 通过 season_id 获取番剧详情（推荐页只有 seasonId 没有 epId 时使用）
    Q_INVOKABLE void getBangumiBySeasonId(const QString &seasonId);

private slots:
    void onPlayUrlReplyFinished();

private:
    // 把接口返回的在线人数文本补上"人正在看"后缀。
    // 上游（B 站）返回的已是格式化好的展示文本（千级 "999+"、万级 "2.4万+"），
    // 故此处刻意**不解析数值**——QString::toInt 遇"万"会静默返回已解析的
    // 前缀（"2.4万" → 2），曾导致万级视频显示成"2+人正在看"。
    static QString formatOnlineCount(const QString &raw);

    QString getSign(const QString &params);
    QString generateTimestamp();
    QString getAppKey();
    QString getAppSecret();
    QString generateRandomHex(int length);  // 生成随机十六进制字符串（用于伪造 buvid3）
    void parsePlayUrlData(const QByteArray &data, int quality, const QString &cid = QString());
    void parseQualityList(const QJsonObject &data);
    void parseLiveRoomInfo(const QByteArray &data);
    void parseLivePlayUrl(const QByteArray &data, int quality, const QString &roomId = QString(), int requestId = 0);
    void getLivePlayUrlLegacy(const QString &roomId, int quality, int requestId);

    // 番剧播放 URL 四策略支持（引入 Web PGC V2 + from_client=BILIBILI：Web SESSDATA 用户正确的鉴权路径）：
    //   策略 A(WebVideoKey signed V1) 失败 → fallback 策略 B(wiliwili SeasonUrl2 V2 PC_APP)
    //   策略 B 返回只有 ≤480P（mid=0，PC_APP不认WebCookie）→ fallback 策略 D(PGC-Web V2 + from_client=BILIBILI + WBI + 番剧Referer)
    //   策略 D 仍 ≤480P 且有 aid/bvid → fallback 策略 C(浏览器 WBI /x/player/wbi/playurl)
    void requestSeasonPlayUrlStrategyA(const QString &cid, int clientQuality, const QString &epId,
                                       int seasonType, const QString &seasonId,
                                       const QString &bvid, const QString &aid,
                                       const QString &cookies, const QString &buvid3Header,
                                       const QString &accessKey, int userMid);
    void requestSeasonPlayUrlStrategyB(const QString &cid, int clientQuality, const QString &epId,
                                       const QString &seasonId,
                                       const QString &bvid, const QString &aid,
                                       const QString &cookies, const QString &buvid3Header,
                                       const QString &accessKey, int userMid, int seasonType = 0);
    void requestSeasonPlayUrlStrategyC(const QString &cid, int clientQuality,
                                       const QString &bvid, const QString &aid,
                                       const QByteArray &fallbackResponse = QByteArray());
    void requestSeasonPlayUrlStrategyD(const QString &cid, int clientQuality,
                                       const QString &epId, int seasonType, const QString &seasonId,
                                       const QString &bvid, const QString &aid,
                                       const QByteArray &fallbackResponse);
    void handleSeasonPlayUrlResponse(QNetworkReply *reply, int clientQuality, const QString &cid,
                                     const QString &logTag, bool isStrategyA, bool isStrategyD,
                                     const QString &epId, int seasonType, const QString &seasonId,
                                     const QString &bvid, const QString &aid,
                                     const QString &cookies, const QString &buvid3Header,
                                     const QString &accessKey, int userMid);

    // 获取 UP 主大会员状态（通过 /x/web-interface/card 接口）
    void fetchUpVipInfo(qlonglong mid);
    
    // 解析 ugc_season 数据（合集/分集信息）
    void parseUgcSeason(const QJsonObject &dataObj, VideoDetail &detail);
    
    // 解析 pages 数据（分P信息）
    void parsePages(const QJsonObject &dataObj, VideoDetail &detail);
    void parseViewPoints(const QJsonObject &dataObj, VideoDetail &detail);

    // 从 view 接口响应缓存当前视频的字幕权威列表（data.subtitle.list[]）。
    // 供字幕轨过滤使用：player 接口在风控/无字幕视频上会返回毫不相干的
    // 占位字幕，靠这份列表识别并丢弃。view 未返回 subtitle 字段时
    // m_videoSubtitleChecked=false，不过滤
    void parseVideoSubtitleIds(const QJsonObject &dataObj);

    // 字幕轨为空但有权威列表时的重试调度（见 m_subtitleRetryBvid 注释）。
    // 按视频独立计数，指数退避，最多 m_subtitleMaxRetry 次
    void scheduleSubtitleRetry(const QString &aid, const QString &cid, const QString &bvid);
    
    // 解析番剧详情数据
    void parseSeasonDetail(const QJsonObject &dataObj, VideoDetail &detail, const QString &requestedEpId = QString());
    
    // 解析番剧选集数据
    QVariantList parseSeasonEpisodes(const QJsonArray &episodesArray, const QString &currentCid, int &currentIndex);

    QVariantMap videoDetailToMap(const VideoDetail &detail) const;
    QVariantMap videoCardToMap(const VideoCardInfo &video) const;
    QVariantMap playUrlInfoToMap(const PlayUrlInfo &info) const;
    QVariantMap videoUrlResultToMap(const VideoUrlResult &result) const;
    QVariantMap qualityInfoToMap(const QualityInfo &info) const;

    QNetworkAccessManager *m_networkManager;
    // 注意：player/wbi/v2（章节/历史进度）与 legacy /x/player/v2、history/cursor
    // 降级链路不再使用共享 QNAM——共享池 + clearConnectionCache 无法保证新连接
    // （连接在 reply finished 后异步归还缓存，紧接的下一次请求可能复用被服务端
    // 标记的连接，被静默按游客处理）。这些请求改用一次性 QNAM（每次请求新建，
    // 用完销毁），见 getPlayerDetailImpl / fetchHistoryCursorPage。
    // m_networkManager 仅供 playurl 等共享路径使用，维持 480P 隔离
    // 当前视频的字幕权威列表（来自 view 接口 data.subtitle.list[]），
    // 每项 {id, lang, title, isAi}，**不含 URL**。
    //
    // 为什么需要（2026-10-14 实测结论）：
    //   - view 接口（签名/非签名、游客/登录）的 subtitle.list 稳定反映
    //     "这个视频有没有字幕"，但 **subtitle_url 恒为空串**
    //   - player 接口（/x/player/v2、/x/player/wbi/v2）的 subtitle.subtitles
    //     带 URL，但在视频无字幕时会返回**毫不相干的 AI 占位字幕**
    //     （实测：给"一加6评测"返回"大佬K·世田谷灭门案"的AI字幕，
    //     lan=ai-zh、ai_status=2、URL 在 bfs/ai_subtitle/prod/ 下）
    //   - 所以：view 出列表（权威），player 只按 id 匹配补 URL；
    //     player 返回的 id 不在 view 列表里 → 一律丢弃
    //   - view list 为空 = 该视频无字幕，player 返回的任何字幕都是脏数据
    //
    // m_videoSubtitleChecked 记录 view 是否已确认过该视频（请求失败/未调用
    // 时为 false，不过滤——避免误杀）。m_videoSubtitleBvid 防止切视频后
    // 旧列表误用（请求异步到达，顺序不保证）
    QVariantList m_videoSubtitleList;
    bool m_videoSubtitleChecked = false;
    QString m_videoSubtitleBvid;

    // 字幕 URL 的补齐重试状态。
    //
    // 为什么需要：player 接口在风控灰度下**不报错也不返回空**，而是只返回
    // 毫不相干的 AI 占位轨、不返回真正的 CC 轨——于是"view 说有字幕、
    // player 却没给 URL"，过滤后列表为空，用户看到字幕按钮消失。实测同一
    // 视频反复打开时好时坏（第一次正确、第二次只有占位轨）。请求本身是
    // 幂等的，所以按视频重试直到拿到正确轨（上限 m_subtitleMaxRetry 次）
    QString m_subtitleRetryAid;
    QString m_subtitleRetryCid;
    QString m_subtitleRetryBvid;
    int m_subtitleRetryAttempt = 0;
    // 上次调度时间戳：同一次打开会从主链路与 fallback 各触发一次，用它去重
    qint64 m_subtitleRetryLastMs = 0;
    // 本视频是否已成功拿到字幕轨。拿到后即使后续降级响应返回空也不再重试
    bool m_subtitleResolved = false;
    static constexpr int m_subtitleMaxRetry = 5;
    QList<QualityInfo> m_qualityList;
    QMap<QString, QString> m_playUrls;
    QMap<QString, QString> m_userUploadCursorMap;  // mid -> lastAid，APP 投稿游标分页
    int m_currentRequestId = 0;  // 用于追踪最新的请求，忽略旧请求的响应
    int m_liveRequestId = 0;     // 直播请求ID
    QString m_requestedEpId;     // 当前请求的番剧 ep_id
    
    // 用于旧版API回退时保存新API的结果
    LiveUrlInfo m_newApiResult;
    QString m_roomIdForFallback;
    int m_requestIdForFallback = 0;

    // 缓存机制：保存首次请求后的完整流列表，用于清晰度切换
    VideoUrlResult m_cachedVideoUrlResult;  // 缓存的完整结果（包含所有可用流）
    bool m_hasCachedResult = false;  // 是否有缓存
    QString m_cachedCid;  // 缓存对应的 CID

    // 高画质获取标志：一旦某个 CID 成功获取了高画质（通常为 qn=120）的流，
    // 后续对同一 CID 的请求将直接使用缓存，不再发起新的 API 调用，
    // 从而避免 B 站因重复请求导致会话降级（只能返回 480P 及以下）。
    bool m_highQualityFetched = false;
    QString m_highQualityFetchedCid;

    // 请求去重：防止同一 CID 并发发起多个 API 请求
    QString m_inFlightCid;  // 当前正在请求的 CID
    bool m_inFlightRequest = false;  // 是否有正在进行的请求
    int m_inFlightRequestQuality = 0;  // 当前请求的质量参数
    
    // getSeasonEpisodes 去重：避免同一 seasonId 连续发多次请求（造成选集Loader反复闪）
    QNetworkReply *m_pendingSeasonEpisodesReply = nullptr;
    QString m_pendingSeasonEpisodesSeasonId;

    // 重试机制：当 API 返回的流不完整时，用更高的质量重新请求
    QString m_lastRequestAid;  // 上次请求的 aid
    int m_retryCount = 0;  // 当前 CID 的重试次数
    QString m_retryCid;  // 当前重试的 CID

    static const QString APP_KEY;
    static const QString APP_SECRET;
    static const QString USER_AGENT;
    static const QString REFERER;
    static const QString ORIGIN;

    // APP 接口专用 key（参考 biliuwp-lite）
    static const QString APP_ANDROID_KEY;
    static const QString APP_ANDROID_SECRET;

    // 计算 APP 接口签名
    static QString calculateAppSign(const QString &params, const QString &secret);
    static QString generateFakeBuvid3();

    // CDN 相关方法
    struct CDNServer {
        QString host;
        QString name;
    };
    
    // 官方 CDN 节点列表（bilivideo.com 域名）
    static const QList<CDNServer> OFFICIAL_CDN_SERVERS;
    
    // 检查 URL 是否为官方 CDN（非 PCDN）
    static bool isOfficialCDN(const QString &url);
    
    // 检查 URL 是否为 PCDN 节点
    static bool isPCDN(const QString &url);
    
    // 从备选 URL 列表中获取第一个官方 CDN URL
    static QString getOfficialCDNFromBackups(const QString &baseUrl, const QList<QString> &backupUrls);
    
    // 处理 URL：优先官方 CDN，支持 CDN 替换
    QString handleUrl(const QString &baseUrl, const QList<QString> &backupUrls, 
                      bool isProxy = false);
    
    // 设置 CDN 替换模式
    Q_INVOKABLE void setCDNReplaceMode(int mode);
    int cdnReplaceMode() const { return m_cdnReplaceMode; }
    
    // 设置替换的 CDN 服务器
    Q_INVOKABLE void setCDNServer(const QString &server);
    QString cdnServer() const { return m_cdnServer; }
    
    // 刷新 CDN 设置（从 AppSettings 重新加载）
    Q_INVOKABLE void refreshCDNSettings();
    
    // 获取可用的 CDN 服务器列表
    Q_INVOKABLE QVariantList getAvailableCDNServers() const;
    
    // CDN 替换模式：0=不替换, 1=全部替换, 2=仅替换PCDN, 3=仅替换代理
    int m_cdnReplaceMode = 0;
    QString m_cdnServer = "upos-sz-mirrorhwo1.bilivideo.com";  // 默认华为云
};

#endif // PLAYURLMANAGER_H
