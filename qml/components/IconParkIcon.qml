import QtQuick
import QtQuick.Effects
import FluentUI 1.0

Item {
    id: root
    property string name: ""
    property color iconColor: FluTheme.fontPrimaryColor

    implicitWidth: 18
    implicitHeight: 18

    Image {
        id: img
        anchors.fill: parent
        source: root.name ? "qrc:/BiliQt/qml/assets/icons/iconpark/" + root.name + ".svg" : ""
        sourceSize: Qt.size(Math.max(root.width, 18), Math.max(root.height, 18))
        fillMode: Image.PreserveAspectFit
        asynchronous: false
        visible: false

        onStatusChanged: {
            if (status === Image.Error) {
                console.warn("IconParkIcon failed to load:", root.name, "source:", source)
            } else if (status === Image.Ready) {
            }
        }
    }

    MultiEffect {
        anchors.fill: parent
        source: img
        colorization: 1.0
        colorizationColor: root.iconColor
    }
}
