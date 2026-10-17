#include "PlayUrlManager.h"
#include "AppSettings.h"
#include "LoginManager.h"
#include "WbiSigner.h"
#include <QCryptographicHash>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QUrlQuery>
#include <QUrl>
#include <QDateTime>
#include <QSslConfiguration>
#include <QSslSocket>
#include <QSet>
#include <QRandomGenerator>
#include <QDebug>
#include <QTimer>
#include <QRegularExpression>
#include <algorithm>

const QString PlayUrlManager::APP_KEY = "1d8b6e7d45233436";
const QString PlayUrlManager::APP_SECRET = "560c52ccd288fed045859ed18bffd973";
const QString PlayUrlManager::USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
const QString PlayUrlManager::REFERER = "https://www.bilibili.com";
const QString PlayUrlManager::ORIGIN = "https://www.bilibili.com";

// APP 接口专用 key（参考 biliuwp-lite 的 AndroidVideoKey）
const QString PlayUrlManager::APP_ANDROID_KEY = "iVGUTjsxvpLeuDCf";
const QString PlayUrlManager::APP_ANDROID_SECRET = "aHRmhWMLkdeMuILqORnYZocwMBpMEOdt";

// 未登录时使用的固定 buvid3，整个进程生命周期内复用，避免每次请求都被识别为新会话而触发 -799
static QString s_persistentFakeBuvid3;

QString PlayUrlManager::calculateAppSign(const QString &params, const QString &secret)
{
    QString sorted = params;
    QStringList parts = sorted.split("&");
    std::sort(parts.begin(), parts.end());
    QString joined = parts.join("&");
    QString stringToSign = joined + secret;

    QByteArray hash = QCryptographicHash::hash(stringToSign.toUtf8(), QCryptographicHash::Md5);
    return hash.toHex().toLower();
}

PlayUrlManager::PlayUrlManager(QObject *parent)
    : QObject(parent)
    , m_networkManager(new QNetworkAccessManager(this))
{
    // 简化的清晰度列表（只包含常用清晰度）
    // H.264 编码的清晰度
    m_qualityList.append({16, "流畅 360P", "H.264"});
    m_qualityList.append({32, "清晰 480P", "H.264"});
    m_qualityList.append({64, "高清 480P", "H.264"});
    m_qualityList.append({74, "高清 720P", "H.264"});
    m_qualityList.append({80, "高清 1080P", "H.264"});
    m_qualityList.append({112, "高清 1080P+", "H.264"});
    m_qualityList.append({116, "高清 1080P60", "H.264"});
    m_qualityList.append({212, "高清 720P60", "H.264"});
    m_qualityList.append({216, "高清 1080P60+", "H.264"});
    
    // H.265/HEVC 编码的清晰度（4K等）
    m_qualityList.append({120, "超清 4K", "H.265"});
    m_qualityList.append({125, "超清 4K HDR", "H.265"});
    m_qualityList.append({224, "超清 4K60", "H.265"});
    
    // AV1 编码的清晰度
    m_qualityList.append({127, "超清 8K", "AV1"});
    
    // 加载 CDN 设置
    AppSettings *appSettings = AppSettings::instance();
    if (appSettings) {
        m_cdnReplaceMode = appSettings->getInt("cdnReplaceMode", 0);
        m_cdnServer = appSettings->getString("cdnServer", "upos-sz-mirrorhwo1.bilivideo.com");
        qDebug() << "[PlayUrlManager] CDN settings loaded: mode=" << m_cdnReplaceMode 
                 << "server=" << m_cdnServer;
    }
}

PlayUrlManager::~PlayUrlManager()
{
}

// 官方 CDN 服务器列表（bilivideo.com 域名）
const QList<PlayUrlManager::CDNServer> PlayUrlManager::OFFICIAL_CDN_SERVERS = {
    {"upos-sz-mirrorhwo1.bilivideo.com", "华为云"},
    {"upos-sz-mirrorcos.bilivideo.com", "腾讯云"},
    {"upos-sz-mirrorali.bilivideo.com", "阿里云"},
    {"upos-sz-mirrorhw.bilivideo.com", "华为云HW"},
    {"upos-sz-mirrorks3.bilivideo.com", "金山云"},
    {"upos-tf-all-js.bilivideo.com", "JS"},
    {"cn-hk-eq-bcache-01.bilivideo.com", "香港01"},
    {"cn-hk-eq-bcache-16.bilivideo.com", "香港16"},
    {"upos-hz-mirrorakam.akamaized.net", "Akamaized"},
};

bool PlayUrlManager::isOfficialCDN(const QString &url)
{
    // 官方 CDN 必须包含 bilivideo.com 或 akamaized.net
    return url.contains("bilivideo.com") || url.contains("akamaized.net");
}

bool PlayUrlManager::isPCDN(const QString &url)
{
    // PCDN 节点是不包含官方 CDN 域名的节点
    if (url.isEmpty()) return false;
    return !isOfficialCDN(url);
}

QString PlayUrlManager::getOfficialCDNFromBackups(const QString &baseUrl, const QList<QString> &backupUrls)
{
    // 如果 baseUrl 已经是官方 CDN，直接返回
    if (isOfficialCDN(baseUrl)) {
        return baseUrl;
    }
    
    // 从备选 URL 列表中找到第一个官方 CDN
    for (const QString &backup : backupUrls) {
        if (isOfficialCDN(backup)) {
            qDebug() << "[PlayUrlManager] Found official CDN backup:" << backup;
            return backup;
        }
    }
    
    // 没有找到官方 CDN，返回原 URL
    qWarning() << "[PlayUrlManager] No official CDN found in backups, using original URL";
    return baseUrl;
}

QString PlayUrlManager::handleUrl(const QString &baseUrl, const QList<QString> &backupUrls, bool isProxy)
{
    if (baseUrl.isEmpty()) return baseUrl;
    
    QString optimizedUrl = baseUrl;
    bool isPCDN = PlayUrlManager::isPCDN(baseUrl);
    
    // 步骤1：优先使用官方 CDN（非 PCDN）
    if (isPCDN) {
        qDebug() << "[PlayUrlManager] URL is PCDN, trying to find official CDN from backups";
        optimizedUrl = getOfficialCDNFromBackups(baseUrl, backupUrls);
    }
    
    // 步骤2：根据 CDN 替换模式进行替换
    // m_cdnReplaceMode: 0=不替换, 1=全部替换, 2=仅替换PCDN, 3=仅替换代理
    if (m_cdnReplaceMode == 0) {
        return optimizedUrl;
    }
    
    // 解析 URL 获取 host
    QUrl urlObj(optimizedUrl);
    QString host = urlObj.host();
    QString replacedHost = m_cdnServer;
    
    if (replacedHost.isEmpty() || host.isEmpty()) {
        return optimizedUrl;
    }
    
    bool shouldReplace = false;
    switch (m_cdnReplaceMode) {
        case 1:  // 全部替换
            shouldReplace = true;
            break;
        case 2:  // 仅替换 PCDN
            shouldReplace = isPCDN;
            break;
        case 3:  // 仅替换代理
            shouldReplace = isProxy;
            break;
        default:
            shouldReplace = false;
    }
    
    if (shouldReplace && host != replacedHost) {
        // 替换 URL 中的 host
        QString replacedUrl = optimizedUrl;
        replacedUrl.replace(host, replacedHost);
        qDebug() << "[PlayUrlManager] CDN replaced:" << host << "->" << replacedHost
                 << "mode:" << m_cdnReplaceMode;
        return replacedUrl;
    }
    
    return optimizedUrl;
}

void PlayUrlManager::setCDNReplaceMode(int mode)
{
    m_cdnReplaceMode = mode;
    AppSettings *appSettings = AppSettings::instance();
    if (appSettings) {
        appSettings->setInt("cdnReplaceMode", mode);
    }
    qDebug() << "[PlayUrlManager] CDN replace mode set to:" << mode;
}

void PlayUrlManager::setCDNServer(const QString &server)
{
    m_cdnServer = server;
    AppSettings *appSettings = AppSettings::instance();
    if (appSettings) {
        appSettings->setString("cdnServer", server);
    }
    qDebug() << "[PlayUrlManager] CDN server set to:" << server;
}

void PlayUrlManager::refreshCDNSettings()
{
    AppSettings *appSettings = AppSettings::instance();
    if (appSettings) {
        m_cdnReplaceMode = appSettings->getInt("cdnReplaceMode", 0);
        m_cdnServer = appSettings->getString("cdnServer", "upos-sz-mirrorhwo1.bilivideo.com");
        qDebug() << "[PlayUrlManager] CDN settings refreshed: mode=" << m_cdnReplaceMode 
                 << "server=" << m_cdnServer;
    }
}

QVariantList PlayUrlManager::getAvailableCDNServers() const
{
    QVariantList result;
    for (const CDNServer &server : OFFICIAL_CDN_SERVERS) {
        QVariantMap item;
        item["host"] = server.host;
        item["name"] = server.name;
        result.append(item);
    }
    return result;
}

QString PlayUrlManager::getQualityName(int qualityId)
{
    for (const QualityInfo &info : m_qualityList) {
        if (info.qualityId == qualityId) {
            return info.qualityName;
        }
    }
    return QString("未知 %1P").arg(qualityId);
}

QString PlayUrlManager::getQualityDescription(int qn)
{
    // 直播清晰度描述映射（参考 wiliwili 和 B站API返回）
    switch (qn) {
        case 30000: return "杜比";
        case 20000: return "4K";
        case 15000: return "2K";
        case 10000: return "原画";
        case 400: return "蓝光";
        case 250: return "超清";
        case 150: return "高清";
        case 80: return "流畅";
        case 0: return "自动";
        default: return QString("清晰度%1").arg(qn);
    }
}

void PlayUrlManager::getPlayUrl(const QString &aid, const QString &cid, int quality)
{
    qDebug() << "[PlayUrlManager] getPlayUrl start aid:" << aid << "cid:" << cid << "quality:" << quality;
    // 递增请求ID，确保只处理最新请求的响应
    ++m_currentRequestId;
    int thisRequestId = m_currentRequestId;

    // 使用 WBI 签名接口，绕过 -351 风控
    QString url = "https://api.bilibili.com/x/player/wbi/playurl";

    // 从 AppSettings 获取编码设置
    AppSettings *appSettings = AppSettings::instance();
    int fnval = appSettings->getCodecFnval(appSettings->videoCodec());

    // 如果没有指定清晰度，使用默认清晰度
    if (quality <= 0) {
        quality = appSettings->defaultQuality();
    }

    // 构建请求参数（不带签名参数）
    QString params = QString("appkey=%1&avid=%2&cid=%3&fnval=%4&fnver=0&fourk=1&platform=pc")
                         .arg(APP_KEY)
                         .arg(aid)
                         .arg(cid)
                         .arg(fnval);

    if (quality > 0) {
        params += QString("&qn=%1").arg(quality);
    }

    // 使用 WBI 签名
    QString signedParams = WbiSigner::instance()->signParams(params);
    QString fullUrl = url + "?" + signedParams;

    QUrl qurl(fullUrl);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), USER_AGENT.toUtf8());
    request.setRawHeader(QByteArray("Referer"), REFERER.toUtf8());
    request.setRawHeader(QByteArray("Origin"), ORIGIN.toUtf8());
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));
    request.setRawHeader(QByteArray("Accept-Language"), QByteArray("zh-CN,zh;q=0.9,en;q=0.8"));
    // 2026-10-15：删掉原先写死的 Connection: keep-alive —— 启用 HTTP/2 后该头
    // 属非法头（RFC 9113 禁止 h2 携带 connection 类头）。连接复用由共享池自身
    // 行为决定：h1.1 默认就是 keep-alive，h2 靠多路复用，无需这个提示。
    request.setRawHeader(QByteArray("Cache-Control"), QByteArray("no-cache"));

    // 添加 Cookie 头 - 这是获取高清晰度视频流和绕过风控的关键
    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    } else {
        // 诊断：无 cookie 请求 playurl，服务端会按游客处理，最高只能 480P
        qWarning() << "[PlayUrlManager] getPlayUrl with NO cookie, will get guest-level quality (max 480P)"
                   << "requested qn:" << quality;
    }
    
    // 添加 buvid 相关头（重要的设备标识）
    request.setRawHeader(QByteArray("buvid"), QByteArray("XY8D30F8-E10D-4B3A-B9C6-78D2E1C4F7A0"));
    request.setRawHeader(QByteArray("buvid_fp"), QByteArray("d9a5c7d8f2e1b4a6c3b9e7f1a2d4c6b8"));

    QNetworkReply *reply = m_networkManager->get(request);
    reply->setProperty("quality", quality);
    reply->setProperty("requestId", thisRequestId);

    connect(reply, &QNetworkReply::finished, this, &PlayUrlManager::onPlayUrlReplyFinished);
}

void PlayUrlManager::resetConnectionState()
{
    // 关闭视频时调用：清空 m_networkManager 的空闲连接池，下次请求走全新
    // TCP/TLS 连接。依据：480P 降级绑定连接层（重启客户端必恢复，凭据沿用旧值）。
    // playerDetail 系列请求已改用一次性 QNAM（每次请求新建/销毁），
    // 无需在此清池。顺带清掉单条播放缓存，避免重开同一视频命中降级期的旧结果。
    qDebug() << "[PlayUrlManager] resetConnectionState - clearing HTTP connection cache";
    m_networkManager->clearConnectionCache();
    LoginManager::instance()->resetHttpConnections();
    m_hasCachedResult = false;
    m_cachedCid.clear();
}

void PlayUrlManager::onPlayUrlReplyFinished()
{
    qDebug() << "[PlayUrlManager] onPlayUrlReplyFinished";
    QNetworkReply *reply = qobject_cast<QNetworkReply*>(sender());
    if (!reply) return;

    // 检查是否是最新请求的响应，忽略过期请求
    int thisRequestId = reply->property("requestId").toInt();
    if (thisRequestId != m_currentRequestId) {
        reply->deleteLater();
        return;
    }

    int quality = reply->property("quality").toInt();

    if (reply->error() != QNetworkReply::NoError) {
        int httpStatus = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        QString errorMsg;
        if (httpStatus > 0) {
            errorMsg = QString("Network error: HTTP %1 - %2").arg(httpStatus).arg(reply->errorString());
            qWarning() << "[PlayUrlManager] playurl request failed, HTTP status:" << httpStatus
                       << "url:" << reply->url().toString();
        } else {
            errorMsg = QString("Network error: %1").arg(reply->errorString());
        }
        emit errorOccurred(errorMsg);
        reply->deleteLater();
        return;
    }

    QByteArray data = reply->readAll();

    parsePlayUrlData(data, quality);

    reply->deleteLater();
}

void PlayUrlManager::parsePlayUrlData(const QByteArray &data, int quality, const QString &cid)
{
    QJsonDocument doc = QJsonDocument::fromJson(data);
    if (!doc.isObject()) {
        emit errorOccurred("Invalid JSON format");
        return;
    }
    
    QJsonObject root = doc.object();
    int code = root["code"].toInt();

    if (code != 0) {
        QString message = root["message"].toString();
        // 诊断：playurl 接口返回错误码（-351=WBI签名失败/风控，-101=未登录/cookie失效）
        // 这类错误会导致视频降级到 480P，记录关键信息便于定位
        qWarning() << "[PlayUrlManager] playurl API error code:" << code
                   << "message:" << message
                   << "requested qn:" << quality
                   << "logged_in:" << LoginManager::instance()->isLoggedIn();
        emit errorOccurred(QString("API error: %1").arg(message));
        return;
    }
    
    
    QJsonObject dataObj = root["data"].toObject();
    qDebug() << "[PlayUrlManager] parsePlayUrlData data keys:" << dataObj.keys() << "requested quality:" << quality;
    qDebug() << "[PlayUrlManager] parsePlayUrlData has support_formats:" << dataObj.contains("support_formats");
    qDebug() << "[PlayUrlManager] parsePlayUrlData has dash:" << dataObj.contains("dash");
    qDebug() << "[PlayUrlManager] parsePlayUrlData has durl:" << dataObj.contains("durl");
    if (dataObj.contains("fnval")) {
        qDebug() << "[PlayUrlManager] parsePlayUrlData server reported fnval:" << dataObj["fnval"].toInt();
    }
    if (dataObj.contains("quality")) {
        qDebug() << "[PlayUrlManager] parsePlayUrlData server returned actual quality (data.quality):" << dataObj["quality"].toInt();
    }
    if (!dataObj.contains("dash") && dataObj.contains("support_formats")) {
        // Only-FLV 场景：检测是否 support_formats 中宣称的最高档高于实际返回的 data.quality（即用户宣称支持高画质但 FLV 拿不到）
        int declaredMax = 0;
        QJsonArray sf = dataObj["support_formats"].toArray();
        for (const QJsonValue &fv : sf) {
            int q = fv.toObject()["quality"].toInt();
            if (q > declaredMax) declaredMax = q;
        }
        int actualQ = dataObj.contains("quality") ? dataObj["quality"].toInt() : -1;
        if (declaredMax > 32 && actualQ > 0 && actualQ < declaredMax) {
            qWarning() << "[PlayUrlManager] ONLY-FLV WARNING: source returned no DASH stream (fnval probably includes DASH bit, but server didn't pack DASH encodes for this episode)."
                       << " support_formats declared max quality=" << declaredMax
                       << " but actual FLV returned quality=" << actualQ
                       << " — Only FLV single-file switching will likely downgrade to" << actualQ
                       << " even if user picks higher qid.";
        }
    }
    
    // 解析支持的所有清晰度
    parseQualityList(dataObj);
    
    // 获取 support_formats 中的最高质量
    int maxSupportQuality = 0;
    if (dataObj.contains("support_formats")) {
        QJsonArray supportFormats = dataObj["support_formats"].toArray();
        for (const QJsonValue &fmt : supportFormats) {
            int q = fmt.toObject()["quality"].toInt();
            if (q > maxSupportQuality) {
                maxSupportQuality = q;
            }
        }
        qDebug() << "[PlayUrlManager] V3 maxSupportQuality from support_formats:" << maxSupportQuality;
    }
    
    // 构建完整的结果对象
    VideoUrlResult result;

    // 先从 support_formats 建立 qualityId -> 名称 映射（FLV 和 DASH 路径都会用到）
    QMap<int, QString> qualityNames;
    if (dataObj.contains("support_formats")) {
        QJsonArray formats = dataObj["support_formats"].toArray();
        for (const QJsonValue &val : formats) {
            QJsonObject format = val.toObject();
            int qid = format["quality"].toInt();
            QString displayName = format["new_description"].toString();
            if (displayName.isEmpty()) {
                displayName = format["display_desc"].toString();
            }
            qualityNames[qid] = displayName;
        }
    }

    // 获取 API 真实返回的当前播放清晰度（请求 qn=120 时实际可能只返回 32=480P）
    int actualQuality = dataObj.contains("quality") ? dataObj["quality"].toInt() : quality;
    if (actualQuality <= 0) actualQuality = quality;

    // 诊断：记录请求 qn 与服务端返回 quality 的差异。
    // 若请求高画质（如80/120）但返回 ≤32（480P），说明鉴权失败或服务端风控降级。
    // logged_in 显示当前登录态，便于区分"cookie失效"vs"会话风控"。
    if (quality >= 80 && actualQuality <= 32) {
        qWarning() << "[PlayUrlManager] quality downgrade detected:"
                   << "requested qn:" << quality
                   << "server returned quality:" << actualQuality
                   << "logged_in:" << LoginManager::instance()->isLoggedIn();
    }

    // 解析FLV格式（作为备用）
    PlayUrlInfo playInfo;
    playInfo.duration = dataObj["timelength"].toInt() / 1000;

    // ====== 优先解析 durls（复数）：PGC V2 Only-FLV 多清晰度FLV数组 ======
    //   durls 是数组，每个元素含 {quality, format, durl[]}，可能包含 1080P/720P/480P/360P 多个 FLV 流
    //   选流策略：优先选 == 请求quality 的流；其次选 <= 请求quality 的最高流；最后才选最高流
    bool durlsHasHd = false;
    if (dataObj.contains("durls")) {
        QJsonArray durlsArr = dataObj["durls"].toArray();
        qDebug() << "[PlayUrlManager] durls (plural) count:" << durlsArr.size()
                 << "requested quality:" << quality;
        int exactMatchQ = -1, exactMatchIdx = -1;
        int bestBelowQ = -1, bestBelowIdx = -1;   // <= 请求quality 的最高流
        int bestAnyQ = -1, bestAnyIdx = -1;       // 最高流（兜底）
        for (int i = 0; i < durlsArr.size(); ++i) {
            QJsonObject durlObj = durlsArr[i].toObject();
            int durlQ = durlObj.contains("quality") ? durlObj["quality"].toInt() : -1;
            QJsonArray durlSegs = durlObj.contains("durl") ? durlObj["durl"].toArray() : QJsonArray();
            qDebug() << "    [durls[" << i << "]] quality=" << durlQ
                     << "format=" << durlObj["format"].toString()
                     << "durl_count=" << durlSegs.size();
            if (durlQ > 32) durlsHasHd = true;
            if (durlQ > bestAnyQ) { bestAnyQ = durlQ; bestAnyIdx = i; }
            if (durlQ == quality) { exactMatchQ = durlQ; exactMatchIdx = i; }
            if (durlQ <= quality && durlQ > bestBelowQ) { bestBelowQ = durlQ; bestBelowIdx = i; }
        }
        // 选流优先级：精确匹配 > 不超过请求的最高流 > 全局最高流
        int selQ = -1, selIdx = -1;
        if (exactMatchIdx >= 0) { selQ = exactMatchQ; selIdx = exactMatchIdx; }
        else if (bestBelowIdx >= 0) { selQ = bestBelowQ; selIdx = bestBelowIdx; }
        else if (bestAnyIdx >= 0) { selQ = bestAnyQ; selIdx = bestAnyIdx; }

        if (selIdx >= 0 && selQ > 0) {
            QJsonObject selDurlObj = durlsArr[selIdx].toObject();
            QJsonArray selDurlSegs = selDurlObj["durl"].toArray();
            if (!selDurlSegs.isEmpty()) {
                QJsonObject firstSeg = selDurlSegs[0].toObject();
                QList<QString> flvBackupUrls;
                if (firstSeg.contains("backup_url")) {
                    for (const QJsonValue &bu : firstSeg["backup_url"].toArray())
                        flvBackupUrls.append(bu.toString());
                }
                QString baseFlvUrl = firstSeg["url"].toString();
                result.flvUrl = handleUrl(baseFlvUrl, flvBackupUrls);
                playInfo.flvUrl = result.flvUrl;
                playInfo.videoUrl = result.flvUrl;
                playInfo.flvBackupUrls = flvBackupUrls;
                actualQuality = selQ;
                playInfo.qualityId = selQ;
                if (qualityNames.contains(selQ)) {
                    playInfo.qualityName = qualityNames[selQ];
                } else {
                    playInfo.qualityName = getQualityName(selQ);
                }
                playInfo.codec = "H.264";
                qDebug() << "[PlayUrlManager] FLV-from-durls path: selected quality=" << selQ
                         << "qualityName=" << playInfo.qualityName
                         << "(requested=" << quality
                         << "durlsHasHd=" << durlsHasHd << ")";
            }
        }
    }

    // 只在 durls（复数）没有成功解析出 FLV URL 时，才解析 durl（单数）
    // durl（单数）是默认 480P 流，如果 durls 已经选了 HD 流，这里会覆盖成 480P！
    if (result.flvUrl.isEmpty() && dataObj.contains("durl")) {
        QJsonArray durls = dataObj["durl"].toArray();
        if (!durls.isEmpty()) {
            QJsonObject firstDurl = durls[0].toObject();
            
            // 解析备选 URL
            QList<QString> flvBackupUrls;
            if (firstDurl.contains("backup_url")) {
                QJsonArray backups = firstDurl["backup_url"].toArray();
                for (const QJsonValue &backup : backups) {
                    flvBackupUrls.append(backup.toString());
                }
            }
            playInfo.flvBackupUrls = flvBackupUrls;
            
            // 使用 handleUrl 处理 FLV URL
            QString baseFlvUrl = firstDurl["url"].toString();
            result.flvUrl = handleUrl(baseFlvUrl, flvBackupUrls);
            playInfo.flvUrl = result.flvUrl;
            playInfo.videoUrl = result.flvUrl;
            // 关键修复：使用 API 实际返回的清晰度而非用户请求的清晰度
            // 请求 qn=120(4K) 时，服务器可能只下发 qn=32(480P) 的 durl
            playInfo.qualityId = actualQuality;
            if (qualityNames.contains(actualQuality)) {
                playInfo.qualityName = qualityNames[actualQuality];
            } else {
                playInfo.qualityName = getQualityName(actualQuality);
            }
            playInfo.codec = "H.264";
            qDebug() << "[PlayUrlManager] FLV path: requestedQuality=" << quality
                     << "actualQuality=" << actualQuality
                     << "qualityName=" << playInfo.qualityName;
        }
    }

    // 总是解析 DASH 格式（优先使用，包含真正的清晰度和分离的音视频）
    if (dataObj.contains("dash")) {
        QJsonObject dash = dataObj["dash"].toObject();

        // 获取所有视频流
        if (dash.contains("video")) {
            QJsonArray videos = dash["video"].toArray();
            qDebug() << "[PlayUrlManager] API returned" << videos.size() << "video streams in dash.video";
            for (const QJsonValue &val : videos) {
                QJsonObject video = val.toObject();
                int videoId = video["id"].toInt();
                QString videoCodec = video["codecs"].toString();
                QString baseUrl = video["baseUrl"].toString();
                qDebug() << "[PlayUrlManager]   Raw video stream id:" << videoId
                         << "codec:" << videoCodec
                         << "hasBaseUrl:" << !baseUrl.isEmpty();
            }
            
            for (const QJsonValue &val : videos) {
                QJsonObject video = val.toObject();
                PlayUrlInfo info;
                
                // 解析备选 URL 列表
                QList<QString> videoBackupUrls;
                if (video.contains("backupUrl")) {
                    QJsonArray backups = video["backupUrl"].toArray();
                    for (const QJsonValue &backup : backups) {
                        videoBackupUrls.append(backup.toString());
                    }
                }
                info.videoBackupUrls = videoBackupUrls;
                
                // 使用 handleUrl 处理视频 URL（优先官方 CDN，支持 CDN 替换）
                QString baseVideoUrl = video["baseUrl"].toString();
                info.videoUrl = handleUrl(baseVideoUrl, videoBackupUrls);
                
                info.qualityId = video["id"].toInt();
                info.codec = video["codecs"].toString();
                info.mimeType = video["mimeType"].toString();
                info.duration = playInfo.duration;

                if (video.contains("segmentBase")) {
                    QJsonObject segmentBase = video["segmentBase"].toObject();
                    info.segmentBaseInitialization = segmentBase["initialization"].toString();
                    info.segmentBaseIndexRange = segmentBase["indexRange"].toString();
                }

                // 优先使用 support_formats 中的官方描述
                if (qualityNames.contains(info.qualityId)) {
                    info.qualityName = qualityNames[info.qualityId];
                } else {
                    // 回退到预设列表
                    for (const QualityInfo &qualityItem : m_qualityList) {
                        if (qualityItem.qualityId == info.qualityId) {
                            info.qualityName = qualityItem.qualityName;
                            break;
                        }
                    }
                }

                if (info.qualityName.isEmpty()) {
                    info.qualityName = QString("清晰度 %1").arg(info.qualityId);
                }

                if (!info.videoUrl.isEmpty()) {
                    qDebug() << "[PlayUrlManager] Adding video stream qualityId:" << info.qualityId
                             << "codec:" << info.codec << "hasUrl:" << !info.videoUrl.isEmpty();
                    result.dashVideoUrls.append(info);
                } else {
                    qDebug() << "[PlayUrlManager] Skipping video stream qualityId:" << info.qualityId
                             << "because videoUrl is empty";
                }
            }
        }

        // 获取所有音频流
        if (dash.contains("audio")) {
            QJsonArray audios = dash["audio"].toArray();
            for (const QJsonValue &val : audios) {
                QJsonObject audio = val.toObject();
                PlayUrlInfo info;
                
                // 解析备选 URL 列表
                QList<QString> audioBackupUrls;
                if (audio.contains("backupUrl")) {
                    QJsonArray backups = audio["backupUrl"].toArray();
                    for (const QJsonValue &backup : backups) {
                        audioBackupUrls.append(backup.toString());
                    }
                }
                info.audioBackupUrls = audioBackupUrls;
                
                // 使用 handleUrl 处理音频 URL
                QString baseAudioUrl = audio["baseUrl"].toString();
                info.audioUrl = handleUrl(baseAudioUrl, audioBackupUrls);
                
                info.qualityId = audio["id"].toInt();
                info.codec = audio["codecs"].toString();
                info.mimeType = audio["mimeType"].toString();

                if (!info.audioUrl.isEmpty()) {
                    result.dashAudioUrls.append(info);
                }
            }
        }
    }

    // Debug: show available video streams
    qDebug() << "[PlayUrlManager] dashVideoUrls count:" << result.dashVideoUrls.count() << "requested quality:" << quality;
    for (const PlayUrlInfo &stream : result.dashVideoUrls) {
        qDebug() << "[PlayUrlManager]   video stream qualityId:" << stream.qualityId 
                 << "codec:" << stream.codec << "url:" << (stream.videoUrl.left(80) + "...");
    }
    
    // 设置主要播放信息 - 优先使用 FLV（音视频合一，兼容性好），否则使用 DASH
    if (!result.flvUrl.isEmpty()) {
        // 关键修复：FLV 路径再次确认使用 API 真实返回的清晰度，避免再次覆盖成请求值
        playInfo.flvUrl = result.flvUrl;
        playInfo.videoUrl = result.flvUrl;
        playInfo.qualityId = actualQuality;
        if (qualityNames.contains(actualQuality)) {
            playInfo.qualityName = qualityNames[actualQuality];
        } else {
            playInfo.qualityName = getQualityName(actualQuality);
        }
        playInfo.codec = "H.264";
        qDebug() << "[PlayUrlManager] Primary playback via FLV: actualQualityId=" << playInfo.qualityId
                 << "qualityName=" << playInfo.qualityName;
    } else if (!result.dashVideoUrls.isEmpty()) {
        // 从 AppSettings 获取当前编码设置，用于选择视频流
        AppSettings *appSettings = AppSettings::instance();
        int currentCodec = appSettings->videoCodec();

        // 编码优先级（数字越小越优先）
        // 0: H.264, 1: H.265, 2: AV1
        auto codecPriority = [currentCodec](const QString &codecStr) -> int {
            bool isH264 = codecStr.startsWith("avc1") || codecStr.contains("avc1");
            bool isH265 = codecStr.startsWith("hvc1") || codecStr.startsWith("hev1");
            bool isAV1 = codecStr.startsWith("av01");

            // 用户偏好的编码优先
            if (currentCodec == 0 && isH264) return 0;
            if (currentCodec == 1 && isH265) return 0;
            if (currentCodec == 2 && isAV1) return 0;

            // 其他编码按默认优先级
            if (isH265) return 1;
            if (isAV1) return 2;
            if (isH264) return 3;
            return 4;
        };

        if (quality > 0) {
            // 用户指定了清晰度，先找到该清晰度的所有视频流，按编码优先级选
            qDebug() << "[PlayUrlManager] Looking for streams with qualityId:" << quality;
            QList<PlayUrlInfo> matchingStreams;
            for (const PlayUrlInfo &stream : result.dashVideoUrls) {
                if (stream.qualityId == quality) {
                    matchingStreams.append(stream);
                }
            }
            qDebug() << "[PlayUrlManager] Found" << matchingStreams.count() << "streams with exact qualityId:" << quality;

            if (!matchingStreams.isEmpty()) {
                // 按编码优先级排序
                std::sort(matchingStreams.begin(), matchingStreams.end(),
                          [&codecPriority](const PlayUrlInfo &a, const PlayUrlInfo &b) {
                              return codecPriority(a.codec) < codecPriority(b.codec);
                          });
                playInfo = matchingStreams.first();
                qDebug() << "[PlayUrlManager] Using exact match: qualityId=" << playInfo.qualityId << "codec=" << playInfo.codec;
            } else {
                // 没有找到匹配的清晰度，找最近的可用清晰度
                // （最高 qualityId 不超过请求的 quality）
                QList<PlayUrlInfo> sortedByQuality = result.dashVideoUrls;
                std::sort(sortedByQuality.begin(), sortedByQuality.end(),
                          [](const PlayUrlInfo &a, const PlayUrlInfo &b) {
                              return a.qualityId > b.qualityId;
                          });
                qDebug() << "[PlayUrlManager] No exact match, falling back. Available qualities:";
                for (const PlayUrlInfo &stream : sortedByQuality) {
                    qDebug() << "[PlayUrlManager]   qualityId:" << stream.qualityId << "codec:" << stream.codec;
                }

                int fallbackQualityId = -1;
                for (const PlayUrlInfo &stream : sortedByQuality) {
                    if (stream.qualityId <= quality) {
                        fallbackQualityId = stream.qualityId;
                        break;
                    }
                }
                // ===== 关键修复：如果按"<= requested qn"没找到合适的档，或当前服务器
                // 把所有高 qn 档都排除在 dash.video 打包外（log43 场景：请求 qn=120，
                // 但 dash 里只有 32/16 的流，support_formats 中 64/80/112/120 没打包），
                // 那么 fallbackQualityId 会变成 <= 请求 qn 的最低可用档（32），画面看起来
                // "所有番剧都只能 480P"。
                //
                // 更合理的 fallback 策略：如果 fallbackQualityId 低于 dash.video 里实际
                // 打包的最高档，就直接用 dash 里打包好的最高档（sortedByQuality.first()）
                // 作为真实可用清晰度。这样即使服务器拒绝打包高 qn 档，我们也能用它
                // 真正下发的最好画质，而不是掉到最底部的 480P。
                int bestPackedQualityId = sortedByQuality.isEmpty() ? -1 : sortedByQuality.first().qualityId;
                if (bestPackedQualityId > fallbackQualityId) {
                    qDebug() << "[PlayUrlManager] Fallback boost: upgrade from qualityId=" << fallbackQualityId
                             << "to best actually packed qualityId=" << bestPackedQualityId
                             << "(server did not pack requested qn encodes into dash.video)";
                    fallbackQualityId = bestPackedQualityId;
                }
                qDebug() << "[PlayUrlManager] Fallback qualityId:" << fallbackQualityId << "(requested:" << quality << ")";

                // 如果没有更低清晰度可用，就用最高的
                if (fallbackQualityId == -1 && !sortedByQuality.isEmpty()) {
                    fallbackQualityId = sortedByQuality.first().qualityId;
                }

                // 收集 fallbackQualityId 的所有流，按编码优先级选
                if (fallbackQualityId > 0) {
                    QList<PlayUrlInfo> fallbackStreams;
                    for (const PlayUrlInfo &stream : result.dashVideoUrls) {
                        if (stream.qualityId == fallbackQualityId) {
                            fallbackStreams.append(stream);
                        }
                    }
                    if (!fallbackStreams.isEmpty()) {
                        std::sort(fallbackStreams.begin(), fallbackStreams.end(),
                                  [&codecPriority](const PlayUrlInfo &a, const PlayUrlInfo &b) {
                                      return codecPriority(a.codec) < codecPriority(b.codec);
                                  });
                        playInfo = fallbackStreams.first();
                    } else if (!result.dashVideoUrls.isEmpty()) {
                        playInfo = result.dashVideoUrls.first();
                    }
                } else if (!result.dashVideoUrls.isEmpty()) {
                    playInfo = result.dashVideoUrls.first();
                }
            }
        } else {
            // 没有指定清晰度，选择最高清晰度（列表按清晰度ID从高到低排）
            // 先按清晰度ID从高到低排序
            QList<PlayUrlInfo> sortedStreams = result.dashVideoUrls;
            std::sort(sortedStreams.begin(), sortedStreams.end(),
                      [](const PlayUrlInfo &a, const PlayUrlInfo &b) {
                          return a.qualityId > b.qualityId;
                      });

            if (!sortedStreams.isEmpty()) {
                int highestQualityId = sortedStreams.first().qualityId;

                // 在最高清晰度中按编码优先级选择
                QList<PlayUrlInfo> highestStreams;
                for (const PlayUrlInfo &stream : sortedStreams) {
                    if (stream.qualityId == highestQualityId) {
                        highestStreams.append(stream);
                    }
                }

                std::sort(highestStreams.begin(), highestStreams.end(),
                          [&codecPriority](const PlayUrlInfo &a, const PlayUrlInfo &b) {
                              return codecPriority(a.codec) < codecPriority(b.codec);
                          });
                playInfo = highestStreams.first();
            } else {
                playInfo = result.dashVideoUrls.first();
            }
        }

        // 获取对应的音频 URL
        if (!result.dashAudioUrls.isEmpty()) {
            // 按优先级选择音频：最高码率优先
            QList<PlayUrlInfo> sortedAudios = result.dashAudioUrls;
            // 音频流的 id 越大通常码率越高（30280 > 30232 > 30216）
            std::sort(sortedAudios.begin(), sortedAudios.end(),
                      [](const PlayUrlInfo &a, const PlayUrlInfo &b) {
                          return a.qualityId > b.qualityId;
                      });
            playInfo.audioUrl = sortedAudios.first().audioUrl;
        }
        
        qDebug() << "[PlayUrlManager] selected stream qualityId:" << playInfo.qualityId 
                 << "qualityName:" << playInfo.qualityName << "codec:" << playInfo.codec;
    }

    if (playInfo.videoUrl.isEmpty()) {
        emit errorOccurred("Failed to parse play URL");
        return;
    }

    if (!playInfo.audioUrl.isEmpty()) {
    }

    // 保存用户请求的清晰度，供 onPlayUrlLoaded 使用
    result.requestedQuality = quality;

    qDebug() << "[PlayUrlManager] parsePlayUrlData done, videoUrl:" << playInfo.videoUrl << "audioUrl:" << playInfo.audioUrl
             << "cid:" << cid << "quality:" << quality;

    // 缓存逻辑：
    // 1. 如果有 DASH 流且数量 >= 2，缓存结果以便后续切换清晰度
    // 2. 如果只有 FLV 流（番剧 V2 API 常见情况），不缓存，每次切换都重新请求 API
    if (!cid.isEmpty() && result.dashVideoUrls.count() >= 2) {
        // 统计流中包含的不同清晰度数量
        QSet<int> availableQualities;
        for (const PlayUrlInfo &s : result.dashVideoUrls) {
            availableQualities.insert(s.qualityId);
        }
        qDebug() << "[PlayUrlManager] Caching DASH result with" << result.dashVideoUrls.count()
                 << "video streams, distinct qualities:" << availableQualities.size()
                 << "(" << availableQualities << ")" << "cid:" << cid;
        m_cachedVideoUrlResult = result;
        m_hasCachedResult = true;
        m_cachedCid = cid;

        // 检查返回的流是否包含高画质（至少 1080P）
        bool hasHighQuality = false;
        for (int q : availableQualities) {
            if (q >= 80) {
                hasHighQuality = true;
                break;
            }
        }
        if (hasHighQuality) {
            m_highQualityFetched = true;
            m_highQualityFetchedCid = cid;
            qDebug() << "[PlayUrlManager] Marked CID" << cid
                     << "as high-quality fetched (qualities:" << availableQualities << ")";
        } else {
            m_highQualityFetched = false;
            m_highQualityFetchedCid.clear();
        }
    } else if (result.flvUrl.isEmpty()) {
        // 既没有 DASH 也没有 FLV，清空缓存
        qDebug() << "[PlayUrlManager] No cacheable result (no DASH or FLV), clearing cache";
        m_hasCachedResult = false;
        m_cachedCid.clear();
        m_highQualityFetched = false;
        m_highQualityFetchedCid.clear();
    } else {
        // 只有 FLV（番剧常见情况），不缓存，保留高画质标记
        qDebug() << "[PlayUrlManager] Only FLV available (no DASH), not caching for quality switching";
        m_hasCachedResult = false;
        m_cachedCid.clear();
        // 保留 m_highQualityFetched/m_highQualityFetchedCid 不变
    }
    
    emit playUrlLoaded(videoUrlResultToMap(result));
    emit playUrlReady(playUrlInfoToMap(playInfo));
}

