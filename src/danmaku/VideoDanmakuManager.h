#ifndef VIDEODANMAKUMANAGER_H
#define VIDEODANMAKUMANAGER_H

#include <QObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QString>
#include <QList>
#include <QByteArray>
#include <QColor>
#include <QVariantList>
#include <QSslConfiguration>

class VideoDanmakuManager : public QObject
{
    Q_OBJECT

public:
    explicit VideoDanmakuManager(QObject *parent = nullptr);
    ~VideoDanmakuManager();

    struct DanmakuItem {
        QString text;
        qint64 timestamp;
        int type;
        QColor color;
        QString author;
        int fontSize;
    };

    Q_INVOKABLE void getDanmakuList(const QString &cid);
    Q_INVOKABLE void clearDanmaku();

signals:
    // 使用 QVariantList 传递弹幕数据，QML 无法直接接收 QList<DanmakuItem>
    void danmakuListReady(const QVariantList &list);
    void errorOccurred(const QString &error);

private slots:
    void onDanmakuReplyFinished();

private:
    QList<DanmakuItem> parseXMLData(const QByteArray &data);
    QVariantList toVariantList(const QList<DanmakuItem> &list);

    QNetworkAccessManager *m_networkManager;
    QList<DanmakuItem> m_danmakuList;
    QString m_currentCid;  // 当前请求的 cid，用于过滤过期的请求

    static const QString USER_AGENT;
    static const QString REFERER;
};

#endif // VIDEODANMAKUMANAGER_H
