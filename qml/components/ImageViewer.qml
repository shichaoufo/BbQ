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

    property real _scale: 1.0
    property real _offsetX: 0
    property real _offsetY: 0

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
        }
        onPositionChanged: (mouse) => {
            if (pressed && root._scale > root.minScale) {
                root._offsetX = startOffsetX + (mouse.x - pressX)
                root._offsetY = startOffsetY + (mouse.y - pressY)
                root.clampOffset()
            }
        }
        onDoubleClicked: root.reset()
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
