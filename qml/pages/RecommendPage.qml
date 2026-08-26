import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

import FluentUI 1.0
import BiliQt 1.0
import "../components"

Rectangle {
    id: root
    color: "transparent"

    property int cardWidth: Theme.cardWidth        // 卡片固定宽度，用于列数计算
    property int margins: Theme.pageMargins
    property int vSpacing: Theme.pageVSpacing
    property int minHSpacing: Theme.pageHSpacing   // 最小横向间距，实际间距会在此基础上拉伸以撑满页面
    property int pageSize: Theme.pageSize

    property int columns: Math.max(1, Math.floor((gridView.width + minHSpacing) / (cardWidth + minHSpacing)))
    property real cellWidth: columns > 1 ? gridView.width / columns : gridView.width
    property real displayCardWidth: Math.max(1, root.cellWidth - root.minHSpacing)

    property var videoModel: null
    property alias contentY: gridView.contentY
    property real initialContentY: 0

    property bool _scrollRestored: false
    property bool _pageInitialized: false
    property real _lastContentY: 0
    property bool _sizeValid: root.width > 0 && root.height > 0

    signal contentYChangedExternally(real y)

    function tryLoadInitial() {
        if (root._sizeValid && root.visible && videoModel && videoModel.count === 0 && !GlobalState.recommendLoading && GlobalState.recommendHasMore) {
            root.loadMore()
        }
    }

    onVideoModelChanged: {
        root.tryLoadInitial()
    }

    onWidthChanged: tryLoadInitial()
    onHeightChanged: tryLoadInitial()

    Component.onCompleted: {
        _lastContentY = Math.max(0, root.initialContentY > 0 ? root.initialContentY : GlobalState.recommendScrollY)
        _pageInitialized = true
        root.restoreScroll()
        restoreCheckTimer.start()
        tryLoadInitial()
    }

    Timer {
        id: restoreCheckTimer
        interval: 50
        repeat: true
        property int _attempts: 0
        onTriggered: {
            _attempts++
            root.restoreScroll()
            // 恢复成功或内容不足一页/超过 1 秒仍未满足条件则停止重试
            if (root._scrollRestored || _attempts >= 20) stop()
        }
    }

    Component.onDestruction: {
        var y = gridView.contentY
        if (y === 0 && root._lastContentY > 0) y = root._lastContentY
        GlobalState.recommendScrollY = y
        if (gridView.contentHeight > 0) GlobalState.recommendContentHeight = gridView.contentHeight
    }

    onVisibleChanged: {
        if (visible) {
            root._scrollRestored = false
            restoreCheckTimer._attempts = 0
            root.restoreScroll()
            restoreCheckTimer.start()
            root.tryLoadInitial()
        } else if (root._pageInitialized) {
            var y = gridView.contentY
            if (y === 0 && root._lastContentY > 0) y = root._lastContentY
            root._lastContentY = y
            GlobalState.recommendScrollY = y
            if (gridView.contentHeight > 0) GlobalState.recommendContentHeight = gridView.contentHeight
        }
    }

    function restoreScroll() {
        if (!root._sizeValid || gridView.height <= 0 || root._scrollRestored) return
        var savedY = root._lastContentY
        var savedH = GlobalState.recommendContentHeight
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
        if (videoModel === null || GlobalState.recommendLoading) return
        GlobalState.recommendLoading = false
        videoModel.clear()
        GlobalState.recommendHasMore = true
        GlobalState.recommendNextPage = 1
        GlobalState.recommendEmptyStreak = 0
        GlobalState.recommendManualRefresh = true
        GlobalState.recommendScrollY = 0
        GlobalState.recommendContentHeight = 0
        gridView.positionViewAtBeginning()
        gridView.contentY = 0
        if (root._sizeValid) {
            gridView.forceLayout()
            loadMore()
        }
    }

    function loadMore() {
        if (GlobalState.recommendLoading || !GlobalState.recommendHasMore || videoModel === null) return
        if (!root._sizeValid) return
        GlobalState.recommendLoading = true
        // 对齐 wiliwili：固定 ps=30，手动刷新 fresh_type=3，初始加载=0，自动加载=4
        var freshType = 4
        if (GlobalState.recommendManualRefresh) {
            freshType = 3
            GlobalState.recommendManualRefresh = false
        } else if (GlobalState.recommendNextPage === 1) {
            freshType = 0
        }
        // y_num 使用当前列数，最小为 1，与 wiliwili 保持一致
        var yNum = Math.max(1, root.columns)
        Api.getWbiRecommendVideos(GlobalState.recommendNextPage, 30, freshType, 3, yNum)
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

    function formatNumber(num) {
        var n = parseInt(num, 10) || 0
        if (n >= 100000000) return (n / 100000000).toFixed(1) + "亿"
        if (n >= 10000) return (n / 10000).toFixed(1) + "万"
        return String(n)
    }

    function formatTimeAgo(timestamp) {
        var now = Date.now() / 1000
        var diff = now - (parseInt(timestamp, 10) || 0)
        if (diff < 60) return "刚刚"
        if (diff < 3600) return Math.floor(diff / 60) + "分钟前"
        if (diff < 86400) return Math.floor(diff / 3600) + "小时前"
        if (diff < 2592000) return Math.floor(diff / 86400) + "天前"
        if (diff < 31536000) return Math.floor(diff / 2592000) + "个月前"
        return Math.floor(diff / 31536000) + "年前"
    }

    // 64 位无符号异或（JS 位运算只有 32 位有符号）
    function xor64(a, b) {
        var aLow = a % 0x100000000
        var aHigh = Math.floor(a / 0x100000000)
        var bLow = b % 0x100000000
        var bHigh = Math.floor(b / 0x100000000)
        var low = aLow ^ bLow
        if (low < 0) low += 0x100000000
        var high = aHigh ^ bHigh
        if (high < 0) high += 0x100000000
        return high * 0x100000000 + low
    }

    // AV 号转 BV 号（B站当前使用的算法），用于 APP 推荐接口返回 aid 而非 bvid 的情况
    function av2bv(aid) {
        var alphabet = "FcwAPNKTMug3GV5Lj7EJnHpWsx4tb8haYeviqBz6rkCy12mUSDQX9RdoZf"
        var xorCode = 23442827791579
        var maxAid = 2251799813685248  // 1 << 51
        var bytes = ["B", "V", "1", "0", "0", "0", "0", "0", "0", "0", "0", "0"]
        var bvIdx = 11
        // 用算术加法代替位或：aid < MAX_AID 时 maxAid | aid == maxAid + aid
        var tmp = xor64(maxAid + aid, xorCode)
        while (tmp > 0) {
            bytes[bvIdx] = alphabet.charAt(tmp % 58)
            tmp = Math.floor(tmp / 58)
            bvIdx--
        }
        // 交换位置 [3,9] 和 [4,7]
        var t = bytes[3]; bytes[3] = bytes[9]; bytes[9] = t
        t = bytes[4]; bytes[4] = bytes[7]; bytes[7] = t
        return bytes.join("")
    }

    function extractBvid(uri, param, argsAid) {
        if (uri) {
            var m = uri.match(/BV[0-9A-Za-z]{10}/)
            if (m) return m[0]
        }
        var aid = parseInt(argsAid, 10)
        if (isNaN(aid) || aid <= 0) aid = parseInt(param, 10)
        if (isNaN(aid) || aid <= 0) {
            console.warn("RecommendPage extractBvid failed, uri:", uri, "param:", param, "argsAid:", argsAid)
            return ""
        }
        return av2bv(aid)
    }

    function finishLoad() {
        GlobalState.recommendLoading = false
        fillTimer.start()
    }

    function checkLoadMore() {
        if (GlobalState.recommendLoading || !GlobalState.recommendHasMore || videoModel === null) return
        if (gridView.height <= 0) return
        if (gridView.contentY + gridView.height >= gridView.contentHeight - Theme.cardWidth * 2) {
            root.loadMore()
        }
    }

    Timer {
        id: fillTimer
        interval: 50
        onTriggered: {
            if (GlobalState.recommendLoading || !GlobalState.recommendHasMore || root.videoModel === null) return
            if (!root._sizeValid || gridView.height <= 0) return
            // 初始填充时最多加载 10 页，防止窗口极高时无限加载
            var maxFillItems = 30 * 10
            if (root.videoModel.count < maxFillItems && gridView.contentHeight <= gridView.height + 10) {
                root.loadMore()
            }
        }
    }

    function appendApiData(jsonText) {
        // 多个 RecommendPage 实例会同时监听 Api 信号；只有正在 loading 的那个实例才有资格处理本次响应
        if (!GlobalState.recommendLoading) {
            return
        }
        try {
            var resp = JSON.parse(jsonText)
            if (resp.code !== 0 || !resp.data) {
                console.warn("[RecommendPage] invalid response, code:", resp ? resp.code : "null")
                finishLoad()
                return
            }
            // Web WBI 接口返回 data.item，APP 接口返回 data.items，兼容两种格式
            var items = resp.data.item || resp.data.items || []
            if (!Array.isArray(items) || items.length === 0) {
                GlobalState.recommendEmptyStreak++
                GlobalState.recommendNextPage++
                // 空数组也按同样的上限判断，避免一直卡在同一个空页
                GlobalState.recommendHasMore = GlobalState.recommendEmptyStreak < 10 && GlobalState.recommendNextPage <= 50
                finishLoad()
                return
            }

            // 建立已存在 bvid 集合，防止同一视频被多次追加
            var existing = {}
            if (videoModel) {
                for (var mi = 0; mi < videoModel.count; mi++) {
                    var mItem = videoModel.get(mi)
                    if (mItem && mItem.bvid) existing[mItem.bvid] = true
                }
            }

            var appendedCount = 0
            for (var i = 0; i < items.length; i++) {
                var item = items[i]
                if (!item || (!item.title && !item.uri)) continue

                // 过滤广告：Web 接口是 business_info.is_ad，APP 接口是 ad_info
                if (item.business_info && item.business_info.is_ad) continue
                if (item.ad_info) continue
                if (item.card_goto === "banner") continue

                var bvid = ""
                if (item.bvid) {
                    bvid = item.bvid
                } else {
                    var argsAid = item.args && item.args.aid ? item.args.aid : ""
                    bvid = root.extractBvid(item.uri, item.param, argsAid)
                }
                if (!bvid || bvid === "") continue

                // 已存在则跳过
                if (existing[bvid]) {
                    continue
                }
                existing[bvid] = true

                var badge = ""
                if (item.rcmd_reason && item.rcmd_reason.content) {
                    badge = item.rcmd_reason.content
                } else if (item.rcmd_reason_style && item.rcmd_reason_style.text) {
                    badge = item.rcmd_reason_style.text
                } else if (item.badge) {
                    badge = item.badge
                }

                var author = ""
                if (item.owner && item.owner.name) author = item.owner.name
                else if (item.args && item.args.up_name) author = item.args.up_name
                else if (item.desc_button && item.desc_button.text) author = item.desc_button.text

                var views = ""
                if (item.stat && item.stat.view !== undefined) {
                    views = root.formatNumber(item.stat.view)
                } else {
                    views = item.cover_left_text_1 || ""
                }

                var danmakus = ""
                if (item.stat && item.stat.danmaku !== undefined) {
                    danmakus = root.formatNumber(item.stat.danmaku)
                } else {
                    danmakus = item.cover_left_text_2 || ""
                }

                var duration = ""
                if (item.duration !== undefined && item.duration !== "") {
                    duration = root.formatDuration(item.duration)
                } else {
                    duration = item.cover_right_text || ""
                }

                var cover = item.pic || item.cover || ""
                var pubDate = ""
                if (item.pubdate) pubDate = GlobalState.formatVideoCardTime(item.pubdate)

                videoModel.append({
                    bvid: bvid,
                    title: item.title || "",
                    cover: cover,
                    author: author,
                    views: views,
                    danmakus: danmakus,
                    duration: duration,
                    pubDate: pubDate,
                    badgeText: badge
                })
                appendedCount++
            }

            // Web WBI 接口使用页码分页，直接递增
            GlobalState.recommendNextPage++

            // 推荐池有限时可能出现重复，只要服务器还返回数据就继续尝试下一页；
            // 只有真正返回空数组或达到硬上限时才停止，避免很快触底。
            if (appendedCount === 0) {
                GlobalState.recommendEmptyStreak++
            } else {
                GlobalState.recommendEmptyStreak = 0
            }
            // 硬上限 50 页，防止极端情况下死循环
            var hardLimit = GlobalState.recommendNextPage <= 50
            // 当服务器连续 10 次都返回非空但全部重复时，认为已到底
            var repeatLimit = GlobalState.recommendEmptyStreak < 10
            GlobalState.recommendHasMore = items.length > 0 && repeatLimit && hardLimit
        } catch (e) {
            console.warn("RecommendPage parse API data failed:", e)
            GlobalState.recommendLoading = false
            return
        }
        finishLoad()
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
        reuseItems: true

        model: root.videoModel
        cellWidth: Math.max(1, root.cellWidth)
        cellHeight: Math.max(1, root.displayCardWidth * Theme.cardAspectRatio + Theme.cardInfoHeight + root.vSpacing)
        cacheBuffer: Math.max(0, gridView.height)
        flow: GridView.LeftToRight
        layoutDirection: Qt.LeftToRight
        verticalLayoutDirection: GridView.TopToBottom

        delegate: Item {
            width: Math.max(1, root.cellWidth)
            height: Math.max(1, gridView.cellHeight)

            VideoCard {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(1, root.displayCardWidth - Theme.scrollBarReserve)
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
            if (root.visible) {
                // 只有真正滚动过或已经恢复完成才更新 _lastContentY，
                // 避免页面隐藏/销毁前 layout 把 contentY 重置为 0 时把保存值清掉。
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
        onClicked: {
            root.refresh()
        }
    }

    Connections {
        target: Api
        function onWbiRecommendVideosReceived(data) {
            root.appendApiData(data)
        }
    }
}
