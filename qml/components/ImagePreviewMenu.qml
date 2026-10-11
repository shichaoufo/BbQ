import QtQuick 2.15
import QtQuick.Controls 2.15

import FluentUI 1.0
import BiliQt 1.0

// 图片预览层的右键菜单（复制图片 / 下载图片 / 重置缩放）。
//
// 三处预览层（评论面板 / 动态详情 / 播放页评论）版式一致，菜单只此一份：
// 各页面负责把「当前这张图的地址」和「自己的提示条」喂进来，其余都在这里。
//
// 与评论右键菜单同一套弹窗语义：modal 才能让「菜单开着时点击别处」只收菜单
// 而不把这次点击继续漏给预览层的左键兜底（否则顺手就把预览关了）；dim 必须
// 显式关掉 —— modal 会连带 dim=true，FluentUI 给模态弹窗画的是半透明全窗遮罩。
FluMenu {
    id: root

    // 当前预览图的地址（各页面用自己的取图函数喂进来，随翻页自动更新）
    property string imageUrl: ""
    // 是否已放大（决定「重置缩放」是否出现）
    property bool zoomed: false
    // 页面的 FluInfoBar，用来回报复制/下载结果（传 null 则静默）。
    // 名字不叫 infoBar：三处预览层里那个 FluInfoBar 的 id 就叫 infoBar，
    // 属性与 id 同名时绑定会写成自身引用（绑定循环），换个名断掉这条路。
    property var notifyBar: null

    // 「重置缩放」由持有 ImageViewer 的页面执行（本组件够不到那个 viewer）
    signal resetZoomRequested()

    // 一次请求只有发起它的那个菜单实例会回报结果。页面上可能同时存在多个
    // 本组件（播放页的评论预览 + 播放页自己的预览），不打标记的话一次复制
    // 会让每个实例都弹一条提示。
    property bool _pending: false

    // 在父项坐标 (px, py) 处弹出，超出右/下边界时向内收。
    function openAt(px, py) {
        var w = root.implicitWidth > 0 ? root.implicitWidth : root.width
        var h = root.implicitHeight > 0 ? root.implicitHeight : root.height
        var pw = root.parent ? root.parent.width : 0
        var ph = root.parent ? root.parent.height : 0
        root.x = Math.max(0, Math.min(px, Math.max(0, pw - w)))
        root.y = Math.max(0, Math.min(py, Math.max(0, ph - h)))
        root.open()
    }

    function _report(text, isWarning) {
        if (!root._pending)
            return
        root._pending = false
        if (!root.notifyBar)
            return
        if (isWarning)
            root.notifyBar.showWarning(text, 4000)
        else
            root.notifyBar.showSuccess(text, 4000)
    }

    modal: true
    dim: false

    FluMenuItem {
        text: "复制图片"
        enabled: root.imageUrl !== ""
        onTriggered: {
            root._pending = true
            ImageActions.copyImage(root.imageUrl)
        }
    }

    FluMenuItem {
        text: "下载图片"
        enabled: root.imageUrl !== ""
        onTriggered: {
            root._pending = true
            ImageActions.saveImage(root.imageUrl)
        }
    }

    FluMenuItem {
        text: "重置缩放"
        visible: root.zoomed
        onTriggered: root.resetZoomRequested()
    }

    Connections {
        target: ImageActions
        function onImageCopied(message) {
            root._report(message, false)
        }
        function onImageCopyFailed(error) {
            root._report(error, true)
        }
        function onImageSaved(path) {
            root._report("已保存到 " + path, false)
        }
        function onImageSaveFailed(error) {
            root._report(error, true)
        }
    }
}
