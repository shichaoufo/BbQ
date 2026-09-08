import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import QtQuick.Effects

import FluentUI 1.0
import BiliQt 1.0
import "../components"

FluPage {
    id: search_page
    title: ""
    launchMode: FluPageType.SingleInstance

    // 搜索状态
    property bool hasSearched: false
    property string submittedKeyword: ""
    property bool loading: false
    property bool hasMore: true
    property bool videoVisible: false
    property int pageSize: Theme.pageSize
    property int _currentPage: 0
    property int _searchRequestId: 0
    property int _pendingRequestId: 0
    // 首页空结果自动重试（B站搜索API偶尔首次返回空结果，重试即可获得数据）
    property bool _firstPageRetryPending: false

    // ====== 搜索类型（与 biliuwp-lite SearchType 对齐，仅实现番剧搜索，其他占位） ======
    // 0=视频, 1=番剧(Anime), 2=直播, 3=用户, 4=影视(Movie)
    property int searchType: 0
    readonly property var _searchTypeLabels: [
        qsTr("视频"),
        qsTr("番剧"),
        qsTr("直播"),
        qsTr("用户"),
        qsTr("影视")
    ]
    // 搜索结果行类型：0=视频行，1=番剧/影视行，2=直播行，3=用户行
    readonly property int resultTypeVideo: 0
    readonly property int resultTypeBangumi: 1
    readonly property int resultTypeLive: 2
    readonly property int resultTypeUser: 3

    // 直播搜索开关
    property bool liveVisible: false
    // 用户主页开关
    property bool userProfileVisible: false

    // 直播卡片布局参数（与视频卡相同尺寸，竖向封面）
    property int liveCardHeight: 0  // 与视频卡相同：cardWidth*9/16+120，运行时在 cellHeight 计算

    // 用户搜索下拉框选项
    readonly property var _userOrderLabels: [
        qsTr("默认排序"),
        qsTr("粉丝数由高到低"),
        qsTr("粉丝数由低到高"),
        qsTr("LV等级由高到低"),
        qsTr("LV等级由低到高")
    ]
    readonly property var _userTypeLabels: [
        qsTr("全部用户"),
        qsTr("UP主"),
        qsTr("普通用户"),
        qsTr("认证用户")
    ]

    // 搜索联想
    property var _suggestWords: []
    property bool _suggestPopupOpen: false
    property int _suggestRequestSeq: 0
    property int _suggestLastRenderedSeq: 0
    // doSearch 防抖（防同一关键词连发导致重复结果）
    property string _lastDoSearchKeyword: ""
    property int _lastDoSearchType: -1
    property string _lastDoSearchFilterSig: ""
    property real _lastDoSearchTs: 0
    property int _pendingSuggestSeq: 0
    // _startSearch 重复触发拦截（比对"上一次真正提交"的 keyword/searchType/pendingRequestId/filterSig 快照）
    property string _lastCommittedKeyword: ""
    property int _lastCommittedSearchType: -1
    property int _lastCommittedRequestId: -1
    property string _lastCommittedFilterSig: ""

    // 当前筛选条件签名（用于区分"同关键词同类型但筛选条件不同"的搜索）
    function currentFilterSig() {
        switch (search_page.searchType) {
        case 0: // 视频
            return "v:" + videoSortCombo.currentIndex + ":" + videoDurationCombo.currentIndex + ":" + videoPartitionCombo.currentIndex
        case 3: // 用户
            return "u:" + userOrderCombo.currentIndex + ":" + userTypeCombo.currentIndex
        default:
            return ""
        }
    }

    // ========== 联想锁定 ==========
    // 用户一旦按回车/点搜索提交，2 秒内联想 API 返回不得再显示下拉，
    // 防止搜索结果出来后又被联想 API 延迟返回的结果开回来。
    property bool _submittedLock: false
    property bool _popupClosePending: false  // 防止 _forceCloseAllVisiblePopups 被多次调用
    property Timer _submittedLockTimer: Timer {
        interval: 1500
        repeat: false
        onTriggered: {
            search_page._submittedLock = false
        }
    }

    // ========== 联想相关 Timer（统一放在顶层，内部/外部都通过 search_page 访问） ==========
    // 300ms 防抖请求联想
    property Timer suggestDebounceTimer: Timer {
        interval: 300
        repeat: false
        onTriggered: search_page._requestSuggest()
    }
    // 失焦后 150ms 清理联想词（防止失焦瞬间竞态重开下拉）
    property Timer suggestCloseTimer: Timer {
        interval: 150
        repeat: false
        onTriggered: {
            if (!searchBox.activeFocus && !searchBox.focus) {
                search_page._suggestWords = []
            }
        }
    }

    // 滚动位置恢复
    property bool _scrollRestored: false
    property bool _pageInitialized: false
    property real _lastContentY: 0
    property bool _sizeValid: search_page.width > 0 && search_page.height > 0

    // 视频卡片布局参数（与 RecommendPage 一致）
    property int cardWidth: Theme.cardWidth
    property int margins: Theme.pageMargins
    property int vSpacing: Theme.pageVSpacing
    property int minHSpacing: Theme.pageHSpacing
    // 番剧卡片布局参数：单独加大横向/纵向间距 + 卡片高度
    property int bangumiVSpacing: 36       // 每行之间间距（纵向）- 再加大
    property int bangumiHSpacing: 28       // 每张卡片之间间距（横向）- 再加大
    property int bangumiCardHeight: 220    // 单行番剧卡片高度（竖向海报 144×216 + padding）
    property int bangumiMinCardWidth: 460  // 单行番剧卡片最小总宽度（封面144 + 间距12 + 右侧信息 要求 >= 300），低于它就降列数

    // 列数（番剧模式、用户模式、视频模式分开算）
    property bool isBangumiMode: search_page.searchType === 1 || search_page.searchType === 4
    // 直播卡片与视频卡片相同列数（竖向封面）
    property bool isLiveMode: search_page.searchType === 2
    // 用户搜索：横向卡片，单列（和番剧类似但更短）
    property bool isUserMode: search_page.searchType === 3
    // 用户卡片布局参数
    property int userVSpacing: 12
    property int userCardHeight: 110  // 单行用户卡片高度（88头像 + 2*10边距≈108）
    property int userMinCardWidth: 380  // 用户卡最小宽度，低于就降列数（基本保持单列）
    property int columns: {
        var gridW = resultGrid.width
        if (gridW <= 0) gridW = search_page.width
        if (isBangumiMode) {
            var bw = bangumiMinCardWidth + bangumiHSpacing
            var cols = Math.max(1, Math.floor((gridW + bangumiHSpacing) / bw))
            return cols
        }
        if (isUserMode) {
            var uw = userMinCardWidth + userVSpacing
            return Math.max(1, Math.floor((gridW + userVSpacing) / uw))
        }
        return Math.max(1, Math.floor((gridW + minHSpacing) / (cardWidth + minHSpacing)))
    }
    property real cellWidth: columns > 1 ? resultGrid.width / columns : resultGrid.width
    // cellHeight 用属性绑定（只在 searchType 变化时重算，避免每次访问都执行函数）
    property real cellHeightValue: {
        var st = search_page.searchType
        if (st === 1 /*番剧*/ || st === 4 /*影视*/) {
            return search_page.bangumiCardHeight + search_page.bangumiVSpacing
        }
        if (st === 3 /*用户*/) {
            return search_page.userCardHeight + search_page.userVSpacing
        }
        return search_page.cardWidth * 9 / 16 + 120
    }
    property real displayCardWidth: Math.max(1, cellWidth - minHSpacing)
    // 番剧模式下的实际卡宽：用 bangumiHSpacing 作为留白
    property real displayCardWidthBangumi: Math.max(1, cellWidth - bangumiHSpacing - (Theme.scrollBarReserve || 0))
    // 用户模式下的实际卡宽
    property real displayCardWidthUser: Math.max(1, cellWidth - userVSpacing - (Theme.scrollBarReserve || 0))

    // 分区 ID 映射（与 biliuwp-lite 一致，使用 B站一级分区 tid）
    property var _regionIds: [0, 1, 4, 3, 129, 36, 188, 234, 155, 5, 181, 13]

    function orderValue(index) {
        switch (index) {
        case 0: return ""          // 综合排序
        case 1: return "click"     // 最多点击
        case 2: return "pubdate"   // 最新发布
        case 3: return "dm"        // 最多弹幕
        case 4: return "stow"      // 最多收藏
        }
        return ""
    }

    function durationValue(index) {
        switch (index) {
        case 0: return ""  // 全部时长
        case 1: return "1" // 10分钟以下
        case 2: return "2" // 10-30分钟
        case 3: return "3" // 30-60分钟
        case 4: return "4" // 60分钟以上
        }
        return ""
    }

    // ====== 与 RecommendPage 对齐的卡片文本格式化工具 ======
    function pad2(n) {
        return n < 10 ? "0" + n : String(n)
    }
    // 把 API 返回的时长（秒数 "396"/396，或格式化串 "06:36"/"1:06:36"）统一解析为秒数。
    // 分钟数可能超过 60 的格式化串（如 "75:30"）也正确折算。
    // 解析为 0 = 无时长数据（课程类 cheese 视频搜索结果不带时长）。
    function parseDurationToSeconds(v) {
        if (typeof v === "string" && v.indexOf(":") !== -1) {
            var parts = v.split(":")
            var total = 0
            for (var i = 0; i < parts.length && i < 3; i++)
                total = total * 60 + (parseInt(parts[i], 10) || 0)
            return total
        }
        return parseInt(v, 10) || 0
    }
    function formatDuration(seconds) {
        var s = parseDurationToSeconds(seconds)
        var h = Math.floor(s / 3600)
        var m = Math.floor((s % 3600) / 60)
        var sec = s % 60
        if (h > 0) return pad2(h) + ":" + pad2(m) + ":" + pad2(sec)
        return pad2(m) + ":" + pad2(sec)
    }
    function formatNumber(num) {
        var n = parseInt(num, 10) || 0
        if (n >= 100000000) return (n / 100000000).toFixed(1) + "亿"
        if (n >= 10000) return (n / 10000).toFixed(1) + "万"
        return String(n)
    }

    function _startSearch(keyword) {
        // ====== 前置拦截：如果这次要搜的 keyword+searchType 与"上一次已真正发起搜索"的相同
        // 且当前 _pendingRequestId>0（说明上一次相同请求还在 pending 或已响应刚处理完），
        // 直接丢弃。彻底解决 Keys.onReturnPressed + onCommit 连续两次间隔>300ms 的重复触发。
        if (keyword === search_page._lastCommittedKeyword
            && search_page.searchType === search_page._lastCommittedSearchType
            && search_page.currentFilterSig() === search_page._lastCommittedFilterSig
            && search_page._pendingRequestId === search_page._lastCommittedRequestId
            && search_page._lastCommittedRequestId > 0) {
            // submittedLock 依然续一下（不然外层 Keys 处理器已开的锁会提前释放）
            search_page._submittedLock = true
            search_page._submittedLockTimer.restart()
            return
        }
        // 所有搜索触发路径统一：关联想 + 打开「提交锁」（防止联想 API 延迟返回把下拉又顶回来）
        search_page._submittedLock = true
        search_page._submittedLockTimer.restart()
        submittedKeyword = keyword
        GlobalState.searchKeyword = keyword
        GlobalState.searchHasSearched = true
        hasSearched = true
        hasMore = true
        loading = false
        _scrollRestored = false
        _currentPage = 0
        _firstPageRetryPending = false

        GlobalState.searchResultModel.clear()
        resultGrid.positionViewAtBeginning()
        resultGrid.contentY = 0
        // 记录本次"已真正提交"的快照（用于后续重复触发拦截）
        search_page._lastCommittedKeyword = keyword
        search_page._lastCommittedSearchType = search_page.searchType
        search_page._lastCommittedFilterSig = search_page.currentFilterSig()
        if (search_page._sizeValid) {
            resultGrid.forceLayout()
            appendSearchResults()
            // appendSearchResults 会把 _searchRequestId+1 并赋给 _pendingRequestId，
            // 所以必须在它之后才能拿到真正的 requestId
            search_page._lastCommittedRequestId = search_page._pendingRequestId
        } else {
            // 尺寸还没就绪（比如刚进入页面立刻触发），保守用 requestId+1 估计
            search_page._lastCommittedRequestId = search_page._searchRequestId
        }
    }

    function doSearch() {
        var keyword = searchBox.text.trim()
        if (keyword === "") return
        // ====== 第一层：submittedLock 期间（刚提交 2 秒内）的完全相同搜索直接丢弃（兜底） ======
        if (search_page._submittedLock
            && keyword === search_page._lastCommittedKeyword
            && search_page.searchType === search_page._lastCommittedSearchType
            && search_page.currentFilterSig() === search_page._lastCommittedFilterSig) {
            return
        }
        // ====== 第二层：防抖：同一关键词+同类型 800ms 内重复点击/回车，直接丢弃
        // 300ms 太窄，onCommit 与 Keys.onReturnPressed 之间若夹杂 Popup 关闭等耗时会超，
        // 改为 800ms 覆盖绝大多数重复触发窗口。
        var nowTs = Date.now()
        if (keyword === search_page._lastDoSearchKeyword
            && search_page.searchType === search_page._lastDoSearchType
            && search_page.currentFilterSig() === search_page._lastDoSearchFilterSig
            && nowTs - search_page._lastDoSearchTs < 800) {
            return
        }
        search_page._lastDoSearchKeyword = keyword
        search_page._lastDoSearchType = search_page.searchType
        search_page._lastDoSearchFilterSig = search_page.currentFilterSig()
        search_page._lastDoSearchTs = nowTs
        // 立刻停掉所有联想相关 Timer：
        // ① debounceTimer 还没触发的直接取消，避免 300ms 后再去请求联想 API
        // ② suggestCloseTimer 也停掉（不需要了，我们直接清空词+锁）
        search_page.suggestDebounceTimer.stop()
        search_page.suggestCloseTimer.stop()
        // 关键：搜索提交瞬间，先清空联想词数组，再开 submittedLock。
        // 1. 清空 _suggestWords，这样就算 debounce 里异步结果
        //    紧接着回来，_applySuggestWords 里的 _suggestWords.length>0 条件也不满足，
        //    不会再调 showSuggest() 把下拉又顶回来。
        // 2. submittedLock 作为第二道保险。
        // 3. _suggestPopupOpen 保留兼容旧代码。
        search_page._suggestWords = []
        search_page._suggestPopupOpen = false
        search_page._startSearch(keyword)
    }

    // ====== 搜索联想 ======
    function _requestSuggest() {
        // 如果用户刚刚提交了搜索（submittedLock 还在）或正在搜索中（loading），
        // 就直接不请求联想，避免与搜索请求竞态（API 结果返回后会把下拉又顶回来）。
        if (search_page._submittedLock || search_page.loading) return
        var txt = searchBox.text.trim()
        if (txt === "") {
            search_page._suggestWords = []
            search_page._suggestPopupOpen = false
            return
        }
        search_page._suggestRequestSeq++
        var curSeq = search_page._suggestRequestSeq
        // 在 QML 里记录 seq，当 API 返回后如果不是最新的 seq 就丢弃
        search_page._pendingSuggestSeq = curSeq
        Api.getSearchSuggest(txt)
    }

    // 强关搜索联想下拉 Popup（不管它挂在 Overlay 上还是 Window 上，彻底扫）。
    // 背景：FluAutoSuggestBox 内部 control_popup 是 QQC2 Popup，挂在 Overlay.overlay。
    // 但附加属性语法的正确性在 Qt 不同版本里差异很大，Overlay.overlay 有时能拿到有时拿不到。
    // 做法：以 Window.window 为根，把 4 条路径全扫一遍：
    //        1) Window.contentItem.data  (普通 UI 元素)
    //        2) Window.data              (全局声明的 QObject)
    //        3) 每个扫描到的对象再附加扫它的 parent() 上去 (防止父子层级差异)
    //        4) 尝试对 Window 和所有 Item 调 Overlay.overlay 附加属性
    function _forceCloseAllVisiblePopups() {
        var win = null
        try { win = Window.window } catch(e) { win = null }
        if (!win) {
            try { win = search_page.window } catch(e) { win = null }
        }
        if (!win) {
            return
        }

        var stack = []
        // 路径 1: 标准 UI 元素
        try { if (win.contentItem && win.contentItem.data) stack.push(win.contentItem.data) } catch(e) {}
        // 路径 2: 全局声明的 data 列表
        try { if (win.data) stack.push(win.data) } catch(e) {}
        // 路径 3: 尝试附加属性方式拿 Overlay.overlay
        try {
            var overlay = null
            try { overlay = win.Overlay ? win.Overlay.overlay : null } catch(e) { overlay = null }
            if (overlay) stack.push([overlay])
        } catch(e) {}
        try {
            var overlay2 = null
            try { overlay2 = search_page.Overlay ? search_page.Overlay.overlay : null } catch(e) { overlay2 = null }
            if (overlay2 && overlay2 !== (win.Overlay ? win.Overlay.overlay : null)) stack.push([overlay2])
        } catch(e) {}

        // 把 stack 数组内的子数组/列表扁平化到对象栈
        var objStack = []
        for (var k = 0; k < stack.length; k++) {
            var arr = stack[k]
            if (!arr) continue
            try {
                for (var kk = 0; kk < arr.length; kk++) {
                    objStack.push(arr[kk])
                }
            } catch(e) {}
        }
        // 再把 window 自己作为对象加进去（有些 Popup 挂在 window 的直接 data）
        objStack.push(win)

        var visited = []
        var closedCount = 0
        while (objStack.length > 0) {
            var obj = objStack.pop()
            if (!obj) continue
            var skip = false
            for (var i2 = 0; i2 < visited.length; i2++) {
                if (visited[i2] === obj) { skip = true; break }
            }
            if (skip) continue
            visited.push(obj)

            // 判断是否是可见的 Popup: visible=true 是硬门槛；
            // hasOpen + hasClose 是标准 Popup；
            // looksPopup（有 opened/modal 属性）+ hasClose 用来兜底 FluentUI 自定义 Popup
            var isVisible = false
            try { isVisible = obj.visible } catch(e) { isVisible = false }
            var hasClose = false
            try { hasClose = typeof obj.close === "function" } catch(e) { hasClose = false }
            var hasOpen = false
            try { hasOpen = typeof obj.open === "function" } catch(e) { hasOpen = false }
            var looksPopup = false
            try { looksPopup = (typeof obj.opened === "boolean") || ("modal" in obj) } catch(e) {}
            if (isVisible && hasClose && (hasOpen || looksPopup)) {
                try {
                    obj.close()
                    closedCount++
                } catch(e) {}
            }
            // 推入 children / data / parent
            var childLists = []
            try { if (obj.children) childLists.push(obj.children) } catch(e) {}
            try { if (obj.data) childLists.push(obj.data) } catch(e) {}
            try {
                var contentData = obj.contentItem ? (obj.contentItem.data ? obj.contentItem.data : null) : null
                if (contentData) childLists.push(contentData)
            } catch(e) {}
            for (var i3 = 0; i3 < childLists.length; i3++) {
                var list = childLists[i3]
                try {
                    for (var j = 0; j < list.length; j++) {
                        objStack.push(list[j])
                        // 顺便把每个子对象的 parent() 也推一次（兜底漏网层级）
                        try {
                            var p = list[j].parent
                            if (p) objStack.push(p)
                        } catch(e) {}
                    }
                } catch(e) {}
            }
            // 当前对象本身的 parent 也要推
            try {
                var p = obj.parent
                if (p) objStack.push(p)
            } catch(e) {}
        }
    }

    function _applySuggestWords(words) {
        // 忽略过期的返回
        if (search_page._suggestLastRenderedSeq > 0
                && search_page._pendingSuggestSeq < search_page._suggestLastRenderedSeq) {
            return
        }
        search_page._suggestLastRenderedSeq = search_page._pendingSuggestSeq
        search_page._suggestWords = words ? words : []
        if (search_page._submittedLock || search_page.loading) {
            return
        }
        // 关键：异步联想结果回来后，必须再调用一次 FluAutoSuggestBox 暴露的 showSuggest()
        // （FluentUI 源码 FluAutoSuggestBox.qml L164 是 public function），原因：
        //   1. 内部 list_view.model 只在 showSuggest() 里通过 d.loadData() 重新过滤赋值；
        //      异步 items 绑定变化不会自动触发 list_view.model 更新。
        //   2. 打字瞬间 onTextChanged 立刻调了 showSuggest()，但那时 _suggestWords 还是空，
        //      list_view.model 被设成 []，visible=true，下拉就空着摆在那儿。
        //   3. 用户"删一个字再打字"之所以能出词，是因为又触发了一次 onTextChanged→showSuggest。
        // 这里用 Qt.callLater 在下一帧让 items 绑定完成后再 showSuggest，避免时序竞态。
        if (searchBox && searchBox.text.trim() !== ""
                && search_page._suggestWords && search_page._suggestWords.length > 0) {
            Qt.callLater(function() {
                if (search_page._submittedLock || search_page.loading) return
                searchBox.showSuggest()
            })
        }
    }

    function doRefreshSearch() {
        if (submittedKeyword === "") return
        searchBox.text = submittedKeyword
        _startSearch(submittedKeyword)
    }

    // 首页空结果自动重试：B站搜索API偶尔首次返回空结果（code:0但result为空），
    // 手动重试即可获得数据。此处自动重试一次，避免用户需要手动重试。
    // 返回 true 表示已触发重试（调用方应跳过后续的 hasMore=false 等状态更新）。
    function _retryIfEmptyFirstPage(added, typeName) {
        if (added > 0) return false
        if (_currentPage !== 1) return false       // 仅首页（_currentPage 在响应处理中已 ++）
        if (_firstPageRetryPending) return false    // 已重试过，不再重试
        _firstPageRetryPending = true
        _currentPage = 0
        hasMore = true
        loading = false
        // 延迟 300ms 重试，给服务器一点缓冲时间
        Qt.callLater(function() {
            if (search_page._firstPageRetryPending) {
                search_page.appendSearchResults()
            }
        })
        return true
    }

    function appendSearchResults() {
        if (loading || !hasMore) return
        if (submittedKeyword === "") return
        loading = true
        _searchRequestId++
        _pendingRequestId = _searchRequestId
        var nextPage = _currentPage + 1
        switch (search_page.searchType) {
        case 0: { // 视频
            var order = search_page.orderValue(videoSortCombo.currentIndex)
            var duration = search_page.durationValue(videoDurationCombo.currentIndex)
            var region = _regionIds[videoPartitionCombo.currentIndex]
            Api.searchVideos(submittedKeyword, nextPage, order, duration, region)
            break
        }
        case 1: // 番剧
            Api.searchBangumi(submittedKeyword, nextPage, false)
            break
        case 4: // 影视（复用番剧接口，search_type=media_ft）
            Api.searchBangumi(submittedKeyword, nextPage, true)
            break
        case 2: // 直播
            Api.searchLive(submittedKeyword, nextPage)
            break
        case 3: { // 用户搜索
            var orderType = 0
            try { orderType = userOrderCombo ? userOrderCombo.currentIndex : 0 } catch (e) { orderType = 0 }
            var userType = 0
            try { userType = userTypeCombo ? userTypeCombo.currentIndex : 0 } catch (e) { userType = 0 }
            Api.searchUser(submittedKeyword, nextPage, orderType, userType)
            break
        }
        default:
            loading = false
            hasMore = false
            // 空结果，给用户一个可点击的占位提示（通过清空 model 显示初始态的"No Results"，此处直接 return）
            return
        }
    }

    function appendSearchData(data, requestId) {
        if (requestId !== _pendingRequestId || _pendingRequestId < 0) {
            return
        }
        try {
            var dataStr = typeof data === "string" ? data : data.toString()
            var resp = JSON.parse(dataStr)
            if (resp.code !== 0 || !resp.data) {
                console.warn("[SearchPage] search API error, code:", resp.code, "msg:", resp.message)
                hasMore = false
                loading = false
                return
            }
            var result = resp.data.result || []
            var added = 0
            // ====== 结果去重（B站视频搜索有时返回重复 item，且重复触发 doSearch 会重复 append） ======
            var existingVideo = {}
            try {
                for (var jv = 0; jv < GlobalState.searchResultModel.count; jv++) {
                    var rv = GlobalState.searchResultModel.get(jv)
                    if (!rv || (rv.searchType !== undefined && rv.searchType !== search_page.resultTypeVideo)) continue
                    var vkey = (rv.bvid ? ("b" + rv.bvid) : "") + "|" + (rv.aid ? ("a" + rv.aid) : "")
                    if (vkey !== "|") existingVideo[vkey] = true
                }
            } catch (e) { existingVideo = {} }
            for (var i = 0; i < result.length; i++) {
                var item = result[i]
                if (!item) continue
                // 课程类（cheese 付费课）视频：搜索 API 不返回时长（解析为 0），
                // 播放需独立的课程 API + 购买校验，客户端无法播放，直接过滤
                if (search_page.parseDurationToSeconds(item.duration) <= 0) continue
                var bvid = item.bvid || ""
                var aid = item.aid ? String(item.aid) : ""
                var vdedupe = (bvid ? ("b" + bvid) : "") + "|" + (aid ? ("a" + aid) : "")
                if (vdedupe !== "|" && existingVideo[vdedupe]) continue
                if (vdedupe !== "|") existingVideo[vdedupe] = true
                var title = item.title || ""
                title = title.replace(/<[^>]+>/g, "")
                var cover = item.pic || ""
                if (cover && cover.indexOf("http") !== 0) {
                    cover = "https:" + cover
                }
                var playStr = item.play || 0
                var playsRaw = (typeof playStr === "string" && playStr.indexOf("--") !== -1) ? 0 : Number(playStr) || 0
                var plays = search_page.formatNumber(playsRaw)
                var danmuRaw = Number(item.video_review || item.danmaku || 0) || 0
                var danmu = search_page.formatNumber(danmuRaw)
                var duration = search_page.formatDuration(item.duration || 0)
                var pubDate = item.pubdate || 0
                var author = item.author || ""
                var mid = item.mid ? String(item.mid) : ""
                GlobalState.searchResultModel.append({
                    bvid: bvid,
                    aid: aid,
                    title: title,
                    cover: cover,
                    plays: plays,
                    danmu: danmu,
                    duration: duration,
                    author: author,
                    mid: mid,
                    pubDate: GlobalState.formatVideoCardTime(pubDate)
                })
                added++
            }
            // 不再续 submittedLock：doSearch 初始 1500ms 锁已覆盖联想 API 延迟返回窗口，
            // 且 _applySuggestWords/_requestSuggest 已增加 loading 检查，搜索中不会显示联想。
            // 续锁反而会阻止用户立即重新搜索（串行多页加载时锁累积可达数秒）。
            _currentPage++
            if (_retryIfEmptyFirstPage(added, "video")) return
            hasMore = added > 0 && _currentPage < 50
        } catch (e) {
            console.warn("[SearchPage] parse search data failed:", e)
            hasMore = false
            loading = false
            return
        }
        loading = false
        if (hasMore && _sizeValid) {
            var needsMore = resultGrid.contentHeight <= resultGrid.height + 100
            if (needsMore) appendSearchResults()
        }
    }

    // ====== 番剧/影视搜索结果解析（对齐 biliuwp-lite SearchAnimeItem） ======
    // data.result[].season_id / media_id / title / cover / areas / cv / styles / desc /
    //                pubtime / season_type_name / angle_title(会员角标) / showBadge
    function _bangumiFlattenArrayToString(val, sep) {
        // 兼容 string / number / array / 嵌套对象：["日本","国产"] / [{name:"东京动画"}] / "日本"
        if (val === undefined || val === null || val === "") return ""
        if (typeof val === "string") return val
        if (typeof val === "number" || typeof val === "boolean") return String(val)
        if (Array.isArray(val)) {
            var arr = []
            for (var i = 0; i < val.length; i++) {
                var v = val[i]
                if (v === undefined || v === null) continue
                if (typeof v === "string") { if (v !== "") arr.push(v); continue }
                if (typeof v === "number" || typeof v === "boolean") { arr.push(String(v)); continue }
                if (typeof v === "object") {
                    // 常见结构：{name: "日本"} / {area_name: "日本"} / {title: "奇幻"}
                    var sub = (v.name !== undefined && v.name !== "") ? v.name
                            : (v.area_name !== undefined && v.area_name !== "") ? v.area_name
                            : (v.style_name !== undefined && v.style_name !== "") ? v.style_name
                            : (v.staff_name !== undefined && v.staff_name !== "") ? v.staff_name
                            : (v.title !== undefined && v.title !== "") ? v.title
                            : ""
                    if (sub === "" && typeof v.toString === "function") {
                        try {
                            var t = v.toString()
                            if (t && typeof t === "string" && t.indexOf("[object") !== 0) sub = t
                        } catch(e) {}
                    }
                    if (sub !== "") arr.push(String(sub))
                }
            }
            if (sep === undefined) sep = "、"
            return arr.join(sep)
        }
        if (typeof val === "object") {
            // 纯对象也兜底
            var keys = Object.keys(val)
            if (keys.length === 1) return search_page._bangumiFlattenArrayToString(val[keys[0]], sep)
            var str = ""
            try { str = JSON.stringify(val) } catch(e) {}
            if (str && str.length < 80 && str.indexOf("{") !== 0) return str
            return search_page._bangumiFlattenArrayToString(
                [val.name, val.area_name, val.style_name, val.staff_name, val.title].filter(function(x){ return x && x !== "" }),
                sep)
        }
        try { return String(val) } catch(e) { return "" }
    }

    function appendSearchBangumiData(data, requestId, isMovie) {
        if (requestId !== _pendingRequestId) {
            return
        }
        try {
            var dataStr = typeof data === "string" ? data : data.toString()
            var resp = JSON.parse(dataStr)
            if (resp.code !== 0 || !resp.data) {
                console.warn("[SearchPage] bangumi search API error, code:", resp.code, "msg:", resp.message,
                             "first 500 chars:", dataStr ? dataStr.substring(0, 500) : "")
                hasMore = false
                loading = false
                return
            }
            var result = resp.data.result || []
            var numPages = resp.data.numPages !== undefined ? parseInt(resp.data.numPages, 10) : 1
            var added = 0
            // ====== 调试：空结果时打印原始响应前 1500 字符（排查 areas/styles/cv 结构 & 为什么有时候 0 条） ======
            if (result.length === 0) {
                var rawPreview = (dataStr && dataStr.length > 1500)
                                  ? (dataStr.substring(0, 1500) + "...<truncated, total=" + dataStr.length + ">")
                                  : (dataStr || "")
                console.warn("[SearchPage] bangumi search returned empty result. requestId=", requestId,
                             "isMovie=", isMovie,
                             "page=", _currentPage + 1,
                             "keyword=", JSON.stringify(submittedKeyword),
                             "data.preview:", rawPreview)
            } else {
                // 打印首条 item 的完整 JSON（不截断），用于排查「有些番剧点击无法正常加载」的原因
                try {
                    var it0 = result[0]
                    var rawIt = JSON.stringify(it0)
                    var MAX = 3500
                    var preview = (rawIt && rawIt.length > MAX)
                                    ? (rawIt.substring(0, MAX) + "...<truncated total=" + rawIt.length + ">")
                                    : (rawIt || "")
                } catch (e) {
                    console.warn("[SearchPage] failed to stringify first bangumi item:", e)
                }
            }
            // 结果去重（B站有时返回重复 item，且两次请求竞态也会重复 append）
            var existingBangumi = {}
            try {
                for (var j = 0; j < GlobalState.searchResultModel.count; j++) {
                    var row = GlobalState.searchResultModel.get(j)
                    if (!row || row.searchType !== search_page.resultTypeBangumi) continue
                    var key = (row.seasonId ? ("s" + row.seasonId) : "")
                           + "|" + (row.mediaId ? ("m" + row.mediaId) : "")
                           + "|" + row.title
                    existingBangumi[key] = true
                }
            } catch (e) { existingBangumi = {} }
            for (var i = 0; i < result.length; i++) {
                var item = result[i]
                if (!item) continue

                var titleRaw = item.title || ""
                // B站返回 title 中含有 <em class="keyword">...</em> 高亮，像 biliuwp-lite 一样去掉
                var titleClean = titleRaw
                    .replace(/<em class="keyword">/g, "")
                    .replace(/<\/em>/g, "")
                    .replace(/<[^>]+>/g, "")

                var cover = item.cover || item.pic || ""
                if (cover && cover.indexOf("http") !== 0 && cover !== "") {
                    cover = "https:" + cover
                }
                var seasonId = item.season_id ? String(item.season_id) : ""
                var mediaId = item.media_id ? String(item.media_id) : ""
                var epId = item.ep_id ? String(item.ep_id) : ""
                // ====== 主动从 episode 列表中抽取首集的 ep_id / aid / cid / bvid ======
                // 凡人修仙传这类「new_ep=null」「顶层 ep_id 不存在」的番剧，只传 seasonId 进入
                // VideoPlayerPage 时可能无法直接命中播放接口；因此主动在 item 内嵌的 episode
                // 列表里找首集 ep_id，成功率更高。
                // 提取顺序（和 biliuwp-lite / 官方 web 一致）：
                //  1) item.episodes / item.public_episodes / item.user_status.episodes
                //  2) item.modules[i].data.episodes  / item.modules[i].episodes
                //  3) item.result[i].episodes（偶见二级结果里带，兜底）
                var firstEpBvid = ""
                var firstEpAid = ""
                var firstEpCid = ""
                try {
                    var candidateLists = []
                    if (item.episodes) candidateLists.push(item.episodes)
                    if (item.public_episodes) candidateLists.push(item.public_episodes)
                    if (item.user_status && item.user_status.episodes) candidateLists.push(item.user_status.episodes)
                    if (Array.isArray(item.modules)) {
                        for (var mi = 0; mi < item.modules.length; mi++) {
                            var mod = item.modules[mi]
                            if (!mod) continue
                            if (mod.data && mod.data.episodes) candidateLists.push(mod.data.episodes)
                            if (mod.episodes) candidateLists.push(mod.episodes)
                            if (Array.isArray(mod.data)) candidateLists.push(mod.data)
                        }
                    }
                    if (Array.isArray(item.data)) candidateLists.push(item.data)
                    if (Array.isArray(item.result)) candidateLists.push(item.result)
                    // 遍历每个候选 list，找到第一个有 ep_id 的项
                    for (var li = 0; li < candidateLists.length; li++) {
                        var list = candidateLists[li]
                        if (!list || !Array.isArray(list)) continue
                        for (var ei = 0; ei < list.length; ei++) {
                            var ep = list[ei]
                            if (!ep) continue
                            var eid = ep.ep_id || ep.epid || ep.episode_id || ep.id
                            if (eid) {
                                if (epId === "") epId = String(eid)
                                if (firstEpAid === "" && (ep.aid || ep.arc_aid)) firstEpAid = String(ep.aid || ep.arc_aid)
                                if (firstEpCid === "" && (ep.cid || ep.page_cid || ep.danmaku))
                                    firstEpCid = String(ep.cid || ep.page_cid || ep.danmaku)
                                if (firstEpBvid === "" && ep.bvid) firstEpBvid = String(ep.bvid)
                                break
                            }
                        }
                        if (epId !== "") break
                    }
                } catch (e) {
                    console.warn("[SearchPage] extract first ep fields error:", e)
                    epId = epId || ""
                }
                // 基于 (seasonId, mediaId, title) 做去重 key（B站番剧搜索 media_bangumi 通常都有 season_id 或 media_id）
                var dedupeKey = (seasonId ? ("s" + seasonId) : "")
                              + "|" + (mediaId ? ("m" + mediaId) : "")
                              + "|" + titleClean
                if (existingBangumi[dedupeKey]) continue
                existingBangumi[dedupeKey] = true
                // 番剧类型名：优先用 season_type_name（字符串），再用 season_type（整数对应编码名）
                var seasonTypeName = ""
                if (item.season_type_name !== undefined && String(item.season_type_name) !== "") {
                    seasonTypeName = String(item.season_type_name)
                } else if (item.season_type !== undefined && String(item.season_type) !== "") {
                    seasonTypeName = String(item.season_type)
                } else {
                    seasonTypeName = isMovie ? qsTr("影视") : qsTr("番剧")
                }
                // areas/styles/cv：兼容 B站返回 数组 / 对象 / 字符串三种结构
                var areas = search_page._bangumiFlattenArrayToString(item.areas, "、")
                if (areas === "" && item.area !== undefined && String(item.area) !== "") areas = String(item.area)
                var cv = search_page._bangumiFlattenArrayToString(item.cv, "、")
                if (cv === "" && item.casts !== undefined) cv = search_page._bangumiFlattenArrayToString(item.casts, "、")
                if (cv === "" && item.staff_list !== undefined) cv = search_page._bangumiFlattenArrayToString(item.staff_list, "、")
                var styles = search_page._bangumiFlattenArrayToString(item.styles, "、")
                if (styles === "" && item.style !== undefined && String(item.style) !== "") styles = String(item.style)
                if (styles === "" && item.tags !== undefined) styles = search_page._bangumiFlattenArrayToString(item.tags, "、")
                var desc = item.desc || item.description || item.brief || ""
                var pubtime = item.pubtime || item.pub_date_ts || item.publish || 0
                // ====== 角标：会员/大会员/独播 等标签才显示；「13 / 全12 / 已完结」这种集数信息不显示 ======
                // B站番剧搜索 media_bangumi 返回可能同时有 angle_title / badge / corner / labels[]，
                // 也可能把集数塞到 badge（凡人修仙传的 badge="13"，角标就显示成了"13"）。
                var angleTitle = ""
                var showBadge = false
                try {
                    // 1) 候选池：依次从 labels/badges(数组)、badge、angle_title、corner、label 取
                    var rawCandidates = []
                    if (item.labels !== undefined) rawCandidates.push(item.labels)
                    if (item.badges !== undefined) rawCandidates.push(item.badges)
                    if (item.badge !== undefined) rawCandidates.push(item.badge)
                    if (item.angle_title !== undefined) rawCandidates.push(item.angle_title)
                    if (item.corner !== undefined) rawCandidates.push(item.corner)
                    if (item.label !== undefined) rawCandidates.push(item.label)
                    var flatText = search_page._bangumiFlattenArrayToString(rawCandidates, "|||")
                    var candidates = flatText ? flatText.split("|||") : []
                    // 会员关键字白名单（只匹配这些词，避免把集数"13"当角标）
                    var vipKeywords = ["会员", "大会员", "vip", "VIP", "付费", "独家", "独播", "抢先", "限免"]
                    // 2) 遍历找第一个命中关键字的候选
                    for (var ci = 0; ci < candidates.length; ci++) {
                        var t = (candidates[ci] !== undefined && candidates[ci] !== null) ? String(candidates[ci]).trim() : ""
                        if (t === "") continue
                        // 纯数字（集数）、含"话/集/全/完结/更新/已"的、或长度>=20 这种长描述，直接跳过
                        if (/^\d+$/.test(t)) continue
                        if (/话|集|已|全|完结|更新|上映|播出/.test(t)) continue
                        if (t.length > 15) continue
                        // 关键词命中
                        for (var ki = 0; ki < vipKeywords.length; ki++) {
                            if (t.indexOf(vipKeywords[ki]) >= 0) {
                                angleTitle = t
                                showBadge = true
                                break
                            }
                        }
                        if (showBadge) break
                    }
                } catch (e) { angleTitle = ""; showBadge = false }
                // 评分（部分结果在 rating 字段）：如 item.rating 是数字（9.6），或对象 {score: "9.6", count: "xx万人评分"}
                var scoreVal = 0
                try {
                    if (typeof item.rating === "number") scoreVal = item.rating
                    else if (item.rating && typeof item.rating.score !== undefined) {
                        scoreVal = parseFloat(item.rating.score) || 0
                    } else if (typeof item.score === "number") {
                        scoreVal = item.score
                    } else if (item.rating_score !== undefined) {
                        scoreVal = parseFloat(item.rating_score) || 0
                    }
                } catch (e) { scoreVal = 0 }
                // 追番数（favorites / follow_count）
                var followRaw = 0
                try {
                    if (item.favorites !== undefined) followRaw = parseInt(item.favorites, 10)
                    else if (item.follow_count !== undefined) followRaw = parseInt(item.follow_count, 10)
                    else if (item.stat && item.stat.follow) followRaw = parseInt(item.stat.follow, 10)
                } catch (e) { followRaw = 0 }
                var followCount = search_page.formatNumber(followRaw)
                // 最新更新：item.new_ep / item.progress / item.update_info
                var updateInfo = ""
                try {
                    if (item.new_ep !== undefined && item.new_ep !== null) {
                        if (typeof item.new_ep === "string") updateInfo = item.new_ep
                        else if (item.new_ep.index_show) updateInfo = String(item.new_ep.index_show)
                        else if (item.new_ep.title) updateInfo = String(item.new_ep.title)
                    }
                    if (updateInfo === "" && item.progress !== undefined && String(item.progress) !== "") {
                        updateInfo = String(item.progress)
                    }
                    if (updateInfo === "" && item.update_info !== undefined && String(item.update_info) !== "") {
                        updateInfo = String(item.update_info)
                    }
                    if (updateInfo === "") {
                        // 完结 / 全话兜底：is_finish 为 true / 1，或者有 total_* 数字
                        var isFinish = (item.is_finish === true || item.is_finish === 1
                                        || (item.is_finished !== undefined && (item.is_finished === true || item.is_finished === 1)))
                        var total = item.total_count || item.total_ep_count || item.total || item.total_ep || 0
                        if (total && Number(total) > 0) {
                            if (isFinish) updateInfo = qsTr("全") + String(total) + qsTr("话")
                            else if (item.now_ep_count !== undefined && Number(item.now_ep_count) > 0)
                                updateInfo = qsTr("更新至第") + String(item.now_ep_count) + qsTr("话")
                            else if (item.new_ep_count !== undefined && Number(item.new_ep_count) > 0)
                                updateInfo = qsTr("更新至第") + String(item.new_ep_count) + qsTr("话")
                            else
                                updateInfo = qsTr("共") + String(total) + qsTr("话")
                        }
                    }
                } catch (e) { updateInfo = "" }

                // bvid/aid/cid：从 item 顶层或首集 episode 里能拿就拿——VideoPlayerPage 有这些字段时
                // 会走更短的"普通视频播放"路径，不必依赖 season 详情接口，对"部分番剧无法播放"有显著改善
                var bangumiBvid = firstEpBvid !== "" ? firstEpBvid : (item.bvid ? String(item.bvid) : "")
                var bangumiAid  = firstEpAid  !== "" ? firstEpAid  : (item.aid  ? String(item.aid)  : (item.archive && item.archive.aid ? String(item.archive.aid) : ""))
                var bangumiCid  = firstEpCid  !== "" ? firstEpCid  : (item.cid  ? String(item.cid)  : "")

                GlobalState.searchResultModel.append({
                    searchType: search_page.resultTypeBangumi,
                    searchMovie: isMovie,
                    seasonId: seasonId,
                    mediaId: mediaId,
                    epId: epId,
                    bvid: bangumiBvid,
                    aid: bangumiAid,
                    cid: bangumiCid,
                    title: titleClean,
                    cover: cover,
                    seasonTypeName: seasonTypeName,
                    areas: areas,
                    cv: cv,
                    styles: styles,
                    desc: desc,
                    pubDate: pubtime ? GlobalState.formatVideoCardTime(pubtime) : "",
                    angleTitle: angleTitle,
                    showBadge: showBadge,
                    score: scoreVal,
                    followCount: followCount,
                    updateInfo: updateInfo,
                    // 与 VideoCard 番剧模式的字段名对齐
                    isBangumiCard: true
                })
                added++
            }
            _currentPage++
            if (_retryIfEmptyFirstPage(added, isMovie ? "movie" : "bangumi")) return
            hasMore = added > 0 && _currentPage < numPages && _currentPage < 50
        } catch (e) {
            console.warn("[SearchPage] parse bangumi search data failed:", e)
            hasMore = false
            loading = false
            return
        }
        loading = false
        if (hasMore && _sizeValid) {
            var needsMoreBg = resultGrid.contentHeight <= resultGrid.height + 100
            if (needsMoreBg) appendSearchResults()
        }
    }

    function appendSearchLiveData(data, requestId) {
        if (requestId !== _pendingRequestId || _pendingRequestId < 0) {
            return
        }
        try {
            var dataStr = typeof data === "string" ? data : data.toString()
            var resp = JSON.parse(dataStr)
            if (resp.code !== 0 || !resp.data) {
                console.warn("[SearchPage] live search API error, code:", resp.code, "msg:", resp.message)
                hasMore = false
                loading = false
                return
            }
            var result = resp.data.result || []
            var numPages = (resp.data && resp.data.numResults !== undefined)
                               ? Math.ceil(Number(resp.data.numResults) / Math.max(1, pageSize))
                               : (resp.data && resp.data.numPages !== undefined ? Number(resp.data.numPages) : 0)
            if (!numPages && resp.data && resp.data.seid !== undefined) numPages = 100

            var added = 0
            // ====== 结果去重（兜底：B站直播搜索有时返回重复 item，且多次请求竞态/重复触发也会重复 append） ======
            var existingLive = {}
            try {
                for (var jl = 0; jl < GlobalState.searchResultModel.count; jl++) {
                    var rl = GlobalState.searchResultModel.get(jl)
                    if (!rl || rl.searchType !== search_page.resultTypeLive) continue
                    if (rl.roomId) existingLive[String(rl.roomId)] = true
                }
            } catch (e) { existingLive = {} }
            for (var i = 0; i < result.length; i++) {
                var item = result[i]
                if (!item) continue

                // 直播间房间号（id / roomid），播放用
                var roomId = (item.roomid !== undefined && item.roomid !== null && String(item.roomid) !== "")
                                 ? String(item.roomid)
                                 : (item.id !== undefined ? String(item.id) : "")
                if (roomId === "") continue

                // 去重 key：roomId（直播间号全局唯一）
                if (existingLive[roomId]) continue
                existingLive[roomId] = true

                // 标题
                var titleClean = ""
                try {
                    var rawTitle = item.title || item.name || ""
                    if (typeof rawTitle === "string") {
                        titleClean = rawTitle.replace(/<[^>]*>/g, "")
                    } else {
                        titleClean = String(rawTitle || "")
                    }
                } catch (e) { titleClean = "" }

                // 主播名
                var unameClean = ""
                try {
                    var unameRaw = item.uname || item.user_name || item.up_uname || (item.up_info && item.up_info.uname) || ""
                    if (typeof unameRaw === "string") {
                        unameClean = unameRaw.replace(/<[^>]*>/g, "")
                    } else {
                        unameClean = String(unameRaw || "")
                    }
                } catch (e) { unameClean = "" }

                // 封面：user_cover > cover > system_cover > pic
                var cover = ""
                if (item.user_cover !== undefined && String(item.user_cover) !== "") cover = String(item.user_cover)
                else if (item.cover !== undefined && String(item.cover) !== "") cover = String(item.cover)
                else if (item.system_cover !== undefined && String(item.system_cover) !== "") cover = String(item.system_cover)
                else if (item.pic !== undefined && String(item.pic) !== "") cover = String(item.pic)
                if (cover && cover.indexOf("http") !== 0 && cover !== "") {
                    cover = "https:" + cover
                }

                // 人气（观看人数）
                var online = 0
                if (item.online !== undefined && !isNaN(Number(item.online))) online = Number(item.online)
                else if (item.attentions !== undefined && !isNaN(Number(item.attentions))) online = Number(item.attentions)
                function fmtOnline(n) {
                    var num = parseInt(n, 10) || 0
                    if (num >= 100000000) return (num / 100000000).toFixed(1) + "亿"
                    if (num >= 10000) return (num / 10000).toFixed(1) + "万"
                    return String(num)
                }

                // 直播状态：live_status（0=未开播，1=直播中，2=轮播）
                var liveStatus = 0
                if (item.live_status !== undefined) liveStatus = Number(item.live_status)
                else if (item.live_screen !== undefined) liveStatus = item.live_screen ? 1 : 0
                var isLiveNow = (liveStatus === 1) || (item.live === true)

                // 分区名（area_name / area_v2_name / cate_name）
                var areaName = ""
                if (item.area_name !== undefined) areaName = String(item.area_name)
                else if (item.area_v2_name !== undefined) areaName = String(item.area_v2_name)
                else if (item.cate_name !== undefined) areaName = String(item.cate_name)

                GlobalState.searchResultModel.append({
                    searchType: search_page.resultTypeLive,
                    roomId: roomId,
                    title: titleClean,
                    uname: unameClean,
                    cover: cover,
                    online: online,
                    onlineText: fmtOnline(online),
                    liveStatus: liveStatus,
                    isLiveNow: isLiveNow,
                    areaName: areaName,
                    face: (item.face !== undefined) ? String(item.face) : (item.uface !== undefined ? String(item.uface) : ""),
                    uid: (item.uid !== undefined) ? String(item.uid) : (item.mid !== undefined ? String(item.mid) : "")
                })
                added++
            }
            _currentPage++
            if (_retryIfEmptyFirstPage(added, "live")) return
            hasMore = added > 0 && _currentPage < numPages && _currentPage < 50
        } catch (e) {
            console.warn("[SearchPage] parse live search data failed:", e)
            hasMore = false
            loading = false
            return
        }
        loading = false
        if (hasMore && _sizeValid) {
            var needsMore = resultGrid.contentHeight <= resultGrid.height + 100
            if (needsMore) appendSearchResults()
        }
    }

    // ====== 用户搜索结果解析 ==========
    function appendSearchUserData(data, requestId) {
        if (requestId !== _pendingRequestId || _pendingRequestId < 0) {
            return
        }
        try {
            var dataStr = typeof data === "string" ? data : data.toString()
            var resp = JSON.parse(dataStr)
            if (resp.code !== 0 || !resp.data) {
                console.warn("[SearchPage] user search API error, code:", resp.code, "msg:", resp.message)
                hasMore = false
                loading = false
                return
            }
            var result = resp.data.result || []
            var numPages = (resp.data && resp.data.numResults !== undefined)
                               ? Math.ceil(Number(resp.data.numResults) / Math.max(1, pageSize))
                               : (resp.data && resp.data.numPages !== undefined ? Number(resp.data.numPages) : 0)
            if (!numPages && resp.data && resp.data.seid !== undefined) numPages = 100

            var added = 0
            // ====== 结果去重（按 mid 去重） ======
            var existingUser = {}
            try {
                for (var ju = 0; ju < GlobalState.searchResultModel.count; ju++) {
                    var ru = GlobalState.searchResultModel.get(ju)
                    if (!ru || ru.searchType !== search_page.resultTypeUser) continue
                    if (ru.mid) existingUser[String(ru.mid)] = true
                }
            } catch (e) { existingUser = {} }

            function fmtNum(n) {
                var num = parseInt(n, 10) || 0
                if (num >= 100000000) return (num / 100000000).toFixed(1) + "亿"
                if (num >= 10000) return (num / 10000).toFixed(1) + "万"
                return String(num)
            }
            function fixUpic(pic) {
                if (!pic || pic === "") return ""
                var s = String(pic)
                if (s.indexOf("http") === 0) return s
                if (s.indexOf("//") === 0) return "https:" + s
                return s
            }

            for (var i = 0; i < result.length; i++) {
                var item = result[i]
                if (!item) continue

                var mid = (item.mid !== undefined && item.mid !== null && String(item.mid) !== "")
                              ? String(item.mid)
                              : ""
                if (mid === "") continue
                if (existingUser[mid]) continue
                existingUser[mid] = true

                // 用户名（去掉B站搜索结果的高亮HTML标签）
                var unameClean = ""
                try {
                    var rawUname = item.uname || item.name || ""
                    if (typeof rawUname === "string") {
                        unameClean = rawUname.replace(/<[^>]*>/g, "")
                    } else {
                        unameClean = String(rawUname || "")
                    }
                } catch (e) { unameClean = "" }

                // 头像
                var upic = ""
                if (item.upic !== undefined && String(item.upic) !== "") upic = fixUpic(item.upic)
                else if (item.face !== undefined) upic = fixUpic(String(item.face))

                // LV等级
                var level = 0
                if (item.level !== undefined && !isNaN(Number(item.level))) level = Number(item.level)

                // 稿件数
                var videos = 0
                if (item.videos !== undefined && !isNaN(Number(item.videos))) videos = Number(item.videos)
                else if (item.arc_count !== undefined && !isNaN(Number(item.arc_count))) videos = Number(item.arc_count)

                // 粉丝数
                var fans = 0
                if (item.fans !== undefined && !isNaN(Number(item.fans))) fans = Number(item.fans)

                // 是否UP主
                var isUpuser = 0
                if (item.is_upuser !== undefined) isUpuser = Number(item.is_upuser) ? 1 : 0
                else if (item.isUp !== undefined) isUpuser = Number(item.isUp) ? 1 : 0

                // 认证：official_verify.type / official_verify.desc
                var verifyType = -1
                var verifyDesc = ""
                try {
                    var ov = item.official_verify
                    if (ov && typeof ov === "object") {
                        if (ov.type !== undefined) verifyType = Number(ov.type)
                        if (ov.desc !== undefined) verifyDesc = String(ov.desc || "")
                    } else if (item.officialVerify && typeof item.officialVerify === "object") {
                        if (item.officialVerify.type !== undefined) verifyType = Number(item.officialVerify.type)
                        if (item.officialVerify.desc !== undefined) verifyDesc = String(item.officialVerify.desc || "")
                    }
                } catch (e) { verifyType = -1; verifyDesc = "" }

                // 个性签名（去掉HTML标签）
                var usign = ""
                try {
                    var rawSign = item.usign || item.sign || ""
                    if (typeof rawSign === "string") {
                        usign = rawSign.replace(/<[^>]*>/g, "")
                    } else {
                        usign = String(rawSign || "")
                    }
                } catch (e) { usign = "" }

                GlobalState.searchResultModel.append({
                    searchType: search_page.resultTypeUser,
                    mid: mid,
                    uname: unameClean,
                    upic: upic,
                    level: level,
                    videos: videos,
                    fans: fans,
                    fansText: fmtNum(fans),
                    isUpuser: isUpuser,
                    verifyType: verifyType,
                    verifyDesc: verifyDesc,
                    usign: usign
                })
                added++
            }
            _currentPage++
            if (_retryIfEmptyFirstPage(added, "user")) return
            hasMore = added > 0 && _currentPage < numPages && _currentPage < 50
        } catch (e) {
            console.warn("[SearchPage] parse user search data failed:", e)
            hasMore = false
            loading = false
            return
        }
        loading = false
        if (hasMore && _sizeValid) {
            var needsMore2 = resultGrid.contentHeight <= resultGrid.height + 100
            if (needsMore2) appendSearchResults()
        }
    }

    // ====== 自动保存 / 恢复滚动位置 ======
    function saveScroll() {
        if (search_page.visible && resultGrid && resultGrid.contentHeight > 0) {
            _lastContentY = resultGrid.contentY
            _pageInitialized = true
        }
    }

    function restoreScroll() {
        if (!resultGrid || !_pageInitialized) return
        if (GlobalState.searchResultModel.count === 0) return
        if (_scrollRestored) return
        if (resultGrid.contentHeight <= 0 || !isFinite(resultGrid.contentHeight)) return
        var target = _lastContentY
        if (target < 0) target = 0
        var maxY = Math.max(0, resultGrid.contentHeight - resultGrid.height)
        if (target > maxY) target = maxY
        resultGrid.contentY = target
        _scrollRestored = true
    }

    // ====== 页面生命周期 ======
    onVisibleChanged: {
        if (search_page.visible) {
            if (!GlobalState.searchKeyword) {
                // do nothing
            } else if (!hasSearched && GlobalState.searchKeyword) {
                searchBox.text = GlobalState.searchKeyword
                _startSearch(GlobalState.searchKeyword)
            } else if (hasSearched && _sizeValid) {
                resultGrid.forceLayout()
                if (_pageInitialized) restoreScroll()
                else if (GlobalState.searchResultModel.count === 0) appendSearchResults()
            }
        } else {
            // 小窗模式：pageStack.visible=false 使 visible 从父级"流动"为 false
            //（Qt 语义：父项 visible 变化会直接改变全部子孙的 visible 值并触发
            //  visibleChanged），非真实切页，绝不能关闭播放器
            if (App.miniPlayerMode) return
            saveScroll()
            // 切到其他导航页时关闭视频/直播播放器，避免声音串扰
            //（与 HomePage/HistoryPage/DynamicPage 的既定行为一致）
            if (videoVisible) closeVideoPlayer()
            if (liveVisible) closeLivePlayer()
        }
    }

    // 尺寸变化防抖定时器：拖动窗口边框时 onWidthChanged/onHeightChanged 每秒触发几十次，
    // forceLayout + restoreScroll 很昂贵，用 150ms 防抖避免每次都执行
    Timer {
        id: resizeDebounceTimer
        interval: 150
        repeat: false
        onTriggered: {
            if (!search_page.visible || !search_page.hasSearched) return
            if (resultGrid.width > 0 && resultGrid.height > 0) {
                resultGrid.forceLayout()
                restoreScroll()
            }
        }
    }

    onWidthChanged: {
        if (!search_page.visible) return
        if (search_page.width > 0 && search_page.height > 0) {
            if (!_sizeValid) {
                if (hasSearched) {
                    if (GlobalState.searchResultModel.count === 0) {
                        appendSearchResults()
                    }
                } else if (GlobalState.searchKeyword) {
                    searchBox.text = GlobalState.searchKeyword
                    _startSearch(GlobalState.searchKeyword)
                }
                if (_pageInitialized) restoreScroll()
            } else {
                resizeDebounceTimer.restart()
            }
        }
    }

    onHeightChanged: {
        if (!search_page.visible) return
        if (search_page.width > 0 && search_page.height > 0) {
            if (!_sizeValid) {
                if (hasSearched && GlobalState.searchResultModel.count === 0) {
                    appendSearchResults()
                }
                if (_pageInitialized) restoreScroll()
            } else {
                resizeDebounceTimer.restart()
            }
        }
    }

    Component.onCompleted: {
    }

    Component.onDestruction: {
        // 离开搜索页面时强制销毁直播播放器（释放 D3D11 设备/纹理）
        try {
            if (liveOverlay._playerCreated && livePlayerLoader.item) {
                livePlayerLoader.item.stopPlayer()
            }
        } catch (e) {}
        liveOverlay._playerCreated = false
        // 断开弹幕 WebSocket，释放 SSL 资源
        try { sharedDanmakuManager.disconnectRoom() } catch (e) {}
    }

    // 联想 API 返回处理
    Connections {
        target: Api
        function onSearchResultsReceived(data) {
            search_page.appendSearchData(data, search_page._pendingRequestId)
        }
        function onSearchBangumiReceived(data, isMovie) {
            search_page.appendSearchBangumiData(data, search_page._pendingRequestId, isMovie)
        }
        function onSearchLiveReceived(data) {
            search_page.appendSearchLiveData(data, search_page._pendingRequestId)
        }
        function onSearchUserReceived(data) {
            search_page.appendSearchUserData(data, search_page._pendingRequestId)
        }
        function onSearchSuggestReceived(words) {
            search_page._applySuggestWords(words)
        }
        // 断网等网络错误时 Api 只发 errorOccurred 不发数据信号，
        // 不复位 loading 会让 appendSearchResults 的 loading 守卫永久卡死
        function onErrorOccurred(error) {
            console.warn("[SearchPage] API error:", error)
            if (!search_page.loading) return
            search_page.loading = false
            search_page.hasMore = false
            // 打断 _startSearch 的重复搜索拦截：失败请求的 requestId 永远停在
            // pending 状态，不清零的话恢复网络后再搜同一关键词会被当作
            // "重复提交"直接丢弃（表现：永远提示"没有找到相关内容"）
            search_page._lastCommittedRequestId = 0
        }
    }

    // ====== 页面主容器（FluFrame，与 HomePage/HistoryPage 保持一致的外框样式） ======
    FluFrame {
        id: searchFrame
        // 诊断开关：隐藏整个 FluFrame 内容，用于定位卡顿源是否在页面内容
        visible: true
        radius: Theme.frameRadius
        anchors.fill: parent
        anchors.leftMargin: Theme.homeFrameLeftMargin
        anchors.rightMargin: Theme.homeFrameRightMargin
        anchors.bottomMargin: Theme.homeFrameBottomMargin
        anchors.topMargin: Theme.homeFrameTopMargin
        padding: Theme.homeFramePadding

        // 顶部栏：分区 / 排序 / 时长 + 搜索框
        ColumnLayout {
            id: topColumnLayout
            // 诊断开关：设为 false 可临时隐藏整个筛选栏，用于定位 resize 卡顿源
            visible: true
            anchors.fill: parent
            anchors.leftMargin: 12
            anchors.rightMargin: 12
            anchors.topMargin: 12
            anchors.bottomMargin: 12
            spacing: 12

        // 第一行：筛选（仅视频）+ 搜索类型（紧挨着搜索框左侧）+ 搜索框
        RowLayout {
            Layout.fillWidth: true
            spacing: 12

            FluComboBox {
                id: videoSortCombo
                visible: search_page.searchType === 0
                Layout.preferredWidth: 140
                Layout.minimumWidth: 140
                Layout.maximumWidth: 140
                Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
                Layout.leftMargin: 16
                model: [qsTr("综合排序"), qsTr("最多点击"), qsTr("最新发布"), qsTr("最多弹幕"), qsTr("最多收藏")]
                currentIndex: 0
                onCurrentIndexChanged: {
                    if (search_page.hasSearched) doRefreshSearch()
                }
            }

            FluComboBox {
                id: videoDurationCombo
                visible: search_page.searchType === 0
                Layout.preferredWidth: 140
                Layout.minimumWidth: 140
                Layout.maximumWidth: 140
                Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
                model: [qsTr("全部时长"), qsTr("10分钟以下"), qsTr("10-30分钟"), qsTr("30-60分钟"), qsTr("60分钟以上")]
                currentIndex: 0
                onCurrentIndexChanged: {
                    if (search_page.hasSearched) doRefreshSearch()
                }
            }

            FluComboBox {
                id: videoPartitionCombo
                visible: search_page.searchType === 0
                Layout.preferredWidth: 140
                Layout.minimumWidth: 140
                Layout.maximumWidth: 140
                Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
                model: [qsTr("全部分区"), qsTr("动画"), qsTr("音乐"), qsTr("游戏"), qsTr("娱乐"),
                       qsTr("番剧"), qsTr("影视"), qsTr("知识"), qsTr("科技"), qsTr("时尚"),
                       qsTr("资讯"), qsTr("生活"), qsTr("动漫"), qsTr("鬼畜"), qsTr("电影"),
                       qsTr("电视剧")]
                currentIndex: 0
                onCurrentIndexChanged: {
                    if (search_page.hasSearched) doRefreshSearch()
                }
            }

            // 用户搜索：排序下拉框（第1个）
            FluComboBox {
                id: userOrderCombo
                visible: search_page.searchType === 3
                Layout.preferredWidth: 170
                Layout.minimumWidth: 170
                Layout.maximumWidth: 170
                Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
                Layout.leftMargin: 16
                model: search_page._userOrderLabels
                currentIndex: 0
                onCurrentIndexChanged: {
                    if (search_page.hasSearched) doRefreshSearch()
                }
            }

            // 用户搜索：用户类型下拉框（第2个）
            FluComboBox {
                id: userTypeCombo
                visible: search_page.searchType === 3
                Layout.preferredWidth: 140
                Layout.minimumWidth: 140
                Layout.maximumWidth: 140
                Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
                model: search_page._userTypeLabels
                currentIndex: 0
                onCurrentIndexChanged: {
                    if (search_page.hasSearched) doRefreshSearch()
                }
            }

            Item { Layout.fillWidth: true; Layout.minimumWidth: 20 }

            // ====== 搜索类型：紧挨着搜索框左侧 ======
            // 选项：视频 / 番剧 / 直播 / 用户 / 影视（目前实现番剧搜索，其他占位提示）
            FluComboBox {
                id: searchTypeCombo
                Layout.preferredWidth: 120
                Layout.minimumWidth: 110
                Layout.maximumWidth: 120
                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                model: search_page._searchTypeLabels
                currentIndex: search_page.searchType
                onCurrentIndexChanged: {
                    if (search_page.searchType === currentIndex) return
                    search_page.searchType = currentIndex
                    // 切换类型瞬间：① 立刻清空旧类型的 model（防止 GridView reuseItems 把旧视频行按番剧卡 delegate 渲染，导致地区/评分等字段都是 undefined）
                    //             ② 把 _pendingRequestId 作废，让在路上的旧类型响应全部被 append* 函数的 requestId 校验丢弃
                    //             ③ _currentPage 归零，取消旧请求的"翻页到 N 页"状态
                    GlobalState.searchResultModel.clear()
                    resultGrid.positionViewAtBeginning()
                    resultGrid.contentY = 0
                    search_page._pendingRequestId = -1
                    search_page._currentPage = 0
                    search_page.hasMore = true
                    search_page.loading = false
                    if (search_page._sizeValid) resultGrid.forceLayout()
                    // 切换搜索类型后，若已搜索过，则立刻以新类型重搜
                    if (search_page.hasSearched) {
                        doSearch()
                    }
                }
            }

            // ====== 搜索框：用 FluAutoSuggestBox 原生组件 ======
            // FluAutoSuggestBox 本身就是 FluentUI 写好的：下拉位置由其内部
            // control_popup.x/y 绑定 mapToItem(null,0,0) 控制，永远精准；
            // 且它的 control_popup 是 Overlay.overlay 上的 Popup，绝不挤布局。
            // 我们唯一要做的：用异步后端联想结果填充 items，
            // 并通过 Binding 强制 control_popup.visible 只在有词、未锁时 true，
            // 这样 debounce 期间空 items 就不会显示 No results found。
            FluAutoSuggestBox {
                id: searchBox
                Layout.preferredWidth: 380
                Layout.minimumWidth: 280
                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                Layout.rightMargin: 16
                Layout.fillWidth: false
                placeholderText: qsTr("搜索视频、UP主、番剧、话题...")
                iconSource: FluentIcons.Search
                cleanEnabled: true
                itemHeight: 40
                itemRows: 10
                emptyText: qsTr("") // 空状态下不显示任何文字

                // items 绑定：把纯字符串 _suggestWords 转成 FluAutoSuggestBox 需要的
                // { title: word } 结构（因为其 textRole 默认 "title"，
                // delegate text: modelData[textRole]）。
                items: (search_page._suggestWords || []).map(function(w){ return {title: w} })
                textRole: "title"

                // 不过滤：联想后端 API 已经过滤好了，前端再过滤是反效果
                filter: function(item){ return true }

                // 点联想项 → 用 updateText() 填充搜索框（不会弹下拉，因为内部会暂时
                // 把 flagVisible 设 false，onTextChanged 触发的 showSuggest() 被阻挡）
                // 然后 doSearch 立即执行搜索，内部会清空 _suggestWords 并开 submittedLock。
                // 提示：FluAutoSuggestBox 源码 d.handleClick 已经先把 control_popup.visible=false
                // 再调 itemClicked 信号，所以不用我们手动关。
                onItemClicked: function(data) {
                    if (data && data.title) {
                        searchBox.updateText(data.title)
                    }
                    doSearch()
                }

                // 提交（按回车 / 点搜索按钮）
                // 注意：FluAutoSuggestBox 源码 L54-L58 d.handleEnterReturn()
                // 只在 list_view.currentIndex ≠ -1（键盘↑↓选过联想项）时才会走
                // d.handleClick → control_popup.visible=false 关下拉。
                // 如果用户打字直接按回车（currentIndex = -1），源码里没有任何地方会
                // 去关 control_popup.visible！这就是"按回车下拉不消失"的根因。
                onCommit: function(text) {
                    // 关联想弹窗：利用 FluAutoSuggestBox.onActiveFocusChanged 自动关 Popup（O(1)），
                    // 替代 _forceCloseAllVisiblePopups() 全树遍历（O(n²)，实测 ~800ms 阻塞）。
                    // focus=false 触发 onActiveFocusChanged → control_popup.visible=false，
                    // 与点联想词时 d.handleClick 关 Popup 是同一条代码路径。
                    search_page._suggestWords = []
                    search_page._suggestPopupOpen = false
                    searchBox.focus = false
                    searchBox.forceActiveFocus()
                    doSearch()
                }

                // 输入变化：启动 300ms debounce 请求联想（Timer 在 SearchPage 顶层）
                onTextChanged: {
                    search_page.suggestDebounceTimer.restart()
                }

                // 失焦延时清理联想词（防止失焦瞬间竞态重开下拉，Timer 在 SearchPage 顶层）
                onFocusChanged: {
                    if (!focus) {
                        search_page.suggestCloseTimer.restart()
                    }
                }
                onActiveFocusChanged: {
                    if (!activeFocus) {
                        search_page.suggestCloseTimer.restart()
                    }
                }

                // ========== 关键：拦截回车键（兜底强制关下拉） ==========
                // 背景：FluAutoSuggestBox 源码 L71-L76 的 Keys.onReturnPressed/onEnterPressed
                // 只走 d.handleEnterReturn()——只有当 list_view.currentIndex != -1
                // （用户用键盘↑↓选过某个联想项）才会关下拉；
                // 如果用户打字后直接按回车（currentIndex=-1），源码完全不会关 control_popup！
                // 我们这里在组件内部 Signal Handlers 的运行顺序里，我们的 Keys Handler
                // 写在 FluAutoSuggestBox 子项里会比源码的 Keys Handler 先跑吗？不一定，但
                // Qt Quick Keys Handlers 会按顺序调用——而且我们即使后跑也没关系，
                // 因为我们再次扫一次 Popup 全关 + doSearch 是幂等的。
                Keys.onReturnPressed: function(event) {
                    event.accepted = true
                    // 关联想弹窗：focus 切换触发 onActiveFocusChanged（O(1)），
                    // 替代 _forceCloseAllVisiblePopups() 全树遍历（~800ms 阻塞）
                    search_page._suggestWords = []
                    search_page._suggestPopupOpen = false
                    searchBox.focus = false
                    searchBox.forceActiveFocus()
                    doSearch()
                }
                Keys.onEnterPressed: function(event) {
                    event.accepted = true
                    search_page._suggestWords = []
                    search_page._suggestPopupOpen = false
                    searchBox.focus = false
                    searchBox.forceActiveFocus()
                    doSearch()
                }
            }

            // ====== 关于联想下拉弹出的说明 ======
            // 当前 FluentUI 版本 FluAutoSuggestBox 内部 popup 属性名不是 control_popup
            // （日志报 undefined），所以不用 Binding 控 visible。
            // 改由 emptyText: "" 屏蔽 No results found 文字；
            // _applySuggestWords 在联想结果回来后，重新赋值 searchBox.text 以触发组件
            // 内部 onTextChanged → showSuggest()，解决"首次输不弹、删一个字才弹"。

        }

        // 搜索结果区
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.topMargin: Theme.pageMargins

            // 初始占位（保持在 resultGrid 之上，避免透明/禁用的 GridView 拦截事件）
            Column {
                anchors.centerIn: parent
                z: 1
                spacing: Theme.spacingMedium
                visible: !search_page.hasSearched

                FluIcon {
                    width: 120
                    height: 120
                    iconSource: FluentIcons.Search
                    color: FluTheme.fontTertiaryColor
                    anchors.horizontalCenter: parent.horizontalCenter
                }
                FluText {
                    text: qsTr("输入关键词开始搜索")
                    color: FluTheme.fontSecondaryColor
                    font.pixelSize: 15
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }

            // 搜索中 loading
            BusyIndicator {
                anchors.centerIn: parent
                z: 2
                width: 40
                height: 40
                running: search_page.loading && GlobalState.searchResultModel.count === 0
                visible: running
            }

            // 无结果占位（仅在真·有过搜索、0 条、没在 loading 时显示）
            Column {
                anchors.centerIn: parent
                z: 3
                spacing: Theme.spacingMedium
                visible: search_page.hasSearched && !search_page.loading
                         && GlobalState.searchResultModel.count === 0

                FluIcon {
                    width: 96
                    height: 96
                    iconSource: FluentIcons.Search
                    color: FluTheme.fontTertiaryColor
                    anchors.horizontalCenter: parent.horizontalCenter
                }
                FluText {
                    text: qsTr("没有找到相关内容")
                    color: FluTheme.fontSecondaryColor
                    font.pixelSize: 15
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }

            // 结果列表（GridView）
            GridView {
                id: resultGrid
                anchors.fill: parent
                cellWidth: search_page.cellWidth
                // cellHeight 用属性绑定（避免函数表达式每次访问都重新执行）
                cellHeight: search_page.cellHeightValue
                clip: true
                z: 0
                boundsBehavior: Flickable.StopAtBounds
                reuseItems: true
                model: GlobalState.searchResultModel

                header: Item {
                    // 结果 Grid 顶部的占位（没有就没有分隔）。
                    // 也可以这里放一个"共X条"标题，暂时省略。
                    width: resultGrid.width
                    height: 0
                    visible: false
                }
                footer: Item {
                    width: resultGrid.width
                    height: visible ? 60 : 0
                    visible: search_page.hasSearched && !search_page.loading
                             && GlobalState.searchResultModel.count > 0
                             && !search_page.hasMore
                    FluText {
                        anchors.centerIn: parent
                        text: qsTr("— 已经到底啦 —")
                        color: FluTheme.fontTertiaryColor
                        font.pixelSize: 13
                    }
                }

                delegate: Item {
                    id: delegateItem
                    width: Math.max(1, search_page.cellWidth)
                    height: Math.max(1, resultGrid.cellHeight)

                    // ===== 抗 GridView reuseItems 脏数据：固定从 ListModel.get(index) 取行对象 =====
                    // 现象：先搜视频→切番剧→clear()→append 1 条，GridView 复用 delegate 实例时，
                    // model.xxx 绑定会"继续指向"旧 ListElement 或 undefined，导致 seasonId/areas
                    // 全 undefined，只有 title/cover/pubDate（视频行已有字段）能取到。
                    // 解决：在这里直接根据 index 从 ListModel 拿到真实行对象，所有字段都从
                    // __row 读，不使用 model.<role> 的隐式绑定。
                    property var __row: (GlobalState.searchResultModel && index >= 0 && index < GlobalState.searchResultModel.count)
                                            ? GlobalState.searchResultModel.get(index)
                                            : null

                    property int __st: (delegateItem.__row && delegateItem.__row.searchType !== undefined)
                                            ? delegateItem.__row.searchType
                                            : search_page.resultTypeVideo
                    readonly property bool __isBangumi: (__st === search_page.resultTypeBangumi)
                    readonly property bool __isLive: (__st === search_page.resultTypeLive)
                    readonly property bool __isUser: (__st === search_page.resultTypeUser)
                    readonly property bool __isVideo: (__st === search_page.resultTypeVideo) || (!__isBangumi && !__isLive && !__isUser)

                    // ====== 视频卡片（竖向）======
                    Loader {
                        visible: delegateItem.__isVideo && delegateItem.__row !== null
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.max(1, search_page.displayCardWidth - (Theme.scrollBarReserve || 0))
                        height: resultGrid.cellHeight - (search_page.vSpacing + 8)
                        active: delegateItem.__isVideo && delegateItem.__row !== null
                        asynchronous: false
                        sourceComponent: VideoCard {
                            bvid: (delegateItem.__row && delegateItem.__row.bvid) ? delegateItem.__row.bvid : ""
                            title: (delegateItem.__row && delegateItem.__row.title) ? delegateItem.__row.title : ""
                            cover: (delegateItem.__row && delegateItem.__row.cover) ? delegateItem.__row.cover : ""
                            author: (delegateItem.__row && delegateItem.__row.author) ? delegateItem.__row.author : ""
                            views: (delegateItem.__row && delegateItem.__row.plays !== undefined && delegateItem.__row.plays !== null) ? String(delegateItem.__row.plays) : ""
                            danmakus: (delegateItem.__row && delegateItem.__row.danmu !== undefined && delegateItem.__row.danmu !== null) ? String(delegateItem.__row.danmu) : ""
                            duration: (delegateItem.__row && delegateItem.__row.duration !== undefined) ? delegateItem.__row.duration : ""
                            pubDate: (delegateItem.__row && delegateItem.__row.pubDate !== undefined) ? delegateItem.__row.pubDate : ""
                        }
                    }

                    // ====== 直播卡片（竖向，同视频卡列数）======
                    Loader {
                        visible: delegateItem.__isLive && delegateItem.__row !== null
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.max(1, search_page.displayCardWidth - (Theme.scrollBarReserve || 0))
                        height: resultGrid.cellHeight - (search_page.vSpacing + 8)
                        active: delegateItem.__isLive && delegateItem.__row !== null
                        asynchronous: false
                        sourceComponent: LiveCard {
                            roomId: (delegateItem.__row && delegateItem.__row.roomId) ? String(delegateItem.__row.roomId) : ""
                            title: (delegateItem.__row && delegateItem.__row.title) ? String(delegateItem.__row.title) : ""
                            cover: (delegateItem.__row && delegateItem.__row.cover) ? String(delegateItem.__row.cover) : ""
                            streamer: (delegateItem.__row && delegateItem.__row.uname) ? String(delegateItem.__row.uname) : ""
                            viewers: (delegateItem.__row && delegateItem.__row.onlineText !== undefined) ? String(delegateItem.__row.onlineText) : "0"
                            category: (delegateItem.__row && delegateItem.__row.areaName !== undefined) ? String(delegateItem.__row.areaName) : ""
                            badgeText: ""
                            onClicked: {
                                var row = delegateItem.__row
                                var rid = (row && row.roomId) ? String(row.roomId) : ""
                                var ttl = (row && row.title) ? String(row.title) : ""
                                var unm = (row && row.uname) ? String(row.uname) : ""
                                if (rid === "") return
                                search_page.openLivePlayer(rid, ttl, unm)
                            }
                        }
                    }

                    // ====== 番剧/影视卡片（横向 左封面+右信息），对齐 biliuwp-lite AnimeTpl ======
                    Loader {
                        visible: __isBangumi && delegateItem.__row !== null
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.max(1, search_page.displayCardWidthBangumi)
                        height: search_page.bangumiCardHeight
                        active: __isBangumi && delegateItem.__row !== null
                        asynchronous: false
                        sourceComponent: Rectangle {
                            id: bangumiCard
                            width: parent.width
                            height: parent.height
                            color: "transparent"

                            // 鼠标悬浮时整体轻微上浮
                            property bool hovered: false
                            layer.enabled: hovered && width > 0 && height > 0
                            layer.effect: MultiEffect {
                                shadowEnabled: true
                                shadowColor: "#80000000"
                                shadowOpacity: hovered ? 0.5 : 0
                                shadowBlur: 0.8
                                shadowVerticalOffset: hovered ? 6 : 0
                                shadowScale: 1
                                Behavior on shadowOpacity { NumberAnimation { duration: 200 } }
                                Behavior on shadowVerticalOffset { NumberAnimation { duration: 200 } }
                            }
                            transform: Translate {
                                y: bangumiCard.hovered ? -6 : 0
                                Behavior on y { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                            }

                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                onEntered: bangumiCard.hovered = true
                                onExited: bangumiCard.hovered = false
                                onClicked: {
                                    var row = delegateItem.__row
                                    var sid = (row && row.seasonId) ? String(row.seasonId) : ""
                                    var mid = (row && row.mediaId) ? String(row.mediaId) : ""
                                    var eid = (row && row.epId) ? String(row.epId) : ""
                                    var ttl = (row && row.title) ? String(row.title) : ""
                                    var bvd = (row && row.bvid)  ? String(row.bvid)  : ""
                                    if (sid === "" && mid === "" && eid === "" && bvd === "") return
                                    App.openBangumi(bvd, eid, sid, ttl)
                                }
                                cursorShape: Qt.PointingHandCursor
                            }

                            RowLayout {
                                anchors.fill: parent
                                spacing: 12

                                // ====== 封面（左，竖向海报比例：宽 144 × 高 210，约 2:3 番剧海报比例） ======
                                Item {
                                    Layout.preferredWidth: 144
                                    Layout.minimumWidth: 120
                                    Layout.maximumWidth: 144
                                    Layout.fillHeight: true

                                    Rectangle {
                                        id: bgCover
                                        anchors.fill: parent
                                        color: FluTheme.frameColor
                                        radius: Theme.cardRadius
                                        clip: true
                                        layer.enabled: width > 0 && height > 0
                                        layer.samples: 4
                                        layer.effect: MultiEffect {
                                            maskEnabled: true
                                            maskSource: ShaderEffectSource {
                                                sourceItem: Rectangle {
                                                    x: -10000; y: -10000
                                                    width: Math.max(1, bgCover.width)
                                                    height: Math.max(1, bgCover.height)
                                                    radius: Theme.cardRadius
                                                    color: "black"
                                                }
                                                hideSource: true
                                                live: false
                                                // 蒙版纹理按 DPR 超采样 2 倍，圆弧边缘
                                                // 在高分屏缩放采样下不出现锯齿
                                                textureSize: Qt.size(
                                                    Math.max(1, bgCover.width * Screen.devicePixelRatio * 2),
                                                    Math.max(1, bgCover.height * Screen.devicePixelRatio * 2))
                                            }
                                        }

                                        FluImage {
                                            id: bgCoverImg
                                            anchors.fill: parent
                                            source: {
                                                var row = delegateItem.__row
                                                var cv = (row && row.cover !== undefined && row.cover !== null) ? String(row.cover) : ""
                                                return GlobalState.fixImageUrl(cv,
                                                    Math.max(1, bgCover.width * Screen.devicePixelRatio),
                                                    Math.max(1, bgCover.height * Screen.devicePixelRatio),
                                                    true)
                                            }
                                            fillMode: Image.PreserveAspectCrop
                                            visible: {
                                                var row = delegateItem.__row
                                                return (row && row.cover !== undefined && row.cover !== null && String(row.cover) !== "")
                                            }
                                            asynchronous: true
                                            cache: false
                                            sourceSize: Qt.size(
                                                Math.max(1, bgCover.width * Screen.devicePixelRatio),
                                                Math.max(1, bgCover.height * Screen.devicePixelRatio))
                                        }

                                        // 右上角「会员专享/独播」等角标（biliuwp-lite showBadge + angle_title）
                                        Rectangle {
                                            id: badgeRect
                                            visible: {
                                                var row = delegateItem.__row
                                                return !!(row && row.showBadge)
                                            }
                                            x: bgCover.width - badgeRect.width - 6
                                            y: 6
                                            radius: 6
                                            color: "#FFA500"
                                            width: badgeText.width + 14
                                            height: badgeText.height + 6
                                            FluText {
                                                id: badgeText
                                                anchors.centerIn: parent
                                                text: {
                                                    var row = delegateItem.__row
                                                    return (row && row.angleTitle !== undefined && String(row.angleTitle) !== "")
                                                               ? String(row.angleTitle)
                                                               : qsTr("会员专享")
                                                }
                                                color: "white"
                                                font.pixelSize: 12
                                            }
                                        }
                                    }

                                    // 封面圆角描边：必须位于 bgCover 的遮罩层（layer+mask）
                                    // 之外，否则被同一个圆角蒙版裁剪，外扩部分永远盖不住
                                    // 蒙版边缘的抗锯齿毛边（同 VideoCard/LiveCard 方案）
                                    Rectangle {
                                        anchors.fill: parent
                                        anchors.margins: -1
                                        radius: Theme.cardRadius
                                        color: "transparent"
                                        border.color: Window.active ? Theme.cardBorderActiveColor : Theme.cardBorderColor
                                        border.width: Theme.cardBorderWidth
                                    }
                                }

                                // ====== 右侧信息区（标题+类型+地区+风格+开播时间/更新进度 评分） ======
                                Item {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true

                                    FluText {
                                        id: bgmTitle
                                        text: {
                                            var row = delegateItem.__row
                                            return (row && row.title !== undefined) ? String(row.title) : ""
                                        }
                                        color: FluTheme.fontPrimaryColor
                                        font.pixelSize: 16
                                        font.weight: Font.DemiBold
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.top: parent.top
                                        maximumLineCount: 1
                                        wrapMode: Text.Wrap
                                        elide: Text.ElideRight
                                    }

                                    // 评分（右上一行）
                                    Row {
                                        id: scoreRow
                                        anchors.top: bgmTitle.bottom
                                        anchors.topMargin: 8
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        spacing: 10
                                        readonly property bool _hasScore: {
                                            var row = delegateItem.__row
                                            if (!row) return false
                                            var s = row.score
                                            return (s !== undefined && s !== null && !isNaN(s) && Number(s) > 0)
                                        }

                                        FluText {
                                            visible: parent._hasScore
                                            text: {
                                                var row = delegateItem.__row
                                                return Number(row ? row.score : 0).toFixed(1)
                                            }
                                            color: "#FE8529"
                                            font.pixelSize: 15
                                            font.bold: true
                                        }
                                        FluText {
                                            visible: parent._hasScore
                                            text: qsTr("分")
                                            color: FluTheme.fontTertiaryColor
                                            font.pixelSize: 13
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                    }

                                    // 简介（自动换行，填充评分与底部信息之间的留白区域）
                                    FluText {
                                        id: bangumiDesc
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.top: scoreRow.bottom
                                        anchors.topMargin: 6
                                        anchors.bottom: bottomInfoColumn.top
                                        anchors.bottomMargin: 6
                                        visible: {
                                            var row = delegateItem.__row
                                            var d = (row && row.desc !== undefined) ? String(row.desc) : ""
                                            return d !== ""
                                        }
                                        text: {
                                            var row = delegateItem.__row
                                            return (row && row.desc !== undefined) ? String(row.desc) : ""
                                        }
                                        color: FluTheme.fontSecondaryColor
                                        font.pixelSize: 13
                                        wrapMode: Text.Wrap
                                        elide: Text.ElideRight
                                        maximumLineCount: 5
                                    }

                                    // 底部信息（类型 / 地区 / 风格 / 开播时间 / 更新进度 / 声优）
                                    Column {
                                        id: bottomInfoColumn
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.bottom: parent.bottom
                                        spacing: 2
                                        // 工具：安全判断是否「有非空非 undefined 文本」
                                        function _t(v) { return (v !== undefined && v !== null && String(v) !== "") }

                                        FluText {
                                            visible: {
                                                var row = delegateItem.__row
                                                return parent._t(row ? row.seasonTypeName : "") || parent._t(row ? row.updateInfo : "")
                                            }
                                            text: {
                                                var row = delegateItem.__row
                                                var stn = row ? row.seasonTypeName : ""
                                                var upd = row ? row.updateInfo : ""
                                                var parts = []
                                                if (parent._t(stn)) parts.push(qsTr("类型：") + String(stn))
                                                if (parent._t(upd)) parts.push(String(upd))
                                                return parts.join("        ")
                                            }
                                            color: FluTheme.fontTertiaryColor
                                            font.pixelSize: 13
                                            elide: Text.ElideRight
                                            wrapMode: Text.Wrap
                                        }
                                        FluText {
                                            visible: parent._t(delegateItem.__row ? delegateItem.__row.areas : "")
                                            text: qsTr("地区：") + String(delegateItem.__row ? delegateItem.__row.areas : "")
                                            color: FluTheme.fontTertiaryColor
                                            font.pixelSize: 13
                                            elide: Text.ElideRight
                                            wrapMode: Text.Wrap
                                        }
                                        FluText {
                                            visible: parent._t(delegateItem.__row ? delegateItem.__row.styles : "")
                                            text: qsTr("风格：") + String(delegateItem.__row ? delegateItem.__row.styles : "")
                                            color: FluTheme.fontTertiaryColor
                                            font.pixelSize: 13
                                            elide: Text.ElideRight
                                            wrapMode: Text.Wrap
                                        }
                                        FluText {
                                            visible: parent._t(delegateItem.__row ? delegateItem.__row.pubDate : "")
                                            text: qsTr("开播时间：") + String(delegateItem.__row ? delegateItem.__row.pubDate : "")
                                            color: FluTheme.fontTertiaryColor
                                            font.pixelSize: 13
                                            elide: Text.ElideRight
                                            wrapMode: Text.Wrap
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ====== 用户卡片（横向：圆形头像+右侧用户名/稿件/粉丝/签名） ======
                    Loader {
                        visible: __isUser && delegateItem.__row !== null
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.max(1, search_page.displayCardWidthUser)
                        height: search_page.userCardHeight
                        active: __isUser && delegateItem.__row !== null
                        asynchronous: false
                        sourceComponent: UserCard {
                            width: parent.width
                            height: parent.height
                            mid: (delegateItem.__row && delegateItem.__row.mid !== undefined) ? String(delegateItem.__row.mid) : ""
                            uname: (delegateItem.__row && delegateItem.__row.uname !== undefined) ? String(delegateItem.__row.uname) : ""
                            upic: (delegateItem.__row && delegateItem.__row.upic !== undefined) ? String(delegateItem.__row.upic) : ""
                            level: (delegateItem.__row && delegateItem.__row.level !== undefined) ? Number(delegateItem.__row.level) : 0
                            videos: (delegateItem.__row && delegateItem.__row.videos !== undefined) ? Number(delegateItem.__row.videos) : 0
                            fans: (delegateItem.__row && delegateItem.__row.fans !== undefined) ? Number(delegateItem.__row.fans) : 0
                            isUpuser: (delegateItem.__row && delegateItem.__row.isUpuser !== undefined) ? Number(delegateItem.__row.isUpuser) : 0
                            verifyType: (delegateItem.__row && delegateItem.__row.verifyType !== undefined) ? Number(delegateItem.__row.verifyType) : -1
                            verifyDesc: (delegateItem.__row && delegateItem.__row.verifyDesc !== undefined) ? String(delegateItem.__row.verifyDesc) : ""
                            usign: (delegateItem.__row && delegateItem.__row.usign !== undefined) ? String(delegateItem.__row.usign) : ""
                            onClicked: {
                                var row = delegateItem.__row
                                var m = (row && row.mid) ? String(row.mid) : ""
                                var unm = (row && row.uname) ? String(row.uname) : ""
                                var upic = (row && row.upic) ? String(row.upic) : ""
                                var vType = (row && row.verifyType !== undefined) ? Number(row.verifyType) : -1
                                App.openUserProfile(m, unm, upic, vType)
                            }
                        }
                    }
                }

                onContentHeightChanged: {
                    if (search_page.visible && !loading) {
                        Qt.callLater(function(){
                            search_page.restoreScroll()
                        })
                    }
                }
                onCountChanged: {
                    if (search_page.visible && count > 0 && !loading) {
                        resultGrid.forceLayout()
                        Qt.callLater(function(){ search_page.restoreScroll() })
                    }
                }

                ScrollBar.vertical: FluScrollBar {}

                // 滚动到底，自动加载下一页（参考 RecommendPage 的 checkLoadMore 方式）
                onContentYChanged: {
                    if (search_page.visible && search_page.hasSearched
                            && resultGrid.height > 0
                            && resultGrid.contentY + resultGrid.height >= resultGrid.contentHeight - search_page.cardWidth) {
                        search_page.appendSearchResults()
                    }
                }
            }
        }
        } // 关闭顶层 ColumnLayout（顶部栏 + 结果区）
    }     // 关闭 FluFrame（searchFrame）

    // ====== 视频播放器 overlay（从 HistoryPage 复制，支持视频+番剧+切换动画） ======
    // 注意：FluPage 内部会把 children 包在 contentItem 里，所以这里的 parent
    // 是 contentItem（尺寸和 FluPage 完全一致）。用 anchors.fill: parent 而不是
    // search_page，否则 "Cannot anchor to an item that isn't a parent or sibling"
    // 导致 videoOverlay 宽高 0×0，视频加载了但用户看不见。
    // 兜底拦截滚轮：videoVisible=true 时消费滚轮，阻止穿透到底层 resultGrid
    MouseArea {
        anchors.fill: parent
        z: 99
        enabled: search_page.videoVisible
        acceptedButtons: Qt.NoButton
        hoverEnabled: true
        onWheel: function(wheel) { wheel.accepted = true }
    }

    // 兜底拦截滚轮：liveVisible=true 时消费滚轮，阻止穿透到底层 resultGrid
    MouseArea {
        anchors.fill: parent
        z: 99
        enabled: search_page.liveVisible
        acceptedButtons: Qt.NoButton
        hoverEnabled: true
        onWheel: function(wheel) { wheel.accepted = true }
    }

    Item {
        id: videoOverlay
        // 与 HomePage 的 videoOverlay（fill homeFrame + margins 1）几何
        // 一致：Frame 边距 + overlayMargin 内缩，播放器不遮 Frame 框线。
        // 注意 anchors 单边 margin 会覆盖 margins 基数，故写成显式和
        anchors.fill: parent
        anchors.leftMargin: Theme.homeFrameLeftMargin + Theme.playerOverlayMargin
        anchors.rightMargin: Theme.homeFrameRightMargin + Theme.playerOverlayMargin
        anchors.bottomMargin: Theme.homeFrameBottomMargin + Theme.playerOverlayMargin
        anchors.topMargin: Theme.homeFrameTopMargin + Theme.playerOverlayMargin
        z: 104
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
        property string _pendingOpenBvid: ""
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

            MouseArea {
                anchors.fill: parent
                z: -1
                enabled: videoPlayerLoader.active
                onClicked: { /* 仅消费事件，防止穿透到底层搜索卡片 */ }
            }

            Loader {
                id: videoPlayerLoader
                anchors.fill: parent
                active: videoOverlay._playerCreated
                sourceComponent: videoPlayerComponent
            }
        }

        Timer {
            id: videoPlayerDestroyTimer
            interval: 400
            repeat: false
            onTriggered: {
                if (!search_page.videoVisible
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
            videoPlayerDestroyTimer.stop()
            openVideoAnim.stop()
            closeVideoAnim.stop()
            switchVideoSeqAnim.stop()
            if (videoPlayerLoader.item) {
                videoPlayerLoader.item.stopPlayer()
            }
            closeVideoAnim.start()
            videoPlayerDestroyTimer.start()
        }

        function doSwitch(bvid, title, isBangumi, epId, seasonId) {
            videoPlayerDestroyTimer.stop()
            switchVideoSeqAnim.stop()
            closeVideoAnim.stop()
            openVideoAnim.stop()

            _pendingSwitchBvid = bvid
            _pendingSwitchTitle = title
            _pendingSwitchIsBangumi = !!isBangumi
            _pendingSwitchEpId = epId || ""
            _pendingSwitchSeasonId = seasonId || ""
            _playerCreated = true

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

    // 共享弹幕管理器：放在 SearchPage 层级，不随 LivePlayerPage 销毁/重建。
    // 避免 QWebSocket（SSL 握手线程）频繁创建/销毁导致卡死。
    LiveDanmakuManager {
        id: sharedDanmakuManager
    }

    // ====== 直播播放器 overlay（参照 HistoryPage liveOverlay 实现） ======
    Item {
        id: liveOverlay
        // 基准与 videoOverlay 一致：Frame 边距 + playerOverlayMargin 内缩，
        // 所有弹出页尺寸统一（单边 margin 覆盖 margins 基数，故写成显式和）
        anchors.fill: parent
        anchors.leftMargin: Theme.homeFrameLeftMargin + Theme.playerOverlayMargin
        anchors.rightMargin: Theme.homeFrameRightMargin + Theme.playerOverlayMargin
        anchors.bottomMargin: Theme.homeFrameBottomMargin + Theme.playerOverlayMargin
        anchors.topMargin: Theme.homeFrameTopMargin + Theme.playerOverlayMargin
        z: 105
        visible: opacity > 0 || openLiveAnim.running || closeLiveAnim.running
        opacity: 0

        property string liveRoomId: ""
        property string liveTitleText: ""
        property string liveStreamerName: ""
        property bool _playerCreated: false
        property string _pendingOpenLiveRoomId: ""
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
                onCloseRequested: search_page.closeLivePlayer()
            }
        }

        MouseArea {
            anchors.fill: parent
            z: -1
            enabled: livePlayerLoader.active
            onClicked: { /* 仅消费事件，防止穿透到底层搜索卡片 */ }
        }

        Loader {
            id: livePlayerLoader
            anchors.fill: parent
            // 与视频播放页相同策略：active 同时依赖 visible 和 _playerCreated。
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
                if (!search_page.liveVisible
                    && !openLiveAnim.running
                    && !closeLiveAnim.running) {
                    liveOverlay._playerCreated = false
                }
            }
        }

        function doOpen() {
            livePlayerDestroyTimer.stop()
            closeLiveAnim.stop()
            liveOverlay._playerCreated = true
            openLiveAnim.start()
        }

        function doClose() {
            livePlayerDestroyTimer.stop()
            openLiveAnim.stop()
            if (livePlayerLoader.item) {
                livePlayerLoader.item.stopPlayer()
            }
            // 清空 roomId：与视频播放页相同的销毁策略，Loader 会在动画结束后销毁 LivePlayerPage。
            liveOverlay.liveRoomId = ""
            closeLiveAnim.start()
            livePlayerDestroyTimer.start()
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
            onStopped: {
                if (liveOverlay._pendingOpenLiveRoomId) {
                    var newRoomId = liveOverlay._pendingOpenLiveRoomId
                    liveOverlay.liveTitleText = liveOverlay._pendingOpenLiveTitle
                    liveOverlay.liveStreamerName = liveOverlay._pendingOpenLiveStreamer
                    liveOverlay._pendingOpenLiveRoomId = ""
                    // 销毁策略下 doClose 已清空 liveRoomId，这里设置新值会触发 onRoomIdChanged → loadStream
                    liveOverlay.liveRoomId = newRoomId
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
        }
    }

    // 兜底拦截滚轮：userProfileVisible=true 时消费滚轮，阻止穿透到底层 resultGrid
    MouseArea {
        anchors.fill: parent
        z: 99
        enabled: search_page.userProfileVisible
        acceptedButtons: Qt.NoButton
        hoverEnabled: true
        onWheel: function(wheel) { wheel.accepted = true }
    }

    // ====== 用户主页 Overlay（与 HomePage 相同动画模式） ======
    Item {
        id: userProfileOverlay
        // 与 videoOverlay 同几何：Frame 边距 + playerOverlayMargin 内缩，
        // 所有弹出页尺寸统一（单边 margin 覆盖 margins 基数，故写成显式和）
        anchors.fill: parent
        anchors.leftMargin: Theme.homeFrameLeftMargin + Theme.playerOverlayMargin
        anchors.rightMargin: Theme.homeFrameRightMargin + Theme.playerOverlayMargin
        anchors.bottomMargin: Theme.homeFrameBottomMargin + Theme.playerOverlayMargin
        anchors.topMargin: Theme.homeFrameTopMargin + Theme.playerOverlayMargin
        z: 102
        visible: opacity > 0 || openUserProfileAnim.running || closeUserProfileAnim.running
        opacity: 0

        property string profileMid: ""
        property string profileName: ""
        property string profileFace: ""
        property int profileVerify: -1
        property bool _profileCreated: false

        Component {
            id: userProfileComponent
            UserProfilePage {
                anchors.fill: parent
                mid: userProfileOverlay.profileMid
                userName: userProfileOverlay.profileName
                userFace: userProfileOverlay.profileFace
                userVerify: userProfileOverlay.profileVerify
            }
        }

        Item {
            id: userProfileContainer
            anchors.fill: parent
            transform: Translate {
                id: userProfileTranslate
                y: 0
            }
            MouseArea {
                anchors.fill: parent
                z: -1
                enabled: userProfileLoader.active
                onClicked: { /* 仅消费事件 */ }
            }
            Loader {
                id: userProfileLoader
                anchors.fill: parent
                // 守卫：切导航栏时 search_page.visible=false 会使 overlay 的
                // visible 从父级"流动"为 false，若不守卫会立即卸载销毁用户主
                // 页实例，切回导航时重新加载。userProfileVisible 是逻辑状态，
                // 不受父级隐藏影响（与 videoOverlay 的小窗守卫同一模式）
                active: (userProfileOverlay.visible || search_page.userProfileVisible) && userProfileOverlay._profileCreated
                sourceComponent: userProfileComponent
            }
        }

        Timer {
            id: userProfileDestroyTimer
            interval: 250
            repeat: false
            onTriggered: {
                if (!userProfileVisible && !openUserProfileAnim.running && !closeUserProfileAnim.running) {
                    userProfileOverlay._profileCreated = false
                }
            }
        }

        // 与 HomePage 保持一致：立即创建 + 启动动画。
        // 实例化开销发生在动画起始帧，被 OutCubic 缓动自然掩盖；
        // 若延迟到动画结束后再创建，反而会让用户在动画收尾时看到明显卡顿。
        function doOpen() {
            userProfileDestroyTimer.stop()
            closeUserProfileAnim.stop()
            _profileCreated = true
            openUserProfileAnim.start()
        }

        function doClose() {
            openUserProfileAnim.stop()
            closeUserProfileAnim.stop()
            userProfileDestroyTimer.start()
            closeUserProfileAnim.start()
        }

        ParallelAnimation {
            id: openUserProfileAnim
            NumberAnimation {
                target: userProfileOverlay
                property: "opacity"
                from: 0; to: 1; duration: 250
                easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: userProfileTranslate
                property: "y"
                from: userProfileOverlay.height * 0.15; to: 0
                duration: 250
                easing.type: Easing.OutCubic
            }
        }

        ParallelAnimation {
            id: closeUserProfileAnim
            NumberAnimation {
                target: userProfileOverlay
                property: "opacity"
                from: 1; to: 0; duration: 200
                easing.type: Easing.InCubic
            }
            NumberAnimation {
                target: userProfileTranslate
                property: "y"
                from: 0; to: userProfileOverlay.height * 0.15
                duration: 200
                easing.type: Easing.InCubic
            }
        }
    }

    Connections {
        target: App
        function onVideoOpenRequested(bvid, title) {
            // 非当前可见页面不响应，避免多页面同时打开播放器
            if (!search_page.visible) return
            search_page.openVideoPlayer(bvid, title)
        }
        function onBangumiOpenRequested(bvid, epId, seasonId, title) {
            if (!search_page.visible) return
            search_page.openBangumiPlayer(bvid, epId, seasonId, title)
        }
        function onVideoCloseRequested() {
            search_page.closeVideoPlayer()
        }
        function onUserProfileOpenRequested(mid, name, face, verify) {
            if (!search_page.visible) return
            search_page.openUserProfile(mid, name, face, verify)
        }
        function onUserProfileCloseRequested() {
            search_page.closeUserProfile()
        }
    }

    function openUserProfile(mid, name, face, verify) {
        // 若视频/直播打开中，先关闭。顺序必须在 same-mid 去重之前：
        // 下方已开着同用户主页时（主页→视频→点UP本人头像），也要关闭
        // 视频露出主页，而不是因去重提前返回让视频留在原地
        if (videoVisible) closeVideoPlayer()
        if (liveVisible) closeLivePlayer()
        if (userProfileVisible && userProfileOverlay.profileMid === mid) return
        userProfileOverlay.profileMid = mid
        userProfileOverlay.profileName = name || ""
        userProfileOverlay.profileFace = face || ""
        userProfileOverlay.profileVerify = verify !== undefined ? verify : -1
        userProfileVisible = true
        userProfileOverlay.doOpen()
    }

    function closeUserProfile() {
        if (!userProfileVisible) return
        userProfileVisible = false
        userProfileOverlay.doClose()
    }

    function openVideoPlayer(bvid, title) {
        if (search_page.videoVisible && videoOverlay.videoBvid === bvid) return
        var oldBvid = videoOverlay.videoBvid
        var hasOldVideo = search_page.videoVisible && videoOverlay._playerCreated
                         && oldBvid !== "" && oldBvid !== bvid
        videoOverlay.videoTitleText = title
        videoOverlay.videoIsBangumi = false
        videoOverlay.videoEpId = ""
        videoOverlay.videoSeasonId = ""
        videoOverlay.videoBvid = bvid
        if (hasOldVideo) {
            search_page.videoVisible = true
            videoOverlay.doSwitch(bvid, title, false, "", "")
        } else {
            videoOverlay._pendingOpenBvid = bvid
            videoOverlay._pendingOpenIsBangumi = false
            videoOverlay._pendingOpenEpId = ""
            videoOverlay._pendingOpenSeasonId = ""
            search_page.videoVisible = true
            videoOverlay.doOpen()
        }
    }

    function openBangumiPlayer(bvid, epId, seasonId, title) {
        videoOverlay.videoTitleText = title
        videoOverlay.videoIsBangumi = true
        videoOverlay.videoEpId = epId
        videoOverlay.videoSeasonId = seasonId
        var videoBvid = bvid
        if (!videoBvid || videoBvid.indexOf("bangumi_") === 0) {
            videoBvid = "bangumi_" + (epId || seasonId)
        }
        if (search_page.videoVisible && videoOverlay.videoBvid === videoBvid) return
        videoOverlay.videoBvid = videoBvid
        if (search_page.videoVisible && videoOverlay._playerCreated) {
            search_page.videoVisible = true
            videoOverlay.doSwitch(videoBvid, title, true, epId, seasonId)
        } else {
            videoOverlay._pendingOpenBvid = videoBvid
            videoOverlay._pendingOpenIsBangumi = true
            videoOverlay._pendingOpenEpId = epId
            videoOverlay._pendingOpenSeasonId = seasonId
            search_page.videoVisible = true
            videoOverlay.doOpen()
        }
    }

    function closeVideoPlayer() {
        if (!search_page.videoVisible) return
        search_page.videoVisible = false
        videoOverlay.doClose()
    }

    function openLivePlayer(roomId, title, streamer) {
        // 同一直播间已打开时直接忽略，避免重复加载
        if (search_page.liveVisible && liveOverlay.liveRoomId === roomId) {
            return
        }
        // 当前正打开其他直播时，先关闭旧的（销毁策略：doClose 会清空 roomId 并启动销毁）
        if (search_page.liveVisible && liveOverlay.liveRoomId !== roomId) {
            liveOverlay.doClose()
        }
        // 使用延迟加载（动画结束后设置 roomId 触发加载），避免动画卡顿
        liveOverlay._pendingOpenLiveRoomId = roomId
        liveOverlay._pendingOpenLiveTitle = title
        liveOverlay._pendingOpenLiveStreamer = streamer
        search_page.liveVisible = true
        liveOverlay.doOpen()
    }

    function closeLivePlayer() {
        if (!search_page.liveVisible) return
        search_page.liveVisible = false
        liveOverlay.doClose()
    }
}
