import QtQuick 2.15

// 评论正文渲染器。
//
// 背景：Qt 富文本里的 <img> 永远只画第一帧（QTextDocument 把图片当静态资源缓存），
// 所以动态表情放进去就是一张静图。AnimatedImage 能播，但它没法嵌在 Text 内部。
//
// 因此这里做**双路径**：
//   · 正文里没有动态表情（绝大多数评论）-> 走老路径：单个 Text.RichText，
//     参数与替换前逐字一致，排版零变化；
//   · 含动态表情 -> 走 Flow 分段：文本段仍是 Text.RichText（排版还是 Qt 管），
//     只有表情段换成 AnimatedImage。
// 把两条路分开，是为了让"动图"这个新特性完全不波及原有排版。
//
// 用法：
//   CommentRichText {
//       segments: GlobalState.formatCommentSegments(...)
//       bodyFont: FluTextStyle.Body
//       bodyColor: FluTheme.fontPrimaryColor
//       Layout.fillWidth: true
//       onLinkActivated: function(link) { ... }
//   }
Item {
    id: root

    // [{t:"text", html, breakAfter} | {t:"emote", url, gifUrl, size}]
    property var segments: []
    property font bodyFont
    property color bodyColor: "#000000"
    // 最大行数：0 = 不限制（评论正文）。>0 时按行数截断并显示省略号 ——
    // 只对**单 Text 路径**（正文无动态表情）生效；含动态表情走 Flow 分段，
    // Flow 的 item 是独立矩形，无法参与 Text 的 elide 机制，故不截断
    // （动态卡片里同时出现动态表情又超长的概率极低）。
    property int maxLines: 0

    signal linkActivated(string link)

    // 有动态表情才切到分段路径
    property bool hasAnimatedEmote: {
        for (var i = 0; i < segments.length; i++) {
            var g = segments[i]
            if (g && g.t === "emote" && g.gifUrl) return true
        }
        return false
    }

    // 老路径要把各文本段拼回一整块 HTML（breakAfter 补回被切掉的换行）
    property string plainHtml: {
        var s = ""
        for (var i = 0; i < segments.length; i++) {
            var g = segments[i]
            if (!g || g.t !== "text") continue
            s += (g.html || "")
            if (g.breakAfter) s += "<br>"
        }
        return s
    }

    // 一行文字的高度：用来把表情的行高对齐到文字行高，避免表情把行撑高
    property real lineHeight: {
        var px = bodyFont.pixelSize > 0 ? bodyFont.pixelSize
               : (bodyFont.pointSize > 0 ? Math.round(bodyFont.pointSize * 1.333) : 14)
        return Math.ceil(px * 1.45)
    }

    // 只绑高度：宽度交给 Layout（实例处用 Layout.fillWidth）。
    // 若这里也绑 implicitWidth，会与子项 width 形成循环绑定。
    implicitHeight: hasAnimatedEmote ? flow.implicitHeight : plainText.implicitHeight

    // ---------- 路径一：无动态表情，与替换前完全等价 ----------
    Text {
        id: plainText
        visible: !root.hasAnimatedEmote
        width: root.width
        text: root.plainHtml
        font: root.bodyFont
        color: root.bodyColor
        textFormat: Text.RichText
        wrapMode: Text.Wrap
        verticalAlignment: Text.AlignTop
        // maxLines > 0 时按行数截断（列表卡片摘要用，等价原 FluText 的
        // maximumLineCount + elide 组合）；0 时 -1/ElideNone 即不限制
        maximumLineCount: root.maxLines > 0 ? root.maxLines : -1
        elide: root.maxLines > 0 ? Text.ElideRight : Text.ElideNone
        onLinkActivated: function(link) { root.linkActivated(link) }
    }

    // ---------- 路径二：含动态表情，Flow 分段 ----------
    Flow {
        id: flow
        visible: root.hasAnimatedEmote
        width: root.width
        spacing: 0

        Repeater {
            model: root.hasAnimatedEmote ? root.segments : []

            Item {
                id: segItem
                property var seg: modelData
                property bool isEmote: !!(seg && seg.t === "emote")
                property bool forceBreak: !!(seg && seg.breakAfter === true)

                // 量宽用的影子文本：**必须 NoWrap**。
                // 直接用可见 Text 的 implicitWidth 不行 —— 它带 wrapMode，
                // 值会随可用宽度变化，拿来做 Flow 的 item 宽度会翻车。
                Text {
                    id: measure
                    visible: false
                    text: segItem.isEmote ? "" : (segItem.seg.html || "")
                    font: root.bodyFont
                    textFormat: Text.RichText
                    wrapMode: Text.NoWrap
                }

                // 段宽：表情按图片宽；文本段取"自然宽度"，但不超过容器宽
                //（超长句仍会独占一行并在段内折行 —— 这是 Flow 的固有取舍）。
                // breakAfter 的段强制占满整行，使后续 item 从新行开始，
                // 等价于原文的换行。
                width: isEmote
                       ? (segItem.seg.size + 4)
                       : (forceBreak ? flow.width
                                     : Math.min(measure.implicitWidth, flow.width))
                height: isEmote
                        ? Math.max(root.lineHeight, segItem.seg.size)
                        : inner.implicitHeight

                Text {
                    id: inner
                    visible: !segItem.isEmote
                    width: segItem.width
                    text: segItem.isEmote ? "" : (segItem.seg.html || "")
                    font: root.bodyFont
                    color: root.bodyColor
                    textFormat: Text.RichText
                    wrapMode: Text.Wrap
                    verticalAlignment: Text.AlignTop
                    onLinkActivated: function(link) { root.linkActivated(link) }
                }

                AnimatedImage {
                    visible: segItem.isEmote
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.verticalCenter: parent.verticalCenter
                    width: segItem.isEmote ? segItem.seg.size : 0
                    height: width
                    // 动图 URL 不能走 fixImageUrl 的格式转换分支（会把动图变静图），
                    // fixImageUrl 内部已对 .gif/.webp 原样返回。
                    source: segItem.isEmote ? segItem.seg.gifUrl : ""
                    playing: segItem.isEmote && flow.visible
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                    // 动图原图通常比显示尺寸大得多，没有 mipmap 时缩小采样会
                    // 出现闪烁/锯齿（和静态表情同一个问题）
                    mipmap: true
                    cache: true
                }
            }
        }
    }
}
