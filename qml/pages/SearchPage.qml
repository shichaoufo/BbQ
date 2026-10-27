import QtQuick 2.15
import QtQuick.Controls 2.15

import FluentUI 1.0
import BiliQt 1.0

// 搜索页容器
//
// 结构（与 PiliPlus 一致）：
//   · 底层 = SearchLanding（搜索初始页：搜索框 / 大家都在搜 / 搜索发现 / 搜索历史）
//   · 上层 = SearchResultPage（原来的整套结果逻辑），**以 overlay 方式弹出**
//
// 弹出方式刻意对齐 App 里既有的 overlay（视频播放页 / 用户主页）：
//   淡入 + 从下往上位移 15% 高度、250ms OutCubic；
//   关闭时反向（淡出 + 向下位移），收起后延时销毁实例。
// 右键与返回按钮都走同一个 closeResult()。
FluPage {
    id: searchPage
    title: ""

    // 结果页的逻辑状态（不受父级 visible 影响，用于 Loader active 守卫）
    property bool resultVisible: false

    // ===== 底层：搜索初始页 =====
    SearchLanding {
        id: landing
        anchors.fill: parent
        // 结果页盖着时关掉联想请求，避免两个页面抢 Api 的联想信号
        suggestEnabled: !searchPage.resultVisible
        onSearchRequested: function(keyword) {
            searchPage.openResult(keyword)
        }
    }

    // ===== 上层：搜索结果页 overlay =====
    Item {
        id: resultOverlay
        anchors.fill: parent
        z: 101
        opacity: 0
        visible: opacity > 0 || openResultAnim.running || closeResultAnim.running

        property string keyword: ""
        property bool _created: false

        // 不透明底：结果页自己的 FluFrame 有 5px 外边距 + 圆角，
        // 只靠它铺不满整个 overlay，边角会透出底下的搜索初始页。
        // 这层底色同时让"淡入"过程是整块浮起，而不是内容先透出来。
        Rectangle {
            anchors.fill: parent
            color: FluTheme.dark ? "#202020" : "#F3F3F3"
        }

        Item {
            id: resultContainer
            anchors.fill: parent
            transform: Translate { id: resultTranslate; y: 0 }

            Loader {
                id: resultLoader
                anchors.fill: parent
                // 守卫：切导航页时父级 visible 变 false，不能让实例被销毁，
                // 否则切回来要重新加载并重发搜索（与 HomePage 的 userProfileLoader 同模式）
                active: (resultOverlay.visible || searchPage.resultVisible)
                        && resultOverlay._created
                sourceComponent: resultComponent
            }
        }

        // 兜底右键：关闭结果页。
        // 放在**最上层**（最后声明）：搜索结果页里没有任何右键菜单，
        // 需要的是"右键任意位置都能退出"；若放在最下层，页面里的
        // Flickable / MouseArea 会把右键先吃掉（实测点不动）。
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.RightButton
            onPressed: function(mouse) {
                if (mouse.button !== Qt.RightButton) return
                searchPage.closeResult()
                mouse.accepted = true
            }
        }

        Component {
            id: resultComponent
            SearchResultPage {
                anchors.fill: parent
                initialKeyword: resultOverlay.keyword
                // 首屏搜索等弹出动画跑完再发（见 openResultAnim.onStopped），
                // 免得建瀑布流的开销掉帧、把动画尾段拖成慢动作。
                initialSearchDelay: 200
            }
        }

        Timer {
            id: resultDestroyTimer
            interval: 250
            repeat: false
            onTriggered: {
                if (!searchPage.resultVisible && !openResultAnim.running
                        && !closeResultAnim.running) {
                    resultOverlay._created = false
                }
            }
        }

        ParallelAnimation {
            id: openResultAnim
            // 参数与视频播放页 / 用户主页的 overlay 完全一致（250ms OutCubic、位移 15%）。
            // 弹出"变慢"不是动画参数的问题，而是结果页首屏建瀑布流 + 灌模型时的
            // 掉帧 —— 那波开销原本正好落在动画窗口里。现在首屏搜索推迟到
            // onStopped 之后才发（见下方 onStopped 与 SearchResultPage.initialSearchDelay），
            // 动画期间不再有重活，同样的 250ms 就能跑满帧。
            NumberAnimation {
                target: resultOverlay
                property: "opacity"
                from: 0; to: 1; duration: 250
                easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: resultTranslate
                property: "y"
                from: resultOverlay.height * 0.15; to: 0
                duration: 250
                easing.type: Easing.OutCubic
            }
            onStopped: {
                // 动画跑完再放开首屏搜索，把建模开销挪出动画窗口
                if (resultLoader.item) resultLoader.item.triggerInitialSearch()
            }
        }

        ParallelAnimation {
            id: closeResultAnim
            NumberAnimation {
                target: resultOverlay
                property: "opacity"
                from: 1; to: 0; duration: 200
                easing.type: Easing.InCubic
            }
            NumberAnimation {
                target: resultTranslate
                property: "y"
                from: 0; to: resultOverlay.height * 0.15
                duration: 200
                easing.type: Easing.InCubic
            }
        }
    }

    function openResult(keyword) {
        var kw = String(keyword || "").trim()
        if (kw === "") return
        resultDestroyTimer.stop()
        closeResultAnim.stop()
        // 顺序很重要：先设关键词，再置 _created 让 Loader 按新关键词创建实例
        resultOverlay.keyword = kw
        resultOverlay._created = true
        searchPage.resultVisible = true
        openResultAnim.start()
    }

    function closeResult() {
        if (!searchPage.resultVisible) return
        searchPage.resultVisible = false
        openResultAnim.stop()
        closeResultAnim.stop()
        resultDestroyTimer.start()
        closeResultAnim.start()
    }
}
