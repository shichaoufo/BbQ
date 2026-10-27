#include "LiveDanmakuManager.h"
#include "LoginManager.h"
#include "EmoticonCache.h"
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>

#include <QBuffer>
#include <QCoreApplication>
#include <QDataStream>
#include <QtEndian>
#include <QVariantMap>
#include <QPointer>
#include <QTimer>
#include <zlib.h>

namespace {

/// 宽松取整：B 站偶尔把数值字段发成字符串（如 "size": "2"），
/// QJsonValue::toInt() 遇到字符串会直接返回默认值，这里显式兼容
int lenientInt(const QJsonValue &v, int def = 0)
{
    if (v.isDouble())
        return v.toInt(def);
    if (v.isString()) {
        bool ok = false;
        const int n = v.toString().toInt(&ok);
        return ok ? n : def;
    }
    return def;
}

}   // namespace

LiveDanmakuManager::LiveDanmakuManager(QObject *parent)
    : QObject(parent)
    , m_webSocket(new QWebSocket(QString(), QWebSocketProtocol::VersionLatest, this))
    , m_heartbeatTimer(new QTimer(this))
    , m_switchTimer(new QTimer(this))
    , m_cleanupTimer(new QTimer(this))
    , m_reconnectTimer(new QTimer(this))
    , m_batchTimer(new QTimer(this))
    , m_roomId(0)
    , m_isConnected(false)
    , m_isClosing(false)
    , m_sequence(1)
    , m_danmakuPort(0)
    , m_pendingRoomId(0)
    , m_reconnectAttempts(0)
{
    // 命名 WebSocket，避免析构时 abort() 触发的 destroyed/disconnected
    // 信号在未命名对象上导致 Qt 打印 wildcard disconnect 警告
    m_webSocket->setObjectName(QStringLiteral("LiveDanmakuSocket"));

    connect(m_webSocket, &QWebSocket::connected, this, &LiveDanmakuManager::onConnected);
    connect(m_webSocket, &QWebSocket::disconnected, this, &LiveDanmakuManager::onDisconnected);
    connect(m_webSocket, &QWebSocket::textMessageReceived, this, &LiveDanmakuManager::onTextMessageReceived);
    connect(m_webSocket, &QWebSocket::binaryMessageReceived, this, &LiveDanmakuManager::onBinaryMessageReceived);
    connect(m_webSocket, &QWebSocket::errorOccurred, this, &LiveDanmakuManager::onError);

    connect(m_heartbeatTimer, &QTimer::timeout, this, &LiveDanmakuManager::onHeartbeatTimer);
    m_heartbeatTimer->setInterval(30000);

    // close() 后延迟 open 新房间：disconnected 信号发出时 SSL 后台线程的握手关闭
    // 可能未完成，立即 open 会导致 processHandshake 错误 → Qt 内部 abort → 崩溃。
    // 500ms 足够 SSL 线程退出，且对弹幕加载体验影响可忽略（弹幕本就比视频晚）。
    m_switchTimer->setSingleShot(true);
    m_switchTimer->setInterval(500);
    connect(m_switchTimer, &QTimer::timeout, this, &LiveDanmakuManager::onSwitchTimer);

    // 延迟销毁旧 socket：每次 openConnection 创建新 socket，旧 socket 移入 m_oldSockets。
    // 3 秒后统一删除，确保旧 socket 内部 QSslSocket 的 SSL 后台线程已完全退出，
    // 避免 QSslSocket 析构时与 SSL 线程竞争 → 死锁卡死。
    m_cleanupTimer->setSingleShot(true);
    m_cleanupTimer->setInterval(3000);
    connect(m_cleanupTimer, &QTimer::timeout, this, &LiveDanmakuManager::onCleanupTimer);

    // 意外断线自动重连：服务器踢线/网络闪断后恢复弹幕连接。
    // singleShot + 指数退避（5s→10s→20s→30s 封顶），认证成功后归零，
    // 避免网络长时间不可用时高频重试刷日志/耗资源
    m_reconnectTimer->setSingleShot(true);
    connect(m_reconnectTimer, &QTimer::timeout, this, &LiveDanmakuManager::onReconnectTimer);

    // 弹幕 50ms 合批：高峰时逐条发信号会让 QML 属性系统过载，
    // 聚合为批次后一批弹幕仅一次跨线程信号
    m_batchTimer->setSingleShot(true);
    m_batchTimer->setInterval(50);
    connect(m_batchTimer, &QTimer::timeout, this, &LiveDanmakuManager::flushDanmakuBatch);

    // 退出时提前销毁 WebSocket：不要拖到 QML 引擎销毁阶段才在 ~LiveDanmakuManager
    // 里析构。引擎销毁时 Qt 内部状态已开始拆卸，~QWebSocket 的内部 disconnect 警告
    // 与网络线程的 deleteLater 析构并发，曾实测造成 AB-BA 死锁（进程残留不退出）。
    // aboutToQuit 时事件循环刚结束、对象树完整，是更安全的销毁时机。
    connect(qApp, &QCoreApplication::aboutToQuit, this, &LiveDanmakuManager::teardownConnection);
}

