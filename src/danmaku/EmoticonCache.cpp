#include "EmoticonCache.h"

#include "../core/AppDirs.h"

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
    // 缓存目录：Linux 在 ~/.config/BbQ/emoticons/，Windows 仍在 exe 同目录
    // （行为不变）。**不能沿用旧位置**：.deb 安装后 exe 在 /opt/bbq/bin/ 归root，
    // 普通用户往那儿写必然 EACCES 失败 → 表情永远缓存不下来、每次都重新下载。
    // 详见 src/core/AppDirs.h。
    //
    // 注意：本函数是 const 且被 prefetch()/loadFromDisk() 等**纯读**路径调用，
    // 因此这里**不做任何建目录动作**（早期版本误用了 AppDirs::writableDir()，
    // 它内部 mkpath，会导致"只要启动过就创建 emoticons/"，与改动前
    // "下载成功才建目录"的行为不一致，且给热路径平白增加一次 stat）。
    // 建目录由写入方 onDownloadFinished() 负责。
    return AppDirs::configRoot() + QStringLiteral("emoticons/") + name;
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

    // 建目录放在真正要落盘的时刻（cachePath() 保持无副作用）。
    // 这样与改动前一致：只有下载成功才会创建 emoticons/ 目录。
    const QString target = cachePath(url);
    QDir().mkpath(QFileInfo(target).absolutePath());
    QFile f(target);
    if (f.open(QIODevice::WriteOnly))
        f.write(data);

    m_images.insert(url, img);
    emit ready(url);
}
