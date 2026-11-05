#include "SponsorBlockManager.h"

#include "AppSettings.h"
#include "../core/AppDirs.h"

#include <QCoreApplication>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QUrl>
#include <QUrlQuery>
#include <QTimer>
#include <QUuid>
#include <algorithm>

// ===========================================================================
// 分类约束表（B 站版 12 类）
//
// 数组顺序即提交面板的下拉顺序；actions 用 '|' 分隔，第一个就是默认行为。
// 这份表是**唯一真值**：QML 的分类下拉、时间框禁用逻辑、以及 C++ 构造请求
// 前的校验都从这里取，避免两套规则漂移。
// ===========================================================================
namespace {

struct CategoryRule {
    const char *key;
    const char *actions;
};

const CategoryRule kCategoryRules[] = {
    { "sponsor",          "skip|mute|full" },   // 恰饭
    { "selfpromo",        "skip|mute|full" },   // 自我推广
    { "exclusive_access", "full"            },   // 品牌合作（只能整段）
    { "interaction",      "skip|mute"       },   // 互动提醒
    { "poi_highlight",    "poi"             },   // 高能点（时间点）
    { "intro",            "skip|mute"       },   // 片头
    { "outro",            "skip|mute"       },   // 片尾
    { "preview",          "skip|mute"       },   // 回顾
    { "padding",          "skip"            },   // 黑屏填充
    { "filler",           "skip|mute"       },   // 无意义内容
    { "music_offtopic",   "skip"            },   // 非音乐部分
    { "jumpscare",        "mute"            },   // 惊吓（只能静音）
};

// userAgent / x-ext-version 用的版本串（applicationVersion 可能为空）
QString clientVersionTag()
{
    const QString v = QCoreApplication::applicationVersion();
    return v.isEmpty() ? QStringLiteral("1.0") : v;
}

}   // namespace

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
    // bsb.conf 为纯文本：首个非注释非空行 = 接口基地址。
    // 支持 "#" 行注释与行内空白；结尾多余的 "/" 去掉。任何解析失败都
    // 静默保持 m_baseUrl 为空 → available=false，功能整体关闭。
    //
    // 路径：Linux 在 ~/.config/BbQ/bsb.conf，Windows 仍在 exe 同目录
    // （行为不变）。找不到时回退读旧位置，让 tar.gz 绿色版升级到 .deb 的
    // 用户不会突然"配置全丢"。详见 src/core/AppDirs.h。
    bool usedLegacy = false;
    const QString confPath = AppDirs::resolveReadable(QStringLiteral("bsb.conf"),
                                                      &usedLegacy);
    QFile f(confPath);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) {
        // 打不开有两种截然不同的含义，必须分开报，否则用户只能看到
        // "空降助手不见了"却毫无线索：
        //   1) 文件不存在 —— 正常状态（用户没配过这个功能），属预期；
        //   2) 文件存在但读不了 —— 权限/编码等异常，需要用户处理。
        // 用 QFile::exists 先区分。注意 usedLegacy 为 true 时文件必然存在
        //（resolveReadable 只在旧路径命中时才返回它），所以这里**不可能**
        // 是"回退路径存在却打不开"，只需按exists 判断即可。
        if (QFile::exists(confPath)) {
            qWarning().noquote() << QStringLiteral(
                "[SponsorBlock] bsb.conf 存在但无法读取: %1（%2）")
                .arg(confPath, f.errorString());
        } else {
            qInfo().noquote() << QStringLiteral(
                "[SponsorBlock] 未配置 bsb.conf，空降助手功能未启用。"
                "如需启用请在 %1 创建该文件（写入接口基地址）")
                .arg(AppDirs::configRoot());
        }
        return;
    }
    if (usedLegacy) {
        qInfo().noquote() << QStringLiteral(
            "[SponsorBlock] 未在 %1 找到 bsb.conf，回退使用旧位置: %2")
            .arg(AppDirs::configRoot(), confPath);
    }

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

// ===========================================================================
// 分类：唯一真值在文件头的 kCategoryRules
// ===========================================================================

QStringList SponsorBlockManager::categories() const
{
    QStringList out;
    for (const CategoryRule &r : kCategoryRules)
        out << QString::fromLatin1(r.key);
    return out;
}