// 清理缓存和状态（在切换视频前调用）
void PlayUrlManager::clearCache()
{
    qDebug() << "[PlayUrlManager] V3 clearCache - clearing all cached state";
    
    // 清理缓存
    m_cachedVideoUrlResult = VideoUrlResult();
    m_hasCachedResult = false;
    m_cachedCid.clear();
    
    // 清理高画质标记
    m_highQualityFetched = false;
    m_highQualityFetchedCid.clear();
    
    // 清理请求去重标记
    m_inFlightRequest = false;
    m_inFlightCid.clear();
    m_inFlightRequestQuality = 0;
    
    // 清理重试状态
    m_lastRequestAid.clear();
    m_retryCount = 0;
    m_retryCid.clear();
    
    qDebug() << "[PlayUrlManager] clearCache done";
}

// 从缓存中切换清晰度
void PlayUrlManager::switchQualityFromCache(int quality)
{
    qDebug() << "[PlayUrlManager] switchQualityFromCache quality:" << quality << "hasCache:" << m_hasCachedResult;

    if (!m_hasCachedResult || m_cachedVideoUrlResult.dashVideoUrls.isEmpty()) {
        qDebug() << "[PlayUrlManager] No cached result, cannot switch quality";
        emit errorOccurred("无法切换清晰度，请重新加载视频");
        return;
    }

    // 打印缓存中所有流的质量 ID
    qDebug() << "[PlayUrlManager] Cached streams quality IDs:";
    for (const PlayUrlInfo &stream : m_cachedVideoUrlResult.dashVideoUrls) {
        qDebug() << "[PlayUrlManager]   qualityId:" << stream.qualityId << "codec:" << stream.codec;
    }

    AppSettings *appSettings = AppSettings::instance();
    int currentCodec = appSettings->videoCodec();

    // 编码优先级
    auto codecPriority = [currentCodec](const QString &codecStr) -> int {
        bool isH264 = codecStr.startsWith("avc1") || codecStr.contains("avc1");
        bool isH265 = codecStr.startsWith("hvc1") || codecStr.startsWith("hev1");
        bool isAV1 = codecStr.startsWith("av01");

        if (currentCodec == 0 && isH264) return 0;
        if (currentCodec == 1 && isH265) return 0;
        if (currentCodec == 2 && isAV1) return 0;

        if (isH265) return 1;
        if (isAV1) return 2;
        if (isH264) return 3;
        return 4;
    };

    // 从缓存中找到匹配质量的流
    QList<PlayUrlInfo> matchingStreams;
    for (const PlayUrlInfo &stream : m_cachedVideoUrlResult.dashVideoUrls) {
        if (stream.qualityId == quality) {
            matchingStreams.append(stream);
        }
    }

    qDebug() << "[PlayUrlManager] Found" << matchingStreams.count() << "streams with qualityId:" << quality;

    PlayUrlInfo playInfo;
    if (!matchingStreams.isEmpty()) {
        // 精确匹配，按编码优先级排序
        std::sort(matchingStreams.begin(), matchingStreams.end(),
                  [&codecPriority](const PlayUrlInfo &a, const PlayUrlInfo &b) {
                      return codecPriority(a.codec) < codecPriority(b.codec);
                  });
        playInfo = matchingStreams.first();
        qDebug() << "[PlayUrlManager] Using exact match: qualityId=" << playInfo.qualityId << "codec=" << playInfo.codec;
    } else {
        // 没有精确匹配，找最接近的（不超过请求质量的最高质量）
        QList<PlayUrlInfo> sortedByQuality = m_cachedVideoUrlResult.dashVideoUrls;
        std::sort(sortedByQuality.begin(), sortedByQuality.end(),
                  [](const PlayUrlInfo &a, const PlayUrlInfo &b) {
                      return a.qualityId > b.qualityId;
                  });

        int fallbackQualityId = -1;
        for (const PlayUrlInfo &stream : sortedByQuality) {
            if (stream.qualityId <= quality) {
                fallbackQualityId = stream.qualityId;
                break;
            }
        }

        if (fallbackQualityId == -1 && !sortedByQuality.isEmpty()) {
            fallbackQualityId = sortedByQuality.first().qualityId;
        }

        qDebug() << "[PlayUrlManager] Fallback qualityId:" << fallbackQualityId << "(requested:" << quality << ")";

        if (fallbackQualityId > 0) {
            QList<PlayUrlInfo> fallbackStreams;
            for (const PlayUrlInfo &stream : m_cachedVideoUrlResult.dashVideoUrls) {
                if (stream.qualityId == fallbackQualityId) {
                    fallbackStreams.append(stream);
                }
            }
            if (!fallbackStreams.isEmpty()) {
                std::sort(fallbackStreams.begin(), fallbackStreams.end(),
                          [&codecPriority](const PlayUrlInfo &a, const PlayUrlInfo &b) {
                              return codecPriority(a.codec) < codecPriority(b.codec);
                          });
                playInfo = fallbackStreams.first();
            }
        }
    }

    if (playInfo.videoUrl.isEmpty()) {
        qDebug() << "[PlayUrlManager] Failed to find suitable stream";
        emit errorOccurred("无法找到合适的视频流");
        return;
    }

    // 选择对应的音频流（使用缓存中的音频）
    if (!m_cachedVideoUrlResult.dashAudioUrls.isEmpty()) {
        QList<PlayUrlInfo> sortedAudios = m_cachedVideoUrlResult.dashAudioUrls;
        std::sort(sortedAudios.begin(), sortedAudios.end(),
                  [](const PlayUrlInfo &a, const PlayUrlInfo &b) {
                      return a.qualityId > b.qualityId;
                  });
        playInfo.audioUrl = sortedAudios.first().audioUrl;
    }

    qDebug() << "[PlayUrlManager] switchQualityFromCache done, videoUrl:" << playInfo.videoUrl.left(80)
             << "qualityId:" << playInfo.qualityId << "qualityName:" << playInfo.qualityName;
    emit playUrlReady(playUrlInfoToMap(playInfo));
}

void PlayUrlManager::parseQualityList(const QJsonObject &dataObj)
{
    // 从 support_formats 获取所有清晰度选项（这是 API 提供的完整列表）
    // dash.video 是当前请求参数下返回的视频流，不能作为清晰度选项的依据
    QList<QualityInfo> supportedQualities;

    // 方式1: 使用 support_formats（旧 API 格式）
    if (dataObj.contains("support_formats")) {
        QJsonArray formats = dataObj["support_formats"].toArray();
        qDebug() << "[PlayUrlManager] support_formats count:" << formats.size();
        for (const QJsonValue &val : formats) {
            QJsonObject format = val.toObject();
            int qualityId = format["quality"].toInt();
            QString displayName = format["new_description"].toString();
            if (displayName.isEmpty()) {
                displayName = format["display_desc"].toString();
            }
            qDebug() << "[PlayUrlManager] support_formats quality:" << qualityId << "name:" << displayName;

            // 优先从预设列表匹配编码类型，否则标记为自动
            QString codecLabel = "自动";
            for (const QualityInfo &preset : m_qualityList) {
                if (preset.qualityId == qualityId) {
                    codecLabel = preset.codec;
                    break;
                }
            }

            supportedQualities.append({qualityId, displayName, codecLabel});
        }
    }
    
    // 方式2: 使用 accept_quality + accept_description（V2 API 格式）
    if (supportedQualities.isEmpty() && dataObj.contains("accept_quality") && dataObj.contains("accept_description")) {
        QJsonArray acceptQuality = dataObj["accept_quality"].toArray();
        QJsonArray acceptDescription = dataObj["accept_description"].toArray();
        qDebug() << "[PlayUrlManager] accept_quality count:" << acceptQuality.size();
        
        for (int i = 0; i < acceptQuality.size(); ++i) {
            int qualityId = acceptQuality[i].toInt();
            QString displayName = (i < acceptDescription.size()) ? acceptDescription[i].toString() : QString();
            
            qDebug() << "[PlayUrlManager] accept_quality quality:" << qualityId << "name:" << displayName;
            
            // 优先从预设列表匹配编码类型，否则标记为自动
            QString codecLabel = "自动";
            for (const QualityInfo &preset : m_qualityList) {
                if (preset.qualityId == qualityId) {
                    codecLabel = preset.codec;
                    break;
                }
            }
            
            supportedQualities.append({qualityId, displayName, codecLabel});
        }
    }

    // 如果没有 support_formats 或 accept_quality，回退到预设
    if (supportedQualities.isEmpty()) {
        qDebug() << "[PlayUrlManager] no support_formats/accept_quality, using preset list";
        supportedQualities = m_qualityList;
    }

    // 按清晰度ID排序（从高到低）
    std::sort(supportedQualities.begin(), supportedQualities.end(),
              [](const QualityInfo &a, const QualityInfo &b) {
                  return a.qualityId > b.qualityId;
              });

    QVariantList result;
    result.reserve(supportedQualities.size());
    for (const QualityInfo &info : supportedQualities) {
        result.append(qualityInfoToMap(info));
    }
    qDebug() << "[PlayUrlManager] qualityList emitting" << result.size() << "items";
    emit qualityListReady(result);
}

QVariantMap PlayUrlManager::videoDetailToMap(const VideoDetail &detail) const
{
    QVariantMap map;
    map["aid"] = detail.aid;
    map["bvid"] = detail.bvid;
    map["cid"] = detail.cid;
    map["title"] = detail.title;
    map["ownerName"] = detail.ownerName;
    map["ownerFace"] = detail.ownerFace;
    map["ownerPendant"] = detail.ownerPendant;
    map["ownerVerify"] = detail.ownerVerify;
    map["ownerMid"] = QString::number(detail.ownerMid);
    map["view"] = QString::number(detail.view);
    map["danmaku"] = QString::number(detail.danmaku);
    map["reply"] = QString::number(detail.reply);
    map["favorite"] = QString::number(detail.favorite);
    map["coin"] = QString::number(detail.coin);
    map["like"] = QString::number(detail.like);
    map["share"] = QString::number(detail.share);
    map["pubdate"] = QString::number(detail.pubdate);
    map["pic"] = detail.pic;
    map["description"] = detail.description;
    map["reqLike"] = detail.reqLike;
    map["reqDislike"] = detail.reqDislike;
    map["reqCoin"] = detail.reqCoin;
    map["reqFavorite"] = detail.reqFavorite;
    map["reqAttention"] = detail.reqAttention;
    map["hasReqUser"] = detail.hasReqUser;
    map["lastPlayTime"] = detail.lastPlayTime;
    map["lastPlayCid"] = detail.lastPlayCid;
    map["progress"] = detail.progress;
    
    // 添加合集/分集信息
    map["hasUgcSeason"] = detail.hasUgcSeason;
    map["seasonTitle"] = detail.seasonTitle;
    map["seasonCover"] = detail.seasonCover;
    map["seasonCurrentIndex"] = detail.seasonCurrentIndex;
    
    // 将 QList<QVariantMap> 转换为 QVariantList
    QVariantList episodesList;
    for (const QVariantMap &ep : detail.episodes) {
        episodesList.append(ep);
    }
    map["episodes"] = episodesList;
    
    // 添加分P信息
    map["hasPages"] = detail.hasPages;
    map["pageCurrentIndex"] = detail.pageCurrentIndex;
    
    QVariantList pagesList;
    for (const QVariantMap &pg : detail.pages) {
        pagesList.append(pg);
    }
    map["pages"] = pagesList;

    // 分段章节恒为空列表：真实数据由 player/wbi/v2（playerDetailReady）提供，
    // QML 侧 onPlayerDetailReady 会覆盖（见 VideoPlayerPage.qml）
    map["viewPoints"] = QVariantList();

    // 添加番剧相关信息
    map["isBangumi"] = detail.isBangumi;
    map["seasonId"] = detail.seasonId;
    map["epId"] = detail.epId;
    map["seasonType"] = detail.seasonType;
    map["bangumiTitle"] = detail.bangumiTitle;
    map["bangumiCover"] = detail.bangumiCover;
    map["bangumiTotalCount"] = detail.bangumiTotalCount;
    map["bangumiIndexFormat"] = detail.bangumiIndexFormat;
    
    return map;
}

QVariantMap PlayUrlManager::videoCardToMap(const VideoCardInfo &video) const
{
    QVariantMap map;
    map["aid"] = video.aid;
    map["bvid"] = video.bvid;
    map["title"] = video.title;
    map["pic"] = video.pic;
    map["author"] = video.author;
    map["mid"] = QString::number(video.mid);
    map["play"] = QString::number(video.play);
    map["danmaku"] = QString::number(video.danmaku);
    map["like"] = QString::number(video.like);
    map["duration"] = static_cast<int>(video.duration);
    map["pubdate"] = static_cast<qint64>(video.pubdate);
    map["badgeText"] = video.badgeText;
    map["epId"] = video.epId;
    map["seasonId"] = video.seasonId;
    map["cid"] = video.cid;

    // ====== 番剧推荐卡片专用字段 ======
    map["isBangumiCard"] = video.isBangumiCard;
    map["score"] = video.score;
    map["follow"] = QString::number(video.follow);
    map["seasonTitle"] = video.seasonTitle;
    map["updateInfo"] = video.updateInfo;

    return map;
}

QVariantMap PlayUrlManager::playUrlInfoToMap(const PlayUrlInfo &info) const
{
    QVariantMap map;
    map["videoUrl"] = info.videoUrl;
    map["audioUrl"] = info.audioUrl;
    map["flvUrl"] = info.flvUrl;
    map["qualityId"] = info.qualityId;
    map["qualityName"] = info.qualityName;
    map["codec"] = info.codec;
    map["mimeType"] = info.mimeType;
    map["duration"] = info.duration;
    map["segmentBaseInitialization"] = info.segmentBaseInitialization;
    map["segmentBaseIndexRange"] = info.segmentBaseIndexRange;
    
    // 添加备选 URL 列表（用于 CDN 切换或重试）
    QVariantList videoBackupList;
    for (const QString &url : info.videoBackupUrls) {
        videoBackupList.append(url);
    }
    map["videoBackupUrls"] = videoBackupList;
    
    QVariantList audioBackupList;
    for (const QString &url : info.audioBackupUrls) {
        audioBackupList.append(url);
    }
    map["audioBackupUrls"] = audioBackupList;
    
    QVariantList flvBackupList;
    for (const QString &url : info.flvBackupUrls) {
        flvBackupList.append(url);
    }
    map["flvBackupUrls"] = flvBackupList;
    
    return map;
}

QVariantMap PlayUrlManager::videoUrlResultToMap(const VideoUrlResult &result) const
{
    QVariantMap map;
    map["flvUrl"] = result.flvUrl;
    map["requestedQuality"] = result.requestedQuality;
    map["requestedAudioQuality"] = result.requestedAudioQuality;

    QVariantList videoList;
    videoList.reserve(result.dashVideoUrls.size());
    for (const PlayUrlInfo &info : result.dashVideoUrls) {
        videoList.append(playUrlInfoToMap(info));
    }
    map["dashVideoUrls"] = videoList;

    QVariantList audioList;
    audioList.reserve(result.dashAudioUrls.size());
    for (const PlayUrlInfo &info : result.dashAudioUrls) {
        audioList.append(playUrlInfoToMap(info));
    }
    map["dashAudioUrls"] = audioList;

    return map;
}

QVariantMap PlayUrlManager::qualityInfoToMap(const QualityInfo &info) const
{
    QVariantMap map;
    map["qualityId"] = info.qualityId;
    map["qualityName"] = info.qualityName;
    map["codec"] = info.codec;
    return map;
}

QUrl PlayUrlManager::getDanmakuUrl(const QString &cid)
{
    QString timestamp = generateTimestamp();
    QString params = QString("type=1&oid=%1&platform=pc&version=2.0.0&ts=%2")
                         .arg(cid)
                         .arg(timestamp);
    
    return QUrl(QString("https://api.bilibili.com/x/v2/dm/list/seg.so?%1").arg(params));
}

QString PlayUrlManager::generateTimestamp()
{
    return QString::number(QDateTime::currentSecsSinceEpoch());
}

QString PlayUrlManager::generateRandomHex(int length)
{
    QString chars = "0123456789abcdef";
    QString result;
    for (int i = 0; i < length; ++i) {
        result += chars[QRandomGenerator::global()->bounded(16)];
    }
    return result;
}

// 生成与真实 buvid3 格式一致的伪 buvid3：XY + UUID v4 样式
QString PlayUrlManager::generateFakeBuvid3()
{
    auto hex = [](int n) {
        QString chars = "0123456789abcdef";
        QString s;
        for (int i = 0; i < n; ++i) s += chars[QRandomGenerator::global()->bounded(16)];
        return s;
    };
    return QString("XY%1-%2-%3-%4-%5")
        .arg(hex(6), hex(4), hex(4), hex(4), hex(12));
}

void PlayUrlManager::getVideoUrlByAid(const QString &aid, const QString &overrideCid)
{
    // 使用 Web 接口获取视频详情（Cookie 鉴权）
    // Web 接口 /x/web-interface/view 在登录态下（带 SESSDATA 等 Cookie）返回 req_user 字段，
    // 包含当前用户的点赞/投币/收藏/关注状态（参考 biliuwp-lite 的 DetailWebInterface 实现）
    QString url = "https://api.bilibili.com/x/web-interface/view?aid=" + aid;


    QUrl reqUrl(url);
    QNetworkRequest request(reqUrl);
    request.setRawHeader("User-Agent", USER_AGENT.toUtf8());
    request.setRawHeader("Referer", REFERER.toUtf8());
    request.setRawHeader("Origin", ORIGIN.toUtf8());

    // 添加 Cookie - 让接口返回登录用户的 req_user 状态
    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    } else {
    }

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, aid, overrideCid]() {
        if (reply->error() != QNetworkReply::NoError) {
            emit errorOccurred("获取视频信息失败");
            reply->deleteLater();
            return;
        }

        QByteArray data = reply->readAll();
        // 检查响应中是否包含 req_user
        if (data.contains("req_user")) {
        } else {
        }

        QJsonDocument doc = QJsonDocument::fromJson(data);
        if (!doc.isObject()) {
            emit errorOccurred("解析视频信息失败");
            reply->deleteLater();
            return;
        }

        QJsonObject root = doc.object();
        if (root["code"].toInt() != 0) {
            emit errorOccurred("API错误: " + root["message"].toString());
            reply->deleteLater();
            return;
        }

        QJsonObject dataObj = root["data"].toObject();
        QString cid = QString::number(dataObj["cid"].toVariant().toLongLong());
        QString title = dataObj["title"].toString();


        emit videoInfoReady(aid, QString(), cid, title);

        // 解析详细视频信息
        VideoDetail detail;
        detail.aid = aid;
        detail.cid = cid;
        detail.title = title;
        detail.bvid = dataObj["bvid"].toString();
        detail.pic = dataObj["pic"].toString();
        detail.description = dataObj["desc"].toString();
        detail.pubdate = dataObj["pubdate"].toVariant().toLongLong();

        QJsonObject owner = dataObj["owner"].toObject();
        detail.ownerName = owner["name"].toString();
        detail.ownerFace = owner["face"].toString();
        detail.ownerMid = owner["mid"].toVariant().toLongLong();
        QJsonObject ownerPendant = owner["pendant"].toObject();
        detail.ownerPendant = ownerPendant["image"].toString();
        detail.ownerVerify = owner["official_verify"].toObject()["type"].toInt(-1);

        QJsonObject stat = dataObj["stat"].toObject();
        detail.view = stat["view"].toVariant().toLongLong();
        detail.danmaku = stat["danmaku"].toVariant().toLongLong();
        detail.reply = stat["reply"].toVariant().toLongLong();
        detail.favorite = stat["favorite"].toVariant().toLongLong();
        detail.coin = stat["coin"].toVariant().toLongLong();
        detail.like = stat["like"].toVariant().toLongLong();
        detail.share = stat["share"].toVariant().toLongLong();

        // 解析 req_user 字段（登录态下 Web 接口返回，包含当前用户对该视频的互动状态）
        if (dataObj.contains("req_user")) {
            QJsonObject reqUser = dataObj["req_user"].toObject();
            detail.hasReqUser = true;
            detail.reqLike = reqUser["like"].toInt() == 1;
            detail.reqDislike = reqUser["dislike"].toInt() == 1;
            detail.reqCoin = reqUser["coin"].toInt() >= 1;
            detail.reqFavorite = reqUser["favorite"].toInt() == 1;
            detail.reqAttention = reqUser["attention"].toInt();
            qDebug() << "[PlayUrlManager] req_user parsed:" << "like=" << detail.reqLike << "dislike=" << detail.reqDislike
                     << "coin=" << detail.reqCoin << "favorite=" << detail.reqFavorite << "attention=" << detail.reqAttention;
        } else {
            qDebug() << "[PlayUrlManager] req_user not found in response";
        }

        // 解析 ugc_season 数据（合集/分集信息）
        parseUgcSeason(dataObj, detail);

        // 解析分段章节（view_points）
        parseViewPoints(dataObj, detail);

        // 缓存字幕 id 白名单（供 player 接口返回的字幕轨过滤占位数据）
        parseVideoSubtitleIds(dataObj);

        // 解析 pages 数据（分P信息）
        bool hasPagesField = dataObj.contains("pages");
        int pagesSize = hasPagesField ? dataObj["pages"].toArray().size() : 0;
        qDebug() << "[PlayUrlManager] getVideoUrlByAid dataObj contains 'pages':" << hasPagesField << "size:" << pagesSize;
        parsePages(dataObj, detail);
        qDebug() << "[PlayUrlManager] after parsePages: hasPages=" << detail.hasPages 
                 << "pages.count=" << detail.pages.size() 
                 << "pageCurrentIndex=" << detail.pageCurrentIndex;

        // 如果主接口没有返回分P数据（pages 字段不存在或只有 1 个分P），
        // 调用 /x/player/pagelist 接口获取分P列表作为补充
        if (!hasPagesField || pagesSize <= 1) {
            qDebug() << "[PlayUrlManager] getVideoUrlByAid: no pages data from main API, fetching from /x/player/pagelist";
            getVideoPageList(aid, detail.bvid, cid);
        }

        emit videoDetailReady(videoDetailToMap(detail));

        // 额外获取 UP 主大会员状态
        fetchUpVipInfo(detail.ownerMid);

        // 使用 overrideCid（如果提供了）或 API 返回的默认 cid
        QString finalCid = overrideCid.isEmpty() ? cid : overrideCid;
        qDebug() << "[PlayUrlManager] getVideoUrlByAid finalCid for getPlayUrl:" << finalCid;

        // 获取到cid后再获取播放链接（使用AppSettings中的默认清晰度）
        int defaultQuality = AppSettings::instance()->defaultQuality();
        getPlayUrl(aid, finalCid, defaultQuality);

        reply->deleteLater();
    });
}

