import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import QtQuick.Window 2.15

import FluentUI 1.0
import BiliQt 1.0
import "./"
import "../components"

FluPage {
    id: history_page
    title: ""
    launchMode: FluPageType.SingleInstance

    FluInfoBar {
        id: infoBar
        root: history_page
    }

    Connections {
        target: Api
        function onHistoryListReceived(data) {
            history_page.appendHistoryData(data)
        }
        // 断网等网络错误时 Api 只发 errorOccurred 不发数据信号，
        // 不复位 loading 会让 loadMore 的 loading 守卫永久卡死（只能重启）
        function onErrorOccurred(error) {
            console.warn("[HistoryPage] API error:", error)
            if (!history_page.loading) return
            history_page.loading = false
            history_page.hasMore = false
        }
    }

    property bool videoVisible: false
    property bool liveVisible: false

    onVisibleChanged: {
        if (visible) {
            if (!Login.isLoggedIn) {
                history_page.showLoginWarning()
            } else {
                history_page.tryLoadInitial()
            }
        } else {
            // 小窗模式：pageStack.visible=false 使 visible 从父级"流动"为 false
            //（Qt 语义：父项 visible 变化会直接改变全部子孙的 visible 值并触发
            //  visibleChanged），非真实切页，绝不能关闭播放器
            if (App.miniPlayerMode) return
            // 切到其他导航页时，如果播放器还开着，关闭并卸载实例，避免声音串扰
            _loginWarnShown = false
            if (videoVisible) closeVideoPlayer()
            if (liveVisible) closeLivePlayer()
        }
    }

    Component.onCompleted: {
        if (!Login.isLoggedIn) {
            history_page.showLoginWarning()
        } else {
            history_page.tryLoadInitial()
        }
    }

    property bool loading: false
    property bool hasMore: true
    property int pageSize: Theme.pageSize

    property int cardWidth: Theme.cardWidth
    property int margins: Theme.pageMargins
    property int vSpacing: Theme.pageVSpacing
    property int minHSpacing: Theme.pageHSpacing
    property int columns: Math.max(1, Math.floor((gridView.width + minHSpacing) / (cardWidth + minHSpacing)))
    property real cellWidth: columns > 1 ? gridView.width / columns : gridView.width
    property real displayCardWidth: Math.max(1, cellWidth - minHSpacing)
    property bool _sizeValid: history_page.width > 0 && history_page.height > 0

    property bool _loginWarnShown: false
    property int _cursorMax: 0
    property int _cursorViewAt: 0
    property string _cursorBusiness: ""

    function tryLoadInitial() {
        if (!Login.isLoggedIn) return
        if (history_page._sizeValid && historyModel.count === 0 && !history_page.loading && history_page.hasMore) {
            history_page.loadMore()
        }
    }

    function showLoginWarning() {
        if (!_loginWarnShown && history_page.visible) {
            _loginWarnShown = true
            infoBar.showWarning("请先登录")
        }
    }

    onWidthChanged: tryLoadInitial()
    onHeightChanged: tryLoadInitial()

    function loadMore() {
        if (loading || !hasMore) return
        if (!history_page._sizeValid) return
        if (!Login.isLoggedIn) {
            showLoginWarning()
            loading = false
            hasMore = false
            return
        }
        loading = true
        Api.getHistoryList(_cursorMax, _cursorViewAt, _cursorBusiness, history_page.pageSize)
    }

    function refresh() {
        if (!Login.isLoggedIn) {
            showLoginWarning()
            return
        }
        historyModel.clear()
        _cursorMax = 0
        _cursorViewAt = 0
        _cursorBusiness = ""
        hasMore = true
        loadMore()
    }

    function appendHistoryData(data) {
        try {
            var dataStr = typeof data === "string" ? data : data.toString()
            var resp = JSON.parse(dataStr)
            if (resp.code !== 0 || !resp.data) {
                console.warn("[HistoryPage] history API error, code:", resp.code, "msg:", resp.message)
                var msg = resp.message || ""
                if (resp.code === -101 || msg.indexOf("未登录") >= 0 || msg.indexOf("账号未登录") >= 0) {
                    showLoginWarning()
                }
                loading = false
                hasMore = false
                return
            }

            var list = resp.data.list || []
            var cursor = resp.data.cursor || {}
            var added = 0
            for (var i = 0; i < list.length; i++) {
                var item = list[i]
                if (!item) continue

                var history = item.history || {}
                var business = history.business || ""
                var type = "video"
                var bvid = history.bvid || ""
                var roomId = ""
                var epId = ""
                var seasonId = ""
                var isBangumi = false
                
                if (business === "live") {
                    type = "live"
                    roomId = String(history.oid || "")
                } else if (business === "pgc") {
                    type = "bangumi"
                    isBangumi = true
                    epId = String(history.epid || "")
                    seasonId = String(history.oid || "")
                    // 番剧也可能有 bvid
                    bvid = history.bvid || ""
                    // 调试：打印番剧条目的所有字段
                    var allKeys = Object.keys(item)
                    for (var kp = 0; kp < allKeys.length; kp++) {
                        var k = allKeys[kp]
                        if (k === "covers" || k === "long_title") continue  // 跳过太大的
                    }
                } else if (business === "archive" || business === "") {
                    // 检查是否有番剧特征字段（epid 和 oid），即使 business 是 archive 也可能是番剧
                    var hasBangumiEpid = history.epid && String(history.epid) !== "" && String(history.epid) !== "0"
                    var hasBangumiOid = history.oid && String(history.oid) !== "" && String(history.oid) !== "0"
                    if (hasBangumiEpid && hasBangumiOid) {
                        type = "bangumi"
                        isBangumi = true
                        epId = String(history.epid)
                        seasonId = String(history.oid)
                        bvid = history.bvid || ""
                    } else {
                        type = "video"
                    }
                } else {
                    type = "video"
                }

                var title = item.title || ""
                var subtitle = item.show_title || ""
                
                // ===== 番剧：记录 seasonTitle（番剧总标题）和 epTitle（集数标题）=====
                var seasonTitle = ""
                var epTitle = ""
                if (isBangumi) {
                    // 优先尝试 season_title 字段（通常 PGC 有这个字段表示番剧总名）
                    seasonTitle = item.season_title || ""
                    if (seasonTitle === "") seasonTitle = item.bangumi_title || ""
                    if (seasonTitle === "") seasonTitle = item.series_title || ""
                    
                    // 集数标题：通常 show_title 是"第2集"这种序号，long_title 是完整集标题
                    epTitle = item.long_title || ""
                    if (epTitle === "") epTitle = subtitle
                    if (epTitle === "") epTitle = title  // 兜底用 title
                    
                    // 如果 seasonTitle 拿不到，但 title 里有"番剧"，只能兜底
                    if (seasonTitle === "") {
                        seasonTitle = title
                        // 如果 title 包含 epTitle，把 epTitle 去掉，剩下的就是番剧名
                        if (epTitle !== "" && title !== epTitle) {
                            // 取前面部分，例如"凡人修仙传 第2集" -> "凡人修仙传"
                            var idx = title.indexOf(epTitle)
                            if (idx >= 0) {
                                var candidate = title.substring(0, idx).trim()
                                if (candidate.length > 2) seasonTitle = candidate
                            }
                        }
                    }
                }
                
                if (subtitle && subtitle !== title && title.indexOf(subtitle) < 0) {
                    title = title + " " + subtitle
                }

                var cover = ""
                if (Array.isArray(item.covers) && item.covers.length > 0) {
                    cover = item.covers[0]
                } else if (item.cover) {
                    cover = item.cover
                }

                // ====== 显式转换为 int 并设置默认值 0，避免 QML "Unable to assign [undefined] to int" 警告 ======
                // 番剧 (pgc) / 普通视频条目中的数字字段可能来自 JSON 为 string/undefined/null，
                // 统一用 parseInt(...,10)||0 确保始终是合法的 int 值，委托绑定到子组件 int 属性时不会 undefined。
                var progress = parseInt(item.progress, 10) || 0
                var duration = parseInt(item.duration, 10) || 0
                var viewAt   = parseInt(item.view_at, 10)  || 0
                var liveStatus = parseInt(item.live_status, 10) || 0
                var finished = progress === -1 || (duration > 0 && progress >= duration)
                var progressText = ""
                if (!finished && duration > 0 && progress > 0) {
                    progressText = history_page.formatDuration(progress) + " / " + history_page.formatDuration(duration)
                }

                historyModel.append({
                    type: type,
                    bvid: bvid,
                    roomId: roomId,
                    epId: epId,
                    seasonId: seasonId,
                    isBangumi: isBangumi,
                    title: title,
                    cover: GlobalState.fixImageUrl(cover),
                    author: item.author_name || "",
                    // 番剧专用字段：seasonTitle=番剧总标题；epTitle=集数标题（如"第4集 凡人风起天南4"）
                    seasonTitle: seasonTitle,
                    epTitle: epTitle,
                    viewTime: history_page.formatTimeAgo(viewAt),
                    progress: progressText,
                    finished: finished,
                    isLive: type === "live" && (liveStatus === 1)
                })
                added++
            }

            _cursorMax = cursor.max || 0
            _cursorViewAt = cursor.view_at || 0
            _cursorBusiness = cursor.business || ""

            hasMore = added > 0
        } catch (e) {
            console.warn("[HistoryPage] parse history data failed:", e)
            hasMore = false
        }
        finishLoad()
    }

    function formatDuration(seconds) {
        var s = parseInt(seconds, 10) || 0
        var h = Math.floor(s / 3600)
        var m = Math.floor((s % 3600) / 60)
        var sec = s % 60
        if (h > 0) {
            return (h < 10 ? "0" + h : h) + ":" + (m < 10 ? "0" + m : m) + ":" + (sec < 10 ? "0" + sec : sec)
        }
        return (m < 10 ? "0" + m : m) + ":" + (sec < 10 ? "0" + sec : sec)
    }

    function formatTimeAgo(timestamp) {
        if (!timestamp) return ""
        var now = new Date()
        var date = new Date(timestamp * 1000)
        var pad = function(n) { return n < 10 ? "0" + n : String(n) }
        var sameDay = function(a, b) {
            return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate()
        }
        var yesterday = function(today, target) {
            var d = new Date(today.getFullYear(), today.getMonth(), today.getDate() - 1)
            return target.getFullYear() === d.getFullYear() && target.getMonth() === d.getMonth() && target.getDate() === d.getDate()
        }
        var hm = pad(date.getHours()) + ":" + pad(date.getMinutes())
        if (sameDay(now, date)) {
            return "今天 " + hm
        }
        if (yesterday(now, date)) {
            return "昨天 " + hm
        }
        if (date.getFullYear() !== now.getFullYear()) {
            return date.getFullYear() + "-" + pad(date.getMonth() + 1) + "-" + pad(date.getDate()) + " " + hm
        }
        return pad(date.getMonth() + 1) + "-" + pad(date.getDate()) + " " + hm
    }

    function finishLoad() {
        loading = false
        fillTimer.start()
    }

    function checkLoadMore() {
        if (history_page.loading || !history_page.hasMore) return
        if (gridView.height <= 0) return
        if (gridView.contentY + gridView.height >= gridView.contentHeight - Theme.cardWidth * 2) {
            history_page.loadMore()
        }
    }

    Timer {
        id: fillTimer
        interval: 50
        onTriggered: {
            if (history_page.loading || !history_page.hasMore) return
            if (!history_page._sizeValid || gridView.height <= 0) return
            var maxFillItems = history_page.pageSize * 10
            if (historyModel.count < maxFillItems && gridView.contentHeight <= gridView.height + 10) {
                history_page.loadMore()
            }
        }
    }

    ListModel {
        id: historyModel
    }

    FluFrame {
        id: historyFrame
        anchors.fill: parent
        anchors.leftMargin: Theme.homeFrameLeftMargin
        anchors.rightMargin: Theme.homeFrameRightMargin
        anchors.bottomMargin: Theme.homeFrameBottomMargin
        anchors.topMargin: Theme.homeFrameTopMargin
        padding: Theme.homeFramePadding

        Rectangle {
            id: rootRect
            color: "transparent"
            anchors.fill: parent
            property int margins: Theme.pageMargins

            GridView {
                id: gridView
                anchors.fill: parent
                anchors.leftMargin: rootRect.margins
                anchors.rightMargin: rootRect.margins + 20
                anchors.topMargin: rootRect.margins
                anchors.bottomMargin: rootRect.margins
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: FluScrollBar {}

                model: historyModel
                cellWidth: Math.max(1, history_page.cellWidth)
                cellHeight: Math.max(1, history_page.displayCardWidth * Theme.cardAspectRatio + Theme.cardInfoHeight + history_page.vSpacing)
                cacheBuffer: Math.max(0, gridView.height * 2)
                flow: GridView.LeftToRight
                layoutDirection: Qt.LeftToRight
                verticalLayoutDirection: GridView.TopToBottom

                delegate: Item {
                    width: Math.max(1, history_page.cellWidth)
                    height: Math.max(1, gridView.cellHeight)

                    HistoryCard {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.max(1, history_page.displayCardWidth - Theme.scrollBarReserve)
                        type: model.type
                        bvid: model.bvid
                        roomId: model.roomId
                        epId: model.epId
                        seasonId: model.seasonId
                        isBangumi: model.isBangumi
                        title: model.title
                        // 番剧：使用 seasonTitle（番剧总标题）作为大标题
                        seasonTitle: model.seasonTitle || ""
                        // 番剧：使用 epTitle（集数标题，如"第4集 凡人风起天南4"）作为第二行
                        epTitle: model.epTitle || ""
                        cover: model.cover
                        author: model.author
                        viewTime: model.viewTime
                        progress: model.progress
                        finished: model.finished
                        isLive: model.isLive

                        onClicked: {
                            if (model.type === "bangumi" || model.isBangumi) {
                                // 番剧始终走 openBangumiPlayer，确保选集、seasonType 等信息正确加载
                                // openBangumiPlayer 内部会判断是否有真实 bvid：
                                //   - 有真实 bvid：走番剧 API 获取完整信息后切换到普通视频路径
                                //   - 无真实 bvid：走番剧专用接口
                                history_page.openBangumiPlayer(model.bvid, model.epId, model.seasonId, model.title)
                            } else if (model.type === "video") {
                                App.openVideo(model.bvid, model.title)
                            } else if (model.isLive) {
                                history_page.openLivePlayer(model.roomId, model.title, model.author)
                            } else {
                                infoBar.showWarning("当前直播已结束")
                            }
                        }
                    }
                }

                onContentYChanged: {
                    history_page.checkLoadMore()
                }

                onMovementEnded: {
                    history_page.checkLoadMore()
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
                    history_page.refresh()
                }
            }
        }
    }

    // 视频播放页打开时，兜底拦截滚轮事件，防止其穿透到底层主页滚动视图。
    MouseArea {
        anchors.fill: historyFrame
        z: 99
        enabled: videoVisible
        acceptedButtons: Qt.NoButton
        hoverEnabled: true
        onWheel: function(wheel) { wheel.accepted = true }
    }

    Item {
        id: videoOverlay
        anchors.fill: historyFrame
        anchors.margins: Theme.overlayMargin
        z: 100
        visible: opacity > 0 || openVideoAnim.running || closeVideoAnim.running || switchVideoSeqAnim.running
        opacity: 0

        property string videoBvid: ""
        property string videoTitleText: ""
        property bool videoIsBangumi: false
        property string videoEpId: ""
        property string videoSeasonId: ""
        property string _currentLoadedKey: ""
        property bool _playerCreated: false
        property string _pendingSwitchBvid: ""
        property string _pendingSwitchTitle: ""
        property bool _pendingSwitchIsBangumi: false
        property string _pendingSwitchEpId: ""
        property string _pendingSwitchSeasonId: ""
        property string _pendingOpenBvid: ""  // 延迟打开时的 bvid
        property bool _pendingOpenIsBangumi: false
        property string _pendingOpenEpId: ""
        property string _pendingOpenSeasonId: ""

        Component {
            id: videoPlayerComponent
            VideoPlayerPage {
                anchors.fill: parent
                bvid: videoOverlay.videoBvid
                videoTitle: videoOverlay.videoTitleText
                isBangumi: videoOverlay.videoIsBangumi
                epId: videoOverlay.videoEpId
                seasonId: videoOverlay.videoSeasonId
            }
        }

        Item {
            id: videoContainer
            anchors.fill: parent
            transform: Translate {
                id: videoTranslate
                y: 0
            }

            // 仅在 Loader 实际加载了播放器时才启用，避免切换/关闭过程中
            // 空 overlay 挡住主页卡片交互。
            MouseArea {
                anchors.fill: parent
                z: -1
                enabled: videoPlayerLoader.active
                onClicked: { /* 仅消费事件，不执行任何操作 */ }
            }

            Loader {
                id: videoPlayerLoader
                anchors.fill: parent
                // Loader.active 只受 _playerCreated 控制，不受 videoOverlay.visible 影响
                // 这样当关闭动画完成后，videoOverlay.visible 变为 false，
                // 但 Loader 仍保持激活，确保播放器在延迟销毁定时器触发前不会被过早销毁
                active: videoOverlay._playerCreated
                sourceComponent: videoPlayerComponent
            }
        }

        // 延迟卸载定时器：在所有动画完成后再卸载实例，
        // 避免在渲染线程仍持有 mpv 上下文时销毁导致卡死/闪退。
        Timer {
            id: videoPlayerDestroyTimer
            interval: 400  // 动画(250ms) + 安全余量
            repeat: false
            onTriggered: {
                // 只有当视频不可见且没有在切换/打开时才真正销毁
                if (!videoVisible
                    && !openVideoAnim.running
                    && !closeVideoAnim.running
                    && !switchVideoSeqAnim.running) {
                    videoOverlay._playerCreated = false
                }
            }
        }

        function doOpen() {
            videoPlayerDestroyTimer.stop()
            closeVideoAnim.stop()
            switchVideoSeqAnim.stop()
            _playerCreated = true
            openVideoAnim.start()
        }

        function doClose() {
            videoPlayerDestroyTimer.stop()  // 停止之前可能的销毁定时器
            openVideoAnim.stop()
            closeVideoAnim.stop()
            switchVideoSeqAnim.stop()
            if (videoPlayerLoader.item) {
                videoPlayerLoader.item.stopPlayer()
            }
            closeVideoAnim.start()
            videoPlayerDestroyTimer.start()  // 动画完成后延迟销毁
        }

        function doSwitch(bvid, title, isBangumi, epId, seasonId) {
            videoPlayerDestroyTimer.stop()  // 切换时停止销毁定时器
            switchVideoSeqAnim.stop()
            closeVideoAnim.stop()
            openVideoAnim.stop()

            _pendingSwitchBvid = bvid
            _pendingSwitchTitle = title
            _pendingSwitchIsBangumi = !!isBangumi
            _pendingSwitchEpId = epId || ""
            _pendingSwitchSeasonId = seasonId || ""
            _playerCreated = true  // 保持播放器存活，只切换内容

            if (videoPlayerLoader.item) {
                videoPlayerLoader.item.stopPlayer()
            }

            switchVideoSeqAnim.start()
        }

        ParallelAnimation {
            id: openVideoAnim
            NumberAnimation {
                target: videoOverlay
                property: "opacity"
                from: 0
                to: 1
                duration: 250
                easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: videoTranslate
                property: "y"
                from: videoOverlay.height * 0.15
                to: 0
                duration: 250
                easing.type: Easing.OutCubic
            }
            // 关键优化：动画完成后再设置 bvid 触发加载，避免动画卡顿
            onStopped: {
                if (videoOverlay._pendingOpenBvid) {
                    videoOverlay.videoBvid = videoOverlay._pendingOpenBvid
                    videoOverlay.videoIsBangumi = videoOverlay._pendingOpenIsBangumi
                    videoOverlay.videoEpId = videoOverlay._pendingOpenEpId
                    videoOverlay.videoSeasonId = videoOverlay._pendingOpenSeasonId
                    videoOverlay._pendingOpenBvid = ""
                }
            }
        }

        ParallelAnimation {
            id: closeVideoAnim
            NumberAnimation {
                target: videoOverlay
                property: "opacity"
                from: 1
                to: 0
                duration: 200
                easing.type: Easing.InCubic
            }
            NumberAnimation {
                target: videoTranslate
                property: "y"
                from: 0
                to: videoOverlay.height * 0.15
                duration: 200
                easing.type: Easing.InCubic
            }
            // onStopped 不再立即销毁播放器，由 videoPlayerDestroyTimer 统一管理
        }

        SequentialAnimation {
            id: switchVideoSeqAnim

            ParallelAnimation {
                NumberAnimation {
                    target: videoOverlay
                    property: "opacity"
                    from: 1
                    to: 0
                    duration: 200
                    easing.type: Easing.InCubic
                }
                NumberAnimation {
                    target: videoTranslate
                    property: "y"
                    from: 0
                    to: videoOverlay.height * 0.3
                    duration: 200
                    easing.type: Easing.InCubic
                }
            }

            ScriptAction {
                script: {
                    videoOverlay.videoBvid = videoOverlay._pendingSwitchBvid
                    videoOverlay.videoTitleText = videoOverlay._pendingSwitchTitle
                    videoOverlay.videoIsBangumi = videoOverlay._pendingSwitchIsBangumi
                    videoOverlay.videoEpId = videoOverlay._pendingSwitchEpId
                    videoOverlay.videoSeasonId = videoOverlay._pendingSwitchSeasonId
                }
            }
            ParallelAnimation {
                NumberAnimation {
                    target: videoOverlay
                    property: "opacity"
                    from: 0
                    to: 1
                    duration: 250
                    easing.type: Easing.OutCubic
                }
                NumberAnimation {
                    target: videoTranslate
                    property: "y"
                    from: videoOverlay.height * 0.3
                    to: 0
                    duration: 250
                    easing.type: Easing.OutCubic
                }
            }

            onStopped: {
                videoOverlay._pendingSwitchBvid = ""
                videoOverlay._pendingSwitchTitle = ""
            }
        }
    }

    // 共享弹幕管理器：放在 HistoryPage 层级，不随 LivePlayerPage 销毁/重建。
    // 避免 QWebSocket（SSL 握手线程）频繁创建/销毁导致卡死。
    LiveDanmakuManager {
        id: sharedDanmakuManager
    }

    Item {
        id: liveOverlay
        anchors.fill: historyFrame
        anchors.margins: Theme.overlayMargin
        z: 100
        visible: opacity > 0 || openLiveAnim.running || closeLiveAnim.running
        opacity: 0

        property string liveRoomId: ""
        property string liveTitleText: ""
        property string liveStreamerName: ""
        property bool _playerCreated: false
        property string _pendingOpenLiveRoomId: ""  // 延迟打开时的 roomId
        property string _pendingOpenLiveTitle: ""
        property string _pendingOpenLiveStreamer: ""

        transform: Translate {
            id: liveTranslate
            y: 0
        }

        Component {
            id: livePlayerComponent
            LivePlayerPage {
                anchors.fill: parent
                roomId: liveOverlay.liveRoomId
                streamTitle: liveOverlay.liveTitleText
                streamer: liveOverlay.liveStreamerName
                danmakuManager: sharedDanmakuManager
                onCloseRequested: history_page.closeLivePlayer()
            }
        }

        // 仅在 Loader 实际加载了播放器时才启用，避免切换/关闭过程中
        // 空 overlay 挡住主页卡片交互。
        MouseArea {
            anchors.fill: parent
            z: -1
            enabled: livePlayerLoader.active
            onClicked: { /* 仅消费事件，不执行任何操作 */ }
        }

        Loader {
            id: livePlayerLoader
            anchors.fill: parent
            // 与视频播放页相同策略：active 同时依赖 visible 和 _playerCreated。
            // 关闭直播时 _playerCreated 在 livePlayerDestroyTimer（250ms）后置 false，
            // 期间等退出动画完成再销毁 LivePlayerPage，避免渲染线程仍持有 mpv 上下文时销毁导致卡死。
            // 小窗模式守卫：进入小窗时 pageStack 隐藏使 liveOverlay.visible 从父级
            // "流动"为 false，若不守卫会立即卸载销毁直播页（白屏无声）
            active: (liveOverlay.visible || App.miniPlayerMode) && liveOverlay._playerCreated
            sourceComponent: livePlayerComponent
        }

        // 延迟卸载定时器：等退出动画完成后卸载实例，
        // 避免在渲染线程仍持有 mpv 上下文时销毁导致卡死/闪退。
        Timer {
            id: livePlayerDestroyTimer
            interval: 250
            repeat: false
            onTriggered: {
                if (!liveVisible
                    && !openLiveAnim.running
                    && !closeLiveAnim.running) {
                    liveOverlay._playerCreated = false
                }
            }
        }

        function doOpen() {
            livePlayerDestroyTimer.stop()
            // 先停止退出动画，再标记创建实例，避免 stop() 同步触发
            // closeLiveAnim.onStopped 时把 _playerCreated 清掉。
            closeLiveAnim.stop()
            liveOverlay._playerCreated = true
            openLiveAnim.start()
        }

        function doClose() {
            livePlayerDestroyTimer.stop()  // 停止之前可能的销毁定时器
            openLiveAnim.stop()
            // 先立即停止播放与弹幕，再延迟卸载实例
            if (livePlayerLoader.item) {
                livePlayerLoader.item.stopPlayer()
            }
            // 清空 roomId：与视频播放页相同的销毁策略，Loader 会在动画结束后销毁 LivePlayerPage。
            // 清空 roomId 确保下次重建时 LivePlayerPage 以 roomId="" 初始化，
            // 不会因旧 roomId 触发 onRoomIdChanged → loadStream() 加载旧房间。
            liveOverlay.liveRoomId = ""
            closeLiveAnim.start()
            livePlayerDestroyTimer.start()  // 动画完成后延迟销毁
        }

        ParallelAnimation {
            id: openLiveAnim
            NumberAnimation {
                target: liveOverlay
                property: "opacity"
                from: 0
                to: 1
                duration: 250
                easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: liveTranslate
                property: "y"
                from: liveOverlay.height * 0.15
                to: 0
                duration: 250
                easing.type: Easing.OutCubic
            }
            // 关键优化：动画完成后再设置 roomId 触发加载，避免动画卡顿
            onStopped: {
                if (liveOverlay._pendingOpenLiveRoomId) {
                    liveOverlay.liveRoomId = liveOverlay._pendingOpenLiveRoomId
                    liveOverlay.liveTitleText = liveOverlay._pendingOpenLiveTitle
                    liveOverlay.liveStreamerName = liveOverlay._pendingOpenLiveStreamer
                    liveOverlay._pendingOpenLiveRoomId = ""
                }
            }
        }

        ParallelAnimation {
            id: closeLiveAnim
            NumberAnimation {
                target: liveOverlay
                property: "opacity"
                from: 1
                to: 0
                duration: 200
                easing.type: Easing.InCubic
            }
            NumberAnimation {
                target: liveTranslate
                property: "y"
                from: 0
                to: liveOverlay.height * 0.15
                duration: 200
                easing.type: Easing.InCubic
            }
            // onStopped 不再立即销毁播放器，由 livePlayerDestroyTimer 统一管理
        }
    }

    Connections {
        target: App
        function onVideoOpenRequested(bvid, title) {
            // 非当前可见页面不响应，避免多实例同时打开视频造成卡顿
            if (!history_page.visible) return
            history_page.openVideoPlayer(bvid, title)
        }
        function onBangumiOpenRequested(bvid, epId, seasonId, title) {
            if (!history_page.visible) return
            history_page.openBangumiPlayer(bvid, epId, seasonId, title)
        }
        function onVideoCloseRequested() {
            history_page.closeVideoPlayer()
        }
    }

    function openBangumiPlayer(bvid, epId, seasonId, title) {
        
        videoOverlay.videoTitleText = title
        videoOverlay.videoIsBangumi = true
        videoOverlay.videoEpId = epId
        videoOverlay.videoSeasonId = seasonId
        
        // 简化：直接设置番剧模式，统一走番剧API路径
        // 如果有真实 bvid，用它；没有的话用 bangumi_ 前缀标识
        var videoBvid = bvid
        if (!videoBvid || videoBvid.indexOf("bangumi_") === 0) {
            videoBvid = "bangumi_" + (epId || seasonId)
        }
        
        if (videoVisible && videoOverlay.videoBvid === videoBvid) {
            return
        }
        
        // 立即设置 videoBvid，确保 Loader 创建时获取正确的值
        videoOverlay.videoBvid = videoBvid
        
        if (videoVisible && videoOverlay._playerCreated) {
            videoVisible = true
            videoOverlay.doSwitch(videoBvid, title, true, epId, seasonId)
        } else {
            videoOverlay._pendingOpenBvid = videoBvid
            videoOverlay._pendingOpenIsBangumi = true
            videoOverlay._pendingOpenEpId = epId
            videoOverlay._pendingOpenSeasonId = seasonId
            videoVisible = true
            videoOverlay.doOpen()
        }
    }

    function openVideoPlayer(bvid, title) {
        if (videoVisible && videoOverlay.videoBvid === bvid) {
            return
        }
        
        var oldBvid = videoOverlay.videoBvid
        var hasOldVideo = videoVisible && videoOverlay._playerCreated && oldBvid !== "" && oldBvid !== bvid
        
        // 关键修复：立即设置 videoBvid，确保 Loader 创建新实例时获取正确的 bvid
        videoOverlay.videoTitleText = title
        videoOverlay.videoIsBangumi = false
        videoOverlay.videoEpId = ""
        videoOverlay.videoSeasonId = ""
        videoOverlay.videoBvid = bvid  // 立即设置，避免时序问题
        
        if (hasOldVideo) {
            // 切换视频时不需要延迟，因为已经有播放器实例
            videoVisible = true
            videoOverlay.doSwitch(bvid, title, false, "", "")
        } else {
            // 使用延迟加载
            videoOverlay._pendingOpenBvid = bvid
            videoOverlay._pendingOpenIsBangumi = false
            videoOverlay._pendingOpenEpId = ""
            videoOverlay._pendingOpenSeasonId = ""
            videoVisible = true
            videoOverlay.doOpen()
        }
    }

    function closeVideoPlayer() {
        if (!videoVisible) return
        videoVisible = false
        videoOverlay.doClose()
    }

    function openLivePlayer(roomId, title, streamer) {
        // 同一直播间已打开时直接忽略，避免重复加载
        if (liveVisible && liveOverlay.liveRoomId === roomId) {
            return
        }
        // 当前正打开其他直播时，先停旧流再开新直播（销毁策略：doClose 会清空 roomId 并启动销毁）
        if (liveVisible && liveOverlay.liveRoomId !== roomId) {
            if (livePlayerLoader.item) {
                try { livePlayerLoader.item.stopPlayer() } catch (e) {}
            }
            liveOverlay.doClose()
        }
        // 关键优化：使用延迟加载，避免动画卡顿
        liveOverlay._pendingOpenLiveRoomId = roomId
        liveOverlay._pendingOpenLiveTitle = title
        liveOverlay._pendingOpenLiveStreamer = streamer
        liveVisible = true
        liveOverlay.doOpen()
    }

    function closeLivePlayer() {
        if (!liveVisible) return
        liveVisible = false
        liveOverlay.doClose()
    }

    Component.onDestruction: {
        // 离开历史页面时强制销毁播放器，释放 D3D11 资源
        livePlayerDestroyTimer.stop()
        if (livePlayerLoader.item) {
            try { livePlayerLoader.item.stopPlayer() } catch (e) {}
        }
        liveOverlay._playerCreated = false
        // 断开弹幕 WebSocket，释放 SSL 资源
        try { sharedDanmakuManager.disconnectRoom() } catch (e) {}
    }
}
