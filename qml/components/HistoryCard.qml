import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import QtQuick.Effects
import QtQuick.Window 2.15

import FluentUI 1.0
import BiliQt 1.0

Rectangle {
    id: root
    implicitHeight: Math.max(1, width * Theme.cardAspectRatio + Theme.cardInfoHeight)

    property string type: "video" // "video", "live", 或 "bangumi"
    property string bvid: ""
    property string roomId: ""
    property string epId: ""
    property string seasonId: ""
    property bool isBangumi: false
    property string title: "视频标题 - Qt Quick Vulkan 演示视频"
    // 番剧专用：番剧总名称，作为主标题（显示在卡片的第一行）
    property string seasonTitle: ""
    // 番剧专用：当前集数的标题，如"第4集 凡人风起天南4"，作为第二行（原UP主位置）
    property string epTitle: ""
    property string cover: ""
    property string author: "UP主"

    // 视频历史
    property string viewTime: ""
    property string progress: "00:00/00:00"
    property bool finished: false

    // 直播历史
    property bool isLive: false

    signal clicked()

    color: "transparent"

    property bool hovered: false

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
                    live: true
                }
            }

            Rectangle {
                anchors.fill: parent
                color: FluTheme.frameColor
                visible: root.cover === ""

                FluIcon {
                    anchors.centerIn: parent
                    // 为每个枚举项加 || 0 回退，防止某个 FluentIcons 值未注册/拼写错时
                    // 出现 "Unable to assign [undefined] to int" 警告（番剧卡片 type="bangumi"
                    // 时走 FluentIcons.Movie 分支，如果该枚举缺失就会触发 undefined→int 报错）。
                    iconSource: (root.type === "live"   ? (FluentIcons.Video || 0)
                               : root.type === "bangumi" ? (FluentIcons.Movie || 0)
                               :                            (FluentIcons.Play  || 0))
                    iconSize: Theme.cardCoverPlaceholderIconSize || 48
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

            // 视频/直播历史：左下角观看时间
            Row {
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                anchors.leftMargin: Theme.cardBadgeSpacing
                anchors.bottomMargin: Theme.cardBadgeBottomMargin
                spacing: Theme.spacingTiny
                visible: root.type === "video" || root.type === "live" || root.type === "bangumi"

                FluIcon {
                    iconSource: FluentIcons.ScreenTime
                    iconSize: Theme.cardBadgeIconSize
                    color: "white"
                    anchors.verticalCenter: parent.verticalCenter
                }

                FluText {
                    text: root.viewTime
                    font: FluTextStyle.Caption
                    color: "white"
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            // 视频历史：右下角播放进度（未看完时）
            FluText {
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.rightMargin: Theme.cardBadgeSpacing
                anchors.bottomMargin: Theme.cardBadgeBottomMargin
                text: root.progress
                font: FluTextStyle.Caption
                color: "white"
                padding: 2
                visible: (root.type === "video" || root.type === "bangumi") && !root.finished
            }

            // 视频历史：已看完 / 直播历史：live 状态角标
            Rectangle {
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.rightMargin: Theme.cardBadgeSpacing
                anchors.topMargin: Theme.cardBadgeSpacing
                height: 18
                width: badgeRow.width + 10
                radius: 4
                color: root.type === "live"
                        ? (root.isLive ? "#FF4D4F" : "#9499A0")
                        : "#61666D"
                visible: ((root.type === "video" || root.type === "bangumi") && root.finished) || root.type === "live"

                Row {
                    id: badgeRow
                    anchors.centerIn: parent
                    spacing: 2

                    Rectangle {
                        width: 6
                        height: 6
                        radius: 3
                        color: "white"
                        anchors.verticalCenter: parent.verticalCenter
                        visible: root.type === "live" && root.isLive
                    }

                    FluText {
                        text: root.type === "live" ? "LIVE" : "已看完"
                        font: FluTextStyle.Caption
                        color: "white"
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }

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
                // 番剧：主标题为 seasonTitle（番剧名）；普通视频：主标题为视频 title
                text: root.isBangumi && root.seasonTitle !== "" ? root.seasonTitle : root.title
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
                id: badgeRect
                width: Theme.cardBadgeWidth
                height: Theme.cardBadgeHeight
                radius: Theme.cardBadgeRadius
                color: "transparent"
                border.color: FluTheme.fontSecondaryColor
                border.width: Theme.cardBorderWidth
                // 番剧：不再加前缀徽章（无法区分国创/番剧），直接显示集数标题
                // 普通视频：显示"UP"；直播：显示"LIVE"
                visible: (root.type === "video" && !root.isBangumi) || root.type === "live"

                FluText {
                    anchors.centerIn: parent
                    // 番剧显示"番"；普通视频显示"UP"
                    text: root.type === "bangumi" || root.isBangumi ? "番" : "UP"
                    font: FluTextStyle.Caption
                    color: FluTheme.fontSecondaryColor
                }
            }

            FluText {
                // 番剧：第二行改为集数标题（如"第4集 凡人风起天南4"）
                // 普通视频：第二行为UP主名称
                text: root.isBangumi && root.epTitle !== "" ? root.epTitle : root.author
                font: FluTextStyle.Caption
                color: FluTheme.fontSecondaryColor
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                maximumLineCount: 1
                // 徽章可见时减去徽章宽度+间距；徽章隐藏（番剧）时使用整行宽度
                width: Math.max(1, badgeRect.visible
                    ? parent.width - badgeRect.width - parent.spacing
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
            root.clicked()
        }
        onEntered: {
            if (root.width > 0 && root.height > 0)
                root.hovered = true
        }
        onExited: root.hovered = false
    }
}