void PlayUrlManager::getVideoUrlByBvid(const QString &bvid, const QString &overrideCid, bool skipPlayUrl)
{
    qDebug() << "[PlayUrlManager] getVideoUrlByBvid start:" << bvid << "overrideCid:" << overrideCid << "skipPlayUrl:" << skipPlayUrl;
    // 先获取视频详情（包含aid和cid）
    QString url = "https://api.bilibili.com/x/web-interface/view?bvid=" + bvid;


    QUrl reqUrl(url);
    QNetworkRequest request(reqUrl);
    request.setRawHeader("User-Agent", USER_AGENT.toUtf8());
    // Referer 指向具体视频页面，有助于 /x/web-interface/view 在登录态下返回 req_user
    request.setRawHeader("Referer", (QString("https://www.bilibili.com/video/%1").arg(bvid)).toUtf8());
    request.setRawHeader("Origin", ORIGIN.toUtf8());

    // 添加 Cookie - 让接口能返回登录用户的状态信息
    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    } else {
    }

    qDebug() << "[PlayUrlManager] sending request:" << url;
    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, bvid, overrideCid, skipPlayUrl]() {
        qDebug() << "[PlayUrlManager] reply finished for bvid:" << bvid << "error:" << reply->error() << reply->errorString();
        if (reply->error() != QNetworkReply::NoError) {
            emit errorOccurred("获取视频信息失败");
            reply->deleteLater();
            return;
        }

        QByteArray data = reply->readAll();
        if (data.contains("req_user")) {
        } else {
        }

        QJsonDocument doc = QJsonDocument::fromJson(data);
        if (!doc.isObject()) {
            emit errorOccurred("解析视频信息失败");
            reply->deleteLater();
            return;
        }

        QJsonObject root = doc.object();
        if (root["code"].toInt() != 0) {
            emit errorOccurred("API错误: " + root["message"].toString());
            reply->deleteLater();
            return;
        }

        QJsonObject dataObj = root["data"].toObject();
        qDebug() << "[PlayUrlManager] parsed data object, keys:" << dataObj.keys();
        QString aid = QString::number(dataObj["aid"].toVariant().toLongLong());
        QString cid = QString::number(dataObj["cid"].toVariant().toLongLong());
        QString title = dataObj["title"].toString();
        qDebug() << "[PlayUrlManager] aid:" << aid << "cid:" << cid << "title:" << title;


        emit videoInfoReady(aid, bvid, cid, title);

        // 解析详细视频信息
        VideoDetail detail;
        detail.aid = aid;
        detail.bvid = bvid;
        detail.cid = cid;
        detail.title = title;
        detail.pic = dataObj["pic"].toString();
        detail.description = dataObj["desc"].toString();
        detail.pubdate = dataObj["pubdate"].toVariant().toLongLong();

        QJsonObject owner = dataObj["owner"].toObject();
        detail.ownerName = owner["name"].toString();
        detail.ownerFace = owner["face"].toString();
        detail.ownerMid = owner["mid"].toVariant().toLongLong();
        QJsonObject ownerPendant = owner["pendant"].toObject();
        detail.ownerPendant = ownerPendant["image"].toString();
        detail.ownerVerify = owner["official_verify"].toObject()["type"].toInt(-1);

        QJsonObject stat = dataObj["stat"].toObject();
        detail.view = stat["view"].toVariant().toLongLong();
        detail.danmaku = stat["danmaku"].toVariant().toLongLong();
        detail.reply = stat["reply"].toVariant().toLongLong();
        detail.favorite = stat["favorite"].toVariant().toLongLong();
        detail.coin = stat["coin"].toVariant().toLongLong();
        detail.like = stat["like"].toVariant().toLongLong();
        detail.share = stat["share"].toVariant().toLongLong();

        // 解析 req_user 字段（仅登录态下返回）
        if (dataObj.contains("req_user")) {
            QJsonObject reqUser = dataObj["req_user"].toObject();
            detail.hasReqUser = true;
            detail.reqLike = reqUser["like"].toInt() == 1;
            detail.reqDislike = reqUser["dislike"].toInt() == 1;
            detail.reqCoin = reqUser["coin"].toInt() >= 1;
            detail.reqFavorite = reqUser["favorite"].toInt() == 1;
            detail.reqAttention = reqUser["attention"].toInt();
            qDebug() << "[PlayUrlManager] req_user parsed:" << "like=" << detail.reqLike << "dislike=" << detail.reqDislike
                     << "coin=" << detail.reqCoin << "favorite=" << detail.reqFavorite << "attention=" << detail.reqAttention;
        } else {
            qDebug() << "[PlayUrlManager] req_user not found in response";
        }

        // 解析 ugc_season 数据（合集/分集信息）
        parseUgcSeason(dataObj, detail);

        // 解析分段章节（view_points）
        parseViewPoints(dataObj, detail);

        // 缓存字幕 id 白名单（供 player 接口返回的字幕轨过滤占位数据）
        parseVideoSubtitleIds(dataObj);

        // 解析 pages 数据（分P信息）
        bool hasPagesField = dataObj.contains("pages");
        int pagesSize = hasPagesField ? dataObj["pages"].toArray().size() : 0;
        qDebug() << "[PlayUrlManager] dataObj contains 'pages':" << hasPagesField << "size:" << pagesSize;
        parsePages(dataObj, detail);
        qDebug() << "[PlayUrlManager] after parsePages: hasPages=" << detail.hasPages
                 << "pages.count=" << detail.pages.size()
                 << "pageCurrentIndex=" << detail.pageCurrentIndex;

        // ===== 检测 redirect_url 判断是否为番剧 =====
        // 推荐页/热门页的番剧视频通过 /x/web-interface/view 接口返回时，
        // 响应中会包含 redirect_url 字段指向 /bangumi/play/epXXXX 或 /bangumi/play/ssXXXX。
        // 此时需要标记为番剧，由 QML 层切换到 PGC 专用播放接口（getSeasonPlayUrl），
        // 否则普通 UGC /x/player/wbi/playurl 对番剧会返回"什么都没有"导致播放失败。
        if (!detail.isBangumi && dataObj.contains("redirect_url")) {
            QString redirectUrl = dataObj["redirect_url"].toString();
            if (redirectUrl.contains("/bangumi/")) {
                detail.isBangumi = true;
                // 解析 ep_id（格式: /bangumi/play/ep1234567）
                QRegularExpression epRegex("/bangumi/play/ep(\\d+)");
                QRegularExpressionMatch epMatch = epRegex.match(redirectUrl);
                if (epMatch.hasMatch()) {
                    detail.epId = epMatch.captured(1);
                }
                // 解析 season_id（格式: /bangumi/play/ss12345）
                QRegularExpression ssRegex("/bangumi/play/ss(\\d+)");
                QRegularExpressionMatch ssMatch = ssRegex.match(redirectUrl);
                if (ssMatch.hasMatch()) {
                    detail.seasonId = ssMatch.captured(1);
                }
                qDebug() << "[PlayUrlManager] redirect_url detected as bangumi:"
                         << "redirectUrl:" << redirectUrl
                         << "epId:" << detail.epId << "seasonId:" << detail.seasonId;
            }
        }

        // 番剧不需要分P列表（番剧使用剧集列表，由 getSeasonEpisodes 获取）
        if (!detail.isBangumi && (!hasPagesField || pagesSize <= 1)) {
            qDebug() << "[PlayUrlManager] no pages data from main API, fetching from /x/player/pagelist";
            // 在 videoDetailReady 之后异步获取分P列表
            // QML 层需要监听 videoPageListReady 信号来更新分P数据
            getVideoPageList(aid, bvid, cid);
        }

        qDebug() << "[PlayUrlManager] emitting videoDetailReady";
        emit videoDetailReady(videoDetailToMap(detail));

        // 额外获取 UP 主大会员状态
        fetchUpVipInfo(detail.ownerMid);

        // 番剧不调用普通 UGC getPlayUrl（会返回"什么都没有"），由 QML 层走 PGC getSeasonPlayUrl
        if (skipPlayUrl || detail.isBangumi) {
            qDebug() << "[PlayUrlManager] skipPlayUrl:" << skipPlayUrl << "isBangumi:" << detail.isBangumi << ", skipping getPlayUrl";
            reply->deleteLater();
            return;
        }

        // 使用 overrideCid（如果提供了）或 API 返回的默认 cid
        QString finalCid = overrideCid.isEmpty() ? cid : overrideCid;
        qDebug() << "[PlayUrlManager] finalCid for getPlayUrl:" << finalCid << "(overrideCid:" << overrideCid << ")";

        // 获取到cid后再获取播放链接（使用AppSettings中的默认清晰度）
        int defaultQuality = AppSettings::instance()->defaultQuality();
        getPlayUrl(aid, finalCid, defaultQuality);

        reply->deleteLater();
    });
}

void PlayUrlManager::getVideoOnlineCount(const QString &aid, const QString &cid, const QString &bvid)
{
    // API: https://api.bilibili.com/x/player/online/total?aid=...&cid=...&bvid=...
    QString url = QString("https://api.bilibili.com/x/player/online/total?aid=%1&cid=%2&bvid=%3")
                      .arg(aid)
                      .arg(cid)
                      .arg(bvid);

    QUrl reqUrl(url);
    QNetworkRequest request(reqUrl);
    request.setRawHeader("User-Agent", USER_AGENT.toUtf8());
    request.setRawHeader("Referer", REFERER.toUtf8());
    request.setRawHeader("Origin", ORIGIN.toUtf8());

    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    qDebug() << "[PlayUrlManager] getVideoOnlineCount request:" << url;
    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        if (reply->error() != QNetworkReply::NoError) {
            qDebug() << "[PlayUrlManager] online/total network error:" << reply->error() << reply->errorString();
            reply->deleteLater();
            return;
        }

        QByteArray data = reply->readAll();
        qDebug() << "[PlayUrlManager] online/total raw response:" << data.left(512);
        QJsonDocument doc = QJsonDocument::fromJson(data);
        if (!doc.isObject()) {
            qDebug() << "[PlayUrlManager] online/total response is not JSON object";
            reply->deleteLater();
            return;
        }

        QJsonObject root = doc.object();
        int code = root["code"].toInt();
        if (code != 0) {
            qDebug() << "[PlayUrlManager] online/total API error code:" << code << "message:" << root["message"].toString();
            reply->deleteLater();
            return;
        }

        QJsonObject dataObj = root["data"].toObject();

        // 打印在线人数接口返回的原始 data 字段，便于排查字段名变化
        QStringList dataKeys;
        for (auto it = dataObj.begin(); it != dataObj.end(); ++it) {
            dataKeys << it.key();
        }
        qDebug() << "[PlayUrlManager] online/total data keys:" << dataKeys;
        qDebug() << "[PlayUrlManager] online/total data:" << QJsonDocument(dataObj).toJson(QJsonDocument::Compact);

        // B站接口返回的 show 字段已经是格式化好的文本，如 "3000+人正在看"
        QString showText = dataObj["show"].toString();
        if (!showText.isEmpty()) {
            emit videoOnlineCountReady(showText);
            reply->deleteLater();
            return;
        }

        // 兼容其他可能字段
        QJsonValue totalVal = dataObj.value("total");
        qDebug() << "[PlayUrlManager] online/total totalVal type:" << totalVal.type()
                 << "isString:" << totalVal.isString()
                 << "isDouble:" << totalVal.isDouble()
                 << "variant:" << totalVal.toVariant();
        QString totalStr = totalVal.toVariant().toString();
        if (totalStr.isEmpty()) {
            totalStr = dataObj.value("count").toVariant().toString();
        }
        if (totalStr.isEmpty()) {
            totalStr = dataObj.value("online").toVariant().toString();
        }
        if (totalStr.isEmpty()) {
            totalStr = dataObj.value("num").toVariant().toString();
        }
        // 接口返回的 total/count 已是**官方格式化好的展示文本**，直接用：
        //   千级 "999+"   万级 "2.4万+"   小人数 "82"
        // 原代码把它当数字解析（剥 + 号再 toInt）才导致 bug——QString::toInt
        // 遇到"万"会静默返回已解析的前缀（不抛异常、不置 ok），
        // "2.4万" → 2，于是显示成荒谬的"2+人正在看"。
        // 既然上游已经替我们做好了格式化，就别再拆解重拼：
        // 直接补后缀即可，也天然与官方客户端显示一致。
        // （曾考虑过解析单位再重组，但那样既多一层出错可能，
        //   又会把 "2.4万" 这种**有损**的量级值当成精确值去处理。）
        QString text = PlayUrlManager::formatOnlineCount(totalStr);
        if (text.isEmpty()) {
            // 兼容 count（Web 端实时在线，始终是纯数字）与 online（APP 端字段）
            for (const char *field : {"count", "online"}) {
                QString alt = dataObj.value(field).toVariant().toString();
                if (alt.isEmpty())
                    continue;
                text = PlayUrlManager::formatOnlineCount(alt);
                if (!text.isEmpty())
                    break;
            }
        }
        if (text.isEmpty()) {
            // 兜底：接口偶尔会额外给一个纯数字的 online 字段
            for (const char *field : {"online", "count", "total"}) {
                int n = dataObj.value(field).toInt();
                if (n > 0) {
                    text = QString::number(n) + "人正在看";
                    break;
                }
            }
        }
        qDebug() << "[PlayUrlManager] online/total totalStr:" << totalStr << "formatted text:" << text;
        emit videoOnlineCountReady(text);

        reply->deleteLater();
    });
}

QString PlayUrlManager::formatOnlineCount(const QString &raw)
{
    // 补"人正在看"后缀；空输入返回空串交由调用方回退。
    // 刻意不拆解数值/单位：B 站给什么就显示什么，与官方客户端一致。
    const QString s = raw.trimmed();
    if (s.isEmpty())
        return QString();
    // 上游若已带后缀则不重复追加
    if (s.contains(QStringLiteral("人正在看")))
        return s;
    return s + QStringLiteral("人正在看");
}

void PlayUrlManager::getArchiveRelation(const QString &aid, const QString &bvid)
{
    // Web 端 /x/web-interface/view 在某些情况下不返回 req_user，
    // 用 archive/relation 接口补充查询当前登录用户的点赞/点踩/投币/收藏状态
    QString params = QString("aid=%1").arg(aid);
    QString signedParams = WbiSigner::instance()->signParams(params);
    QString url = QString("https://api.bilibili.com/x/web-interface/archive/relation?%1").arg(signedParams);

    QUrl reqUrl(url);
    QNetworkRequest request(reqUrl);
    request.setRawHeader("User-Agent", USER_AGENT.toUtf8());
    request.setRawHeader("Referer", (QString("https://www.bilibili.com/video/%1").arg(bvid)).toUtf8());
    request.setRawHeader("Origin", ORIGIN.toUtf8());

    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    qDebug() << "[PlayUrlManager] getArchiveRelation request:" << url;
    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        if (reply->error() != QNetworkReply::NoError) {
            qDebug() << "[PlayUrlManager] archive/relation network error:" << reply->error() << reply->errorString();
            reply->deleteLater();
            return;
        }

        QByteArray data = reply->readAll();
        qDebug() << "[PlayUrlManager] archive/relation raw response:" << data.left(512);
        QJsonDocument doc = QJsonDocument::fromJson(data);
        if (!doc.isObject()) {
            qDebug() << "[PlayUrlManager] archive/relation response is not JSON object";
            reply->deleteLater();
            return;
        }

        QJsonObject root = doc.object();
        int code = root["code"].toInt();
        if (code != 0) {
            qDebug() << "[PlayUrlManager] archive/relation API error code:" << code << "message:" << root["message"].toString();
            reply->deleteLater();
            return;
        }

        QJsonObject dataObj = root["data"].toObject();
        qDebug() << "[PlayUrlManager] archive/relation data keys:" << dataObj.keys();

        QVariantMap relation;
        relation["like"] = dataObj["like"].toVariant().toBool();
        relation["dislike"] = dataObj["dislike"].toVariant().toBool();
        relation["coin"] = dataObj["coin"].toVariant().toBool();
        relation["favorite"] = dataObj["favorite"].toVariant().toBool();
        qDebug() << "[PlayUrlManager] archive/relation parsed:" << "like=" << relation["like"] << "dislike=" << relation["dislike"]
                 << "coin=" << relation["coin"] << "favorite=" << relation["favorite"];
        emit archiveRelationReady(relation);

        reply->deleteLater();
    });
}

// 获取视频分P详情（历史播放进度 + 分段章节）
// 用 /x/player/wbi/v2 返回 last_play_time/last_play_cid（恢复播放位置）、
// view_points（UP主分段章节）与 subtitle（字幕轨）
void PlayUrlManager::getPlayerDetail(const QString &aid, const QString &cid, const QString &bvid)
{
    // 主链路用 /x/player/wbi/v2（PiliPlus 的字幕接口也是它）：一次请求拿全
    // progress + view_points + subtitle，而且**不会返回占位轨**。
    //
    // 【2026-10-15 定位】此前它对本机稳定 412，根因不在网络栈、不在 UA/头部/TLS，
    // 而是**我们自己**把 SESSDATA 里的 %2C 解码成裸逗号再回传，被 B站风控当成
    // "脚本构造的 cookie"。修好编码（LoginManager::sessDataForCookie）后实测：
    //   同一会话、只改这一处编码 —— 裸逗号 412 / %2C 200 且拿到真实字幕轨
    // 详见 LoginManager.cpp 里该函数的注释。
    //
    // 兜底：万一 wbi/v2 又被拦（走 handleBanned），立刻转 legacy
    // /x/player/v2 + 并发对冲。legacy 的 subtitle 字段会被服务端**概率性投毒**
    // ——返回一条**别的视频**的 AI 字幕（URL 形如
    //   //aisubtitle.hdslb.com/bfs/ai_subtitle/prod/<别人的aid><别人的cid><hash>
    // 例如实测拿到指向 BV1N9xKeHEQ3（iPhone 评测）的 675 条字幕，而本视频真实轨
    // 是 323 条人工 CC）。它的 id 不在 view 权威列表里，会被按 id 的过滤丢弃，
    // 表现为"这个视频没有字幕"，所以才需要多路并发碰运气。
    getPlayerDetailImpl(aid, cid, bvid, false, /*useLegacyEndpoint=*/false);
}

void PlayUrlManager::getPlayerDetailImpl(const QString &aid, const QString &cid, const QString &bvid, bool asGuest,
                                         bool useLegacyEndpoint, const QVariantList &fallbackViewPoints)
{
    qWarning() << "[PlayUrlManager] getPlayerDetail aid:" << aid << "cid:" << cid << "bvid:" << bvid
             << "asGuest:" << asGuest << "legacy:" << useLegacyEndpoint;

    QString params = bvid.isEmpty()
                         ? QString("aid=%1&cid=%2").arg(aid, cid)
                         : QString("aid=%1&cid=%2&bvid=%3").arg(aid, cid, bvid);

    QString url;
    if (useLegacyEndpoint) {
        // 老 /x/player/v2：无需 WBI 签名，即**当前主链路**。
        // 实测返回与 wbi/v2 等价的数据（subtitle / last_play_time / view_points
        // 齐备，见 2026-10-14 对照）
        url = QString("https://api.bilibili.com/x/player/v2?%1").arg(params);
    } else {
        // /x/player/wbi/v2：2026-10-14 确认它对**所有客户端**稳定 412 ——
        // 用 curl 配完整 Cookie + 独立实现算出的正确 w_rid，同样拿到 412
        // 风控页。所以 412 与 UA、请求头、TLS 指纹都无关（此前"Qt TLS 指纹被
        // 拦"的判断是错的：当时只拿 legacy 端点做对照，而 legacy 本来就不受
        // 风控）。它是端点级拦截，B站要求该接口带浏览器侧反爬参数。
        // 此分支已不参与主链路，仅保留备查
        QString signedParams = WbiSigner::instance()->signParams(params);
        url = QString("https://api.bilibili.com/x/player/wbi/v2?%1").arg(signedParams);
    }

    QUrl reqUrl(url);
    QNetworkRequest request(reqUrl);
    // HTTP/2 由 main.cpp 的全局 ALPN 白名单统一放开（默认即可，无需逐请求设
    // Http2AllowedAttribute）；此处不再强制关闭。
    //
    // 2026-10-15 更正：以前这里写死 false、理由是"B站对 h2 返 -412"，实测证明
    // 那是错的——真实根因是 SESSDATA 的 %2C 被解码成裸逗号（见
    // LoginManager::sessDataForCookie）。用修好编码的 cookie 复测，h2 与
    // http/1.1 均正常返回 200 + 真实字幕轨。
    // 连接用完立即过期，杜绝任何形式的连接复用。
    //
    // 本项目在 720P 降级（只拿到 720P 清晰度）问题上验证过：B站会**按连接
    // 维度做风控标记**，同一条连接上后续请求会被静默降级；当时的解法就是不
    // 复用连接。这里沿用该约定，配合 Connection: close 保证每次请求都走
    // 全新的 TCP 连接
    request.setAttribute(QNetworkRequest::ConnectionCacheExpiryTimeoutSecondsAttribute, 0);

    // 两个端点统一用浏览器风格头：这是实测能稳定返回 subtitle 字段的组合。
    //
    // 历史上 wbi/v2 分支还试过 "wiliwili" UA、Dart/3.6 UA、去掉 Origin 等变体，
    // 那是在"412 由客户端特征引起"的错误假设下打的补丁。现已确认 412 与这些
    // 全都无关（连 curl 都被拦），保留这些变体只会制造"伪装不一致"这种多余
    // 特征，故统一为真实浏览器特征
    request.setRawHeader("User-Agent", USER_AGENT.toUtf8());
    request.setRawHeader("Referer", REFERER.toUtf8());
    request.setRawHeader("Origin", ORIGIN.toUtf8());
    request.setRawHeader("Accept", "application/json, text/plain, */*");
    // 不再显式发 Connection: close —— 一次性 QNAM 本身就保证连接不跨请求复用，
    // 而这个头在 HTTP/2 下是非法头（可能被服务端拒掉），2026-10-15 开 h2 时去掉。

    // 防 412 风控：确保真实设备指纹（buvid3 缺失是 412 的常见原因），与 getUserSpaceDynamics 同一套模式
    LoginManager *loginMgr = LoginManager::instance();
    loginMgr->ensureServerBuvid3();
    QString buvid3 = loginMgr->getOrCreateBuvid3();

    // buvid 请求头两个端点都加（与 Cookie 里的 buvid3 冗余，但真实浏览器也会带）
    if (!buvid3.isEmpty()) {
        request.setRawHeader(QByteArray("buvid"), buvid3.toUtf8());
    }

    if (!asGuest) {
        // 合并登录 cookie + 设备指纹 cookie（登录 cookie 可能缺 buvid3/bili_ticket 等）
        QString cookies = loginMgr->getCookies();
        auto appendCookie = [&](const QString &key, const QString &val) {
            if (val.isEmpty()) return;
            if (!cookies.isEmpty() && cookies.contains(key + "=")) return;
            if (!cookies.isEmpty() && !cookies.endsWith("; ")) cookies += "; ";
            cookies += QString("%1=%2; ").arg(key, val);
        };
        appendCookie("buvid3", buvid3);
        appendCookie("buvid4", loginMgr->getBuvid4());
        appendCookie("b_nut", loginMgr->getBNut());
        appendCookie("bili_ticket", loginMgr->getBiliTicket());
        // 注意：不再伪造 buvid_fp=buvid3。buvid_fp 应为 32 位 hex 指纹，拿
        // buvid3（infoc 格式）冒充是明显的指纹伪造特征，疑似近期 412 风控诱因；
        // 登录 cookie 里如有真实 buvid_fp 会随 getCookies() 带上，没有就不发

        if (!cookies.isEmpty()) {
            request.setRawHeader("Cookie", cookies.toUtf8());
        }
    }

    // 一次性 QNAM：每次请求新建网络管理器，请求结束后连同 reply 一起销毁。
    // 之前的方案（共享池 + 每次请求前 clearConnectionCache()）无法保证新连接：
    //   1. clearConnectionCache 只能关闭"已归还到缓存"的空闲连接，而连接在
    //      reply finished 后是异步归还缓存的，降级链中紧接着发起的下一次请求
    //      （guest 重试 / legacy 补救）可能复用尚未归还、已被服务端标记的
    //      连接，被静默按游客处理（HTTP 200 + last_play_time=0），表现为
    //      "启动后只有第一个视频能恢复历史进度"；
    //   2. api.bilibili.com 支持 HTTP/2，同池连接多路复用，清缓存行为更不可控；
    //   3. history/cursor 兜底路径此前完全没清缓存，且与 legacy 共池。
    // 一次性 QNAM 物理上杜绝连接复用（含 TLS 会话复用），是根治手段；
    // playurl 仍走 m_networkManager 共享池，480P 隔离不受影响
    QNetworkAccessManager *manager = new QNetworkAccessManager(this);
    QNetworkReply *reply = manager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, manager, aid, cid, bvid, asGuest, useLegacyEndpoint, fallbackViewPoints]() {
        // 一次性 QNAM：控制权回到事件循环后销毁（reply 是 manager 的子对象，
        // 会一起清理；lambda 内后续对 reply 的读取不受影响）
        manager->deleteLater();
        // 412 风控分层降级：
        //   wbi/v2+Cookie 412 → 老 /x/player/v2 + Cookie，同时起 3 路字幕并发对冲
        //   老 v2 也 412      → history/cursor 翻页找进度（最终兜底）
        //
        // 不再走"游客重试 wbi/v2"那一跳：实测游客请求 wbi/v2 虽然返回 200，
        // 但 subtitle 恒为空列表（无 CC 权限），纯属浪费一次往返
        auto handleBanned = [this, aid, cid, bvid, asGuest, useLegacyEndpoint, fallbackViewPoints]() {
            if (!asGuest && !useLegacyEndpoint) {
                qWarning() << "[PlayUrlManager] player detail banned (412), falling back to legacy /x/player/v2 (+3 hedges)";
                // legacy 的 subtitle 会被概率性投毒（见 getPlayerDetail 注释），
                // 3 路并发 + 主链路 1 路，单轮命中率约 97%
                for (int i = 0; i < 3; ++i)
                    requestSubtitleListViaLegacy(aid, cid, bvid);
                getPlayerDetailImpl(aid, cid, bvid, false, /*useLegacyEndpoint=*/true, fallbackViewPoints);
            } else if (!asGuest && useLegacyEndpoint) {
                qWarning() << "[PlayUrlManager] legacy /x/player/v2 banned (412), falling back to history/cursor";
                getHistoryProgress(aid, cid, fallbackViewPoints);
            } else {
                qWarning() << "[PlayUrlManager] player detail banned (412) even as guest, trying legacy /x/player/v2";
                getPlayerDetailImpl(aid, cid, bvid, false, true, fallbackViewPoints);
            }
        };
        int httpStatus = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (reply->error() != QNetworkReply::NoError) {
            qWarning() << "[PlayUrlManager] player detail network error:" << reply->error()
                       << "httpStatus:" << httpStatus << reply->errorString();
            QByteArray errBody = reply->readAll();
            if (!errBody.isEmpty()) {
                qDebug() << "[PlayUrlManager] player detail error body:" << errBody.left(512);
            }
            // B 站风控两种形态都接进降级链：HTTP 412，或 HTTP 200 + body 含 -412
            if (httpStatus == 412 || errBody.contains("-412")) {
                handleBanned();
            } else {
                // 其他网络错误：emit 空进度 + 透传章节，别让 QML 干等
                QVariantMap failDetail;
                failDetail["aid"] = aid;
                failDetail["cid"] = cid;
                failDetail["lastPlayTime"] = 0;
                failDetail["lastPlayCid"] = "";
                failDetail["viewPoints"] = fallbackViewPoints;
                emit playerDetailReady(failDetail);
            }
            reply->deleteLater();
            return;
        }

        QByteArray data = reply->readAll();

        QJsonDocument doc = QJsonDocument::fromJson(data);
        if (!doc.isObject()) {
            qWarning() << "[PlayUrlManager] player detail invalid JSON, size:" << data.size();
            // 失败也 emit 空进度 + 透传章节：保证 QML 侧总能收到 playerDetailReady
            QVariantMap failDetail;
            failDetail["aid"] = aid;
            failDetail["cid"] = cid;
            failDetail["lastPlayTime"] = 0;
            failDetail["lastPlayCid"] = "";
            failDetail["viewPoints"] = fallbackViewPoints;
            emit playerDetailReady(failDetail);
            reply->deleteLater();
            return;
        }

        QJsonObject root = doc.object();
        if (root["code"].toInt() != 0) {
            int apiCode = root["code"].toInt();
            qWarning() << "[PlayUrlManager] player detail API error:" << apiCode
                     << root["message"].toString();
            // HTTP 200 + JSON code:-412 也是风控（B 站常见形态），同样走降级链
            if (apiCode == -412) {
                handleBanned();
            } else {
                // 其他 API 错误（如 -404/-101）：同样 emit 空进度 + 透传章节，
                // 失败路径必须发完成信号，避免 QML 侧挂等
                QVariantMap failDetail;
                failDetail["aid"] = aid;
                failDetail["cid"] = cid;
                failDetail["lastPlayTime"] = 0;
                failDetail["lastPlayCid"] = "";
                failDetail["viewPoints"] = fallbackViewPoints;
                emit playerDetailReady(failDetail);
            }
            reply->deleteLater();
            return;
        }

        QJsonObject dataObj = root["data"].toObject();

        QVariantMap detail;
        detail["aid"] = aid;
        detail["cid"] = cid;

        // 解析历史播放进度
        // last_play_time 单位为毫秒，直接透传（已对照加入章节功能前的可用版本
        // 核实：同样裸透传且恢复正常。注意 history/cursor 降级路径的 progress
        // 才是秒、在那边 ×1000——两条路径单位不同，勿混淆）
        qint64 lastPlayTime = 0;
        QString lastPlayCid;
        if (dataObj.contains("last_play_time")) {
            lastPlayTime = dataObj["last_play_time"].toVariant().toLongLong();
        }
        if (dataObj.contains("last_play_cid")) {
            lastPlayCid = QString::number(dataObj["last_play_cid"].toVariant().toLongLong());
        }
        detail["lastPlayTime"] = lastPlayTime;
        detail["lastPlayCid"] = lastPlayCid;

        // 解析分段章节（view_points，UP主设置的视频分段）。
        // 章节数据只在此接口返回（/x/web-interface/view 无此字段），
        // 每项含 content(标题)/from(起始秒)/to(结束秒)；无章节为空列表。
        // 老 /x/player/v2 响应若缺 view_points 字段，沿用调用链上游（游客
        // wbi/v2）已解析的章节
        QVariantList viewPointsList;
        if (dataObj.contains("view_points")) {
            const QJsonArray vpArr = dataObj.value("view_points").toArray();
            for (const QJsonValue &v : vpArr) {
                const QJsonObject o = v.toObject();
                if (o.value("content").toString().isEmpty())
                    continue;
                QVariantMap m;
                m["title"] = o.value("content").toString();
                m["from"] = o.value("from").toDouble();
                m["to"] = o.value("to").toDouble();
                viewPointsList.append(m);
            }
        } else {
            viewPointsList = fallbackViewPoints;
        }
        detail["viewPoints"] = viewPointsList;
        if (!viewPointsList.isEmpty())
            qWarning() << "[PlayUrlManager] chapters from player detail:" << viewPointsList.size();

        // 解析字幕轨列表（data.subtitle.subtitles[]）。
        // 注意：这里的字幕**不是权威列表**——它只在提供 subtitle_url 上有用，
        // 而且视频无字幕/被风控时会返回毫不相干的 AI 占位字幕。权威判定在
        // view 接口的 subtitle.list（见 parseVideoSubtitleIds），本处只按 id
        // 匹配补 URL。字段名：lan / lan_doc / subtitle_url / type（type==1 为 AI）
        // 放在进度降级判断之前发射，避免被 last_play_time==0 的重试拖住
        QVariantList subtitleList;
        if (dataObj.contains("subtitle")) {
            // 过滤基准的就绪状态。若 checked=false 说明 view 响应还没到（或没
            // 返回 subtitle 字段），此时不过滤——这行日志用于定位"顺序问题"
            qWarning() << "[PlayUrlManager] subtitle filter state, checked:" << m_videoSubtitleChecked
                       << "listSize:" << m_videoSubtitleList.size()
                       << "bvid:" << m_videoSubtitleBvid << "curBvid:" << bvid;
            const QJsonObject subtitleObj = dataObj.value("subtitle").toObject();
            const QJsonArray subArr = subtitleObj.value("subtitles").toArray();
            for (const QJsonValue &v : subArr) {
                const QJsonObject o = v.toObject();
                const QString subUrl = o.value("subtitle_url").toString();
                if (subUrl.isEmpty())
                    continue;
                QString subId = o.value("id_str").toString();
                if (subId.isEmpty())
                    subId = QString::number(o.value("id").toDouble(), 'f', 0);
                bool isAi = o.value("type").toInt() == 1;
                QString lanDoc = o.value("lan_doc").toString();
                if (lanDoc.isEmpty())
                    lanDoc = o.value("lan").toString();

                // view 权威列表过滤：player 接口返回的每条字幕，其 id 必须能在
                // view 接口的 subtitle.list 里找到，否则丢弃。
                // 两种情况都是脏数据：
                //   1) 视频无字幕（view list 为空）——player 会返回毫不相干的
                //      AI 占位字幕（实测给"一加6评测"返回"大佬K灭门案"字幕）
                //   2) 视频有 CC——player 被风控时只返回 AI 占位轨（id 不匹配）
                // view 未确认过该视频（m_videoSubtitleChecked=false，如请求
                // 失败或番剧路径）时不过滤，避免误杀
                if (m_videoSubtitleChecked
                    && (m_videoSubtitleBvid.isEmpty() || m_videoSubtitleBvid == bvid)) {
                    QVariantMap viewItem;
                    bool found = false;
                    for (const QVariant &lv : m_videoSubtitleList) {
                        const QVariantMap m = lv.toMap();
                        if (m.value("id").toString() == subId) {
                            viewItem = m;
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        qWarning() << "[PlayUrlManager] subtitle dropped (not in view list):"
                                   << "id=" << subId
                                   << "lan=" << o.value("lan").toString()
                                   << "type=" << o.value("type").toInt()
                                   << "ai_status=" << o.value("ai_status").toInt()
                                   << "url=" << subUrl.left(60);
                        continue;
                    }
                    // 标题/类型以 view 为准（player 的 lan_doc 在降级响应里不可信）
                    const QString viewTitle = viewItem.value("title").toString();
                    if (!viewTitle.isEmpty())
                        lanDoc = viewTitle;
                    isAi = viewItem.value("isAi").toBool();
                }
                // AI 字幕补后缀，让用户能看出哪些是机器生成的
                if (isAi && !lanDoc.endsWith(QString::fromUtf8("（AI）")))
                    lanDoc += QString::fromUtf8("（AI）");
                QVariantMap sm;
                sm["lang"] = o.value("lan").toString();
                sm["title"] = lanDoc;
                sm["url"] = subUrl;
                sm["isAi"] = isAi;
                subtitleList.append(sm);
                // 诊断日志：字幕串视频的故障极难定位（服务端会对异常请求返回
                // 毫不相干的占位字幕），打出 id/type/URL 便于与 view 接口的
                // subtitle.list[].id 比对。URL 截断到 80 字符（含 auth_key）
                qWarning() << "[PlayUrlManager] subtitle item:"
                           << "id=" << subId
                           << "lan=" << o.value("lan").toString()
                           << "type=" << o.value("type").toInt()
                           << "ai_status=" << o.value("ai_status").toInt()
                           << "url=" << subUrl.left(80);
            }
            qWarning() << "[PlayUrlManager] subtitles from player detail:" << subtitleList.size();
        }
        // view 说有字幕、这里却一条都没（join 后为空）→ 说明 player 接口被
        // 降级了（只给 AI 占位轨或空），调度重试
        if (subtitleList.isEmpty()) {
            scheduleSubtitleRetry(aid, cid, bvid);
        } else {
            m_subtitleRetryAttempt = 0;   // 拿到内容就清计数
            m_subtitleResolved = true;
        }
        emit subtitleListReady(subtitleList);

        // 拿不到字幕时的补救：仅在**非 legacy 主链路**（即 wbi/v2 分支，已停用）
        // 才需要换端点重试。legacy 就是主链路时，这里重发同一端点纯属浪费——
        // 空列表的情况交给 scheduleSubtitleRetry 按间隔重试
        //
        // 补救条件刻意收得很窄，避免给无字幕视频白加一次请求：
        //   服务端说"有字幕但需要登录"（need_login_subtitle=true）
        //   + 我们确实已登录 + 却仍拿到空列表
        // 三者同时成立才说明是被网关了，而不是真没有字幕。
        // 游客身份下 need_login_subtitle=true 是正常的（就是不给看），不补救
        if (subtitleList.isEmpty()
            && !useLegacyEndpoint
            && dataObj.value("need_login_subtitle").toBool()
            && LoginManager::instance()->isLoggedIn()) {
            qWarning() << "[PlayUrlManager] player detail returned no subtitle but need_login_subtitle=true, retrying via legacy /x/player/v2";
            requestSubtitleListViaLegacy(aid, cid, bvid);
        }

        qWarning() << "[PlayUrlManager] playerDetail:" << "lastPlayTime=" << lastPlayTime
                 << "lastPlayCid=" << lastPlayCid;

        // 拿到 0 进度的两种情形都补救（last_play_time 仅登录 Cookie 请求返回）：
        //   1. 游客重试成功：登录态历史进度被游客身份丢掉
        //   2. 带 Cookie 却被静默按游客处理：复用连接被标记的另一形态
        //      （非 412、HTTP 200，与 480P 风控同源）
        // 两者都先走老 /x/player/v2 + Cookie 补救（同源数据、独立连接池、
        // 浏览器风格头，被连带风控的概率低）；viewPoints 一并传递，避免降级
        // emit 把 QML 侧章节覆盖为空。legacy 路径自身除外，防止循环重试
        if (lastPlayTime == 0 && !useLegacyEndpoint) {
            qWarning() << "[PlayUrlManager] no progress (guest-degraded?), trying legacy /x/player/v2 with cookies";
            getPlayerDetailImpl(aid, cid, bvid, false, true, viewPointsList);
            reply->deleteLater();
            return;
        }

        // legacy 补救也拿到 0：这是"带 Cookie 却被静默按游客处理"的最后一种
        // 形态（非 412、HTTP 200、last_play_time=0）。此前这里直接放弃导致
        // 第二个视频从头播放；现在落到 history/cursor 最终兜底（与历史列表
        // 页同源，登录态数据最可靠）。history/cursor 不会再回调
        // getPlayerDetailImpl，链路在此终结，无循环风险
        if (lastPlayTime == 0 && useLegacyEndpoint) {
            qWarning() << "[PlayUrlManager] legacy /x/player/v2 still no progress, falling back to history/cursor";
            getHistoryProgress(aid, cid, viewPointsList);
            reply->deleteLater();
            return;
        }

        emit playerDetailReady(detail);
        reply->deleteLater();
    });
}

