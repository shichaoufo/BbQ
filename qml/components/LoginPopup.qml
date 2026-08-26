import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import FluentUI
import BiliQt 1.0

FluPopup {
    id: control
    width: 320
    height: 420
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 24
        spacing: 16

        FluText {
            text: "扫码登录"
            font: FluTextStyle.Title
            Layout.alignment: Qt.AlignHCenter
        }

        Image {
            id: qrImage
            Layout.preferredWidth: 200
            Layout.preferredHeight: 200
            Layout.alignment: Qt.AlignHCenter
            source: Login.qrCodeSource
            fillMode: Image.PreserveAspectFit
            cache: false
        }

        FluText {
            text: Login.loginStatusText
            Layout.alignment: Qt.AlignHCenter
        }

        Item { Layout.fillHeight: true }

        FluButton {
            text: "刷新二维码"
            Layout.alignment: Qt.AlignHCenter
            onClicked: Login.getLoginQRCode()
        }
    }

    onOpened: Login.getLoginQRCode()

    Connections {
        target: Login
        function onUserInfoChanged() {
            if (Login.isLoggedIn) {
                control.close()
            }
        }
    }
}