LiveDanmakuManager::~LiveDanmakuManager()
{
    // 正常路径下 aboutToQuit 已提前清理（teardownConnection），此处为兜底
    teardownConnection();
}

void LiveDanmakuManager::teardownConnection()
{
    m_isClosing = true;
    m_isConnected = false;

    if (m_heartbeatTimer) {
        m_heartbeatTimer->stop();
    }
    if (m_switchTimer) {
        m_switchTimer->stop();
    }
    if (m_cleanupTimer) {
        m_cleanupTimer->stop();
    }
    if (m_reconnectTimer) {
        m_reconnectTimer->stop();
    }
    if (m_batchTimer) {
        m_batchTimer->stop();
    }
    m_pendingDanmaku.clear();

    if (m_webSocket) {
        m_webSocket->blockSignals(true);
        if (m_webSocket->state() != QAbstractSocket::UnconnectedState) {
            m_webSocket->abort();
        }
        delete m_webSocket;
        m_webSocket = nullptr;
    }

    // 销毁所有待删除的旧 socket。
    // 注意：onCleanupTimer 中已用 deleteLater() 排队删除旧 socket 并 clear() 了列表，
    // 正常情况下此处列表为空。仅在 timer 未触发（如程序退出）时列表非空，此时直接 delete 安全。
    // 已 deleteLater 排队的对象不会出现在 m_oldSockets 中（clear 已移除引用），不会双重释放。
    for (QWebSocket *old : m_oldSockets) {
        old->blockSignals(true);
        delete old;
    }
    m_oldSockets.clear();
}

void LiveDanmakuManager::connectRoom(int roomId)
{
    m_roomId = roomId;
    m_sequence = 1;
    m_isClosing = false;  // 新连接，允许接收消息
    m_reconnectTimer->stop();  // 用户主动切换：取消挂起的自动重连
    m_reconnectAttempts = 0;   // 新连接重置退避计数

    // switchTimer 正在运行（close 已完成，等 SSL 退出延迟）：
    // 只更新 pendingRoomId，timer 到期会 open 最新房间
    if (m_switchTimer->isActive()) {
        m_pendingRoomId = roomId;
        return;
    }

    // 已有连接：close() 优雅关闭，onDisconnected 中启动 switchTimer 延迟 open
    if (m_webSocket && m_webSocket->state() != QAbstractSocket::UnconnectedState) {
        m_pendingRoomId = roomId;
        m_webSocket->close(QWebSocketProtocol::CloseCodeGoingAway, QStringLiteral("switching room"));
        return;
    }

    // socket 已断开：仍需通过 switchTimer 延迟 open。
    // wss:// 连接断开后，QSslSocket 的 SSL 后台线程可能仍在清理，
    // 立即 open() 发起新 SSL 握手会与之竞争 → 死锁卡死。
    // 500ms 延迟确保 SSL 线程完全退出后再建立新连接。
    m_pendingRoomId = roomId;
    m_switchTimer->start();
}