// 只用 legacy /x/player/v2 补取字幕列表（不动进度/章节）。
//
// 用途：主链路（同样是 legacy）拿到的字幕列表为空时，由 scheduleSubtitleRetry
// 按间隔重试、以及 wbi/v2 分支的补救逻辑调用。单发这个请求比重入
// getPlayerDetailImpl 更轻，也不会重复动进度/章节状态。
//
// 这个请求**不影响主链路**：失败/无字幕都只是不发信号或发空列表，
// 由 QML 侧的"空列表不覆盖非空列表"守卫兜底
void PlayUrlManager::requestSubtitleListViaLegacy(const QString &aid, const QString &cid, const QString &bvid)
{
    // 已经拿到字幕轨就不再发请求。放在最前面是为了省掉一次无意义的网络往返：
    // 并发对冲时后到的几路、以及已解决后仍到期的重试定时器，都会走到这里
    if (m_subtitleResolved)
        return;

    QString params = bvid.isEmpty()
                         ? QString("aid=%1&cid=%2").arg(aid, cid)
                         : QString("aid=%1&cid=%2&bvid=%3").arg(aid, cid, bvid);
    QUrl reqUrl(QString("https://api.bilibili.com/x/player/v2?%1").arg(params));
    QNetworkRequest request(reqUrl);
    // HTTP/2 保持默认（由 main.cpp 的 ALPN 白名单决定），见 getPlayerDetailImpl
    // 里的更正说明——h2 本身没问题，此前误判为 412 根源。
    // 不复用连接（同 getPlayerDetailImpl：B站按连接维度做风控标记）
    request.setAttribute(QNetworkRequest::ConnectionCacheExpiryTimeoutSecondsAttribute, 0);
    // 浏览器风格头：这是实测能返回 subtitle 字段的组合
    request.setRawHeader(QByteArray("User-Agent"), USER_AGENT.toUtf8());
    request.setRawHeader(QByteArray("Referer"), REFERER.toUtf8());
    request.setRawHeader(QByteArray("Origin"), ORIGIN.toUtf8());
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));
    // 同主链路：不发 Connection: close（一次性 QNAM 已保证不复用，且 h2 下非法）

    // 防 412 风控：与主链路 getPlayerDetailImpl 保持**完全一致**的头部。
    // 这里踩过一个极隐蔽的坑（用户日志，BV1DzpG6CEEH）：同一个 URL、同一个
    // Cookie、同一个 UA，只差 Origin/buvid 头，服务端返回的字幕完全不同——
    //   带 Origin+buvid → 当前视频的人工 CC 字幕（id 与 view 接口一致）
    //   缺 Origin+buvid → 一个**毫不相干的 AI 占位字幕**
    //     （lan=ai-zh, type=1, ai_status=2, URL 在 ai_subtitle/prod/ 下）
    // 所以补救请求的头部不能省，省了会比不补救更糟——把正确字幕覆盖成脏数据
    LoginManager *loginMgr = LoginManager::instance();
    loginMgr->ensureServerBuvid3();
    QString buvid3 = loginMgr->getOrCreateBuvid3();
    if (!buvid3.isEmpty()) {
        request.setRawHeader(QByteArray("buvid"), buvid3.toUtf8());
    }

    QString cookies = loginMgr->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    QNetworkAccessManager *manager = new QNetworkAccessManager(this);
    QNetworkReply *reply = manager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, manager, aid, cid, bvid]() {
        manager->deleteLater();
        QByteArray data = reply->readAll();
        reply->deleteLater();

        // 入口并行预取会同时发两个请求，先到的拿到字幕后就置 resolved，
        // 后到的直接丢弃（省一次解析，也避免重复 emit）
        if (m_subtitleResolved) {
            qDebug() << "[PlayUrlManager] subtitle legacy response ignored (already resolved)";
            return;
        }
        // 迟到的响应：期间已切到别的视频，丢弃防止污染新视频的字幕列表。
        // 必须带 m_videoSubtitleChecked 条件——view 响应还没到时该字段恒为
        // false，若只看 bvid 不匹配会把**当前视频**的响应误杀（bvid 还是
        // 上一个视频的残留值）
        if (m_videoSubtitleChecked && !m_videoSubtitleBvid.isEmpty()
            && m_videoSubtitleBvid != bvid) {
            qDebug() << "[PlayUrlManager] subtitle legacy response ignored (video changed to"
                     << m_videoSubtitleBvid << ")";
            return;
        }

        QVariantList subtitleList;
        QJsonDocument doc = QJsonDocument::fromJson(data);
        if (doc.isObject()) {
            const QJsonObject dataObj = doc.object().value("data").toObject();
            const QJsonObject subtitleObj = dataObj.value("subtitle").toObject();
            const QJsonArray subArr = subtitleObj.value("subtitles").toArray();
            for (const QJsonValue &v : subArr) {
                const QJsonObject o = v.toObject();
                const QString subUrl = o.value("subtitle_url").toString();
                if (subUrl.isEmpty())
                    continue;
                // view 权威列表过滤，同主链路：风控时 legacy 端点也会返回
                // 毫不相干的占位字幕，只放行 id 能在 view list 里找到的
                QString subId = o.value("id_str").toString();
                if (subId.isEmpty())
                    subId = QString::number(o.value("id").toDouble(), 'f', 0);
                bool isAi = o.value("type").toInt() == 1;
                QString lanDoc = o.value("lan_doc").toString();
                if (lanDoc.isEmpty())
                    lanDoc = o.value("lan").toString();
                if (m_videoSubtitleChecked
                    && (m_videoSubtitleBvid.isEmpty() || m_videoSubtitleBvid == bvid)) {
                    QVariantMap viewItem;
                    bool found = false;
                    for (const QVariant &lv : m_videoSubtitleList) {
                        const QVariantMap m = lv.toMap();
                        if (m.value("id").toString() == subId) {
                            viewItem = m;
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        qWarning() << "[PlayUrlManager] subtitle dropped (legacy fallback, not in view list):"
                                   << "id=" << subId
                                   << "lan=" << o.value("lan").toString()
                                   << "type=" << o.value("type").toInt()
                                   << "ai_status=" << o.value("ai_status").toInt()
                                   << "url=" << subUrl.left(60);
                        continue;
                    }
                    const QString viewTitle = viewItem.value("title").toString();
                    if (!viewTitle.isEmpty())
                        lanDoc = viewTitle;
                    isAi = viewItem.value("isAi").toBool();
                }
                if (isAi && !lanDoc.endsWith(QString::fromUtf8("（AI）")))
                    lanDoc += QString::fromUtf8("（AI）");
                QVariantMap sm;
                sm["lang"] = o.value("lan").toString();
                sm["title"] = lanDoc;
                sm["url"] = subUrl;
                sm["isAi"] = isAi;
                subtitleList.append(sm);
                // 诊断日志同主链路：用于核对 id/type 是否属于当前视频
                qWarning() << "[PlayUrlManager] subtitle item (legacy fallback):"
                           << "id=" << subId
                           << "lan=" << o.value("lan").toString()
                           << "type=" << o.value("type").toInt()
                           << "ai_status=" << o.value("ai_status").toInt()
                           << "url=" << subUrl.left(80);
            }
        }
        qWarning() << "[PlayUrlManager] subtitles via legacy fallback:" << subtitleList.size();
        if (!subtitleList.isEmpty()) {
            m_subtitleRetryAttempt = 0;
            m_subtitleResolved = true;
            emit subtitleListReady(subtitleList);
        } else {
            // 补救也没拿到 → 继续重试（上限见 m_subtitleMaxRetry）
            scheduleSubtitleRetry(aid, cid, bvid);
        }
    });
}

// 字幕轨为空但有权威列表时的重试调度。
//
// 为什么需要（用户日志，BV1DzpG6CEEH）：
//   view 接口稳定说"该视频有 1 条字幕"，但 player 接口在风控灰度下
//   **不报错也不返回空**，而是只返回毫不相干的 AI 占位轨（ai-zh/ai_status=2），
//   不含真正的 CC 轨。于是 join 结果为空，用户看到"有字幕的视频反复打开
//   重试才会有字幕选项出现"——本质是服务端随机降级，重试能命中。
//
// 设计：
//   - 只在 view 已确认"该视频有字幕"时重试，避免给无字幕视频空转
//   - 按 bvid 独立计数，换视频自动重置
//   - 时间窗口去重：同一次打开会从主链路和 fallback 各触发一次，
//     800ms 内的重复调度只算一次，避免 attempt 被快速耗尽
//   - 指数退避（0.7s / 1.4s / 2.1s ...），最多 m_subtitleMaxRetry 次
//   - 重试只走 requestSubtitleListViaLegacy 单请求，不重入 getPlayerDetailImpl
//     的降级链（那条链会再次触发 fallback，导致请求风暴）
void PlayUrlManager::scheduleSubtitleRetry(const QString &aid, const QString &cid, const QString &bvid)
{
    // 无权威列表（view 说没字幕 / 没确认过）时不重试
    if (!m_videoSubtitleChecked || m_videoSubtitleList.isEmpty())
        return;
    // 已经拿到字幕轨了，后续降级响应返回空不必再试
    if (m_subtitleResolved)
        return;
    // 已经不是当前视频了
    if (!m_videoSubtitleBvid.isEmpty() && m_videoSubtitleBvid != bvid)
        return;

    if (m_subtitleRetryBvid != bvid) {
        // 换了视频，重置计数与去重时间戳
        m_subtitleRetryBvid = bvid;
        m_subtitleRetryAttempt = 0;
        m_subtitleRetryLastMs = 0;
    }

    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (m_subtitleRetryLastMs > 0 && now - m_subtitleRetryLastMs < 800)
        return;   // 同一次打开的重复触发，丢弃

    if (m_subtitleRetryAttempt >= m_subtitleMaxRetry) {
        qWarning() << "[PlayUrlManager] subtitle retry exhausted, giving up. bvid:" << bvid
                   << "attempts:" << m_subtitleRetryAttempt;
        return;
    }

    ++m_subtitleRetryAttempt;
    m_subtitleRetryLastMs = now;
    // 首次 400ms 起、每次 +400ms。比 700ms 起步更快出结果，又不至于把
    // 服务端打成高频（灰度降级本来就是概率性放行，间隔太小收益递减）
    const int delay = 400 * m_subtitleRetryAttempt;
    qWarning() << "[PlayUrlManager] subtitle URL missing (view says has subtitle), retry"
               << m_subtitleRetryAttempt << "/" << m_subtitleMaxRetry
               << "in" << delay << "ms. bvid:" << bvid;
    QTimer::singleShot(delay, this, [this, aid, cid, bvid]() {
        // 延迟期间可能已切视频，校验后放弃
        if (!m_videoSubtitleBvid.isEmpty() && m_videoSubtitleBvid != bvid) {
            qDebug() << "[PlayUrlManager] subtitle retry skipped, video changed to"
                     << m_videoSubtitleBvid;
            return;
        }
        requestSubtitleListViaLegacy(aid, cid, bvid);
    });
}

// 降级方案：通过 /x/web-interface/history/cursor 获取视频观看进度
// 当 /x/player/v2（player detail 主链路）被风控拦截、或返回 0 进度时的最终兜底。
// history/cursor 每页只返回最近 ps=30 条，目标视频可能埋得更深，
// 故按 cursor 翻页查找，最多 maxHistoryPages 页
static const int maxHistoryPages = 5;
void PlayUrlManager::getHistoryProgress(const QString &aid, const QString &cid,
                                        const QVariantList &viewPoints)
{
    qWarning() << "[PlayUrlManager] getHistoryProgress fallback aid:" << aid << "cid:" << cid;
    fetchHistoryCursorPage(aid, cid, viewPoints, 0, 0, 1);
}

void PlayUrlManager::fetchHistoryCursorPage(const QString &aid, const QString &cid,
                                            const QVariantList &viewPoints, qint64 max, qint64 viewAt, int page)
{
    // 使用 /x/web-interface/history/cursor（与 ApiManager::getHistoryList 相同，无需 WBI 签名）
    QString url = "https://api.bilibili.com/x/web-interface/history/cursor";
    QString params = QString("max=%1&view_at=%2&ps=30").arg(max).arg(viewAt);

    QUrl reqUrl(url + "?" + params);
    QNetworkRequest request(reqUrl);
    // HTTP/2 保持默认（main.cpp 的 ALPN 白名单），见 getPlayerDetailImpl 里的
    // 更正说明：h2 与 http/1.1 都能正常工作，不必强制关掉。
    // 不复用连接（同 getPlayerDetailImpl：B站按连接维度做风控标记）
    request.setAttribute(QNetworkRequest::ConnectionCacheExpiryTimeoutSecondsAttribute, 0);
    request.setRawHeader("User-Agent", USER_AGENT.toUtf8());
    request.setRawHeader("Referer", REFERER.toUtf8());
    request.setRawHeader("Origin", ORIGIN.toUtf8());
    request.setRawHeader("Accept", "application/json, text/plain, */*");

    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    qWarning() << "[PlayUrlManager] history/cursor page" << page << "request:" << params
             << "cookieLen:" << cookies.size();

    // 一次性 QNAM：每页请求新建网络管理器，用完连同 reply 一起销毁，
    // 物理上杜绝复用被服务端标记的连接（与 getPlayerDetailImpl 同一策略）
    QNetworkAccessManager *manager = new QNetworkAccessManager(this);
    QNetworkReply *reply = manager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, manager, aid, cid, viewPoints, page]() {
        // 一次性 QNAM：控制权回到事件循环后销毁（reply 是其子对象）
        manager->deleteLater();
        // 失败时也 emit（lastPlayTime=0 + 透传章节）：保证 QML 侧总能收到
        // playerDetailReady，章节不因降级失败而丢失
        QVariantMap failDetail;
        failDetail["aid"] = aid;
        failDetail["cid"] = cid;
        failDetail["lastPlayTime"] = 0;
        failDetail["lastPlayCid"] = "";
        failDetail["viewPoints"] = viewPoints;

        int httpStatus = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (reply->error() != QNetworkReply::NoError) {
            qWarning() << "[PlayUrlManager] history/cursor error:" << reply->error()
                     << "httpStatus:" << httpStatus << reply->errorString();
            emit playerDetailReady(failDetail);
            reply->deleteLater();
            return;
        }

        QByteArray data = reply->readAll();

        QJsonDocument doc = QJsonDocument::fromJson(data);
        if (!doc.isObject()) {
            qWarning() << "[PlayUrlManager] history/cursor invalid JSON, size:" << data.size();
            emit playerDetailReady(failDetail);
            reply->deleteLater();
            return;
        }

        QJsonObject root = doc.object();
        if (root["code"].toInt() != 0) {
            qWarning() << "[PlayUrlManager] history/cursor API error:" << root["code"].toInt()
                     << root["message"].toString();
            emit playerDetailReady(failDetail);
            reply->deleteLater();
            return;
        }

        QVariantMap detail;
        detail["aid"] = aid;
        detail["cid"] = cid;
        detail["lastPlayTime"] = 0;
        detail["lastPlayCid"] = "";
        // viewPoints 由调用方透传（游客补救场景带真实章节）；独立降级场景为
        // 空列表，与主路径信号结构一致，避免 QML 侧 undefined 语义歧义
        detail["viewPoints"] = viewPoints;

        QJsonObject dataObj = root["data"].toObject();
        QJsonArray list = dataObj["list"].toArray();
        bool found = false;
        for (const QJsonValue &item : list) {
            QJsonObject obj = item.toObject();
            // history/cursor 返回的结构：list[].history.oid/cid
            if (!obj.contains("history")) continue;
            QJsonObject historyObj = obj["history"].toObject();

            QString itemAid;
            if (historyObj.contains("oid")) {
                itemAid = QString::number(historyObj["oid"].toVariant().toLongLong());
            } else if (historyObj.contains("aid")) {
                itemAid = QString::number(historyObj["aid"].toVariant().toLongLong());
            }
            QString itemCid = QString::number(historyObj["cid"].toVariant().toLongLong());

            if (itemAid == aid && itemCid == cid) {
                // progress/duration 可能在 history 内部或顶层
                int progress = 0;
                int duration = 0;
                if (historyObj.contains("progress")) {
                    progress = historyObj["progress"].toInt();
                } else if (obj.contains("progress")) {
                    progress = obj["progress"].toInt();
                }
                if (historyObj.contains("duration")) {
                    duration = historyObj["duration"].toInt();
                } else if (obj.contains("duration")) {
                    duration = obj["duration"].toInt();
                }

                qint64 lastPlayTime = static_cast<qint64>(progress) * 1000;
                detail["lastPlayTime"] = lastPlayTime;
                detail["lastPlayCid"] = cid;
                qWarning() << "[PlayUrlManager] history/cursor FOUND match at page" << page
                         << "progress=" << progress << "duration=" << duration
                         << "lastPlayTime=" << lastPlayTime;
                found = true;
                break;
            }
        }

        if (found) {
            emit playerDetailReady(detail);
            reply->deleteLater();
            return;
        }

        // 本页没找到：用响应里的 cursor 翻下一页（list 空说明历史翻完了）
        QJsonObject cursor = dataObj["cursor"].toObject();
        qint64 nextMax = cursor["max"].toVariant().toLongLong();
        qint64 nextViewAt = cursor["view_at"].toVariant().toLongLong();
        if (page < maxHistoryPages && !list.isEmpty() && nextMax > 0) {
            qWarning() << "[PlayUrlManager] history/cursor not in page" << page
                     << "(" << list.size() << "items ), fetching page" << page + 1;
            reply->deleteLater();
            fetchHistoryCursorPage(aid, cid, viewPoints, nextMax, nextViewAt, page + 1);
            return;
        }

        qWarning() << "[PlayUrlManager] history/cursor result: not found in" << page << "page(s), lastPlayTime=0";
        emit playerDetailReady(detail);
        reply->deleteLater();
    });
}

QString PlayUrlManager::getSign(const QString &params)
{
    // 签名算法与ApiManager相同
    QString toSign = params;
    
    QStringList paramList = toSign.split("&");
    paramList.sort();
    QString sortedParams = paramList.join("&");
    
    QString signSource = sortedParams + APP_SECRET;
    
    QCryptographicHash hash(QCryptographicHash::Md5);
    hash.addData(signSource.toUtf8());
    QString sign = hash.result().toHex().toLower();
    
    return "&sign=" + sign;
}

// 获取相关视频
void PlayUrlManager::getRelatedVideos(const QString &aid)
{
    qDebug() << "[PlayUrlManager] getRelatedVideos aid:" << aid;
    // 使用专门的相关视频推荐API
    QString url = QString("https://api.bilibili.com/x/web-interface/archive/related?aid=%1")
                      .arg(aid);

    QUrl reqUrl(url);
    QNetworkRequest request(reqUrl);
    request.setRawHeader("User-Agent", USER_AGENT.toUtf8());
    request.setRawHeader("Referer", REFERER.toUtf8());
    request.setRawHeader("Origin", ORIGIN.toUtf8());
    request.setRawHeader("Accept", "application/json, text/plain, */*");

    // 添加 Cookie（包含 buvid3，关键的反爬虫标识）
    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }


    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, aid]() {
        if (reply->error() != QNetworkReply::NoError) {
            // 不触发全局错误，只返回空列表
            emit relatedVideosReady(QVariantList());
            reply->deleteLater();
            return;
        }

        QByteArray data = reply->readAll();
        QJsonDocument doc = QJsonDocument::fromJson(data);
        if (!doc.isObject()) {
            emit relatedVideosReady(QVariantList());
            reply->deleteLater();
            return;
        }

        QJsonObject root = doc.object();
        if (root["code"].toInt() != 0) {
            emit relatedVideosReady(QVariantList());
            reply->deleteLater();
            return;
        }

        // 解析相关视频列表（related接口返回的是数组直接在data字段）
        QList<VideoCardInfo> videos;
        QJsonArray relatedArray = root["data"].toArray();
        for (int i = 0; i < relatedArray.size(); ++i) {
            QJsonObject item = relatedArray[i].toObject();
            VideoCardInfo video;
            video.aid = QString::number(item["aid"].toVariant().toLongLong());
            video.bvid = item["bvid"].toString();
            video.title = item["title"].toString();
            video.pic = item["pic"].toString();
            video.author = item["owner"].toObject()["name"].toString();
            video.mid = item["owner"].toObject()["mid"].toVariant().toLongLong();
            QJsonObject stat = item["stat"].toObject();
            video.play = stat["view"].toVariant().toLongLong();
            video.danmaku = stat["danmaku"].toVariant().toLongLong();
            video.like = stat["like"].toVariant().toLongLong();
            video.duration = item["duration"].toInt();
            video.pubdate = item["pubdate"].toVariant().toLongLong();
            // 解析推荐标签（相关视频接口可能返回 rcmd_reason）
            QJsonValue rcmdReasonVal = item["rcmd_reason"];
            if (rcmdReasonVal.isString()) {
                video.badgeText = rcmdReasonVal.toString();
            } else if (rcmdReasonVal.isObject()) {
                video.badgeText = rcmdReasonVal.toObject()["content"].toString();
            }
            videos.append(video);
        }

        QVariantList result;
        result.reserve(videos.size());
        for (const VideoCardInfo &video : videos) {
            result.append(videoCardToMap(video));
        }
        qDebug() << "[PlayUrlManager] relatedVideosReady count:" << result.size();
        emit relatedVideosReady(result);

        reply->deleteLater();
    });
}

void PlayUrlManager::getBangumiRecommendations(const QString &seasonId)
{
    qDebug() << "[PlayUrlManager] getBangumiRecommendations (related/recommend API) seasonId:" << seasonId;
    // 参考 wiliwili SeasonRCMD：/pgc/season/web/related/recommend
    // 返回"相关番剧推荐"（不是当前番剧的分集列表），包含评分、追番数、播放量、更新进度等字段
    QString url = QString("https://api.bilibili.com/pgc/season/web/related/recommend?season_id=%1")
                      .arg(seasonId);

    QUrl reqUrl(url);
    QNetworkRequest request(reqUrl);
    request.setRawHeader("User-Agent", USER_AGENT.toUtf8());
    request.setRawHeader("Referer", REFERER.toUtf8());
    request.setRawHeader("Origin", ORIGIN.toUtf8());
    request.setRawHeader("Accept", "application/json, text/plain, */*");

    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, seasonId]() {
        if (reply->error() != QNetworkReply::NoError) {
            qDebug() << "[PlayUrlManager] getBangumiRecommendations error:" << reply->errorString();
            emit relatedVideosReady(QVariantList());
            reply->deleteLater();
            return;
        }

        QByteArray data = reply->readAll();
        QJsonDocument doc = QJsonDocument::fromJson(data);
        if (!doc.isObject()) {
            emit relatedVideosReady(QVariantList());
            reply->deleteLater();
            return;
        }

        QJsonObject root = doc.object();
        if (root["code"].toInt() != 0) {
            qDebug() << "[PlayUrlManager] getBangumiRecommendations code:" << root["code"].toInt()
                     << "msg:" << root["message"].toString();
            emit relatedVideosReady(QVariantList());
            reply->deleteLater();
            return;
        }

        QList<VideoCardInfo> videos;
        // related/recommend API 返回结构：data -> items[]
        QJsonObject dataObj = root.value("data").toObject();
        QJsonArray items;
        if (dataObj.contains("items")) {
            items = dataObj.value("items").toArray();
        } else if (dataObj.contains("season")) {
            // 兼容 wiliwili SeasonRecommendWrapper.season 字段
            items = dataObj.value("season").toArray();
        } else if (root.contains("result")) {
            // 部分版本顶层 result
            QJsonObject resultObj = root.value("result").toObject();
            if (resultObj.contains("items")) items = resultObj.value("items").toArray();
            else if (resultObj.contains("season")) items = resultObj.value("season").toArray();
        }

        if (items.isEmpty()) {
            // related/recommend 返回空，简单打印调试
            qDebug() << "[PlayUrlManager] getBangumiRecommendations: items empty, raw data keys:"
                     << dataObj.keys() << "top-level keys:" << root.keys();
            emit relatedVideosReady(QVariantList());
            reply->deleteLater();
            return;
        }

        // 最多取 30 条作为推荐
        int limit = qMin(items.size(), 30);
        for (int i = 0; i < limit; ++i) {
            QJsonObject item = items[i].toObject();
            VideoCardInfo video;
            video.isBangumiCard = true;  // 标记为番剧推荐卡片

            // 基础字段
            video.seasonId = QString::number(item["season_id"].toVariant().toLongLong());
            if (video.seasonId.isEmpty() || video.seasonId == "0")
                video.seasonId = item["season_id_str"].toString();
            video.epId = QString::number(item["ep_id"].toVariant().toLongLong());
            if (video.epId.isEmpty() || video.epId == "0")
                video.epId = item["ep_id_str"].toString();
            video.aid = QString::number(item["aid"].toVariant().toLongLong());
            video.bvid = item["bvid"].toString();
            video.cid = QString::number(item["cid"].toVariant().toLongLong());

            // 标题 & 封面
            video.title = item["title"].toString();
            video.pic = item["cover"].toString();
            if (video.pic.isEmpty()) video.pic = item["horizontal_picture"].toString();
            if (video.pic.isEmpty()) video.pic = item["square_picture"].toString();
            video.seasonTitle = video.title;

            // 播放量 & 追番数（对应 wiliwili d.stat.view / d.stat.follow）
            QJsonObject stat = item["stat"].toObject();
            if (!stat.isEmpty()) {
                video.play = stat["view"].toVariant().toLongLong();
                video.follow = stat["follow"].toVariant().toLongLong();
                video.danmaku = stat["danmakus"].toVariant().toLongLong();
            } else {
                // 顶层兜底
                video.play = item["view"].toVariant().toLongLong();
                video.follow = item["follow"].toVariant().toLongLong();
                if (video.follow == 0) video.follow = item["favorites"].toVariant().toLongLong();
            }

            // 评分：wiliwili d.score
            double score = 0;
            if (item.contains("rating")) {
                QJsonObject rating = item["rating"].toObject();
                score = rating["score"].toDouble();
            }
            if (score <= 0 && item.contains("score"))
                score = item["score"].toDouble();
            video.score = score;

            // 更新进度信息（对应"更新至第X话"、"全X话"）
            QString updateInfo;
            if (item.contains("new_ep")) {
                QJsonObject newEp = item["new_ep"].toObject();
                QString indexShow = newEp["index_show"].toString();   // 如 "更新至第12话" / "全12话"
                if (!indexShow.isEmpty()) updateInfo = indexShow;
                else {
                    qlonglong epIdx = newEp["id"].toVariant().toLongLong();
                    if (epIdx > 0) updateInfo = QString("第%1话").arg(epIdx);
                }
            }
            if (updateInfo.isEmpty() && item.contains("progress")) {
                updateInfo = item["progress"].toString();
            }
            if (updateInfo.isEmpty()) {
                // 兜底：用 total_ep（总集数） 组合展示
                qlonglong total = item["total_ep"].toVariant().toLongLong();
                qlonglong finishedPgc = item["is_finish"].toVariant().toLongLong();
                qlonglong nowEp = item["now_ep"].toVariant().toLongLong();
                if (nowEp > 0 && finishedPgc == 0 && total > 0)
                    updateInfo = QString("更新至第%1话").arg(nowEp);
                else if (finishedPgc == 1 && total > 0)
                    updateInfo = QString("全%1话").arg(total);
            }
            video.updateInfo = updateInfo;
            // 把"更新进度"放在原 author 的位置，QML 里会先读取 updateInfo，空时回落到 author
            video.author = updateInfo;

            if (!video.title.isEmpty() && !video.seasonId.isEmpty() && video.seasonId != "0") {
                videos.append(video);
            }
        }

        QVariantList resultList;
        resultList.reserve(videos.size());
        for (const VideoCardInfo &v : videos) {
            resultList.append(videoCardToMap(v));
        }
        qDebug() << "[PlayUrlManager] bangumi (related/recommend) recommendations count:" << resultList.size();
        emit relatedVideosReady(resultList);

        reply->deleteLater();
    });
}

