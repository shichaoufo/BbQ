import QtQuick 2.15
import QtQuick.Controls 2.15
import QtMultimedia

Item {
    id: root
    clip: true

    property url source
    property bool animated: false
    // 实况照片的动态视频地址（B站 live_url，mp4）。非空时改用 MediaPlayer
    // 播放视频、不再显示静态图 —— 实况照片的数据形态就是「静态图 .jpg +
    // 独立 .mp4」，静态图只用作列表/网格里的占位和 Hero 过渡标识。
    // 与 PiliPlus 的 SourceModel(sourceType: .livePhoto, liveUrl:) 同语义
    property url liveUrl: ""
    property real minScale: 1.0
    property real maxScale: 10.0
    property real wheelStep: 0.15

    // 左键「单击」（按下到松开之间没有拖动）时发出 —— 预览层据此关闭预览。
    // 与 PiliPlus 的图片预览口径一致：单击关闭、滚轮缩放、放大后左键拖动平移、
    // 右键弹菜单（菜单由各预览层自己挂，本组件只做手势识别，不碰菜单）。
    signal clicked()

    // 拖动判定阈值（px）。取 4，与播放页小窗「拖视频区移动窗口」的判定同值。
    // 桌面鼠标按下时的手抖远小于 4px，而真要拖动平移基本都会超过它。
    property real dragThreshold: 4

    // 是否处于放大状态（供右键菜单决定「重置缩放」是否显示）
    readonly property bool zoomed: _scale > minScale + 0.0001

    property real _scale: 1.0
    property real _offsetX: 0
    property real _offsetY: 0
    // 本次按下是否已升级成拖动。见下方左键 MouseArea。
    property bool _dragged: false

    function reset() {
        _scale = 1.0
        _offsetX = 0
        _offsetY = 0
    }

    onSourceChanged: reset()
    onLiveUrlChanged: reset()

    // liveUrl 是 url 类型：Qt6 里 JS 侧 typeof 是 object，与 "" 严格比较
    // 恒不相等（空串时 liveUrl === "" 也是 false），必须 toString() 后再比。
    // 曾经直接写 liveUrl === "" / !== ""，导致图片 Loader 永不激活、
    // 视频 Loader 常驻，普通图片预览整个消失（实况照片反而正常）
    readonly property bool hasLiveVideo: root.liveUrl.toString() !== ""

    // 实况视频播放器。与图片二选一：liveUrl 非空时启用，否则彻底卸载
    // （Loader.active=false 会销毁实例，MediaPlayer 随之释放，不会在后台继续拉流）
    Loader {
        id: videoLoader
        anchors.fill: parent
        active: root.hasLiveVideo
        sourceComponent: videoComponent
    }

    Component {
        id: videoComponent
        Item {
            anchors.fill: parent

            MediaPlayer {
                id: player
                source: root.liveUrl
                videoOutput: videoOutput
                autoPlay: true
                // 实况视频通常只有 2-3 秒，循环播放才像"实况"
                loops: MediaPlayer.Infinite
                // loops 正常情况下不会走到这里；万一某平台/某格式不吃 loops，
                // 播完了手动续上。刻意不用 playbackState===StoppedState 兜底 ——
                // 加载失败同样会进 StoppedState，那样会和 onErrorOccurred
                // 形成"失败→起播→失败"的空转
                onMediaStatusChanged: {
                    if (mediaStatus === MediaPlayer.EndOfMedia)
                        play()
                }
                onErrorOccurred: console.warn("[ImageViewer] live video error:", errorString)
            }

            VideoOutput {
                id: videoOutput
                anchors.fill: parent
                fillMode: VideoOutput.PreserveAspectFit

                // 缩放/平移与静态图片同口径：绕中心缩放，拖动平移
                scale: root._scale
                transform: Translate {
                    x: root._offsetX
                    y: root._offsetY
                }
            }
        }
    }

    // 动图/静态图二选一按需创建（与 DynamicPage 内嵌图片的 Loader 模式一致）：
    // 不能让静态 Image 与 AnimatedImage 同时挂同一 URL——静态 Image 会先解码
    // GIF/WebP 首帧并与动画实例并存，预览模式下动图因此显示为静止首帧。
    // liveUrl 非空时整个卸载，把舞台让给视频播放器
    Loader {
        id: imageLoader
        anchors.centerIn: parent
        width: root.width
        height: root.height
        active: !root.hasLiveVideo
        sourceComponent: root.animated ? animatedImageComponent : staticImageComponent
    }

    Component {
        id: staticImageComponent
        Image {
            anchors.centerIn: parent
            width: root.width
            height: root.height
            source: root.source
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            cache: true
            smooth: true
            visible: status === Image.Ready

            scale: root._scale
            transform: Translate {
                x: root._offsetX
                y: root._offsetY
            }
        }
    }

    Component {
        id: animatedImageComponent
        AnimatedImage {
            anchors.centerIn: parent
            width: root.width
            height: root.height
            source: root.source
            fillMode: Image.PreserveAspectFit
            cache: true
            smooth: true
            playing: true
            visible: status === AnimatedImage.Ready

            scale: root._scale
            transform: Translate {
                x: root._offsetX
                y: root._offsetY
            }
        }
    }

    // 左键：拖动平移；若按下到松开之间没拖动过，则抛 clicked()（关闭预览）
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor

        property real pressX: 0
        property real pressY: 0
        property real startOffsetX: 0
        property real startOffsetY: 0

        onPressed: (mouse) => {
            pressX = mouse.x
            pressY = mouse.y
            startOffsetX = root._offsetX
            startOffsetY = root._offsetY
            root._dragged = false
        }
        onPositionChanged: (mouse) => {
            if (!pressed)
                return
            // 超过阈值即认定为拖动，松手时不再抛 clicked()。
            // 这里不能只看「底下那位有没有真的平移」：未放大时平移分支不执行，
            // 但用户仍可能在拖（只是没得平移），只看平移会把拖动当成单击而误关预览。
            if (Math.abs(mouse.x - pressX) > root.dragThreshold
                    || Math.abs(mouse.y - pressY) > root.dragThreshold) {
                root._dragged = true
            }
            if (root._scale > root.minScale) {
                root._offsetX = startOffsetX + (mouse.x - pressX)
                root._offsetY = startOffsetY + (mouse.y - pressY)
                root.clampOffset()
            }
        }
        // 双击不再重置缩放：左键单击已改作「关闭预览」，而双击的第一下就已经
        // 把预览关掉了，保留 onDoubleClicked 只会得到一句永远跑不到的死代码。
        // 「重置缩放」挪到右键菜单里（见 ImagePreviewMenu），滚轮缩到底等效。
        onClicked: {
            if (!root._dragged)
                root.clicked()
        }
        onCanceled: root._dragged = false
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.NoButton
        onWheel: (wheel) => {
            const oldScale = root._scale
            const factor = wheel.angleDelta.y > 0 ? (1 + root.wheelStep) : 1 / (1 + root.wheelStep)
            const newScale = Math.max(root.minScale, Math.min(root.maxScale, oldScale * factor))
            if (newScale === oldScale)
                return

            const contentX = wheel.x - root.width / 2
            const contentY = wheel.y - root.height / 2
            const ratio = newScale / oldScale

            root._offsetX -= contentX * (ratio - 1)
            root._offsetY -= contentY * (ratio - 1)
            root._scale = newScale
            root.clampOffset()
        }
    }

    function clampOffset() {
        if (_scale <= minScale) {
            _offsetX = 0
            _offsetY = 0
            return
        }
        const maxX = Math.max(0, (root.width * (_scale - 1)) / 2)
        const maxY = Math.max(0, (root.height * (_scale - 1)) / 2)
        _offsetX = Math.max(-maxX, Math.min(maxX, _offsetX))
        _offsetY = Math.max(-maxY, Math.min(maxY, _offsetY))
    }
}
