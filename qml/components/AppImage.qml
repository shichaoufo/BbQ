import QtQuick 2.15
import FluentUI 1.0

// 图片加载失败时 FluImage 会盖一层 "Reload" 按钮，但项目里点它一直没有反应。
// 根因在 FluentUI 自带的默认实现：
//
//     property var clickErrorListener : function(){
//         image.source = ""
//         image.source = control.source
//     }
//
// 这里引用的 id `image` 在 FluImage 内部并不存在（内部只有 control / com_error /
// com_loading），一旦点击就抛 ReferenceError，表现就是"按钮能点，但毫无反应"。
//
// 本项目统一用 AppImage 代替 FluImage：继承它并给出可用的重试实现。
// 把 source 清空再赋回，Qt 才会丢掉失败状态重新发起请求（URL 不变时直接重设
// source 不会触发重新加载）。
FluImage {
    clickErrorListener: function() {
        var s = source
        source = ""
        source = s
    }
}
