import QtQuick 2.15
import QtQuick.Controls 2.15

Item {
    id: root
    clip: true

    property url source
    property bool animated: false
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

    // 动图/静态图二选一按需创建（与 DynamicPage 内嵌图片的 Loader 模式一致）：
    // 不能让静态 Image 与 AnimatedImage 同时挂同一 URL——静态 Image 会先解码
    // GIF/WebP 首帧并与动画实例并存，预览模式下动图因此显示为静止首帧。
    Loader {
        id: imageLoader
        anchors.centerIn: parent
        width: root.width
        height: root.height
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
