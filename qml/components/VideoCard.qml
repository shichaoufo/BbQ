import QtQuick 2.15
import QtQuick.Window 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import QtQuick.Effects

import FluentUI 1.0
import BiliQt 1.0

Rectangle {
    id: root
    implicitHeight: Math.max(1, width * Theme.cardAspectRatio + Theme.cardInfoHeight)

    property string bvid: ""
    property string title: "视频标题 - Qt Quick Vulkan 演示视频"
    property string cover: ""
    property string author: "UP主"
    property string views: "10万"
    property string danmakus: "1234"
    property string duration: "10:24"
    property string pubDate: "2天前"
    property string badgeText: ""  // 特性标签，如"1万点赞""已关注"；为空时显示默认"UP"

    // ====== 番剧推荐卡片专用字段（isBangumiCard=true 时生效） ======
    property bool isBangumiCard: false
    property real score: 0             // 评分，如 9.6；<=0 显示"暂无评分"
    property string followCount: ""    // 追番数（已格式化的字符串，如"123.5万"）
    property string updateInfo: ""     // 更新进度（如"更新至第12话"、"全12话"，为空时用 author）
    // 番剧跳转字段
    property string seasonId: ""
    property string epId: ""

    color: "transparent"

    property bool hovered: false

    // 圆角遮罩源（用于封面容器的 MultiEffect 遮罩）
    Rectangle {
        id: maskRect
        x: -10000
        y: -10000
        width: Math.max(0, root.width)
        height: Math.max(0, root.width * Theme.cardAspectRatio)
        radius: Theme.cardRadius
        color: "black"
        visible: true
    }

    Item {
        id: cardContent
        anchors.fill: parent
        layer.enabled: root.hovered && root.width > 0 && root.height > 0
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: "#80000000"
            shadowOpacity: root.hovered ? 0.5 : 0
            shadowBlur: 0.8
            shadowVerticalOffset: root.hovered ? 8 : 0
            shadowScale: 1
            Behavior on shadowOpacity { NumberAnimation { duration: 200 } }
            Behavior on shadowVerticalOffset { NumberAnimation { duration: 200 } }
        }
        transform: Translate {
            y: root.hovered ? -8 : 0
            Behavior on y { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        }

        Column {
            id: content
            width: parent.width
            spacing: Theme.cardSpacing

            Rectangle {
                id: coverContainer
                width: parent.width
                height: Math.max(0, width * Theme.cardAspectRatio)
                color: "transparent"
                radius: Theme.cardRadius
                clip: true
                layer.enabled: root.width > 0 && root.height > 0
                layer.samples: 4
                layer.effect: MultiEffect {
                    maskEnabled: true
                    maskSource: ShaderEffectSource {
                        sourceItem: maskRect
                        hideSource: true
                        live: false
                    }
                }

                Rectangle {
                    anchors.fill: parent
                    color: FluTheme.frameColor
                    visible: root.cover === ""

                    FluIcon {
                        anchors.centerIn: parent
                        iconSource: FluentIcons.Play
                        iconSize: Theme.cardCoverPlaceholderIconSize
                        color: FluTheme.fontTertiaryColor
                    }
                }

                FluImage {
                    anchors.fill: parent
                    source: GlobalState.fixImageUrlStatic(root.cover)
                    fillMode: Image.PreserveAspectCrop
                    visible: root.cover !== ""
                    asynchronous: true
                    cache: true
                    sourceSize: Qt.size(480, 270)
                }

                // 底部向上渐变消失的黑色阴影
                Rectangle {
                    anchors.fill: parent
                    radius: coverContainer.radius
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: "transparent" }
                        GradientStop { position: 0.75; color: "transparent" }
                        GradientStop { position: 0.90; color: "#70000000" }
                        GradientStop { position: 1.0; color: "#B0000000" }
                    }
                }

                // 底部统计信息（播放 + 弹幕 / 播放 + 追番）
                Row {
                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                    anchors.leftMargin: Theme.cardBadgeSpacing
                    anchors.bottomMargin: Theme.cardBadgeBottomMargin
                    spacing: Theme.spacingTiny

                    FluIcon {
                        iconSource: FluentIcons.Slideshow
                        iconSize: Theme.cardBadgeIconSize
                        color: "white"
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    FluText {
                        text: root.views
                        font: FluTextStyle.Caption
                        color: "white"
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    FluText {
                        text: "·"
                        font: FluTextStyle.Caption
                        color: "#b0b0b0"
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    FluIcon {
                        // 番剧推荐卡片：追番图标(心形)；普通视频：弹幕图标
                        // FluentUI 图标使用 PascalCase 命名（FluentIcons.Heart / FluentIcons.Favorite）
                        iconSource: root.isBangumiCard ? FluentIcons.Heart : FluentIcons.Subtitles
                        iconSize: Theme.cardBadgeIconSize
                        color: "white"
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    FluText {
                        // 番剧推荐卡片：追番数；普通视频：弹幕数
                        text: root.isBangumiCard ? root.followCount : root.danmakus
                        font: FluTextStyle.Caption
                        color: "white"
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                // 右下角角标：番剧卡片=评分(9.6分)；普通卡片=时长
                FluText {
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.rightMargin: Theme.cardBadgeSpacing
                    anchors.bottomMargin: Theme.cardBadgeBottomMargin
                    text: {
                        if (root.isBangumiCard) {
                            // 番剧推荐卡片：评分，如 "9.6分"，<=0 时显示 "暂无评分"
                            return root.score > 0 ? root.score.toFixed(1) + "分" : "暂无评分"
                        }
                        return root.duration
                    }
                    font: FluTextStyle.Caption
                    color: "white"
                    padding: 2
                }

                // 圆角边框覆盖层
                Rectangle {
                    anchors.fill: parent
                    radius: coverContainer.radius
                    color: "transparent"
                    border.color: Theme.cardBorderColor
                    border.width: Theme.cardBorderWidth
                }
            }

            // 标题区域固定占用 2 行高度
            Item {
                width: parent.width
                height: titleMeasure.paintedHeight

                Text {
                    id: titleMeasure
                    visible: false
                    width: parent.width
                    font: titleText.font
                    text: "X\nX"
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                }

                FluText {
                    id: titleText
                    anchors.fill: parent
                    text: root.title
                    font: FluTextStyle.Body
                    color: FluTheme.fontPrimaryColor
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    verticalAlignment: Text.AlignTop
                }
            }

            Row {
                width: parent.width
                spacing: Theme.cardSpacing

                Rectangle {
                    id: upBadge
                    width: root.badgeText ? Math.max(1, Math.min(Math.max(1, root.width * 0.45), badgeLabel.implicitWidth + 8)) : Theme.cardBadgeWidth
                    height: Theme.cardBadgeHeight
                    radius: Theme.cardBadgeRadius
                    color: root.badgeText ? "#FFF0D9" : "transparent"
                    border.color: root.badgeText ? "transparent" : FluTheme.fontSecondaryColor
                    border.width: root.badgeText ? 0 : Theme.cardBorderWidth
                    visible: !root.isBangumiCard  // 番剧推荐卡片不加 UP/追番 徽章，直接显示更新进度

                    FluText {
                        id: badgeLabel
                        anchors.centerIn: parent
                        width: root.badgeText ? parent.width - 8 : implicitWidth
                        text: root.badgeText ? root.badgeText : "UP"
                        font: FluTextStyle.Caption
                        color: root.badgeText ? "#FF8C00" : FluTheme.fontSecondaryColor
                        elide: root.badgeText ? Text.ElideRight : Text.ElideNone
                        horizontalAlignment: Text.AlignHCenter
                    }
                }

                FluText {
                    text: {
                        if (root.isBangumiCard) {
                            // 番剧卡片：显示更新进度（如"更新至第12话"/"全12话"），空时用 author 兜底
                            return (root.updateInfo && root.updateInfo.length > 0)
                                ? root.updateInfo
                                : root.author
                        }
                        // 普通视频：UP主 + 发布时间
                        return root.author + (root.pubDate ? " · " + root.pubDate : "")
                    }
                    font: FluTextStyle.Caption
                    color: FluTheme.fontSecondaryColor
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    maximumLineCount: 1
                    width: Math.max(1, upBadge.visible
                        ? parent.width - upBadge.width - parent.spacing
                        : parent.width)
                    wrapMode: Text.NoWrap
                }
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            if (root.isBangumiCard) {
                // 番剧推荐卡片：走 openBangumi（通过 AppManager 转发）
                // 注意参数顺序必须和 App.openBangumi 签名一致：(bvid, epId, seasonId, title)
                App.openBangumi(root.bvid || "", root.epId || "", root.seasonId || "", root.title)
            } else {
                App.openVideo(root.bvid, root.title)
            }
        }
        onEntered: {
            if (root.width > 0 && root.height > 0)
                root.hovered = true
        }
        onExited: root.hovered = false
    }
}