void LiveDanmakuManager::recreateSocket()
{
    // 将当前 socket 移入待删除列表，等 SSL 后台线程退出后统一销毁
    if (m_webSocket) {
        m_webSocket->blockSignals(true);
        if (m_webSocket->state() != QAbstractSocket::UnconnectedState) {
            m_webSocket->abort();
        }
        // 列表上限兜底：极端高频开关时（间隔 <3s），m_cleanupTimer 会被反复重启
        // 而不触发，m_oldSockets 会线性增长。限制最多 3 个，超出立即 delete
        // 最老的。3 秒已足够 SSL 后台线程退出，最老的 socket 可安全销毁。
        while (m_oldSockets.size() >= 3) {
            QWebSocket *oldest = m_oldSockets.takeFirst();
            oldest->blockSignals(true);
            delete oldest;
        }
        m_oldSockets.append(m_webSocket);
        m_webSocket = nullptr;
        // 启动/重启清理定时器，3 秒后删除所有旧 socket
        m_cleanupTimer->start();
    }

    // 创建全新的 QWebSocket，避免复用旧 socket 的 SSL 状态
    m_webSocket = new QWebSocket(QString(), QWebSocketProtocol::VersionLatest, this);
    m_webSocket->setObjectName(QStringLiteral("LiveDanmakuSocket"));

    connect(m_webSocket, &QWebSocket::connected, this, &LiveDanmakuManager::onConnected);
    connect(m_webSocket, &QWebSocket::disconnected, this, &LiveDanmakuManager::onDisconnected);
    connect(m_webSocket, &QWebSocket::textMessageReceived, this, &LiveDanmakuManager::onTextMessageReceived);
    connect(m_webSocket, &QWebSocket::binaryMessageReceived, this, &LiveDanmakuManager::onBinaryMessageReceived);
    connect(m_webSocket, &QWebSocket::errorOccurred, this, &LiveDanmakuManager::onError);
}

void LiveDanmakuManager::onCleanupTimer()
{
    // SSL 后台线程已完全退出（3 秒延迟），安全同步销毁旧 socket。
    // 必须用 delete 而非 deleteLater：deleteLater 的实际析构时机不确定，
    // 可能排到新 socket SSL 握手回调期间处理，旧 QSslSocket 析构与新 QSslSocket
    // 握手在 OpenSSL 全局锁上竞争 → 死锁卡死。delete 在 timer 回调中同步完成，
    // 时机确定，不会与新连接竞争。
    // wildcard disconnect 警告是 Qt 内部日志噪音，无害，接受。
    for (QWebSocket *old : m_oldSockets) {
        old->blockSignals(true);
        delete old;
    }
    m_oldSockets.clear();
}

void LiveDanmakuManager::openConnection()
{
    QString host = m_danmakuHost.isEmpty() ? "broadcastlv.chat.bilibili.com" : m_danmakuHost;
    int port = m_danmakuPort > 0 ? m_danmakuPort : 2245;
    QString url = QString("wss://%1:%2/sub").arg(host).arg(port);

    // 每次连接都创建新的 QWebSocket，旧 socket 移入待删除列表。
    // 复用同一 socket 会导致旧连接的 SSL 后台线程与新连接的 SSL 握手竞争 → 死锁卡死。
    recreateSocket();

    QNetworkRequest request(url);
    request.setRawHeader("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36");

    QSslConfiguration sslConfig = QSslConfiguration::defaultConfiguration();
    sslConfig.setPeerVerifyMode(QSslSocket::VerifyNone);
    request.setSslConfiguration(sslConfig);

    m_webSocket->open(request);
}

void LiveDanmakuManager::setDanmakuInfo(const QString &host, int port, const QString &token)
{
    m_danmakuHost = host;
    m_danmakuPort = port;
    m_danmakuToken = token;
}

