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

    TextMetrics {
        id: metrics
        font: root.bodyFont
        text: "国"
    }
    readonly property real lineH: Math.max(12, metrics.height)
    readonly property real bodyH: lineH * Math.max(1, root.maxLines)
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
