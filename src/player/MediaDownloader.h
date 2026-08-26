#ifndef MEDIADOWNLOADER_H
#define MEDIADOWNLOADER_H

#include <QObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QTemporaryFile>
#include <QPointer>
#include <QUrl>

class MediaDownloader : public QObject
{
    Q_OBJECT

public:
    explicit MediaDownloader(QObject *parent = nullptr);
    ~MediaDownloader();

    Q_INVOKABLE void downloadVideo(const QString &url);
    Q_INVOKABLE void cancel();

signals:
    void downloadReady(const QString &localPath);
    void downloadError(const QString &error);
    void downloadProgress(qint64 bytesReceived, qint64 bytesTotal);

private slots:
    void onReadyRead();
    void onFinished();
    void onDownloadProgress(qint64 bytesReceived, qint64 bytesTotal);
    void onError(QNetworkReply::NetworkError code);

private:
    void cleanup();

    QNetworkAccessManager *m_networkManager = nullptr;
    QPointer<QNetworkReply> m_reply;
    QPointer<QTemporaryFile> m_tempFile;
    QString m_currentUrl;
};

#endif // MEDIADOWNLOADER_H
