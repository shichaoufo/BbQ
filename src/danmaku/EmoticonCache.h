#ifndef EMOTICONCACHE_H
#define EMOTICONCACHE_H

#include <QObject>
#include <QHash>
#include <QImage>
#include <QSet>
#include <QString>

class QNetworkAccessManager;
class QNetworkReply;

/**
 * @brief 直播表情弹幕图片缓存（进程级单例，主线程使用）
 *
 * 三级查找：内存 QImage → 磁盘（exe 同目录 emoticons/，文件名 = url SHA1 + 原扩展名）
 * → 网络下载。GIF/WebP 动图仅取首帧静态渲染——弹幕管线为一次性位图烘焙，
 * 逐帧动画需要每帧重传图集，违背零上传设计。
 *
 * 使用方式（DanmakuCanvas 激活路径）：
 *   - image(url) 未就绪返回 null → 本帧跳过烘焙，等 ready(url) 信号触发 update()
 *   - isFailed(url) 或等待超时 → 丢弃该条弹幕
 */
class EmoticonCache : public QObject
{
    Q_OBJECT
public:
    static EmoticonCache *instance();

    /// 图片是否已在内存中
    bool isReady(const QString &url) const { return m_images.contains(url); }
    /// 取已就绪图片（未就绪返回 null，不触发下载）
    QImage image(const QString &url) const { return m_images.value(url); }
    /// 永久失败（下载/解码失败，单 url 生命周期内只尝试一次）
    bool isFailed(const QString &url) const { return m_failed.contains(url); }
    /// 异步加载：磁盘命中直接入内存并发 ready；否则网络下载（8s 超时）
    void prefetch(const QString &url);

signals:
    /// 图片进入内存（磁盘命中或下载完成）。带 url 参数，
    /// 消费方可只对感兴趣的 url 做精确响应
    void ready(const QString &url);

private:
    explicit EmoticonCache(QObject *parent = nullptr);
    QString cachePath(const QString &url) const;
    void loadFromDisk(const QString &url);
    void startDownload(const QString &url);
    void onDownloadFinished(const QString &url, QNetworkReply *reply);

    QNetworkAccessManager *m_nam = nullptr;
    QHash<QString, QImage> m_images;
    QSet<QString> m_failed;
    QSet<QString> m_downloading;   // 进行中（防重复下载）
};

#endif // EMOTICONCACHE_H