void LiveDanmakuManager::disconnectRoom()
{
    m_heartbeatTimer->stop();
    m_switchTimer->stop();  // 取消待切换房间，避免 onSwitchTimer 中误 open
    m_reconnectTimer->stop();  // 用户主动断开：取消自动重连
    m_isConnected = false;
    m_isClosing = true;  // 标记正在断开，忽略残留消息
    m_pendingRoomId = 0;
    if (m_webSocket && m_webSocket->state() != QAbstractSocket::UnconnectedState) {
        // 用 close() 替代 abort()，避免 SSL 后台线程的暴力中断警告。
        m_webSocket->close(QWebSocketProtocol::CloseCodeGoingAway, QStringLiteral("closing"));
    }
}

bool LiveDanmakuManager::isConnected() const
{
    return m_isConnected;
}

void LiveDanmakuManager::onConnected()
{
    // 忽略旧 socket 的信号：connectRoom 创建新 socket 后，旧 socket 的 pending
    // connected 信号可能仍会触发本槽。sender() 返回信号发送者，若非当前 socket 则跳过。
    if (sender() != m_webSocket) return;

    // 二次防御：即使新建了 socket，如果在 open() 之后、connected 信号到达之前
    // 又调用了 disconnectRoom()（m_isClosing=true），也不应发送 auth。
    if (m_isClosing) {
        if (m_webSocket) m_webSocket->abort();
        return;
    }
    qWarning() << "[LiveDanmakuManager] connected to" << m_danmakuHost << ":" << m_danmakuPort
               << "room" << m_roomId << ", sending auth";
    sendAuth(m_roomId);
}

void LiveDanmakuManager::onDisconnected()
{
    if (sender() != m_webSocket) return;

    m_heartbeatTimer->stop();
    m_isConnected = false;

    if (!m_heartbeatTimer) {
        return;
    }

    // 切换房间流程：close() 发出 disconnected 后，SSL 后台线程的握手关闭
    // 可能仍未完成。启动 switchTimer 延迟 500ms 再 open，等 SSL 线程退出。
    // 立即 open 会导致 processHandshake 错误 → Qt 内部 abort → 崩溃。
    if (m_pendingRoomId > 0 && !m_isClosing) {
        m_switchTimer->start();
        return;  // 切换流程不向外发 disconnected 信号，避免 QML 误处理
    }

    // 意外断线（服务器踢线/网络闪断）：调度自动重连。
    // 用户主动断开（m_isClosing）或从未连接过（roomId 无效）不重连
    if (!m_isClosing && m_roomId > 0) {
        ++m_reconnectAttempts;
        int delay = qMin(5000 * (1 << qMin(m_reconnectAttempts - 1, 3)), 30000);
        m_reconnectTimer->start(delay);
        qWarning() << "[LiveDanmakuManager] unexpected disconnect, reconnect in" << delay / 1000
                   << "s (attempt" << m_reconnectAttempts << ") room" << m_roomId
                   << "closeCode:" << (m_webSocket ? int(m_webSocket->closeCode()) : -1)
                   << "closeReason:" << (m_webSocket ? m_webSocket->closeReason() : QString());
    }

    emit disconnected();
}

void LiveDanmakuManager::onSwitchTimer()
{
    // SSL 后台线程已退出，安全 open 新房间
    if (m_pendingRoomId > 0 && !m_isClosing) {
        m_roomId = m_pendingRoomId;  // 确保 roomId 是最新的（timer 期间可能多次切换）
        m_pendingRoomId = 0;
        openConnection();
    }
}

void LiveDanmakuManager::onReconnectTimer()
{
    // 定时器到期时状态可能已变化（用户切房间/关播放页）：不再重连
    if (m_isClosing || m_roomId <= 0) {
        return;
    }
    // 认证成功会停用所有路径；此处 socket 必为断开态，
    // connectRoom 内部会走 switchTimer（500ms SSL 退出延迟）→ openConnection
    qWarning() << "[LiveDanmakuManager] reconnecting to room" << m_roomId
               << "(attempt" << m_reconnectAttempts << ")";
    connectRoom(m_roomId);
}

void LiveDanmakuManager::onTextMessageReceived(const QString &message)
{
    if (sender() != m_webSocket) return;
    Q_UNUSED(message);
}

