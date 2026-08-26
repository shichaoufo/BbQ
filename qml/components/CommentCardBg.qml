import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Window 2.15
import FluentUI 1.0
import BiliQt 1.0

Item {
    id: root

    property var cardbg: null
    // 是否显示 NO. 前缀：默认 true（评论区原样）；动态页单独传 false
    property bool showNoPrefix: true
    // 数字相对装饰图的位置：
    //   "right" → 默认（评论区原样，装饰图在左，数字在右，1:1还原老项目）
    //   "left"  → 动态页定制，数字在装饰图左侧
    property string numberPosition: "right"

    // ====== 评论区默认值 100% 还原老项目 /workspace/BiliQt_QuickVulkan_Old CommentCardBg.qml ======
    // numberPosition="right"（评论区默认）时就是老项目 1:1；"left" 时走动态页定制覆盖
    readonly property bool _isRight: numberPosition === "right"

    width: _isRight ? 150 : 180
    height: 54
    visible: cardbg && cardbg.show

    // 数字字体大小：评论区 11 老项目一致；动态页 17（加粗，用户要求再大）
    readonly property int _numFontSize: _isRight ? 11 : 17
    readonly property bool _numBold: !_isRight   // 动态页数字加粗
    // NO. 字体大小（评论区老项目 9px；动态页不显示NO.前缀，此值无用）
    readonly property int _noFontSize: 9
    // Row 间距：评论区老项目 6；动态页 4
    readonly property int _rowSpacing: _isRight ? 6 : 4
    // 装饰图 Item 宽度：评论区老项目 100；动态页 110（更舒展）
    readonly property int _decorateWidth: _isRight ? 100 : 110
    // 装饰图 translateX：评论区老项目 35（NO.XXX 与装饰重叠一部分）；动态页 12 贴紧数字
    readonly property int _decorateTranslateX: _isRight ? 35 : 12
    // 数字列 translateX：动态页（数字在左）再往右移动 15px
    //   累计偏移：第一轮15 + 第二轮15（共30） + 本轮15 = 总共 45px
    readonly property int _numberTranslateX: _isRight ? 0 : 45

    function cardBgImageUrl(image) {
        if (!image) return ""
        var url = image
        var atIndex = url.indexOf("@")
        if (atIndex >= 0) url = url.substring(0, atIndex)
        // 装扮图统一用原图 PNG（官方评论区/动态页都是 PNG 原图，CDN 支持直访）。
        // 不调 GlobalState.fixImageUrl：它对无 @ 参数的 URL 会追加 @.jpg，
        // 把 PNG 转 JPEG 丢失透明通道。这里只补全协议头。
        if (url.indexOf("//") === 0) url = "https:" + url
        return url
    }

    Row {
        id: mainRow
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: root._rowSpacing
        height: root.height
        layoutDirection: Qt.LeftToRight
        // 注意：Qt Quick Row 没有 verticalItemAlignment 属性；
        // 统一通过每个子 Loader 的 anchors.verticalCenter + 子 Component 内部的 anchors.verticalCenter
        // 双层保险确保数字列和装饰图的 Y 中心完全对齐。

        // ====== 评论区默认 (right)：装饰图在前，数字在后（老项目结构完全一致）======
        // ====== 动态页定制 (left)：数字在前，装饰图在后 ================================
        Loader {
            active: true
            anchors.verticalCenter: parent.verticalCenter
            sourceComponent: root._isRight ? decorateImageComponent : numberColumnComponent
        }

        Loader {
            active: true
            anchors.verticalCenter: parent.verticalCenter
            sourceComponent: root._isRight ? numberColumnComponent : decorateImageComponent
        }
    }

    // ===== 子组件：数字列（NO. + 数字），评论区和动态页共用，只是字号不同 =====
    Component {
        id: numberColumnComponent
        Column {
            id: numCol
            // 数字列整体垂直居中：与 Row（装饰图+数字共同高度=54） 的 Y 中心对齐
            anchors.verticalCenter: parent.verticalCenter
            spacing: 0
            // 数字向右偏移 15px（评论区_isRight时为0，动态页时15）
            transform: Translate { x: root._numberTranslateX }

            FluText {
                visible: root.showNoPrefix
                text: "NO."
                font.pixelSize: root._noFontSize
                color: root.cardbg && root.cardbg.fanColor ? root.cardbg.fanColor : "#FB7299"
                horizontalAlignment: Text.AlignLeft
                width: contentWidth
                height: implicitHeight
            }

            FluText {
                text: root.cardbg ? (root.cardbg.fanNumDesc || "") : ""
                font.pixelSize: root._numFontSize
                font.bold: root._numBold
                color: root.cardbg && root.cardbg.fanColor ? root.cardbg.fanColor : "#FB7299"
                horizontalAlignment: Text.AlignLeft
                width: contentWidth
                height: implicitHeight
            }
        }
    }

    // ===== 子组件：装饰图（卡片右侧装饰图案），评论区和动态页共用，只是宽度和偏移不同 =====
    Component {
        id: decorateImageComponent
        Item {
            id: decorateItem
            width: root._decorateWidth
            height: root.height
            // 不 clip：装扮图左侧带渐变透明区，clip 会把渐变硬切掉，
            // 去掉后图片左侧自然渐隐到数字区域下方，与官方效果一致
            // 装饰 Item 整体垂直居中（与数字列对齐）
            anchors.verticalCenter: parent.verticalCenter
            transform: Translate { x: root._decorateTranslateX }

            Image {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                height: root.height
                width: height * 5
                source: root.cardbg && root.cardbg.image ? root.cardBgImageUrl(root.cardbg.image) : ""
                fillMode: Image.PreserveAspectCrop
                mipmap: true
                asynchronous: true
            }
        }
    }
}