QStringList SponsorBlockManager::allowedActions(const QString &category) const
{
    for (const CategoryRule &r : kCategoryRules) {
        if (category == QLatin1String(r.key)) {
            return QString::fromLatin1(r.actions)
                .split(QLatin1Char('|'), Qt::SkipEmptyParts);
        }
    }
    return {};
}

QString SponsorBlockManager::defaultAction(const QString &category) const
{
    const QStringList actions = allowedActions(category);
    return actions.isEmpty() ? QString() : actions.first();
}

// ===========================================================================
// 提交身份（私人 ID）
//
// 服务器不保存明文：丢了就永久找不回此前的提交归属。所以生成后立刻写设置，
// 且**不暴露给 QML**（少一个泄漏面 —— 它等同于密码）。
// ===========================================================================

QString SponsorBlockManager::ensureUserID()
{
    if (!m_userID.isEmpty())
        return m_userID;

    AppSettings *st = AppSettings::instance();
    if (st)
        m_userID = st->getString(QStringLiteral("sponsor/userID")).trimmed();

    if (m_userID.size() < 30) {
        // Id128 = 32 位小写 hex（无连字符），满足官方的「≥30 字符」要求
        m_userID = QUuid::createUuid().toString(QUuid::Id128);
        if (st)
            st->setString(QStringLiteral("sponsor/userID"), m_userID);
        qInfo() << "[SponsorBlock] 已生成本机提交身份 ID"
                << "（私人 ID，相当于密码；丢失后此前提交无法找回）";
    }
    return m_userID;
}

QString SponsorBlockManager::httpStatusMessage(int st)
{
    switch (st) {
    case 0:   return QStringLiteral("网络错误，请检查网络后重试");
    case 400: return QStringLiteral("参数不合法：请检查片段的时间范围");
    case 403: return QStringLiteral("被服务器自动审核拒绝，请确认片段标注准确");
    case 404: return QStringLiteral("接口不存在，请检查 bsb.conf 中的地址");
    case 409: return QStringLiteral("该片段已存在（可能已被提交过）");
    case 429: return QStringLiteral("提交太频繁，请稍后再试");
    default:
        if (st >= 500)
            return QStringLiteral("服务器错误（HTTP %1），请稍后重试").arg(st);
        return QStringLiteral("提交失败（HTTP %1）").arg(st);
    }
}

void SponsorBlockManager::emitSubmitFailure(int httpStatus, const QString &message)
{
    emit submitFinished(false, httpStatus, message, {});
}

