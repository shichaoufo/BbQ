import QtQuick 2.15
import FluentUI 1.0

// 评论区粉丝勋章（胶囊形）。
//
// B 站评论接口的 member.fans_detail 只下发"颜色 + 名字 + 等级"，没有任何
// 图片资源（guard_icon / honor_icon 实测恒为空），官方网页端与 APP 同样是
// 前端用圆角块画出来的。所以这里按同样的规则复刻：
//
//   · 形状：高度固定 16（与等级标同高），radius 取 height/2 → 胶囊
//   · 背景色 = medal_color，名字色 = medal_color_name，
//     等级数字色 = medal_color_level（通常比名字亮）
//
// 不做"未点亮变灰"：接口虽有 is_receive 字段，但实测佩戴中的勋章也下发 0，
// 语义不明确，贸然灰化会把正常勋章全部打成灰的。
//
// 三个颜色都由 CommentManager 的 argbToCss() 转成 "#AARRGGBB"，
// 空值走兜底色，避免 QML 侧再做位运算。
Rectangle {
    id: control

    property string medalName: ""
    property int medalLevel: 0
    property string bgColorHex: ""
    property string nameColorHex: ""
    property string levelColorHex: ""

    // 勋章名过长时截断。官方勋章名最多 8 个汉字，但仍留一道保险，
    // 防止长名字把用户名挤没（用户名本身已经是 Flexible）
    readonly property int maxNameWidth: 56

    implicitWidth: row.implicitWidth + 12
    implicitHeight: 16
    radius: height / 2
    color: bgColorHex !== "" ? bgColorHex : "#8A8A8A"

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 2

        FluText {
            text: control.medalName
            textColor: control.nameColorHex !== "" ? control.nameColorHex : "#FFFFFF"
            font.pixelSize: 10
            elide: Text.ElideRight
            width: Math.min(implicitWidth, control.maxNameWidth)
            anchors.verticalCenter: parent.verticalCenter
        }

        FluText {
            text: String(control.medalLevel)
            textColor: control.levelColorHex !== ""
                       ? control.levelColorHex
                       : (control.nameColorHex !== "" ? control.nameColorHex : "#FFFFFF")
            font.pixelSize: 10
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
        }
    }
}
