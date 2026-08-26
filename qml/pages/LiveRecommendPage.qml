import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

import FluentUI 1.0
import BiliQt 1.0
import "../components"

Rectangle {
    id: root
    color: "transparent"

    property int cardWidth: Theme.cardWidth
    property int margins: Theme.pageMargins
    property int vSpacing: Theme.pageVSpacing
    property int minHSpacing: Theme.pageHSpacing
    property int pageSize: Theme.pageSize

    property int columns: Math.max(1, Math.floor((gridView.width + minHSpacing) / (cardWidth + minHSpacing)))
    property real cellWidth: columns > 1 ? gridView.width / columns : gridView.width
    property real displayCardWidth: Math.max(1, root.cellWidth - root.minHSpacing)

    property var liveModel: null
    property alias contentY: gridView.contentY
    property real initialContentY: 0

    property string currentArea: "全部"
    property string currentSubArea: "全部"
    property int currentParentAreaId: 0
    property int currentAreaId: 0

    // 监听 ID 属性变化触发刷新（实际控制 API 调用的属性）
    // 用 Timer 防抖，避免 parentId 和 areaId 两次变化导致重复请求
    onCurrentParentAreaIdChanged: {
        if (root._pageReady) areaChangeTimer.restart()
    }
    onCurrentAreaIdChanged: {
        if (root._pageReady) areaChangeTimer.restart()
    }

    Timer {
        id: areaChangeTimer
        interval: 30
        repeat: false
        onTriggered: root.refresh()
    }

    onLiveModelChanged: {
        if (liveModel && liveModel.count === 0 && !root.loading) {
            loadDelayTimer.start()
        }
    }

    Timer {
        id: loadDelayTimer
        interval: 100
        repeat: false
        onTriggered: {
            root.tryLoadInitial()
        }
    }

    property bool loading: false
    property bool hasMore: true
    property int currentPage: 0
    property bool _scrollRestored: false
    property bool _pageInitialized: false
    property bool _pageReady: false
    property real _lastContentY: 0
    property bool _sizeValid: root.width > 0 && root.height > 0

    // 延迟一帧再把模型绑定到 GridView，避免页面转场瞬间同步创建大量 delegate
    property var _displayModel: null

    signal contentYChangedExternally(real y)
    signal openLivePlayerRequested(string roomId, string title, string streamer)

    function tryLoadInitial() {
        if (root._sizeValid && root.visible && liveModel && liveModel.count === 0 && !root.loading && root.hasMore) {
            root.loadMore()
        }
    }

    onWidthChanged: tryLoadInitial()
    onHeightChanged: tryLoadInitial()

    Component.onCompleted: {
        _lastContentY = Math.max(0, root.initialContentY > 0 ? root.initialContentY : GlobalState.liveRecommendScrollY)
        _pageInitialized = true
        bindDelayTimer.start()
        tryLoadInitial()
        // 所有绑定属性稳定后再响应 area 变化，避免初始化时误触发 refresh
        root._pageReady = true
    }

    Timer {
        id: bindDelayTimer
        interval: 0
        repeat: false
        onTriggered: root._displayModel = root.liveModel
    }

    Timer {
        id: restoreCheckTimer
        interval: 50
        repeat: true
        property int _attempts: 0
        onTriggered: {
            _attempts++
            root.restoreScroll()
            if (root._scrollRestored || _attempts >= 20) stop()
        }
    }

    Component.onDestruction: {
        var y = gridView.contentY
        if (y === 0 && root._lastContentY > 0) y = root._lastContentY
        GlobalState.liveRecommendScrollY = y
        if (gridView.contentHeight > 0) GlobalState.liveRecommendContentHeight = gridView.contentHeight
    }

    onVisibleChanged: {
        if (visible) {
            root._scrollRestored = false
            restoreCheckTimer._attempts = 0
            root.restoreScroll()
            restoreCheckTimer.start()
            root.tryLoadInitial()
            // 切回时发现 area 在不可见期间变化过，需要刷新以显示正确分区数据
            if (root._areaDirty) {
                root._areaDirty = false
                root.refresh()
            }
        } else if (root._pageInitialized) {
            var y = gridView.contentY
            if (y === 0 && root._lastContentY > 0) y = root._lastContentY
            root._lastContentY = y
            GlobalState.liveRecommendScrollY = y
            if (gridView.contentHeight > 0) GlobalState.liveRecommendContentHeight = gridView.contentHeight
        }
    }

    function restoreScroll() {
        if (!root._sizeValid || gridView.height <= 0 || root._scrollRestored) return
        var savedY = root._lastContentY
        var savedH = GlobalState.liveRecommendContentHeight
        var target = savedY
        if (savedH > 0 && gridView.contentHeight > 0 && Math.abs(savedH - gridView.contentHeight) > 1) {
            target = savedY * gridView.contentHeight / savedH
        }
        if (target > 0 && gridView.contentHeight > gridView.height) {
            var maxY = Math.max(0, gridView.contentHeight - gridView.height)
            if (target > maxY) target = maxY
            gridView.contentY = target
            root._lastContentY = target
            root._scrollRestored = true
            root.contentYChangedExternally(target)
        } else if (savedY <= 0 && gridView.contentHeight > 0) {
            // 保存位置就在顶部：内容布局完成后恢复即视为完成（无需位移）。
            // 必须置位 _scrollRestored 关闭恢复逻辑，否则它会一直保持待命，
            // 之后加载更多触发 contentHeight 变化时，会拿陈旧的
            // liveRecommendContentHeight 对当前滚动位置做比例缩放，页面突然下跳
            root._scrollRestored = true
        }
    }

    function refresh() {
        if (liveModel === null) return
        loading = false
        liveModel.clear()
        currentPage = 0
        hasMore = true
        GlobalState.liveRecommendScrollY = 0
        GlobalState.liveRecommendContentHeight = 0
        gridView.positionViewAtBeginning()
        gridView.contentY = 0
        if (root._sizeValid) {
            gridView.forceLayout()
            loadMore()
        }
    }

    function loadMore() {
        if (loading || !hasMore || liveModel === null) return
        if (!root._sizeValid) return
        loading = true
        var nextPage = currentPage + 1
        if (currentParentAreaId === 0 && currentAreaId === 0) {
            Api.setLivePage(nextPage)
            Api.getLiveList()
        } else {
            Api.getSubAreaLiveList(currentParentAreaId, currentAreaId, nextPage)
        }
    }

    function formatViewers(num) {
        var n = parseInt(num, 10) || 0
        if (n >= 10000) return (n / 10000).toFixed(1) + "万"
        return String(n)
    }

    function extractLiveBadge(item) {
        if (!item) return ""
        if (item.badge) return item.badge
        if (item.is_followed === 1 || item.is_followed === true) return "已关注"
        if (item.relation_type === 1) return "已关注"
        return ""
    }

    function appendFeedData(data) {
        try {
            var dataStr = typeof data === "string" ? data : data.toString()
            var resp = JSON.parse(dataStr)
            if (resp.code !== 0 || !resp.data) {
                console.warn("[LiveRecommendPage] feedV2 API error, code:", resp.code, "msg:", resp.message)
                loading = false
                hasMore = false
                return
            }
            var cardList = resp.data.card_list || resp.data.list || []
            var added = 0
            for (var i = 0; i < cardList.length; i++) {
                var card = cardList[i]
                if (!card) continue
                var item = null
                if (card.card_type === "small_card_v1" && card.card_data) {
                    item = card.card_data.small_card_v1
                } else if (card.card_type === "large_card_v1" && card.card_data) {
                    item = card.card_data.large_card_v1
                } else if (card.roomid || card.room_id) {
                    item = card
                }
                if (!item) continue
                var roomId = item.id || item.roomid || item.room_id || ""
                var title = item.title || ""
                if (!roomId || roomId === "" || title === "") continue
                var cover = item.cover || item.system_cover || item.user_cover || ""
                var uname = item.uname || item.name || ""
                var areaName = item.area_name || item.area_v2_name || item.cate_name || ""
                var online = item.online || (item.watched_show ? item.watched_show.num : 0) || 0
                liveModel.append({
                    roomId: String(roomId),
                    title: title,
                    cover: cover,
                    streamer: uname,
                    viewers: root.formatViewers(online),
                    category: areaName,
                    badgeText: root.extractLiveBadge(item)
                })
                added++
            }
            hasMore = added > 0 && currentPage < 10
        } catch (e) {
            console.warn("[LiveRecommendPage] parse feed data failed:", e)
            loading = false
            hasMore = false
            return
        }
        finishLoad()
    }

    function appendSubAreaData(data) {
        try {
            var dataStr = typeof data === "string" ? data : data.toString()
            var resp = JSON.parse(dataStr)
            if (resp.code !== 0 || !resp.data) {
                console.warn("[LiveRecommendPage] subArea API error, code:", resp.code, "msg:", resp.message)
                loading = false
                hasMore = false
                return
            }
            // second/getList 可能返回 card_list 或 list
            var list = resp.data.list || []
            if (resp.data.card_list) {
                list = []
                var cardList = resp.data.card_list
                for (var k = 0; k < cardList.length; k++) {
                    var card = cardList[k]
                    if (!card) continue
                    if (card.card_type === "small_card_v1" && card.card_data) {
                        list.push(card.card_data.small_card_v1)
                    } else if (card.card_type === "large_card_v1" && card.card_data) {
                        list.push(card.card_data.large_card_v1)
                    } else if (card.roomid || card.room_id || card.id) {
                        list.push(card)
                    }
                }
            }
            var added = 0
            for (var i = 0; i < list.length; i++) {
                var item = list[i]
                var roomId = item.roomid || item.room_id || item.id || ""
                var title = item.title || ""
                if (!roomId || roomId === "" || title === "") continue
                var cover = item.cover || item.user_cover || item.system_cover || ""
                var uname = item.uname || item.name || ""
                var areaName = item.area_v2_name || item.area_name || ""
                var online = item.online || 0
                liveModel.append({
                    roomId: String(roomId),
                    title: title,
                    cover: cover,
                    streamer: uname,
                    viewers: root.formatViewers(online),
                    category: areaName,
                    badgeText: root.extractLiveBadge(item)
                })
                added++
            }
            hasMore = added >= 10
        } catch (e) {
            console.warn("[LiveRecommendPage] parse subArea data failed:", e)
            loading = false
            hasMore = false
            return
        }
        finishLoad()
    }

    function finishLoad() {
        currentPage++
        loading = false
        fillTimer.start()
    }

    function checkLoadMore() {
        if (root.loading || !root.hasMore || liveModel === null) return
        if (gridView.height <= 0) return
        if (gridView.contentY + gridView.height >= gridView.contentHeight - Theme.cardWidth * 2) {
            root.loadMore()
        }
    }

    Timer {
        id: fillTimer
        interval: 300
        onTriggered: {
            if (root.loading || !root.hasMore || root.liveModel === null) return
            if (!root._sizeValid || gridView.height <= 0) return
            var maxFillItems = root.pageSize * 10
            if (root.liveModel.count < maxFillItems && gridView.contentHeight <= gridView.height + 10) {
                root.loadMore()
            }
        }
    }

    GridView {
        id: gridView
        anchors.fill: parent
        anchors.leftMargin: root.margins
        anchors.rightMargin: root.margins + 20
        anchors.topMargin: root.margins
        anchors.bottomMargin: root.margins
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: FluScrollBar {}

        model: root._displayModel
        cellWidth: Math.max(1, root.cellWidth)
        cellHeight: Math.max(1, root.displayCardWidth * Theme.cardAspectRatio + Theme.cardInfoHeight + root.vSpacing)
        cacheBuffer: Math.max(0, gridView.height)
        reuseItems: true
        flow: GridView.LeftToRight
        layoutDirection: Qt.LeftToRight
        verticalLayoutDirection: GridView.TopToBottom

        delegate: Item {
            width: Math.max(1, root.cellWidth)
            height: Math.max(1, gridView.cellHeight)

            LiveCard {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(1, root.displayCardWidth - Theme.scrollBarReserve)
                roomId: model.roomId
                title: model.title
                cover: model.cover
                streamer: model.streamer
                viewers: model.viewers
                category: model.category
                badgeText: model.badgeText || ""
                onClicked: {
                    root.openLivePlayerRequested(model.roomId, model.title, model.streamer)
                }
            }
        }

        onContentYChanged: {
            if (root.visible) {
                if (contentY > 0 || root._scrollRestored) {
                    root._lastContentY = contentY
                }
                if (root._scrollRestored) {
                    root.contentYChangedExternally(contentY)
                }
            }
            root.checkLoadMore()
        }

        onMovementEnded: {
            root.checkLoadMore()
        }

        onContentHeightChanged: {
            root.restoreScroll()
        }
    }

    FluIconButton {
        id: refreshBtn
        width: 50
        height: 50
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.rightMargin: 20
        anchors.bottomMargin: 20
        iconSource: FluentIcons.Refresh
        iconSize: 20
        onClicked: {
            root.refresh()
        }
    }

    Connections {
        target: Api
        function onLiveListReceived(data) {
            if (!root.visible || root.liveModel === null) return
            root.appendFeedData(data)
        }
        function onSubAreaLiveListReceived(data) {
            if (!root.visible || root.liveModel === null) return
            root.appendSubAreaData(data)
        }
        function onErrorOccurred(error) {
            console.warn("[LiveRecommendPage] API error:", error)
            root.loading = false
            root.hasMore = false
        }
    }
}