void LiveDanmakuManager::onBinaryMessageReceived(const QByteArray &message)
{
    if (sender() != m_webSocket) return;
    // 断开后忽略残留的缓冲消息，避免切换直播间时旧弹幕串到新直播间
    if (m_isClosing) {
        return;
    }
    parsePacket(message);
}

void LiveDanmakuManager::onError(QAbstractSocket::SocketError error)
{
    if (sender() != m_webSocket) return;
    qWarning() << "[LiveDanmakuManager] socket error" << int(error)
               << (m_webSocket ? m_webSocket->errorString() : QString())
               << "state:" << (m_webSocket ? int(m_webSocket->state()) : -1);
    if (m_webSocket) {
        emit danmakuError(m_webSocket->errorString());
    }
}

void LiveDanmakuManager::onHeartbeatTimer()
{
    // 连接已断开（服务器踢线等）：立即停表，避免对已关闭的
    // QSslSocket 持续 sendBinaryMessage → "device not open" 警告
    // 刷日志；重连由 QML 层的 disconnected 信号处理
    if (!m_webSocket || m_webSocket->state() != QAbstractSocket::ConnectedState) {
        m_heartbeatTimer->stop();
        return;
    }
    sendHeartbeat();
}

void LiveDanmakuManager::sendHeartbeat()
{
    QByteArray packet = buildPacket(OP_HEARTBEAT);
    m_webSocket->sendBinaryMessage(packet);
}

void LiveDanmakuManager::sendAuth(int roomId)
{
    QJsonObject authObj;
    int uid = LoginManager::instance()->getCurrentUser().mid;
    authObj["uid"] = uid;
    authObj["roomid"] = roomId;
    authObj["protover"] = 2;
    authObj["platform"] = "web";
    authObj["type"] = 2;
    authObj["key"] = m_danmakuToken;
    authObj["buvid"] = LoginManager::instance()->getOrCreateBuvid3();

    // 诊断：认证被踢时靠这行确认实际发出的内容（token 只打长度，避免泄露）
    qWarning() << "[LiveDanmakuManager] auth payload: uid" << uid << "roomid" << roomId
               << "tokenLen" << m_danmakuToken.size() << "buvid" << authObj["buvid"].toString();

    QJsonDocument doc(authObj);
    QByteArray payload = doc.toJson(QJsonDocument::Compact);

    QByteArray packet = buildPacket(OP_AUTH, payload);
    m_webSocket->sendBinaryMessage(packet);
}

