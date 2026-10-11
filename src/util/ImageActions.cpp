#include "ImageActions.h"

#include "LoginManager.h"

#include <QByteArray>
#include <QClipboard>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QImage>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QStandardPaths>
#include <QStringList>
#include <QUrl>

namespace {

// 与 MediaDownloader 同口径：图床也认 Referer，带上 Cookie 才能在需要登录
// 的场景（受限动态里的图）拿到图。
const char *const kUserAgent =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

// 预览用的地址是 GlobalState.fixImageUrl 拼出来的，尾巴上挂着 CDN 转换参数：
// "@.jpg"（转格式）或 "@260w_260h_1e_2c.jpg"（裁方）。下载 / 复制要的是原图，
// 所以把 "@" 之后整段去掉；只处理路径部分里的 "@"，避免误伤 URL 里的 userinfo。
QString normalizeUrl(const QString &url)
{
    QString u = url.trimmed();
    if (u.isEmpty())
        return QString();
    if (u.startsWith(QLatin1String("//")))
        u.prepend(QLatin1String("https:"));
    const int slash = u.lastIndexOf(QLatin1Char('/'));
    const int at = u.indexOf(QLatin1Char('@'), slash + 1);
    if (at > slash)
        u = u.left(at);
    return u;
}

} // namespace

ImageActions::ImageActions(QObject *parent)
    : QObject(parent)
    , m_network(new QNetworkAccessManager(this))
{
}

ImageActions::~ImageActions() = default;

void ImageActions::copyImage(const QString &url)
{
    fetch(url, /*save=*/false);
}

void ImageActions::saveImage(const QString &url)
{
    fetch(url, /*save=*/true);
}

void ImageActions::fetch(const QString &url, bool save)
{
    const QString src = normalizeUrl(url);
    if (src.isEmpty()) {
        const QString msg = tr("图片地址为空");
        if (save)
            emit imageSaveFailed(msg);
        else
            emit imageCopyFailed(msg);
        return;
    }

    QNetworkRequest request(QUrl(src));
    request.setRawHeader(QByteArray("User-Agent"), QByteArray(kUserAgent));
    request.setRawHeader(QByteArray("Referer"), QByteArray("https://www.bilibili.com/"));
    request.setRawHeader(QByteArray("Origin"), QByteArray("https://www.bilibili.com"));
    request.setRawHeader(QByteArray("Accept"),
                         QByteArray("image/avif,image/webp,image/apng,image/*,*/*;q=0.8"));
    const QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty())
        request.setRawHeader(QByteArray("Cookie"), cookies.toUtf8());

    QNetworkReply *reply = m_network->get(request);
    // 每次请求各用一个 reply 并各自持有 lambda：复制 / 下载可以并发
    //（比如刚点完下载又点复制），不必排队，也不会互相 abort。
    connect(reply, &QNetworkReply::finished, this, [this, reply, src, save]() {
        const QNetworkReply::NetworkError err = reply->error();
        const QString errText = reply->errorString();
        const QByteArray data = reply->readAll();
        const QString contentType =
            reply->header(QNetworkRequest::ContentTypeHeader).toString();
        reply->deleteLater();

        const auto fail = [this, save](const QString &reason) {
            if (save)
                emit imageSaveFailed(reason);
            else
                emit imageCopyFailed(reason);
        };

        if (err == QNetworkReply::OperationCanceledError)
            return; // 主动取消（析构时）不报错
        if (err != QNetworkReply::NoError) {
            fail(tr("请求失败：%1").arg(errText));
            return;
        }
        if (data.isEmpty()) {
            fail(tr("拿到的内容为空"));
            return;
        }

        if (save)
            saveToDisk(src, data, contentType);
        else
            copyToClipboard(data);
    });
}

void ImageActions::copyToClipboard(const QByteArray &data)
{
    QImage image;
    if (!image.loadFromData(data)) {
        emit imageCopyFailed(tr("无法解码这张图片"));
        return;
    }
    QClipboard *clipboard = QGuiApplication::clipboard();
    if (!clipboard) {
        emit imageCopyFailed(tr("拿不到系统剪贴板"));
        return;
    }
    clipboard->setImage(image);
    emit imageCopied(tr("已复制图片"));
}

void ImageActions::saveToDisk(const QString &url, const QByteArray &data,
                              const QString &contentType)
{
    const QString dir = downloadDir();
    const QString ext = extensionOf(url, contentType);
    const QString stamp =
        QDateTime::currentDateTime().toString(QStringLiteral("yyyyMMdd_HHmmss"));
    const QString base = QStringLiteral("bili_") + stamp;

    QString path = QDir(dir).filePath(base + QStringLiteral(".") + ext);
    // 同一秒内连点两次「下载图片」会撞名，加序号避让（不覆盖已有文件）
    int seq = 2;
    while (QFile::exists(path)) {
        path = QDir(dir).filePath(base + QStringLiteral("_") + QString::number(seq)
                                  + QStringLiteral(".") + ext);
        ++seq;
    }

    QFile file(path);
    if (!file.open(QIODevice::WriteOnly)) {
        emit imageSaveFailed(tr("写入失败：%1").arg(file.errorString()));
        return;
    }
    const qint64 written = file.write(data);
    // 错误串要在 close() 之前取 —— close() 会把状态复位掉
    const QString writeError = file.errorString();
    file.close();
    if (written != data.size()) {
        QFile::remove(path);
        emit imageSaveFailed(tr("写入失败：%1").arg(writeError));
        return;
    }
    emit imageSaved(path);
}

QString ImageActions::downloadDir() const
{
    // 系统「下载」目录优先，取不到时依次退到图片 / 主目录，都取不到才用临时目录。
    const QStringList candidates{
        QStandardPaths::writableLocation(QStandardPaths::DownloadLocation),
        QStandardPaths::writableLocation(QStandardPaths::PicturesLocation),
        QStandardPaths::writableLocation(QStandardPaths::HomeLocation),
    };
    for (const QString &dir : candidates) {
        if (!dir.isEmpty() && QDir().mkpath(dir))
            return dir;
    }
    return QDir::tempPath();
}

QString ImageActions::extensionOf(const QString &url, const QString &contentType) const
{
    // 先看 URL 路径的后缀（B 站图床的图片名都带 .jpg/.png/.gif/.webp）
    const QString path = QUrl(url).path();
    const int dot = path.lastIndexOf(QLatin1Char('.'));
    if (dot >= 0) {
        const QString ext = path.mid(dot + 1).toLower();
        static const QStringList kKnown{
            QStringLiteral("jpg"),  QStringLiteral("jpeg"), QStringLiteral("png"),
            QStringLiteral("gif"),  QStringLiteral("webp"), QStringLiteral("bmp"),
            QStringLiteral("avif"),
        };
        if (kKnown.contains(ext))
            return ext == QLatin1String("jpeg") ? QStringLiteral("jpg") : ext;
    }
    // 再看响应头（URL 后缀认不出来时兜底）
    const QString type = contentType.toLower();
    if (type.contains(QLatin1String("png")))
        return QStringLiteral("png");
    if (type.contains(QLatin1String("webp")))
        return QStringLiteral("webp");
    if (type.contains(QLatin1String("gif")))
        return QStringLiteral("gif");
    if (type.contains(QLatin1String("avif")))
        return QStringLiteral("avif");
    return QStringLiteral("jpg");
}
