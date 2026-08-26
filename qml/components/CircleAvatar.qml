import QtQuick
import QtQuick.Controls
import QtQuick.Window
import FluentUI
import BiliQt 1.0

FluClip {
    id: root
    property string source: ""
    property string placeholderText: ""

    radius: [width/2, width/2, width/2, width/2]
    color: FluTheme.frameColor

    Image {
        id: avatarImage
        anchors.fill: parent
        source: GlobalState.fixAvatarUrl(root.source,
                                         root.width * Screen.devicePixelRatio)
        fillMode: Image.PreserveAspectCrop
        visible: root.source !== "" && status !== Image.Error
        asynchronous: true
        cache: false
        smooth: true
        mipmap: true
        antialiasing: true
    }

    FluText {
        anchors.centerIn: parent
        text: root.placeholderText
        font: FluTextStyle.Caption
        color: FluTheme.fontSecondaryColor
        visible: (root.source === "" || avatarImage.status === Image.Error) && root.placeholderText !== ""
    }
}
