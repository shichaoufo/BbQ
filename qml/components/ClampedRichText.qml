import QtQuick 2.15
import QtQuick.Controls 2.15

import FluentUI 1.0
import BiliQt 1.0

// 正文富文本的"整行截断 + 查看更多"
//
// 为什么不用 CommentRichText 自带的 maxLines：那个只在"纯文本单 Text"路径生效，
// 正文里只要有一个动态表情就会走 Flow 分段路径，那条路径无法 elide，整段都会展开。
// 这里改成按高度裁切，裁在整行边界上，最后一行保证完整，下面再单独留一行给「查看更多」。
Item {
    id: root

    property var segments: []
    property font bodyFont: Theme.fontNormal
    property color bodyColor: FluTheme.fontPrimaryColor
    property int maxLines: 5
    property string moreLabel: "查看更多"

    signal linkActivated(string link)
    signal moreClicked()

    // ---------- 高度怎么算 ----------
    //
    // 教训（2026-10-27）：正文里出现 Unicode 表情（如 ⭐）时，Qt 会回退到
    // Segoe UI Emoji 等字体，那一行的行盒变成 26px（实测：普通行 24px）。
    // 早先的做法是用一个 "国\n国\n…" 的 QML 探针算 N 行高（5 × 24 = 120），
    // 而真实内容是 4×24 + 26 = 122 → 裁在 120 就把最后一行底部切掉了 2px。
    // 探针只能反映**纯汉字**行高，任何字体回退都会让它偏小。
    //
    // 为什么不用 Text.maximumLineCount：QML 的 Text 在 RichText 下**不支持**
    // maximumLineCount / elide / lineCount（Qt 官方文档明确写了不支持），
    // 试过 StyledText 量尺，行高与 RichText 差 4px，也不可靠。
    // 所以改用 App.measureRichTextLines()：C++ 里用 QTextDocument 排一遍，
    // 与 QQuickText 的富文本内部实现同源，能给出"前 N 行精确高度 + 总行数"。
    readonly property bool _flowMode: body.hasAnimatedEmote

    // C++ 量尺：{ height: 前 maxLines 行高度, lineCount: 总行数 }
    readonly property var _measured: {
        if (root.width <= 0) return ({ height: 0, lineCount: 0 })
        return App.measureRichTextLines(body.plainHtml, root.width,
                                        root.bodyFont, Math.max(1, root.maxLines))
    }

    // Flow 路径（含动态表情）仍用探针：那条路径的行高由分段矩形自己决定，
    // 量尺反映的是富文本，对不上；且动态表情卡片极罕见，老办法足够。
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

    readonly property real bodyH: {
        if (root.width <= 0) return Math.max(1, body.implicitHeight)
        if (root._flowMode) return Math.max(1, lineProbe.implicitHeight)
        var h = root._measured.height
        // 量不到（空内容等）时退回正文自身高度，避免出现 0 高度。
        // 量到则向上取整再 +1：C++ 的 QTextDocument 与 QQuickText 的行高可能有
        // 亚像素差，宁可多留 1px（那 1px 是下一行的行首留白，看不出来），
        // 也不能少 —— 少了就是把最后一行切掉。
        return (h > 0) ? (Math.ceil(h) + 1)
                       : Math.max(1, Math.min(body.implicitHeight, lineProbe.implicitHeight))
    }

    readonly property bool truncated: {
        if (root.width <= 0) return false
        if (root._flowMode) return body.implicitHeight > root.bodyH + 1
        return root._measured.lineCount > Math.max(1, root.maxLines)
    }

    implicitHeight: bodyH + (truncated ? moreText.implicitHeight : 0)

    // 暴露给调用方绑 Layout.preferredHeight 用
    readonly property real naturalHeight: implicitHeight

    Item {
        width: parent.width
        height: root.bodyH
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