void SponsorBlockManager::submitSegments(const QString &bvid, const QString &cid,
                                         double durationSec, const QVariantList &segments)
{
    // ---- 本地前置校验（不发请求）----
    if (!available())
        return emitSubmitFailure(0, QStringLiteral("空降助手未启用"));
    if (m_submitting)
        return emitSubmitFailure(0, QStringLiteral("上一次提交还在进行中"));
    if (!bvid.startsWith(QStringLiteral("BV")))
        return emitSubmitFailure(0, QStringLiteral("仅支持普通投稿视频提交片段"));
    if (!(durationSec > 0))
        return emitSubmitFailure(0, QStringLiteral("视频时长未就绪，请稍候再试"));
    if (segments.isEmpty())
        return emitSubmitFailure(0, QStringLiteral("请至少添加一个片段"));

    QJsonArray segArr;
    QVariantList normalized;   // 与 segArr 同序：服务器不回 actionType，靠它回填

    for (const QVariant &v : segments) {
        const QVariantMap s = v.toMap();
        const QString category = s.value(QStringLiteral("category")).toString();
        QString action = s.value(QStringLiteral("actionType")).toString();
        double start = s.value(QStringLiteral("start")).toDouble();
        double end = s.value(QStringLiteral("end")).toDouble();

        const QStringList allowed = allowedActions(category);
        if (allowed.isEmpty())
            return emitSubmitFailure(0, QStringLiteral("未知片段分类：%1").arg(category));
        if (!allowed.contains(action))
            return emitSubmitFailure(
                0, QStringLiteral("分类 %1 不支持行为 %2").arg(category, action));

        if (action == QLatin1String("full")) {
            // 整段：服务端要求 start=0
            start = 0.0;
            end = durationSec;
        } else if (action == QLatin1String("poi")) {
            // 高能点：时间点，end==start
            end = start;
        } else if (end <= start) {
            return emitSubmitFailure(0, QStringLiteral("片段结束时间必须大于开始时间"));
        }
        if (start < 0.0 || start > durationSec + 0.5 || end > durationSec + 0.5)
            return emitSubmitFailure(0, QStringLiteral("片段超出视频时长范围"));

        QJsonArray pair;
        pair.append(start);
        pair.append(end);

        QJsonObject o;
        o[QStringLiteral("segment")] = pair;
        o[QStringLiteral("category")] = category;
        o[QStringLiteral("actionType")] = action;
        segArr.append(o);

        QVariantMap n;
        n[QStringLiteral("start")] = start;
        n[QStringLiteral("end")] = end;
        n[QStringLiteral("category")] = category;
        n[QStringLiteral("actionType")] = action;
        normalized.append(n);
    }

    QJsonObject body;
    body[QStringLiteral("videoID")] = bvid;
    body[QStringLiteral("cid")] = cid;          // 字符串：不传会落到第一 P
    body[QStringLiteral("userID")] = ensureUserID();
    body[QStringLiteral("userAgent")] = QStringLiteral("BbQ/") + clientVersionTag();
    body[QStringLiteral("videoDuration")] = durationSec;
    body[QStringLiteral("segments")] = segArr;

    // 元数据同时放进 query 与 body：
    // 服务端 postSkipSegments 取的是 `req.query.x || req.body.x`（segments 只从
    // body 读），两处都带一份就不会因为 fork 改了读取方式而失败。
    // 另外这个服务器对 POST 的 body 解析并不总是可用（setUsername 就完全
    // 只读 query），冗余一份最稳。
    QUrl url(m_baseUrl + QStringLiteral("/skipSegments"));
    QUrlQuery query;
    query.addQueryItem(QStringLiteral("videoID"), bvid);
    query.addQueryItem(QStringLiteral("cid"), cid);
    query.addQueryItem(QStringLiteral("userID"), body[QStringLiteral("userID")].toString());
    query.addQueryItem(QStringLiteral("userAgent"), body[QStringLiteral("userAgent")].toString());
    query.addQueryItem(QStringLiteral("videoDuration"), QString::number(durationSec, 'f', 3));
    url.setQuery(query);

    m_submitting = true;
    emit submittingChanged();

    sendSubmitRequest(url, QJsonDocument(body).toJson(QJsonDocument::Compact),
                      normalized, 0);
}

