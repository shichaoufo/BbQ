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
        // type 是请求时传的分类标识，原样回传。三个 Tab 各有独立游标，
        // 响应会乱序到达，必须靠它把数据送回对应的模型
        function onHistoryListReceived(data, type) {
            history_page.appendHistoryData(data, history_page.categoryOfType(type))
        }
        // 断网等网络错误时 Api 只发 errorOccurred 不发数据信号。
        // 不复位 loading 会让该 Tab 的 loading 守卫永久卡死（只能重启）
        function onErrorOccurred(error) {
            console.warn("[HistoryPage] API error:", error)
            var cat = history_page.currentCategory()
            var row = history_page.tabRow(cat)
            if (row && row.loading) history_page.setTab(cat, "loading", false)
        }
    }

    property bool liveVisible: false

    // Pivot 索引持久化守卫（与 HomePage 同一模式）：
    // 页面销毁时把"用户最后选中的 Tab"写回 GlobalState；
    // _pageReady 防止组件初始化过程中的回写覆盖掉已保存的值。
    // onCompleted / onDestruction 本体在文件下方（与既有的登录检查、
    // 播放器清理合并在一起），这里只留状态属性
    property bool _pageReady: false
    property int _lastPivotIndex: 0

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
            _loginWarnShown = false
            // 切到其他导航页：本页内还留着的直播播放器一并关闭；
            // 视频页与用户主页是窗口级牌，由 main.qml 统一收牌
            if (liveVisible) closeLivePlayer()
        }
    }

    Component.onCompleted: {
        _pageReady = true
        _lastPivotIndex = GlobalState.historyPivotIndex
        if (!Login.isLoggedIn) {
            history_page.showLoginWarning()
        } else {
            history_page.tryLoadInitial()
        }
    }

    property int pageSize: Theme.pageSize

    // 卡片网格间距参数。列数/格子宽高改由各 Tab 的 GridView 按**自身宽度**计算
    // （见 historyGridComponent）：三个 Tab 各自算更稳妥，也避免与 pivot 布局耦合。
    property int vSpacing: Theme.pageVSpacing
    property int minHSpacing: Theme.pageHSpacing
    property bool _sizeValid: history_page.width > 0 && history_page.height > 0

    // ===== 历史记录按业务类型分三类展示 =====
    // 做法对齐 PiliPlus（lib/pages/history/controller.dart）：**每个 Tab 一个独立
    // 游标、各发各的请求**，接口参数用 type 分类（PiliPlus 的 UserHttp.historyList
    // 传的就是 type，默认 "all"）。而不是"拉全量再在客户端分发"——后者在某一类
    // 记录特别多时，另一个 Tab 要翻很多页才填得满。
    //
    // 分类标识不写死：服务端在 data.tab 里下发 [{type, name}]，按名字匹配出
    // "视频"/"直播"对应的 type（B站实际是 archive/live）。匹配不到时用兜底值。
    // 番剧(pgc)归入"视频"Tab —— 它走的也是应用内播放器，与投稿视频同类。
    property string _videoTabType: "archive"
    property string _liveTabType: "live"

    // 三个 Tab 的游标与翻页状态。用 ListModel 而不是 JS 对象：绑定系统
    // 监听不到 JS 对象内部字段的变化，loading/hasMore 改了界面不会刷新。
    // setProperty 会正常触发 role 变更通知。
    property bool _loginWarnShown: false

    function tabIndex(category) {
        for (var i = 0; i < tabStateModel.count; i++) {
            if (tabStateModel.get(i).category === category) return i
        }
        return -1
    }

    function tabRow(category) {
        var i = tabIndex(category)
        return i >= 0 ? tabStateModel.get(i) : null
    }

    function setTab(category, role, value) {
        var i = tabIndex(category)
        if (i >= 0) tabStateModel.setProperty(i, role, value)
    }

    // 界面 Tab（all/video/live）→ 接口 type 参数
    function tabTypeOf(category) {
        if (category === "video") return _videoTabType
        if (category === "live") return _liveTabType
        return "all"
    }

    // 接口回传的 type → 界面 Tab 分类。响应会乱序到达，靠它把数据送回正确的模型
    function categoryOfType(type) {
        if (type === _videoTabType) return "video"
        if (type === _liveTabType) return "live"
        return "all"
    }

    function modelOf(category) {
        if (category === "video") return historyVideoModel
        if (category === "live") return historyLiveModel
        return historyAllModel
    }

    function currentCategory() {
        if (!historyPivot) return "all"
        var i = historyPivot.currentIndex
        return i === 1 ? "video" : (i === 2 ? "live" : "all")
    }

    // 已加载过的 Tab（懒加载：只加载当前 Tab，切过去时再拉，避免一次三个请求）
    property var _loadedTabs: ({})

    function tryLoadInitial() {
        if (!Login.isLoggedIn) return
        var cat = history_page.currentCategory()
        if (history_page._sizeValid && !history_page._loadedTabs[cat]) {
            history_page._loadedTabs[cat] = true
            history_page.loadMore(cat)
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

    function loadMore(category) {
        var row = history_page.tabRow(category)
        if (!row || row.loading || !row.hasMore) return
        if (!history_page._sizeValid) return
        if (!Login.isLoggedIn) {
            showLoginWarning()
            history_page.setTab(category, "hasMore", false)
            return
        }
        history_page.setTab(category, "loading", true)
        Api.getHistoryList(row.max, row.viewAt, history_page.tabTypeOf(category), history_page.pageSize)
    }

    function refresh() {
        if (!Login.isLoggedIn) {
            showLoginWarning()
            return
        }
        // 三个 Tab 全部重置：游标归零、清空模型、恢复 hasMore。
        // 分类标识也重置，等下次响应里的 data.tab 重新解析
        _videoTabType = "archive"
        _liveTabType = "live"
        _loadedTabs = ({})
        for (var i = 0; i < tabStateModel.count; i++) {
            tabStateModel.setProperty(i, "max", 0)
            tabStateModel.setProperty(i, "viewAt", 0)
            tabStateModel.setProperty(i, "hasMore", true)
        }
        historyAllModel.clear()
        historyVideoModel.clear()
        historyLiveModel.clear()
        // 三个 Tab 都重新拉，避免切过去看到的是旧数据
        history_page.loadMore("all")
        history_page.loadMore("video")
        history_page.loadMore("live")
    }

    function appendHistoryData(data, category) {
        var model = history_page.modelOf(category)
        try {
            var dataStr = typeof data === "string" ? data : data.toString()
            var resp = JSON.parse(dataStr)
            if (resp.code !== 0 || !resp.data) {
                console.warn("[HistoryPage] history API error, cat:", category,
                             "code:", resp.code, "msg:", resp.message)
                var msg = resp.message || ""
                if (resp.code === -101 || msg.indexOf("未登录") >= 0 || msg.indexOf("账号未登录") >= 0) {
                    showLoginWarning()
                }
                history_page.setTab(category, "hasMore", false)
                return
            }

            // 只在「全部」响应里解析分类标识 —— data.tab 每个 Tab 的响应都会带回，
            // 但内容相同，解析一次就够
            if (category === "all") history_page.parseHistoryTabs(resp)

            var list = resp.data.list || []
            var cursor = resp.data.cursor || {}
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

                model.append({
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
            }

            // 游标取服务端 cursor；为空时退回"末条记录的 oid/view_at"
            // （PiliPlus 同思路：max=last.history.oid, viewAt=last.viewAt）
            var nextMax = cursor.max || 0
            var nextViewAt = cursor.view_at || 0
            if (nextMax === 0 && list.length > 0) {
                var lastItem = list[list.length - 1]
                var lastHistory = (lastItem && lastItem.history) || {}
                nextMax = parseInt(lastHistory.oid, 10) || 0
                nextViewAt = parseInt(lastItem.view_at, 10) || 0
            }
            history_page.setTab(category, "max", nextMax)
            history_page.setTab(category, "viewAt", nextViewAt)

            // 这一页没拿到数据就是到尾了。注意不能用"列表长度 < pageSize"判断：
            // 服务端在分类末尾可能返回不满一页
            history_page.setTab(category, "hasMore", list.length > 0)
        } catch (e) {
            console.warn("[HistoryPage] parse history data failed, cat:", category, e)
            history_page.setTab(category, "hasMore", false)
        }
        history_page.setTab(category, "loading", false)
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

    // 解析服务端下发的历史分类（data.tab: [{type, name}]）。
    // PiliPlus 直接按它动态生成 Tab；这里界面固定「全部/视频/直播」三个，
    // 所以只从中取出"视频"和"直播"对应的 type 值，避免把 B站的分类标识写死。
    function parseHistoryTabs(resp) {
        var tab = resp.data && resp.data.tab
        if (!tab || !tab.length) return
        for (var i = 0; i < tab.length; i++) {
            var entry = tab[i]
            if (!entry) continue
            var name = String(entry.name || "")
            var t = String(entry.type || "")
            if (!t) continue
            if (name.indexOf("视频") >= 0) _videoTabType = t
            else if (name.indexOf("直播") >= 0) _liveTabType = t
        }
    }

    // 某个 Tab 滚到底部时续拉。grid 由调用方（GridView 自身）传入，
    // 页面不需要反查当前可见的是哪个 Grid —— 各网格的"自动填满视口"
    // 也由网格自带的定时器负责（见 historyGridComponent）。
    function checkLoadMore(category, grid) {
        var row = history_page.tabRow(category)
        if (!row || row.loading || !row.hasMore) return
        if (!grid || grid.height <= 0) return
        if (grid.contentY + grid.height >= grid.contentHeight - Theme.cardWidth * 2) {
            history_page.loadMore(category)
        }
    }

    // 三个 Tab 的数据模型。全部/视频/直播各一份，互不影响
    ListModel {
        id: historyAllModel
    }
    ListModel {
        id: historyVideoModel
    }
    ListModel {
        id: historyLiveModel
    }

    // 三个 Tab 共用的卡片网格。抽成 Component 避免三份重复代码。
    // 网格尺寸（列数/格子宽高）在组件内部按**自身宽度**计算 —— 三个 Tab 的
    // 可见宽度一致，但各自算更稳妥，也不受 pivot 切换时机影响。
    Component {
        id: historyGridComponent

        GridView {
            id: grid
            // all / video / live。由 Loader 在 onLoaded 里注入。
            // 默认空串 → modelOf 返回 null → 注入前不绑定任何模型，
            // 避免「视频」Tab 在 category 就位前闪一下「全部」的数据
            property string category: ""

            anchors.fill: parent
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: FluScrollBar {}

            readonly property int _columns: Math.max(1, Math.floor((width + history_page.minHSpacing) / (Theme.cardWidth + history_page.minHSpacing)))
            readonly property real _cellWidth: _columns > 1 ? width / _columns : width
            readonly property real _displayCardWidth: Math.max(1, _cellWidth - history_page.minHSpacing)
            readonly property real _cellHeight: Math.max(1, _displayCardWidth * Theme.cardAspectRatio + Theme.cardInfoHeight + history_page.vSpacing)

            model: history_page.modelOf(category)

            cellWidth: Math.max(1, _cellWidth)
            cellHeight: Math.max(1, _cellHeight)
            cacheBuffer: Math.max(0, height * 2)
            flow: GridView.LeftToRight
            layoutDirection: Qt.LeftToRight
            verticalLayoutDirection: GridView.TopToBottom

            delegate: Item {
                width: Math.max(1, grid._cellWidth)
                height: Math.max(1, grid._cellHeight)

                HistoryCard {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(1, grid._displayCardWidth - Theme.scrollBarReserve)
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
                            // 番剧统一走 App.openBangumi（视频牌内部会判断有没有真实
                            // bvid：有则按番剧接口取完整信息，无则用 bangumi_<epId> 占位）
                            App.openBangumi(model.bvid || "", model.epId || "", model.seasonId || "", model.title)
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

            onContentYChanged: history_page.checkLoadMore(category, grid)
            onMovementEnded: history_page.checkLoadMore(category, grid)

            // ===== 自动填满当前视口 =====
            // 每个网格自带一个定时器，不靠页面反查"当前可见的是哪个网格"。
            // 触发源：内容高度变化（数据到达/尺寸变化）+ 自身变为可见（切 Tab）。
            // 非重复运行：内容不再变化就不会再触发，空闲时零开销。
            Timer {
                id: gridFillTimer
                interval: 50
                repeat: false
                onTriggered: {
                    if (!grid.visible || !grid.category) return
                    var row = history_page.tabRow(grid.category)
                    if (!row || row.loading || !row.hasMore) return
                    if (grid.model && grid.model.count >= history_page.pageSize * 10) return
                    if (grid.height > 0 && grid.contentHeight <= grid.height + 10) {
                        history_page.loadMore(grid.category)
                    }
                }
            }

            onContentHeightChanged: gridFillTimer.restart()
            onVisibleChanged: if (visible) gridFillTimer.restart()

            // 空状态提示。三个 Tab 各自独立判断，直播记录为空很常见
            FluText {
                anchors.centerIn: parent
                visible: grid.model && grid.model.count === 0
                text: "暂无记录"
                font: FluTextStyle.Body
                color: FluTheme.fontSecondaryColor
            }
        }
    }

    // 三个 Tab 的游标与翻页状态。用 ListModel 而不是 JS 对象：绑定系统
    // 监听不到 JS 对象内部字段的变化，loading/hasMore 改了界面不会刷新。
    ListModel {
        id: tabStateModel
        ListElement { category: "all";   max: 0; viewAt: 0; loading: false; hasMore: true }
        ListElement { category: "video"; max: 0; viewAt: 0; loading: false; hasMore: true }
        ListElement { category: "live";  max: 0; viewAt: 0; loading: false; hasMore: true }
    }

    FluFrame {
        id: historyFrame
        radius: Theme.frameRadius
        anchors.fill: parent
        anchors.leftMargin: Theme.homeFrameLeftMargin
        anchors.rightMargin: Theme.homeFrameRightMargin
        anchors.bottomMargin: Theme.homeFrameBottomMargin
        anchors.topMargin: Theme.homeFrameTopMargin
        padding: Theme.homeFramePadding

        // 排版与首页「推荐/热门」一致：FluFrame + FluPivot
        FluPivot {
            id: historyPivot
            anchors.fill: parent
            anchors.leftMargin: Theme.pivotLeftMargin
            font.pixelSize: FluTextStyle.Title.pixelSize * 2 / 3
            currentIndex: GlobalState.historyPivotIndex

            onCurrentIndexChanged: {
                if (history_page.visible && history_page._pageReady) {
                    history_page._lastPivotIndex = currentIndex
                    GlobalState.historyPivotIndex = currentIndex
                }
                // 懒加载：第一次切到某个 Tab 时才拉它的数据，
                // 避免进页面就同时发三个请求
                var cat = history_page.currentCategory()
                if (!history_page._loadedTabs[cat]) {
                    history_page._loadedTabs[cat] = true
                    history_page.loadMore(cat)
                }
            }

            // 每个 Tab 一个 Loader，加载后把自己的分类注入网格组件。
            // 用 Loader 而不是直接写三份 GridView：组件只维护一处，
            // 而 category 在 onLoaded 里赋值可保证注入前模型绑定为 null，
            // 不会出现「视频」Tab 闪一下「全部」数据的情况
            FluPivotItem {
                title: "全部"
                contentItem: Component {
                    Loader {
                        anchors.fill: parent
                        sourceComponent: historyGridComponent
                        onLoaded: if (item) item.category = "all"
                    }
                }
            }

            FluPivotItem {
                title: "视频"
                contentItem: Component {
                    Loader {
                        anchors.fill: parent
                        sourceComponent: historyGridComponent
                        onLoaded: if (item) item.category = "video"
                    }
                }
            }

            FluPivotItem {
                title: "直播"
                contentItem: Component {
                    Loader {
                        anchors.fill: parent
                        sourceComponent: historyGridComponent
                        onLoaded: if (item) item.category = "live"
                    }
                }
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

    // 视频播放页/直播页/用户主页打开时，兜底拦截滚轮事件，防止其穿透到底层主页滚动视图。



    // 共享弹幕管理器：放在 HistoryPage 层级，不随 LivePlayerPage 销毁/重建。
    // 避免 QWebSocket（SSL 握手线程）频繁创建/销毁导致卡死。
    LiveDanmakuManager {
        id: sharedDanmakuManager
    }

    Item {
        id: liveOverlay
        anchors.fill: historyFrame
        anchors.margins: Theme.playerOverlayMargin
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

    // 页面类型互斥：直播播放器仍留在本页内（不是牌堆里的牌），
    // 其它宿主打开直播时关掉自己这份；视频 / 用户主页已由牌堆统一管理。
    Connections {
        target: GlobalState
        function onPageTypeCloseRequested(type, exceptHost) {
            if (exceptHost === "history") return
            if (type === "live" && history_page.liveVisible) history_page.closeLivePlayer()
        }
    }



    function openLivePlayer(roomId, title, streamer) {
        GlobalState.requestClosePagesOfType("live", "history")
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
        // 记住用户最后选中的 Tab，下次进历史页恢复
        GlobalState.historyPivotIndex = _lastPivotIndex
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
