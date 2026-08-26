import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

import FluentUI 1.0
import BiliQt 1.0
import ".."

Rectangle {
    id: root
    width: Theme.navWidth
    color: Theme.surface
    border.color: Theme.border
    border.width: 0.5

    property int currentIndex: 0
    signal navItemClicked(int index)

    ColumnLayout {
        anchors.fill: parent
        anchors.topMargin: Theme.spacingLarge
        anchors.bottomMargin: Theme.spacingLarge
        spacing: Theme.spacingTiny

        Rectangle {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: 40
            Layout.preferredHeight: 40
            radius: Theme.radiusMedium
            color: Theme.primary + "15"

            Text {
                anchors.centerIn: parent
                text: "B"
                font: Theme.fontTitle
                color: Theme.primary
            }
        }

        Item { Layout.preferredHeight: Theme.spacingLarge }

        Repeater {
            model: [
                { icon: "🏠", label: "首页" },
                { icon: "📺", label: "直播" },
                { icon: "🔍", label: "搜索" },
                { icon: "⏱️", label: "历史" }
            ]

            Rectangle {
                id: navItem
                width: root.width - Theme.spacingMedium * 2
                height: 48
                radius: Theme.radiusMedium
                color: index === root.currentIndex ? Theme.primary + "15" : "transparent"

                MouseArea {
                    anchors.fill: parent
                    onClicked: root.navItemClicked(index)
                }

                ColumnLayout {
                    anchors.centerIn: parent
                    spacing: 2

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: modelData.icon
                        font.pixelSize: 20
                    }

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: modelData.label
                        font: Theme.fontTiny
                        color: index === root.currentIndex ? Theme.primary : Theme.textSecondary
                    }
                }
            }
        }

        Item { Layout.fillHeight: true }

        ColumnLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: Theme.spacingTiny

            CircleAvatar {
                id: avatarContainer
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: 40
                Layout.preferredHeight: 40
                source: Login.isLoggedIn ? Login.userFace : ""
                placeholderText: "👤"
            }

            FluText {
                Layout.alignment: Qt.AlignHCenter
                text: Login.isLoggedIn ? Login.userName : "未登录"
                font: Theme.fontTiny
                color: Theme.textSecondary
                elide: Text.ElideRight
                Layout.maximumWidth: root.width - Theme.spacingMedium * 2
            }
        }
    }
}
