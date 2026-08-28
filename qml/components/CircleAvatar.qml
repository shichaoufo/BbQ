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
    // _applySource 通过"清空再赋值"强制触发重载（cache: false 保证发起
    // 真实的网络请求）；失败后由 retryTimer 每 8s 重试一次，上限 30 次
    //（约 4 分钟，覆盖典型断网恢复窗口，失效 URL 不会永久空转重试），
    // 加载成功即停止并清零计数
    property string _displayUrl: ""
    property int _retryCount: 0

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
        interval: 8000
        repeat: false
        onTriggered: {
            if (root._retryCount >= 30) return
            root._retryCount++
            root._applySource(true)
        }
    }

    Image {
        id: avatarImage
        anchors.fill: parent
        source: root._displayUrl
        fillMode: Image.PreserveAspectCrop
        visible: root.source !== "" && status !== Image.Error
        asynchronous: true
        cache: false
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
