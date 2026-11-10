import QtQuick 2.15

// 带自动重试的图片
//
// 背景：B 站图床偶尔会直接掐断连接（日志里是
//   QML QQuickImage: HTTP/2 protocol error
//   stream 1999 finished with error: "HTTP/2 protocol error"
// 一张图失败一次就一直空着 —— 表情面板一开几十张图并发，最容易撞上，
// 表现就是"偶尔有几个表情加载不出来"。
//
// 重设一次 source 就能恢复，所以这里失败后自动重试 3 次（300/600/1200ms 退避）。
//
// 注意重试要在 URL 后面挂一个递增参数：Qt 对**同一个 URL** 直接重设 source
// 不会重新发起请求，必须让 URL 变化才会真正重来；B 站 CDN 会忽略未知查询参数。
Image {
    id: img

    // 用法：写 imageSource，不要写 source（source 由本组件接管）
    property url imageSource
    property int maxRetries: 3

    // 第几次重试。0 = 原始 URL
    property int _attempt: 0

    readonly property bool _hasSource: imageSource !== undefined
                                       && imageSource !== null
                                       && String(imageSource) !== ""

    readonly property string _retrySuffix: {
        if (_attempt <= 0 || !_hasSource)
            return ""
        return (String(imageSource).indexOf("?") >= 0 ? "&_r=" : "?_r=") + _attempt
    }

    // 注意 imageSource 未绑定时是 undefined，String(undefined) === "undefined"，
    // 直接拼会让 Image 去请求一个叫 "undefined" 的相对路径，所以先判空。
    source: _hasSource ? String(imageSource) + _retrySuffix : ""

    // 换图（delegate 复用 / 切换表情包）时重置计数
    onImageSourceChanged: _attempt = 0

    onStatusChanged: {
        if (status === Image.Error) {
            if (_attempt < maxRetries)
                retryTimer.restart()
        }
    }

    Timer {
        id: retryTimer
        // 300ms 起步，最多退避到 1200ms
        interval: 300 * Math.pow(2, Math.min(img._attempt, 2))
        onTriggered: img._attempt += 1
    }
}
