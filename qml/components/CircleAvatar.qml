import QtQuick
import QtQuick.Controls
import QtQuick.Window
import FluentUI
import BiliQt 1.0

FluClip {
    id: root
    property string source: ""
    property string placeholderText: ""

    radius: [width/2, width/2, width/2, width/2]
    color: FluTheme.frameColor

    // Image 实际显示的 URL：显式管理而非绑定。原因：断网时加载失败进入
    // Error 后，QML Image 对未变化的 source 不会重新请求——头像 URL 由本地
    // 登录数据恢复，断网启动客户端后若不重试，头像将永远空白只能重启。
    // _applySource 通过"清空再赋值"强制触发重载；失败后由 retryTimer 重试，
    // 上限 30 次，加载成功即停止并清零计数。
    //
    // cache 保持 true：同一 URL 只发一次网络请求（QML 内存缓存），评论区/动态
    // 列表里同一用户反复出现、delegate 复用时不再重复打 hdslb 图片 CDN——
    // 2026-10-17 起该 CDN 已对我们发 429（限流），重复请求正是主因之一。
    // 失败图像不进缓存，因此"清空再赋值"的强制重试依然会真实发请求，
    // 断网恢复场景不受影响（这一点与 cache:false 时等价）
    property string _displayUrl: ""
    property int _retryCount: 0
    // 重退避间隔：429 是"请求太快"，匀速重试会一直踩限流线，改为指数退避
    // 8s→16s→32s…上限 120s。成功后清零回 8s
    property int _retryInterval: 8000

    function _applySource(force) {
        var u = source !== "" ? GlobalState.fixAvatarUrl(source, width * Screen.devicePixelRatio) : ""
        if (!force && _displayUrl === u) return
        _displayUrl = ""
        _displayUrl = u
    }

    onSourceChanged: _applySource(false)
    onWidthChanged: _applySource(false)
    Component.onCompleted: _applySource(false)

    Timer {
        id: avatarRetryTimer
        interval: root._retryInterval
        repeat: false
        onTriggered: {
            if (root._retryCount >= 30) return
            root._retryCount++
            root._applySource(true)
            // 指数退避：本次重试也失败的话下次等更久（onStatusChanged 的
            // Error 分支会把 interval 翻倍；成功后清零）
            root._retryInterval = Math.min(root._retryInterval * 2, 120000)
            avatarRetryTimer.interval = root._retryInterval
        }
    }

    Image {
        id: avatarImage
        anchors.fill: parent
        source: root._displayUrl
        fillMode: Image.PreserveAspectCrop
        visible: root.source !== "" && status !== Image.Error
        asynchronous: true
        cache: true
        smooth: true
        mipmap: true
        antialiasing: true

        // 注意只在 Ready 清零计数：强制重载的"清空"阶段会短暂经过
        // Null/Loading 状态，在那些状态清零会让上限形同虚设
        onStatusChanged: {
            if (status === Image.Error) {
                avatarRetryTimer.restart()
            } else if (status === Image.Ready) {
                avatarRetryTimer.stop()
                root._retryCount = 0
                root._retryInterval = 8000
                avatarRetryTimer.interval = 8000
            }
        }
    }

    FluText {
        anchors.centerIn: parent
        text: root.placeholderText
        font: FluTextStyle.Caption
        color: FluTheme.fontSecondaryColor
        visible: (root.source === "" || avatarImage.status === Image.Error) && root.placeholderText !== ""
    }
}
