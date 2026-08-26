#ifndef DANMAKUMANAGER_H
#define DANMAKUMANAGER_H

#include <QObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QString>
#include <QList>
#include <QByteArray>
#include <QColor>

class DanmakuManager : public QObject
{
    Q_OBJECT

public:
    explicit DanmakuManager(QObject *parent = nullptr);
    ~DanmakuManager();

    // 弹幕数据模型
    struct DanmakuItem {
        int id;              // 弹幕ID
        QString text;        // 弹幕文本
        int64_t timestamp;   // 出现时间（毫秒）
        int type;            // 类型：1=滚动，5=顶部，4=底部
        QColor color;        // 颜色
        QString author;      // 发送者
        int weight;          // 权重
    };

    // 获取弹幕列表
    void getDanmakuList(const QString &cid);
    
    // 发送弹幕
    void sendDanmaku(const QString &aid, const QString &cid, 
                     const QString &text, int position = 0,
                     const QColor &color = Qt::white);
    
    // 点赞弹幕
    void likeDanmaku(const QString &dmid, const QString &oid, bool like = true);
    
    // 过滤弹幕
    QList<DanmakuItem> filterDanmaku(const QList<DanmakuItem> &list, 
                                     const QString &keyword);
    
    // 生成 ASS 字幕文件
    static QString generateASS(const QList<DanmakuItem> &list, int videoWidth = 852, int videoHeight = 480);

signals:
    // 弹幕列表获取成功
    void danmakuListReady(const QList<DanmakuItem> &list);
    
    // 弹幕发送成功
    void danmakuSent(bool success, const QString &message);
    
    // 弹幕点赞结果
    void danmakuLikeResult(bool success);
    
    // 获取失败
    void errorOccurred(const QString &error);

private slots:
    void onDanmakuReplyFinished();
    void parseDanmakuData(const QByteArray &data);

private:
    QList<DanmakuItem> parseXMLData(const QByteArray &data);
    QString getCSRFToken();
    QString generateTimestamp();

    QNetworkAccessManager *m_networkManager;
    QList<DanmakuItem> m_danmakuList;
    
    static const QString USER_AGENT;
    static const QString REFERER;
};

#endif // DANMAKUMANAGER_H