// 获取UP主投稿列表
void PlayUrlManager::getUserUploadedVideos(const QString &mid, int pn, int ps)
{
    qDebug() << "[PlayUrlManager] getUserUploadedVideos mid:" << mid << "pn:" << pn << "ps:" << ps;
    // 参考 biliuwp-lite：正常浏览使用 APP 接口 x/v2/space/archive/cursor，未登录也能稳定获取
    QString baseUrl = "https://app.bilibili.com/x/v2/space/archive/cursor";

    LoginManager *loginMgr = LoginManager::instance();
    QString ts = generateTimestamp();
    QString params = QString("appkey=%1&build=75900200&mobi_app=android&platform=android&ts=%2")
                         .arg(APP_KEY).arg(ts);

    // 已登录时带上 access_key（biliuwp-lite 的 MustParameter 行为）
    if (loginMgr->isLoggedIn()) {
        QString accessKey = loginMgr->getCurrentUser().accessKey;
        if (!accessKey.isEmpty()) {
            params += "&access_key=" + accessKey;
        }
    }

    params += QString("&vmid=%1&ps=%2&order=pubdate").arg(mid).arg(ps);

    // APP 接口使用 aid 游标分页：pn=1 重置游标，pn>1 使用上一页最后一个 aid
    if (pn > 1) {
        QString cursor = m_userUploadCursorMap.value(mid);
        if (!cursor.isEmpty()) {
            params += "&aid=" + cursor;
        }
    } else {
        m_userUploadCursorMap.remove(mid);
    }

    QString signedParams = params + getSign(params);
    QString fullUrl = baseUrl + "?" + signedParams;

    QUrl reqUrl(fullUrl);
    QNetworkRequest request(reqUrl);
    request.setRawHeader("User-Agent", USER_AGENT.toUtf8());
    request.setRawHeader("Referer", QString("https://space.bilibili.com/%1/video").arg(mid).toUtf8());
    request.setRawHeader("Origin", ORIGIN.toUtf8());
    request.setRawHeader("Accept", "application/json, text/plain, */*");
    request.setRawHeader("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8");

    // 兜底：带上 buvid3 cookie，作为设备/反爬虫标识
    QString cookies = loginMgr->getCookies();
    if (cookies.isEmpty() || !cookies.contains("buvid3")) {
        QString buvid3 = loginMgr->getOrCreateBuvid3();
        if (cookies.isEmpty()) {
            cookies = "buvid3=" + buvid3;
        } else {
            cookies += "; buvid3=" + buvid3;
        }
    }
    request.setRawHeader("Cookie", cookies.toUtf8());

    qDebug() << "[PlayUrlManager] getUserUploadedVideos sending APP request:" << fullUrl;
    qDebug() << "[PlayUrlManager] getUserUploadedVideos cookie:" << cookies;
    QNetworkReply *reply = m_networkManager->get(request);
    qDebug() << "[PlayUrlManager] getUserUploadedVideos reply ptr:" << reinterpret_cast<quintptr>(reply);
    if (!reply) {
        qDebug() << "[PlayUrlManager] getUserUploadedVideos reply is null, aborting";
        emit userUploadedVideosReady(QVariantList(), pn, -1);
        return;
    }
    connect(reply, &QNetworkReply::finished, this, [this, reply, mid, pn, ps]() {
        qDebug() << "[PlayUrlManager] getUserUploadedVideos lambda finished start";
        int httpStatus = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        qDebug() << "[PlayUrlManager] getUserUploadedVideos HTTP status:" << httpStatus;
        if (reply->error() != QNetworkReply::NoError) {
            qDebug() << "[PlayUrlManager] getUserUploadedVideos network error:" << reply->error()
                     << reply->errorString() << "raw headers:" << reply->rawHeaderList();
            emit userUploadedVideosReady(QVariantList(), pn, -1);
            reply->deleteLater();
            return;
        }

        QByteArray data = reply->readAll();
        qDebug() << "[PlayUrlManager] getUserUploadedVideos raw response size:" << data.size();
        QJsonDocument doc = QJsonDocument::fromJson(data);
        if (!doc.isObject()) {
            qDebug() << "[PlayUrlManager] getUserUploadedVideos response is not JSON object:" << data.left(200);
            emit userUploadedVideosReady(QVariantList(), pn, -1);
            reply->deleteLater();
            return;
        }

        QJsonObject root = doc.object();
        int code = root["code"].toInt();
        qDebug() << "[PlayUrlManager] getUserUploadedVideos response code:" << code
                 << "message:" << root["message"].toString();
        if (code != 0) {
            qDebug() << "[PlayUrlManager] getUserUploadedVideos error response:" << data;
            QString msg = root["message"].toString();
            if (msg.contains("频繁") || msg.contains("-799")) {
                emit userUploadedVideosReady(QVariantList(), pn, -2);
            } else {
                emit userUploadedVideosReady(QVariantList(), pn, -1);
            }
            reply->deleteLater();
            return;
        }

        QJsonObject dataObj = root["data"].toObject();
        qDebug() << "[PlayUrlManager] getUserUploadedVideos data keys:" << dataObj.keys();

        // APP 接口格式：data.item[]
        QList<VideoCardInfo> videos;
        QJsonArray itemArray = dataObj["item"].toArray();

        for (int i = 0; i < itemArray.size(); ++i) {
            QJsonObject item = itemArray[i].toObject();
            VideoCardInfo video;
            video.aid = item["param"].toString();  // APP 接口 aid 在 param 字段
            video.bvid = item["bvid"].toString();
            video.title = item["title"].toString();
            video.pic = item["cover"].toString();
            video.author = item["author"].toString();
            video.mid = mid.toLongLong();

            QJsonValue playVal = item["play"];
            if (playVal.isString()) {
                QString playStr = playVal.toString();
                video.play = (playStr == "--") ? 0 : playStr.toLongLong();
            } else {
                video.play = playVal.toVariant().toLongLong();
            }

            QJsonValue danmakuVal = item["danmaku"];
            if (danmakuVal.isString()) {
                QString danmakuStr = danmakuVal.toString();
                video.danmaku = (danmakuStr == "--") ? 0 : danmakuStr.toLongLong();
            } else {
                video.danmaku = danmakuVal.toVariant().toLongLong();
            }

            video.duration = item["duration"].toVariant().toLongLong();
            video.like = 0;  // 该接口没有点赞数据
            video.pubdate = item["ctime"].toVariant().toLongLong();

            // 解析推荐标签（保留兼容）
            QJsonValue upRcmdReasonVal = item["rcmd_reason"];
            if (upRcmdReasonVal.isString()) {
                video.badgeText = upRcmdReasonVal.toString();
            } else if (upRcmdReasonVal.isObject()) {
                video.badgeText = upRcmdReasonVal.toObject()["content"].toString();
            }

            videos.append(video);
        }

        // 保存最后一个 aid 作为下一页游标
        if (!videos.isEmpty()) {
            m_userUploadCursorMap[mid] = videos.last().aid;
        }

        // 分页信息：data.count
        int totalCount = dataObj["count"].toInt();
        int totalPages = (totalCount + ps - 1) / ps;
        if (totalPages <= 0) totalPages = 1;

        QVariantList result;
        result.reserve(videos.size());
        for (const VideoCardInfo &video : videos) {
            result.append(videoCardToMap(video));
        }
        qDebug() << "[PlayUrlManager] userUploadedVideosReady count:" << result.size() << "pn:" << pn << "totalPages:" << totalPages;
        emit userUploadedVideosReady(result, pn, totalPages);

        reply->deleteLater();
    });
    qDebug() << "[PlayUrlManager] getUserUploadedVideos connect done";
}

// 获取直播房间信息
void PlayUrlManager::getLiveRoomInfo(const QString &roomId)
{
    ++m_liveRequestId;
    int thisRequestId = m_liveRequestId;

    QString url = QString("https://api.live.bilibili.com/room/v1/Room/get_info?room_id=%1&platform=web&protocol=0,1&stream=0,1&pt-customer_scgi=1")
                      .arg(roomId);


    QUrl reqUrl(url);
    QNetworkRequest request(reqUrl);
    
    // 构造直播间 Referer
    QString referer = QString("https://live.bilibili.com/%1").arg(roomId);
    
    // 添加完整的请求头
    request.setRawHeader("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36");
    request.setRawHeader("Referer", referer.toUtf8());
    request.setRawHeader("Origin", "https://live.bilibili.com");
    request.setRawHeader("Accept", "application/json, text/plain, */*");
    request.setRawHeader("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8");
    
    // 添加 buvid 头
    LoginManager *loginMgr = LoginManager::instance();
    QString buvid3 = loginMgr->getCurrentUser().buvid3;
    if (!buvid3.isEmpty()) {
        request.setRawHeader("buvid", buvid3.toUtf8());
    }

    // 添加 Cookie
    QString cookies = loginMgr->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    QSslConfiguration config = QSslConfiguration::defaultConfiguration();
    config.setPeerVerifyMode(QSslSocket::VerifyNone);
    request.setSslConfiguration(config);

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, roomId, thisRequestId]() {
        if (thisRequestId != m_liveRequestId) {
            reply->deleteLater();
            return;
        }

        if (reply->error() != QNetworkReply::NoError) {
            emit errorOccurred("获取直播信息失败");
            reply->deleteLater();
            return;
        }

        QByteArray data = reply->readAll();

        parseLiveRoomInfo(data);

        reply->deleteLater();
    });
}

void PlayUrlManager::getLiveDanmakuInfo(const QString &roomId)
{
    // 获取弹幕WebSocket连接信息（参考 wiliwili，使用WBI签名）
    // API: https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo
    // 参数: type=0&id=roomid （需要WBI签名）
    
    // 构建参数（参考wiliwili: type=0, id=roomid）
    QString params = QString("id=%1&type=0").arg(roomId);
    
    // 使用WBI签名
    WbiSigner *signer = WbiSigner::instance();
    QString signedParams = signer->signParams(params);
    
    QString url = QString("https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo?%1")
                      .arg(signedParams);


    QUrl reqUrl(url);
    QNetworkRequest request(reqUrl);
    
    // 构造直播间 Referer
    QString referer = QString("https://live.bilibili.com/%1").arg(roomId);
    
    LoginManager *loginMgr = LoginManager::instance();
    
    // 添加完整的请求头
    request.setRawHeader("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36");
    request.setRawHeader("Referer", referer.toUtf8());
    request.setRawHeader("Origin", "https://live.bilibili.com");
    request.setRawHeader("Accept", "application/json, text/plain, */*");
    request.setRawHeader("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8");
    request.setRawHeader("Cache-Control", "no-cache");
    request.setRawHeader("Pragma", "no-cache");
    
    // 添加 buvid 头
    QString buvid3 = loginMgr->getCurrentUser().buvid3;
    if (!buvid3.isEmpty()) {
        request.setRawHeader("buvid", buvid3.toUtf8());
    }
    
    // 添加 Cookie（关键：用于通过风控）
    QString cookies = loginMgr->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    QSslConfiguration config = QSslConfiguration::defaultConfiguration();
    config.setPeerVerifyMode(QSslSocket::VerifyNone);
    request.setSslConfiguration(config);

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, roomId]() {
        if (reply->error() != QNetworkReply::NoError) {
            reply->deleteLater();
            return;
        }

        QByteArray data = reply->readAll();

        // 解析弹幕信息
        QJsonDocument doc = QJsonDocument::fromJson(data);
        if (!doc.isObject()) {
            reply->deleteLater();
            return;
        }

        QJsonObject root = doc.object();
        if (root["code"].toInt() != 0) {
            // 即使API失败，也发射信号使用默认服务器
            LiveDanmakuInfo defaultInfo;
            defaultInfo.host = "broadcastlv.chat.bilibili.com";
            defaultInfo.wsPort = 2245;
            defaultInfo.token = "";
            emit liveDanmakuInfoReady(defaultInfo);
            reply->deleteLater();
            return;
        }

        QJsonObject dataObj = root["data"].toObject();
        
        LiveDanmakuInfo info;
        
        // 解析 host_list
        if (dataObj.contains("host_list")) {
            QJsonArray hostList = dataObj["host_list"].toArray();
            
            if (!hostList.isEmpty()) {
                // wiliwili使用最后一个服务器
                QJsonObject hostInfo = hostList.last().toObject();
                info.host = hostInfo["host"].toString();
                // 使用 wss_port（用于wss://协议连接）
                info.wsPort = hostInfo["wss_port"].toInt();
                if (info.wsPort == 0) {
                    info.wsPort = hostInfo["ws_port"].toInt();
                    if (info.wsPort == 0) {
                        info.wsPort = hostInfo["port"].toInt();
                    }
                }
                
                // 打印所有host信息
                for (int i = 0; i < hostList.size(); i++) {
                    QJsonObject h = hostList[i].toObject();
                }
                
            }
        }
        
        // 解析 token
        info.token = dataObj["token"].toString();
        
        // 打印观众人数
        if (dataObj.contains("online")) {
        }

        // 即使某些字段为空也发射信号
        emit liveDanmakuInfoReady(info);

        reply->deleteLater();
    });
}

void PlayUrlManager::getLivePlayUrl(const QString &roomId, int quality)
{
    ++m_liveRequestId;
    int thisRequestId = m_liveRequestId;

    // 使用 getRoomPlayInfo API（参考 wiliwili + bilibili-api）
    // 当 quality=0（自动）时，请求 qn=10000（原画）以获取最高清晰度
    int requestQn = (quality == 0) ? 10000 : quality;
    
    // codec=0,1,2 包含avc+hevc+av1
    // format=0,1,2 包含flv+ts+fmp4
    // protocol=0,1 包含http_stream+http_hls
    QString url = QString("https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo?"
                          "room_id=%1&protocol=0,1&format=0,1,2&codec=0,1,2&qn=%2&platform=web&ptype=8&dolby=5&panorama=1")
                      .arg(roomId)
                      .arg(requestQn);


    QUrl reqUrl(url);
    QNetworkRequest request(reqUrl);
    
    // 构造直播间 Referer（关键：必须是具体的直播间 URL）
    QString referer = QString("https://live.bilibili.com/%1").arg(roomId);
    
    // 添加完整的请求头（参考 wiliwili 和 bilibili-api 项目）
    request.setRawHeader("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36");
    request.setRawHeader("Referer", referer.toUtf8());
    request.setRawHeader("Origin", "https://live.bilibili.com");
    request.setRawHeader("Accept", "application/json, text/plain, */*");
    request.setRawHeader("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8");
    request.setRawHeader("Cache-Control", "no-cache");
    request.setRawHeader("Pragma", "no-cache");
    
    // 添加 buvid 相关头（设备指纹，用于绕过风控）
    LoginManager *loginMgr = LoginManager::instance();
    QString buvid3 = loginMgr->getCurrentUser().buvid3;
    if (!buvid3.isEmpty()) {
        request.setRawHeader("buvid", buvid3.toUtf8());
    }

    // 添加 Cookie
    QString cookies = loginMgr->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    QSslConfiguration config = QSslConfiguration::defaultConfiguration();
    config.setPeerVerifyMode(QSslSocket::VerifyNone);
    request.setSslConfiguration(config);

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, roomId, thisRequestId, quality]() {
        if (thisRequestId != m_liveRequestId) {
            reply->deleteLater();
            return;
        }

        if (reply->error() != QNetworkReply::NoError) {
            emit errorOccurred("获取直播地址失败");
            reply->deleteLater();
            return;
        }

        QByteArray data = reply->readAll();

        parseLivePlayUrl(data, quality, roomId, thisRequestId);

        reply->deleteLater();
    });
}

void PlayUrlManager::parseLiveRoomInfo(const QByteArray &data)
{
    QJsonDocument doc = QJsonDocument::fromJson(data);
    if (!doc.isObject()) {
        emit errorOccurred("解析直播信息失败");
        return;
    }

    QJsonObject root = doc.object();
    if (root["code"].toInt() != 0) {
        emit errorOccurred("API错误: " + root["message"].toString());
        return;
    }

    QJsonObject dataObj = root["data"].toObject();

    LiveRoomInfo info;
    info.roomId = dataObj["room_id"].toInt();
    info.uid = dataObj["uid"].toInt();
    info.title = dataObj["title"].toString();
    // 注意：/room/v1/Room/get_info API 不返回 uname 字段，需要通过用户信息 API 获取
    // 先设置为空字符串，后面会通过 uid 获取用户信息来填充
    info.uname = "";
    info.cover = dataObj["cover"].toString();
    info.areaName = dataObj["area_name"].toString();
    info.liveStatus = dataObj["live_status"].toInt();
    info.online = dataObj["online"].toInt();


    emit liveRoomInfoReady(info);

    // 通过uid获取UP主名字（/room/v1/Room/get_info API 不返回 uname）
    if (info.uid > 0) {
        getUserInfoByUid(info.uid);
    }
}

void PlayUrlManager::parseLivePlayUrl(const QByteArray &data, int quality, const QString &roomId, int requestId)
{
    QJsonDocument doc = QJsonDocument::fromJson(data);
    if (!doc.isObject()) {
        emit errorOccurred("解析直播地址失败");
        return;
    }

    QJsonObject root = doc.object();
    if (root["code"].toInt() != 0) {
        emit errorOccurred("API错误: " + root["message"].toString());
        return;
    }

    QJsonObject dataObj = root["data"].toObject();

    LiveUrlInfo info;

    // 打印一些关键信息用于调试
    
    // 解析 playurl_info 格式（参考 wiliwili）
    if (dataObj.contains("playurl_info")) {
        QJsonObject playurlInfo = dataObj["playurl_info"].toObject();
        QJsonObject playurl = playurlInfo["playurl"].toObject();

        // 调试：打印playurl对象的所有key
        if (playurl.contains("dolby_qn")) {
        }
        if (playurl.contains("current_qn")) {
        }
        if (playurl.contains("current_quality")) {
        }
        
        // 打印conf_json
        if (playurlInfo.contains("conf_json")) {
        }
        
        // 打印stream数量和每个stream的protocol_name
        if (playurl.contains("stream")) {
            QJsonArray streams = playurl["stream"].toArray();
            for (const QJsonValue &sv : streams) {
                QJsonObject s = sv.toObject();
                if (s.contains("format")) {
                    QJsonArray fmts = s["format"].toArray();
                    for (const QJsonValue &fv : fmts) {
                        QJsonObject f = fv.toObject();
                    }
                }
            }
        }

        // 先解析完整的清晰度描述列表（用于后续匹配）
        QMap<int, QString> qualityDescriptions;
        if (playurl.contains("g_qn_desc")) {
            QJsonArray qnDesc = playurl["g_qn_desc"].toArray();
            for (const QJsonValue &val : qnDesc) {
                QJsonObject q = val.toObject();
                int qn = q["qn"].toInt();
                QString desc = q["desc"].toString();
                qualityDescriptions[qn] = desc;
            }
        }

        // 解析流信息
        if (playurl.contains("stream")) {
            QJsonArray streams = playurl["stream"].toArray();

            // 收集所有可用的流信息
            struct StreamInfo {
                QString host;
                QString baseUrl;
                QString extra;
                QString protocolName;
                QString formatName;
                QString codecName;
                int qn;
                bool isNative;
            };
            QList<StreamInfo> allStreams;
            QSet<int> acceptQnSet;  // 收集所有codec支持的清晰度

            for (const QJsonValue &streamVal : streams) {
                QJsonObject stream = streamVal.toObject();
                QString protocolName = stream["protocol_name"].toString();

                if (stream.contains("format")) {
                    QJsonArray formats = stream["format"].toArray();
                    for (const QJsonValue &formatVal : formats) {
                        QJsonObject format = formatVal.toObject();
                        QString formatName = format["format_name"].toString();

                        if (format.contains("codec")) {
                            QJsonArray codecs = format["codec"].toArray();
                            for (const QJsonValue &codecVal : codecs) {
                                QJsonObject codec = codecVal.toObject();
                                int currentQn = codec["current_qn"].toInt();
                                QString baseUrl = codec["base_url"].toString();
                                
                                // 打印codec的所有key，看看是否有accept_qn等字段
                                static bool printedCodecKeys = false;
                                if (!printedCodecKeys) {
                                    // 打印stream_resource_req
                                    if (codec.contains("stream_resource_req")) {
                                    }
                                    printedCodecKeys = true;
                                }
                                
                                // 检查是否有 accept_qn 字段（支持的清晰度列表）
                                if (codec.contains("accept_qn")) {
                                    QJsonArray acceptQnArray = codec["accept_qn"].toArray();
                                    // 收集所有支持的清晰度
                                    for (const QJsonValue &v : acceptQnArray) {
                                        acceptQnSet.insert(v.toInt());
                                    }
                                }

                                if (codec.contains("url_info")) {
                                    QJsonArray urlInfos = codec["url_info"].toArray();
                                    if (!urlInfos.isEmpty()) {
                                        QJsonObject urlInfo = urlInfos[0].toObject();
                                        QString host = urlInfo["host"].toString();
                                        QString extra = urlInfo["extra"].toString();
                                        
                                        
                                        // 只使用API原生返回的流，不自己修改URL
                                        StreamInfo si;
                                        si.host = host;
                                        si.baseUrl = baseUrl;
                                        si.extra = extra;
                                        si.protocolName = protocolName;
                                        si.formatName = formatName;
                                        si.codecName = codec["codec_name"].toString();
                                        si.qn = currentQn;
                                        si.isNative = true;  // 标记为原生流
                                        allStreams.append(si);
                                        
                                    }
                                }
                            }
                        }
                    }
                }
            }


            // 辅助函数：选择最优流
            // 优先级：1.原生流 > 2.编码av1 > hevc > avc > 3.格式fmp4 > ts > flv
            auto selectBestStream = [](const QList<StreamInfo> &streams) -> StreamInfo {
                if (streams.isEmpty()) {
                    return StreamInfo{};
                }
                
                QList<StreamInfo> candidates = streams;
                
                // 优先选择原生流
                QList<StreamInfo> nativeStreams;
                for (const auto &s : candidates) {
                    if (s.isNative) {
                        nativeStreams.append(s);
                    }
                }
                if (!nativeStreams.isEmpty()) {
                    candidates = nativeStreams;
                }
                
                // 编码优先级：avc > hevc > av1（avc兼容性最好）
                QStringList codecPriority = {"avc", "hevc", "av1"};
                for (const QString &codec : codecPriority) {
                    QList<StreamInfo> codecStreams;
                    for (const auto &s : candidates) {
                        if (s.codecName == codec) {
                            codecStreams.append(s);
                        }
                    }
                    if (!codecStreams.isEmpty()) {
                        candidates = codecStreams;
                        break;
                    }
                }
                
                // 格式优先级：flv > fmp4 > ts（flv兼容性最好，fmp4次之，ts可能有问题）
                QStringList formatPriority = {"flv", "fmp4", "ts"};
                for (const QString &format : formatPriority) {
                    for (const auto &s : candidates) {
                        if (s.formatName == format) {
                            return s;
                        }
                    }
                }
                
                return candidates.first();
            };

            // 根据用户请求的 quality 选择合适的流
            if (allStreams.isEmpty()) {
            } else if (quality > 0) {
                // 用户指定了清晰度，查找匹配的流
                QList<StreamInfo> filteredStreams;
                for (const auto &s : allStreams) {
                    if (s.qn == quality) {
                        filteredStreams.append(s);
                    }
                }

                if (!filteredStreams.isEmpty()) {
                    StreamInfo si = selectBestStream(filteredStreams);
                    
                    info.liveUrl = si.host + si.baseUrl + si.extra;
                    info.qualityId = si.qn;
                    info.qualityDesc = getQualityDescription(si.qn);
                    info.codecName = si.codecName;

                } else {
                    // 没有找到匹配的，选择最高清晰度
                    std::sort(allStreams.begin(), allStreams.end(),
                              [](const StreamInfo &a, const StreamInfo &b) { return a.qn > b.qn; });
                    
                    // 选择最高qn的最优流
                    QList<StreamInfo> highestQnStreams;
                    int highestQn = allStreams.first().qn;
                    for (const auto &s : allStreams) {
                        if (s.qn == highestQn) {
                            highestQnStreams.append(s);
                        }
                    }
                    
                    StreamInfo si = selectBestStream(highestQnStreams);
                    info.liveUrl = si.host + si.baseUrl + si.extra;
                    info.qualityId = si.qn;
                    info.qualityDesc = getQualityDescription(si.qn);
                    info.codecName = si.codecName;

                }
            } else {
                // quality=0（自动），选择最高清晰度的流
                std::sort(allStreams.begin(), allStreams.end(),
                          [](const StreamInfo &a, const StreamInfo &b) { return a.qn > b.qn; });
                
                // 选择最高qn的最优流
                QList<StreamInfo> highestQnStreams;
                int highestQn = allStreams.first().qn;
                for (const auto &s : allStreams) {
                    if (s.qn == highestQn) {
                        highestQnStreams.append(s);
                    }
                }
                
                StreamInfo si = selectBestStream(highestQnStreams);
                
                info.liveUrl = si.host + si.baseUrl + si.extra;
                info.qualityId = si.qn;
                info.qualityDesc = getQualityDescription(si.qn);
                info.codecName = si.codecName;

            }

            if (!info.liveUrl.isEmpty()) {
                // 使用accept_qn收集的所有支持的清晰度构建列表
                QList<int> sortedQns = acceptQnSet.values();
                std::sort(sortedQns.begin(), sortedQns.end(), std::greater<int>());
                
                
                // 构建最终的清晰度列表
                for (int qn : sortedQns) {
                    // 只保留有实际意义的清晰度（80及以上）
                    if (qn < 80) continue;
                    
                    LiveQualityInfo qualityInfo;
                    qualityInfo.qn = qn;
                    // 优先使用API返回的描述，否则使用默认描述
                    if (qualityDescriptions.contains(qn)) {
                        qualityInfo.desc = qualityDescriptions[qn];
                    } else {
                        qualityInfo.desc = getQualityDescription(qn);
                    }
                    info.qualityList.append(qualityInfo);
                }
                
                
                // 只有当用户明确选择原画(quality >= 10000)，但实际返回的清晰度低于10000时，才尝试旧版API
                // 自动模式(quality=0)不回退，因为新API返回的蓝光(400)比旧版API返回的超清(250)更好
                if (quality >= 10000 && info.qualityId < 10000 && !roomId.isEmpty() && requestId > 0) {
                    // 保存新API的结果，以备旧版API更差时回退
                    m_newApiResult = info;
                    m_roomIdForFallback = roomId;
                    m_requestIdForFallback = requestId;
                    getLivePlayUrlLegacy(roomId, quality, requestId);
                    return;
                }
                
                emit livePlayUrlReady(info);
                return;
            }
        }
    }

    // 备用：尝试解析旧的 durl 格式
    if (info.liveUrl.isEmpty() && dataObj.contains("durl")) {
        QJsonArray durls = dataObj["durl"].toArray();
        int currentQn = dataObj["current_qn"].toInt();

        if (!durls.isEmpty()) {
            QJsonObject selectedDurl = durls[0].toObject();
            info.liveUrl = selectedDurl["url"].toString();
            info.qualityId = currentQn;
            info.qualityDesc = getQualityDescription(currentQn);
            info.codecName = "FLV";
        }
    }

    if (info.liveUrl.isEmpty()) {
        emit errorOccurred("未找到可用的直播地址");
        return;
    }


    emit livePlayUrlReady(info);
}

void PlayUrlManager::getLivePlayUrlLegacy(const QString &roomId, int quality, int requestId)
{
    int requestQn = (quality == 0) ? 10000 : quality;
    // 关键发现：quality=4 表示原画，qn=10000 也表示原画
    // 但服务器可能根据多种因素决定实际返回的画质
    // 尝试同时使用两个参数（参考BililiveRecorder项目）
    QString url;
    if (requestQn >= 10000) {
        // 原画：同时使用 qn=10000 和 quality=4
        url = QString("https://api.live.bilibili.com/room/v1/Room/playUrl?"
                      "cid=%1&qn=%2&quality=4&platform=web&ptype=8")
                  .arg(roomId)
                  .arg(requestQn);
    } else {
        url = QString("https://api.live.bilibili.com/room/v1/Room/playUrl?"
                      "cid=%1&qn=%2&platform=web&ptype=8")
                  .arg(roomId)
                  .arg(requestQn);
    }
    

    QUrl reqUrl(url);
    QNetworkRequest request(reqUrl);
    
    // 构造直播间 Referer
    QString referer = QString("https://live.bilibili.com/%1").arg(roomId);
    
    // 添加完整的请求头
    request.setRawHeader("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36");
    request.setRawHeader("Referer", referer.toUtf8());
    request.setRawHeader("Origin", "https://live.bilibili.com");
    request.setRawHeader("Accept", "application/json, text/plain, */*");
    request.setRawHeader("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8");
    
    // 添加 buvid 头
    LoginManager *loginMgr = LoginManager::instance();
    QString buvid3 = loginMgr->getCurrentUser().buvid3;
    if (!buvid3.isEmpty()) {
        request.setRawHeader("buvid", buvid3.toUtf8());
    }

    QString cookies = loginMgr->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    QSslConfiguration config = QSslConfiguration::defaultConfiguration();
    config.setPeerVerifyMode(QSslSocket::VerifyNone);
    request.setSslConfiguration(config);

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, roomId, requestId, quality]() {
        if (requestId != m_liveRequestId) {
            reply->deleteLater();
            return;
        }

        if (reply->error() != QNetworkReply::NoError) {
            // 旧API失败，不做处理，让新API的结果继续生效
            reply->deleteLater();
            return;
        }

        QByteArray data = reply->readAll();

        // 解析旧版API响应
        QJsonDocument doc = QJsonDocument::fromJson(data);
        if (!doc.isObject()) {
            reply->deleteLater();
            return;
        }

        QJsonObject root = doc.object();
        if (root["code"].toInt() != 0) {
            reply->deleteLater();
            return;
        }

        QJsonObject dataObj = root["data"].toObject();
        LiveUrlInfo info;

        if (dataObj.contains("durl")) {
            QJsonArray durls = dataObj["durl"].toArray();
            int currentQn = dataObj["current_qn"].toInt();
            QString currentQualityDesc = dataObj["current_quality"].toString();


            if (!durls.isEmpty()) {
                QJsonObject selectedDurl = durls[0].toObject();
                info.liveUrl = selectedDurl["url"].toString();
                info.qualityId = currentQn;
                info.qualityDesc = getQualityDescription(currentQn);
                info.codecName = "FLV";
                
                // 从quality_description获取可用清晰度
                if (dataObj.contains("quality_description")) {
                    QJsonArray qualityDescArray = dataObj["quality_description"].toArray();
                    
                    
                    for (const QJsonValue &v : qualityDescArray) {
                        QJsonObject qDesc = v.toObject();
                        LiveQualityInfo qi;
                        qi.qn = qDesc["qn"].toInt();
                        qi.desc = qDesc["desc"].toString();
                        info.qualityList.append(qi);
                    }
                }

                
                // 比较新旧API的清晰度，如果旧版API的清晰度不如新API，使用新API的结果
                if (m_requestIdForFallback == requestId && m_newApiResult.qualityId > info.qualityId) {
                    emit livePlayUrlReady(m_newApiResult);
                } else {
                    emit livePlayUrlReady(info);
                }
            }
        }

        reply->deleteLater();
    });
}

