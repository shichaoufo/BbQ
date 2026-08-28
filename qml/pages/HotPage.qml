import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

import FluentUI 1.0
import BiliQt 1.0
import "../components"

Rectangle {
    id: root
    color: "transparent"

    property string currentCategory: GlobalState.hotCurrentCategory

    function categoryIndex(cat) {
        switch (cat) {
        case "all": return 0
        case "rank": return 1
        case "weekly": return 2
        case "history": return 3
        }
        return 0
    }

    StackLayout {
        id: stack
        anchors.fill: parent
        currentIndex: root.categoryIndex(root.currentCategory)

        Loader {
            property bool _wasLoaded: false
            active: stack.currentIndex === 0 || _wasLoaded
            asynchronous: true
            sourceComponent: hotCategoryViewComponent
            onLoaded: {
                item.category = "all"
                item._lastContentY = item.savedScrollY
                item.restoreScroll()
                item.ensureLoaded()
            }
            onActiveChanged: if (active) _wasLoaded = true
        }
        Loader {
            property bool _wasLoaded: false
            active: stack.currentIndex === 1 || _wasLoaded
            asynchronous: true
            sourceComponent: hotCategoryViewComponent
            onLoaded: {
                item.category = "rank"
                item._lastContentY = item.savedScrollY
                item.restoreScroll()
                item.ensureLoaded()
            }
            onActiveChanged: if (active) _wasLoaded = true
        }
        Loader {
            property bool _wasLoaded: false
            active: stack.currentIndex === 2 || _wasLoaded
            asynchronous: true
            sourceComponent: hotCategoryViewComponent
            onLoaded: {
                item.category = "weekly"
                item._lastContentY = item.savedScrollY
                item.restoreScroll()
                item.ensureLoaded()
            }
            onActiveChanged: if (active) _wasLoaded = true
        }
        Loader {
            property bool _wasLoaded: false
            active: stack.currentIndex === 3 || _wasLoaded
            asynchronous: true
            sourceComponent: hotCategoryViewComponent
            onLoaded: {
                item.category = "history"
                item._lastContentY = item.savedScrollY
                item.restoreScroll()
                item.ensureLoaded()
            }
            onActiveChanged: if (active) _wasLoaded = true
        }
    }

    Component {
        id: hotCategoryViewComponent
        Rectangle {
            id: catView
            color: "transparent"
            property string category

            property int cardWidth: Theme.cardWidth
            property int margins: Theme.pageMargins
            property int vSpacing: Theme.pageVSpacing
            property int minHSpacing: Theme.pageHSpacing
            property int pageSize: Theme.pageSize

            property int columns: Math.max(1, Math.floor((gridView.width + minHSpacing) / (cardWidth + minHSpacing)))
            property real cellWidth: columns > 1 ? gridView.width / columns : gridView.width
            property real displayCardWidth: Math.max(1, catView.cellWidth - catView.minHSpacing)

            property var videoModel: {
                switch (catView.category) {
                case "all": return GlobalState.hotsAllModel
                case "rank": return GlobalState.hotsRankModel
                case "weekly": return GlobalState.hotsWeeklyModel
                case "history": return GlobalState.hotsHistoryModel
                }
                return null
            }
            property real savedScrollY: {
                switch (catView.category) {
                case "all": return GlobalState.hotsAllScrollY
                case "rank": return GlobalState.hotsRankScrollY
                case "weekly": return GlobalState.hotsWeeklyScrollY
                case "history": return GlobalState.hotsHistoryScrollY
                }
                return 0
            }

            property bool loading: false
            property bool _scrollRestored: false
            property bool _pageInitialized: false
            property real _lastContentY: 0
            property bool _sizeValid: catView.width > 0 && catView.height > 0

            Component.onCompleted: {
                _lastContentY = catView.savedScrollY
                _pageInitialized = true
                catView.ensureLoaded()
            }

            onWidthChanged: catView.ensureLoaded()
            onHeightChanged: catView.ensureLoaded()

            Component.onDestruction: {
                catView.saveScroll()
            }

            onVisibleChanged: {
                if (catView.visible) {
                    _scrollRestored = false
                    _lastContentY = catView.savedScrollY
                    catView.restoreScroll()
                    catView.ensureLoaded()
                } else {
                    catView.saveScroll()
                }
            }

            function saveScroll() {
                switch (catView.category) {
                case "all": GlobalState.hotsAllScrollY = _lastContentY; break
                case "rank": GlobalState.hotsRankScrollY = _lastContentY; break
                case "weekly": GlobalState.hotsWeeklyScrollY = _lastContentY; break
                case "history": GlobalState.hotsHistoryScrollY = _lastContentY; break
                }
            }

            function restoreScroll() {
                if (!catView._sizeValid || gridView.height <= 0 || _scrollRestored) return
                if (_lastContentY > 0 && gridView.contentHeight > gridView.height) {
                    var target = _lastContentY
                    var maxY = Math.max(0, gridView.contentHeight - gridView.height)
                    if (target > maxY) target = maxY
                    gridView.contentY = target
                    _scrollRestored = true
                }
            }

            function ensureLoaded() {
                if (!catView._sizeValid) return
                if (catView.videoModel && catView.videoModel.count === 0 && !catView.loading) {
                    catView.loadMore()
                }
            }

            function refresh() {
                if (catView.videoModel === null || catView.loading) return
                catView.videoModel.clear()
                catView.loading = false
                catView.setHasMore(true)
                catView.setPage(0)
                catView.setScrollY(0)
                gridView.positionViewAtBeginning()
                gridView.contentY = 0
                if (catView._sizeValid) {
                    gridView.forceLayout()
                    catView.loadMore()
                }
            }

            function page() {
                switch (catView.category) {
                case "all": return GlobalState.hotsAllPage
                case "rank": return GlobalState.hotsRankPage
                case "weekly": return GlobalState.hotsWeeklyNumber
                }
                return 0
            }

            function setPage(p) {
                switch (catView.category) {
                case "all": GlobalState.hotsAllPage = p; break
                case "rank": GlobalState.hotsRankPage = p; break
                case "weekly": GlobalState.hotsWeeklyNumber = p; break
                }
            }

            function hasMore() {
                switch (catView.category) {
                case "all": return GlobalState.hotsAllHasMore
                case "rank": return GlobalState.hotsRankHasMore
                case "weekly": return GlobalState.hotsWeeklyHasMore
                case "history": return GlobalState.hotsHistoryHasMore
                }
                return false
            }

            function setHasMore(v) {
                switch (catView.category) {
                case "all": GlobalState.hotsAllHasMore = v; break
                case "rank": GlobalState.hotsRankHasMore = v; break
                case "weekly": GlobalState.hotsWeeklyHasMore = v; break
                case "history": GlobalState.hotsHistoryHasMore = v; break
                }
            }

            function loadMore() {
                if (catView.loading || !catView.hasMore() || catView.videoModel === null) return
                if (!catView._sizeValid) return
                catView.loading = true

                switch (catView.category) {
                case "all":
                    Api.getHotsAll(catView.page() + 1, catView.pageSize)
                    break
                case "rank":
                    Api.getHotsRank(GlobalState.hotsRankRid, "all")
                    break
                case "weekly":
                    if (GlobalState.hotsWeeklyList.length === 0) {
                        Api.getHotsWeeklyList()
                    } else {
                        var number = catView.page() > 0 ? catView.page() : GlobalState.hotsWeeklyList[0].number
                        Api.getHotsWeekly(number)
                    }
                    break
                case "history":
                    Api.getHotsHistory()
                    break
                }
            }

            function finishLoad() {
                if (catView.category === "all") {
                    catView.setPage(catView.page() + 1)
                }
                catView.loading = false
                fillTimer.start()
            }

            function checkLoadMore() {
                if (!catView.visible || catView.loading || !catView.hasMore() || catView.videoModel === null) return
                if (gridView.height <= 0) return
                if (gridView.contentY + gridView.height >= gridView.contentHeight - Theme.cardWidth * 2) {
                    catView.loadMore()
                }
            }

            Timer {
                id: fillTimer
                interval: 50
                onTriggered: {
                    if (!catView.visible || catView.loading || !catView.hasMore() || catView.videoModel === null) return
                    if (!catView._sizeValid || gridView.height <= 0) return
                    var maxFillItems = catView.pageSize * 10
                    if (catView.videoModel.count < maxFillItems && gridView.contentHeight <= gridView.height + 10) {
                        catView.loadMore()
                    }
                }
            }

            function pad2(n) {
                return n < 10 ? "0" + n : String(n)
            }

            function formatDuration(seconds) {
                var s = parseInt(seconds, 10) || 0
                var h = Math.floor(s / 3600)
                var m = Math.floor((s % 3600) / 60)
                var sec = s % 60
                if (h > 0) {
                    return pad2(h) + ":" + pad2(m) + ":" + pad2(sec)
                }
                return pad2(m) + ":" + pad2(sec)
            }

            function extractBadge(item) {
                if (!item) return ""
                if (catView.category === "history") {
                    return item.achievement || ""
                }
                if (item.rcmd_reason) {
                    if (typeof item.rcmd_reason === "string") {
                        return item.rcmd_reason
                    } else if (item.rcmd_reason.content) {
                        return item.rcmd_reason.content
                    }
                }
                return ""
            }

            function appendVideoItem(item) {
                if (!item.bvid || item.bvid === "" || !item.title || item.title === "") return
                catView.videoModel.append({
                    bvid: item.bvid,
                    title: item.title,
                    cover: item.pic,
                    author: item.owner && item.owner.name ? item.owner.name : "",
                    views: GlobalState.formatNumber(item.stat && item.stat.view ? item.stat.view : 0),
                    danmakus: GlobalState.formatNumber(item.stat && item.stat.danmaku ? item.stat.danmaku : 0),
                    duration: catView.formatDuration(item.duration || 0),
                    pubDate: GlobalState.formatVideoCardTime(item.pubdate || 0),
                    badgeText: catView.extractBadge(item)
                })
            }

            function appendApiData(jsonText) {
                try {
                    var resp = JSON.parse(jsonText)
                    if (resp.code !== 0 || !resp.data) {
                        catView.loading = false
                        return
                    }
                    var items = resp.data.list || []
                    for (var i = 0; i < items.length; i++) {
                        catView.appendVideoItem(items[i])
                    }

                    if (catView.category === "all") {
                        catView.setHasMore(!resp.data.no_more)
                    } else {
                        catView.setHasMore(false)
                    }
                } catch (e) {
                    console.warn("[HotPage] parse API data failed:", e)
                    catView.loading = false
                    return
                }
                catView.finishLoad()
            }

            function appendWeeklyListData(jsonText) {
                try {
                    var resp = JSON.parse(jsonText)
                    if (resp.code !== 0 || !resp.data) return
                    var list = resp.data.list || []
                    GlobalState.hotsWeeklyList = list
                    if (list.length > 0) {
                        var targetNumber = list[0].number
                        for (var i = 0; i < list.length; i++) {
                            if (list[i].status === 1) {
                                targetNumber = list[i].number
                                break
                            }
                        }
                        if (GlobalState.hotsWeeklyNumber === 0 || GlobalState.hotsWeeklyNumber !== targetNumber) {
                            GlobalState.hotsWeeklyNumber = targetNumber
                            catView.setPage(targetNumber)
                        }
                        Api.getHotsWeekly(targetNumber)
                    } else {
                        catView.loading = false
                    }
                } catch (e) {
                    console.warn("[HotPage] parse weekly list failed:", e)
                    catView.loading = false
                }
            }

            function setScrollY(y) {
                switch (catView.category) {
                case "all": GlobalState.hotsAllScrollY = y; break
                case "rank": GlobalState.hotsRankScrollY = y; break
                case "weekly": GlobalState.hotsWeeklyScrollY = y; break
                case "history": GlobalState.hotsHistoryScrollY = y; break
                }
            }

            GridView {
                id: gridView
                anchors.fill: parent
                anchors.leftMargin: catView.margins
                anchors.rightMargin: catView.margins + 20
                anchors.topMargin: catView.margins
                anchors.bottomMargin: catView.margins
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: FluScrollBar {}
                reuseItems: true

                model: catView.videoModel
                cellWidth: Math.max(1, catView.cellWidth)
                cellHeight: Math.max(1, catView.displayCardWidth * Theme.cardAspectRatio + Theme.cardInfoHeight + catView.vSpacing)
                cacheBuffer: Math.max(0, gridView.height)
                flow: GridView.LeftToRight
                layoutDirection: Qt.LeftToRight
                verticalLayoutDirection: GridView.TopToBottom

                delegate: Item {
                    width: Math.max(1, catView.cellWidth)
                    height: Math.max(1, gridView.cellHeight)

                    VideoCard {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.max(1, catView.displayCardWidth - Theme.scrollBarReserve)
                        bvid: model.bvid
                        title: model.title
                        cover: model.cover
                        author: model.author
                        views: model.views
                        danmakus: model.danmakus
                        duration: model.duration
                        pubDate: model.pubDate
                        badgeText: model.badgeText || ""
                    }
                }

                onContentYChanged: {
                    if (catView.visible) {
                        catView._lastContentY = contentY
                        if (catView._scrollRestored) {
                            catView.setScrollY(contentY)
                        }
                    }
                    catView.checkLoadMore()
                }

                onMovementEnded: {
                    catView.checkLoadMore()
                }

                onContentHeightChanged: {
                    catView.restoreScroll()
                }
            }

            // 右下角悬浮刷新按钮
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
                onClicked: catView.refresh()
            }

            Connections {
                target: Api
                function onHotsAllReceived(data) {
                    if (catView.category !== "all") return
                    catView.appendApiData(data)
                }
                function onHotsRankReceived(data) {
                    if (catView.category !== "rank") return
                    catView.appendApiData(data)
                }
                function onHotsWeeklyReceived(data) {
                    if (catView.category !== "weekly") return
                    catView.appendApiData(data)
                }
                function onHotsHistoryReceived(data) {
                    if (catView.category !== "history") return
                    catView.appendApiData(data)
                }
                function onHotsWeeklyListReceived(data) {
                    if (catView.category !== "weekly") return
                    catView.appendWeeklyListData(data)
                }
                // 断网等网络错误时 Api 只发 errorOccurred 不发数据信号，
                // 不复位 loading 会让 refresh() 的 loading 守卫永久卡死
                function onErrorOccurred(error) {
                    console.warn("[HotPage] API error:", error)
                    if (!catView.loading) return
                    catView.loading = false
                    catView.setHasMore(false)
                }
            }
        }
    }
}
