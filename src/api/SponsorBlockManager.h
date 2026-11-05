#ifndef SPONSORBLOCKMANAGER_H
#define SPONSORBLOCKMANAGER_H

#include <QObject>
#include <QNetworkAccessManager>
#include <QString>
#include <QStringList>
#include <QVariantList>
#include <QUrl>

/**
 * @brief 空降助手（BilibiliSponsorBlock）查询管理器
 *
 * 数据源为社区众包服务器（默认 https://bsbsb.top/api），返回视频中的
 * 恰饭/片头/片尾等标注片段，客户端据此自动跳过并在进度条上绘制色带。
 *
 * 服务器为个人维护、无可用性保证，因此整体按"可插拔"设计：
 *   - exe 同目录 bsb.conf 首个有效行 = 接口基地址（如 https://bsbsb.top/api）
 *   - 文件缺失/内容为空/非 http(s) → available=false，功能整体关闭，
 *     不发任何网络请求，QML 侧开关与色带随之隐藏
 *   - 运行中连续 5 次请求失败（网络错误/5xx）→ 本会话内自动禁用
 *     （下次启动重新尝试），期间零请求
 *
 * 所有失败路径静默降级，绝不影响播放主流程。
 */
class SponsorBlockManager : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool available READ available NOTIFY availableChanged)
    Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY enabledChanged)
    // 提交进行中（QML 用它禁按钮；QML 自己的 _busy 只是为了让按钮立刻变字）
    Q_PROPERTY(bool submitting READ submitting NOTIFY submittingChanged)
    // 排行榜昵称（未设置时服务器返回 64 位公开 ID 哈希串）
    Q_PROPERTY(QString userName READ userName NOTIFY userNameChanged)
public:
    static SponsorBlockManager *instance();

    /// bsb.conf 有效且本会话未被自动禁用（QML 据此隐藏整套 UI）
    bool available() const;
    /// 用户开关（持久化 video/sponsor/enabled，默认开）；available=false 时无意义
    bool enabled() const;
    void setEnabled(bool v);

    bool submitting() const { return m_submitting; }
    QString userName() const { return m_userName; }

    /// 查询视频的标注片段。durationSec 用于校验片段是否过期（提交时长与
    /// 实际时长差 >2s 视为换源后过期，丢弃；任一方未知则跳过校验）。
    /// 结果经 segmentsReady 异步返回；404（无数据）返回空列表。
    /// 只保留 actionType=="skip" 的片段（mute/poi 等类型 MVP 不支持）。
    Q_INVOKABLE void getSegments(const QString &bvid, const QString &cid, double durationSec);

    /// 上报一次成功跳过（服务器统计用，fire-and-forget，失败忽略）
    Q_INVOKABLE void reportViewed(const QString &uuid);

    // ===== 提交片段（空降助手众包贡献）=====
    //
    // 只需用户选「分类 + 区间」，其余字段客户端自补：
    //   cid            —— 当前播放的 cid（不传服务端会按第一 P 记账，必须传）
    //   userID         —— 本地生成的私人 ID（≥30 字符），存 AppSettings 的
    //                     sponsor/userID；**它相当于密码**，服务器不保存明文，
    //                     丢失即永久无法找回；排行榜展示的是它的 SHA256×5000
    //   userAgent      —— "BbQ/<版本>"，纯记录用途，不参与鉴权
    //   videoDuration  —— mpv 的真实总时长（秒）；服务端据此判断是否换源，
    //                     时长变化会删除该视频此前所有片段，绝不能传 0
    //
    /// segments 元素：{ start:double(秒), end:double(秒),
    ///                  category:QString, actionType:QString }
    /// actionType 由 QML 用 defaultAction(category) 取；C++ 侧再做一次校验与
    /// 归一化（full → [0,duration]，poi → end=start）。
    /// 结果经 submitFinished 异步返回；失败不会计入「连续失败即禁用」的判定。
    Q_INVOKABLE void submitSegments(const QString &bvid, const QString &cid,
                                    double durationSec, const QVariantList &segments);

    /// 12 个分类 key（顺序即下拉顺序）
    Q_INVOKABLE QStringList categories() const;
    /// 某分类允许的 actionType（QML 据此决定时间框是否禁用）
    Q_INVOKABLE QStringList allowedActions(const QString &category) const;
    /// 某分类的默认 actionType（第一个允许项；多数是 skip）
    Q_INVOKABLE QString defaultAction(const QString &category) const;

    // ===== 排行榜昵称 =====
    // 排行榜/统计展示的是「公开 ID」（私人 ID 的 SHA256 迭代 5000 次），
    // 想要可读名字必须单独调 setUsername —— 其唯一凭证就是私人 ID，
    // 任何拿到它的人都能改名/以你的身份提交，所以它不能写死在客户端。
    /// 取一次当前昵称（每会话一次即可，内部去重；失败静默）
    Q_INVOKABLE void fetchUsername();
    /// 设置昵称（空串不发请求 = 保持默认哈希名）
    Q_INVOKABLE void setUsername(const QString &name);

signals:
    void availableChanged();
    void enabledChanged();
    void submittingChanged();
    void userNameChanged();
    /// 查询完成（含空结果）。segments 元素为 {start, end, category, uuid}（秒）
    void segmentsReady(const QString &bvid, const QString &cid, const QVariantList &segments);
    /// ok=true 时 segments 为服务器已受理的片段（含 uuid，actionType 由请求侧回填）
    /// ok=false 时 httpStatus 为 HTTP 码（0 = 本地校验失败或网络错误）
    void submitFinished(bool ok, int httpStatus, const QString &message,
                        const QVariantList &segments);
    /// 设置昵称的结果（ok=false 时 message 为中文原因）
    void usernameResult(bool ok, const QString &message);

private:
    explicit SponsorBlockManager(QObject *parent = nullptr);
    ~SponsorBlockManager() override = default;

    void loadConfig();          // 解析 bsb.conf（构造时调用一次）
    void noteResult(bool ok);   // 连续失败计数 → 会话级自动禁用
    QString ensureUserID();     // 懒生成 + 持久化私人 ID（不进 QML）
    // 设完昵称后读回来核对。服务端有几种"回 200 但根本不保存"的分支
    // （用户名被锁定、身份被封禁、该身份还没有任何提交记录、命中请求校验
    // 规则等），不核对的话客户端会骗用户"已更新"
    void verifyUsernameSaved(const QString &expected);
    // 发出提交请求；attempt=0 首次，网络层失败后自动以 attempt=1 重试一次
    // （服务端按 videoID+userID+片段去重，重试只会得到 409，不会重复入库）
    void sendSubmitRequest(const QUrl &url, const QByteArray &payload,
                           const QVariantList &normalized, int attempt);
    void emitSubmitFailure(int httpStatus, const QString &message);
    static QString httpStatusMessage(int st);

    static SponsorBlockManager *s_instance;
    QNetworkAccessManager m_nam;
    QString m_baseUrl;          // 空 = 功能不可用
    bool m_sessionDisabled = false;
    int m_consecutiveFailures = 0;
    int m_requestSeq = 0;       // 递增序号：过期响应丢弃（快速切集时）

    bool m_submitting = false;
    QString m_userID;           // 私人 ID（进程内缓存）
    QString m_userName;         // 排行榜昵称（服务器返回，可能等于公开 ID）
    bool m_userNameFetched = false;
};

#endif // SPONSORBLOCKMANAGER_H