void LiveDanmakuManager::parsePacket(const QByteArray &data)
{
    if (data.size() < PACKET_HEADER_SIZE) {
        return;
    }

    int offset = 0;
    while (offset < data.size()) {
        if (offset + PACKET_HEADER_SIZE > data.size()) {
            break;
        }

        QDataStream stream(data.mid(offset));
        stream.setByteOrder(QDataStream::BigEndian);

        quint32 packetLength;
        quint16 headerLength;
        quint16 protocolVersion;
        quint32 operation;
        quint32 sequence;

        stream >> packetLength;
        stream >> headerLength;
        stream >> protocolVersion;
        stream >> operation;
        stream >> sequence;

        if (packetLength < PACKET_HEADER_SIZE || offset + packetLength > data.size()) {
            break;
        }

        QByteArray payload = data.mid(offset + headerLength, packetLength - headerLength);

        switch (operation) {
            case OP_AUTH_REPLY: {
                QJsonDocument doc = QJsonDocument::fromJson(payload);
                if (doc.isObject()) {
                    QJsonObject obj = doc.object();
                    int code = obj["code"].toInt();
                    if (code == 0) {
                        m_isConnected = true;
                        m_heartbeatTimer->start();
                        // 重连成功：重置退避计数（下次断线从 5s 重新开始）
                        m_reconnectAttempts = 0;

                        if (obj.contains("data")) {
                            QJsonObject dataObj = obj["data"].toObject();
                            int online = dataObj["online"].toInt();
                            emit roomInfo(online, "");
                        }

                        emit connected();
                        qWarning() << "[LiveDanmakuManager] auth OK, room" << m_roomId;
                    } else {
                        emit danmakuError(QString("认证失败: %1").arg(code));
                    }
                }
                break;
            }

            case OP_HEARTBEAT_REPLY: {
                break;
            }

            case OP_MESSAGE: {

                if (protocolVersion == 2) {
                    z_stream strm;
                    strm.zalloc = Z_NULL;
                    strm.zfree = Z_NULL;
                    strm.opaque = Z_NULL;
                    strm.avail_in = payload.size();
                    strm.next_in = (Bytef*)payload.data();

                    QByteArray decompressed;

                    if (inflateInit(&strm) == Z_OK) {
                        do {
                            char buffer[8192];
                            strm.avail_out = sizeof(buffer);
                            strm.next_out = (Bytef*)buffer;

                            int ret = inflate(&strm, Z_NO_FLUSH);
                            if (ret == Z_STREAM_ERROR) {
                                break;
                            }

                            size_t produced = sizeof(buffer) - strm.avail_out;
                            decompressed.append(buffer, produced);
                        } while (strm.avail_out == 0);

                        inflateEnd(&strm);

                        if (!decompressed.isEmpty()) {
                            parsePacket(decompressed);
                        }
                    }
                } else {
                    QJsonDocument doc = QJsonDocument::fromJson(payload);
                    if (doc.isObject()) {
                        QJsonObject obj = doc.object();
                        QString cmd = obj["cmd"].toString();

                        if (cmd == "DANMU_MSG") {
                            QJsonArray info = obj["info"].toArray();

                            LiveDanmakuItem danmaku;
                            QString dmEmoUrl;          // 纯表情弹幕图（空 = 文本/混排）
                            int dmEmoSize = 1;         // 1=小表情 2=大表情
                            QVariantList dmEmoticons;  // 混排表情（text+url+size）
                            danmaku.type = 1;
                            danmaku.color = QColor(255, 255, 255);

                            if (info.size() > 1) {
                                danmaku.text = info[1].toString();
                            }

                            if (info.size() > 2) {
                                QJsonArray userInfo = info[2].toArray();
                                if (userInfo.size() > 1) {
                                    danmaku.nickname = userInfo[1].toString();
                                }
                                if (userInfo.size() > 0) {
                                    danmaku.uid = QString::number(userInfo[0].toVariant().toLongLong());
                                }
                            }

                            if (info.size() > 0) {
                                QJsonArray basicInfo = info[0].toArray();
                                if (basicInfo.size() > 3) {
                                    int colorValue = basicInfo[3].toInt();
                                    if (colorValue == 0) {
                                        danmaku.color = QColor(255, 255, 255);
                                    } else {
                                        danmaku.color = QColor((colorValue >> 16) & 0xFF,
                                                               (colorValue >> 8) & 0xFF,
                                                               colorValue & 0xFF);
                                    }
                                }
                                if (basicInfo.size() > 4) {
                                    danmaku.timestamp = basicInfo[4].toVariant().toLongLong();
                                }
                                // 混排表情：info[0][15].extra（JSON 字符串）内的
                                // emots 字典，key 为文本占位符（如 "[哇]"），
                                // value 含 url。文本中的占位符由渲染层替换为行内图片。
                                //
                                // 大小表情判定（2026-09-25 实测抓包 435 条真实弹幕）：
                                // emots 各值字段固定为 count/descript/emoji/
                                // emoticon_id/emoticon_unique/height/url/width ——
                                // **没有 size**；info[0][13] 同样没有。真正的大小信号
                                // 是**弹幕级**的 bulge_display == 1，extra 顶层与
                                // info[0][13] 上都会出现。实测 435 条里仅 1 条为 1，
                                // 正是装扮大表情 upower_[...]；行内 emoji（emoji_*，
                                // 图 20×20）恒为 0。故以 bulge_display 为准，
                                // size 只作老数据兼容兜底。
                                if (basicInfo.size() > 15) {
                                    const QString extraStr = basicInfo[15].toObject()
                                                                 ["extra"].toString();
                                    if (!extraStr.isEmpty()) {
                                        const QJsonDocument extraDoc =
                                                QJsonDocument::fromJson(extraStr.toUtf8());
                                        if (extraDoc.isObject()) {
                                            const QJsonObject extraObj = extraDoc.object();
                                            // 大表情是整条弹幕的属性，不是单个表情的属性
                                            const bool bulge =
                                                    lenientInt(extraObj["bulge_display"]) == 1;
                                            const QJsonObject emots = extraObj["emots"].toObject();
                                            for (auto eIt = emots.begin();
                                                 eIt != emots.end(); ++eIt) {
                                                const QJsonObject emo = eIt.value().toObject();
                                                const QString url = emo["url"].toString();
                                                const QString key = eIt.key();
                                                if (url.isEmpty() || key.isEmpty())
                                                    continue;
                                                const int size = (bulge
                                                        || lenientInt(emo["size"], 1) >= 2) ? 2 : 1;
                                                EmoticonCache::instance()->prefetch(url);
                                                if (danmaku.text.contains(key)) {
                                                    // 混排：占位符在文本内
                                                    QVariantMap em;
                                                    em["text"] = key;
                                                    em["url"] = url;
                                                    em["size"] = size;
                                                    dmEmoticons.append(em);
                                                } else if (dmEmoUrl.isEmpty()
                                                           && !danmaku.text.contains('[')) {
                                                    // 纯表情（文本为空/不含占位符）
                                                    dmEmoUrl = url;
                                                    dmEmoSize = size;
                                                }
                                            }
                                        }
                                    }
                                }
                                // 兼容旧字段 info[0][13] emoticon 对象（纯表情）：
                                // 字段为 bulge_display/emoticon_unique/height/
                                // in_player_area/is_dynamic/url/width，同样没有 size
                                if (dmEmoUrl.isEmpty() && basicInfo.size() > 13) {
                                    QJsonObject emo = basicInfo[13].toObject();
                                    const QString emoUrl = emo["url"].toString();
                                    if (!emoUrl.isEmpty()) {
                                        dmEmoUrl = emoUrl;
                                        dmEmoSize = (lenientInt(emo["bulge_display"]) == 1
                                                || lenientInt(emo["size"], 1) >= 2) ? 2 : 1;
                                        EmoticonCache::instance()->prefetch(emoUrl);
                                    }
                                }
                            }

                            // 50ms 合批发射：缓冲累积，超阈值立即冲刷（防超高峰值时延迟无限累积）
                            QVariantMap dm;
                            dm["text"] = danmaku.text;
                            dm["nickname"] = danmaku.nickname;
                            dm["color"] = danmaku.color.name();
                            dm["type"] = danmaku.type;
                            if (!dmEmoUrl.isEmpty()) {
                                dm["emoticonUrl"] = dmEmoUrl;
                                dm["emoticonSize"] = dmEmoSize;
                            }
                            if (!dmEmoticons.isEmpty())
                                dm["emoticons"] = dmEmoticons;
                            m_pendingDanmaku.append(dm);
                            if (m_pendingDanmaku.size() >= 300) {
                                flushDanmakuBatch();
                            } else if (!m_batchTimer->isActive()) {
                                m_batchTimer->start();
                            }
                        }
                        else if (cmd == "SUPER_CHAT_MESSAGE") {
                            // 醒目留言：data 内含发送者/金额/内容/持续时长/官方配色
                            // 用户信息现行协议在 user_info 内（uname/face），旧版在顶层（username/face）
                            // 下半部颜色现行字段为 background_color2，旧版为 background_bottom_color
                            QJsonObject data = obj["data"].toObject();
                            QJsonObject userInfo = data["user_info"].toObject();
                            QString username = userInfo["uname"].toString();
                            if (username.isEmpty()) username = data["username"].toString();
                            QString face = userInfo["face"].toString();
                            if (face.isEmpty()) face = data["face"].toString();
                            QString message = data["message"].toString();
                            int price = data["price"].toInt();
                            // time 为服务端设计的展示持续秒数（按金额分档）。
                            // 注意：客户端 SC 显示时长已统一为固定 10 秒
                            // （LivePlayerPage.scDisplayDuration），此值仅作协议
                            // 原样透传，不再决定显示时长
                            int scTime = data["time"].toInt();
                            QString bgColor = data["background_color"].toString();
                            QString bgBottomColor = data["background_color2"].toString();
                            if (bgBottomColor.isEmpty()) bgBottomColor = data["background_bottom_color"].toString();
                            if (scTime <= 0) scTime = 60;  // 异常数据兜底
                            emit superChatReceived(username, face, message, price, scTime,
                                                   bgColor, bgBottomColor);
                        }
                        else if (cmd == "SEND_GIFT") {
                        }
                        // 天选时刻开启推送。data 含 id（参与接口的 lottery_id）、
                        // award_name/award_num（奖品与数量）、require_text（参与
                        // 条件）、danmu（需发送的弹幕）、max_time（有效期秒）。
                        // 服务端只推一次；客户端仅在观看中首次收到时提示，不做
                        // 官方那种"开奖前常驻"的选项
                        else if (cmd == "ANCHOR_LOT_START") {
                            QJsonObject data = obj["data"].toObject();
                            // require_type：0=无 1=关注主播 2=粉丝勋章等级 3=大航海。
                            // 服务端**不会**替我们完成关注/发弹幕，官方网页端也是
                            // 先关注、先发口令弹幕，再调 Anchor/Join，所以这里把
                            // 条件类型与礼物价格一并交给 QML/接口层
                            emit anchorLotteryStarted(
                                QString::number(data["id"].toVariant().toLongLong()),
                                data["award_name"].toString(),
                                lenientInt(data["award_num"]),
                                lenientInt(data["require_type"]),
                                data["require_text"].toString(),
                                data["danmu"].toString(),
                                lenientInt(data["max_time"]),
                                lenientInt(data["gift_price"]));
                        }
                        // 天选时刻结束：常驻抽奖按钮据此立刻隐藏（与本地倒计时
                        // 归零互为兜底，服务端推送可能先到或后到）
                        else if (cmd == "ANCHOR_LOT_END") {
                            QJsonObject data = obj["data"].toObject();
                            emit anchorLotteryEnded(
                                QString::number(data["id"].toVariant().toLongLong()));
                        }
                        else if (cmd == "WELCOME") {
                        }
                        else if (cmd == "LIVE") {
                        }
                        else if (cmd == "PREPARING") {
                        }
                        // 高能观众数：data.count。PiliPlus 顶部「高能观众(N)」
                        // 显示的就是它，认证连接后由服务端不定期推送
                        else if (cmd == "ONLINE_RANK_COUNT") {
                            emit onlineRankCountChanged(
                                obj["data"].toObject()["count"].toInt());
                        }
                        // 看过人数：data.text_large 形如 "1.2万人看过"
                        else if (cmd == "WATCHED_CHANGE") {
                            const QString textLarge =
                                obj["data"].toObject()["text_large"].toString();
                            if (!textLarge.isEmpty())
                                emit watchedShowChanged(textLarge);
                        }
                    }
                }
                break;
            }

            default:
                break;
        }

        offset += packetLength;
    }
}

QByteArray LiveDanmakuManager::buildPacket(int operation, const QByteArray &payload)
{
    QByteArray packet;
    QDataStream stream(&packet, QIODevice::WriteOnly);
    stream.setByteOrder(QDataStream::BigEndian);

    quint32 packetLength = PACKET_HEADER_SIZE + payload.size();
    quint16 headerLength = PACKET_HEADER_SIZE;
    quint16 protocolVersion = 0;
    quint32 op = operation;
    quint32 sequence = m_sequence++;

    stream << packetLength;
    stream << headerLength;
    stream << protocolVersion;
    stream << op;
    stream << sequence;

    if (!payload.isEmpty()) {
        packet.append(payload);
    }

    return packet;
}

void LiveDanmakuManager::flushDanmakuBatch()
{
    if (m_batchTimer)
        m_batchTimer->stop();
    if (m_pendingDanmaku.isEmpty())
        return;
    const QVariantList batch = m_pendingDanmaku;
    m_pendingDanmaku.clear();
    emit danmakuBatchReceived(batch);
}
