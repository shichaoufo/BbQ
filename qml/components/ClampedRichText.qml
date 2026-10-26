import QtQuick 2.15
import QtQuick.Controls 2.15

import FluentUI 1.0
import BiliQt 1.0

// 正文富文本的"整行截断 + 查看更多"
//
// 为什么不用 CommentRichText 自带的 maxLines：那个只在"纯文本单 Text"路径生效，
// 正文里只要有一个动态表情就会走 Flow 分段路径，那条路径无法 elide，整段都会展开。
// 这里改成按高度裁切：用 TextMetrics 量出真实行高，裁在整行边界上，
// 最后一行保证完整，下面再单独留一行给「查看更多」。
Item {
    id: root

    property var segments: []
    property font bodyFont: Theme.fontNormal
    property color bodyColor: FluTheme.fontPrimaryColor
    property int maxLines: 5
    property string moreLabel: "查看更多"

    signal linkActivated(string link)
    signal moreClicked()

    // 探针：让 Qt 自己把 maxLines 行排一遍，读它的真实整块高度。
    //
    // 为什么不能用 TextMetrics.height × maxLines（原来就是这么写的）：
    // TextMetrics.height 是**单行字体度量**（ascent+descent，可能是小数），
    // 而真实排版会**逐行向上取整**。实测 Qt 6.11 / 微软雅黑 / pointSize 14：
    //   100% 缩放：metrics.height = 24.000，实际每行 24px，5 行 = 120  → 差值 0，看不出来
    //   150% 缩放：metrics.height = 24.125，实际每行 25px，5 行 = 125
    //              metrics × 5 = 120.625 → 裁掉 4.4px，正好把最后一行切掉下半截
    // 单行的小数误差乘以行数就会被放大 —— 这就是"只有 150% 才截断"的原因。
    readonly property string _probeText: {
        var n = Math.max(1, root.maxLines)
        var s = ""
        for (var i = 0; i < n; i++) s += (i === 0 ? "" : "\n") + "国"
        return s
    }

    Text {
        id: lineProbe
        visible: false
        text: root._probeText
        font: root.bodyFont
        textFormat: Text.PlainText
        wrapMode: Text.NoWrap
    }

    // N 行整块的精确高度（已含逐行取整）
    readonly property real lineH: Math.max(1, lineProbe.implicitHeight / Math.max(1, root.maxLines))
    readonly property real bodyH: Math.max(1, lineProbe.implicitHeight)
    readonly property bool truncated: body.implicitHeight > bodyH + 1

    implicitHeight: Math.min(body.implicitHeight, bodyH)
                    + (truncated ? moreText.implicitHeight : 0)

    // 暴露给调用方绑 Layout.preferredHeight 用
    readonly property real naturalHeight: implicitHeight

    Item {
        width: parent.width
        height: Math.min(body.implicitHeight, root.bodyH)
        clip: true

        CommentRichText {
            id: body
            width: parent.width
            segments: root.segments
            bodyFont: root.bodyFont
            bodyColor: root.bodyColor
            onLinkActivated: function(link) { root.linkActivated(link) }
        }
    }

    FluText {
        id: moreText
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        text: root.moreLabel
        font: Theme.fontSmall
        color: FluTheme.primaryColor
        visible: root.truncated

        MouseArea {
            anchors.fill: parent
            anchors.margins: -4
            cursorShape: Qt.PointingHandCursor
            onClicked: root.moreClicked()
        }
    }
}