void PlayUrlManager::parseUgcSeason(const QJsonObject &dataObj, VideoDetail &detail)
{
    // 检查是否有 ugc_season 字段（合集/分集信息）
    if (!dataObj.contains("ugc_season")) {
        qDebug() << "[PlayUrlManager] no ugc_season in response";
        return;
    }
    
    QJsonObject ugcSeason = dataObj["ugc_season"].toObject();
    if (ugcSeason.isEmpty()) {
        qDebug() << "[PlayUrlManager] ugc_season is empty";
        return;
    }
    
    detail.hasUgcSeason = true;
    detail.seasonTitle = ugcSeason["title"].toString();
    detail.seasonCover = ugcSeason["cover"].toString();
    
    qDebug() << "[PlayUrlManager] ugc_season parsed: title=" << detail.seasonTitle;
    
    // 解析 sections 数组
    if (ugcSeason.contains("sections")) {
        QJsonArray sections = ugcSeason["sections"].toArray();
        int globalIndex = 0;
        QString currentCid = detail.cid;
        
        for (const QJsonValue &sectionVal : sections) {
            QJsonObject section = sectionVal.toObject();
            int sectionId = section["id"].toInt();
            QString sectionTitle = section["title"].toString();
            
            // 解析每个 section 中的 episodes
            if (section.contains("episodes")) {
                QJsonArray episodes = section["episodes"].toArray();
                
                for (const QJsonValue &epVal : episodes) {
                    QJsonObject ep = epVal.toObject();
                    
                    EpisodeInfo info;
                    info.aid = QString::number(ep["aid"].toVariant().toLongLong());
                    info.bvid = ep["bvid"].toString();
                    info.cid = QString::number(ep["cid"].toVariant().toLongLong());
                    info.title = ep["title"].toString();
                    info.index = globalIndex;
                    info.sectionId = sectionId;
                    info.sectionTitle = sectionTitle;
                    
                    // 解析 page 子对象
                    if (ep.contains("page")) {
                        QJsonObject page = ep["page"].toObject();
                        info.duration = page["duration"].toInt();
                        info.part = page["part"].toString();
                    }
                    
                    // 构建 QVariantMap 添加到列表
                    QVariantMap epMap;
                    epMap["aid"] = info.aid;
                    epMap["bvid"] = info.bvid;
                    epMap["cid"] = info.cid;
                    epMap["title"] = info.title;
                    epMap["index"] = info.index;
                    epMap["duration"] = info.duration;
                    epMap["part"] = info.part;
                    epMap["sectionId"] = info.sectionId;
                    epMap["sectionTitle"] = info.sectionTitle;
                    
                    detail.episodes.append(epMap);
                    
                    // 查找当前视频在合集中的索引
                    if (info.cid == currentCid) {
                        detail.seasonCurrentIndex = globalIndex;
                    }
                    
                    globalIndex++;
                }
            }
        }
        
        qDebug() << "[PlayUrlManager] ugc_season episodes count:" << detail.episodes.size() 
                 << "currentIndex:" << detail.seasonCurrentIndex;
    }
}

void PlayUrlManager::parseViewPoints(const QJsonObject &dataObj, VideoDetail &detail)
{
    // 分段章节数据由 /x/player/v2 返回（getPlayerDetail 中解析），
    // /x/web-interface/view 实测无 view_points 字段。此函数保留接口签名但
    // 置空列表，VideoDetail::viewPoints 统一由 playerDetailReady 信号侧填充
    Q_UNUSED(dataObj)
    detail.viewPoints.clear();
}

void PlayUrlManager::parseVideoSubtitleIds(const QJsonObject &dataObj)
{
    // 从 view 接口缓存当前视频的字幕权威列表。
    //
    // 为什么需要：/x/player/v2 与 /x/player/wbi/v2 的 subtitle.subtitles
    // 在视频无字幕（或被风控）时会返回**毫不相干的 AI 占位字幕**——
    // 实测给"一加6上手体验"返回了"大佬K·世田谷灭门案"的AI字幕
    // （lan=ai-zh, type=1, ai_status=2）。用户看到的就是"字幕牛头不对马嘴"。
    // view 接口的 subtitle.list 是唯一可靠基准：
    //   有 CC 的视频 → list 里有对应 id（但 subtitle_url 恒为空）
    //   无字幕的视频 → list 为空数组
    // 所以 view 出列表，player 只按 id 匹配补 URL，其余一律丢弃。
    //
    // m_videoSubtitleChecked：view 确实返回了 subtitle 字段（无论 list 是否
    // 为空）。为 false 时不过滤，避免 view 请求失败时误杀
    m_videoSubtitleList.clear();
    m_videoSubtitleBvid = dataObj.value("bvid").toString();
    m_videoSubtitleChecked = dataObj.contains("subtitle");
    // 新一次 view 响应（换视频/换分P）→ 重置字幕重试状态
    m_subtitleResolved = false;
    m_subtitleRetryAttempt = 0;
    m_subtitleRetryLastMs = 0;
    m_subtitleRetryBvid = m_videoSubtitleBvid;
    if (!m_videoSubtitleChecked)
        return;
    const QJsonObject subtitleObj = dataObj.value("subtitle").toObject();
    const QJsonArray list = subtitleObj.value("list").toArray();
    for (const QJsonValue &v : list) {
        const QJsonObject o = v.toObject();
        QString id = o.value("id_str").toString();
        if (id.isEmpty())
            id = QString::number(o.value("id").toDouble(), 'f', 0);
        if (id.isEmpty())
            continue;
        QVariantMap sm;
        sm["id"] = id;
        sm["lang"] = o.value("lan").toString();
        QString lanDoc = o.value("lan_doc").toString();
        if (lanDoc.isEmpty())
            lanDoc = o.value("lan").toString();
        const bool isAi = o.value("type").toInt() == 1;
        if (isAi && !lanDoc.endsWith(QString::fromUtf8("（AI）")))
            lanDoc += QString::fromUtf8("（AI）");
        sm["title"] = lanDoc;
        sm["isAi"] = isAi;
        m_videoSubtitleList.append(sm);
    }
    qDebug() << "[PlayUrlManager] video subtitle list from view:" << m_videoSubtitleList.size()
             << "checked:" << m_videoSubtitleChecked << "bvid:" << m_videoSubtitleBvid;
}

void PlayUrlManager::parsePages(const QJsonObject &dataObj, VideoDetail &detail)
{
    if (!dataObj.contains("pages")) {
        qDebug() << "[PlayUrlManager] no pages in response";
        detail.hasPages = false;
        detail.pageCurrentIndex = -1;
        return;
    }
    
    QJsonArray pagesArr = dataObj["pages"].toArray();
    if (pagesArr.isEmpty()) {
        qDebug() << "[PlayUrlManager] pages array is empty";
        detail.hasPages = false;
        detail.pageCurrentIndex = -1;
        return;
    }
    
    qDebug() << "[PlayUrlManager] pages array size:" << pagesArr.size() << "detail.cid:" << detail.cid;
    
    detail.hasPages = pagesArr.size() > 1;
    QString currentCid = detail.cid;
    int currentIndex = -1;
    
    for (int i = 0; i < pagesArr.size(); ++i) {
        const QJsonValue &pageVal = pagesArr[i];
        QJsonObject page = pageVal.toObject();
        
        QVariantMap pageMap;
        qlonglong cidVal = page["cid"].toVariant().toLongLong();
        QString cid = QString::number(cidVal);
        pageMap["cid"] = cid;
        pageMap["page"] = page["page"].toInt();
        pageMap["part"] = page["part"].toString();
        pageMap["duration"] = page["duration"].toInt();
        
        qDebug() << "[PlayUrlManager] page" << i 
                 << "cid:" << cid 
                 << "page:" << page["page"].toInt() 
                 << "part:" << page["part"].toString()
                 << "duration:" << page["duration"].toInt();
        
        if (cid == currentCid) {
            currentIndex = detail.pages.size();
            qDebug() << "[PlayUrlManager] matched current cid at index:" << currentIndex;
        }
        
        detail.pages.append(pageMap);
    }
    
    detail.pageCurrentIndex = currentIndex;
    
    qDebug() << "[PlayUrlManager] pages parsed: count=" << detail.pages.size() 
             << "hasPages=" << detail.hasPages 
             << "currentIndex:" << detail.pageCurrentIndex
             << "currentCid:" << currentCid;
}

// 获取视频分P列表（/x/player/pagelist 接口）
// 当 /x/web-interface/view 接口不返回 pages 字段时，使用此接口作为补充
void PlayUrlManager::getVideoPageList(const QString &aid, const QString &bvid, const QString &currentCid)
{
    qDebug() << "[PlayUrlManager] getVideoPageList aid:" << aid << "bvid:" << bvid << "currentCid:" << currentCid;
    
    QString url;
    if (!bvid.isEmpty()) {
        url = "https://api.bilibili.com/x/player/pagelist?bvid=" + bvid;
    } else if (!aid.isEmpty()) {
        url = "https://api.bilibili.com/x/player/pagelist?aid=" + aid;
    } else {
        qWarning() << "[PlayUrlManager] getVideoPageList: both aid and bvid are empty";
        return;
    }

    QUrl reqUrl(url);
    QNetworkRequest request(reqUrl);
    request.setRawHeader("User-Agent", USER_AGENT.toUtf8());
    request.setRawHeader("Referer", REFERER.toUtf8());
    request.setRawHeader("Origin", ORIGIN.toUtf8());
    request.setRawHeader("Accept", "application/json, text/plain, */*");

    // 添加 Cookie
    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    qDebug() << "[PlayUrlManager] getVideoPageList request:" << url;
    
    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, aid, bvid, currentCid]() {
        if (reply->error() != QNetworkReply::NoError) {
            qWarning() << "[PlayUrlManager] getVideoPageList network error:" << reply->error() << reply->errorString();
            reply->deleteLater();
            return;
        }

        QByteArray data = reply->readAll();
        qDebug() << "[PlayUrlManager] getVideoPageList response:" << data.left(512);

        QJsonDocument doc = QJsonDocument::fromJson(data);
        if (!doc.isObject()) {
            qWarning() << "[PlayUrlManager] getVideoPageList invalid JSON";
            reply->deleteLater();
            return;
        }

        QJsonObject root = doc.object();
        int code = root["code"].toInt();
        if (code != 0) {
            qWarning() << "[PlayUrlManager] getVideoPageList API error:" << code << root["message"].toString();
            reply->deleteLater();
            return;
        }

        QJsonArray pagesArr = root["data"].toArray();
        if (pagesArr.isEmpty()) {
            qDebug() << "[PlayUrlManager] getVideoPageList: pages array is empty";
            reply->deleteLater();
            return;
        }

        qDebug() << "[PlayUrlManager] getVideoPageList: found" << pagesArr.size() << "pages";

        // 解析分P列表
        QVariantList pagesList;
        int foundIndex = -1;

        for (int i = 0; i < pagesArr.size(); ++i) {
            const QJsonValue &pageVal = pagesArr[i];
            QJsonObject page = pageVal.toObject();

            QVariantMap pageMap;
            qlonglong cidVal = page["cid"].toVariant().toLongLong();
            QString cid = QString::number(cidVal);
            pageMap["cid"] = cid;
            pageMap["page"] = page["page"].toInt();
            pageMap["part"] = page["part"].toString();
            pageMap["duration"] = page["duration"].toInt();

            qDebug() << "[PlayUrlManager] pagelist page" << i 
                     << "cid:" << cid 
                     << "page:" << page["page"].toInt() 
                     << "part:" << page["part"].toString();

            // 检查是否匹配当前CID
            if (!currentCid.isEmpty() && cid == currentCid) {
                foundIndex = i;
                qDebug() << "[PlayUrlManager] pagelist: found currentCid at index:" << foundIndex;
            }

            pagesList.append(pageMap);
        }

        // 只有多个分P时才发射信号
        if (pagesArr.size() > 1) {
            qDebug() << "[PlayUrlManager] getVideoPageList: emitting videoPageListReady with" << pagesList.size() << "pages";
            emit videoPageListReady(pagesList, currentCid, foundIndex);
        } else {
            qDebug() << "[PlayUrlManager] getVideoPageList: only 1 page, not emitting";
        }

        reply->deleteLater();
    });
}

void PlayUrlManager::fetchUpVipInfo(qlonglong mid)
{
    if (mid <= 0) {
        return;
    }
    // 通过 /x/web-interface/card 获取 UP 主信息，解析 vip 字段
    // 该接口返回 data.card.vip.vipType：0=无，1=月度/季度大会员，2=年度大会员
    QString url = QString("https://api.bilibili.com/x/web-interface/card?mid=%1").arg(mid);

    QUrl reqUrl(url);
    QNetworkRequest request(reqUrl);
    request.setRawHeader("User-Agent", USER_AGENT.toUtf8());
    request.setRawHeader("Referer", QString("https://space.bilibili.com/%1").arg(mid).toUtf8());
    request.setRawHeader("Accept", "application/json, text/plain, */*");

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        if (reply->error() != QNetworkReply::NoError) {
            reply->deleteLater();
            return;
        }

        QByteArray data = reply->readAll();
        QJsonDocument doc = QJsonDocument::fromJson(data);
        if (!doc.isObject()) {
            reply->deleteLater();
            return;
        }

        QJsonObject root = doc.object();
        if (root["code"].toInt() != 0) {
            reply->deleteLater();
            return;
        }

        QJsonObject dataObj = root["data"].toObject();
        QJsonObject card = dataObj["card"].toObject();
        QJsonObject vip = card["vip"].toObject();
        int vipType = vip["vipType"].toInt();
        int vipStatus = vip["vipStatus"].toInt();
        int effectiveType = (vipStatus == 1) ? vipType : 0;
        QJsonObject pendant = card["pendant"].toObject();
        QString pendantImage = pendant["image"].toString();
        qDebug() << "[PlayUrlManager] fetchUpVipInfo mid:" << card["mid"].toVariant().toLongLong()
                 << "vipType:" << vipType << "vipStatus:" << vipStatus << "effectiveType:" << effectiveType
                 << "pendant:" << pendantImage;
        // 认证：card.official_verify.type（-1=无, 0=个人, 1=机构）。
        // 必须从这里取：/x/web-interface/view 的 owner 实测只有 mid/name/face
        // （BV1fLpk6rEhd 祁奕翔实测），仅靠 detail.ownerVerify 会恒为 -1，
        // UP 主头像的认证标永远不显示。个别响应只有 Official.type，做兜底
        QJsonObject officialVerify = card["official_verify"].toObject();
        int verifyType = officialVerify["type"].toInt(-1);
        if (verifyType < 0) {
            verifyType = card["Official"].toObject()["type"].toInt(-1);
        }
        // face_nft：数字藏品（NFT）头像用户，对应头像右下角钻石角标
        bool faceNft = (card["face_nft"].toInt() == 1);
        qDebug() << "[PlayUrlManager] fetchUpVipInfo verifyType:" << verifyType << "faceNft:" << faceNft;
        emit upVipReady(effectiveType, faceNft, verifyType);
        emit upPendantReady(pendantImage);

        reply->deleteLater();
    });
}

void PlayUrlManager::getUserInfoByUid(int uid)
{
    // 通过uid获取用户信息（UP主名字）
    // API: https://api.bilibili.com/x/web-interface/card?mid=uid
    QString url = QString("https://api.bilibili.com/x/web-interface/card?mid=%1").arg(uid);


    QUrl reqUrl(url);
    QNetworkRequest request(reqUrl);

    request.setRawHeader("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36");
    request.setRawHeader("Referer", "https://www.bilibili.com/");
    request.setRawHeader("Accept", "application/json, text/plain, */*");

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, uid]() {
        if (reply->error() != QNetworkReply::NoError) {
            reply->deleteLater();
            return;
        }

        QByteArray data = reply->readAll();
        QJsonDocument doc = QJsonDocument::fromJson(data);
        if (!doc.isObject()) {
            reply->deleteLater();
            return;
        }

        QJsonObject root = doc.object();
        if (root["code"].toInt() != 0) {
            reply->deleteLater();
            return;
        }

        QJsonObject dataObj = root["data"].toObject();
        QString uname = dataObj["card"].toObject()["name"].toString();

        if (!uname.isEmpty()) {
            emit liveUnameReady(uname);
        }

        reply->deleteLater();
    });
}

// ============ 番剧 API 实现 ============

void PlayUrlManager::getSeasonDetail(const QString &id, const QString &type)
{
    qDebug() << "[PlayUrlManager] getSeasonDetail id:" << id << "type:" << type;
    
    // 如果通过 season_id 查询，清空之前可能设置的 ep_id
    if (type == "season") {
        m_requestedEpId.clear();
    }
    
    // 使用 PC 端 API（与 wiliwili 一致）：/pgc/view/pc/season
    // 这个 API 直接传 ep_id 或 season_id，不需要 appkey/sign
    QString url;
    if (type == "season") {
        url = QString("https://api.bilibili.com/pgc/view/pc/season?season_id=%1").arg(id);
    } else {
        url = QString("https://api.bilibili.com/pgc/view/pc/season?ep_id=%1").arg(id);
    }
    
    qDebug() << "[PlayUrlManager] getSeasonDetail url:" << url;
    
    QUrl reqUrl(url);
    QNetworkRequest request(reqUrl);
    request.setRawHeader("User-Agent", USER_AGENT.toUtf8());
    request.setRawHeader("Referer", "https://www.bilibili.com");
    request.setRawHeader("Origin", ORIGIN.toUtf8());
    
    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }
    
    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, id, type]() {
        qDebug() << "[PlayUrlManager] getSeasonDetail reply finished";
        
        if (reply->error() != QNetworkReply::NoError) {
            qDebug() << "[PlayUrlManager] getSeasonDetail error:" << reply->errorString();
            emit errorOccurred("获取番剧详情失败");
            reply->deleteLater();
            return;
        }
        
        QByteArray data = reply->readAll();
        QJsonDocument doc = QJsonDocument::fromJson(data);
        if (!doc.isObject()) {
            emit errorOccurred("解析番剧详情失败");
            reply->deleteLater();
            return;
        }
        
        QJsonObject root = doc.object();
        int code = root["code"].toInt();
        if (code != 0) {
            qDebug() << "[PlayUrlManager] getSeasonDetail API error:" << root["message"].toString();
            emit errorOccurred("番剧API错误: " + root["message"].toString());
            reply->deleteLater();
            return;
        }
        
        QJsonObject dataObj = root["result"].toObject();
        
        // 解析番剧详情
        VideoDetail detail;
        parseSeasonDetail(dataObj, detail, m_requestedEpId);

        // 番剧的字幕 id 体系与普通视频不同（且不在本响应内），
        // 清空列表并标记"未确认"，避免用上一个普通视频的列表误杀番剧字幕
        m_videoSubtitleList.clear();
        m_videoSubtitleChecked = false;
        m_videoSubtitleBvid.clear();
        
        // 转换为 QVariantMap 并发射信号
        QVariantMap detailMap = videoDetailToMap(detail);
        emit seasonDetailReady(detailMap);
        emit videoDetailReady(detailMap);
        
        // 如果有 season_id，获取选集列表（传入当前CID以正确匹配当前集）
        if (!detail.seasonId.isEmpty()) {
            getSeasonEpisodes(detail.seasonId, detail.cid);
        }

        
        reply->deleteLater();
    });
}

void PlayUrlManager::getSeasonEpisodes(const QString &seasonId, const QString &currentCid)
{
    qDebug() << "[PlayUrlManager] getSeasonEpisodes seasonId:" << seasonId << "currentCid:" << currentCid;

    // ====== 请求去重：同一 seasonId 的请求未完成时，直接复用（避免重复请求导致选集 Loader 反复闪） ======
    if (m_pendingSeasonEpisodesReply && !m_pendingSeasonEpisodesReply->isFinished()
        && m_pendingSeasonEpisodesSeasonId == seasonId) {
        qDebug() << "[PlayUrlManager] getSeasonEpisodes deduplicated, same seasonId " << seasonId << " already in-flight";
        // currentCid 可能不一样（比如上一次是默认第1集，这一次是指定的新集），但 seasonId 相同说明结果列表一样，
        // currentCid 只影响 currentIndex 计算。所以我们把当前请求的 currentCid 记录到 reply 的动态属性上，
        // 多个后续请求都保存一次最新的，reply finished 时用最后一次（也就是最准确的）。
        m_pendingSeasonEpisodesReply->setProperty("deferred_currentCid", currentCid);
        return;
    }

    QString url = QString("https://api.bilibili.com/pgc/view/web/ep/list?season_id=%1").arg(seasonId);

    QUrl reqUrl(url);
    QNetworkRequest request(reqUrl);
    request.setRawHeader("User-Agent", USER_AGENT.toUtf8());
    request.setRawHeader("Referer", "https://www.bilibili.com");

    QString cookies = LoginManager::instance()->getCookies();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
    }

    QNetworkReply *reply = m_networkManager->get(request);
    // 保存正在进行中的请求指针（只有当前没有一个未完成的同 seasonId 请求时才保存）
    m_pendingSeasonEpisodesReply = reply;
    m_pendingSeasonEpisodesSeasonId = seasonId;
    reply->setProperty("deferred_currentCid", currentCid);

    connect(reply, &QNetworkReply::finished, this, [this, reply, seasonId]() {
        qDebug() << "[PlayUrlManager] getSeasonEpisodes reply finished";
        // 请求完成，清空 pending 状态
        if (reply == m_pendingSeasonEpisodesReply) {
            m_pendingSeasonEpisodesReply = nullptr;
            m_pendingSeasonEpisodesSeasonId.clear();
        }

        if (reply->error() != QNetworkReply::NoError) {
            qDebug() << "[PlayUrlManager] getSeasonEpisodes error:" << reply->errorString();
            reply->deleteLater();
            return;
        }

        QByteArray data = reply->readAll();
        QJsonDocument doc = QJsonDocument::fromJson(data);
        if (!doc.isObject()) {
            reply->deleteLater();
            return;
        }

        QJsonObject root = doc.object();
        if (root["code"].toInt() != 0) {
            reply->deleteLater();
            return;
        }

        QJsonObject dataObj = root["result"].toObject();
        QJsonArray episodesArray = dataObj["episodes"].toArray();

        // 如果后续有去重请求，使用他们最新的 currentCid（覆盖首次传入的 currentCid）
        QString deferredCid = reply->property("deferred_currentCid").toString();
        QString cid = deferredCid.isEmpty() ? QString() : deferredCid;
        int currentIndex = -1;
        QVariantList episodes = parseSeasonEpisodes(episodesArray, cid, currentIndex);

        emit seasonEpisodesReady(episodes, cid, currentIndex);

        reply->deleteLater();
    });
}

void PlayUrlManager::getSeasonPlayUrl(const QString &cid, int quality,
                                       const QString &epId, int seasonType,
                                       const QString &bvid, const QString &aid,
                                       bool forceMaxQuality,
                                       const QString &seasonId)
{
    qDebug() << "[PlayUrlManager] getSeasonPlayUrl cid:" << cid << "quality:" << quality
             << "forceMaxQuality:" << forceMaxQuality
             << "epId:" << epId
             << "bvid:" << bvid << "aid:" << aid
             << "hasCached:" << m_hasCachedResult << "cachedCid:" << m_cachedCid;
    // [DIAG] 诊断电影/番剧无法加载：入口决策点（release 下 qDebug 不可见，用 qWarning）
    qWarning() << "[DIAG][getSeasonPlayUrl] enter cid:" << cid << "epId:" << epId
               << "quality:" << quality << "forceMax:" << forceMaxQuality
               << "bvid:" << bvid << "seasonId:" << seasonId
               << "hasCached:" << m_hasCachedResult << "cachedCid:" << m_cachedCid;

    // 如果 CID 变化了，清除所有缓存
    if ((m_hasCachedResult && !m_cachedCid.isEmpty() && m_cachedCid != cid)) {
        qDebug() << "[PlayUrlManager] CID changed, clearing cache:" << m_cachedCid << "->" << cid;
        m_hasCachedResult = false;
        m_cachedCid.clear();
        m_cachedVideoUrlResult = VideoUrlResult();
        m_highQualityFetched = false;
        m_highQualityFetchedCid.clear();
    }

    // 如果已经缓存了该 CID 的 DASH 流，检查是否包含所需质量
    if (m_hasCachedResult && m_cachedCid == cid
        && !m_cachedVideoUrlResult.dashVideoUrls.isEmpty()) {

        bool hasHighQuality = false;
        for (const auto &stream : m_cachedVideoUrlResult.dashVideoUrls) {
            if (stream.qualityId >= 80) {  // 1080P 及以上
                hasHighQuality = true;
                break;
            }
        }

        // 如果缓存中有高质量流（1080P+），直接使用缓存
        if (hasHighQuality) {
            qDebug() << "[PlayUrlManager] Using cached result ("
                     << m_cachedVideoUrlResult.dashVideoUrls.count()
                     << " streams), switching to quality:" << quality;
            switchQualityFromCache(quality);
            return;
        }

        // 缓存中没有高质量流，清除缓存重新请求
        qDebug() << "[PlayUrlManager] Cache has no high quality streams, clearing cache";
        m_hasCachedResult = false;
        m_cachedCid.clear();
        m_cachedVideoUrlResult = VideoUrlResult();
        m_highQualityFetched = false;
        m_highQualityFetchedCid.clear();
    }

    // 如果有正在进行的请求且是同一个 CID 且质量相同，避免重复请求
    if (m_inFlightRequest && m_inFlightCid == cid && m_inFlightRequestQuality == quality) {
        qDebug() << "[PlayUrlManager] Request already in flight for same CID + same quality:" << cid << "qn=" << quality;
        return;
    }
    if (m_inFlightRequest && m_inFlightCid == cid && m_inFlightRequestQuality != quality) {
        qDebug() << "[PlayUrlManager] In-flight request for same CID but DIFFERENT quality (old="
                 << m_inFlightRequestQuality << "new=" << quality << ") — allowing new request";
    }

    // 标记请求正在进行
    m_inFlightRequest = true;
    m_inFlightCid = cid;
    m_inFlightRequestQuality = quality;

    // =====================================================================
    // 双策略 fallback：
    //   策略 A（PGC V1 signed, biliuwp-lite SeasonAndroidPlayUrl）优先
    //   若 code!=0 → 自动 fallback 策略 B（PGC V2, wiliwili SeasonUrl2）
    // =====================================================================
    LoginManager *loginMgr = LoginManager::instance();
    const QString cookies = loginMgr ? loginMgr->getCookies() : QString();
    const int userMid = loginMgr ? loginMgr->mid() : 0;
    const QString accessKey = loginMgr ? loginMgr->getCurrentUser().accessKey : QString();

    QString buvid3Header;
    if (loginMgr) {
        buvid3Header = loginMgr->getCurrentUser().buvid3;
    }
    if (buvid3Header.isEmpty()) {
        buvid3Header = "XY8D30F8-E10D-4B3A-B9C6-78D2E1C4F7A0infoc";
    }

    int clientQuality;
    if (forceMaxQuality) {
        clientQuality = 120;
        qDebug() << "[PlayUrlManager] forceMaxQuality=true → qn=120 (requested quality=" << quality << "ignored)";
    } else if (quality > 0) {
        clientQuality = quality;
        qDebug() << "[PlayUrlManager] explicit switch → exact qn=" << quality;
    } else {
        clientQuality = 120;
    }

    requestSeasonPlayUrlStrategyA(cid, clientQuality, epId, seasonType, seasonId,
                                  bvid, aid,
                                  cookies, buvid3Header, accessKey, userMid);
}

// =====================================================================
// 策略 A：biliuwp-lite SeasonAndroidPlayUrl (WebVideoKey signed PGC V1)
//   接口: /pgc/player/web/playurl
//   签名: WebVideoKey MD5
// =====================================================================
void PlayUrlManager::requestSeasonPlayUrlStrategyA(const QString &cid, int clientQuality,
                                                    const QString &epId, int seasonType,
                                                    const QString &seasonId,
                                                    const QString &bvid, const QString &aid,
                                                    const QString &cookies, const QString &buvid3Header,
                                                    const QString &accessKey, int userMid)
{
    const QString logTag = "PGC-V1";
    const bool hasAccessKey = !accessKey.isEmpty() && userMid > 0;

    // biliuwp-lite WebVideoKey（SeasonAndroidPlayUrl 使用的签名对）
    const QString WEBVIDEO_APPKEY   = "84956560bc028eb7";
    const QString WEBVIDEO_APPSECRET= "94aba54af9065f71de72f5508f1cd42e";
    const QString FNVAL_WEBVIDEO    = "4048";

    const QString baseUrl = "https://api.bilibili.com/pgc/player/web/playurl";

    QString rawParams;
    rawParams += QString("appkey=%1").arg(WEBVIDEO_APPKEY);
    rawParams += QString("&cid=%1").arg(cid);
    if (!epId.isEmpty()) {
        rawParams += QString("&ep_id=%1").arg(epId);
    }
    rawParams += QString("&qn=%1").arg(clientQuality);
    rawParams += "&type=";
    rawParams += "&otype=json";
    rawParams += "&module=bangumi";
    rawParams += QString("&season_type=%1").arg(seasonType);

    if (hasAccessKey) {
        rawParams += QString("&access_key=%1").arg(accessKey);
        rawParams += QString("&mid=%1").arg(userMid);
    }
    rawParams += "&fourk=1";
    rawParams += QString("&fnval=%1").arg(FNVAL_WEBVIDEO);
    rawParams += "&fnver=0";

    // MD5 签名（sorted params + secret）
    {
        QStringList paramList = rawParams.split("&");
        paramList.sort();
        QString sortedParams = paramList.join("&");
        QString signSource = sortedParams + WEBVIDEO_APPSECRET;
        QByteArray hash = QCryptographicHash::hash(signSource.toUtf8(), QCryptographicHash::Md5);
        rawParams += QString("&sign=") + QString(hash.toHex());
    }

    QString fullUrl = baseUrl + "?" + rawParams;
    qDebug() << "[PlayUrlManager]" << logTag << "PATH: biliuwp-lite SeasonAndroidPlayUrl (WebVideoKey MD5 signed)";
    qDebug() << "[PlayUrlManager]" << logTag << "baseUrl:" << baseUrl;
    qDebug() << "[PlayUrlManager]" << logTag << "rawParams (with sign, first 500):" << rawParams.left(500);
    qDebug() << "[PlayUrlManager]" << logTag << "full URL (first 600):" << fullUrl.left(600);

    const bool hasCookieAuth = cookies.contains("SESSDATA") && userMid > 0;
    qDebug() << "[PlayUrlManager]" << logTag << "auth-state:"
             << "hasAccessKey(APP-ak)=" << hasAccessKey
             << "hasCookieAuth(SESSDATA+mid)=" << hasCookieAuth
             << "userMid=" << userMid
             << "cookies.len=" << cookies.size()
             << "accessKey.len=" << accessKey.size();
    qDebug() << "[PlayUrlManager]" << logTag << "cookie preview (first 250):" << cookies.left(250);
    qDebug() << "[PlayUrlManager]" << logTag << "buvid3 (in UserInfo, will set as header buvid):" << buvid3Header;
    qDebug() << "[PlayUrlManager]" << logTag << "cookie contains SESSDATA:" << cookies.contains("SESSDATA=")
             << "contains DedeUserID:" << cookies.contains("DedeUserID=")
             << "contains buvid3:" << cookies.contains("buvid3=")
             << "contains bili_jct:" << cookies.contains("bili_jct=");

    QUrl qurl(fullUrl);
    QNetworkRequest request(qurl);

    request.setRawHeader(QByteArray("User-Agent"), USER_AGENT.toUtf8());
    QString bangumiReferer = "https://www.bilibili.com";
    if (!epId.isEmpty()) {
        bangumiReferer = QString("https://www.bilibili.com/bangumi/play/ep%1/").arg(epId);
    } else if (!seasonId.isEmpty() && seasonId.toInt() > 0) {
        bangumiReferer = QString("https://www.bilibili.com/bangumi/play/ss%1/").arg(seasonId);
    }
    request.setRawHeader(QByteArray("Referer"), bangumiReferer.toUtf8());
    request.setRawHeader(QByteArray("Origin"),     QByteArray("https://www.bilibili.com"));
    qDebug() << "[PlayUrlManager]" << logTag
             << "User-Agent: Chrome(120)"
             << "Referer:" << bangumiReferer;
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));
    request.setRawHeader(QByteArray("Accept-Language"), QByteArray("zh-CN,zh;q=0.9,en;q=0.8"));
    // 2026-10-15：删掉原先写死的 Connection: keep-alive —— 启用 HTTP/2 后该头
    // 属非法头（RFC 9113 禁止 h2 携带 connection 类头）。连接复用由共享池自身
    // 行为决定：h1.1 默认就是 keep-alive，h2 靠多路复用，无需这个提示。
    request.setRawHeader(QByteArray("Cache-Control"), QByteArray("no-cache"));

    if (!cookies.isEmpty()) {
        qDebug() << "[PlayUrlManager]" << logTag << "adding Cookie header, length:" << cookies.size();
        request.setRawHeader("Cookie", cookies.toUtf8());
    } else if (!hasAccessKey) {
        qWarning() << "[PlayUrlManager]" << logTag << "NO COOKIES + NO access_key → pure guest, max 480P";
    }
    request.setRawHeader(QByteArray("buvid"), buvid3Header.toUtf8());
    request.setRawHeader(QByteArray("buvid_fp"), QByteArray("d9a5c7d8f2e1b4a6c3b9e7f1a2d4c6b8"));

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, clientQuality, cid, logTag,
                                                    epId, seasonType, seasonId,
                                                    bvid, aid,
                                                    cookies, buvid3Header, accessKey, userMid]() {
        handleSeasonPlayUrlResponse(reply, clientQuality, cid, logTag,
                                    true /*isStrategyA*/,
                                    false /*isStrategyD*/,
                                    epId, seasonType, seasonId,
                                    bvid, aid,
                                    cookies, buvid3Header, accessKey, userMid);
    });
}