// 真正发出提交请求。attempt 用于"网络层失败自动重试一次"：
// 服务端按 (videoID, userID, segment) 去重，重复提交只会拿到 409，
// 不会产生重复片段，所以重试是安全的。
//
// 为什么必须重试：跨境线路经常出现"请求已到、回包丢失/超时"，
// 客户端看到的是无 HTTP 状态的网络错误（status 0），用户再点一次就变 409。
// 2026-11-04 另一台机器的日志就是 0/0/409/0/0 这个序列。
void SponsorBlockManager::sendSubmitRequest(const QUrl &url, const QByteArray &payload,
                                            const QVariantList &normalized, int attempt)
{
    QNetworkRequest req(url);
    req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    req.setRawHeader("origin", "BbQ");
    req.setRawHeader("x-ext-version", clientVersionTag().toUtf8());
    // 20 秒：服务端提交时要走去重/风控/写库，跨境线路又慢。8 秒会把
    // "其实已经受理、只是回包慢"的请求判成失败
    req.setTransferTimeout(20000);
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                     QNetworkRequest::NoLessSafeRedirectPolicy);

    QNetworkReply *reply = m_nam.post(req, payload);
    connect(reply, &QNetworkReply::finished, this,
            [this, reply, url, payload, normalized, attempt]() {
        reply->deleteLater();

        const int httpStatus = reply->attribute(
            QNetworkRequest::HttpStatusCodeAttribute).toInt();

        if (reply->error() != QNetworkReply::NoError && httpStatus == 0) {
            const auto err = reply->error();
            qWarning() << "[SponsorBlock] submit network error, attempt:" << attempt
                       << err << reply->errorString();
            // 第一次失败就静默重试一次（保持"提交中…"状态，用户无感）
            if (attempt == 0) {
                QTimer::singleShot(700, this, [this, url, payload, normalized]() {
                    sendSubmitRequest(url, payload, normalized, 1);
                });
                return;
            }

            m_submitting = false;
            emit submittingChanged();

            QString msg;
            switch (err) {
            case QNetworkReply::TimeoutError:
            case QNetworkReply::OperationCanceledError:
                msg = QStringLiteral(
                    "服务器响应超时（可能已受理：稍后重新打开视频，"
                    "片段若已在进度条上就说明提交成功）");
                break;
            case QNetworkReply::HostNotFoundError:
                msg = QStringLiteral("无法解析服务器地址，请检查网络/DNS");
                break;
            case QNetworkReply::SslHandshakeFailedError:
                msg = QStringLiteral("TLS 握手失败（请检查系统时间或代理设置）");
                break;
            case QNetworkReply::ConnectionRefusedError:
            case QNetworkReply::RemoteHostClosedError:
            case QNetworkReply::NetworkSessionFailedError:
                msg = QStringLiteral("连接被服务器断开，请稍后重试");
                break;
            default:
                msg = httpStatusMessage(0);
                break;
            }
            emit submitFinished(false, 0, msg, {});
            return;
        }

        m_submitting = false;
        emit submittingChanged();

        // 重试时才出现的 409：说明第一次其实已经写进去了（只是回包丢了）
        if (httpStatus == 409 && attempt > 0) {
            emit submitFinished(true, 200, QStringLiteral("已提交（上一次已受理）"),
                                normalized);
            return;
        }
        if (httpStatus != 200) {
            // 注意：**不调用 noteResult()** —— 用户输错/重复提交/被限流都不该
            // 让整个空降助手在本会话被禁用
            emit submitFinished(false, httpStatus, httpStatusMessage(httpStatus), {});
            return;
        }

        const QJsonDocument doc = QJsonDocument::fromJson(reply->readAll());
        if (!doc.isArray()) {
            emit submitFinished(false, 0, QStringLiteral("服务器返回格式异常"), {});
            return;
        }

        const QJsonArray arr = doc.array();
        QVariantList out;
        for (int i = 0; i < arr.size() && i < normalized.size(); ++i) {
            const QJsonObject o = arr.at(i).toObject();
            QVariantMap m = normalized.at(i).toMap();   // 回填 actionType
            const QJsonArray seg = o.value(QStringLiteral("segment")).toArray();
            if (seg.size() == 2) {
                m[QStringLiteral("start")] = seg.at(0).toDouble();
                m[QStringLiteral("end")] = seg.at(1).toDouble();
            }
            const QString category = o.value(QStringLiteral("category")).toString();
            if (!category.isEmpty())
                m[QStringLiteral("category")] = category;
            const QString uuid = o.value(QStringLiteral("UUID")).toString();
            if (uuid.isEmpty())
                continue;
            m[QStringLiteral("uuid")] = uuid;
            out.append(m);
        }

        const int n = out.size();
        emit submitFinished(true, 200,
                            n > 0 ? QStringLiteral("提交成功") : QStringLiteral("已提交"),
                            out);
    });
}

// ===========================================================================
// 排行榜昵称
// ===========================================================================

void SponsorBlockManager::fetchUsername()
{
    if (!available() || m_userNameFetched)
        return;

    const QString uid = ensureUserID();
    if (uid.isEmpty())
        return;
    m_userNameFetched = true;   // 每会话只尝试一次，失败也不再重试

    QUrl url(m_baseUrl + QStringLiteral("/getUsername"));
    QUrlQuery query;
    query.addQueryItem(QStringLiteral("userID"), uid);
    url.setQuery(query);

    QNetworkRequest req(url);
    req.setRawHeader("origin", "BbQ");
    req.setRawHeader("x-ext-version", clientVersionTag().toUtf8());
    req.setTransferTimeout(6000);

    QNetworkReply *reply = m_nam.get(req);
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError)
            return;
        const QJsonDocument doc = QJsonDocument::fromJson(reply->readAll());
        if (!doc.isObject())
            return;
        const QString name = doc.object().value(QStringLiteral("userName")).toString();
        if (name.isEmpty() || name == m_userName)
            return;
        m_userName = name;
        emit userNameChanged();
    });
}

