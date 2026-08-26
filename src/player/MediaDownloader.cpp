#include "MediaDownloader.h"
#include "LoginManager.h"
#include <QDebug>
#include <QDir>
#include <QFile>

static const QString DL_USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
static const QString DL_REFERER = "https://www.bilibili.com";
static const QString DL_ORIGIN = "https://www.bilibili.com";

MediaDownloader::MediaDownloader(QObject *parent)
    : QObject(parent)
    , m_networkManager(new QNetworkAccessManager(this))
{
}

MediaDownloader::~MediaDownloader()
{
    cancel();
}

void MediaDownloader::downloadVideo(const QString &url)
{
    if (url.isEmpty()) {
        emit downloadError("Empty video URL");
        return;
    }

    // 如果正在下载同一个 URL，直接忽略
    if (m_currentUrl == url && m_reply) {
        return;
    }

    cancel();
    cleanup();

    m_currentUrl = url;

    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), DL_USER_AGENT.toUtf8());
    request.setRawHeader(QByteArray("Referer"), DL_REFERER.toUtf8());
    request.setRawHeader(QByteArray("Origin"), DL_ORIGIN.toUtf8());
    request.setRawHeader(QByteArray("Accept"), QByteArray("*/*"));
    request.setRawHeader(QByteArray("Accept-Language"), QByteArray("zh-CN,zh;q=0.9"));
    request.setRawHeader(QByteArray("Connection"), QByteArray("keep-alive"));

    // 添加 Cookie（大会员/登录状态的关键）
    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader(QByteArray("Cookie"), cookies.toUtf8());
    }

    // 创建临时文件，前缀固定便于调试
    m_tempFile = new QTemporaryFile(QDir::tempPath() + "/biliqt_video_XXXXXX.mp4", this);
    m_tempFile->setAutoRemove(false);
    if (!m_tempFile->open()) {
        emit downloadError("Failed to create temporary file");
        cleanup();
        return;
    }

    qDebug() << "[MediaDownloader] start download:" << url << "->" << m_tempFile->fileName();

    m_reply = m_networkManager->get(request);
    connect(m_reply, &QNetworkReply::readyRead, this, &MediaDownloader::onReadyRead);
    connect(m_reply, &QNetworkReply::finished, this, &MediaDownloader::onFinished);
    connect(m_reply, &QNetworkReply::downloadProgress, this, &MediaDownloader::onDownloadProgress);
    connect(m_reply, QOverload<QNetworkReply::NetworkError>::of(&QNetworkReply::errorOccurred),
            this, &MediaDownloader::onError);
}

void MediaDownloader::cancel()
{
    if (m_reply) {
        m_reply->abort();
        m_reply->deleteLater();
        m_reply.clear();
    }
}

void MediaDownloader::cleanup()
{
    if (m_tempFile) {
        // 清理旧的临时文件
        QString oldPath = m_tempFile->fileName();
        if (!oldPath.isEmpty()) {
            QFile::remove(oldPath);
        }
        m_tempFile->deleteLater();
        m_tempFile.clear();
    }
    m_currentUrl.clear();
}

void MediaDownloader::onReadyRead()
{
    if (!m_reply || !m_tempFile) return;
    QByteArray data = m_reply->readAll();
    if (m_tempFile->write(data) < 0) {
        qWarning() << "[MediaDownloader] failed to write to temp file";
    }
}

void MediaDownloader::onFinished()
{
    if (!m_reply || !m_tempFile) {
        cleanup();
        return;
    }

    QNetworkReply::NetworkError err = m_reply->error();
    QString errorString = m_reply->errorString();
    QByteArray finalData = m_reply->readAll();
    if (!finalData.isEmpty()) {
        m_tempFile->write(finalData);
    }
    m_tempFile->flush();

    QString localPath = m_tempFile->fileName();
    qint64 fileSize = m_tempFile->size();

    m_reply->deleteLater();
    m_reply.clear();
    m_tempFile->close();

    if (err != QNetworkReply::NoError) {
        // 主动取消时不发送错误信号
        if (err == QNetworkReply::OperationCanceledError) {
            QFile::remove(localPath);
            cleanup();
            return;
        }
        qWarning() << "[MediaDownloader] error:" << err << errorString;
        QFile::remove(localPath);
        cleanup();
        emit downloadError(QString("Download failed: %1").arg(errorString));
        return;
    }

    if (fileSize <= 0) {
        QFile::remove(localPath);
        cleanup();
        emit downloadError("Downloaded file is empty");
        return;
    }

    qDebug() << "[MediaDownloader] ready:" << localPath << "size:" << fileSize;
    emit downloadReady(localPath);
}

void MediaDownloader::onDownloadProgress(qint64 bytesReceived, qint64 bytesTotal)
{
    emit downloadProgress(bytesReceived, bytesTotal);
}

void MediaDownloader::onError(QNetworkReply::NetworkError code)
{
    Q_UNUSED(code)
    if (m_reply) {
        qWarning() << "[MediaDownloader] network error:" << m_reply->errorString();
    }
}