// =====================================================================
// 策略 B：wiliwili SeasonUrl2 (PGC V2, Cookie 鉴权)
//   接口: /pgc/player/web/v2/playurl
//   签名: 无（纯 Cookie-only）
//   UA: "wiliwili"
//   Referer: "https://www.bilibili.com/client"
// =====================================================================
void PlayUrlManager::requestSeasonPlayUrlStrategyB(const QString &cid, int clientQuality,
                                                    const QString &epId, const QString &seasonId,
                                                    const QString &bvid, const QString &aid,
                                                    const QString &cookies, const QString &buvid3Header,
                                                    const QString &accessKey, int userMid, int seasonType)
{
    const QString logTag = "PGC-V2";
    const QString baseUrl = "https://api.bilibili.com/pgc/player/web/v2/playurl";
    const QString FNVAL = "4048";

    // 1:1 复刻 wiliwili::get_season_url 参数
    QString rawParams;
    rawParams += QString("cid=%1").arg(cid);
    rawParams += QString("&qn=%1").arg(clientQuality);
    rawParams += "&gaia_source=";      // wiliwili 传空字符串
    rawParams += "&from_client=PC_APP";
    rawParams += "&is_main_page=false";
    rawParams += "&need_fragment=false";
    rawParams += "&isGaiaAvoided=false";
    rawParams += "&voice_balance=1";
    rawParams += "&drm_tech_type=3";
    rawParams += "&fourk=1";
    rawParams += QString("&fnval=%1").arg(FNVAL);
    rawParams += "&fnver=0";

    // B站 PGC V2 还支持这些显式参数，补充上以增强身份识别（mid 是高清的关键）
    if (userMid > 0) {
        rawParams += QString("&mid=%1").arg(userMid);
    }
    if (!accessKey.isEmpty()) {
        rawParams += QString("&access_key=%1").arg(accessKey);
    }
    if (!epId.isEmpty()) {
        rawParams += QString("&ep_id=%1").arg(epId);
    }
    if (!seasonId.isEmpty()) {
        rawParams += QString("&season_id=%1").arg(seasonId);
    }

    QString fullUrl = baseUrl + "?" + rawParams;
    qDebug() << "[PlayUrlManager]" << logTag << "PATH: wiliwili SeasonUrl2 (PGC V2, no sign, Cookie auth)";
    qDebug() << "[PlayUrlManager]" << logTag << "baseUrl:" << baseUrl;
    qDebug() << "[PlayUrlManager]" << logTag << "rawParams (first 500):" << rawParams.left(500);
    qDebug() << "[PlayUrlManager]" << logTag << "full URL (first 600):" << fullUrl.left(600);
    qDebug() << "[PlayUrlManager]" << logTag << "auth-state:"
             << "userMid=" << userMid
             << "cookies.len=" << cookies.size()
             << "accessKey.len=" << accessKey.size();

    QUrl qurl(fullUrl);
    QNetworkRequest request(qurl);

    // wiliwili 风格 headers（与 HTTP.hpp 保持一致）
    request.setRawHeader(QByteArray("User-Agent"), QByteArray("wiliwili"));
    request.setRawHeader(QByteArray("Referer"),    QByteArray("https://www.bilibili.com/client"));
    request.setRawHeader(QByteArray("Origin"),     QByteArray("https://www.bilibili.com"));
    qDebug() << "[PlayUrlManager]" << logTag
             << "User-Agent: wiliwili"
             << "Referer: https://www.bilibili.com/client";
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));
    request.setRawHeader(QByteArray("Accept-Language"), QByteArray("zh-CN,zh;q=0.9,en;q=0.8"));
    // 2026-10-15：删掉原先写死的 Connection: keep-alive —— 启用 HTTP/2 后该头
    // 属非法头（RFC 9113 禁止 h2 携带 connection 类头）。连接复用由共享池自身
    // 行为决定：h1.1 默认就是 keep-alive，h2 靠多路复用，无需这个提示。
    request.setRawHeader(QByteArray("Cache-Control"), QByteArray("no-cache"));

    if (!cookies.isEmpty()) {
        qDebug() << "[PlayUrlManager]" << logTag << "adding Cookie header, length:" << cookies.size();
        request.setRawHeader("Cookie", cookies.toUtf8());
    }
    request.setRawHeader(QByteArray("buvid"), buvid3Header.toUtf8());
    request.setRawHeader(QByteArray("buvid_fp"), QByteArray("d9a5c7d8f2e1b4a6c3b9e7f1a2d4c6b8"));

    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, clientQuality, cid, logTag,
                                                    epId, seasonId, seasonType,
                                                    bvid, aid,
                                                    cookies, buvid3Header, accessKey, userMid]() {
        handleSeasonPlayUrlResponse(reply, clientQuality, cid, logTag,
                                    false /*isStrategyA, fallback B*/,
                                    false /*isStrategyD*/,
                                    epId, seasonType, seasonId,
                                    bvid, aid,
                                    cookies, buvid3Header, accessKey, userMid);
    });
}

// =====================================================================
// 统一响应处理：解析 + 按顺序 A→B→D→C 多级 fallback
// =====================================================================
void PlayUrlManager::handleSeasonPlayUrlResponse(QNetworkReply *reply, int clientQuality, const QString &cid,
                                                  const QString &logTag, bool isStrategyA, bool isStrategyD,
                                                  const QString &epId, int seasonType, const QString &seasonId,
                                                  const QString &bvid, const QString &aid,
                                                  const QString &cookies, const QString &buvid3Header,
                                                  const QString &accessKey, int userMid)
{
    qDebug() << "[PlayUrlManager]" << logTag << "reply finished";

    // 请求完成，重置去重标志
    m_inFlightRequest = false;

    if (reply->error() != QNetworkReply::NoError) {
        int httpStatus = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        qWarning() << "[PlayUrlManager]" << logTag << "network error:" << reply->errorString()
                   << "HTTP status:" << httpStatus
                   << "url:" << reply->url().toString().left(200);
        reply->deleteLater();

        if (isStrategyA) {
            qWarning() << "[PlayUrlManager]" << logTag
                       << "Network error on Strategy-A → fallback to Strategy-B (PGC V2 wiliwili)";
            requestSeasonPlayUrlStrategyB(cid, clientQuality, epId, seasonId,
                                          bvid, aid,
                                          cookies, buvid3Header, accessKey, userMid, seasonType);
        } else if (!isStrategyD) {
            qWarning() << "[PlayUrlManager]" << logTag
                       << "Network error on Strategy-B → fallback to Strategy-D (PGC Web SeasonUrl WBI)";
            requestSeasonPlayUrlStrategyD(cid, clientQuality, epId, seasonType, seasonId,
                                          bvid, aid, QByteArray());
        } else {
            // 策略 D 网络错误（且有 aid/bvid）→ 最后 fallback 策略 C
            if (!aid.isEmpty() || !bvid.isEmpty()) {
                qWarning() << "[PlayUrlManager]" << logTag
                           << "Network error on Strategy-D → last-resort fallback to Strategy-C";
                requestSeasonPlayUrlStrategyC(cid, clientQuality, bvid, aid, QByteArray());
            } else {
                emit errorOccurred("获取番剧播放URL失败（网络错误）");
            }
        }
        return;
    }

    QByteArray data = reply->readAll();
    qDebug() << "[PlayUrlManager]" << logTag << "response size:" << data.size();

    QJsonDocument doc = QJsonDocument::fromJson(data);
    if (!doc.isObject()) {
        qWarning() << "[PlayUrlManager]" << logTag << "Response is NOT valid JSON";
        qDebug() << "[PlayUrlManager]" << logTag << "raw response(first 2000B):"
                 << QString::fromUtf8(data.left(2000));
        reply->deleteLater();

        if (isStrategyA) {
            qWarning() << "[PlayUrlManager]" << logTag
                       << "Invalid JSON on Strategy-A → fallback to Strategy-B (PGC V2 wiliwili)";
            requestSeasonPlayUrlStrategyB(cid, clientQuality, epId, seasonId,
                                          bvid, aid,
                                          cookies, buvid3Header, accessKey, userMid, seasonType);
        } else if (!isStrategyD) {
            qWarning() << "[PlayUrlManager]" << logTag
                       << "Invalid JSON on Strategy-B → fallback to Strategy-D (PGC Web WBI)";
            requestSeasonPlayUrlStrategyD(cid, clientQuality, epId, seasonType, seasonId,
                                          bvid, aid, QByteArray());
        } else if (!aid.isEmpty() || !bvid.isEmpty()) {
            qWarning() << "[PlayUrlManager]" << logTag
                       << "Invalid JSON on Strategy-D → last-resort fallback to Strategy-C";
            requestSeasonPlayUrlStrategyC(cid, clientQuality, bvid, aid, QByteArray());
        } else {
            emit errorOccurred("解析番剧播放URL失败");
        }
        return;
    }

    QJsonObject root = doc.object();
    const int code = root["code"].toInt();
    const QString message = root["message"].toString();
    const QStringList keys = root.keys();

    qDebug() << "[PlayUrlManager]" << logTag << "code:" << code << "message:" << message;
    qDebug() << "[PlayUrlManager]" << logTag << "top-level keys:" << keys;

    if (code != 0) {
        qWarning() << "[PlayUrlManager]" << logTag << "API returned non-zero code:" << message;
        qDebug() << "[PlayUrlManager]" << logTag << "raw response(first 2000B):"
                 << QString::fromUtf8(data.left(2000));
        reply->deleteLater();

        // =========== 关键 fallback 逻辑 ===========
        if (isStrategyA) {
            // 策略A失败（-351 / -400 / -401 等）→ 自动切换策略B
            qWarning() << "[PlayUrlManager]" << logTag
                       << "Strategy-A returned code=" << code
                       << "→ AUTO-FALLBACK to Strategy-B (PGC V2 wiliwili SeasonUrl2)";
            requestSeasonPlayUrlStrategyB(cid, clientQuality, epId, seasonId,
                                          bvid, aid,
                                          cookies, buvid3Header, accessKey, userMid, seasonType);
        } else if (!isStrategyD) {
            // 策略B失败 → 切换策略 D (PGC Web SeasonUrl + WBI + 番剧Referer)
            qWarning() << "[PlayUrlManager]" << logTag
                       << "Strategy-B returned code=" << code
                       << "→ AUTO-FALLBACK to Strategy-D (PGC Web /pgc/player/web/playurl + WBI)";
            requestSeasonPlayUrlStrategyD(cid, clientQuality, epId, seasonType, seasonId,
                                          bvid, aid, QByteArray());
        } else if (!aid.isEmpty() || !bvid.isEmpty()) {
            qWarning() << "[PlayUrlManager]" << logTag
                       << "Strategy-D still returned code=" << code
                       << "→ last-resort fallback to Strategy-C (UGC WBI)";
            requestSeasonPlayUrlStrategyC(cid, clientQuality, bvid, aid, QByteArray());
        } else {
            // 策略D失败且无可跳转策略
            emit errorOccurred(QString("番剧播放获取失败: %1").arg(message));
        }
        return;
    }

    // ===== code == 0，解析播放数据 =====
    // PGC V1 (root.data) + PGC V2 (root.result.video_info 或 root.result) 都兼容
    QJsonObject playData;
    if (root.contains("data") && !root["data"].toObject().isEmpty()) {
        playData = root["data"].toObject();
        qDebug() << "[PlayUrlManager]" << logTag << "playData from: data (standard PGC V1 format)";
    }
    if (playData.isEmpty() && root.contains("result")) {
        QJsonObject r = root["result"].toObject();
        if (r.contains("video_info") && !r["video_info"].toObject().isEmpty()) {
            playData = r["video_info"].toObject();
            qDebug() << "[PlayUrlManager]" << logTag << "playData from: result.video_info (PGC V2 format)";
        } else if (!r.isEmpty()) {
            playData = r;
            qDebug() << "[PlayUrlManager]" << logTag << "playData from: result (fallback wrapper)";
        }
    }

    if (playData.isEmpty()) {
        qWarning() << "[PlayUrlManager]" << logTag << "no playData extracted!";
        qDebug() << "[PlayUrlManager]" << logTag << "raw response(first 4000B):"
                 << QString::fromUtf8(data.left(4000));
        reply->deleteLater();

        if (isStrategyA) {
            qWarning() << "[PlayUrlManager]" << logTag
                       << "No playData on Strategy-A → fallback to Strategy-B";
            requestSeasonPlayUrlStrategyB(cid, clientQuality, epId, seasonId,
                                          bvid, aid,
                                          cookies, buvid3Header, accessKey, userMid, seasonType);
        } else if (!isStrategyD) {
            qWarning() << "[PlayUrlManager]" << logTag
                       << "No playData on Strategy-B → fallback to Strategy-D";
            requestSeasonPlayUrlStrategyD(cid, clientQuality, epId, seasonType, seasonId,
                                          bvid, aid, QByteArray());
        } else if (!aid.isEmpty() || !bvid.isEmpty()) {
            qWarning() << "[PlayUrlManager]" << logTag
                       << "No playData on Strategy-D → last-resort fallback to Strategy-C";
            requestSeasonPlayUrlStrategyC(cid, clientQuality, bvid, aid, QByteArray());
        } else {
            emit errorOccurred("番剧播放URL解析失败");
        }
        return;
    }

    qDebug() << "[PlayUrlManager]" << logTag << "playData keys:" << playData.keys();

    if (playData.contains("quality")) {
        qDebug() << "[PlayUrlManager]" << logTag << "SERVER actual quality(data.quality):"
                 << playData["quality"].toInt()
                 << "(we requested qn=" << clientQuality << ")";
    }
    if (playData.contains("accept_quality")) {
        qDebug() << "[PlayUrlManager]" << logTag << "accept_quality:"
                 << playData["accept_quality"].toArray();
    }

    if (playData.contains("support_formats")) {
        QJsonArray supportFormats = playData["support_formats"].toArray();
        qDebug() << "[PlayUrlManager]" << logTag << "support_formats count:" << supportFormats.size();
        for (const QJsonValue &f : supportFormats) {
            QJsonObject fObj = f.toObject();
            qDebug() << "    [support_format] quality:" << fObj["quality"].toInt()
                     << "new_description:" << fObj["new_description"].toString()
                     << "display_desc:" << fObj["display_desc"].toString();
        }
    }

    // ===== 升级策略 fallback 检测（A/B） =====
    //   SD = dash.video 只有 32/16 且 actualQ<=32 或 Only-FLV actualQ<=32
    //   Note: Only-FLV 路径如果 data.quality>=64（FLV 单文件 720P+），CDN mid=用户，也可接受为HD，
    //         不再触发升级策略。
    bool maxQualityOnlySd = false;
    int handleActualQ = playData.contains("quality") ? playData["quality"].toInt() : 0;
    if (playData.contains("dash")) {
        QJsonObject dashObj = playData["dash"].toObject();
        if (dashObj.contains("video")) {
            QJsonArray dashVideos = dashObj["video"].toArray();
            QSet<int> packedQualities;
            qDebug() << "[PlayUrlManager]" << logTag << "dash.video count:" << dashVideos.size();
            for (const QJsonValue &v : dashVideos) {
                QJsonObject vObj = v.toObject();
                const int vid = vObj["id"].toInt();
                packedQualities.insert(vid);
                qDebug() << "    [dash.video] id=" << vid
                         << "codecs:" << vObj["codecs"].toString()
                         << "bandwidth:" << vObj["bandwidth"].toInt();
            }
            QList<int> pq = packedQualities.values();
            std::sort(pq.begin(), pq.end(), std::greater<int>());
            qDebug() << "[PlayUrlManager]" << logTag << "dash.video packed qualities(sorted desc):" << pq
                     << "actualQ(data.quality)=" << handleActualQ;
            // dash.video 只有 16+32 两种且 actualQ<=32 → 真正 SD（未鉴权）
            if (pq.size() <= 2 && pq.contains(32) && pq.contains(16) && handleActualQ <= 32) {
                maxQualityOnlySd = true;
                qWarning() << "[PlayUrlManager]" << logTag
                           << "*** WARNING: server only packed 480P+360P "
                           << "(actualQ<=32 too). AUTH not succeed — CDN mid=0 likely.";
            } else {
                bool hasHd = false;
                for (int qid : pq) if (qid > 32) { hasHd = true; break; }
                if (hasHd || handleActualQ > 32) {
                    qDebug() << "[PlayUrlManager]" << logTag
                             << "*** OK: server packed >=720P stream (dash max="
                             << (pq.isEmpty() ? -1 : pq.first()) << " actualQ=" << handleActualQ
                             << ") — No upgrade needed, AUTH succeed mid≠0 likely";
                }
            }
        }
        if (dashObj.contains("audio")) {
            qDebug() << "[PlayUrlManager]" << logTag << "dash.audio count:"
                     << dashObj["audio"].toArray().size();
        }
    } else {
        qWarning() << "[PlayUrlManager]" << logTag << "NO DASH field — Only-FLV path."
                   << "actual data.quality=" << handleActualQ
                   << "(if >=64, means FLV 720P+ HD; no upgrade needed)";
        if (handleActualQ > 0 && handleActualQ <= 32) {
            maxQualityOnlySd = true;
            qWarning() << "[PlayUrlManager]" << logTag
                       << "Only-FLV actualQ=<=32 (≤480P) — Will try upgrade strategy D/C";
        }
    }

    // ========== 多级 fallback：SD 时按策略顺序 D → C 逐步提升 ==========
    //   策略 A/B（非 D）SD → 先试 策略 D（PGC Web SeasonUrl WBI，Web Cookie 鉴权成功率最高）
    //   策略 D 仍然 SD → 最后试 策略 C（UGC 视频 WBI 接口，需 aid/bvid）
    if (maxQualityOnlySd) {
        // 先把当前策略拿到的 playData 包装成 fallbackResp：
        // 如果后续所有升级策略都失败，至少保证可播 + 清晰度选项不空
        QJsonObject fallbackWrapper;
        fallbackWrapper["code"] = 0;
        fallbackWrapper["data"] = playData;
        QByteArray fallbackResp = QJsonDocument(fallbackWrapper).toJson(QJsonDocument::Compact);

        if (!isStrategyD) {
            // === A / B 只有 SD，还没试过 D ===
            // PC_APP SeasonUrl2 不认 Web Cookie（mid=0），但「纯 Web PGC SeasonUrl」
            // 才是 Web SESSDATA 用户正确的鉴权接口。优先试这个。
            qWarning() << "[PlayUrlManager]" << logTag
                       << "Only SD (≤480P) streams packed (PGC mid=0 auth fail)."
                       << "Has NOT tried Strategy-D yet → AUTO-FALLBACK to Strategy-D"
                       << "(PGC Web SeasonUrl /pgc/player/web/playurl + WBI + bangumi Referer)"
                       << "fallbackResp size:" << fallbackResp.size();
            reply->deleteLater();
            requestSeasonPlayUrlStrategyD(cid, clientQuality, epId, seasonType, seasonId,
                                          bvid, aid, fallbackResp);
            return;
        }

        // === 已经试过 D 还是只有 SD → 最后兜底策略 C（需 aid/bvid） ===
        if (!aid.isEmpty() || !bvid.isEmpty()) {
            qWarning() << "[PlayUrlManager]" << logTag
                       << "Strategy-D still only SD (≤480P) despite PGC Web auth!"
                       << "Has aid/bvid → LAST-RESORT fallback to Strategy-C (UGC WBI)"
                       << "fallbackResp size:" << fallbackResp.size();
            reply->deleteLater();
            requestSeasonPlayUrlStrategyC(cid, clientQuality, bvid, aid, fallbackResp);
            return;
        }

        // 试过 D 仍然 SD 且无 aid/bvid（没法调用策略 C）
        // 用已经拿到的 480P fallbackResp 直接解析，不 emit 错误避免死循环
        qWarning() << "[PlayUrlManager]" << logTag
                   << "All upgrade strategies exhausted. No aid/bvid for Strategy-C."
                   << "Using valid 480P fallback data directly (no retry). size:"
                   << fallbackResp.size();
        reply->deleteLater();
        parsePlayUrlData(fallbackResp, clientQuality, cid);
        return;
    }

    // 包装成标准 {code, data} 格式传递给 parsePlayUrlData
    QJsonObject wrapper;
    wrapper["code"] = 0;
    wrapper["data"] = playData;
    QJsonDocument wrapperDoc(wrapper);

    parsePlayUrlData(wrapperDoc.toJson(QJsonDocument::Compact), clientQuality, cid);

    reply->deleteLater();
}

// =====================================================================
// 策略 D：PGC Web V2 SeasonUrl + WBI 签名 + from_client=BILIBILI + 番剧 Referer
//   接口: https://api.bilibili.com/pgc/player/web/v2/playurl (V2)
//   签名: WBI (wts + w_rid)  NO appkey  NO MD5 sign
//   鉴权: Web SESSDATA Cookie（SESSDATA + DedeUserID + buvid3）
//   from_client: BILIBILI（浏览器网页端标识，不是 PC_APP！）
//   Referer: https://www.bilibili.com/bangumi/play/ep<epId>/  （番剧播放页！）
//
//   说明：这才是「浏览器端番剧播放页」真正调用的 HTTP 接口！
//         策略 A（WebVideoKey MD5签名 SeasonAndroidPlayUrl）错把 APP 端做法套用，导致 -351；
//         策略 B（V2 from_client=PC_APP）是 PC APP 专用协议，只认 access_key，不认 Web Cookie → 480P；
//         V1（/pgc/player/web/playurl 不带v2）对银魂/Re0等版权番剧也只返 FLV 480P；
//         V2 + from_client=BILIBILI 是浏览器网页端真实接口，服务器走 Web Cookie 鉴权 → DASH HD。
// =====================================================================
void PlayUrlManager::requestSeasonPlayUrlStrategyD(const QString &cid, int clientQuality,
                                                   const QString &epId, int seasonType, const QString &seasonId,
                                                   const QString &bvid, const QString &aid,
                                                   const QByteArray &fallbackResponse)
{
    const QString logTag = "PGC-Web";
    qDebug() << "[PlayUrlManager]" << logTag
             << "PATH: /pgc/player/web/v2/playurl (PGC Web V2 + WBI signed + from_client=BILIBILI + bangumi Referer, Web SESSDATA Cookie auth)";
    qDebug() << "[PlayUrlManager]" << logTag << "params:"
             << "cid=" << cid
             << "qn=" << clientQuality
             << "epId=" << epId
             << "seasonType=" << (seasonType > 0 ? seasonType : 1)
             << "seasonId=" << seasonId
             << "bvid=" << bvid
             << "aid=" << aid
             << "hasFallback=" << (!fallbackResponse.isEmpty());

    ++m_currentRequestId;
    int thisRequestId = m_currentRequestId;

    // ====== 关键：用 V2 接口 + from_client=BILIBILI（浏览器网页端标识）======
    //   V1(/pgc/player/web/playurl) 对银魂/Re0 等版权番剧只返 FLV 480P；
    //   V2(/pgc/player/web/v2/playurl) + from_client=BILIBILI 是浏览器网页端真实使用的接口，
    //   服务器会走 Web SESSDATA Cookie 鉴权路径（而非 PC APP access_key 路径），返回 DASH HD。
    QString url = "https://api.bilibili.com/pgc/player/web/v2/playurl";

    // fnval：至少 4048（DASH+HDR+4K+杜比+8K），与浏览器网页端一致
    const int PGC_WEB_V2_FNVAL = 4048;
    int fnval = PGC_WEB_V2_FNVAL;
    if (AppSettings *appSettings = AppSettings::instance()) {
        int userFnval = appSettings->getCodecFnval(appSettings->videoCodec());
        fnval = std::max(userFnval, PGC_WEB_V2_FNVAL);
    }

    LoginManager *loginMgr = LoginManager::instance();
    int userMid = 0;
    if (loginMgr) userMid = loginMgr->getCurrentUser().mid;

    // ===== 参数：与浏览器网页端真实请求完全对齐 =====
    //   from_client=BILIBILI 是关键！PC_APP 会让服务器只认 access_key，BILIBILI 才认 Web Cookie
    int st = seasonType > 0 ? seasonType : 1;
    QString params = QString("cid=%1&qn=%2&gaia_source=&from_client=BILIBILI&is_main_page=false&need_fragment=false&isGaiaAvoided=false&voice_balance=1&drm_tech_type=3&fourk=1&fnval=%3&fnver=0&module=bangumi&season_type=%4")
                         .arg(cid)
                         .arg(clientQuality)
                         .arg(fnval)
                         .arg(st);
    // season_id：版权番剧定位 season 信息必需，缺失时服务器会降级到仅 FLV 480P
    if (!seasonId.isEmpty()) {
        params += QString("&season_id=%1").arg(seasonId);
    }
    // mid：登录用户的 mid，Web PGC 协议用来定位 VIP 身份（与Cookie的DedeUserID一致即可）
    if (userMid > 0) {
        params += QString("&mid=%1").arg(userMid);
    }
    // ep_id：浏览器端番剧播放页必须带，用于定位具体的 episode
    if (!epId.isEmpty()) {
        params += QString("&ep_id=%1").arg(epId);
    }

    qDebug() << "[PlayUrlManager]" << logTag << "raw params (before WBI):" << params;

    // ===== WBI 签名 =====
    QString signedParams = WbiSigner::instance()->signParams(params);
    QString fullUrl = url + "?" + signedParams;

    qDebug() << "[PlayUrlManager]" << logTag << "full URL (first 700):" << fullUrl.left(700);

    QUrl qurl(fullUrl);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), USER_AGENT.toUtf8());

    // ===== Referer：必须是 番剧播放页（和浏览器真实请求一致！） =====
    //   epId 优先 → /bangumi/play/ep<id>/；兜底 ss<seasonId>/；再不济就通用根
    QString referer;
    if (!epId.isEmpty()) {
        referer = QString("https://www.bilibili.com/bangumi/play/ep%1/").arg(epId);
    } else if (!seasonId.isEmpty()) {
        referer = QString("https://www.bilibili.com/bangumi/play/ss%1/").arg(seasonId);
    } else {
        referer = "https://www.bilibili.com/bangumi/play/";
    }
    request.setRawHeader(QByteArray("Referer"), referer.toUtf8());
    request.setRawHeader(QByteArray("Origin"),  ORIGIN.toUtf8());
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));
    request.setRawHeader(QByteArray("Accept-Language"), QByteArray("zh-CN,zh;q=0.9,en;q=0.8"));
    // 2026-10-15：删掉原先写死的 Connection: keep-alive —— 启用 HTTP/2 后该头
    // 属非法头（RFC 9113 禁止 h2 携带 connection 类头）。连接复用由共享池自身
    // 行为决定：h1.1 默认就是 keep-alive，h2 靠多路复用，无需这个提示。
    request.setRawHeader(QByteArray("Cache-Control"), QByteArray("no-cache"));

    // 注意：loginMgr 已在本函数顶部 L4226 声明（用于取 userMid），这里复用避免重复定义
    QString cookies = loginMgr ? loginMgr->getCookies() : QString();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
        qDebug() << "[PlayUrlManager]" << logTag << "adding Cookie header, length:" << cookies.size();
    } else {
        qWarning() << "[PlayUrlManager]" << logTag << "NO COOKIES — guest mode, max 480P expected";
    }

    // ===== buvid：必须是 36 位标准 UUID（截掉 Cookie.buvid3 的 infoc 尾）=====
    QString rawBuvid;
    if (loginMgr) rawBuvid = loginMgr->getCurrentUser().buvid3;
    QString buvid3Header;
    if (!rawBuvid.isEmpty() && rawBuvid.size() >= 36) {
        buvid3Header = rawBuvid.left(36);
    } else if (!rawBuvid.isEmpty()) {
        buvid3Header = rawBuvid;
    } else {
        buvid3Header = "XY8D30F8-E10D-4B3A-B9C6-78D2E1C4F7A0";
    }
    request.setRawHeader(QByteArray("buvid"),    buvid3Header.toUtf8());
    request.setRawHeader(QByteArray("buvid_fp"), QByteArray("d9a5c7d8f2e1b4a6c3b9e7f1a2d4c6b8"));

    qDebug() << "[PlayUrlManager]" << logTag << "final headers preview:"
             << "Referer=" << referer
             << "buvid=" << buvid3Header << "(len=" << buvid3Header.size() << ")";

    QNetworkReply *reply = m_networkManager->get(request);
    reply->setProperty("quality", clientQuality);
    reply->setProperty("requestId", thisRequestId);
    reply->setProperty("cid", cid);

    // ===== 自包含 lambda（类似策略 C）：正确持有/传递 fallbackResponse (B 的有效 480P 数据) =====
    //   不使用 handleSeasonPlayUrlResponse，避免 handle 调 C 时丢失 B 的 fallbackResponse。
    connect(reply, &QNetworkReply::finished, this, [this, reply, cid, clientQuality, logTag,
                                                    bvid, aid, fallbackResponse]() {
        qDebug() << "[PlayUrlManager]" << logTag << "reply finished";
        m_inFlightRequest = false;

        int thisRequestId = reply->property("requestId").toInt();
        if (thisRequestId != m_currentRequestId) {
            qDebug() << "[PlayUrlManager]" << logTag << "stale response — skip";
            reply->deleteLater();
            return;
        }

        // --- 统一：D 失败 → 兜底到策略 C，并把 fallbackResponse (B 的有效数据) 带上 ---
        auto fallbackToC = [&](const QString &reason) {
            bool canTryC = !aid.isEmpty() || !bvid.isEmpty();
            if (canTryC) {
                qWarning() << "[PlayUrlManager]" << logTag
                           << "D FAILED (" << reason << ") → LAST-RESORT fallback to Strategy-C (UGC WBI)."
                           << "Preserving B's valid 480P fallbackResp (size="
                           << fallbackResponse.size() << ")";
                requestSeasonPlayUrlStrategyC(cid, clientQuality, bvid, aid, fallbackResponse);
            } else if (!fallbackResponse.isEmpty()) {
                qWarning() << "[PlayUrlManager]" << logTag
                           << "D FAILED (" << reason << "), no aid/bvid for C."
                           << "Silently using B's 480P fallback (size=" << fallbackResponse.size() << ")";
                parsePlayUrlData(fallbackResponse, clientQuality, cid);
            } else {
                emit errorOccurred(QString("番剧清晰度提升失败：PGC Web 接口失败(%1)，且无有效兜底数据").arg(reason));
            }
        };

        if (reply->error() != QNetworkReply::NoError) {
            int httpStatus = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
            qWarning() << "[PlayUrlManager]" << logTag << "network error:" << reply->errorString()
                       << "HTTP:" << httpStatus;
            reply->deleteLater();
            fallbackToC(QString("network HTTP %1").arg(httpStatus));
            return;
        }

        QByteArray data = reply->readAll();
        qDebug() << "[PlayUrlManager]" << logTag << "response size:" << data.size();

        QJsonDocument doc = QJsonDocument::fromJson(data);
        if (!doc.isObject()) {
            qWarning() << "[PlayUrlManager]" << logTag << "NOT valid JSON";
            reply->deleteLater();
            fallbackToC("JSON parse");
            return;
        }
        QJsonObject root = doc.object();
        int code = root["code"].toInt();
        QString msg = root["message"].toString();
        if (code != 0) {
            qWarning() << "[PlayUrlManager]" << logTag << "code=" << code << "msg=" << msg;
            qDebug() << "[PlayUrlManager]" << logTag << "raw (first 2000B):" << QString::fromUtf8(data.left(2000));
            reply->deleteLater();
            fallbackToC(QString("API code=%1 %2").arg(code).arg(msg));
            return;
        }

        // ---- extract playData: SeasonUrl Web returns root.data (PGC standard A format) ----
        QJsonObject playData;
        if (root.contains("data") && !root["data"].toObject().isEmpty()) {
            playData = root["data"].toObject();
            qDebug() << "[PlayUrlManager]" << logTag << "playData from: root.data (PGC standard format)";
        }
        if (playData.isEmpty() && root.contains("result")) {
            QJsonObject r = root["result"].toObject();
            if (r.contains("video_info") && !r["video_info"].toObject().isEmpty()) {
                playData = r["video_info"].toObject();
                qDebug() << "[PlayUrlManager]" << logTag << "playData from: result.video_info";
            } else if (!r.isEmpty()) {
                playData = r;
                qDebug() << "[PlayUrlManager]" << logTag << "playData from: result (fallback)";
            }
        }
        if (playData.isEmpty()) {
            qWarning() << "[PlayUrlManager]" << logTag << "code=0 but NO playData!";
            reply->deleteLater();
            fallbackToC("no playData in response");
            return;
        }

        qDebug() << "[PlayUrlManager]" << logTag << "playData keys:" << playData.keys();
        if (playData.contains("quality")) {
            qDebug() << "[PlayUrlManager]" << logTag << "SERVER actual quality(data.quality):"
                     << playData["quality"].toInt() << "(requested qn=" << clientQuality << ")";
        }
        // ===== 诊断字段：has_paid/can_watch_reason/status/is_preview/error_code =====
        if (playData.contains("has_paid"))
            qDebug() << "[PlayUrlManager]" << logTag << "has_paid=" << playData["has_paid"].toInt();
        if (playData.contains("status"))
            qDebug() << "[PlayUrlManager]" << logTag << "status=" << playData["status"].toString();
        if (playData.contains("is_preview"))
            qDebug() << "[PlayUrlManager]" << logTag << "is_preview=" << playData["is_preview"].toInt();
        if (playData.contains("error_code"))
            qDebug() << "[PlayUrlManager]" << logTag << "error_code=" << playData["error_code"].toInt();
        if (playData.contains("can_watch_reason"))
            qDebug() << "[PlayUrlManager]" << logTag << "can_watch_reason=" << playData["can_watch_reason"].toString();

        // ===== 关键诊断：durls（复数）可能包含多清晰度FLV流 =====
        //   PGC V2 接口 Only-FLV 模式下，durls 是数组，每个元素含 {quality, durl[]}，
        //   可能包含 1080P/720P/480P/360P 多个 FLV 单文件流！
        if (playData.contains("durls")) {
            QJsonArray durlsArr = playData["durls"].toArray();
            qDebug() << "[PlayUrlManager]" << logTag << "durls (plural) count:" << durlsArr.size();
            for (int i = 0; i < durlsArr.size(); ++i) {
                QJsonObject durlObj = durlsArr[i].toObject();
                int durlQ = durlObj.contains("quality") ? durlObj["quality"].toInt() : -1;
                int durlCnt = durlObj.contains("durl") ? durlObj["durl"].toArray().size() : 0;
                QString fmt = durlObj.contains("format") ? durlObj["format"].toString() : "";
                qDebug() << "    [durls[" << i << "]] quality=" << durlQ
                         << "format=" << fmt << "durl_count=" << durlCnt;
            }
        }
        if (playData.contains("durl")) {
            QJsonArray durlArr = playData["durl"].toArray();
            qDebug() << "[PlayUrlManager]" << logTag << "durl (singular) count:" << durlArr.size();
            if (!durlArr.isEmpty()) {
                QJsonObject firstD = durlArr[0].toObject();
                QString firstUrl = firstD["url"].toString();
                // CDN URL 中 mid= 参数表明鉴权身份：mid=0=游客(480P)，mid>0=登录用户(HD)
                qDebug() << "[PlayUrlManager]" << logTag << "durl[0] url (first 300):" << firstUrl.left(300);
            }
        }

        // ---- 检查是否真的有 HD 流（不只是 support_formats 宣称） ----
        //   HD = dash.video 中至少有 quality id > 32（720P+），或者 FLV 模式下 data.quality > 32
        //   （CDN URL mid=登录用户时 FLV 单文件 qn=64 qn=80 等实际是 720P/1080P，只是不是DASH分片）
        bool maxQualityOnlySd = false;
        int actualQ = playData.contains("quality") ? playData["quality"].toInt() : 0;
        if (playData.contains("dash")) {
            QJsonObject dashObj = playData["dash"].toObject();
            if (dashObj.contains("video")) {
                QJsonArray dashVideos = dashObj["video"].toArray();
                QSet<int> packedQualities;
                qDebug() << "[PlayUrlManager]" << logTag << "dash.video count:" << dashVideos.size();
                for (const QJsonValue &v : dashVideos) {
                    QJsonObject vObj = v.toObject();
                    packedQualities.insert(vObj["id"].toInt());
                }
                QList<int> pq = packedQualities.values();
                std::sort(pq.begin(), pq.end(), std::greater<int>());
                qDebug() << "[PlayUrlManager]" << logTag << "dash.video packed qualities (desc):" << pq
                         << "server actual data.quality=" << actualQ;
                if (pq.size() <= 2 && pq.contains(32) && pq.contains(16) && actualQ <= 32) {
                    maxQualityOnlySd = true;
                    qWarning() << "[PlayUrlManager]" << logTag
                               << "D still packed ONLY 480P+360P — PGC Web auth not recognized"
                               << "(CDN mid=0 likely). Try support_formats advertised? actualQ=" << actualQ;
                } else {
                    bool hasHdQ = false;
                    for (int qid : pq) if (qid > 32) { hasHdQ = true; break; }
                    if (hasHdQ || actualQ > 32) {
                        qDebug() << "[PlayUrlManager]" << logTag
                                 << "*** SUCCESS: Strategy-D DASH packed >=720P stream (max packed="
                                 << (pq.isEmpty() ? -1 : pq.first())
                                 << " actualQ=" << actualQ
                                 << ") — AUTH recognized, CDN mid!=0 expected";
                    }
                }
            }
        } else {
            // No DASH → FLV/durl/durls path
            // 检查 durls（复数）是否包含 HD FLV 流
            bool durlsHasHd = false;
            if (playData.contains("durls")) {
                QJsonArray durlsArr = playData["durls"].toArray();
                for (const QJsonValue &dv : durlsArr) {
                    int dq = dv.toObject()["quality"].toInt();
                    if (dq > 32) { durlsHasHd = true; break; }
                }
            }
            qWarning() << "[PlayUrlManager]" << logTag
                       << "NO DASH — Only-FLV path, data.quality=" << actualQ
                       << "durlsHasHd=" << durlsHasHd
                       << "(durls HD means multi-quality FLV streams available)";
            if (durlsHasHd) {
                // durls 中有 HD FLV 流 → parsePlayUrlData 会从 durls 选最佳清晰度，不算 SD
                qDebug() << "[PlayUrlManager]" << logTag
                         << "*** SUCCESS: durls contains HD FLV streams — AUTH recognized, will select best quality in parsePlayUrlData";
            } else if (actualQ > 0 && actualQ <= 32) {
                maxQualityOnlySd = true;
                qWarning() << "[PlayUrlManager]" << logTag
                           << "Only-FLV D still actualQ=<=32 (≤480P), durls has no HD — PGC Web auth NOT succeed.";
            } else if (actualQ >= 64) {
                qDebug() << "[PlayUrlManager]" << logTag
                         << "*** SUCCESS: Only-FLV D actualQ=" << actualQ
                         << " (>=64 = 720P+ HD FLV single-file stream). AUTH recognized, mid≠0!";
            }
        }

        // ---- wrap D data into {code,data} ----
        QJsonObject wrapper;
        wrapper["code"] = 0;
        wrapper["data"] = playData;
        QByteArray wrappedD = QJsonDocument(wrapper).toJson(QJsonDocument::Compact);

        if (maxQualityOnlySd) {
            // D 仍然 SD：有 aid/bvid → C (带上 D wrapped 作为 fallback)；否则静默用 D 或 B 的 fallback
            if (!aid.isEmpty() || !bvid.isEmpty()) {
                qWarning() << "[PlayUrlManager]" << logTag
                           << "D still only SD (≤480P). Has aid/bvid → last-resort Strategy-C."
                           << "Using D's wrapped response as fallbackResp (size=" << wrappedD.size() << ")";
                // 如果之前没有 B 的 fallbackResp（例如直接从 B code!=0 → D 过来的），就用 D 的数据
                QByteArray fr = !fallbackResponse.isEmpty() ? fallbackResponse : wrappedD;
                reply->deleteLater();
                requestSeasonPlayUrlStrategyC(cid, clientQuality, bvid, aid, fr);
                return;
            }
            qWarning() << "[PlayUrlManager]" << logTag
                       << "D still SD, no aid/bvid for Strategy-C. Using D's 480P data. size:" << wrappedD.size();
            reply->deleteLater();
            parsePlayUrlData(wrappedD, clientQuality, cid);
            return;
        }

        // HD success! 策略 D 成功拿到了 1080P+ 高清晰度流 → 播放
        qDebug() << "[PlayUrlManager]" << logTag << "*** D HD OK: calling parsePlayUrlData with D's data.";
        parsePlayUrlData(wrappedD, clientQuality, cid);
        reply->deleteLater();
    });
}

