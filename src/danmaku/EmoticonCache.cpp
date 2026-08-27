#include "EmoticonCache.h"

#include <QCoreApplication>
#include <QBuffer>
#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QImageReader>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>

// ---------------------------------------------------------------------------
// 直播表情弹幕图片缓存（实现说明见头文件）
// ---------------------------------------------------------------------------
EmoticonCache *EmoticonCache::instance()
{
    static EmoticonCache inst;
    return &inst;
}

EmoticonCache::EmoticonCache(QObject *parent)
    : QObject(parent)
{
}

QString EmoticonCache::cachePath(const QString &url) const
{
    // 文件名 = url 的 SHA1 + 原始扩展名（表情图基本是 png/webp/gif）
    QString ext = QFileInfo(url).suffix().toLower();
    if (ext != "png" && ext != "webp" && ext != "gif" && ext != "jpg" && ext != "jpeg")
        ext = "png";   // 未知扩展名兜底：内容以 QImageReader 实际探测为准
    const QString name = QString::fromLatin1(
        QCryptographicHash::hash(url.toUtf8(), QCryptographicHash::Sha1).toHex()) + "." + ext;
    return QCoreApplication::applicationDirPath() + QStringLiteral("/emoticons/") + name;
}

void EmoticonCache::prefetch(const QString &url)
{
    if (url.isEmpty() || m_images.contains(url) || m_failed.contains(url)
            || m_downloading.contains(url))
        return;

    if (QFile::exists(cachePath(url))) {
        loadFromDisk(url);
        return;
    }
    startDownload(url);
}

void EmoticonCache::loadFromDisk(const QString &url)
{
    QImageReader reader(cachePath(url));
    // 动图（gif/webp 动画）只取首帧
    reader.setDecideFormatFromContent(true);
    const QImage img = reader.read();
    if (img.isNull()) {
        m_failed.insert(url);
        return;
    }
    m_images.insert(url, img);
    emit ready(url);
}

void EmoticonCache::startDownload(const QString &url)
{
    if (!m_nam)
        m_nam = new QNetworkAccessManager(this);

    QNetworkRequest req(url);
    req.setTransferTimeout(8000);
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                     QNetworkRequest::NoLessSafeRedirectPolicy);
    req.setRawHeader("User-Agent",
                     "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36");
    req.setRawHeader("Referer", "https://live.bilibili.com");

    m_downloading.insert(url);
    QNetworkReply *reply = m_nam->get(req);
    connect(reply, &QNetworkReply::finished, this,
            [this, url, reply]() { onDownloadFinished(url, reply); });
}

void EmoticonCache::onDownloadFinished(const QString &url, QNetworkReply *reply)
{
    m_downloading.remove(url);
    reply->deleteLater();

    if (reply->error() != QNetworkReply::NoError) {
        m_failed.insert(url);
        return;
    }
    const QByteArray data = reply->readAll();

    // 先解码再落盘：坏数据不写磁盘（写坏文件会让缓存永久命中失败）
    QBuffer buf;
    buf.setData(data);
    buf.open(QIODevice::ReadOnly);
    QImageReader reader(&buf);
    reader.setDecideFormatFromContent(true);
    const QImage img = reader.read();
    if (img.isNull()) {
        m_failed.insert(url);
        return;
    }

    QDir().mkpath(QCoreApplication::applicationDirPath() + QStringLiteral("/emoticons"));
    QFile f(cachePath(url));
    if (f.open(QIODevice::WriteOnly))
        f.write(data);

    m_images.insert(url, img);
    emit ready(url);
}
