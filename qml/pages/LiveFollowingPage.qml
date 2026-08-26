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

    property bool _loginWarnShown: false

    FluInfoBar {
        id: infoBar
        root: root
    }

    onLiveModelChanged: {
        root.tryLoadInitial()
    }

    property bool loading: false
    property bool hasMore: true
    property int currentPage: 0
    property bool _scrollRestored: false
    property bool _pageInitialized: false
    property real _lastContentY: 0
    property bool _sizeValid: root.width > 0 && root.height > 0

    // 延迟一帧再把模型绑定到 GridView，避免 tab 切换瞬间同步创建大量 delegate
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
        _lastContentY = Math.max(0, root.initialContentY > 0 ? root.initialContentY : GlobalState.liveFollowingScrollY)
        _pageInitialized = true
        bindDelayTimer.start()
        tryLoadInitial()
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
        GlobalState.liveFollowingScrollY = y
        if (gridView.contentHeight > 0) GlobalState.liveFollowingContentHeight = gridView.contentHeight
    }

    onVisibleChanged: {
        if (visible) {
            root._scrollRestored = false
            restoreCheckTimer._attempts = 0
            root.restoreScroll()
            restoreCheckTimer.start()
            root.tryLoadInitial()
        } else if (root._pageInitialized) {
            root._loginWarnShown = false
            var y = gridView.contentY
            if (y === 0 && root._lastContentY > 0) y = root._lastContentY
            root._lastContentY = y
            GlobalState.liveFollowingScrollY = y
            if (gridView.contentHeight > 0) GlobalState.liveFollowingContentHeight = gridView.contentHeight
        }
    }

    function restoreScroll() {
        if (!root._sizeValid || gridView.height <= 0 || root._scrollRestored) return
        var savedY = root._lastContentY
        var savedH = GlobalState.liveFollowingContentHeight
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
        }
    }

    function refresh() {
        if (liveModel === null) return
        loading = false
        liveModel.clear()
        currentPage = 0
        hasMore = true
        GlobalState.liveFollowingScrollY = 0
        GlobalState.liveFollowingContentHeight = 0
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
        Api.getFollowingLive()
    }

    function formatViewers(num) {
        var n = parseInt(num, 10) || 0
        if (n >= 10000) return (n / 10000).toFixed(1) + "万"
        return String(n)
    }

    function appendFollowingData(data) {
        try {
            var dataStr = typeof data === "string" ? data : data.toString()
            var resp = JSON.parse(dataStr)
            if (resp.code !== 0 || !resp.data) {
                console.warn("[LiveFollowingPage] following API error, code:", resp.code, "msg:", resp.message)
                var msg = resp.message || ""
                if (resp.code === -101 || msg.indexOf("未登录") >= 0 || msg.indexOf("账号未登录") >= 0) {
                    if (!root._loginWarnShown) {
                        root._loginWarnShown = true
                        infoBar.showWarning("请先登录")
                    }
                }
                loading = false
                hasMore = false
                return
            }
            var list = resp.data.list || []
            var added = 0
            for (var i = 0; i < list.length; i++) {
                var item = list[i]
                // 参考原项目 BiliQt_cmake_ela：只显示正在直播的（live_status === 1）
                var liveStatus = item.live_status
                if (liveStatus !== 1) continue
                var roomId = item.roomid || item.room_id || item.id || ""
                var title = item.title || ""
                if (!roomId || roomId === "" || title === "") continue
                // 关注接口字段：room_cover（封面）、area_name_v2（分区）、text_small（观看人数文本）
                var cover = item.room_cover || item.cover || ""
                var uname = item.uname || item.name || ""
                var areaName = item.area_name_v2 || item.area_name || ""
                // 关注接口用 text_small 表示观看人数文本（如"1.2万"），直接使用
                var watchedText = item.text_small || ""
                var viewers = watchedText !== "" ? watchedText : root.formatViewers(item.online || 0)
                liveModel.append({
                    roomId: String(roomId),
                    title: title,
                    cover: cover,
                    streamer: uname,
                    viewers: viewers,
                    category: areaName,
                    badgeText: "已关注"
                })
                added++
            }
            hasMore = false
        } catch (e) {
            console.warn("[LiveFollowingPage] parse following data failed:", e)
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
        cacheBuffer: 0
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
        function onFollowingLiveReceived(data) {
            // 注意：不检查 root.visible，因为 model 是全局共享的 GlobalState.liveFollowingModel
            // 即使页面不可见，数据也应该被处理并添加到 model 中，这样切换到关注tab时就能立即显示
            if (root.liveModel === null) {
                root.loading = false
                return
            }
            root.appendFollowingData(data)
        }
        function onErrorOccurred(error) {
            console.warn("[LiveFollowingPage] API error:", error)
            root.loading = false
            root.hasMore = false
        }
    }
}
