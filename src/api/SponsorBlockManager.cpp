#include "SponsorBlockManager.h"

#include "AppSettings.h"

#include <QCoreApplication>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QUrl>
#include <QUrlQuery>
#include <algorithm>

SponsorBlockManager *SponsorBlockManager::s_instance = nullptr;

SponsorBlockManager::SponsorBlockManager(QObject *parent)
    : QObject(parent)
{
    loadConfig();
}

SponsorBlockManager *SponsorBlockManager::instance()
{
    if (!s_instance)
        s_instance = new SponsorBlockManager(qApp);
    return s_instance;
}

void SponsorBlockManager::loadConfig()
{
    // bsb.conf 约定：exe 同目录、纯文本；首个非注释非空行 = 接口基地址。
    // 支持 "#" 行注释与行内空白；结尾多余的 "/" 去掉。任何解析失败都
    // 静默保持 m_baseUrl 为空 → available=false，功能整体关闭
    QFile f(QCoreApplication::applicationDirPath() + QStringLiteral("/bsb.conf"));
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text))
        return;

    while (!f.atEnd()) {
        const QString line = QString::fromUtf8(f.readLine()).trimmed();
        if (line.isEmpty() || line.startsWith(QLatin1Char('#')))
            continue;
        if (line.startsWith(QStringLiteral("http://"))
                || line.startsWith(QStringLiteral("https://"))) {
            QString base = line;
            while (base.endsWith(QLatin1Char('/')))
                base.chop(1);
            // 只写域名（如 https://bsbsb.top）时自动补官方 API 前缀 /api，
            // 避免请求打到站点根路径 404 后静默失败
            const QUrl u(base);
            if (u.path().isEmpty() || u.path() == QLatin1String("/"))
                base += QStringLiteral("/api");
            m_baseUrl = base;
        }
        break;   // 只认第一个有效行
    }

    if (!m_baseUrl.isEmpty())
        qDebug() << "[SponsorBlock] 空降助手已启用，接口:" << m_baseUrl;
}

bool SponsorBlockManager::available() const
{
    return !m_baseUrl.isEmpty() && !m_sessionDisabled;
}

bool SponsorBlockManager::enabled() const
{
    return AppSettings::instance()
               ? AppSettings::instance()->getBool(QStringLiteral("video/sponsor/enabled"), true)
               : true;
}

void SponsorBlockManager::setEnabled(bool v)
{
    if (AppSettings::instance())
        AppSettings::instance()->setBool(QStringLiteral("video/sponsor/enabled"), v);
    emit enabledChanged();
}

void SponsorBlockManager::noteResult(bool ok)
{
    if (ok) {
        m_consecutiveFailures = 0;
        return;
    }
    if (++m_consecutiveFailures >= 5 && !m_sessionDisabled) {
        // 社区服务器可能已下线/改地址：本会话内停止所有请求，
        // 避免每个视频都白等一次超时。下次启动重新尝试
        m_sessionDisabled = true;
        qWarning() << "[SponsorBlock] 连续" << m_consecutiveFailures
                   << "次请求失败，本会话内自动禁用空降助手";
        emit availableChanged();
    }
}

void SponsorBlockManager::getSegments(const QString &bvid, const QString &cid, double durationSec)
{
    if (!available() || bvid.isEmpty() || cid.isEmpty())
        return;

    QUrl url(m_baseUrl + QStringLiteral("/skipSegments"));
    QUrlQuery query;
    query.addQueryItem(QStringLiteral("videoID"), bvid);
    query.addQueryItem(QStringLiteral("cid"), cid);
    url.setQuery(query);

    QNetworkRequest req(url);
    // 服务端要求标识调用来源（区分 API 调用方），使用本客户端标识
    req.setRawHeader("origin", "BbQ");
    req.setRawHeader("x-ext-version", "1.0");
    req.setTransferTimeout(6000);   // 社区服务器响应慢，给足但有限
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                     QNetworkRequest::NoLessSafeRedirectPolicy);

    const int seq = ++m_requestSeq;
    QNetworkReply *reply = m_nam.get(req);
    connect(reply, &QNetworkReply::finished, this, [this, reply, bvid, cid, durationSec, seq]() {
        reply->deleteLater();
        if (seq != m_requestSeq)
            return;   // 过期响应（期间已发起更新查询）

        // 404 = 该视频无标注（常态），静默返回空列表
        const int httpStatus = reply->attribute(
            QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (httpStatus == 404) {
            noteResult(true);
            emit segmentsReady(bvid, cid, {});
            return;
        }
        if (reply->error() != QNetworkReply::NoError || httpStatus >= 500) {
            noteResult(false);
            return;   // 网络错误/服务器错误：静默，不影响播放
        }

        const QJsonDocument doc = QJsonDocument::fromJson(reply->readAll());
        if (!doc.isArray()) {
            noteResult(false);
            return;
        }

        QVariantList segments;
        for (const QJsonValue &v : doc.array()) {
            const QJsonObject obj = v.toObject();
            const QJsonArray seg = obj[QStringLiteral("segment")].toArray();
            if (seg.size() != 2)
                continue;
            const double start = seg.at(0).toDouble();
            const double end = seg.at(1).toDouble();
            if (end <= start || start < 0)
                continue;
            // MVP 只支持跳过类片段（mute/poi/chapter/full 忽略）
            if (obj[QStringLiteral("actionType")].toString() != QLatin1String("skip"))
                continue;
            // 换源校验：提交时的视频时长与当前时长差 >2s 视为过期
            const double submittedDur = obj[QStringLiteral("videoDuration")].toDouble();
            if (submittedDur > 0 && durationSec > 0 && qAbs(submittedDur - durationSec) > 2.0)
                continue;
            // 防御：片段明显越界（服务器数据异常）丢弃
            if (durationSec > 0 && start > durationSec + 5.0)
                continue;

            QVariantMap m;
            m[QStringLiteral("start")] = start;
            m[QStringLiteral("end")] = end;
            m[QStringLiteral("category")] = obj[QStringLiteral("category")].toString();
            m[QStringLiteral("uuid")] = obj[QStringLiteral("UUID")].toString();
            segments.append(m);
        }
        std::sort(segments.begin(), segments.end(),
                  [](const QVariant &a, const QVariant &b) {
                      return a.toMap()[QStringLiteral("start")].toDouble()
                             < b.toMap()[QStringLiteral("start")].toDouble();
                  });

        noteResult(true);
        emit segmentsReady(bvid, cid, segments);
    });
}

void SponsorBlockManager::reportViewed(const QString &uuid)
{
    if (!available() || uuid.isEmpty())
        return;

    QNetworkRequest req(QUrl(m_baseUrl + QStringLiteral("/viewedVideoSponsorTime")));
    req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    req.setRawHeader("origin", "BbQ");
    req.setRawHeader("x-ext-version", "1.0");
    req.setTransferTimeout(5000);

    QJsonObject body;
    body[QStringLiteral("UUID")] = uuid;
    // fire-and-forget：失败忽略（上报失败不计数，避免干扰会话禁用判定）
    QNetworkReply *reply = m_nam.post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, reply, &QObject::deleteLater);
}
