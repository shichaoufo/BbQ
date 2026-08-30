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

    property string roomId: ""
    property string title: "直播间标题"
    property string cover: ""
    property string streamer: "主播"
    property string viewers: "1000"
    property string category: "分区"
    property string badgeText: ""  // 特性标签，如"已关注"；为空时显示默认"UP"

    signal clicked()

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
                layer.effect: MultiEffect {
                    maskEnabled: true
                    maskSource: ShaderEffectSource {
                        sourceItem: maskRect
                        hideSource: true
                        live: false
                        // 蒙版纹理按 DPR 超采样 2 倍，圆弧边缘在高分屏缩放
                        // 采样下不出现锯齿（与播放器补角层同款处理）
                        textureSize: Qt.size(
                            Math.max(1, maskRect.width * Screen.devicePixelRatio * 2),
                            Math.max(1, maskRect.height * Screen.devicePixelRatio * 2))
                    }
                }

                Rectangle {
                    anchors.fill: parent
                    color: FluTheme.frameColor
                    visible: root.cover === ""

                    FluIcon {
                        anchors.centerIn: parent
                        iconSource: FluentIcons.Video
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
                    sourceSize: Qt.size(480, 270)
                }

                // 直播状态角标（左上角）
                Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.leftMargin: Theme.cardBadgeSpacing
                    anchors.topMargin: Theme.cardBadgeSpacing
                    width: liveBadgeRow.width + 10
                    height: Theme.cardLiveBadgeHeight
                    radius: Theme.cardBadgeRadius
                    color: "#FF4D4F"

                    Row {
                        id: liveBadgeRow
                        anchors.centerIn: parent
                        spacing: 4

                        Rectangle {
                            width: Theme.cardLiveBadgeDotSize
                            height: Theme.cardLiveBadgeDotSize
                            radius: Theme.cardLiveBadgeDotSize / 2
                            color: "white"
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        FluText {
                            text: "LIVE"
                            font: FluTextStyle.Caption
                            color: "white"
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                }

                // 底部向上渐变消失的黑色阴影
                Rectangle {
                    anchors.fill: parent
                    radius: coverContainer.radius
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: "transparent" }
                        GradientStop { position: 0.55; color: "transparent" }
                        GradientStop { position: 0.78; color: "#70000000" }
                        GradientStop { position: 1.0; color: "#B0000000" }
                    }
                }

                // 左下角观看人数
                Row {
                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                    anchors.leftMargin: Theme.cardBadgeSpacing
                    anchors.bottomMargin: Theme.cardBadgeBottomMargin
                    spacing: Theme.spacingTiny

                    FluIcon {
                        iconSource: FluentIcons.Contact
                        iconSize: Theme.cardBadgeIconSize
                        color: "white"
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    FluText {
                        text: root.viewers
                        font: FluTextStyle.Caption
                        color: "white"
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                // 右下角分区
                FluText {
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.rightMargin: Theme.cardBadgeSpacing
                    anchors.bottomMargin: Theme.cardBadgeBottomMargin
                    text: root.category
                    font: FluTextStyle.Caption
                    color: "white"
                    padding: 2
                }
            }

            FluText {
                id: titleText
                width: parent.width
                height: titleMetrics.height
                text: root.title
                font: FluTextStyle.Body
                color: FluTheme.fontPrimaryColor
                wrapMode: Text.NoWrap
                maximumLineCount: 1
                elide: Text.ElideRight
                verticalAlignment: Text.AlignVCenter
            }

            TextMetrics {
                id: titleMetrics
                font: titleText.font
                text: "X"
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
                    // UP 徽章描边独立于封面描边（同 VideoCard 解耦）
                    border.width: root.badgeText ? 0 : Theme.cardBadgeBorderWidth

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
                    text: root.streamer
                    font: FluTextStyle.Caption
                    color: FluTheme.fontSecondaryColor
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }

        // 封面圆角描边：必须位于 coverContainer 的遮罩层（layer+mask）之外。
        // 若作为 coverContainer 的子项，描边会被同一个圆角蒙版裁剪——外扩部分
        // 落在蒙版裁剪线之外被裁掉，永远盖不住蒙版边缘的抗锯齿毛边。
        // 同级叠加层不受 mask 影响，描边半内半外骑在蒙版边缘上，可完整覆盖。
        // Column 默认位于 (0,0)，封面是其第一个子项，故此矩形与封面对齐。
        Rectangle {
            x: -1
            y: -1
            width: content.width + 2
            height: Math.max(0, content.width * Theme.cardAspectRatio) + 2
            radius: Theme.cardRadius
            color: "transparent"
            border.color: Window.active ? Theme.cardBorderActiveColor : Theme.cardBorderColor
            border.width: Theme.cardBorderWidth
        }
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        onClicked: {
            root.clicked()
        }
        onEntered: {
            if (root.width > 0 && root.height > 0)
                root.hovered = true
        }
        onExited: root.hovered = false
    }
}