// =====================================================================
// 策略 C：浏览器 WBI 接口 /x/player/wbi/playurl（与普通视频 getPlayUrl 同一套）
//   鉴权：Web SESSDATA Cookie（登录态）
//   说明：番剧对应的 aid/bvid 走普通视频 UGC 播放接口也能拿到同一集的流，
//         且 Web Cookie (SESSDATA + DedeUserID + buvid3) 在此接口能被正确识别，
//         返回 mid=当前登录用户 的高清晰度（1080P+）CDN URL。
// =====================================================================
void PlayUrlManager::requestSeasonPlayUrlStrategyC(const QString &cid, int clientQuality,
                                                   const QString &bvid, const QString &aid,
                                                   const QByteArray &fallbackResponse)
{
    const QString logTag = "WBI-UGC";
    qDebug() << "[PlayUrlManager]" << logTag << "PATH: browser /x/player/wbi/playurl (WBI signed, Cookie auth)";
    qDebug() << "[PlayUrlManager]" << logTag << "params:"
             << "cid=" << cid
             << "qn=" << clientQuality
             << "bvid=" << bvid
             << "aid=" << aid
             << "hasFallback=" << (!fallbackResponse.isEmpty());

    ++m_currentRequestId;
    int thisRequestId = m_currentRequestId;

    QString url = "https://api.bilibili.com/x/player/wbi/playurl";

    AppSettings *appSettings = AppSettings::instance();
    int fnval = appSettings ? appSettings->getCodecFnval(appSettings->videoCodec()) : 4048;

    // ========================================================================
    // 重要：此处参数 / 请求头 必须与 getPlayUrl (普通视频成功链路) 严格对齐！
    //   错漏会导致 B站 WBI 接口判定为异常请求 → 只返回空的 v_voucher 占位(101B)
    //   普通视频成功的构造为：appkey=...&avid=&cid=&qn=&fnval=&fnver=0&fourk=1&platform=pc
    // ========================================================================
    // 1) 参数：强制加上 appkey=APP_KEY（getPlayUrl 里就有）
    //    且必须用 avid（而非 bvid），biliuwp-lite 经验：avid 比 bvid 更稳
    QString params;
    if (!aid.isEmpty()) {
        params = QString("appkey=%1&avid=%2")
                     .arg(APP_KEY)
                     .arg(aid);
    } else if (!bvid.isEmpty()) {
        // 没有 avid 时兜底用 bvid
        params = QString("appkey=%1&bvid=%2")
                     .arg(APP_KEY)
                     .arg(bvid);
    } else {
        qWarning() << "[PlayUrlManager]" << logTag << "NEITHER aid NOR bvid available — cannot call WBI UGC API, abort Strategy-C";
        // 无参数：直接用 fallback（不再 emit 错误触发 QML retry）
        if (!fallbackResponse.isEmpty()) {
            qWarning() << "[PlayUrlManager]" << logTag
                       << "*** FALLBACK-SILENT: neither aid nor bvid. Using B's 480P data directly."
                       << "fallback size:" << fallbackResponse.size();
            parsePlayUrlData(fallbackResponse, clientQuality, cid);
        } else {
            emit errorOccurred("番剧清晰度提升失败：缺少aid/bvid（只能480P）");
        }
        return;
    }
    params += QString("&cid=%1").arg(cid);
    if (clientQuality > 0) {
        params += QString("&qn=%1").arg(clientQuality);
    }
    params += QString("&fnval=%1&fnver=0&fourk=1&platform=pc").arg(fnval);

    QString signedParams = WbiSigner::instance()->signParams(params);
    QString fullUrl = url + "?" + signedParams;

    qDebug() << "[PlayUrlManager]" << logTag << "full URL (first 600):" << fullUrl.left(600);

    QUrl qurl(fullUrl);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), USER_AGENT.toUtf8());
    // 2) Referer：与 getPlayUrl 一致，使用全局固定 REFERER (= https://www.bilibili.com)
    //    之前动态拼接 "/video/<bvid>" 虽看似更"像真的"，但与 getPlayUrl 成功链路不一致
    //    设备指纹校验要求 Referer 必须为站点根或视频通用 Referer
    request.setRawHeader(QByteArray("Referer"), REFERER.toUtf8());
    request.setRawHeader(QByteArray("Origin"),  ORIGIN.toUtf8());
    request.setRawHeader(QByteArray("Accept"), QByteArray("application/json, text/plain, */*"));
    request.setRawHeader(QByteArray("Accept-Language"), QByteArray("zh-CN,zh;q=0.9,en;q=0.8"));
    // 2026-10-15：删掉原先写死的 Connection: keep-alive —— 启用 HTTP/2 后该头
    // 属非法头（RFC 9113 禁止 h2 携带 connection 类头）。连接复用由共享池自身
    // 行为决定：h1.1 默认就是 keep-alive，h2 靠多路复用，无需这个提示。
    request.setRawHeader(QByteArray("Cache-Control"), QByteArray("no-cache"));

    LoginManager *loginMgr = LoginManager::instance();
    QString cookies = loginMgr ? loginMgr->getCookies() : QString();
    if (!cookies.isEmpty()) {
        request.setRawHeader("Cookie", cookies.toUtf8());
        qDebug() << "[PlayUrlManager]" << logTag << "adding Cookie header, length:" << cookies.size();
    } else {
        qWarning() << "[PlayUrlManager]" << logTag << "NO COOKIES — guest mode, max 480P expected";
    }

    // 3) buvid header：格式必须是 36 位标准 UUID（8-4-4-4-12），**绝对不能带 "infoc" 后缀**！
    //    B站接口 buvid 字段是 "设备ID"，Cookie 里 buvid3=xxx...infoc 是 "Cookie存的设备ID"。
    //    若把带 infoc 的值（48 字符）塞到 buvid header：
    //      → 服务器判定为无效设备指纹 → 鉴权降级 → 只返回 v_voucher 空响应 (101B)
    //    与 getPlayUrl 一致：取 Cookie.buvid3 的前 36 字符（UUID部分）
    QString rawBuvid;
    if (loginMgr) rawBuvid = loginMgr->getCurrentUser().buvid3;
    QString buvid3Header;
    if (!rawBuvid.isEmpty() && rawBuvid.size() >= 36) {
        buvid3Header = rawBuvid.left(36);   // 截掉 infoc 尾
    } else if (!rawBuvid.isEmpty()) {
        buvid3Header = rawBuvid;             // 兜底：原样（虽短但可能是 UUID）
    } else {
        // 与 getPlayUrl 完全一致的默认值（36位 UUID）
        buvid3Header = "XY8D30F8-E10D-4B3A-B9C6-78D2E1C4F7A0";
    }
    request.setRawHeader(QByteArray("buvid"),    buvid3Header.toUtf8());
    // 4) buvid_fp：与 getPlayUrl 完全一致的固定 32 位十六进制指纹
    request.setRawHeader(QByteArray("buvid_fp"), QByteArray("d9a5c7d8f2e1b4a6c3b9e7f1a2d4c6b8"));

    qDebug() << "[PlayUrlManager]" << logTag << "final headers preview:"
             << "UA=Chrome(120) Referer=" << REFERER
             << "buvid=" << buvid3Header << "(len=" << buvid3Header.size() << ")"
             << "Origin=" << ORIGIN;

    QNetworkReply *reply = m_networkManager->get(request);
    reply->setProperty("quality", clientQuality);
    reply->setProperty("requestId", thisRequestId);
    reply->setProperty("cid", cid);

    connect(reply, &QNetworkReply::finished, this, [this, reply, cid, clientQuality, logTag, fallbackResponse]() {
        qDebug() << "[PlayUrlManager]" << logTag << "reply finished";
        m_inFlightRequest = false;

        // ===== 辅助 lambda：静默使用 fallback（策略 B 已经拿到的 480P 可播放数据） =====
        // 只要 fallbackResponse 非空，就不 emit errorOccurred，避免 QML 重试死循环
        auto useFallbackOrError = [&](const QString &failReason) {
            if (!fallbackResponse.isEmpty()) {
                qWarning() << "[PlayUrlManager]" << logTag
                           << "*** FALLBACK-SILENT: Strategy C failed (" << failReason
                           << ") but we have Strategy B's valid 480P playData cached."
                           << "Using fallback (no error signal, no QML retry). Data size:"
                           << fallbackResponse.size();
                parsePlayUrlData(fallbackResponse, clientQuality, cid);
            } else {
                emit errorOccurred(QString("番剧清晰度提升失败（Strategy C %1），只能480P且重试可能无效").arg(failReason));
            }
        };

        int thisRequestId = reply->property("requestId").toInt();
        if (thisRequestId != m_currentRequestId) {
            qDebug() << "[PlayUrlManager]" << logTag << "stale response (requestId mismatch) — skip";
            reply->deleteLater();
            return;
        }

        if (reply->error() != QNetworkReply::NoError) {
            int httpStatus = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
            qWarning() << "[PlayUrlManager]" << logTag << "network error:" << reply->errorString()
                       << "HTTP status:" << httpStatus;
            reply->deleteLater();
            useFallbackOrError(QString("network error HTTP %1").arg(httpStatus));
            return;
        }

        QByteArray data = reply->readAll();
        qDebug() << "[PlayUrlManager]" << logTag << "response size:" << data.size();

        QJsonDocument doc = QJsonDocument::fromJson(data);
        if (!doc.isObject()) {
            qWarning() << "[PlayUrlManager]" << logTag << "response NOT valid JSON";
            reply->deleteLater();
            useFallbackOrError("JSON parse error");
            return;
        }
        QJsonObject root = doc.object();
        int code = root["code"].toInt();
        if (code != 0) {
            QString msg = root["message"].toString();
            qWarning() << "[PlayUrlManager]" << logTag << "API returned non-zero code=" << code
                       << "message:" << msg;
            qDebug() << "[PlayUrlManager]" << logTag << "raw response (first 2000B):"
                     << QString::fromUtf8(data.left(2000));
            reply->deleteLater();
            useFallbackOrError(QString("code=%1 %2").arg(code).arg(msg));
            return;
        }

        // ===== code == 0，但是还要强校验：响应里必须真的有 视频 数据 =====
        // Bug #log52：code=0 且 data.size()=101B，只有 "v_voucher"，没有 dash/durl/support_formats
        // 这种情况下调用 parsePlayUrlData 会：发射假的 qualityList → dashVideoUrls 空 → errorOccurred → QML 死循环
        // 必须检测出来并走 fallback。
        QJsonObject dataObj = root.contains("data") ? root["data"].toObject() : QJsonObject();
        const bool hasDash = dataObj.contains("dash") && !dataObj["dash"].toObject().isEmpty();
        const bool hasDurl = dataObj.contains("durl") && !dataObj["durl"].toArray().isEmpty();
        const bool hasSupport = dataObj.contains("support_formats") && dataObj["support_formats"].toArray().size() > 0;
        const bool looksEmpty = data.size() < 800 || (!hasDash && !hasDurl);

        if (looksEmpty) {
            qWarning() << "[PlayUrlManager]" << logTag
                       << "code=0 BUT EMPTY VIDEO PAYLOAD! size=" << data.size()
                       << "keys=" << root.keys()
                       << "hasDash=" << hasDash << "hasDurl=" << hasDurl
                       << "hasSupportFormats=" << hasSupport;
            qDebug() << "[PlayUrlManager]" << logTag << "raw (first 500B):" << QString::fromUtf8(data.left(500));
            reply->deleteLater();
            useFallbackOrError(QString("code=0 but empty payload (no dash/durl, size=%1)").arg(data.size()));
            return;
        }

        qDebug() << "[PlayUrlManager]" << logTag << "code=0 SUCCESS (hasDash=" << hasDash
                 << "hasDurl=" << hasDurl << "supportFormats="
                 << (hasSupport ? dataObj["support_formats"].toArray().size() : 0)
                 << ") — parsing with real Cookie auth!";
        parsePlayUrlData(data, clientQuality, cid);
        reply->deleteLater();
    });
}

void PlayUrlManager::getBangumiByEpId(const QString &epId)
{
    qDebug() << "[PlayUrlManager] getBangumiByEpId epId:" << epId;
    m_requestedEpId = epId;
    getSeasonDetail(epId, "ep");
}

void PlayUrlManager::getBangumiBySeasonId(const QString &seasonId)
{
    qDebug() << "[PlayUrlManager] getBangumiBySeasonId seasonId:" << seasonId;
    m_requestedEpId.clear();   // 通过 season_id 打开时，不指定具体 ep，让 parseSeasonDetail 自己选（默认第1集或最新一集）
    getSeasonDetail(seasonId, "season");
}

void PlayUrlManager::parseSeasonDetail(const QJsonObject &dataObj, VideoDetail &detail, const QString &requestedEpId)
{
    // 解析番剧基本信息（PC API 格式）
    detail.isBangumi = true;
    detail.seasonId = QString::number(dataObj["season_id"].toVariant().toLongLong());
    
    // PC API 使用 season_title 字段
    detail.bangumiTitle = dataObj["season_title"].toString();
    if (detail.bangumiTitle.isEmpty()) {
        detail.bangumiTitle = dataObj["title"].toString();
    }
    detail.title = detail.bangumiTitle;
    
    detail.bangumiCover = dataObj["cover"].toString();
    detail.pic = detail.bangumiCover;
    
    // PC API 可能没有 total 字段
    if (dataObj.contains("total")) {
        detail.bangumiTotalCount = dataObj["total"].toInt();
    }
    if (dataObj.contains("index_format")) {
        detail.bangumiIndexFormat = dataObj["index_format"].toString();
    }
    
    // PC API 使用 type 字段
    if (dataObj.contains("type")) {
        detail.seasonType = dataObj["type"].toInt(1);
    } else {
        detail.seasonType = dataObj["season_type"].toInt(1);
    }
    
    qDebug() << "[PlayUrlManager] parseSeasonDetail title:" << detail.title 
             << "seasonId:" << detail.seasonId 
             << "total:" << detail.bangumiTotalCount
             << "seasonType:" << detail.seasonType
             << "requestedEpId:" << requestedEpId;
    
    // 获取当前 ep_id 和 cid
    if (dataObj.contains("episodes")) {
        QJsonArray episodes = dataObj["episodes"].toArray();
        qDebug() << "[PlayUrlManager] parseSeasonDetail episodes count:" << episodes.size();
        // [DIAG] 电影无法播放排查：打印前 3 个 ep 的关键字段（release_date/long_title 为空会导致下方"已上线"判断失败）
        qWarning() << "[DIAG][parseSeasonDetail] episodes:" << episodes.size();
        for (int i = 0; i < episodes.size() && i < 3; i++) {
            QJsonObject ep = episodes[i].toObject();
            qWarning() << "[DIAG][parseSeasonDetail] ep[" << i << "] id:" << ep["id"].toVariant().toLongLong()
                       << "cid:" << ep["cid"].toVariant().toLongLong()
                       << "long_title:" << ep["long_title"].toString()
                       << "release_date:" << ep["release_date"].toString();
        }

        // 优先匹配请求的 epId
        bool foundMatch = false;
        if (!requestedEpId.isEmpty()) {
            for (int i = 0; i < episodes.size(); i++) {
                QJsonObject ep = episodes[i].toObject();
                QString epId = QString::number(ep["id"].toVariant().toLongLong());
                if (epId == requestedEpId) {
                    detail.epId = epId;
                    detail.cid = QString::number(ep["cid"].toVariant().toLongLong());
                    detail.aid = QString::number(ep["aid"].toVariant().toLongLong());
                    detail.bvid = ep["bvid"].toString();
                    if (ep.contains("release_date")) {
                        detail.pubdate = ep["release_date"].toVariant().toLongLong();
                    }
                    foundMatch = true;
                    qDebug() << "[PlayUrlManager] parseSeasonDetail matched ep:" << detail.epId
                             << "bvid:" << detail.bvid
                             << "cid:" << detail.cid;
                    break;
                }
            }
        }

        // 如果没有匹配的 epId，找第一个已上线的 episode 作为默认
        if (!foundMatch) {
            for (int i = 0; i < episodes.size(); i++) {
                QJsonObject ep = episodes[i].toObject();
                // PC API 可能没有 release_date，但 long_title 存在表示已上线
                QString releaseDate = ep["release_date"].toString();
                QString longTitle = ep["long_title"].toString();
                if (!releaseDate.isEmpty() || !longTitle.isEmpty()) {
                    detail.epId = QString::number(ep["id"].toVariant().toLongLong());
                    detail.cid = QString::number(ep["cid"].toVariant().toLongLong());
                    detail.aid = QString::number(ep["aid"].toVariant().toLongLong());
                    detail.bvid = ep["bvid"].toString();
                    if (ep.contains("release_date")) {
                        detail.pubdate = ep["release_date"].toVariant().toLongLong();
                    }
                    foundMatch = true;

                    qDebug() << "[PlayUrlManager] parseSeasonDetail first ep (fallback):" << detail.epId
                             << "bvid:" << detail.bvid
                             << "cid:" << detail.cid;
                    break;
                }
            }
        }

        // 兜底：电影类正片 long_title 和 release_date 常为空（上方条件全部跳过），
        // cid 一直拿不到会导致 QML 侧无限重发 season 请求。直接取第一个 ep。
        if (!foundMatch && episodes.size() > 0) {
            QJsonObject ep = episodes[0].toObject();
            detail.epId = QString::number(ep["id"].toVariant().toLongLong());
            detail.cid = QString::number(ep["cid"].toVariant().toLongLong());
            detail.aid = QString::number(ep["aid"].toVariant().toLongLong());
            detail.bvid = ep["bvid"].toString();
            qWarning() << "[DIAG][parseSeasonDetail] fallback ep[0], cid:" << detail.cid
                       << "epId:" << detail.epId << "bvid:" << detail.bvid;
        }
    } else if (dataObj.contains("sections")) {
        // 电影类可能没有顶层 episodes，正片在 sections[].episodes 里
        QJsonArray sections = dataObj["sections"].toArray();
        for (int s = 0; s < sections.size(); s++) {
            QJsonArray eps = sections[s].toObject()["episodes"].toArray();
            if (eps.size() > 0) {
                QJsonObject ep = eps[0].toObject();
                detail.epId = QString::number(ep["id"].toVariant().toLongLong());
                detail.cid = QString::number(ep["cid"].toVariant().toLongLong());
                detail.aid = QString::number(ep["aid"].toVariant().toLongLong());
                detail.bvid = ep["bvid"].toString();
                qWarning() << "[DIAG][parseSeasonDetail] from sections[" << s << "] cid:" << detail.cid
                           << "epId:" << detail.epId << "bvid:" << detail.bvid;
                break;
            }
        }
    } else if (dataObj.contains("ep_id") || dataObj.contains("cid")) {
        // 通过 ep_id 查询时的单集结构
        if (dataObj.contains("ep_id")) {
            detail.epId = QString::number(dataObj["ep_id"].toVariant().toLongLong());
        }
        if (dataObj.contains("cid")) {
            detail.cid = QString::number(dataObj["cid"].toVariant().toLongLong());
        }
        if (dataObj.contains("aid")) {
            detail.aid = QString::number(dataObj["aid"].toVariant().toLongLong());
        }
        if (dataObj.contains("bvid")) {
            detail.bvid = dataObj["bvid"].toString();
        }
        qDebug() << "[PlayUrlManager] parseSeasonDetail single ep:" << detail.epId 
                 << "bvid:" << detail.bvid
                 << "cid:" << detail.cid;
    }
    
    qDebug() << "[PlayUrlManager] parseSeasonDetail done - epId:" << detail.epId 
             << "bvid:" << detail.bvid
             << "cid:" << detail.cid << "seasonType:" << detail.seasonType;
}

QVariantList PlayUrlManager::parseSeasonEpisodes(const QJsonArray &episodesArray, const QString &currentCid, int &currentIndex)
{
    QVariantList episodes;
    currentIndex = -1;

    // 官方网页选集分"正片"和"预告"两栏，ep/list 把两栏内容混在一起返回。
    // 此处只保留正片：badge='预告' 的条目（无论时长）全部移除——预告的 title
    // 也是数字集数、且可能与正片重复编号，时长阈值法对不同番剧不够精准。
    for (int i = 0; i < episodesArray.size(); i++) {
        QJsonObject ep = episodesArray[i].toObject();

        // 过滤文本标题条目（"PV1"、"预告"等花絮，非数字集数）
        QString epTitle = ep["title"].toString().trimmed();
        if (!epTitle.isEmpty()) {
            bool numeric = false;
            epTitle.toDouble(&numeric);
            if (!numeric && epTitle != QStringLiteral("正片"))
                continue;
        }

        // 过滤预告
        QString badge = ep["badge"].toString();
        if (badge == QStringLiteral("预告"))
            continue;

        QVariantMap episodeInfo;
        QString cid = QString::number(ep["cid"].toVariant().toLongLong());
        episodeInfo["cid"] = cid;
        episodeInfo["epId"] = QString::number(ep["id"].toVariant().toLongLong());
        // B 站官方集数编号（"1"、"26"…），供 UI 显示真实集数而非列表顺序号
        episodeInfo["epIndex"] = epTitle;
        // 副标题：ep/list 用 long_title，season 接口用 index_title，两者都取
        QString subTitle = ep["index_title"].toString();
        if (subTitle.isEmpty())
            subTitle = ep["long_title"].toString();
        episodeInfo["title"] = subTitle;
        episodeInfo["indexTitle"] = subTitle;
        episodeInfo["cover"] = ep["cover"].toString();
        episodeInfo["bvid"] = ep["bvid"].toString();
        episodeInfo["aid"] = QString::number(ep["aid"].toVariant().toLongLong());
        episodeInfo["duration"] = ep["duration"].toInt();
        // 官方选集角标："会员"/"限免"（badge_type 在 ep/list 中恒为 0，不可靠，用文本）
        episodeInfo["badge"] = badge;

        // 判断是否已上线
        QString releaseDate = ep["release_date"].toString();
        bool isReleased = !releaseDate.isEmpty();
        episodeInfo["isReleased"] = isReleased;

        // 检查是否为当前集（用过滤后的索引，避免与原数组下标错位）
        if (!currentCid.isEmpty() && cid == currentCid) {
            currentIndex = episodes.size();
        }

        episodes.append(episodeInfo);
    }
    
    // 如果没有匹配的当前集，默认选择第一个已上线的
    if (currentIndex < 0) {
        for (int i = 0; i < episodes.size(); i++) {
            QVariantMap ep = episodes[i].toMap();
            if (ep["isReleased"].toBool()) {
                currentIndex = i;
                break;
            }
        }
        // 如果都没有上线，选择第一个
        if (currentIndex < 0 && !episodes.isEmpty()) {
            currentIndex = 0;
        }
    }
    
    qDebug() << "[PlayUrlManager] parseSeasonEpisodes count:" << episodes.size() 
             << "currentIndex:" << currentIndex;
    
    return episodes;
}
