#include "WbiSigner.h"
#include "LoginManager.h"
#include <QCryptographicHash>
#include <QNetworkAccessManager>
#include <QNetworkRequest>
#include <QNetworkReply>
#include <QJsonDocument>
#include <QJsonObject>
#include <QDateTime>
#include <QEventLoop>
#include <QTimer>
#include <QElapsedTimer>
#include <QCoreApplication>
#include <QDebug>

const int WbiSigner::MIXIN_KEY_ENC_TAB[64] = {
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
    27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
    37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
    22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52
};

WbiSigner::WbiSigner()
    : m_mixinKey("")
    , m_lastUpdateTime(0)
{
}

WbiSigner* WbiSigner::instance()
{
    static WbiSigner instance;
    return &instance;
}

QString WbiSigner::extractKeyFromUrl(const QString& url)
{
    int lastSlash = url.lastIndexOf('/');
    int lastDot = url.lastIndexOf('.');
    
    if (lastSlash != -1 && lastDot != -1 && lastSlash < lastDot) {
        return url.mid(lastSlash + 1, lastDot - lastSlash - 1);
    }
    return "";
}

QString WbiSigner::getMixinKey(const QString& imgKey, const QString& subKey)
{
    QString rawKey = imgKey + subKey;
    QString key;
    key.reserve(32);
    
    for (int i = 0; i < 32; ++i) {
        int index = MIXIN_KEY_ENC_TAB[i];
        if (index < rawKey.length()) {
            key += rawKey[index];
        }
    }
    return key;
}

bool WbiSigner::fetchKeysSync()
{
    qDebug() << "[WbiSigner] fetchKeysSync called, mixinKey empty:" << m_mixinKey.isEmpty();
    qint64 now = QDateTime::currentDateTime().toSecsSinceEpoch();

    if (now - m_lastUpdateTime < 3600 && !m_mixinKey.isEmpty()) {
        qDebug() << "[WbiSigner] using cached keys";
        return true;
    }

    static QNetworkAccessManager* manager = new QNetworkAccessManager();

    QNetworkRequest request(QUrl("https://api.bilibili.com/x/web-interface/nav"));
    request.setRawHeader("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36");
    request.setRawHeader("Referer", "https://www.bilibili.com/");
    request.setRawHeader("Origin", "https://www.bilibili.com");
    request.setRawHeader("Accept", "application/json, text/plain, */*");

    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    QNetworkReply* reply = manager->get(request);

    // 避免在 QNetworkReply::finished 回调里使用 QEventLoop::exec() 形成嵌套事件循环，
    // 改为手动 processEvents 等待，减少闪退风险。
    QElapsedTimer timer;
    timer.start();
    while (!reply->isFinished() && timer.elapsed() < 10000) {
        QCoreApplication::processEvents(QEventLoop::ExcludeUserInputEvents, 50);
    }

    bool success = false;

    if (reply->isFinished() && reply->error() == QNetworkReply::NoError) {
        QByteArray data = reply->readAll();
        QJsonDocument doc = QJsonDocument::fromJson(data);
        if (doc.isObject()) {
            QJsonObject root = doc.object();
            if (root.contains("data") && root["data"].isObject()) {
                QJsonObject dataObj = root["data"].toObject();
                if (dataObj.contains("wbi_img") && dataObj["wbi_img"].isObject()) {
                    QJsonObject wbiImg = dataObj["wbi_img"].toObject();
                    QString imgUrl = wbiImg["img_url"].toString();
                    QString subUrl = wbiImg["sub_url"].toString();

                    QString imgKey = extractKeyFromUrl(imgUrl);
                    QString subKey = extractKeyFromUrl(subUrl);

                    if (!imgKey.isEmpty() && !subKey.isEmpty()) {
                        m_mixinKey = getMixinKey(imgKey, subKey);
                        m_lastUpdateTime = QDateTime::currentDateTime().toSecsSinceEpoch();
                        success = true;
                    }
                }
            }
        }
    } else {
        qWarning() << "[WbiSigner] fetchKeysSync failed/error:" << reply->error() << reply->errorString();
    }

    reply->deleteLater();
    if (success) {
        qDebug() << "[WbiSigner] fetchKeysSync result: true (keys cached)";
    } else {
        // 拿不到 img_key/sub_key：请求会退化为未签名（B 站可能降清晰度/限流），
        // 必须写进日志，别让它静默发生
        qWarning() << "[WbiSigner] fetchKeysSync result: false, requests will be UNSIGNED";
    }
    return success;
}

void WbiSigner::forceRefreshKeys()
{
    m_mixinKey = "";
    m_lastUpdateTime = 0;
    fetchKeysSync();
}

QString WbiSigner::signParams(const QString& params)
{
    qDebug() << "[WbiSigner] signParams called, mixinKey empty:" << m_mixinKey.isEmpty();
    if (m_mixinKey.isEmpty()) {
        if (!fetchKeysSync()) {
            qWarning() << "[WbiSigner] signParams returning UNSIGNED params (signing unavailable)";
            return params;
        }
    }

    QString wts = QString::number(QDateTime::currentDateTime().toSecsSinceEpoch());
    
    QStringList paramPairs = params.split('&');
    QMap<QString, QString> sortedParams;
    
    foreach (const QString& pair, paramPairs) {
        QStringList kv = pair.split('=');
        if (kv.size() == 2) {
            QString key = kv[0];
            QString value = kv[1];
            value.remove('!');
            value.remove('\'');
            value.remove('(');
            value.remove(')');
            value.remove('*');
            sortedParams[key] = value;
        }
    }
    
    sortedParams["wts"] = wts;
    
    QString query;
    foreach (const QString& key, sortedParams.keys()) {
        if (!query.isEmpty()) {
            query += "&";
        }
        query += key + "=" + sortedParams[key];
    }
    
    QString raw = query + m_mixinKey;
    QByteArray md5 = QCryptographicHash::hash(raw.toUtf8(), QCryptographicHash::Md5);
    QString w_rid = md5.toHex();
    
    QString signedParams = params + "&wts=" + wts + "&w_rid=" + w_rid;
    qDebug() << "[WbiSigner] signParams done";
    return signedParams;
}
