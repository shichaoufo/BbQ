import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import QtQuick.Window 2.15

import FluentUI 1.0
import BiliQt 1.0

// 用户搜索结果卡片：左侧圆形头像，右侧用户名/稿件/粉丝/签名
// 注意：不使用 layer + MultiEffect 悬浮阴影，避免与 CircleAvatar(FluClip) 形成嵌套 FBO
//       导致 GridView reuseItems 复用 delegate 时 native 崩溃 (0xc0000005)
Rectangle {
    id: root
    implicitHeight: 110

    property string mid: ""
    property string uname: ""
    property string upic: ""
    property int level: 0
    property int videos: 0
    property int fans: 0
    property int isUpuser: 0
    property int verifyType: 0  // -1=无, 0=个人认证, 1=机构认证
    property string verifyDesc: ""
    property string usign: ""

    signal clicked()

    color: root.hovered ? FluTheme.frameColor : "transparent"
    radius: 8

    property bool hovered: false

    // ====== 工具函数 ======
    // LV 等级图标（与评论区 CommentPanel 一致，使用 qrc SVG 文件）
    function levelIconSource(lv) {
        return "qrc:/BiliQt/icons/level/user-lv" + (lv || 0) + ".svg"
    }
    function formatFans(n) {
        var num = n || 0
        if (num >= 100000000) return "粉丝:" + (num / 100000000).toFixed(1) + "亿"
        if (num >= 10000) return "粉丝:" + (num / 10000).toFixed(1) + "万"
        return "粉丝:" + num
    }

    RowLayout {
        anchors.fill: parent
        spacing: 16
        anchors.leftMargin: 12
        anchors.rightMargin: 12
        anchors.topMargin: 10
        anchors.bottomMargin: 10

        // ========== 左侧：圆形头像 + 右下角认证闪电标 ==========
        Item {
            id: avatarContainer
            Layout.preferredWidth: 88
            Layout.preferredHeight: 88
            Layout.minimumWidth: 72
            Layout.minimumHeight: 72
            Layout.maximumWidth: 100
            Layout.maximumHeight: 100
            Layout.alignment: Qt.AlignTop | Qt.AlignLeft

            CircleAvatar {
                id: avatar
                anchors.fill: parent
                source: root.upic
                placeholderText: root.uname ? root.uname.charAt(0) : ""
            }

            // 认证闪电标：verify0.svg=黄(个人认证 type=0), verify1.svg=蓝(机构认证 type=1)
            // 叠加在头像右下角，与 biliuwp-lite 布局一致
            Image {
                id: verifyIcon
                width: avatarContainer.width * 0.36
                height: width
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.rightMargin: -width * 0.12
                anchors.bottomMargin: -height * 0.12
                source: root.verifyType === 0 ? "qrc:/BiliQt/icons/level/verify0.svg"
                      : root.verifyType === 1 ? "qrc:/BiliQt/icons/level/verify1.svg"
                      : ""
                visible: root.verifyType === 0 || root.verifyType === 1
                fillMode: Image.PreserveAspectFit
                sourceSize: Qt.size(64, 64)
                asynchronous: true
                z: 1
            }
        }

        // ========== 右侧：用户信息（向上对齐）==========
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 6
            Layout.alignment: Qt.AlignTop | Qt.AlignLeft

            // 第一行：用户名 + UP主徽章 + LV等级图标
            // 认证闪电标已移至头像右下角，此处不再重复显示
            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                FluText {
                    id: unameText
                    text: root.uname || "用户"
                    font: FluTextStyle.BodyStrong
                    color: FluTheme.fontPrimaryColor
                    elide: Text.ElideRight
                    maximumLineCount: 1
                    Layout.fillWidth: false
                    Layout.maximumWidth: root.width * 0.5
                    verticalAlignment: Text.AlignVCenter
                }

                // UP主徽章（与评论区一致，使用 user-up.svg）
                Image {
                    source: "qrc:/BiliQt/icons/level/user-up.svg"
                    Layout.preferredWidth: 32
                    Layout.preferredHeight: 16
                    sourceSize: Qt.size(32 * Screen.devicePixelRatio, 16 * Screen.devicePixelRatio)
                    fillMode: Image.PreserveAspectFit
                    visible: root.isUpuser === 1
                    asynchronous: true
                }

                Item { Layout.fillWidth: true }

                // LV 等级图标（与评论区一致，使用 user-lvN.svg）
                Image {
                    source: root.levelIconSource(root.level)
                    Layout.preferredWidth: 32
                    Layout.preferredHeight: 16
                    sourceSize: Qt.size(32 * Screen.devicePixelRatio, 16 * Screen.devicePixelRatio)
                    fillMode: Image.PreserveAspectFit
                    visible: root.level > 0
                    asynchronous: true
                }
            }

            // 第二行：稿件数 + 粉丝数
            RowLayout {
                Layout.fillWidth: true
                spacing: 16

                FluText {
                    text: "稿件:" + root.videos
                    font: FluTextStyle.Caption
                    color: FluTheme.fontSecondaryColor
                    Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
                }

                FluText {
                    text: root.formatFans(root.fans)
                    font: FluTextStyle.Caption
                    color: FluTheme.fontSecondaryColor
                    Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
                }
            }

            // 第三行：个性签名 / 认证描述
            FluText {
                Layout.fillWidth: true
                Layout.fillHeight: true
                text: (root.verifyDesc && root.verifyDesc !== "") ? root.verifyDesc : (root.usign || "")
                font: FluTextStyle.Caption
                color: FluTheme.fontTertiaryColor
                elide: Text.ElideRight
                maximumLineCount: 2
                wrapMode: Text.Wrap
                verticalAlignment: Text.AlignTop
                visible: ((root.verifyDesc && root.verifyDesc !== "") || (root.usign && root.usign !== ""))
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        onClicked: {
            root.clicked()
        }
        onEntered: root.hovered = true
        onExited: root.hovered = false
    }
}
