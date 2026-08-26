import QtQuick
import QtQuick.Layouts
import FluentUI 1.0

Text {
    id: root
    property string name: ""
    property color iconColor: FluTheme.fontPrimaryColor

    // 使用字体族名直接引用，依赖 main.qml 中预加载的 iconParkFontLoader
    font.family: "IconPark"
    font.pixelSize: 20
    color: root.iconColor
    text: iconMap.map[root.name] || ""
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    renderType: Text.NativeRendering

    QtObject {
        id: iconMap
        property var map: (({
        "bell": "\ue800",
        "close": "\ue801",
        "coin": "\ue802",
        "comment": "\ue803",
        "fire": "\ue804",
        "fullscreen": "\ue806",
        "fullscreen-exit": "\ue805",
        "history": "\ue807",
        "home": "\ue808",
        "like": "\ue809",
        "live": "\ue80a",
        "loading": "\ue80b",
        "message": "\ue80c",
        "money": "\ue80d",
        "more": "\ue80e",
        "pause": "\ue80f",
        "play": "\ue810",
        "refresh": "\ue811",
        "search": "\ue812",
        "send": "\ue813",
        "settings": "\ue814",
        "share": "\ue815",
        "star": "\ue817",
        "star-filled": "\ue816",
        "subtitles": "\ue818",
        "thumb-down": "\ue819",
        "thumb-up": "\ue81a",
        "unlike": "\ue81b",
        "user": "\ue81c",
        "video": "\ue81d",
        "volume": "\ue821",
        "volume-mute": "\ue81e",
        "volume-notice": "\ue81f",
        "volume-small": "\ue820"
        }))
    }
}
