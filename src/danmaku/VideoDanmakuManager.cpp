#include "VideoDanmakuManager.h"
#include <QXmlStreamReader>
#include <QUrl>
#include <QNetworkRequest>
#include <QDateTime>
#include <algorithm>
#include <iostream>

const QString VideoDanmakuManager::USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
const QString VideoDanmakuManager::REFERER = "https://www.bilibili.com";

VideoDanmakuManager::VideoDanmakuManager(QObject *parent)
    : QObject(parent)
    , m_networkManager(new QNetworkAccessManager(this))
{
}

VideoDanmakuManager::~VideoDanmakuManager()
{
}

void VideoDanmakuManager::getDanmakuList(const QString &cid)
{
    if (cid.isEmpty()) {
        std::cout << "[VideoDanmaku] cid is empty, abort" << std::endl;
        emit errorOccurred("cid is empty");
        return;
    }

    // 保存当前请求的 cid，用于后续过滤过期的请求
    m_currentCid = cid;

    QString url = QString("https://comment.bilibili.com/%1.xml").arg(cid);
    std::cout << "[VideoDanmaku] Requesting danmaku for cid: " << cid.toStdString()
              << ", url: " << url.toStdString() << std::endl;

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), USER_AGENT.toUtf8());
    request.setRawHeader(QByteArray("Referer"), REFERER.toUtf8());
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/xml, text/xml, */*"));

    // SSL 配置，避免 "device not open" 错误
    QSslConfiguration sslConfig = QSslConfiguration::defaultConfiguration();
    sslConfig.setPeerVerifyMode(QSslSocket::VerifyNone);
    request.setSslConfiguration(sslConfig);

    QNetworkReply *reply = m_networkManager->get(request);
    // 存储 cid 到 reply 的属性中，用于在回调中验证
    reply->setProperty("cid", cid);
    connect(reply, &QNetworkReply::finished, this, &VideoDanmakuManager::onDanmakuReplyFinished);
}

void VideoDanmakuManager::clearDanmaku()
{
    m_danmakuList.clear();
}

void VideoDanmakuManager::onDanmakuReplyFinished()
{
    QNetworkReply *reply = qobject_cast<QNetworkReply*>(sender());
    if (!reply) return;

    // 检查回复的 cid 是否仍然是当前请求的 cid
    QString replyCid = reply->property("cid").toString();
    if (replyCid != m_currentCid) {
        std::cout << "[VideoDanmaku] Ignoring stale danmaku response for cid: " 
                  << replyCid.toStdString() << " (current: " << m_currentCid.toStdString() << ")" << std::endl;
        reply->deleteLater();
        return;
    }

    reply->deleteLater();

    if (reply->error() != QNetworkReply::NoError) {
        std::cout << "[VideoDanmaku] Network error: " << reply->errorString().toStdString()
                  << ", code: " << reply->error() << std::endl;
        emit errorOccurred(reply->errorString());
        return;
    }

    QByteArray data = reply->readAll();
    std::cout << "[VideoDanmaku] Received danmaku data, size: " << data.size() << std::endl;

    if (data.size() == 0) {
        std::cout << "[VideoDanmaku] Empty response" << std::endl;
        emit errorOccurred("Empty response");
        return;
    }

    m_danmakuList = parseXMLData(data);
    std::cout << "[VideoDanmaku] Parsed " << m_danmakuList.size() << " danmaku items" << std::endl;

    QVariantList variantList = toVariantList(m_danmakuList);
    emit danmakuListReady(variantList);
}

QList<VideoDanmakuManager::DanmakuItem> VideoDanmakuManager::parseXMLData(const QByteArray &data)
{
    QList<DanmakuItem> result;

    QXmlStreamReader xml(data);

    while (!xml.atEnd() && !xml.hasError()) {
        xml.readNext();

        if (xml.isStartElement() && xml.name().toString() == QLatin1String("d")) {
            QString attributes = xml.attributes().value("p").toString();
            QStringList attrList = attributes.split(",");

            DanmakuItem item;

            if (attrList.size() >= 6) {
                item.timestamp = (qint64)(attrList[0].toDouble() * 1000);
                item.type = attrList[1].toInt();
                item.fontSize = attrList[2].toInt();

                bool ok;
                uint colorValue = attrList[3].toUInt(&ok, 10);
                if (ok && colorValue > 0) {
                    item.color = QColor((colorValue >> 16) & 0xFF,
                                         (colorValue >> 8) & 0xFF,
                                         colorValue & 0xFF);
                } else {
                    item.color = QColor(255, 255, 255);
                }

                item.author = attrList[5];
            }

            xml.readNext();
            if (xml.isCharacters() && !xml.text().isNull()) {
                item.text = xml.text().toString();
                result.append(item);
            }
        }
    }

    if (xml.hasError()) {
        std::cout << "[VideoDanmaku] XML parse error: " << xml.errorString().toStdString() << std::endl;
    }

    std::sort(result.begin(), result.end(), [](const DanmakuItem &a, const DanmakuItem &b) {
        return a.timestamp < b.timestamp;
    });

    std::cout << "[VideoDanmaku] Sorted " << result.size() << " danmaku items by timestamp" << std::endl;

    return result;
}

QVariantList VideoDanmakuManager::toVariantList(const QList<DanmakuItem> &list)
{
    QVariantList result;
    for (const auto &item : list) {
        QVariantMap map;
        map["text"] = item.text;
        map["timestamp"] = (qlonglong)item.timestamp;
        map["type"] = item.type;
        map["color"] = item.color.name();
        map["author"] = item.author;
        map["fontSize"] = item.fontSize;
        result.append(map);
    }
    return result;
}
