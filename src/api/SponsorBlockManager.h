#ifndef SPONSORBLOCKMANAGER_H
#define SPONSORBLOCKMANAGER_H

#include <QObject>
#include <QNetworkAccessManager>
#include <QString>
#include <QVariantList>

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
public:
    static SponsorBlockManager *instance();

    /// bsb.conf 有效且本会话未被自动禁用（QML 据此隐藏整套 UI）
    bool available() const;
    /// 用户开关（持久化 video/sponsor/enabled，默认开）；available=false 时无意义
    bool enabled() const;
    void setEnabled(bool v);

    /// 查询视频的标注片段。durationSec 用于校验片段是否过期（提交时长与
    /// 实际时长差 >2s 视为换源后过期，丢弃；任一方未知则跳过校验）。
    /// 结果经 segmentsReady 异步返回；404（无数据）返回空列表。
    /// 只保留 actionType=="skip" 的片段（mute/poi 等类型 MVP 不支持）。
    Q_INVOKABLE void getSegments(const QString &bvid, const QString &cid, double durationSec);

    /// 上报一次成功跳过（服务器统计用，fire-and-forget，失败忽略）
    Q_INVOKABLE void reportViewed(const QString &uuid);

signals:
    void availableChanged();
    void enabledChanged();
    /// 查询完成（含空结果）。segments 元素为 {start, end, category, uuid}（秒）
    void segmentsReady(const QString &bvid, const QString &cid, const QVariantList &segments);

private:
    explicit SponsorBlockManager(QObject *parent = nullptr);
    ~SponsorBlockManager() override = default;

    void loadConfig();          // 解析 bsb.conf（构造时调用一次）
    void noteResult(bool ok);   // 连续失败计数 → 会话级自动禁用

    static SponsorBlockManager *s_instance;
    QNetworkAccessManager m_nam;
    QString m_baseUrl;          // 空 = 功能不可用
    bool m_sessionDisabled = false;
    int m_consecutiveFailures = 0;
    int m_requestSeq = 0;       // 递增序号：过期响应丢弃（快速切集时）
};

#endif // SPONSORBLOCKMANAGER_H
