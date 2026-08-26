import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import FluentUI

Rectangle {
    id: control

    property int itemCount: 0
    property int pageSize: 10
    property int pageCurrent: 1
    property int pageCount: Math.max(1, Math.ceil(itemCount / pageSize))
    property bool useTotalPages: false
    property int totalPages: 1
    property bool hasNextPage: true

    signal requestPage(int page)

    height: 40
    color: "transparent"

    RowLayout {
        anchors.centerIn: parent
        spacing: 8

        FluButton {
            text: qsTr("首页")
            enabled: control.pageCurrent > 1
            onClicked: {
                if (control.pageCurrent > 1) {
                    control.requestPage(1)
                }
            }
        }

        FluText {
            text: String(control.pageCurrent)
            Layout.minimumWidth: 40
            horizontalAlignment: Text.AlignHCenter
        }

        FluButton {
            text: qsTr("下一页")
            enabled: {
                if (!control.hasNextPage)
                    return false
                if (control.useTotalPages)
                    return control.pageCurrent < control.totalPages
                return true
            }
            onClicked: {
                control.requestPage(control.pageCurrent + 1)
            }
        }
    }
}
