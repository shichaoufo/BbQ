#ifndef LIVEDANMAKUMANAGER_H
#define LIVEDANMAKUMANAGER_H

#include <QObject>
#include <QtWebSockets>
#include <QTimer>
#include <QByteArray>
#include <QString>
#include <QList>
#include <QColor>
#include <QVariantList>

class LiveDanmakuManager : public QObject
{
    Q_OBJECT

public:
    explicit LiveDanmakuManager(QObject *parent = nullptr);
    ~LiveDanmakuManager();

    struct LiveDanmakuItem {
        QString text;
        QString nickname;
        QColor color;
        int type;           // 1=滚动弹幕
        qint64 timestamp;
        QString uid;
    };

    // QML 可调用接口
    Q_INVOKABLE void connectRoom(int roomId);
    Q_INVOKABLE void disconnectRoom();
    Q_INVOKABLE void setDanmakuInfo(const QString &host, int port, const QString &token);
    Q_INVOKABLE bool isConnected() const;

signals:
    // 50ms 合批后的弹幕批次（替代原逐条 danmakuReceived 信号）。
    // 高峰时刻每条弹幕一次跨线程信号 + 一次 QML 属性系统开销会叠加成卡顿，
    // 合批后一批弹幕只有一次信号；每项为 QVariantMap {text, nickname, color, type}
    void danmakuBatchReceived(const QVariantList &batch);
    void superChatReceived(const QString &username, const QString &face, const QString &message,
                           int price, int time, const QString &backgroundColor, const QString &backgroundBottomColor);
    void connected();
    void disconnected();
    void danmakuError(const QString &errorString);
    void roomInfo(int online, const QString &roomName);
    // 高能观众数实时变化（WS ONLINE_RANK_COUNT，data.count）。
    // PiliPlus 的「高能观众(N)」显示的就是这个值，认证后由服务端推送
    void onlineRankCountChanged(int count);
    // 看过人数实时变化（WS WATCHED_CHANGE，data.text_large，如 "1.2万人看过"）
    void watchedShowChanged(const QString &textLarge);
    // 天选时刻开启（WS ANCHOR_LOT_START）。直播间触发天选时由服务端推送一次，
    // QML 侧据此弹「参与/取消」对话框。字段：
    //   lotteryId  参与接口用的抽奖 id
    //   awardName/awardNum  奖品名 / 数量
    //   requireType 参与条件类型：0=无 1=关注主播 2=粉丝勋章等级 3=大航海(舰长/提督)
    //   requireText 条件文案（"关注主播" 等，直接展示）
    //   danmu       必须发送的弹幕口令（为空则无弹幕要求）
    //   maxTime     有效期秒数
    //   giftPrice   单个礼物价格（>0 表示必须先送礼物才能参与，本端不支持）
    void anchorLotteryStarted(const QString &lotteryId, const QString &awardName, int awardNum,
                              int requireType, const QString &requireText, const QString &danmu,
                              int maxTime, int giftPrice);
    // 天选时刻结束（WS ANCHOR_LOT_END）：QML 侧据此立即隐藏常驻的抽奖按钮，
    // 不必等本地倒计时归零（两路互为兜底）
    void anchorLotteryEnded(const QString &lotteryId);

private slots:
    void onConnected();
    void onDisconnected();
    void onTextMessageReceived(const QString &message);
    void onBinaryMessageReceived(const QByteArray &message);
    void onError(QAbstractSocket::SocketError error);
    void onHeartbeatTimer();
    void onSwitchTimer();  // close() 后延迟 open 新房间，等 SSL 线程退出
    void onCleanupTimer(); // 延迟销毁旧 socket，等 SSL 后台线程完全退出
    void onReconnectTimer(); // 意外断线后自动重连（指数退避）
    void flushDanmakuBatch(); // 50ms 合批刷新

private:
    void sendHeartbeat();
    void sendAuth(int roomId);
    void parsePacket(const QByteArray &data);
    QByteArray buildPacket(int operation, const QByteArray &payload = QByteArray());
    void openConnection();  // 实际发起 open()，供 connectRoom 和待切换房间复用
    void recreateSocket();  // 创建新的 QWebSocket，旧 socket 移入待删除列表
    void teardownConnection(); // 立即销毁 WebSocket 与定时器（aboutToQuit 提前调用 + 析构兜底，幂等）

    QWebSocket *m_webSocket;
    QTimer *m_heartbeatTimer;
    QTimer *m_switchTimer;      // close() 后延迟 open，等 SSL 后台线程完全退出
    QTimer *m_cleanupTimer;     // 延迟销毁旧 socket 列表，确保 SSL 线程退出
    QTimer *m_reconnectTimer;   // 意外断线自动重连（singleShot，指数退避）
    QTimer *m_batchTimer;       // 弹幕 50ms 合批定时器
    QVariantList m_pendingDanmaku;  // 待合批的弹幕缓冲
    QList<QWebSocket*> m_oldSockets;  // 待销毁的旧 socket，由 m_cleanupTimer 统一删除
    int m_roomId;
    bool m_isConnected;
    bool m_isClosing;   // 标记正在断开，忽略残留消息
    int m_sequence;
    QString m_danmakuHost;
    int m_danmakuPort;
    QString m_danmakuToken;
    int m_pendingRoomId;        // 待切换的房间号：close() 期间和 switchTimer 期间记录
    int m_reconnectAttempts;    // 重连尝试次数（指数退避，认证成功后归零）

    static const int PACKET_HEADER_SIZE = 16;
    static const int OP_HEARTBEAT = 2;
    static const int OP_HEARTBEAT_REPLY = 3;
    static const int OP_MESSAGE = 5;
    static const int OP_AUTH = 7;
    static const int OP_AUTH_REPLY = 8;
};

#endif // LIVEDANMAKUMANAGER_H