void SponsorBlockManager::setUsername(const QString &name)
{
    if (!available())
        return emit usernameResult(false, QStringLiteral("空降助手未启用"));

    const QString trimmed = name.trimmed();
    if (trimmed.isEmpty())
        return emit usernameResult(false, QStringLiteral("昵称不能为空"));

    // ★ 参数必须放在 **query string**，不能放 JSON body。
    // 服务端 setUsername 只读 req.query（见 SponsorBlockServer 的
    // src/routes/setUsername.ts：const userIDInput = req.query.userID），
    // 发 body 时它拿不到参数，一律回 400 Bad Request —— 表现为"怎么填都非法"。
    // （同服务器的 postSkipSegments 是 req.query.x || req.body.x，body 可用，
    //   所以只有这一个接口要特殊处理。）
    QUrl url(m_baseUrl + QStringLiteral("/setUsername"));
    QUrlQuery query;
    query.addQueryItem(QStringLiteral("userID"), ensureUserID());   // 唯一凭证
    query.addQueryItem(QStringLiteral("username"), trimmed);
    url.setQuery(query);

    QNetworkRequest req(url);
    // 不带 body，但仍要 POST；Content-Type 留给 Qt（空 body 无需声明）
    req.setRawHeader("origin", "BbQ");
    req.setRawHeader("x-ext-version", clientVersionTag().toUtf8());
    req.setTransferTimeout(8000);

    QNetworkReply *reply = m_nam.post(req, QByteArray());
    connect(reply, &QNetworkReply::finished, this, [this, reply, trimmed]() {
        reply->deleteLater();
        const int httpStatus = reply->attribute(
            QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const bool ok = (reply->error() == QNetworkReply::NoError
                         && httpStatus >= 200 && httpStatus < 300);

        // 服务端在非 2xx 时会用纯文本回一句中文原因（如 429 "只能每分钟修改
        // 一次用户名"），比我们自己的兜底文案准确，能用就用
        QString serverMsg = QString::fromUtf8(reply->readAll()).trimmed();
        if (serverMsg == QLatin1String("Bad Request") || serverMsg.size() > 120)
            serverMsg.clear();

        if (!ok) {
            QString msg;
            if (httpStatus == 403)
                msg = QStringLiteral("没有权限修改该昵称");
            else if (!serverMsg.isEmpty())
                msg = serverMsg;                 // 429/400 时以服务端文案为准
            else if (httpStatus == 400)
                msg = QStringLiteral("昵称不合法（可能过长或含非法字符）");
            else
                msg = httpStatusMessage(httpStatus);
            emit usernameResult(false, msg);
            return;
        }
        // 200 不等于真的存下了：服务端在"用户名被锁定 / 身份被封禁 /
        // 该身份还没有任何提交记录 / 命中请求校验规则"时会直接回 200 而不写库。
        // 所以再 GET 一次核对，只有读回来一致才告诉用户成功
        verifyUsernameSaved(trimmed);
    });
}

void SponsorBlockManager::verifyUsernameSaved(const QString &expected)
{
    QUrl url(m_baseUrl + QStringLiteral("/getUsername"));
    QUrlQuery query;
    query.addQueryItem(QStringLiteral("userID"), ensureUserID());
    url.setQuery(query);

    QNetworkRequest req(url);
    req.setRawHeader("origin", "BbQ");
    req.setRawHeader("x-ext-version", clientVersionTag().toUtf8());
    req.setTransferTimeout(6000);

    QNetworkReply *reply = m_nam.get(req);
    connect(reply, &QNetworkReply::finished, this, [this, reply, expected]() {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError) {
            // 设置请求本身已经 200，只是这次校验没成功，别谎报"未生效"
            emit usernameResult(false,
                QStringLiteral("昵称请求已提交，但校验失败（网络错误），请重开设置确认"));
            return;
        }
        QString actual;
        {
            const QJsonDocument doc = QJsonDocument::fromJson(reply->readAll());
            if (doc.isObject())
                actual = doc.object().value(QStringLiteral("userName")).toString();
        }
        if (actual == expected) {
            m_userName = expected;
            m_userNameFetched = true;
            emit userNameChanged();
            emit usernameResult(true, QStringLiteral("昵称已更新"));
            return;
        }
        // 读回来不是刚设的名字（通常仍是公开 ID）= 服务器没保存
        emit usernameResult(false,
            QStringLiteral("昵称未生效：服务器没有保存（换个昵称再试，"
                           "或该身份尚未提交过片段）"));
    });
}
