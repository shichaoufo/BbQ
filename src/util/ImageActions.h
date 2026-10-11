#ifndef IMAGEACTIONS_H
#define IMAGEACTIONS_H

#include <QByteArray>
#include <QObject>
#include <QString>

class QNetworkAccessManager;

// 图片预览里的「复制图片 / 下载图片」（由 QML 的 ImagePreviewMenu 调用）。
//
// 为什么必须落在 C++：QML 既没有剪贴板 API 也没有写文件的 API。
//   · 复制要的是**位图** —— 粘贴进聊天窗口 / 文档直接成图，这只有
//     QGuiApplication::clipboard()->setImage() 能做到；用隐藏 TextEdit 往剪贴板
//     塞一段 <img src="..."> 得到的只是 HTML 文本，目标程序多半粘出一张裂图。
//   · 下载要落到确定的目录、还要保证文件名不重名，QML 拿不到标准路径，
//     也不能建目录 / 改名 / 写二进制。
// 下载写的是**原始字节**（不做解码再编码），所以存下来的就是服务端那份文件；
// 图床也不放大，拿到什么存什么。
class ImageActions : public QObject
{
    Q_OBJECT

public:
    explicit ImageActions(QObject *parent = nullptr);
    ~ImageActions() override;

    // 下载图片后写入系统剪贴板（位图）
    Q_INVOKABLE void copyImage(const QString &url);
    // 下载图片到系统「下载」目录，命名为 bili_<yyyyMMdd_HHmmss>.<ext>
    Q_INVOKABLE void saveImage(const QString &url);

signals:
    void imageCopied(const QString &message);
    void imageCopyFailed(const QString &error);
    void imageSaved(const QString &path);
    void imageSaveFailed(const QString &error);

private:
    void fetch(const QString &url, bool save);
    void copyToClipboard(const QByteArray &data);
    void saveToDisk(const QString &url, const QByteArray &data, const QString &contentType);

    QString downloadDir() const;
    QString extensionOf(const QString &url, const QString &contentType) const;

    QNetworkAccessManager *m_network = nullptr;
};

#endif // IMAGEACTIONS_H
