import QtQuick 2.15
import QtQuick.Controls 2.15

import FluentUI 1.0
import BiliQt 1.0

// ===== 搜索结果牌（类型 search）=====
//
// 窗口级唯一实例。"搜索结果页"以前是 SearchOverlay 里的两层物理实例
// （layer1/layer2）：因为第一层压着视频时，新的搜索不能刷新第一层（会被
// 视频盖住），又不能关掉视频（关掉搜索页要回到视频）。本质原因就是
// 搜索牌和视频牌不在同一个叠放体系里。
//
// 现在两者都在牌堆里：再次搜索 = 把 search 牌抽到最上面 + 就地换内容，
// 视频牌/用户牌原封不动留在下面，右键关掉搜索牌自然回到它们上面。
Item {
    id: card
    anchors.fill: parent
    z: 102

    opacity: 0
    visible: opacity > 0 || openAnim.running || closeAnim.running

    property string keyword: ""
    property bool opened: false
    // 逻辑状态：不受 visible 影响，用于 Loader active 守卫
    //（切导航页/父级隐藏时不能把实例销毁，否则要重新加载并重发搜索）
    property bool _created: false
    // 首屏搜索延迟：结果页首屏建瀑布流 + 灌模型的开销若和弹出动画抢帧，
    // 动画尾段会掉帧成慢动作；错开后再搜，同样的 250ms 就能跑满帧。
    property int initialSearchDelay: 250

    // 结果页自带 FluFrame 的 5px 外边距，边角会透出底下的牌，垫一层不透明底色
    Rectangle {
        anchors.fill: parent
        color: FluTheme.dark ? "#202020" : "#F3F3F3"
    }

    Item {
        id: container
        anchors.fill: parent
        transform: Translate { id: translate; y: 0 }

        Loader {
            id: loader
            anchors.fill: parent
            active: (card.visible || card.opened) && card._created
            sourceComponent: resultComponent
        }
    }

    Component {
        id: resultComponent
        SearchResultPage {
            anchors.fill: parent
            initialKeyword: card.keyword
            initialSearchDelay: card.initialSearchDelay
        }
    }

    // 右键任意位置退出。子页面（视频/用户主页）现在是**牌堆里更上面的牌**，
    // 不在本牌内部，所以只需要在"本牌就是栈顶"时接收右键。
    MouseArea {
        anchors.fill: parent
        z: 100
        enabled: card.opened && GlobalState.topCard === "search"
        acceptedButtons: Qt.RightButton
        onPressed: function(mouse) {
            if (mouse.button !== Qt.RightButton) return
            card.close()
            mouse.accepted = true
        }
    }

    Timer {
        id: destroyTimer
        interval: 250
        repeat: false
        onTriggered: {
            if (!card.opened && !openAnim.running && !closeAnim.running) {
                card._created = false
                // 退出动画结束后把结果一起清掉：结果是 GlobalState 里的全局
                // ListModel，不清的话下次搜索会先渲染上一轮的行再被顶掉（"闪一下"）
                GlobalState.searchResultModel.clear()
                GlobalState.searchHasSearched = false
                GlobalState.searchKeyword = ""
            }
        }
    }

    // ===== 对外 API =====
    function open(kw) {
        var k = String(kw || "").trim()
        if (k === "") return
        // 抽牌之前先记下它原来是不是被别的牌压着（压着 = 这次是"从下面抽上来"，
        // 要补一个叠上去的入库动画；本来就在最上面 = 只换关键词，不动画）
        var wasCovered = GlobalState.topCard !== "search"
        var zz = GlobalState.bringCardToFront("search")
        card.z = zz
        destroyTimer.stop()
        closeAnim.stop()

        // 已经开着（可能正压着视频牌）：**同一张牌换内容**，不碰别的牌。
        // 视频/用户牌留在下面，右键关掉本牌就回到它们上面。
        if (card._created && loader.item) {
            card.keyword = k
            // prepareForNewSearch 内部已经把上一轮结果清空并置为加载态，
            // 所以无论是否播动画，牌面上都不会残留上一次的搜索内容。
            loader.item.prepareForNewSearch(k)
            if (wasCovered) {
                // 与视频牌同一套语言：从下面抽上来的牌要"叠上去"，播一次弹出动画。
                // 请求仍由 openAnim.onStopped → triggerInitialSearch 发出（错开首帧
                // 建模开销），动画期间显示的是刚清空的加载态。
                openAnim.stop()
                openAnim.start()
                card.opacity = 0
            } else {
                // 本来就在最上面：原地换关键词，直接发请求（没有动画可等）
                loader.item.triggerInitialSearch()
            }
            return
        }

        // 打开新搜索前清空上一轮残留结果，避免先看到旧结果再被顶掉
        GlobalState.searchResultModel.clear()
        GlobalState.searchHasSearched = false
        card.keyword = k
        card._created = true
        card.opened = true
        openAnim.start()
    }

    function close() {
        GlobalState.removeCard("search")
        if (!card.opened) return
        card.opened = false
        openAnim.stop()
        closeAnim.stop()
        destroyTimer.start()
        closeAnim.start()
    }

    ParallelAnimation {
        id: openAnim
        NumberAnimation {
            target: card
            property: "opacity"
            from: 0; to: 1; duration: 250
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: translate
            property: "y"
            from: card.height * 0.15; to: 0
            duration: 250
            easing.type: Easing.OutCubic
        }
        onStopped: {
            if (loader.item) loader.item.triggerInitialSearch()
        }
    }

    ParallelAnimation {
        id: closeAnim
        NumberAnimation {
            target: card
            property: "opacity"
            from: 1; to: 0; duration: 200
            easing.type: Easing.InCubic
        }
        NumberAnimation {
            target: translate
            property: "y"
            from: 0; to: card.height * 0.15
            duration: 200
            easing.type: Easing.InCubic
        }
    }
}
