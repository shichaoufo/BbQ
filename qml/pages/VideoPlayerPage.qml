import QtQuick 2.15
import QtQuick.Window 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import QtQuick.Effects

import FluentUI 1.0
import BiliQt 1.0
import "../components"

Rectangle {
    id: pageRoot
    color: FluTheme.backgroundColor
    radius: 8
    clip: true

    property string bvid: ""
    property string aid: ""
    property string cid: ""
    property string mid: ""
    property string videoTitle: "视频播放"
    property string upName: "加载中..."
    property string upFace: ""
    property string upPendantImage: ""
    property int upVerify: -1
    property string upFans: ""
    property int upVipType: 0
    property string viewCount: "0"
    property string danmakuCount: "0"
    property string pubDate: ""
    property string onlineCount: ""
    property string likeCount: "0"
    property string coinCount: "0"
    property string favoriteCount: "0"
    property int rawLikeCount: 0
    property int rawCoinCount: 0
    property int rawFavoriteCount: 0
    property string shareCount: "0"
    property string cover: ""
    property string description: ""
    property bool isLiked: false
    property bool isDisliked: false
    property bool isCoined: false
    property int coinCountToday: 0
    property int lastCoinMultiply: 0
    property int lastCoinSelectLike: 0
    property bool lastDislikeOldLiked: false
    property bool lastDislikeOldDisliked: false
    property bool isFavorited: false
    property bool isFollowing: false
    property bool isPlaying: false
    property string replyToUser: ""
    property string replyRpid: ""
    property string replyRootRpid: ""
    property bool commentSortByHeat: true
    property int commentTotal: 0
    property int commentPage: 0
    property bool commentLoadingMore: false
    property bool commentHasNextPage: true
    property var videoUrlInfo: null
    property int videoDuration: 0
    property string defaultFavoriteFid: ""
    property bool pendingFavoriteClick: false
    property bool historyReported: false
    property int loadRetryCount: 0
    property string loadErrorMsg: ""
    property bool loadFailed: false
    property bool wasClosed: false
    property string loadingBvid: ""
    property int playbackRetryCount: 0
    property int _savedPositionBeforeRetry: 0
    property bool _retryingPlayback: false
    
    // 番剧相关属性
    property bool isBangumi: false
    property string seasonId: ""
    property string epId: ""
    property int seasonType: 0
    property string bangumiTitle: ""
    property string bangumiCover: ""
    property int bangumiTotalCount: 0
    property string bangumiIndexFormat: ""
    property bool _bangumiFetchingVideoInfo: false  // 标记是否正在为番剧获取视频详情
    property bool _bangumiEpisodesLoaded: false

    // ====== 番剧播放 PGC fallback / 防死循环（显式声明，否则 QML 动态赋值会抛 "Cannot assign to non-existent property"）======
    //  典型场景：仙王的日常生活 第二季，普通 /x/player/wbi/playurl 返回 "啥都没有"（空 playurl），
    //  必须使用 PGC 专用 /pgc/player/web/playurl（PlayUrlManager.getSeasonPlayUrl）。
    property string __bangumiLoopKey: ""        // 格式："{epId}|{cid}"，用于识别同一 ep 的回退循环
    property int __bangumiPlayLoopCount: 0      // 同 (epId,cid) 上 normal→PGC 的回退次数，≥2 就直接硬调 PGC 接口
    property bool __forcePgcPlayUrl: false      // =true 时，real-bvid 分支直接调 PGC getSeasonPlayUrl，不再尝试普通 getPlayUrl

    FluInfoBar {
        id: pageInfoBar
        root: pageRoot
    }

    // 拦截滚轮事件，防止穿透到底层主页滚动。
    // z 设为 0 并启用 hover，确保它能正常接收未被内部 Flickable 消费的滚轮事件。
    MouseArea {
        anchors.fill: parent
        z: 0
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        onWheel: (wheel) => wheel.accepted = true
    }

    property ListModel commentModel: ListModel {}
    property ListModel recommendModel: ListModel {}
    property ListModel uploadModel: ListModel {}
    
    // 延迟加载相关属性
    property bool _commentsLoaded: false
    property bool _relatedLoaded: false
    property bool _relatedRetryBangumi: false
    property bool _uploadsLoaded: false
    property bool _pendingLoadComments: false
    property string _loadingBvid: ""
    property string _loadingMid: ""
    property bool _needLoad: false
    property ListModel episodesModel: ListModel {}  // 选集列表（ugc_season）
    property ListModel pagesModel: ListModel {}  // 分P列表（pages）
    property int uploadPage: 1
    property int uploadTotalPages: 0
    property bool hasUgcSeason: false  // 是否有合集
    property int seasonCurrentIndex: -1  // 当前视频在合集中的索引
    property string seasonTitle: ""  // 合集标题
    property bool hasPages: false  // 是否有多个分P
    property int pageCurrentIndex: -1  // 当前分P索引
    // 分段章节（view_points）：[{title, from, to}]，from/to 单位秒；无章节为空数组
    property var viewPoints: []
    // 空降助手标注片段：[{start, end, category, uuid}]，start/end 单位秒。
    // bsb.conf 缺失时 SponsorBlockManager.available=false，此数组恒为空
    property var sponsorSegments: []
    property bool sponsorEnabled: true           // 自动跳过开关（持久化）
    property bool miniProgressEnabled: true      // 控制栏隐藏时常驻 mini 进度条（持久化）
    property string _sponsorFetchedKey: ""       // 已查询过的 bvid:cid（去重）
    property real _sponsorSkipGuardMs: 0         // 跳过防重入护栏（该时刻前不再触发）
    property string _pendingPageCid: ""  // 切换分P时保存的目标CID
    property int _pendingPageIndex: -1  // 切换分P时保存的目标索引
    
    // 选集 / 合集列表自动滚动标记：首次切换到对应 tab 时为 false，滚过后置 true；
    // clearData / loadData 切换视频时重新置为 false，让下一集 / 下一个番剧重新滚到当前集
    property bool _pagesListAutoScrolled: false
    property bool _ugcEpisodesAutoScrolled: false
    
    // 动态标签列表
    property var pivotTabs: {
        var tabs = ["评论 " + commentTotal]
        if (pagesModel.count > 1) tabs.push("选集")
        if (hasUgcSeason) tabs.push("合集")
        tabs.push("推荐")
        if (!isBangumi) tabs.push("投稿")
        return tabs
    }
    property int tabCount: pivotTabs.length
    
    // StackLayout 结构（固定索引）: 
    // index 0: 评论
    // index 1: 选集 (Loader, active: pagesModel.count > 1)
    // index 2: 合集 (Loader, active: hasUgcSeason)
    // index 3: 推荐
    // index 4: 投稿
    function stackIndexOf(tabName) {
        switch(tabName) {
        case "评论": return 0
        case "选集": return 1
        case "合集": return 2
        case "推荐": return 3
        case "投稿": return 4
        default: return 0
        }
    }
    
    function switchTab(tabIndex) {
        var tabName = pivotTabs[tabIndex]
        var targetIndex = stackIndexOf(tabName)
        rightStack.currentIndex = targetIndex

        // ===== 首次切换到「选集 / 合集」tab 时，自动把当前播放集滚动到可视区中心（避开默认 top 遮挡）=====
        // 仅第一次滚动，之后用户切换 tab 不再强制滚（用户可能自己拖了滚动条想保留位置）；
        // 每次 clearData / 打开新番剧时会重新置为 false，让下次打开新番剧再滚。
        if (targetIndex === stackIndexOf("选集") && !pageRoot._pagesListAutoScrolled) {
            pagesAutoScrollTimer.restart()
        } else if (targetIndex === stackIndexOf("合集") && !pageRoot._ugcEpisodesAutoScrolled) {
            ugcEpisodesAutoScrollTimer.retryCount = 0
            ugcEpisodesAutoScrollTimer.restart()
        }
    }

    // 两个「选集自动滚」Timer：延迟 1 帧（interval=0 或 16ms 等效下一个事件循环 tick）
    // 原因：rightStack.currentIndex 刚赋值的瞬间，Loader 里面的 Flickable/delegate 可能还在 layout，
    //       height/contentHeight/y 可能没算出来，直接设 contentY 会被下一帧 layout 覆盖；
    //       下一个 tick 再赋值，所有尺寸已经稳定，计算一定准确。
    Timer {
        id: pagesAutoScrollTimer
        interval: 0
        repeat: false
        onTriggered: scrollPagesToCurrentIndex()
    }
    Timer {
        id: ugcEpisodesAutoScrollTimer
        interval: 50
        repeat: false
        property int retryCount: 0
        onTriggered: scrollUgcEpisodesToCurrentIndex()
    }

    // 【分P/番剧选集（Stack index=1）】滚到 pageCurrentIndex 对应条目中心
    function scrollPagesToCurrentIndex() {
        var idx = pageRoot.pageCurrentIndex
        var count = pageRoot.pagesModel.count
        if (idx < 0 || idx >= count) {
            pageRoot._pagesListAutoScrolled = true  // 避免之后每次切 tab 都打日志
            return
        }
        // 通过 Loader.item 拿到 Flickable（pagesFlickable 的 id 只在 Loader.sourceComponent 内部可见）
        var loader = pagesTabLoader
        if (!loader || !loader.active) {
            pagesAutoScrollTimer.restart()
            return
        }
        var flick = loader.item  // pagesFlickable（id 只在 Component 内部可见，外部需通过 item 访问）
        if (!flick) {
            pagesAutoScrollTimer.restart()
            return
        }
        var col = flick.contentItem ? flick.contentItem.children[0] : null
        if (!col) {
            pagesAutoScrollTimer.restart()
            return
        }
        // 每个 delegate 高度 44，间距 Theme.spacingSmall；用 col.childAt 兜底拿真实 y 更准
        var delegateItem = col.children[idx]
        if (!delegateItem) {
            pagesAutoScrollTimer.restart()
            return
        }
        var itemTopInContent = col.y + delegateItem.y
        var itemCenterInContent = itemTopInContent + delegateItem.height / 2
        var viewportCenter = flick.height / 2
        var targetY = itemCenterInContent - viewportCenter
        // clamp 到合法范围：contentY 不能 < 0，也不能 > contentHeight - height
        var maxY = Math.max(0, flick.contentHeight - flick.height)
        targetY = Math.max(0, Math.min(targetY, maxY))
        flick.contentY = targetY
        pageRoot._pagesListAutoScrolled = true
    }

    // 【UGC 合集选集（Stack index=2）】滚到 seasonCurrentIndex 对应条目中心（逻辑同分P）
    function scrollUgcEpisodesToCurrentIndex() {
        var idx = pageRoot.seasonCurrentIndex
        var count = pageRoot.episodesModel.count
        if (idx < 0 || idx >= count) {
            pageRoot._ugcEpisodesAutoScrolled = true
            ugcEpisodesAutoScrollTimer.retryCount = 0
            return
        }
        var loader = ugcEpisodesTabLoader
        if (!loader || !loader.active) {
            if (ugcEpisodesAutoScrollTimer.retryCount < 10) {
                ugcEpisodesAutoScrollTimer.retryCount++
                ugcEpisodesAutoScrollTimer.restart()
            } else {
                pageRoot._ugcEpisodesAutoScrolled = true
                ugcEpisodesAutoScrollTimer.retryCount = 0
            }
            return
        }
        var flick = loader.item
        if (!flick || flick.height <= 0 || flick.contentHeight <= 0) {
            if (ugcEpisodesAutoScrollTimer.retryCount < 10) {
                ugcEpisodesAutoScrollTimer.retryCount++
                ugcEpisodesAutoScrollTimer.restart()
            } else {
                pageRoot._ugcEpisodesAutoScrolled = true
                ugcEpisodesAutoScrollTimer.retryCount = 0
            }
            return
        }
        var col = flick.contentItem ? flick.contentItem.children[0] : null
        if (!col) {
            if (ugcEpisodesAutoScrollTimer.retryCount < 10) {
                ugcEpisodesAutoScrollTimer.retryCount++
                ugcEpisodesAutoScrollTimer.restart()
            } else {
                pageRoot._ugcEpisodesAutoScrolled = true
                ugcEpisodesAutoScrollTimer.retryCount = 0
            }
            return
        }
        // 遍历 Column children，找出 _delegateModelIndex === idx 的委托项
        // 注意：Qt Quick 中 children 顺序不保证与 model 顺序一致，因此通过存储的 model 索引精确匹配
        var delegateItem = null
        for (var ci = 0; ci < col.children.length; ci++) {
            var child = col.children[ci]
            if (child && child._delegateModelIndex === idx) {
                delegateItem = child
                break
            }
        }
        if (!delegateItem) {
            if (ugcEpisodesAutoScrollTimer.retryCount < 10) {
                ugcEpisodesAutoScrollTimer.retryCount++
                ugcEpisodesAutoScrollTimer.restart()
            } else {
                pageRoot._ugcEpisodesAutoScrolled = true
                ugcEpisodesAutoScrollTimer.retryCount = 0
            }
            return
        }
        var itemTopInContent = col.y + delegateItem.y
        var itemCenterInContent = itemTopInContent + delegateItem.height / 2
        var viewportCenter = flick.height / 2
        var targetY = itemCenterInContent - viewportCenter
        var maxY = Math.max(0, flick.contentHeight - flick.height)
        targetY = Math.max(0, Math.min(targetY, maxY))
        flick.contentY = targetY
        pageRoot._ugcEpisodesAutoScrolled = true
        ugcEpisodesAutoScrollTimer.retryCount = 0
    }
    
    // 将StackLayout的索引转换为pivotTabs中的标签索引
    // 处理StackLayout中的子项可能不总是可见的情况
    function stackIndexToTabIndex(stackIndex) {
        // 如果StackLayout的index=1（选集）但选集标签不可见，回退到评论
        if (stackIndex === 1 && pagesModel.count <= 1) {
            return 0  // 回退到评论标签
        }
        // 如果StackLayout的index=2（合集）但合集标签不可见，回退到评论
        if (stackIndex === 2 && !hasUgcSeason) {
            return 0  // 回退到评论标签
        }
        for (var i = 0; i < pivotTabs.length; i++) {
            if (stackIndexOf(pivotTabs[i]) === stackIndex) return i
        }
        return 0
    }
    
    // 强制刷新 pivotTabs 属性（用于模型数据变化后触发UI更新）
    function refreshPivotTabs() {
        // 重新计算标签
        var tabs = ["评论 " + commentTotal]
        if (pagesModel.count > 1) tabs.push("选集")
        if (hasUgcSeason) tabs.push("合集")
        tabs.push("推荐")
        if (!isBangumi) tabs.push("投稿")

        // 去重：内容完全一致就不赋值，避免 pivot UI 反复刷新造成卡顿
        if (pivotTabs && pivotTabs.length === tabs.length) {
            var same = true
            for (var ti = 0; ti < tabs.length; ti++) {
                if (pivotTabs[ti] !== tabs[ti]) { same = false; break }
            }
            if (same) {
                return
            }
        }
        pivotTabs = tabs
    }

    property int rightPanelWidth: Theme.playerRightPanelWidth
    property int smallSpacing: Theme.spacingSmall
    property int mediumSpacing: Theme.spacingMedium
    property int largeSpacing: Theme.spacingLarge

    property bool isFullScreen: false
    property bool isMiniWindow: false   // 小窗播放：播放器迁入独立置顶窗口，主窗口隐藏
    property bool controlsVisible: false
    property bool cursorHidden: false   // 鼠标在播放区静止3秒后自动隐藏指针
    // 指针隐藏走应用级 override cursor（App.setPlayerCursorHidden）：
    // MouseArea.cursorShape 依赖叠层光标解析，控制栏 visible 切换后
    // 静止鼠标下窗口光标不会重新求值，会出现指针残留不隐藏的问题
    onCursorHiddenChanged: App.setPlayerCursorHidden(cursorHidden)
    property real volume: 1.0
    property bool danmakuEnabled: true
    // 弹幕帧率限制（高刷屏节流档位）：60/100/120/144，0 = 不限制。
    // 仅刷新率 > 63Hz 的屏幕生效（60Hz 屏本就不节流）。
    // 刷新率取 FramePacer 的 DWM 权威值——QML Screen.refreshRate 在
    // Windows 走 GetDeviceCaps(VREFRESH)，高刷屏常误报 60
    property int danmakuFpsLimit: 60
    readonly property real screenRefreshRate: FramePacer.refreshRate
    property real danmakuSize: 1.0
    property real danmakuOpacity: 1.0
    property int danmakuRangeIndex: 3 // 0=1/4屏, 1=半屏, 2=3/4屏, 3=全屏（与直播一致）
    property int danmakuSpeedIndex: 1 // 0=慢, 1=中, 2=快
    property int danmakuOutlineStyle: 0 // 描边样式：0=描边 1=重墨 2=45°投影（B站三档）
    property real playbackSpeed: 1.0
    readonly property string currentSpeed: {
        var s = playbackSpeed
        if (Math.abs(s - 0.5) < 0.001) return "0.5x"
        if (Math.abs(s - 1.0) < 0.001) return "1.0x"
        if (Math.abs(s - 1.25) < 0.001) return "1.25x"
        if (Math.abs(s - 1.5) < 0.001) return "1.5x"
        if (Math.abs(s - 2.0) < 0.001) return "2.0x"
        return s.toFixed(2) + "x"
    }
    property string currentQuality: ""
    property int currentQualityId: 0
    property var qualityList: []
    // 切换清晰度/编码时保存进度，用于恢复播放位置
    property bool _switchingStream: false
    property int _savedPosition: 0
    property int _pendingSeek: 0

    // 服务器历史播放进度恢复
    property int lastPlayTime: 0          // 单位：毫秒
    property string lastPlayCid: ""
    property bool _historyRestored: false
    property int _lastReportedProgress: -1
    // 弹幕请求去重：记录上一次请求弹幕的 CID 和是否还在请求中
    property string _lastReqDanmakuCid: ""
    property bool _danmakuRequesting: false
    // 延迟加载弹幕：把请求计划到 mpv fileLoaded 后 1s 再触发，避免首帧解码 + 弹幕XML解析同时抢 CPU 造成画面顿一下
    property string _pendingDanmakuCid: ""

    // 心跳上报：每 15 秒同步一次播放进度到 B 站服务器
    Timer {
        id: heartbeatTimer
        interval: 15000
        repeat: true
        onTriggered: {
            if (!Login.isLoggedIn || pageRoot.aid === "" || pageRoot.cid === "") return
            if (!pageRoot.isPlaying || mpvPlayer.duration <= 0) return
            var progress = Math.floor(mpvPlayer.position / 1000)
            if (progress <= 0) return
            doReportHistory(progress, false)
        }
    }

    // 控制栏自动隐藏：鼠标静止 3 秒后隐藏（暂停时保持控制栏可见，与官方行为一致）
    Timer {
        id: hideControlsTimer
        interval: 3000
        onTriggered: {
            // 豁免：悬停控制栏 / 弹出面板或菜单打开时不隐藏，继续等待
            if (controlOverlayActive()) {
                hideControlsTimer.restart()
                return
            }
            if (mpvPlayer.playing) {
                pageRoot.controlsVisible = false
                pageRoot.cursorHidden = true
            } else {
                hideControlsTimer.restart()
            }
        }
    }

    // 鼠标指针自动隐藏：静止 3 秒后隐藏（控制栏还可见时随控制栏一起隐藏）
    Timer {
        id: hideCursorTimer
        interval: 3000
        onTriggered: {
            if (controlOverlayActive()) {
                hideCursorTimer.restart()
                return
            }
            if (pageRoot.controlsVisible)
                hideCursorTimer.restart()
            else
                pageRoot.cursorHidden = true
        }
    }

    // 播放区任意鼠标活动：恢复指针并重置自动隐藏计时器
    function playerMouseActivity() {
        if (pageRoot.cursorHidden) pageRoot.cursorHidden = false
        hideCursorTimer.restart()
        if (pageRoot.controlsVisible) hideControlsTimer.restart()
    }

    // ========== 小窗播放（单窗口变身方案）==========
    // 主窗口自身变身为置顶小窗（App.enterMiniPlayerMode 调整几何/最小尺寸/
    // 置顶/圆角），播放器与迷你控制层 reparent 到 main.qml 的 miniPlayerHost。
    // 同一窗口内 reparent：无渲染上下文/场景图/视频链重建，对播放器只是
    // 一次尺寸变化，播放与弹幕时间轴完全不中断。
    function enterMiniWindow() {
        if (pageRoot.isMiniWindow) return
        if (mpvPlayer.source === "" && !mpvPlayer.hasVideo) return   // 无视频时不进小窗
        if (pageRoot.isFullScreen) pageRoot.isFullScreen = false
        closePopups()
        pageRoot.controlsVisible = false
        pageRoot.cursorHidden = false
        hideControlsTimer.stop()
        hideCursorTimer.stop()

        // 小窗初始尺寸：按视频宽高比（未知时 16:9），基准宽 480
        var vw = pageRoot.actualWidth > 0 ? pageRoot.actualWidth : 16
        var vh = pageRoot.actualHeight > 0 ? pageRoot.actualHeight : 9
        var w = 480
        var h = Math.max(120, Math.round(w * vh / vw))

        // 宿主层防护：host 为空时 reparent 会把播放器挂到无窗口父项，
        // mpv itemChange 将误判"彻底离开场景"走销毁分支（白屏无声）
        if (!App.miniPlayerHost) {
            console.warn("[MiniPlayer][Diag] host is null, refusing mini mode")
            return
        }

        // 主窗口变身（C++ 完成：几何收缩/屏幕居中/置顶/圆角；信号同步触发
        // main.qml 隐藏导航与页面栈、显示宿主层）
        App.enterMiniPlayerMode(w, h)
        if (!App.miniPlayerMode) return   // 变身失败（无主窗口等），保持原状

        pageRoot.isMiniWindow = true
        // 同窗口 reparent：迷你 UI 层挂到宿主，播放器与弹幕层挂到迷你 UI 层。
        // anchors.fill: parent 绑定自动重新求值，各项填满新父级
        miniUiRoot.parent = App.miniPlayerHost
        miniUiRoot.visible = true
        mpvPlayer.parent = miniUiRoot
        videoDanmakuOverlay.parent = miniUiRoot
        mpvPlayer.z = 0
        videoDanmakuOverlay.z = 1
        console.warn("[MiniPlayer][Diag] video mini UI reparented, host window:",
                     App.miniPlayerHost.Window !== undefined ? "ok" : "?")
    }

    function exitMiniWindow() {
        if (!pageRoot.isMiniWindow) return
        // C++ 退出变身：miniPlayerModeChanged(false) 同步触发本页
        // _restoreFromMini（reparent 回页面布局）与 main.qml 恢复常规 UI，
        // 随后恢复窗口几何/最小尺寸/状态/置顶
        App.exitMiniPlayerMode()
    }

    // 小窗模式恢复：播放器与弹幕层挂回 playerLayer（videoContainer 的第一个
    // 子项，专用底层容器，叠层由声明位置保证）。任何退出路径（本页按钮/
    // 右键/Esc/窗口关闭/页面销毁）都经 miniPlayerModeChanged 到这里
    function _restoreFromMini() {
        if (!pageRoot.isMiniWindow) return
        pageRoot.isMiniWindow = false
        mpvPlayer.parent = playerLayer
        videoDanmakuOverlay.parent = playerLayer
        mpvPlayer.z = 0
        videoDanmakuOverlay.z = 0
        miniUiRoot.visible = false
        miniUiRoot.parent = pageRoot
        miniControlBar.visible = false
        pageRoot.cursorHidden = false
    }

    // 小窗内播放/暂停（与主控制栏一致：播完再点从头开始）
    function miniTogglePlay() {
        if (mpvPlayer.playing) {
            mpvPlayer.pause()
        } else if (mpvPlayer.source !== "") {
            var duration = mpvPlayer.duration > 0 ? mpvPlayer.duration
                                                  : (pageRoot.videoDuration > 0 ? pageRoot.videoDuration * 1000 : 0)
            if (duration > 0 && mpvPlayer.position >= duration - 500) {
                mpvPlayer.seek(0)
            }
            mpvPlayer.play()
        }
    }
    // 视频编码：0=AVC/H.264, 1=HEVC/H.265, 2=AV1
    property int currentCodec: Settings.videoCodec()
    readonly property var codecOptions: [
        { name: "AVC",  value: 0 },
        { name: "HEVC", value: 1 },
        { name: "AV1",  value: 2 }
    ]
    readonly property string currentCodecName: {
        if (currentCodec === 1) return "HEVC"
        if (currentCodec === 2) return "AV1"
        return "AVC"
    }

    // 视频信息浮层
    property bool showVideoInfo: false
    property int actualWidth: 0
    property int actualHeight: 0
    property string actualVideoCodec: ""
    property string actualVideoFormat: ""
    property string actualContainerFormat: ""
    property real actualFps: 0
    property real actualVideoBitrate: 0
    property real actualAudioBitrate: 0
    property string actualAudioCodec: ""
    property string actualPath: ""

    // 弹幕速度倍率映射：0=慢(0.7x), 1=中(1.0x), 2=快(1.4x)
    function _danmakuSpeedScale(idx) { return [0.7, 1.0, 1.4][idx] || 1.0 }

    // 同步倍速到底层 mpv
    onPlaybackSpeedChanged: {
        if (mpvPlayer) mpvPlayer.speed = playbackSpeed
    }

    function formatFans(num) {
        var n = parseInt(num, 10) || 0
        if (n >= 100000000) return (n / 100000000).toFixed(1) + "亿粉丝"
        if (n >= 10000) return (n / 10000).toFixed(1) + "万粉丝"
        return n + "粉丝"
    }

    function calcCommentPictureSize(w, h, maxW, maxH) {
        if (maxW <= 0) return Qt.size(100, 100)
        var width = w || maxW
        var height = h || maxW
        if (width <= 0 || height <= 0) return Qt.size(maxW, maxW)
        var aspect = width / height
        var outW = Math.min(width, maxW)
        var outH = outW / aspect
        if (outH > maxH) {
            outH = maxH
            outW = outH * aspect
        }
        return Qt.size(Math.max(1, outW), Math.max(1, outH))
    }

    // 评论区图片网格：每行最多 2 张，正方形，宽度为 可用宽度/2 - 间隔
    function calcCommentGridImageSize(containerWidth) {
        var spacing = 8
        var half = Math.floor(containerWidth / 2)
        var size = half - spacing
        return Math.max(1, size)
    }

    // 生成评论图片缩略图 URL，预览时仍使用原图。
    // 动图（gif/webp）保持原图，不添加 @ 压缩后缀，否则会被转成静态图。
    // 静态图参考 wiliwili：只限制宽度、85% 质量、使用 B站笔记评论专用标识，
    // 由 UI 的 PreserveAspectCrop 负责显示中间区域。
    // 请求宽度为显示宽度的 5 倍（与 wiliwili 一致），避免缩略图分辨率过低导致被过度放大裁剪。
    function getCommentImageThumbnailUrl(src, width, isAnimated) {
        if (!src) return ""
        if (isAnimated) return src
        if (src.indexOf("@") >= 0) return src
        var w = Math.round(width * 5)
        return src + "@" + w + "w_85q_!note-comment-multiple.jpg"
    }

    // ListModel 把 QVariantList 封装成了 QQmlListModel，用 count/get(index) 访问
    function commentPicCount(pics) {
        if (!pics) return 0
        if (pics.count !== undefined) return pics.count
        if (pics.length !== undefined) return pics.length
        return 0
    }

    function commentPicAt(pics, idx) {
        if (!pics) return {}
        if (pics.get !== undefined) {
            var item = pics.get(idx)
            return item || {}
        }
        if (pics[idx] !== undefined) return pics[idx] || {}
        return {}
    }

    function escapeHtml(str) {
        return String(str).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    }

    function replaceEmotesInHtml(htmlText, emotes) {
        if (!emotes) return htmlText
        return htmlText.replace(/\[[^\[\]]+\]/g, function(match) {
            var e = emotes[match]
            if (!e || !e.url) return match
            var size = e.width || 24
            if (size <= 0) size = 24
            return '<img src="' + e.url + '" width="' + size + '" height="' + size + '" align="middle" style="vertical-align:middle;">'
        })
    }

    // 将评论中的跳转链接（如购物链接）替换为蓝色可读标题，不保留可点击超链接。
    // 返回结果已经过 HTML 转义，可直接用于 RichText。
    function replaceJumpUrls(htmlText, jumpUrls) {
        if (!jumpUrls) return pageRoot.escapeHtml(htmlText)
        var keys = Object.keys(jumpUrls)
        if (keys.length === 0) return pageRoot.escapeHtml(htmlText)
        // 按长度降序，避免短 key 先替换导致长 key 无法匹配
        keys.sort(function(a, b) { return b.length - a.length })

        var result = ""
        var pos = 0
        while (pos < htmlText.length) {
            var matched = false
            for (var i = 0; i < keys.length; i++) {
                var key = keys[i]
                if (htmlText.substring(pos, pos + key.length) === key) {
                    var title = jumpUrls[key] || key
                    result += '<span style="color:#00A1D6;">' + pageRoot.escapeHtml(title) + '</span>'
                    pos += key.length
                    matched = true
                    break
                }
            }
            if (!matched) {
                result += pageRoot.escapeHtml(htmlText[pos])
                pos++
            }
        }
        return result
    }

    // 将评论中的时间戳（MM:SS 或 HH:MM:SS）替换为蓝色可点击链接，点击后跳转播放进度。
    // 输入必须是已经过 HTML 转义的文本。
    function replaceTimeStamps(htmlText) {
        return htmlText.replace(/(\d{1,2}):(\d{2})(?::(\d{2}))?/g, function(match, p1, p2, p3) {
            var hours = 0, minutes = 0, seconds = 0
            if (p3 !== undefined && p3 !== "") {
                hours = parseInt(p1, 10)
                minutes = parseInt(p2, 10)
                seconds = parseInt(p3, 10)
            } else {
                minutes = parseInt(p1, 10)
                seconds = parseInt(p2, 10)
            }
            // 简单校验，避免把普通数字组合误判为时间
            if (minutes >= 60 || seconds >= 60) return match
            var totalMs = (hours * 3600 + minutes * 60 + seconds) * 1000
            var duration = mpvPlayer.duration > 0 ? mpvPlayer.duration
                                                   : (pageRoot.videoDuration > 0 ? pageRoot.videoDuration * 1000 : 0)
            if (duration > 0 && totalMs > duration) totalMs = duration
            return '<a href="timestamp:' + totalMs + '" style="color:#00A1D6;text-decoration:none;">' + match + '</a>'
        })
    }

    function formatCommentContent(content, emotes, isReply, jumpUrls) {
        var text
        if (isReply && content && content.startsWith("回复 @")) {
            var idx1 = content.indexOf("：")
            var idx2 = content.indexOf(":")
            var idx = idx1 >= 0 ? idx1 : idx2
            if (idx >= 0) {
                var prefix = content.substring(0, idx + 1)
                var rest = content.substring(idx + 1)
                var gray = FluTheme.fontSecondaryColor
                var primary = FluTheme.fontPrimaryColor
                text = '<span style="color:' + gray + ';">' + pageRoot.escapeHtml(prefix) + '</span>'
                     + '<span style="color:' + primary + ';">' + pageRoot.replaceTimeStamps(pageRoot.replaceJumpUrls(rest, jumpUrls)) + '</span>'
            } else {
                text = pageRoot.replaceTimeStamps(pageRoot.replaceJumpUrls(content, jumpUrls))
            }
        } else {
            text = pageRoot.replaceTimeStamps(pageRoot.replaceJumpUrls(content || "", jumpUrls))
        }
        return pageRoot.replaceEmotesInHtml(text, emotes)
    }

    // 评论图片预览
    property bool commentImagePreviewVisible: false
    property var commentPreviewImages: []
    property int commentPreviewIndex: 0

    function openCommentImagePreview(images, startIndex) {
        if (!images || pageRoot.commentPicCount(images) === 0) return
        pageRoot.commentPreviewImages = images
        pageRoot.commentPreviewIndex = Math.max(0, Math.min(startIndex, pageRoot.commentPicCount(images) - 1))
        pageRoot.commentImagePreviewVisible = true
    }

    function closeCommentImagePreview() {
        pageRoot.commentImagePreviewVisible = false
        pageRoot.commentPreviewImages = []
        pageRoot.commentPreviewIndex = 0
    }

    function previewCurrentImageSource() {
        var pic = pageRoot.commentPicAt(pageRoot.commentPreviewImages, pageRoot.commentPreviewIndex)
        return GlobalState.fixImageUrl(pic.imgSrc || "")
    }

    function previewCurrentImageIsAnimated() {
        var pic = pageRoot.commentPicAt(pageRoot.commentPreviewImages, pageRoot.commentPreviewIndex)
        return pic.isAnimated || false
    }

    function previewNextImage() {
        var count = pageRoot.commentPicCount(pageRoot.commentPreviewImages)
        if (count <= 1) return
        pageRoot.commentPreviewIndex = (pageRoot.commentPreviewIndex + 1) % count
    }

    function previewPrevImage() {
        var count = pageRoot.commentPicCount(pageRoot.commentPreviewImages)
        if (count <= 1) return
        pageRoot.commentPreviewIndex = (pageRoot.commentPreviewIndex - 1 + count) % count
    }

    property ListModel danmakuList: ListModel {}
    property int danmakuIndex: 0
    property int lastDanmakuTime: 0
    property int _lastTickTime: -1

    function closePopups() {
        if (volumePopup.opened) volumePopup.close()
        if (danmakuPopup.opened) danmakuPopup.close()
    }

    // 自动隐藏豁免：鼠标悬停在控制栏区域内，或任一弹出面板/菜单
    //（音量、弹幕设置、倍速/编码/清晰度菜单，含面板内的下拉框）打开时，
    // 控制栏与鼠标指针均不进入自动隐藏
    function controlOverlayActive() {
        return controlBarHover.hovered
            || volumePopup.opened || danmakuPopup.opened
            || speedMenu.opened || codecMenu.opened || qualityMenu.opened
            || danmakuInput.activeFocus     // 弹幕输入中不隐藏（失焦即恢复倒计时）
            || colorPickerDialogOpen()       // 取色对话框为模态（挂窗口 Overlay），
                                             // 鼠标事件到不了播放区，必须豁免隐藏
    }

    // FluColorPicker 未暴露内部弹窗的 opened 状态：从其实例的非可视
    // 子对象（resources，兜底扫 data）里找到 Popup 动态读取 opened。
    // 该函数由定时器轮询调用，无需绑定响应
    function colorPickerDialogOpen() {
        var lists = []
        try { lists.push(danmakuColorPicker.resources) } catch (e) {}
        try { lists.push(danmakuColorPicker.data) } catch (e) {}
        for (var k = 0; k < lists.length; k++) {
            var res = lists[k]
            if (!res || !res.length) continue
            for (var i = 0; i < res.length; i++) {
                var r = res[i]
                if (r && "opened" in r)
                    return r.opened
            }
        }
        return false
    }

    function onVideoDanmakuLoaded(list) {
        // 请求完成：清除去重标记（让下一次不同 CID 可以正常请求）
        pageRoot._danmakuRequesting = false
        pageRoot.danmakuList.clear()
        pageRoot.danmakuIndex = 0
        pageRoot.lastDanmakuTime = 0
        pageRoot._lastTickTime = -1
        if (videoDanmakuOverlay) videoDanmakuOverlay.clear()

        for (var i = 0; i < list.length; i++) {
            var item = list[i]
            // B站弹幕类型：1/2/3都是滚动弹幕，4=底部，5=顶部，6=定位，7=高级，8=字幕
            var dType = parseInt(item.type, 10)
            if (dType === 2 || dType === 3) dType = 1
            pageRoot.danmakuList.append({
                text: item.text,
                timestamp: item.timestamp,
                type: dType,
                color: item.color,
                author: item.author,
                fontSize: item.fontSize
            })
        }

        pageRoot.startDanmakuTimer()
    }

    property var danmakuTimer: null

    Timer {
        id: danmakuTimer
        interval: 80
        repeat: true
        running: pageRoot.danmakuEnabled && pageRoot.danmakuList.count > 0
        onTriggered: pageRoot.tickDanmaku()
    }

    function startDanmakuTimer() {
    }

    function stopDanmakuTimer() {
        danmakuTimer.stop()
    }

    function tickDanmaku() {
        if (!pageRoot.danmakuEnabled) return
        if (!pageRoot.isPlaying) return
        if (pageRoot.danmakuList.count === 0) return

        mpvPlayer.updatePosition()
        var currentTime = mpvPlayer.position
        if (currentTime === pageRoot._lastTickTime) return
        pageRoot._lastTickTime = currentTime

        // 检测跳转
        var diff = currentTime - pageRoot.lastDanmakuTime
        if (diff < -1000 || diff > 10000 || pageRoot.lastDanmakuTime === 0) {
            if (pageRoot.lastDanmakuTime !== 0) {
                if (videoDanmakuOverlay) videoDanmakuOverlay.clear()
            }
            pageRoot.danmakuIndex = _findDanmakuIndex(currentTime)
            pageRoot.lastDanmakuTime = currentTime
            if (pageRoot.lastDanmakuTime === 0) {
                pageRoot.lastDanmakuTime = currentTime
            }
            return
        }

        var startTime = pageRoot.lastDanmakuTime
        var endTime = currentTime
        var count = 0
        var maxPerTick = 8

        for (var i = pageRoot.danmakuIndex; i < pageRoot.danmakuList.count && count < maxPerTick; i++) {
            var danmaku = pageRoot.danmakuList.get(i)

            if (danmaku.timestamp > endTime) {
                break
            }

            if (danmaku.timestamp >= startTime) {
                if (videoDanmakuOverlay) {
                    // 透传 fontSize：B站 XML 字号字段（25=普通 18=小字），overlay 内换算缩放
                    videoDanmakuOverlay.addDanmaku(danmaku.text, danmaku.color, danmaku.type, danmaku.fontSize)
                }
                count++
            }

            pageRoot.danmakuIndex = i + 1
        }

        pageRoot.lastDanmakuTime = currentTime
    }

    // 二分查找：返回第一条 timestamp >= time 的弹幕索引
    function _findDanmakuIndex(time) {
        var lo = 0
        var hi = pageRoot.danmakuList.count - 1
        var target = pageRoot.danmakuList.count
        while (lo <= hi) {
            var mid = Math.floor((lo + hi) / 2)
            var t = pageRoot.danmakuList.get(mid).timestamp
            if (t < time) {
                lo = mid + 1
            } else {
                target = mid
                hi = mid - 1
            }
        }
        return target
    }

    Component.onCompleted: {
        // [DIAG] 电影/番剧打不开排查：实例创建时的初始参数（WARN 级，用户日志可见）
        console.warn("[DIAG][VideoPlayerPage] onCompleted bvid:", pageRoot.bvid,
                     "isBangumi:", pageRoot.isBangumi, "epId:", pageRoot.epId,
                     "seasonId:", pageRoot.seasonId)
        loadPlayerSettings()
        // 关键修复：主动检查初始 bvid 值并调用 loadData
        // 避免依赖 onBvidChanged/onVisibleChanged 触发，解决时序竞争问题
        if (pageRoot.bvid && pageRoot.bvid !== "") {
            loadData()
        }
    }

    // 加载视频播放器设置（与直播分别保存）
    function loadPlayerSettings() {
        pageRoot.volume = Settings.getReal("video/volume", 1.0)
        pageRoot.danmakuEnabled = Settings.getBool("video/danmaku/enabled", true)
        pageRoot.danmakuSize = Settings.getReal("video/danmaku/size", 1.0)
        pageRoot.danmakuOpacity = Settings.getReal("video/danmaku/opacity", 1.0)
        pageRoot.danmakuRangeIndex = Settings.getInt("video/danmaku/rangeIndex", 3)
        pageRoot.danmakuSpeedIndex = Settings.getInt("video/danmaku/speedIndex", 1)
        pageRoot.danmakuOutlineStyle = Settings.getInt("video/danmaku/outlineStyle", 0)
        pageRoot.playbackSpeed = Settings.getReal("video/playbackSpeed", 1.0)
        pageRoot.danmakuFpsLimit = Settings.getInt("video/danmaku/fpsLimit", 60)
        pageRoot.sponsorEnabled = Settings.getBool("video/sponsor/enabled", true)
        pageRoot.miniProgressEnabled = Settings.getBool("video/miniProgress/enabled", true)
        FramePacer.setTargetRate(pageRoot.danmakuFpsLimit)
    }

    function savePlayerSettings() {
        Settings.setReal("video/volume", pageRoot.volume)
        Settings.setBool("video/danmaku/enabled", pageRoot.danmakuEnabled)
        Settings.setReal("video/danmaku/size", pageRoot.danmakuSize)
        Settings.setReal("video/danmaku/opacity", pageRoot.danmakuOpacity)
        Settings.setInt("video/danmaku/rangeIndex", pageRoot.danmakuRangeIndex)
        Settings.setInt("video/danmaku/speedIndex", pageRoot.danmakuSpeedIndex)
        Settings.setInt("video/danmaku/outlineStyle", pageRoot.danmakuOutlineStyle)
        Settings.setReal("video/playbackSpeed", pageRoot.playbackSpeed)
        Settings.setInt("video/danmaku/fpsLimit", pageRoot.danmakuFpsLimit)
        Settings.setBool("video/sponsor/enabled", pageRoot.sponsorEnabled)
        Settings.setBool("video/miniProgress/enabled", pageRoot.miniProgressEnabled)
    }

    // 退出动画开始前调用：立即停止 mpv 渲染，让 QSG 回到 vsync 模式
    // 避免退出动画被 mpv 的 30fps 渲染节奏拖慢
    function stopPlayer() {
        closePopups()
        savePlayerSettings()
        pageRoot.reportFinalProgress()
        heartbeatTimer.stop()
        mpvPlayer.stop()
        mpvPlayer.source = ""
        mpvPlayer.audioSource = ""
        danmakuTimer.stop()
        pageRoot.danmakuList.clear()
        pageRoot.danmakuIndex = 0
        pageRoot.lastDanmakuTime = 0
        if (videoDanmakuOverlay) videoDanmakuOverlay.clear()
    }

    // 统一的上报函数，自动判断番剧/普通视频
    // allowZero: 是否允许 progress=0（首次上报时使用）
    function doReportHistory(progress, allowZero) {
        if (!Login.isLoggedIn || pageRoot.aid === "" || pageRoot.cid === "") return
        if (!allowZero && progress <= 0) return
        if (progress < 0) return
        pageRoot._lastReportedProgress = progress
        if (pageRoot.isBangumi && pageRoot.epId && pageRoot.seasonId) {
            InteractionManager.reportBangumiHistory(pageRoot.aid, pageRoot.cid, progress, pageRoot.videoDuration, pageRoot.epId, pageRoot.seasonId)
        } else {
            InteractionManager.reportHistory(pageRoot.aid, pageRoot.cid, progress, pageRoot.videoDuration)
        }
    }

    // 向服务器上报最终播放进度（退出/暂停/切换视频时调用）
    function reportFinalProgress() {
        if (!Login.isLoggedIn || pageRoot.aid === "" || pageRoot.cid === "") return
        if (mpvPlayer.duration <= 0) return
        var progress = Math.floor(mpvPlayer.position / 1000)
        if (progress > 0 && progress !== pageRoot._lastReportedProgress) {
            doReportHistory(progress, false)
        }
    }

    onVisibleChanged: {
        if (!visible) {
            // 小窗模式下页面变为不可见（外部关闭视频的兜底路径）：
            // 退出小窗模式，恢复主窗口几何与常规 UI。播放器随本页子树
            // 由 Loader 统一销毁（不做 reparent——销毁中移动子对象会
            // use-after-free），_restoreFromMini 由 isMiniWindow=false 短路
            if (pageRoot.isMiniWindow) {
                pageRoot.isMiniWindow = false
                App.exitMiniPlayerMode()
                return   // 后续清理由 Component.onDestruction 兜底
            }
            // 进入小窗时 pageStack.visible=false 使本页 visible 从父级"流动"
            // 为 false（Qt 语义：父项 visible 变化直接改变全部子孙的 visible
            // 值并触发 visibleChanged），非真实关闭——播放器随后 reparent 到
            // miniPlayerHost 继续播放，绝不能走下面的关闭清理
            if (App.miniPlayerMode) return
            pageRoot.wasClosed = true
            closePopups()
            pageRoot.reportFinalProgress()
            heartbeatTimer.stop()
            mpvPlayer.stop()
            mpvPlayer.source = ""
            mpvPlayer.audioSource = ""
            pageRoot.clearData()
            pageRoot.danmakuList.clear()
            // 关闭视频时复位 HTTP 连接（等价重启客户端的连接层效果），
            // 下次打开视频走全新连接，规避 480P 画质降级
            PlayUrlManager.resetConnectionState()
        } else {
            // 页面从关闭状态重新可见时，重新拉取数据以保证点赞/点踩/收藏等状态最新
            if (pageRoot.wasClosed && pageRoot.bvid !== "") {
                pageRoot.wasClosed = false
                loadData()
            } else if (pageRoot.bvid !== "" && pageRoot.aid !== "" && mpvPlayer.source === "") {
                // 页面重新可见时，如果已有数据但播放器没有源，重新加载播放
                if (pageRoot.videoUrlInfo) {
                    var info = pageRoot.videoUrlInfo
                    if (info.flvUrl && info.flvUrl !== "") {
                        mpvPlayer.source = info.flvUrl
                        mpvPlayer.audioSource = ""
                    } else if (info.videoUrl && info.videoUrl !== "") {
                        mpvPlayer.source = info.videoUrl
                        mpvPlayer.audioSource = info.audioUrl || ""
                    }
                    mpvPlayer.play()
                    // 重新加载时也重新获取弹幕
                    if (pageRoot.cid !== "" && pageRoot.danmakuList.count === 0) {
                        scheduleDanmakuRequest(pageRoot.cid)
                    }
                } else {
                    loadData()
                }
            }
            // ===== 播放器页面打开时：抢键盘焦点，让 Space/Left/Right/Esc 快捷键能收到 =====
            if (visible) {
                pageRoot.focus = true
                pageRoot.forceActiveFocus()
            }
        }
    }

    // ========== 播放器快捷键 ==========
    //   Space  : 播放 / 暂停
    //   ←      : 快退 5s
    //   →      : 快进 5s
    //   Esc    : 全屏时先退出全屏
    // 生效前提：
    //   1. 页面可见（pageRoot.visible）
    //   2. 当前焦点不在 FluTextBox / TextInput 等可输入控件上（避免打字时空格打断播放）
    //   3. 视频已有 source（mpvPlayer.source !== ""）

    // 判断焦点是否在「可输入控件」上（打字时禁止快捷键打断播放）
    function _isFocusOnInput() {
        var obj = ApplicationWindow.activeFocusItem
        if (!obj) return false
        var name = (obj.objectName || "") + (obj.toString ? obj.toString() : "")
        return name.indexOf("TextBox") >= 0
            || name.indexOf("TextInput") >= 0
            || name.indexOf("TextField") >= 0
            || name.indexOf("LineEdit") >= 0
            || name.indexOf("Search") >= 0
            || name.indexOf("Input") >= 0
    }

    // 封装：播放/暂停切换（与底部播放按钮完全一致，避免两套逻辑漂移）
    function _shortcutTogglePlayPause() {
        closePopups()
        if (mpvPlayer.playing) {
            mpvPlayer.pause()
        } else if (mpvPlayer.source !== "") {
            var duration = mpvPlayer.duration > 0 ? mpvPlayer.duration
                                                  : (pageRoot.videoDuration > 0 ? pageRoot.videoDuration * 1000 : 0)
            if (mpvPlayer.position + 500 >= duration && duration > 0) {
                mpvPlayer.seek(0)
            }
            mpvPlayer.play()
        }
    }

    // 封装：相对 seek ±毫秒，自动 clamp 到 [0, duration]
    function _shortcutSeekRelative(deltaMs) {
        if (!mpvPlayer || mpvPlayer.source === "") return
        var dur = mpvPlayer.duration > 0 ? mpvPlayer.duration
                                        : (pageRoot.videoDuration > 0 ? pageRoot.videoDuration * 1000 : 0)
        var cur = mpvPlayer.position || 0
        var target = cur + deltaMs
        if (dur > 0) target = Math.max(0, Math.min(target, dur))
        else target = Math.max(0, target)
        mpvPlayer.seek(target)
    }

    focus: true
    activeFocusOnTab: false

    // ========== 播放器快捷键（Shortcut：不依赖焦点，窗口级全局匹配，用户点击子控件抢焦点也不影响） ==========
    // Qt Quick Controls 2 Shortcut 的 sequence 支持字符串直接写键名（"Space"、"Left"、"Right"、"Esc" 等），
    // 不用 StandardKey，避免 StandardKey.MoveToNextChar 在某些平台被解释为 "Ctrl+F" 或 "Shift+Right" 等组合键。
    Shortcut {
        sequence: "Space"
        // 只在视频页可见 + 非输入框打字中 + 视频已加载时才生效
        //（小窗模式下页面 visible 从父级"流动"为 false，需用 isMiniWindow 放行）
        enabled: (pageRoot.visible || pageRoot.isMiniWindow) && !pageRoot._isFocusOnInput() && mpvPlayer.source !== ""
        onActivated: {
            _shortcutTogglePlayPause()
        }
    }
    Shortcut {
        sequence: "Left"
        enabled: (pageRoot.visible || pageRoot.isMiniWindow) && !pageRoot._isFocusOnInput() && mpvPlayer.source !== ""
        onActivated: {
            _shortcutSeekRelative(-5000)
        }
    }
    Shortcut {
        sequence: "Right"
        enabled: (pageRoot.visible || pageRoot.isMiniWindow) && !pageRoot._isFocusOnInput() && mpvPlayer.source !== ""
        onActivated: {
            _shortcutSeekRelative(5000)
        }
    }
    Shortcut {
        sequence: "Esc"
        // 全屏退出全屏；小窗模式退出小窗（非全屏非小窗时 Esc 允许交给主窗口关页面）
        enabled: pageRoot.isMiniWindow || (pageRoot.visible && pageRoot.isFullScreen)
        onActivated: {
            if (pageRoot.isMiniWindow)
                pageRoot.exitMiniWindow()
            else
                pageRoot.isFullScreen = false
        }
    }

    // 小窗模式退出监听：非本页发起的退出路径（main.qml 窗口关闭拦截等）
    // 经 App.miniPlayerModeChanged 驱动本页恢复
    Connections {
        target: App
        function onMiniPlayerModeChanged() {
            if (!App.miniPlayerMode)
                pageRoot._restoreFromMini()
        }
    }

    // 视频弹幕发送响应：code=0 成功，非 0 展示错误信息
    Connections {
        target: Api
        function onVideoDanmakuSendResult(data) {
            pageRoot._danmakuSending = false
            _danmakuSendGuard.stop()
            try {
                var dataStr = typeof data === "string" ? data : data.toString()
                var resp = JSON.parse(dataStr)
                if (resp.code === 0) {
                    // 成功后清空输入框；弹幕经服务器入库，重新加载
                    // 视频或刷新页面后可见（不做本地立即上屏，与
                    // danmakuList 的静态加载模型保持一致）
                    danmakuInput.text = ""
                } else {
                    var errMsg = resp.message || ("错误码: " + resp.code)
                    if (resp.code === -101) errMsg = "请先登录后发送弹幕"
                    pageInfoBar.showWarning("发送失败: " + errMsg)
                }
            } catch (e) {
                pageInfoBar.showWarning("发送失败: 响应解析错误")
            }
        }
    }

    Component.onDestruction: {
        closePopups()
        // 小窗模式下被销毁（外部代码直接关页面的兜底路径）：退出小窗模式，
        // 恢复主窗口几何与常规 UI。播放器/迷你 UI 层随本页子树一并销毁
        //（miniUiRoot 已随本页 reparent，销毁中不做 reparent——会 use-after-free），
        // Connections 监听此时可能已失效，必须先置标志再退出，_restoreFromMini
        // 由 isMiniWindow=false 短路跳过
        if (pageRoot.isMiniWindow) {
            pageRoot.isMiniWindow = false
            App.exitMiniPlayerMode()
        }
        // 恢复被隐藏的鼠标指针（override cursor 是应用级的，不恢复会全局无指针）
        App.setPlayerCursorHidden(false)
        // 上报最终播放进度
        pageRoot.reportFinalProgress()
        heartbeatTimer.stop()
        // mpv 实例由 C++ 析构函数统一异步终止；此处不再重复 stop/source，
        // 避免在销毁过程中向 mpv 发送命令触发竞争。
    }

    onBvidChanged: {
        loadData()
    }

    // 加载弹幕（带 CID 去重：同 CID 且上次请求未完成时跳过，避免频繁切换时 CPU 峰值造成播放卡顿）
    function requestDanmakuSafe(cid) {
        if (!cid || cid === "") return
        if (pageRoot._danmakuRequesting && pageRoot._lastReqDanmakuCid === cid) {
            return
        }
        // 若 CID 不同但上次请求还在，仍然允许发新请求（切集后弹幕必须重新拉），只是打印一下提示
        if (pageRoot._danmakuRequesting) {
        }
        pageRoot._lastReqDanmakuCid = cid
        pageRoot._danmakuRequesting = true
        videoDanmakuManager.getDanmakuList(cid)
    }

    // 【计划】弹幕请求：等 mpv fileLoaded（首帧解码完成、画面稳定）之后再延迟 1s 发，
    //   让播放器先渲染出画面、history seek 完成，避免弹幕 XML 解析 + 首帧解码同时打在同一时间点造成"画面顿一下"。
    function scheduleDanmakuRequest(cid) {
        if (!cid || cid === "") return
        pageRoot._pendingDanmakuCid = cid
        // 1. 先启动一个默认 1.2s 的兜底计时器（如果 fileLoaded 信号来得更晚，后面会再 restart）
        danmakuDelayTimer.restart()
    }

    function clearData() {
        // 先保存番剧相关状态，稍后恢复
        var savedIsBangumi = pageRoot.isBangumi
        var savedEpId = pageRoot.epId
        var savedSeasonId = pageRoot.seasonId
        var savedSeasonType = pageRoot.seasonType
        var savedBangumiTitle = pageRoot.bangumiTitle
        var savedBangumiCover = pageRoot.bangumiCover
        var savedBangumiTotalCount = pageRoot.bangumiTotalCount
        var savedBangumiIndexFormat = pageRoot.bangumiIndexFormat
        
        // 加载新视频时重置关闭标记，避免 onVisibleChanged 误触发重复加载
        pageRoot.wasClosed = false
        pageRoot.aid = ""
        pageRoot.cid = ""
        pageRoot.mid = ""
        pageRoot.cover = ""
        pageRoot.upFace = ""
        pageRoot.upPendantImage = ""
        pageRoot.upVerify = -1
        pageRoot.upVipType = 0
        pageRoot.description = ""
        pageRoot.videoUrlInfo = null
        pageRoot.videoDuration = 0
        pageRoot.defaultFavoriteFid = ""
        pageRoot.pendingFavoriteClick = false
        pageRoot.historyReported = false
        pageRoot.lastPlayTime = 0
        pageRoot.lastPlayCid = ""
        // 空降助手状态复位（换视频后旧片段立即失效）
        pageRoot.sponsorSegments = []
        pageRoot._sponsorFetchedKey = ""
        pageRoot._sponsorSkipGuardMs = 0
        pageRoot._historyRestored = false
        pageRoot._lastReportedProgress = -1
        pageRoot._pendingSeek = 0
        pageRoot.playbackRetryCount = 0
        pageRoot._retryingPlayback = false
        pageRoot._savedPositionBeforeRetry = 0
        // 重置番剧相关属性（保留番剧状态用于后续加载）
        pageRoot.isBangumi = savedIsBangumi
        pageRoot.seasonId = savedSeasonId
        pageRoot.epId = savedEpId
        pageRoot.seasonType = savedSeasonType
        pageRoot.bangumiTitle = savedBangumiTitle
        pageRoot.bangumiCover = savedBangumiCover
        pageRoot.bangumiTotalCount = savedBangumiTotalCount
        pageRoot.bangumiIndexFormat = savedBangumiIndexFormat
        pageRoot._bangumiEpisodesLoaded = false
        pageRoot._bangumiFetchingVideoInfo = false
        pageRoot.commentModel.clear()
        pageRoot.recommendModel.clear()
        pageRoot.uploadModel.clear()
        pageRoot.episodesModel.clear()
        pageRoot.pagesModel.clear()
        pageRoot.hasUgcSeason = false
        pageRoot.seasonCurrentIndex = -1
        pageRoot.seasonTitle = ""
        pageRoot.hasPages = false
        pageRoot.pageCurrentIndex = -1
        pageRoot.viewPoints = []
        pageRoot._pendingPageCid = ""
        pageRoot._pendingPageIndex = -1
        pageRoot.commentTotal = 0
        pageRoot.commentPage = 0
        pageRoot.commentLoadingMore = false
        pageRoot.commentHasNextPage = true
        pageRoot.uploadPage = 1
        pageRoot._commentsLoaded = false
        pageRoot._relatedLoaded = false
        pageRoot._relatedRetryBangumi = false
        pageRoot._uploadsLoaded = false
        pageRoot._pendingLoadComments = false
        pageRoot._needLoad = false
        // 弹幕请求去重状态清理
        pageRoot._lastReqDanmakuCid = ""
        pageRoot._danmakuRequesting = false
        // 弹幕延迟请求状态清理：取消尚未发出的弹幕计划请求，避免切视频后旧集弹幕延迟跑出来
        pageRoot._pendingDanmakuCid = ""
        danmakuDelayTimer.stop()
        commentLoadTimer.stop()
        pageRoot.uploadTotalPages = 0
        pageRoot.currentQuality = ""
        pageRoot.currentQualityId = 0
        pageRoot.qualityList = []
        pageRoot.videoTitle = "视频播放"
        pageRoot.upName = "加载中..."
        pageRoot.upFans = ""
        pageRoot.viewCount = "0"
        pageRoot.danmakuCount = "0"
        pageRoot.likeCount = "0"
        pageRoot.coinCount = "0"
        pageRoot.favoriteCount = "0"
        pageRoot.rawLikeCount = 0
        pageRoot.rawCoinCount = 0
        pageRoot.rawFavoriteCount = 0
        pageRoot.shareCount = "0"
        pageRoot.pubDate = ""
        pageRoot.onlineCount = ""
        pageRoot.isLiked = false
        pageRoot.isDisliked = false
        pageRoot.isCoined = false
        pageRoot.coinCountToday = 0
        pageRoot.lastCoinMultiply = 0
        pageRoot.lastCoinSelectLike = 0
        pageRoot.lastDislikeOldLiked = false
        pageRoot.lastDislikeOldDisliked = false
        pageRoot.isFavorited = false
        pageRoot.isFollowing = false
        pageRoot.replyToUser = ""
        pageRoot.replyRpid = ""
        pageRoot.replyRootRpid = ""
        // 清理播放器状态，避免重复打开同一视频时无法重新加载
        mpvPlayer.stop()
        mpvPlayer.source = ""
        mpvPlayer.audioSource = ""
        playbackRetryTimer.stop()
        // 清理弹幕数据
        danmakuTimer.stop()
        pageRoot.danmakuList.clear()
        pageRoot.danmakuIndex = 0
        pageRoot.lastDanmakuTime = 0
        pageRoot._lastTickTime = -1
        if (videoDanmakuOverlay) videoDanmakuOverlay.clear()
        // 关闭页面后重置控制栏和右侧标签页，下次打开新视频时恢复默认状态
        pageRoot.controlsVisible = false
        pageRoot.cursorHidden = false
        hideControlsTimer.stop()
        hideCursorTimer.stop()
        // ===== 选集/合集列表自动滚动标志重置：每个新打开的番剧/视频首次切换到选集 tab 时重新滚到当前集 =====
        pageRoot._pagesListAutoScrolled = false
        pageRoot._ugcEpisodesAutoScrolled = false
        if (rightStack) rightStack.currentIndex = 0
    }

    Timer {
        id: commentLoadTimer
        interval: 300  // 延迟300ms，等待打开动画完成
        repeat: false
        onTriggered: {
            if (pageRoot._pendingLoadComments && pageRoot._loadingBvid === pageRoot.bvid) {
                pageRoot._pendingLoadComments = false
                loadComments()
                pageRoot._commentsLoaded = true
            }
        }
    }

    Timer {
        id: retryTimer
        interval: 1500
        repeat: false
        onTriggered: {
            if (pageRoot.bvid !== "") {
                // 重试时清理旧数据与播放器状态，再重新请求
                pageRoot.clearData()
                // 检查是否是番剧
                var isBangumi = pageRoot.isBangumi
                var currentBvid = pageRoot.bvid || ""
                var isFakeBvid = currentBvid.indexOf("bangumi_") === 0
                
                if (isBangumi && (isFakeBvid || pageRoot.epId)) {
                    // 番剧专用路径重试
                    loadData()
                } else {
                    // 普通视频重试
                    PlayUrlManager.getVideoUrlByBvid(pageRoot.bvid)
                }
            }
        }
    }

    Timer {
        id: playbackRetryTimer
        interval: 2000
        repeat: false
        onTriggered: {
            pageRoot._retryingPlayback = false
            if (pageRoot.wasClosed || pageRoot.bvid === "") {
                return
            }
            var info = pageRoot.videoUrlInfo
            if (!info) {
                console.warn("[VideoPlayerPage] playback retry: no videoUrlInfo, fallback to reload")
                retryTimer.start()
                return
            }
            mpvPlayer.stop()
            mpvPlayer.source = ""
            mpvPlayer.audioSource = ""
            
            // 尝试使用备选 URL（轮换使用不同的 CDN）
            var videoUrl = info.videoUrl || ""
            var audioUrl = info.audioUrl || ""
            var backupUrls = info.videoBackupUrls || []
            var audioBackupUrls = info.audioBackupUrls || []
            var backupIndex = pageRoot.playbackRetryCount % (backupUrls.length + 1)
            
            if (info.flvUrl && info.flvUrl !== "") {
                // FLV 格式：优先使用备选 URL
                var flvBackupUrls = info.flvBackupUrls || []
                if (pageRoot.playbackRetryCount > 0 && flvBackupUrls.length > 0) {
                    var flvBackupIndex = (pageRoot.playbackRetryCount - 1) % flvBackupUrls.length
                    mpvPlayer.source = flvBackupUrls[flvBackupIndex]
                } else {
                    mpvPlayer.source = info.flvUrl
                }
                mpvPlayer.audioSource = ""
            } else if (videoUrl !== "") {
                // DASH 格式：尝试使用备选视频 URL 和音频 URL
                var finalVideoUrl = videoUrl
                var finalAudioUrl = audioUrl
                
                if (pageRoot.playbackRetryCount > 0 && backupUrls.length > 0) {
                    finalVideoUrl = backupUrls[(pageRoot.playbackRetryCount - 1) % backupUrls.length]
                }

                if (pageRoot.playbackRetryCount > 0 && audioBackupUrls.length > 0) {
                    finalAudioUrl = audioBackupUrls[(pageRoot.playbackRetryCount - 1) % audioBackupUrls.length]
                }
                
                mpvPlayer.source = finalVideoUrl
                mpvPlayer.audioSource = finalAudioUrl
            }
            
            mpvPlayer.play()
            pageRoot._pendingSeek = pageRoot._savedPositionBeforeRetry
        }
    }

    function requireLogin() {
        if (!Login.isLoggedIn) {
            pageInfoBar.showWarning("请先登录")
            return false
        }
        return true
    }

    // ===== 发送弹幕 =====
    // 发送中防抖；当前弹幕颜色（QML color → 十进制接口参数）
    property bool _danmakuSending: false
    property color danmakuColor: "#FFFFFF"

    function sendVideoDanmaku(text) {
        if (pageRoot._danmakuSending) return
        var msg = (text || "").trim()
        if (msg === "") return
        if (!Login.isLoggedIn) {
            pageInfoBar.showWarning("请先登录后发送弹幕")
            return
        }
        if (pageRoot.cid === "") return
        pageRoot._danmakuSending = true
        // 颜色转十进制（忽略透明度）：R*65536 + G*256 + B
        var colorDecimal = Math.round(pageRoot.danmakuColor.r * 255) * 65536
                        + Math.round(pageRoot.danmakuColor.g * 255) * 256
                        + Math.round(pageRoot.danmakuColor.b * 255)
        // 弹幕落点：当前播放进度。progress 参数单位为毫秒
        //（mpvPlayer.position 本身即毫秒，直接使用；传秒会被记到
        //  秒/1000 处即 00:00 附近）
        var progress = Math.max(0, mpvPlayer.position)
        Api.sendVideoDanmaku(pageRoot.cid, pageRoot.bvid, msg, colorDecimal, progress)
        _danmakuSendGuard.restart()
    }

    Timer {
        id: _danmakuSendGuard
        interval: 1500
        onTriggered: pageRoot._danmakuSending = false
    }

    function loadData() {
        // [DIAG] 电影/番剧打不开排查：入口状态快照（WARN 级，用户日志可见）
        console.warn("[DIAG][loadData] enter bvid:", pageRoot.bvid,
                     "isBangumi:", pageRoot.isBangumi,
                     "epId:", pageRoot.epId, "seasonId:", pageRoot.seasonId,
                     "cid:", pageRoot.cid, "loadingBvid:", pageRoot.loadingBvid,
                     "visible:", pageRoot.visible)
        
        // 番剧加载 - 统一走番剧API路径（支持只有 seasonId 没有 epId 的情况，如推荐卡片）
        if (pageRoot.isBangumi && (pageRoot.epId || pageRoot.seasonId)) {
            var bangumiKey = pageRoot.epId ? ("bangumi_" + pageRoot.epId) : ("bangumi_s" + pageRoot.seasonId)
            var isFakeBvid = (pageRoot.bvid || "").indexOf("bangumi_") === 0
            
            // 如果已有真实bvid且有cid，说明已经加载过番剧详情，直接加载播放URL
            // 也允许"假bvid + cid + epId 已就绪"进入：部分电影 season 接口不返回 bvid，
            // 此时 bvid 仍是假 bvid，但 cid/epId 已从 season 详情拿到，可直接走 PGC 播放
            if (pageRoot.cid && ((!isFakeBvid && pageRoot.bvid) || (isFakeBvid && pageRoot.epId))) {
                // 防止重复加载：检查 loadingBvid 是否已经是当前 bvid
                if (pageRoot.loadingBvid === pageRoot.bvid) {
                    return
                }
                // ===== 先保存属性，再 clearData() =====
                // 注意：commentLoadTimer.start()、scheduleDanmakuRequest()、_loadingBvid/loadingBvid 的设置
                // 必须放在 clearData() 之后！因为 clearData() 内部会 commentLoadTimer.stop() + danmakuDelayTimer.stop()，
                // 放前面会导致刚启动的 timer 被 clearData() 立即 stop，评论 / 弹幕永远不加载！
                var savedBangumiEpId = pageRoot.epId
                var savedBangumiSeasonId = pageRoot.seasonId
                var savedBangumiSeasonType = pageRoot.seasonType
                var savedBvid = pageRoot.bvid
                var savedCid = pageRoot.cid
                var savedAid = pageRoot.aid
                var savedBangumiTitle = pageRoot.bangumiTitle
                var savedBangumiCover = pageRoot.bangumiCover
                
                // ===== 先 clearData() =====
                clearData()
                
                // ===== clearData() 之后再：设置 loading 标记 + 启动 timer =====
                pageRoot.loadingBvid = savedBvid
                pageRoot._loadingBvid = savedBvid
                pageRoot.loadRetryCount = 0
                pageRoot.loadErrorMsg = ""
                pageRoot.loadFailed = false
                pageRoot.playbackRetryCount = 0
                pageRoot._retryingPlayback = false
                retryTimer.stop()
                playbackRetryTimer.stop()
                pageRoot._commentsLoaded = false
                pageRoot._pendingLoadComments = true
                commentLoadTimer.start()
                scheduleDanmakuRequest(savedCid)
                
                // 恢复所有属性
                pageRoot.isBangumi = true
                pageRoot.epId = savedBangumiEpId
                pageRoot.seasonId = savedBangumiSeasonId
                pageRoot.seasonType = savedBangumiSeasonType
                pageRoot.bvid = savedBvid
                pageRoot.cid = savedCid
                pageRoot.aid = savedAid
                pageRoot.bangumiTitle = savedBangumiTitle
                pageRoot.bangumiCover = savedBangumiCover
                pageRoot.cover = savedBangumiCover
                pageRoot.videoTitle = savedBangumiTitle
                pageRoot._relatedLoaded = false
                pageRoot._uploadsLoaded = false
                
                // 加载播放URL和视频详情
                var bangumiInitQuality = pageRoot.currentQualityId > 0 ? pageRoot.currentQualityId : Settings.defaultQuality()
                // ====== 番剧播放 API 选择策略（本次修复关键，第 3 版） ======
                //  背景：
                //   - 普通 UGC /x/player/wbi/playurl：对 PGC 番剧（如仙王的日常生活 第二季、凡人修仙传 new_ep=null 等）
                //     经常返回 "啥都没有"（playurl 空），必须用 PGC 专用接口
                //   - PGC 专用 /pgc/player/web/playurl：由 PlayUrlManager.getSeasonPlayUrl 实现，同样 WBI 签名 + 带 SESSDATA，
                //     之前注释里的"只能返回 480P（mid=0）"问题在新版代码里已经解决（mid 已正确从 cookie 里拿）
                //  因此：**对 epId 非空的番剧（99%+）默认直接走 PGC playurl**，省掉一轮 normal API 失败 + 回退等待；
                //        只有 epId 空（极少见的 UGC/影视类型 4 走普通接口场景）才 fallback 到 PlayUrlManager.getPlayUrl(normal)
                var forcePgc = !!pageRoot.__forcePgcPlayUrl
                var hasValidEp = (savedBangumiEpId !== undefined && savedBangumiEpId !== null && String(savedBangumiEpId).trim() !== "")
                if (!forcePgc && hasValidEp) forcePgc = true
                if (forcePgc) {
                    pageRoot.__forcePgcPlayUrl = false
                    // 初始加载 → forceMaxQuality=true：Only-FLV 单文件路径必须用 qn=120 才能拿到最高档，
                    // 传 qn=80/64 会被服务器当成"精确匹配"，encode 不存在就静默降级 480P（见 log41）
                    PlayUrlManager.getSeasonPlayUrl(savedCid || "", bangumiInitQuality,
                                                    savedBangumiEpId || "",
                                                    savedBangumiSeasonType || 1,
                                                    savedBvid || "", savedAid || "",
                                                    true /* forceMaxQuality */,
                                                    savedBangumiSeasonId || "")
                } else {
                    PlayUrlManager.getPlayUrl(savedAid, savedCid, bangumiInitQuality)
                }
                pageRoot._bangumiFetchingVideoInfo = true
                PlayUrlManager.getVideoUrlByBvid(savedBvid, savedCid, true)
                
                // 加载剧集列表 - 使用保存的cid避免竞态条件
                if (savedBangumiSeasonId) {
                    PlayUrlManager.getSeasonEpisodes(savedBangumiSeasonId, savedCid)
                }
                return
            }
            
            // 使用假bvid（bangumi_前缀）的首次加载
            if (pageRoot.loadingBvid === bangumiKey) {
                return
            }
            pageRoot.loadingBvid = bangumiKey
            pageRoot.loadRetryCount = 0
            pageRoot.loadErrorMsg = ""
            pageRoot.loadFailed = false
            pageRoot.playbackRetryCount = 0
            pageRoot._retryingPlayback = false
            retryTimer.stop()
            playbackRetryTimer.stop()
            
            // 保存番剧属性
            var savedBangumiEpId = pageRoot.epId
            var savedBangumiSeasonId = pageRoot.seasonId
            var savedBangumiSeasonType = pageRoot.seasonType
            var savedPendingPageCid = pageRoot._pendingPageCid
            var savedPendingPageIndex = pageRoot._pendingPageIndex
            
            clearData()
            
            // 恢复番剧属性
            pageRoot.isBangumi = true
            pageRoot.epId = savedBangumiEpId
            pageRoot.seasonId = savedBangumiSeasonId
            pageRoot.seasonType = savedBangumiSeasonType
            pageRoot._pendingPageCid = savedPendingPageCid
            pageRoot._pendingPageIndex = savedPendingPageIndex
            
            // 调用番剧API获取详情：有 epId 用 epId，没有 epId（推荐卡片只有 seasonId）用 seasonId
            if (pageRoot.epId && pageRoot.epId !== "") {
                PlayUrlManager.getBangumiByEpId(pageRoot.epId)
            } else if (pageRoot.seasonId && pageRoot.seasonId !== "") {
                PlayUrlManager.getBangumiBySeasonId(pageRoot.seasonId)
            } else {
            }
            return
        }
        
        // 普通视频加载
        if (!pageRoot.bvid || pageRoot.bvid === "") return
        if (pageRoot.loadingBvid === pageRoot.bvid) {
            return
        }
        pageRoot.loadingBvid = pageRoot.bvid
        pageRoot.loadRetryCount = 0
        pageRoot.loadErrorMsg = ""
        pageRoot.loadFailed = false
        pageRoot.playbackRetryCount = 0
        pageRoot._retryingPlayback = false
        retryTimer.stop()
        playbackRetryTimer.stop()
        
        // 保存 pending 分P值
        var savedPendingPageCid = pageRoot._pendingPageCid
        var savedPendingPageIndex = pageRoot._pendingPageIndex
        
        clearData()
        
        // 恢复 pending 分P值
        pageRoot._pendingPageCid = savedPendingPageCid
        pageRoot._pendingPageIndex = savedPendingPageIndex
        PlayUrlManager.getVideoUrlByBvid(pageRoot.bvid, savedPendingPageCid)
    }

    function loadComments() {
        if (!pageRoot.aid || pageRoot.aid === "") return
        pageRoot.commentModel.clear()
        pageRoot.commentPage = 1
        pageRoot.commentTotal = 0
        pageRoot.commentLoadingMore = false
        pageRoot.commentHasNextPage = true
        var sort = pageRoot.commentSortByHeat ? 2 : 1
        CommentManager.getComments(pageRoot.aid, 1, 1, 20, sort)
    }

    function loadCommentsPage(page, count) {
        if (!pageRoot.aid || pageRoot.aid === "") return
        if (pageRoot.commentLoadingMore) return
        if (page < 1) page = 1
        pageRoot.commentPage = page
        pageRoot.commentLoadingMore = true
        var sort = pageRoot.commentSortByHeat ? 2 : 1
        CommentManager.getComments(pageRoot.aid, 1, page, count || 20, sort)
    }

    function loadRelated() {
        if (!pageRoot.aid || pageRoot.aid === "") return
        pageRoot.recommendModel.clear()
        if (pageRoot.isBangumi && pageRoot.seasonId) {
            PlayUrlManager.getBangumiRecommendations(pageRoot.seasonId)
        } else {
            PlayUrlManager.getRelatedVideos(pageRoot.aid)
        }
    }

    function loadUploads() {
        if (!pageRoot.mid || pageRoot.mid === "") return
        pageRoot.uploadModel.clear()
        pageRoot.uploadPage = 1
        pageRoot.uploadTotalPages = 0
        PlayUrlManager.getUserUploadedVideos(pageRoot.mid, 1, 20)
    }

    function loadUploadsPage(page, count) {
        if (!pageRoot.mid || pageRoot.mid === "") return
        if (page < 1) page = 1
        pageRoot.uploadPage = page
        PlayUrlManager.getUserUploadedVideos(pageRoot.mid, page, count || 20)
    }

    function pad2(n) {
        return n < 10 ? "0" + n : String(n)
    }

    function formatNumber(num) {
        var n = parseInt(num, 10) || 0
        if (n >= 100000000) return (n / 100000000).toFixed(1) + "亿"
        if (n >= 10000) return (n / 10000).toFixed(1) + "万"
        return String(n)
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

    // ===== 分段章节辅助 =====
    // 当前播放位置命中的章节索引（-1 = 无章节/未命中）
    readonly property int currentChapterIndex: {
        if (viewPoints.length === 0) return -1
        var pos = mpvPlayer.position / 1000
        for (var i = viewPoints.length - 1; i >= 0; i--) {
            if (pos >= viewPoints[i].from) return i
        }
        return 0
    }
    // 章节标题（含序号前缀），超长截断防溢出播放器区域：
    // 按播放器宽估算可容纳字符数（中文按 1 字符约 14px，"当前章节："前缀
    // + 菜单箭头/内边距预留 120px）
    function chapterTitleAt(idx) {
        if (idx < 0 || idx >= viewPoints.length) return "章节"
        var t = (idx + 1) + " · " + viewPoints[idx].title
        var maxChars = Math.max(6, Math.floor((videoContainer.width - 120) / 14))
        if (t.length > maxChars) t = t.substring(0, maxChars - 1) + "…"
        return t
    }

    // ===== 空降助手辅助 =====
    // 片段类别中文名（悬浮气泡/跳过提示用）
    function sponsorCategoryName(cat) {
        switch (cat) {
        case "sponsor": return "恰饭"
        case "selfpromo": return "自我推广"
        case "intro": return "片头"
        case "outro": return "片尾"
        case "interaction": return "互动提醒"
        case "preview": return "预告"
        case "poi_highlight": return "高能点"
        case "filler": return "无意义内容"
        default: return cat
        }
    }
    // 片段类别色（进度条色带用；未知类别灰）
    function sponsorCategoryColor(cat) {
        switch (cat) {
        case "sponsor": return "#FFC107"
        case "selfpromo": return "#29B6F6"
        case "intro": return "#AB47BC"
        case "outro": return "#7E57C2"
        case "interaction": return "#66BB6A"
        case "preview": return "#8D6E63"
        case "poi_highlight": return "#EF5350"
        default: return "#90A4AE"
        }
    }
    // 跳过提示：视频区顶部短暂浮现"已跳过 恰饭 1:30-2:30"
    function showSponsorSkip(seg) {
        sponsorSkipBar.skipText = qsTr("已跳过 ") + sponsorCategoryName(seg.category) + " "
                + formatDuration(Math.floor(seg.start)) + "-" + formatDuration(Math.floor(seg.end))
        sponsorSkipBar.visible = true
        sponsorSkipHideTimer.restart()
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
    
    // 切换到指定分集
    function switchEpisode(aid, cid, bvid) {
        
        // 获取分集标题
        var newTitle = ""
        for (var i = 0; i < episodesModel.count; i++) {
            var ep = episodesModel.get(i)
            if (ep.cid === cid) {
                seasonCurrentIndex = i
                newTitle = ep.title || ep.part || ""
                break
            }
        }
        
        // 如果没有标题，使用当前视频标题或默认标题
        if (!newTitle || newTitle === "") {
            newTitle = pageRoot.videoTitle || "视频播放"
        }
        
        // 如果是同一视频的不同分P，直接在当前页面切换
        if (pageRoot.bvid === bvid) {
            // 设置 pendingPageCid，loadData 会将其作为 overrideCid 传递给 getVideoUrlByBvid
            pageRoot._pendingPageCid = cid
            pageRoot._pendingPageIndex = seasonCurrentIndex
            
            // 更新视频信息
            pageRoot.aid = aid
            pageRoot.cid = cid
            pageRoot.videoTitle = newTitle
            
            // 立即清理旧弹幕，防止切换期间残留
            danmakuTimer.stop()
            pageRoot.danmakuList.clear()
            pageRoot.danmakuIndex = 0
            pageRoot.lastDanmakuTime = 0
            if (videoDanmakuOverlay) videoDanmakuOverlay.clear()
            
            // 强制重新加载视频（即使 bvid 相同，也需要加载新的 cid）
            pageRoot.loadingBvid = ""  // 重置加载状态，确保 loadData 会重新加载
            loadData()
        } else {
            // 不同视频，立即清理旧弹幕再打开新页面
            danmakuTimer.stop()
            pageRoot.danmakuList.clear()
            pageRoot.danmakuIndex = 0
            pageRoot.lastDanmakuTime = 0
            if (videoDanmakuOverlay) videoDanmakuOverlay.clear()
            if (mpvPlayer) mpvPlayer.stop()
            App.openVideo(bvid, newTitle)
        }
    }
    
    // 切换到指定分P（与switchEpisode统一逻辑）
    function switchPage(cid, pageIdx) {
        
        // 如果是同一分P，跳过
        if (pageRoot.cid === cid) return
        
        // 获取分P/选集信息
        var newTitle = ""
        var newEpId = ""
        var newEpAid = ""
        var newEpBvid = ""
        for (var i = 0; i < pagesModel.count; i++) {
            var pg = pagesModel.get(i)
            if (pg.cid === cid) {
                pageRoot.pageCurrentIndex = i
                newTitle = pg.part || ("P" + pg.page)
                newEpId = pg.epId || ""
                newEpAid = pg.aid || ""
                newEpBvid = pg.bvid || ""
                break
            }
        }
        
        // 如果没有标题，使用当前视频标题或默认标题
        if (!newTitle || newTitle === "") {
            newTitle = pageRoot.videoTitle || "视频播放"
        }
        
        // 更新视频信息
        pageRoot.cid = cid
        // 番剧切集时不更新标题（保持番剧名称，不用分集标题覆盖）
        if (!pageRoot.isBangumi) {
            pageRoot.videoTitle = newTitle
        }
        
        // 番剧：更新epId
        if (pageRoot.isBangumi && newEpId) {
            pageRoot.epId = newEpId
        }
        
        // 立即清理旧弹幕，防止切换期间残留
        danmakuTimer.stop()
        pageRoot.danmakuList.clear()
        pageRoot.danmakuIndex = 0
        pageRoot.lastDanmakuTime = 0
        if (videoDanmakuOverlay) videoDanmakuOverlay.clear()
        
        // 番剧模式：切集 → 使用 PGC getSeasonPlayUrl（普通 UGC /x/player/wbi/playurl 对番剧经常返回「啥都没有」）
        if (pageRoot.isBangumi) {
            var epIdForSwitch = (newEpId && String(newEpId).trim() !== "") ? String(newEpId) : pageRoot.epId
            var switchQuality = pageRoot.currentQualityId > 0 ? pageRoot.currentQualityId : Settings.defaultQuality()
            // 切集 = 自动场景 → forceMaxQuality=true（qn=120），理由同初始加载（Only-FLV 下 qn=80 会降级）
            // 使用每集自己的 aid/bvid（策略C UGC WBI 需要正确的 aid+cid 才能查到播放流）
            PlayUrlManager.getSeasonPlayUrl(cid, switchQuality,
                                            epIdForSwitch, pageRoot.seasonType || 1,
                                            newEpBvid || pageRoot.bvid || "", newEpAid || pageRoot.aid || "",
                                            true /* forceMaxQuality */,
                                            pageRoot.seasonId || "")
            // 同时要把 currentQualityId / __forcePgcPlayUrl 重置好，避免后续逻辑再绕去普通接口
            pageRoot.__bangumiLoopKey = ""
            pageRoot.__bangumiPlayLoopCount = 0
            pageRoot.__forcePgcPlayUrl = false
            // 重新加载弹幕（切集 CID 不同，但如果上一次请求还在跑则跳过重复请求）
            scheduleDanmakuRequest(cid)
            return
        }
        
        // 普通视频模式
        // 强制重新加载视频（即使 bvid 相同，也需要加载新的 cid）
        pageRoot._pendingPageCid = cid
        pageRoot._pendingPageIndex = pageIdx
        pageRoot.loadingBvid = ""  // 重置加载状态，确保 loadData 会重新加载
        loadData()
    }

    function getLevelColor(level) {
        switch (level) {
            case 0:
            case 1: return "#BFBFBF"
            case 2: return "#7FD37F"
            case 3: return "#73C9E5"
            case 4: return "#F7B893"
            case 5: return "#F07C3F"
            case 6: return "#E93B3B"
            default: return "#BFBFBF"
        }
    }

    function levelIconSource(level) {
        return "qrc:/BiliQt/icons/level/user-lv" + (level || 0) + ".svg"
    }

    function isUpAuthor(commentMid) {
        if (!pageRoot.mid || !commentMid) return false
        return String(commentMid) === String(pageRoot.mid)
    }

    function toggleCommentSort() {
        pageRoot.commentSortByHeat = !pageRoot.commentSortByHeat
        loadComments()
    }

    Connections {
        target: PlayUrlManager
        function onVideoDetailReady(detail) {
            
            // 番剧专用获取视频详情元数据（UP主、播放量、点赞数等）
            if (pageRoot._bangumiFetchingVideoInfo) {
                pageRoot._bangumiFetchingVideoInfo = false
                // 填充UP主信息
                pageRoot.upName = detail.ownerName || ""
                pageRoot.upFace = detail.ownerFace || ""
                pageRoot.upPendantImage = detail.ownerPendant || ""
                pageRoot.upVerify = detail.ownerVerify !== undefined ? detail.ownerVerify : -1
                pageRoot.mid = detail.ownerMid || pageRoot.mid
                pageRoot.viewCount = pageRoot.formatNumber(detail.view)
                pageRoot.danmakuCount = pageRoot.formatNumber(detail.danmaku)
                pageRoot.rawLikeCount = parseInt(detail.like, 10) || 0
                pageRoot.rawCoinCount = parseInt(detail.coin, 10) || 0
                pageRoot.rawFavoriteCount = parseInt(detail.favorite, 10) || 0
                pageRoot.likeCount = pageRoot.formatNumber(pageRoot.rawLikeCount)
                pageRoot.coinCount = pageRoot.formatNumber(pageRoot.rawCoinCount)
                pageRoot.favoriteCount = pageRoot.formatNumber(pageRoot.rawFavoriteCount)
                pageRoot.shareCount = pageRoot.formatNumber(detail.share)
                pageRoot.pubDate = GlobalState.formatDateTime(detail.pubdate)
                pageRoot.description = detail.description || ""
                // 填充互动状态
                pageRoot.isLiked = !!detail.reqLike
                pageRoot.isDisliked = !!detail.reqDislike
                pageRoot.isCoined = !!detail.reqCoin
                pageRoot.coinCountToday = pageRoot.isCoined ? 1 : 0
                pageRoot.isFavorited = !!detail.reqFavorite
                pageRoot.isFollowing = (detail.reqAttention === 1) || (detail.reqAttention === 2) || (detail.reqAttention === 6)
                // 填充合集/UGC数据（如果有）
                pageRoot.hasUgcSeason = !!detail.hasUgcSeason
                pageRoot.seasonTitle = detail.seasonTitle || ""
                pageRoot.seasonCurrentIndex = detail.seasonCurrentIndex !== undefined ? detail.seasonCurrentIndex : -1
                if (detail.episodes && detail.episodes.length > 0) {
                    episodesModel.clear()
                    for (var ep = 0; ep < detail.episodes.length; ep++) {
                        episodesModel.append(detail.episodes[ep])
                    }
                }
                // 请求推荐视频和用户关系（延迟到用户切换到推荐标签时再加载）
                if (pageRoot.aid !== "") {
                    pageRoot._relatedLoaded = false
                }
                if (pageRoot.isBangumi) {
                    pageRoot._uploadsLoaded = true  // 番剧不加载投稿
                }
                if (Login.isLoggedIn) {
                    if (pageRoot.aid !== "") {
                        PlayUrlManager.getArchiveRelation(pageRoot.aid, pageRoot.bvid)
                    }
                    if (pageRoot.mid !== "") {
                        InteractionManager.getDefaultFavoriteFolder(pageRoot.aid)
                        InteractionManager.getUserRelation(pageRoot.mid)
                        InteractionManager.getUserFollowers(pageRoot.mid)
                    }
                }
                pageRoot.refreshPivotTabs()
                // 如果用户已经在推荐页，则立即触发懒加载（之前可能因为 isBangumi 状态未就绪而加载了非番剧推荐）
                var curTabIdx = stackIndexOf("推荐")
                if (rightStack.currentIndex === curTabIdx && !pageRoot._relatedLoaded) {
                    pageRoot._relatedLoaded = true
                    loadRelated()
                }
                // 未登录时也需要请求用户关系 / 粉丝数（登录时已在前面 isLoggedIn 块中调用）
                if (!Login.isLoggedIn) {
                    if (pageRoot.mid !== "") {
                        InteractionManager.getUserRelation(pageRoot.mid)
                        InteractionManager.getUserFollowers(pageRoot.mid)
                    }
                }
                if (pageRoot.aid !== "" && pageRoot.cid !== "") {
                    PlayUrlManager.getVideoOnlineCount(pageRoot.aid, pageRoot.cid, pageRoot.bvid)
                }
                // 保持推荐懒加载状态；番剧不加载"投稿"页
                pageRoot._relatedLoaded = pageRoot._relatedLoaded
                pageRoot._uploadsLoaded = true
                // ===== 注意：弹幕请求 (scheduleDanmakuRequest)、评论加载定时器 (commentLoadTimer)、
                //       _pendingLoadComments / _loadingBvid / _commentsLoaded 等已经在 loadData() 的
                //       番剧真实 bvid 分支中统一设置过（L1023-L1026），此处不能重复调用，否则同 CID
                //       弹幕拉两次、且 commentLoadTimer 重入造成重复评论请求与额外 CPU 峰值。=====
                return
            }
            
            // 番剧处理 - 简化：直接使用番剧API返回的所有数据
            if (detail.isBangumi) {

                pageRoot.isBangumi = true
                pageRoot.epId = detail.epId || ""
                pageRoot.seasonType = detail.seasonType || 1
                pageRoot.bangumiTitle = detail.title || detail.bangumiTitle || ""
                pageRoot.bangumiCover = detail.pic || detail.bangumiCover || ""
                pageRoot.bangumiTotalCount = detail.bangumiTotalCount || 0
                pageRoot.bangumiIndexFormat = detail.bangumiIndexFormat || ""
                pageRoot.videoTitle = pageRoot.bangumiTitle
                pageRoot.aid = detail.aid || ""
                pageRoot.cid = detail.cid || ""

                // 从推荐/热门页打开番剧时，redirect_url 只包含 ep_id 没有 season_id，
                // 需要先调用 getBangumiByEpId 获取完整的番剧详情（seasonId + 选集列表），
                // getSeasonDetail 会再 emit 一次 videoDetailReady，届时 seasonId 已填充。
                if ((!detail.seasonId || detail.seasonId === "") && pageRoot.epId !== "") {
                    pageRoot.seasonId = ""
                    PlayUrlManager.getBangumiByEpId(pageRoot.epId)
                    return
                }

                pageRoot.seasonId = detail.seasonId || ""

                // 不在此设置 loadingBvid，让 loadData 正常执行并设置
                // 当设置真实 bvid 时，onBvidChanged 会触发 loadData()
                // loadData 会检测到有真实 bvid 和 cid，从而调用 getSeasonPlayUrl
                var realBvid = detail.bvid || ""
                // 部分电影/番剧 season 接口不返回 bvid：此时不能把 pageRoot.bvid 覆盖成空，
                // 否则会破坏绑定 + 触发 onBvidChanged → loadData 命中 loadingBvid 去重 return → 卡死。
                // 保留原 bvid（假 bvid），由下面的 loadData 走 PGC 路径（PGC 靠 epId+cid，不靠 bvid）
                var bvidUnchanged = (pageRoot.bvid === realBvid) || (realBvid === "")
                if (realBvid !== "") {
                    pageRoot.bvid = realBvid
                }
                pageRoot.cover = pageRoot.bangumiCover
                pageRoot.hasPages = false
                pageRoot.hasUgcSeason = false

                // 从推荐/热门页打开番剧时，bvid 本身就是真实 bvid，
                // 设置 pageRoot.bvid 不会触发 onBvidChanged，需要手动调用 loadData
                // 进入番剧播放路径（getSeasonPlayUrl）
                // realBvid 为空时也走这里（bvidUnchanged 被强制为 true）
                if (bvidUnchanged) {
                    // 防死循环：cid 为空说明 season 详情没解析出可用剧集，
                    // 再调 loadData 只会重发 season 请求无限循环（实测电影场景）
                    if (pageRoot.cid === "") {
                        console.warn("[DIAG][VideoPlayerPage] season detail has no cid, stop loading. seasonId:",
                                     pageRoot.seasonId)
                        pageRoot.loadingBvid = ""
                        pageRoot.loadFailed = true
                        pageRoot.loadErrorMsg = "未获取到剧集信息"
                        return
                    }
                    pageRoot.loadingBvid = ""  // 重置加载状态，确保 loadData 能重新加载
                    loadData()
                }

                return
            }
            
            // ★ 番剧模式下：getVideoUrlByBvid(skipPlayUrl=true) 会再 emit 一次普通视频的 videoDetailReady，
            //   该信号不带 isBangumi=true，但此时 pageRoot.isBangumi 已设为 true。
            //   此时应直接 return，避免再次进入普通视频分支（会重复拉评论/弹幕/用户关系/在线人数/历史进度）
            if (pageRoot.isBangumi) {
                return
            }
            
            // 普通视频处理
            if (detail.bvid !== pageRoot.bvid) {
                return
            }
            pageRoot.loadingBvid = ""
            pageRoot.aid = detail.aid || ""
            
            // 确定最终使用的 CID 和 pageCurrentIndex
            var finalCid = detail.cid || ""
            var finalPageIndex = detail.pageCurrentIndex !== undefined ? detail.pageCurrentIndex : -1
            
            // 如果有待切换的分P CID，使用它代替API返回的默认CID
            if (pageRoot._pendingPageCid !== "") {
                finalCid = pageRoot._pendingPageCid
                finalPageIndex = pageRoot._pendingPageIndex
                pageRoot._pendingPageCid = ""
                pageRoot._pendingPageIndex = -1
            }
            
            pageRoot.cid = finalCid
            pageRoot.mid = detail.ownerMid || ""
            pageRoot.videoTitle = detail.title || ""
            pageRoot.upName = detail.ownerName || ""
            pageRoot.upFace = detail.ownerFace || ""
            pageRoot.upPendantImage = detail.ownerPendant || ""
            pageRoot.upVerify = detail.ownerVerify !== undefined ? detail.ownerVerify : -1
            pageRoot.viewCount = pageRoot.formatNumber(detail.view)
            pageRoot.danmakuCount = pageRoot.formatNumber(detail.danmaku)
            pageRoot.rawLikeCount = parseInt(detail.like, 10) || 0
            pageRoot.rawCoinCount = parseInt(detail.coin, 10) || 0
            pageRoot.rawFavoriteCount = parseInt(detail.favorite, 10) || 0
            pageRoot.likeCount = pageRoot.formatNumber(pageRoot.rawLikeCount)
            pageRoot.coinCount = pageRoot.formatNumber(pageRoot.rawCoinCount)
            pageRoot.favoriteCount = pageRoot.formatNumber(pageRoot.rawFavoriteCount)
            pageRoot.shareCount = pageRoot.formatNumber(detail.share)
            pageRoot.pubDate = GlobalState.formatDateTime(detail.pubdate)
            pageRoot.cover = detail.pic || ""
            pageRoot.description = detail.description || ""
            pageRoot.isLiked = !!detail.reqLike
            pageRoot.isDisliked = !!detail.reqDislike
            pageRoot.isCoined = !!detail.reqCoin
            pageRoot.coinCountToday = pageRoot.isCoined ? 1 : 0
            pageRoot.isFavorited = !!detail.reqFavorite
            pageRoot.isFollowing = (detail.reqAttention === 1) || (detail.reqAttention === 2) || (detail.reqAttention === 6)

            // 处理合集/分集数据
            pageRoot.hasUgcSeason = !!detail.hasUgcSeason
            pageRoot.seasonTitle = detail.seasonTitle || ""
            pageRoot.seasonCurrentIndex = detail.seasonCurrentIndex !== undefined ? detail.seasonCurrentIndex : -1
            
            // 填充分集列表（选集）
            episodesModel.clear()
            if (detail.episodes && detail.episodes.length > 0) {
                for (var ep = 0; ep < detail.episodes.length; ep++) {
                    episodesModel.append(detail.episodes[ep])
                }
            }
            
            // 处理分P数据
            pageRoot.hasPages = !!detail.hasPages
            pageRoot.pageCurrentIndex = finalPageIndex

            // 处理分段章节（view_points）：无章节为空数组，UI 整体退场
            var vps = detail.viewPoints || []
            var vpList = []
            for (var vi = 0; vi < vps.length; vi++) {
                vpList.push({
                    title: vps[vi].title,
                    from: vps[vi].from,
                    to: vps[vi].to
                })
            }
            pageRoot.viewPoints = vpList
            
            // 填充分P列表
            pagesModel.clear()
            var pagesLength = detail.pages ? detail.pages.length : 0
            if (detail.pages && pagesLength > 0) {
                for (var pg = 0; pg < pagesLength; pg++) {
                    var pageData = detail.pages[pg]
                    pagesModel.append(pageData)
                }
            } else {
            }

            // ★ 强制刷新标签UI（在所有数据加载完成后）
            pageRoot.refreshPivotTabs()

            // 重置历史进度相关状态，稍后通过 /x/player/wbi/v2 获取
            pageRoot.lastPlayTime = 0
            pageRoot.lastPlayCid = ""
            pageRoot._historyRestored = false
            pageRoot._lastReportedProgress = -1
            pageRoot._pendingSeek = 0

            // 调用 /x/player/wbi/v2 获取历史播放进度与分段章节
            // （view_points 未登录也返回；last_play_time 未登录时为 0，QML 侧已兼容）
            if (pageRoot.aid !== "" && pageRoot.cid !== "") {
                PlayUrlManager.getPlayerDetail(pageRoot.aid, pageRoot.cid, pageRoot.bvid)
            }

            // 如果 Web 详情接口没有返回 req_user，且已登录，再补充调用 archive/relation 获取互动状态
            if (Login.isLoggedIn && !detail.hasReqUser && pageRoot.aid !== "") {
                PlayUrlManager.getArchiveRelation(pageRoot.aid, pageRoot.bvid)
            }
            pageRoot.loadRetryCount = 0
            pageRoot.loadErrorMsg = ""
            pageRoot.loadFailed = false
            if (Login.isLoggedIn) {
                InteractionManager.getDefaultFavoriteFolder(pageRoot.aid)
            }
            InteractionManager.getUserRelation(pageRoot.mid)
            InteractionManager.getUserFollowers(pageRoot.mid)
            if (pageRoot.aid !== "" && pageRoot.cid !== "") {
                PlayUrlManager.getVideoOnlineCount(pageRoot.aid, pageRoot.cid, pageRoot.bvid)
            }
            // 关键优化：延迟加载评论、推荐、投稿，避免动画卡顿
            pageRoot._commentsLoaded = false
            pageRoot._relatedLoaded = false
            pageRoot._uploadsLoaded = false
            pageRoot._pendingLoadComments = true
            pageRoot._needLoad = true
            pageRoot._loadingBvid = pageRoot.bvid
            pageRoot._loadingMid = pageRoot.mid
            commentLoadTimer.start()
            scheduleDanmakuRequest(pageRoot.cid)
        }
        function onSeasonEpisodesReady(episodes, currentCid, currentIndex) {
            
            // 填充番剧选集列表到 pagesModel
            pagesModel.clear()
            for (var i = 0; i < episodes.length; i++) {
                var ep = episodes[i]
                pagesModel.append({
                    "cid": ep.cid,
                    "page": i + 1,
                    "epIndex": ep.epIndex || "",
                    "part": ep.indexTitle || ep.title || ("第" + (i + 1) + "集"),
                    "duration": ep.duration || 0,
                    "epId": ep.epId,
                    "isReleased": ep.isReleased,
                    "aid": ep.aid || "",
                    "bvid": ep.bvid || "",
                    "badge": ep.badge || ""
                })
            }
            
            // 设置当前索引
            pageRoot.pageCurrentIndex = currentIndex >= 0 ? currentIndex : 0
            pageRoot.hasPages = episodes.length > 0
            
            // 刷新标签
            pageRoot.refreshPivotTabs()
        }
        function onVideoOnlineCountReady(text) {
            pageRoot.onlineCount = text || ""
        }
        function onVideoPageListReady(pages, currentCid, currentIndex) {
            
            // 如果主接口已经返回了分P数据，就不覆盖
            if (pageRoot.pagesModel.count > 1) {
                return
            }
            
            // 填充从 /x/player/pagelist 获取的分P列表
            pagesModel.clear()
            for (var pg = 0; pg < pages.length; pg++) {
                pagesModel.append(pages[pg])
            }
            
            // 更新分P状态
            if (pages.length > 1) {
                pageRoot.hasPages = true
                // 尝试找到当前分P的索引
                var foundIndex = -1
                for (var i = 0; i < pages.length; i++) {
                    if (pages[i].cid === pageRoot.cid) {
                        foundIndex = i
                        break
                    }
                }
                pageRoot.pageCurrentIndex = foundIndex >= 0 ? foundIndex : (currentIndex >= 0 ? currentIndex : 0)
                
                // 强制刷新标签UI
                pageRoot.refreshPivotTabs()
            }
        }
        function onArchiveRelationReady(relation) {
            pageRoot.isLiked = !!relation.like
            pageRoot.isDisliked = !!relation.dislike
            pageRoot.isCoined = !!relation.coin
            pageRoot.coinCountToday = pageRoot.isCoined ? 1 : 0
            pageRoot.isFavorited = !!relation.favorite
        }
        function onPlayerDetailReady(detail) {
            var lastPlayTime = detail.lastPlayTime || 0
            var lastPlayCid = detail.lastPlayCid || ""
            pageRoot.lastPlayTime = lastPlayTime
            pageRoot.lastPlayCid = lastPlayCid

            // 分段章节（view_points）：章节只在 player/wbi/v2 接口返回，
            // 覆盖 videoDetailReady 里解析的空列表（该接口无此字段）
            var vps = detail.viewPoints || []
            var vpList = []
            for (var vi = 0; vi < vps.length; vi++) {
                vpList.push({
                    title: vps[vi].title,
                    from: vps[vi].from,
                    to: vps[vi].to
                })
            }
            pageRoot.viewPoints = vpList

            if (lastPlayTime > 0) {
                var historyMs = lastPlayTime
                // 如果历史记录的 cid 不是当前分 P，说明上次看的是其他分 P
                if (lastPlayCid !== "" && lastPlayCid !== pageRoot.cid) {
                    // 不自动跳转，只记录（用户可手动切到对应分 P）
                    pageRoot._pendingSeek = 0
                    return
                }
                // 限制在视频时长范围内
                var maxMs = mpvPlayer.duration > 0 ? mpvPlayer.duration : (pageRoot.videoDuration > 0 ? pageRoot.videoDuration * 1000 : 0)
                if (maxMs > 0 && historyMs >= maxMs) {
                    historyMs = Math.max(0, maxMs - 3000)
                }
                pageRoot._pendingSeek = Math.floor(historyMs)
                // 如果视频已经在播放，立即 seek
                if (mpvPlayer.hasVideo && mpvPlayer.duration > 0) {
                    mpvPlayer.seek(pageRoot._pendingSeek)
                    mpvPlayer.play()
                    // 空降让路：抬高护栏到恢复位置 +1.5s，避免恢复瞬间
                    // （若历史位置恰落在标注片段内）被空降跳过立即覆盖
                    pageRoot._sponsorSkipGuardMs = Math.max(pageRoot._sponsorSkipGuardMs,
                                                            pageRoot._pendingSeek + 1500)
                    pageRoot._pendingSeek = 0
                    pageRoot._historyRestored = true
                }
            }
        }
        function onPlayUrlReady(info) {
            pageRoot.videoUrlInfo = info
            pageRoot.currentQuality = info.qualityName || ""
            pageRoot.currentQualityId = info.qualityId || 0
            pageRoot.videoDuration = info.duration || 0
            // 新流准备就绪，重置播放级重试状态
            pageRoot.playbackRetryCount = 0
            pageRoot._retryingPlayback = false
            playbackRetryTimer.stop()
            // 切换清晰度/编码前保存的进度，等 fileLoaded 信号后再 seek
            if (pageRoot._switchingStream) {
                pageRoot._pendingSeek = pageRoot._savedPosition
                pageRoot._switchingStream = false
                pageRoot._savedPosition = 0
            }
            // 首次加载时 _pendingSeek 已在 onPlayerDetailReady 中设置为服务器历史进度
            // 先清理旧源，避免重复打开同一视频时 mpv 不重新加载
            mpvPlayer.stop()
            mpvPlayer.source = ""
            mpvPlayer.audioSource = ""
            // 优先使用 FLV（音视频合一），否则使用 DASH 分离的音视频 URL
            if (info.flvUrl && info.flvUrl !== "") {
                mpvPlayer.source = info.flvUrl
                mpvPlayer.audioSource = ""
            } else if (info.videoUrl && info.videoUrl !== "") {
                mpvPlayer.source = info.videoUrl
                mpvPlayer.audioSource = info.audioUrl || ""
            } else {
                // [DIAG] 空流：playurl 返回无可用流（版权/付费/试看限制或风控），静默黑屏的根因定位
                console.warn("[DIAG][onPlayUrlReady] EMPTY stream! flvUrl empty + videoUrl empty, qualityId:",
                             info.qualityId, "cid:", pageRoot.cid, "isBangumi:", pageRoot.isBangumi)
            }
            mpvPlayer.play()
            if (Login.isLoggedIn && pageRoot.aid !== "" && pageRoot.cid !== "") {
                // 不再上报 progress=0：它会覆盖服务器存储的历史进度（上次看到
                // 一半 → 打开即清零 → 快速退出时进度丢失 → 下次无法恢复）。
                // "在看"状态由 position>=5s 的首次上报与 15s 心跳维持
                // 启动心跳定时器，持续同步播放进度
                heartbeatTimer.start()
            }
        }
        function onRelatedVideosReady(videos) {
            // 如果普通视频推荐返回0，但当前是番剧模式，则改用番剧推荐API重试
            if (videos.length === 0 && pageRoot.isBangumi && pageRoot.seasonId && !pageRoot._relatedRetryBangumi) {
                pageRoot._relatedRetryBangumi = true
                pageRoot._relatedLoaded = false
                PlayUrlManager.getBangumiRecommendations(pageRoot.seasonId)
                return
            }
            pageRoot.recommendModel.clear()
            for (var i = 0; i < videos.length; i++) {
                var v = videos[i]
                // 区分番剧推荐卡片 vs 普通视频卡片
                var isBangumiCard = !!(v.isBangumiCard) || !!(v.isBangumi && (v.epId && v.seasonId))
                pageRoot.recommendModel.append({
                    bvid: v.bvid || "",
                    title: v.title || "",
                    cover: v.pic || "",
                    author: v.author || "",
                    views: pageRoot.formatNumber(v.play),
                    danmakus: pageRoot.formatNumber(v.danmaku),
                    duration: pageRoot.formatDuration(v.duration),
                    pubDate: GlobalState.formatDateTime(v.pubdate),
                    badgeText: v.badgeText || "",
                    epId: v.epId || "",
                    seasonId: v.seasonId || "",
                    cid: v.cid || "",
                    aid: v.aid || "",
                    isBangumi: !!(v.epId && v.seasonId),
                    // ====== 番剧推荐卡片专用字段 ======
                    isBangumiCard: isBangumiCard,
                    score: v.score || 0,
                    followCount: pageRoot.formatNumber(v.follow),   // 追番数（格式化后）
                    updateInfo: v.updateInfo || ""
                })
            }
        }
        function onUserUploadedVideosReady(videos, currentPage, totalPages) {
            pageRoot.uploadPage = currentPage || 1
            pageRoot.uploadTotalPages = totalPages || 1
            pageRoot.uploadModel.clear()
            for (var i = 0; i < videos.length; i++) {
                var v = videos[i]
                pageRoot.uploadModel.append({
                    bvid: v.bvid || "",
                    title: v.title || "",
                    cover: v.pic || "",
                    author: v.author || pageRoot.upName,
                    views: pageRoot.formatNumber(v.play),
                    danmakus: pageRoot.formatNumber(v.danmaku),
                    duration: pageRoot.formatDuration(v.duration),
                    pubDate: GlobalState.formatDateTime(v.pubdate),
                    badgeText: v.badgeText || ""
                })
            }
        }
        function onErrorOccurred(error) {
            console.warn("[VideoPlayerPage] PlayUrlManager error:", error)
            pageRoot.loadingBvid = ""
            pageRoot.loadErrorMsg = error
            
            // ===== 番剧回退 / 反死循环修复 =====
            // 仙王的日常生活 第二季 这类 PGC 番剧：
            //   普通 /x/player/wbi/playurl 返回 "啥都没有"（啥都木有 / "无" 等变体也一起匹配），
            //   必须走 /pgc/player/web/playurl（getSeasonPlayUrl），否则 fallback→real bvid→普通接口 的死循环。
            var isBangumi = pageRoot.isBangumi
            var hasBangumiEpId = pageRoot.epId
            var currentBvid = pageRoot.bvid || ""
            var isFakeBvid = currentBvid.indexOf("bangumi_") === 0
            if (isBangumi && hasBangumiEpId) {
                var errStr = String(error || "")
                // 匹配"啥都没有 / 啥都木有 / 无数据 / 空响应 / mid=0"等普通接口失败的典型错误字串
                // 也包括 parsePlayUrlData 的 "Failed to parse play URL" / 解析失败 / 清晰度提升失败 这类
                var normalApiFailed = (errStr.indexOf("啥都") >= 0) ||
                                      (errStr.indexOf("没有") >= 0) ||
                                      (errStr.indexOf("木有") >= 0) ||
                                      (errStr.indexOf("无数据") >= 0) ||
                                      (errStr.indexOf("mid=0") >= 0) ||
                                      (errStr.indexOf("-404") >= 0) ||
                                      (errStr.indexOf("未找到") >= 0) ||
                                      (errStr.indexOf("Failed to parse") >= 0) ||
                                      (errStr.indexOf("解析失败") >= 0) ||
                                      (errStr.indexOf("解析错误") >= 0) ||
                                      (errStr.indexOf("清晰度提升失败") >= 0) ||
                                      (errStr.indexOf("只能480P") >= 0) ||
                                      (errStr.indexOf("只能用PGC") >= 0)
                // 番剧专用路径的重入计数（同一个 epId + cid 元组）
                var loopKey = String(hasBangumiEpId) + "|" + String(pageRoot.cid || "")
                if (pageRoot.__bangumiLoopKey !== loopKey) {
                    pageRoot.__bangumiLoopKey = loopKey
                    pageRoot.__bangumiPlayLoopCount = 0
                }
                if (normalApiFailed && (pageRoot.__bangumiPlayLoopCount || 0) < 2) {
                    pageRoot.__bangumiPlayLoopCount = (pageRoot.__bangumiPlayLoopCount || 0) + 1
                    console.warn("[VideoPlayerPage] normal video API failed for bangumi (loop=",
                                 pageRoot.__bangumiPlayLoopCount, "), force PGC-only playurl path. epId=",
                                 hasBangumiEpId, "cid=", pageRoot.cid, "err:", errStr)
                    // 标记：下一次 loadData real-bvid 分支，直接走 PGC getSeasonPlayUrl，不再尝试普通 getPlayUrl
                    pageRoot.__forcePgcPlayUrl = true
                    pageRoot.loadRetryCount = 0
                    // 重新触发 loadData（走 isFakeBvid=true 分支 → season detail → 回来时命中 __forcePgcPlayUrl）
                    var bangumiKey = "bangumi_" + hasBangumiEpId
                    pageRoot.bvid = bangumiKey
                    pageRoot.isBangumi = true
                    pageRoot.epId = hasBangumiEpId
                    return
                }
                if (normalApiFailed) {
                    // 到了这里：已经 loop 了 2 次 PGC 回退仍然失败 → 直接用 PGC 专用接口，不再走 onBvidChanged 再回绕一圈
                    console.warn("[VideoPlayerPage] PGC fallback still failed after 2 loops, directly calling getSeasonPlayUrl. epId=",
                                 hasBangumiEpId, "cid=", pageRoot.cid)
                    var q = pageRoot.currentQualityId > 0 ? pageRoot.currentQualityId : 80
                    PlayUrlManager.getSeasonPlayUrl(pageRoot.cid || "", q,
                                                    String(hasBangumiEpId),
                                                    pageRoot.seasonType || 1,
                                                    "",     // bvid：直接调用不要再触发普通链路
                                                    "",     // aid：同上
                                                    true /* forceMaxQuality：回退重试 → 用 qn=120 */,
                                                    pageRoot.seasonId || "")
                    return
                }
            }

            // ===== 非番剧错误 + 兜底的 unrecognized bangumi 错误（也用 loopCount 限次，≤2） =====
            if (isBangumi && hasBangumiEpId && !isFakeBvid) {
                var loopKey2 = String(hasBangumiEpId) + "|" + String(pageRoot.cid || "")
                if (pageRoot.__bangumiLoopKey !== loopKey2) {
                    pageRoot.__bangumiLoopKey = loopKey2
                    pageRoot.__bangumiPlayLoopCount = 0
                }
                // 无论 normalApiFailed 是否命中，只要是番剧 real-bvid 模式下的错误，统归为一次 loop
                if ((pageRoot.__bangumiPlayLoopCount || 0) < 2) {
                    pageRoot.__bangumiPlayLoopCount = (pageRoot.__bangumiPlayLoopCount || 0) + 1
                    console.warn("[VideoPlayerPage] bangumi load error (unrecognized string), try PGC path. loopCount=",
                                 pageRoot.__bangumiPlayLoopCount, "err:", String(error || "").slice(0, 120))
                    pageRoot.__forcePgcPlayUrl = true
                    var bk = "bangumi_" + hasBangumiEpId
                    pageRoot.bvid = bk
                    pageRoot.isBangumi = true
                    pageRoot.epId = hasBangumiEpId
                    return
                } else {
                    console.warn("[VideoPlayerPage] bangumi load error (unrecognized) hit loop limit (2x) — will NOT retry, show error.")
                }
            }

            pageRoot.loadRetryCount += 1
            if (pageRoot.loadRetryCount <= 3) {
                retryTimer.start()
            } else {
                pageRoot.loadFailed = true
                console.warn("[VideoPlayerPage] loadData failed after 3 retries")
            }
        }
        function onUpVipReady(vipType) {
            pageRoot.upVipType = vipType || 0
        }
        function onUpPendantReady(pendantImage) {
            pageRoot.upPendantImage = pendantImage || ""
        }
        function onQualityListReady(list) {
            pageRoot.qualityList = list
        }
    }

    Connections {
        target: CommentManager
        function onCommentsReady(comments, page, total, sort) {
            if (page > 0) {
                pageRoot.commentPage = page
            }
            pageRoot.commentLoadingMore = false
            // 只在第一页或尚未有总数时更新主评论总数，避免翻页到最后一页时比例失真导致页数跳变
            if (pageRoot.commentPage <= 1 || pageRoot.commentTotal <= 0) {
                pageRoot.commentTotal = total || comments.length
            }
            // 如果当前页没有返回主评论，说明已超出实际主评论页数，修正总数
            if (comments.length === 0 && pageRoot.commentPage > 1) {
                pageRoot.commentTotal = (pageRoot.commentPage - 1) * 20
            }
            // 返回数量不足一页时，说明已到末尾，禁用下一页
            pageRoot.commentHasNextPage = comments.length >= 20
            
            // ★ 评论数量更新后强制刷新标签，确保"评论XXX"数字正确
            pageRoot.refreshPivotTabs()
            pageRoot.commentModel.clear()
            for (var i = 0; i < comments.length; i++) {
                var c = comments[i]
                // 把视频 aid 存进 model，delegate 里用 model.aid 访问
                c.aid = pageRoot.aid
                // 展开状态直接放在 model 里；子评论列表用 JSON 字符串存储，
                // ListModel 不能直接存 JS 数组角色，会报 unsupported data type
                c.repliesExpanded = false
                c.repliesJson = JSON.stringify([])
                c.repliesPage = 1
                pageRoot.commentModel.append(c)
            }
            // 数据就位后再复位滚动：避免"先滚回顶部、再等加载"的两段式跳动
            if (commentFlickable) commentFlickable.contentY = 0
        }
        function onSubCommentsReady(rootRpid, comments) {
            var targetRpid = String(rootRpid || "")
            for (var i = 0; i < pageRoot.commentModel.count; i++) {
                var item = pageRoot.commentModel.get(i)
                if (String(item.rpid || "") === targetRpid) {
                    pageRoot.commentModel.setProperty(i, "repliesJson", JSON.stringify(comments))
                    pageRoot.commentModel.setProperty(i, "repliesExpanded", true)
                    break
                }
            }
        }
        function onCommentSent(success, message) {
            if (!success) {
                console.warn("[VideoPlayerPage] send comment failed:", message)
            }
        }
        function onCommentPosted(success, message, comment, root, parent) {
            if (!success || !comment || !comment.rpid) {
                console.warn("[VideoPlayerPage] commentPosted invalid data")
                return
            }
            // 统一补充模型里需要的辅助字段
            comment.aid = pageRoot.aid
            comment.repliesExpanded = false
            comment.repliesJson = JSON.stringify([])
            comment.repliesPage = 1

            var rootId = String(root || "")
            if (rootId === "" || rootId === "0") {
                // 主评论：插到最前面，并更新总数
                pageRoot.commentModel.insert(0, comment)
                pageRoot.commentTotal = (pageRoot.commentTotal || 0) + 1
            } else {
                // 子评论：找到根评论，追加到其 repliesJson 并展开
                for (var i = 0; i < pageRoot.commentModel.count; i++) {
                    var item = pageRoot.commentModel.get(i)
                    if (String(item.rpid || "") === rootId) {
                        var list = JSON.parse(item.repliesJson || "[]") || []
                        list.push(comment)
                        pageRoot.commentModel.setProperty(i, "repliesJson", JSON.stringify(list))
                        pageRoot.commentModel.setProperty(i, "repliesExpanded", true)
                        pageRoot.commentModel.setProperty(i, "count", (item.count || 0) + 1)
                        break
                    }
                }
            }
        }
        function onActionSuccess(action, rpid, success, message) {
        }
        function onErrorOccurred(error) {
            console.warn("[VideoPlayerPage] CommentManager error:", error)
            pageRoot.commentLoadingMore = false
        }
    }

    Connections {
        target: InteractionManager
        function onActionSuccess(action, message) {
            if (action === "coin") {
                pageRoot.coinCountToday += pageRoot.lastCoinMultiply
                pageRoot.rawCoinCount += pageRoot.lastCoinMultiply
                pageRoot.coinCount = pageRoot.formatNumber(pageRoot.rawCoinCount)
                // 投币成功即点亮按钮（投 1 个也变蓝）
                pageRoot.isCoined = true
                pageInfoBar.showSuccess(message)
            }
        }
        function onActionFailed(action, error) {
            console.warn("[VideoPlayerPage] InteractionManager action failed:", action, error)
            // default_folder 是后台预检查（页面加载时自动触发），失败时不弹警告；
            // 仅在用户手动点击收藏按钮时才提示
            if (action === "default_folder") {
                if (pageRoot.pendingFavoriteClick) {
                    pageInfoBar.showWarning(error)
                    pageRoot.pendingFavoriteClick = false
                }
                return
            }
            pageInfoBar.showWarning(error)
            if (action === "favorite") {
                pageRoot.rawFavoriteCount += pageRoot.isFavorited ? -1 : 1
                pageRoot.favoriteCount = pageRoot.formatNumber(pageRoot.rawFavoriteCount)
                pageRoot.isFavorited = !pageRoot.isFavorited
            } else if (action === "like") {
                pageRoot.rawLikeCount += pageRoot.isLiked ? -1 : 1
                pageRoot.likeCount = pageRoot.formatNumber(pageRoot.rawLikeCount)
                pageRoot.isLiked = !pageRoot.isLiked
            } else if (action === "dislike") {
                pageRoot.isDisliked = pageRoot.lastDislikeOldDisliked
                if (pageRoot.isLiked !== pageRoot.lastDislikeOldLiked) {
                    pageRoot.isLiked = pageRoot.lastDislikeOldLiked
                    if (pageRoot.lastDislikeOldLiked) {
                        pageRoot.rawLikeCount += 1
                    } else {
                        pageRoot.rawLikeCount -= 1
                    }
                    pageRoot.likeCount = pageRoot.formatNumber(pageRoot.rawLikeCount)
                }
            } else if (action === "follow" || action === "unfollow") {
                pageRoot.isFollowing = !pageRoot.isFollowing
            }
        }
        function onRelationReady(followed, attribute) {
            pageRoot.isFollowing = followed
        }
        function onDefaultFavoriteFolderReady(fid, name) {
            pageRoot.defaultFavoriteFid = fid
            if (pageRoot.pendingFavoriteClick) {
                pageRoot.pendingFavoriteClick = false
                InteractionManager.favoriteVideo(pageRoot.aid, pageRoot.defaultFavoriteFid, 1)
                pageRoot.rawFavoriteCount += 1
                pageRoot.favoriteCount = pageRoot.formatNumber(pageRoot.rawFavoriteCount)
                pageRoot.isFavorited = true
            }
        }
        function onUserFollowersReady(count) {
            pageRoot.upFans = count > 0 ? pageRoot.formatFans(count) : ""
        }
    }

    // 空降助手：查询结果回调（含空结果 = 该视频无标注/查询失败）
    Connections {
        target: SponsorBlockManager
        function onSegmentsReady(bvid, cid, segments) {
            // 过期响应（期间已切视频/切P）：丢弃
            if (bvid !== pageRoot.bvid || cid !== pageRoot.cid) return
            pageRoot.sponsorSegments = segments || []
        }
    }

    // 监听 App 的 bangumiOpenRequested：推荐卡片点击后，在当前播放器页切换到新番剧
    Connections {
        target: App
        function onBangumiOpenRequested(bvid, epId, seasonId, title) {
            if (!pageRoot.visible) return

            pageRoot.clearData()

            // ① 先覆盖番剧跳转参数
            pageRoot.isBangumi = true
            pageRoot.epId = epId || ""
            pageRoot.seasonId = seasonId || ""
            pageRoot.seasonType = 0
            pageRoot.bangumiTitle = title || ""

            // ② 构造用于去重的假 bvid，格式和 loadData 内部的 bangumiKey 完全一致：
            //    - 有 epId: bangumi_{epId}
            //    - 无 epId: bangumi_s{seasonId}
            var needFakeKey = !bvid || bvid === "" || bvid.indexOf("bangumi_") === 0
            var videoBvid
            if (needFakeKey) {
                if (pageRoot.epId && pageRoot.epId !== "") videoBvid = "bangumi_" + pageRoot.epId
                else if (pageRoot.seasonId && pageRoot.seasonId !== "") videoBvid = "bangumi_s" + pageRoot.seasonId
                else videoBvid = "bangumi_s" + Math.floor(Math.random() * 1000000)
            } else {
                videoBvid = bvid
            }

            // ③ 关键：一次性给 bvid 和 loadingBvid 赋值，避免 set bvid 后触发 onBvidChanged 再跑 loadData，
            //    紧接着我们又手动调 loadData，导致加载2次造成卡顿。这里 loadingBvid 先设成假 key，
            //    onBvidChanged 里的 loadData 会命中 "already loading bangumi" 直接 return（相当于屏蔽掉这一次），
            //    然后我们立刻清空 loadingBvid 并调 loadData，保证真正执行1次。
            pageRoot.loadingBvid = videoBvid       // ← 先放占位，用于吞掉 onBvidChanged 的 loadData
            pageRoot._loadingBvid = videoBvid
            pageRoot.bvid = videoBvid              // ← 触发 onBvidChanged → loadData，但被 loadingBvid 命中直接 return
            pageRoot.loadingBvid = ""              // ← 立刻清空，让我们下面手动调的 loadData 能完整执行
            pageRoot._loadingBvid = ""

            pageRoot._needLoad = true
            pageRoot.loadData()
        }
    }

    RowLayout {
        id: mainLayout
        anchors.fill: parent
        anchors.margins: Theme.spacingMedium
        spacing: Theme.spacingMedium

        // ========== 左侧：视频播放区 + 视频信息 ==========
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumWidth: 560

            // ---- 视频播放容器 ----
            Rectangle {
                id: videoContainer
                anchors.fill: parent
                anchors.bottomMargin: pageRoot.isFullScreen ? 0 : bottomPanel.height + pageRoot.smallSpacing
                radius: 6
                clip: true
                color: "#000000"

                // 播放器层：videoContainer 的第一个子项（始终最底层）。
                // 小窗往返的 reparent 挂载点：reparent 会把项追加到目标容器
                // 子项列表末尾，直接挂回 videoContainer 会把播放器排到控制栏/
                // 弹窗等兄弟层之后（视频盖住控制栏）；改用负 z 压底则子项会
                // 绘制到父项自身背景之下，被容器黑色背景挡住（播放区黑屏）。
                // 挂回这个专用底层容器后叠层关系与初始声明完全一致，
                // z 无需任何调整。
                Item {
                    id: playerLayer
                    anchors.fill: parent
                }

                MpvObject {
                    id: mpvPlayer
                    anchors.fill: parent
                    volume: pageRoot.volume
                    onPlayingChanged: {
                        pageRoot.isPlaying = playing
                        if (videoDanmakuOverlay) {
                            if (playing) videoDanmakuOverlay.resume()
                            else videoDanmakuOverlay.pause()
                        }
                        // 暂停时立即上报一次当前进度；恢复播放时重启心跳
                        if (!playing && Login.isLoggedIn && pageRoot.aid !== "" && pageRoot.cid !== "" && mpvPlayer.duration > 0) {
                            heartbeatTimer.stop()
                            var progress = Math.floor(mpvPlayer.position / 1000)
                            if (progress > 0 && progress !== pageRoot._lastReportedProgress) {
                                doReportHistory(progress, false)
                            }
                        } else if (playing && Login.isLoggedIn && pageRoot.aid !== "" && pageRoot.cid !== "") {
                            heartbeatTimer.start()
                        }
                    }
                    onErrorOccurred: {
                        console.warn("[MpvObject] error:", error)
                        // 网络或加载相关错误自动重试
                        var errStr = (error || "").toLowerCase()
                        var isLoadError = errStr.indexOf("loading failed") >= 0
                                        || errStr.indexOf("unable to open") >= 0
                                        || errStr.indexOf("timeout") >= 0
                                        || errStr.indexOf("network") >= 0
                                        || errStr.indexOf("connection") >= 0
                                        || errStr.indexOf("tls") >= 0
                        if (isLoadError && !pageRoot.wasClosed && !pageRoot._retryingPlayback) {
                            pageRoot.playbackRetryCount += 1
                            if (pageRoot.playbackRetryCount <= 5) {
                                // 保存当前位置，重试恢复
                                var pos = mpvPlayer.position
                                pageRoot._savedPositionBeforeRetry = (pos && pos > 0) ? pos : pageRoot._pendingSeek
                                pageRoot._retryingPlayback = true
                                console.warn("[MpvObject] playback error, retry", pageRoot.playbackRetryCount, "/ 5 after 2s, pos:", pageRoot._savedPositionBeforeRetry)
                                playbackRetryTimer.start()
                            } else {
                                pageRoot.loadFailed = true
                                console.warn("[MpvObject] playback failed after 5 retries, giving up")
                            }
                        }
                    }
                    onHasVideoChanged: {
                        if (hasVideo) {
                            videoInfoTimer.restart()
                        }
                    }
                    onFileLoaded: {
                        // 文件加载成功后重置播放级重试状态
                        if (pageRoot._retryingPlayback) {
                            pageRoot._retryingPlayback = false
                            pageRoot.playbackRetryCount = 0
                        }
                        // 文件加载后延迟读取视频信息（覆盖首次加载和切换流两种场景）
                        videoInfoTimer.restart()
                        if (pageRoot._pendingSeek > 0) {
                            pendingSeekTimer.restart()
                        }
                        // ★ 弹幕请求改从这里开始计 1s 延迟（fileLoaded = 首帧解码完成，画面已出），
                        //   避开首帧解码 + 历史进度 seek + 评论解析抢占 CPU 的峰值时间段
                        if (pageRoot._pendingDanmakuCid !== "") {
                            danmakuDelayTimer.restart()
                        }
                        // 空降助手片段查询：与弹幕同窗口触发（一次轻量 JSON GET），
                        // 同一 bvid:cid 只查一次；番剧假 bvid（bangumi_ 前缀）不查。
                        // 查询与 sponsorEnabled 无关——色带展示与开关解耦，
                        // 用户中途开开关时无需重新加载视频
                        var sponsorKey = pageRoot.bvid + ":" + pageRoot.cid
                        if (SponsorBlockManager.available
                                && pageRoot.bvid.indexOf("BV") === 0
                                && pageRoot._sponsorFetchedKey !== sponsorKey) {
                            pageRoot._sponsorFetchedKey = sponsorKey
                            SponsorBlockManager.getSegments(
                                        pageRoot.bvid, pageRoot.cid,
                                        mpvPlayer.duration > 0 ? mpvPlayer.duration / 1000
                                                               : pageRoot.videoDuration)
                        }
                    }
                    Timer {
                        id: videoInfoTimer
                        interval: 300
                        repeat: false
                        onTriggered: {
                            if (!mpvPlayer.hasVideo) return
                            var info = mpvPlayer.getVideoInfo()
                            pageRoot.actualWidth = info["width"] || 0
                            pageRoot.actualHeight = info["height"] || 0
                            pageRoot.actualVideoCodec = info["videoCodec"] || ""
                            pageRoot.actualVideoFormat = info["videoFormat"] || ""
                            pageRoot.actualContainerFormat = info["containerFormat"] || ""
                            pageRoot.actualFps = info["fps"] || 0
                            pageRoot.actualVideoBitrate = info["videoBitrate"] || 0
                            pageRoot.actualAudioBitrate = info["audioBitrate"] || 0
                            pageRoot.actualAudioCodec = info["audioCodec"] || ""
                            pageRoot.actualPath = info["path"] || ""
                        }
                    }
                    Timer {
                        id: pendingSeekTimer
                        // 历史进度恢复 seek 延迟：比默认的 500ms 再长 300ms，
                        // 让解码器先渲染出首帧，避免"立刻 seek"与首帧解码/弹幕解析/评论加载
                        // 同时抢占 CPU/GPU 造成"画面顿一下"的感觉
                        interval: 800
                        repeat: false
                        onTriggered: {
                            if (pageRoot._pendingSeek > 0) {
                                var seekMs = pageRoot._pendingSeek
                                var maxMs = mpvPlayer.duration > 0 ? mpvPlayer.duration : (pageRoot.videoDuration > 0 ? pageRoot.videoDuration * 1000 : 0)
                                if (maxMs > 0 && seekMs >= maxMs) {
                                    seekMs = Math.max(0, maxMs - 3000)
                                }
                                mpvPlayer.seek(seekMs)
                                mpvPlayer.play()
                                // 空降让路：抬高护栏到恢复位置 +1.5s，避免恢复瞬间
                                // （若历史位置恰落在标注片段内）被空降跳过立即覆盖
                                pageRoot._sponsorSkipGuardMs = Math.max(pageRoot._sponsorSkipGuardMs,
                                                                        seekMs + 1500)
                                pageRoot._pendingSeek = 0
                                pageRoot._historyRestored = true
                            }
                        }
                    }
                    // 弹幕延迟计时器：fileLoaded 后 1 秒再请求弹幕，
                    //   避免弹幕 XML 下载 + 解析（3000 条）和首帧解码/历史 seek 同时占满 CPU 造成播放画面"顿一下"
                    Timer {
                        id: danmakuDelayTimer
                        interval: 1000
                        repeat: false
                        onTriggered: {
                            if (pageRoot._pendingDanmakuCid === "") return
                            var targetCid = pageRoot._pendingDanmakuCid
                            // 如果用户在 1s 内快速切集导致 CID 已经变化，跳过旧请求
                            if (targetCid !== pageRoot.cid) {
                                pageRoot._pendingDanmakuCid = ""
                                return
                            }
                            requestDanmakuSafe(targetCid)
                            pageRoot._pendingDanmakuCid = ""
                        }
                    }
                    onPositionChanged: {
                        // 播放超过 5 秒后上报一次历史记录，确保官方客户端能生成观看历史
                        if (!pageRoot.historyReported && pageRoot.aid !== "" && pageRoot.cid !== "" && position >= 5000) {
                            pageRoot.historyReported = true
                            if (Login.isLoggedIn) {
                                var progress = Math.floor(position / 1000)
                                doReportHistory(progress, false)
                            }
                        }
                        // 空降助手：进入标注片段则跳到片段结尾。护栏 _sponsorSkipGuardMs
                        // 抑制 seek 生效前（position 仍报旧值）的重复触发；手动 seek 回
                        // 片段内仍会再次跳过（与官方网页端行为一致）。
                        // _pendingSeek > 0 = 历史进度恢复（或切清晰度/重试的位置恢复）
                        // 尚未执行：期间不抢跳（如片头恰饭片段会把进度先拉到片段尾，
                        // 覆盖/打乱随后的历史恢复 seek，表现为"恢复失效"）
                        if (pageRoot.sponsorEnabled && pageRoot.sponsorSegments.length > 0
                                && position > 0 && position >= pageRoot._sponsorSkipGuardMs
                                && pageRoot._pendingSeek === 0) {
                            var sponsorPosSec = position / 1000
                            for (var ssi = 0; ssi < pageRoot.sponsorSegments.length; ssi++) {
                                var sseg = pageRoot.sponsorSegments[ssi]
                                if (sponsorPosSec >= sseg.start && sponsorPosSec < sseg.end - 0.5) {
                                    pageRoot._sponsorSkipGuardMs = position + 1500
                                    mpvPlayer.seek(sseg.end * 1000)
                                    pageRoot.showSponsorSkip(sseg)
                                    SponsorBlockManager.reportViewed(sseg.uuid)
                                    break
                                }
                            }
                        }
                    }
                }

                // 空降助手跳过提示：自动跳过时短暂浮现于视频区顶部中央
                Rectangle {
                    id: sponsorSkipBar
                    property string skipText: ""
                    visible: false
                    z: 90
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: parent.top
                    anchors.topMargin: 16
                    width: skipLabel.implicitWidth + 28
                    height: skipLabel.implicitHeight + 14
                    radius: 6
                    color: "#CC202020"

                    FluText {
                        id: skipLabel
                        anchors.centerIn: parent
                        text: parent.skipText
                        font: FluTextStyle.Body
                        color: "#FFFFFF"
                    }

                    Timer {
                        id: sponsorSkipHideTimer
                        interval: 2500
                        repeat: false
                        onTriggered: sponsorSkipBar.visible = false
                    }
                }

                // 视频信息浮层
                Rectangle {
                    id: videoInfoPanel
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Theme.spacingMedium
                    width: infoColumn.implicitWidth + 24
                    height: infoColumn.implicitHeight + 24
                    color: "#E6000000"
                    radius: 6
                    visible: pageRoot.showVideoInfo
                    z: 100

                    Column {
                        id: infoColumn
                        anchors.centerIn: parent
                        spacing: 6

                        FluText {
                            text: "实际播放信息"
                            font: FluTextStyle.BodyStrong
                            color: "#FFFFFF"
                        }

                        Rectangle {
                            width: infoColumn.implicitWidth
                            height: 1
                            color: "#444444"
                        }

                        FluText {
                            text: "清晰度: " + (pageRoot.currentQuality || "未知")
                            font: FluTextStyle.Caption
                            color: "#FFD700"
                        }

                        FluText {
                            text: "分辨率: " + pageRoot.actualWidth + " x " + pageRoot.actualHeight
                            font: FluTextStyle.Caption
                            color: "#FFFFFF"
                            visible: pageRoot.actualWidth > 0
                        }

                        FluText {
                            text: "视频编码: " + (pageRoot.actualVideoCodec || "未知")
                            font: FluTextStyle.Caption
                            color: "#FFFFFF"
                        }

                        FluText {
                            text: "视频格式: " + (pageRoot.actualVideoFormat || "未知")
                            font: FluTextStyle.Caption
                            color: "#FFFFFF"
                        }

                        FluText {
                            text: "容器格式: " + (pageRoot.actualContainerFormat || "未知")
                            font: FluTextStyle.Caption
                            color: "#FFFFFF"
                        }

                        FluText {
                            text: "帧率: " + (pageRoot.actualFps > 0 ? pageRoot.actualFps.toFixed(2) + " fps" : "未知")
                            font: FluTextStyle.Caption
                            color: "#FFFFFF"
                        }

                        FluText {
                            text: "视频码率: " + (pageRoot.actualVideoBitrate > 0 ? Math.round(pageRoot.actualVideoBitrate) + " kbps" : "未知")
                            font: FluTextStyle.Caption
                            color: "#FFFFFF"
                        }

                        FluText {
                            text: "音频编码: " + (pageRoot.actualAudioCodec || "未知")
                            font: FluTextStyle.Caption
                            color: "#FFFFFF"
                        }

                        FluText {
                            text: "音频码率: " + (pageRoot.actualAudioBitrate > 0 ? Math.round(pageRoot.actualAudioBitrate) + " kbps" : "未知")
                            font: FluTextStyle.Caption
                            color: "#FFFFFF"
                        }

                        Rectangle {
                            width: infoColumn.implicitWidth
                            height: 1
                            color: "#444444"
                        }

                        FluText {
                            text: "流地址:"
                            font: FluTextStyle.Caption
                            color: "#AAAAAA"
                        }

                        FluText {
                            width: 320
                            text: pageRoot.actualPath
                            font: FluTextStyle.Caption
                            color: "#888888"
                            wrapMode: Text.WrapAnywhere
                            maximumLineCount: 3
                            elide: Text.ElideRight
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.NoButton
                        hoverEnabled: true
                        onPositionChanged: pageRoot.playerMouseActivity()
                    }
                }

                DanmakuOverlay {
                    id: videoDanmakuOverlay
                    anchors.fill: parent
                    visible: pageRoot.danmakuEnabled
                    danmakuEnabled: pageRoot.danmakuEnabled
                    opacityValue: pageRoot.danmakuOpacity
                    fontSizeScale: pageRoot.danmakuSize
                    outlineStyle: pageRoot.danmakuOutlineStyle
                    speedScale: pageRoot._danmakuSpeedScale(pageRoot.danmakuSpeedIndex) * pageRoot.playbackSpeed
                    displayAreaRatio: [0.25, 0.5, 0.75, 1.0][pageRoot.danmakuRangeIndex] || 1.0
                    areaOffsetRatio: 0.0


                }

                VideoDanmakuManager {
                    id: videoDanmakuManager
                    onDanmakuListReady: function(list) {
                        pageRoot.onVideoDanmakuLoaded(list)
                    }
                    onErrorOccurred: function(error) {
                        console.warn("[VideoPlayerPage] video danmaku error:", error)
                    }
                }

                // 视频封面（作为未真正播放时的占位）
                FluImage {
                    anchors.fill: parent
                    source: GlobalState.fixImageUrl(pageRoot.cover,
                                                    videoContainer.width * Screen.devicePixelRatio,
                                                    videoContainer.height * Screen.devicePixelRatio,
                                                    true)
                    fillMode: Image.PreserveAspectCrop
                    visible: !mpvPlayer.hasVideo && pageRoot.cover !== ""
                    asynchronous: true
                    cache: false
                    sourceSize: Qt.size(videoContainer.width * Screen.devicePixelRatio,
                                        videoContainer.height * Screen.devicePixelRatio)
                }

                // 播放区鼠标跟踪：移动恢复指针，静止3秒自动隐藏；点击切换控制栏
                MouseArea {
                    anchors.fill: parent
                    z: -1
                    hoverEnabled: true
                    onPositionChanged: pageRoot.playerMouseActivity()
                    // 鼠标离开播放区（到右侧面板等）：恢复指针并停止计时
                    onExited: {
                        pageRoot.cursorHidden = false
                        hideCursorTimer.stop()
                    }
                    onClicked: {
                        closePopups()
                        if (pageRoot.controlsVisible) {
                            pageRoot.controlsVisible = false
                            hideCursorTimer.restart()
                        } else {
                            pageRoot.controlsVisible = true
                            pageRoot.cursorHidden = false
                            hideControlsTimer.restart()
                            hideCursorTimer.restart()
                        }
                    }
                }

                Column {
                    anchors.centerIn: parent
                    width: parent.width
                    spacing: 12
                    visible: mpvPlayer.source !== "" && !mpvPlayer.hasVideo && !pageRoot.loadFailed

                    FluText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "视频加载中..."
                        font: FluTextStyle.Body
                        color: "#80FFFFFF"
                    }
                }

                Rectangle {
                    anchors.fill: parent
                    color: "#CC000000"
                    visible: pageRoot.loadFailed
                    z: 100

                    Column {
                        anchors.centerIn: parent
                        spacing: 12
                        width: parent.width

                        FluIcon {
                            anchors.horizontalCenter: parent.horizontalCenter
                            iconSource: FluentIcons.Sync
                            iconSize: 48
                            color: "#FFFFFF"
                        }

                        FluText {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "内容加载失败"
                            font: FluTextStyle.Subtitle
                            color: "#FFFFFF"
                        }

                        FluText {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: pageRoot.loadErrorMsg || "请检查网络后重试"
                            font: FluTextStyle.Caption
                            color: "#80FFFFFF"
                            wrapMode: Text.Wrap
                            width: parent.width * 0.7
                            horizontalAlignment: Text.AlignHCenter
                        }

                        FluButton {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "重新加载"
                            onClicked: {
                                pageRoot.loadFailed = false
                                pageRoot.loadRetryCount = 0
                                pageRoot.loadErrorMsg = ""
                                pageRoot.loadData()
                            }
                        }
                    }
                }

                Column {
                    anchors.centerIn: parent
                    width: parent.width
                    spacing: 12
                    visible: mpvPlayer.source === "" && !mpvPlayer.hasVideo && pageRoot.cover === "" && !pageRoot.loadFailed

                    FluIcon {
                        anchors.horizontalCenter: parent.horizontalCenter
                        iconSource: FluentIcons.Play
                        iconSize: 64
                        color: "#FFFFFF"
                    }

                    FluText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "点击开始播放"
                        font: FluTextStyle.Body
                        color: "#80FFFFFF"
                    }
                }

                // ---- 底部常驻 mini 进度条 ----
                // 控制栏隐藏期间显示的无滑块进度细条：底轨 + 已播放填充 +
                // 空降色块 + 章节刻度线。纯视觉层（enabled: false 不收鼠标），
                // 不与控制栏唤起逻辑竞争；控制栏可见时让位淡出。
                // 左右内缩 6px = 容器圆角半径：细条从圆弧与底边交点起画，
                // 两端圆角完整可见，避免细条把底部圆角盖成直角
                Rectangle {
                    id: miniProgressBar
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.leftMargin: 6
                    anchors.rightMargin: 6
                    height: 3
                    z: 50
                    color: "transparent"    // 容器默认白色，会在底轨圆角外的
                                            // 四角露出白边，必须显式透明
                    enabled: false          // 鼠标事件穿透到播放区（点击/双击等）
                    opacity: (pageRoot.miniProgressEnabled
                              && !pageRoot.controlsVisible
                              && mpvPlayer.source !== ""
                              && mpvPlayer.duration > 0) ? 1 : 0
                    Behavior on opacity {
                        NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
                    }

                    // 底轨：与主进度条轨道同款灰（主题区分明暗）；
                    // radius = 高度一半 → 两端半圆（胶囊形），与主进度条一致
                    Rectangle {
                        anchors.fill: parent
                        radius: height / 2
                        color: FluTheme.dark ? Qt.rgba(162/255,162/255,162/255,1)
                                             : Qt.rgba(138/255,138/255,138/255,1)
                    }

                    // 已播放填充：两端半圆（宽度 < 高度时 Qt 自动收窄圆角）
                    Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: mpvPlayer.duration > 0
                               ? parent.width * (mpvPlayer.position / mpvPlayer.duration)
                               : 0
                        radius: height / 2
                        color: FluTheme.primaryColor
                    }

                    // 空降助手色块：两端半圆，与主进度条色带一致
                    Repeater {
                        model: pageRoot.sponsorSegments
                        Rectangle {
                            x: (modelData.start * 1000 / mpvPlayer.duration) * parent.width
                            width: Math.max(2, (modelData.end - modelData.start) * 1000
                                             / mpvPlayer.duration * parent.width)
                            y: 0
                            height: parent.height
                            radius: height / 2
                            color: pageRoot.sponsorCategoryColor(modelData.category)
                            visible: modelData.end > modelData.start
                                     && mpvPlayer.duration > 0
                        }
                    }

                    // 章节刻度线：上下各突出 1px，保证 3px 轨道上可见
                    Repeater {
                        model: pageRoot.viewPoints
                        Rectangle {
                            visible: modelData.from > 0 && mpvPlayer.duration > 0
                            x: (modelData.from * 1000 / mpvPlayer.duration) * parent.width - width / 2
                            y: -1
                            width: 1
                            height: parent.height + 2
                            color: "#B3FFFFFF"
                        }
                    }
                }

                // ---- 顶部渐变阴影（与直播页同款）+ 左上角章节选择 ----
                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    height: 48
                    radius: 6
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: "#CC000000" }
                        GradientStop { position: 1.0; color: "transparent" }
                    }
                    opacity: pageRoot.controlsVisible ? 1 : 0
                    Behavior on opacity {
                        NumberAnimation {
                            duration: Theme.animationFast
                            easing.type: Easing.OutCubic
                        }
                    }
                    visible: pageRoot.viewPoints.length > 0

                    // 章节选择菜单（样式与控制栏清晰度菜单一致）。
                    // enabled 门控：阴影 opacity 0 时菜单不可点击（opacity 不拦截输入）
                    FluMenuBar {
                        id: chapterMenuBar
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.spacingMedium
                        anchors.top: parent.top
                        anchors.topMargin: 2
                        enabled: pageRoot.controlsVisible
                        delegate: FluMenuBarItem {
    id: mbItem
    textColor: "#FFFFFF"
    // 覆写背景：原版悬停色 FluTheme.itemHoverColor（6% 白）在黑色
    // 控制栏上不可见，改为与 FluIconButton 一致的 15%/25% 白。
    // 注意：原组件内部的 control id 外部不可见，须用自身 id 引用
    background: Rectangle {
        implicitWidth: 30
        implicitHeight: 30
        radius: 3
        color: mbItem.pressed ? "#40FFFFFF"
                              : (mbItem.highlighted ? "#26FFFFFF" : "transparent")
    }
}
                        FluMenu {
                            id: chapterMenu
                            // 标题超长截断：上限 = 播放器宽 - 边距/预留，靠 elide 无法
                            // 作用于 FluMenu title（纯文本属性），改为字符数截断
                            title: pageRoot.currentChapterIndex >= 0
                                   ? pageRoot.chapterTitleAt(pageRoot.currentChapterIndex)
                                   : "章节"
                            onAboutToShow: closePopups()
                            width: 360
                            Repeater {
                                model: pageRoot.viewPoints
                                FluMenuItem {
                                    // FluMenuItem 文本不裁剪，长标题需手动截断防溢出菜单
                                    text: {
                                        var t = modelData.title
                                        if (t.length > 24) t = t.substring(0, 23) + "…"
                                        return pageRoot.formatDuration(Math.floor(modelData.from)) + "  " + t
                                    }
                                    onTriggered: {
                                        mpvPlayer.seek(modelData.from * 1000)
                                    }
                                }
                            }
                        }
                    }
                }

                // 播放控制栏
                // radius 使底部两角为圆角（与 videoContainer 圆角一致）；
                // 顶部两角处于渐变透明区（0~55% 全透明），圆角裁切不可见，
                // 视觉上等效"仅底部圆角"
                Rectangle {
                    id: controlBar
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: 118
                    radius: 6
                    visible: pageRoot.controlsVisible
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: "transparent" }
                        GradientStop { position: 0.4; color: "transparent" }
                        GradientStop { position: 0.75; color: "#80000000" }
                        GradientStop { position: 1.0; color: "#CC000000" }
                    }

                    // 控制栏区域悬停检测（HoverHandler 为被动监听，不与
                    // 子控件 MouseArea 抢事件）：悬停期间不触发自动隐藏
                    HoverHandler { id: controlBarHover }

                    ColumnLayout {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: 78
                        anchors.margins: 8
                        spacing: 4

                        // 第一行：进度条（含章节刻度线与悬浮章节气泡）
                        Item {
                            id: progressWrap
                            Layout.fillWidth: true
                            implicitHeight: progressSlider.implicitHeight

                            FluSlider {
                                id: progressSlider
                                anchors.left: parent.left
                                anchors.right: parent.right
                                from: 0
                                to: mpvPlayer.duration > 0 ? mpvPlayer.duration : (pageRoot.videoDuration > 0 ? pageRoot.videoDuration * 1000 : 1)
                                value: mpvPlayer.position
                                text: pageRoot.formatDuration(Math.floor(value / 1000))
                                onMoved: {
                                    mpvPlayer.seek(value)
                                }

                                // 覆写背景：复刻 FluSlider 原样式（灰底槽 + 主题色
                                // 已播放条）+ 章节刻度层。无章节时刻度层空转，
                                // 视觉与原版逐像素一致。注：原实现的内部 id
                                // control 在外部作用域不可见，此处用 progressSlider
                                background: Item {
                                    x: progressSlider.leftPadding + (progressSlider.horizontal ? 0 : (progressSlider.availableWidth - width) / 2)
                                    y: progressSlider.topPadding + (progressSlider.horizontal ? (progressSlider.availableHeight - height) / 2 : 0)
                                    implicitWidth: progressSlider.horizontal ? 180 : 6
                                    implicitHeight: progressSlider.horizontal ? 6 : 180
                                    width: progressSlider.horizontal ? progressSlider.availableWidth : implicitWidth
                                    height: progressSlider.horizontal ? implicitHeight : progressSlider.availableHeight

                                    Rectangle {
                                        anchors.fill: parent
                                        anchors.margins: 1
                                        radius: 2
                                        color: FluTheme.dark ? Qt.rgba(162/255,162/255,162/255,1) : Qt.rgba(138/255,138/255,138/255,1)
                                    }
                                    Rectangle {
                                        y: progressSlider.horizontal ? 0 : progressSlider.visualPosition * parent.height
                                        width: progressSlider.horizontal ? progressSlider.position * parent.width : 6
                                        height: progressSlider.horizontal ? 6 : progressSlider.position * parent.height
                                        radius: 3
                                        color: FluTheme.primaryColor
                                    }

                                    // 空降助手色带：社区标注片段（恰饭/片头/片尾…）。
                                    // 纯视觉层——slider background 不参与鼠标交互，
                                    // 点击/拖动/悬浮逻辑不受影响；画在已播放填充之上、
                                    // 章节刻度线之下（细线压色带，表达章节边界穿片段）
                                    Repeater {
                                        model: pageRoot.sponsorSegments
                                        Rectangle {
                                            visible: modelData.end > modelData.start
                                                     && progressSlider.to > 0
                                            x: (modelData.start * 1000 / progressSlider.to) * parent.width
                                            width: Math.max(2, (modelData.end - modelData.start) * 1000
                                                             / progressSlider.to * parent.width)
                                            y: 0
                                            height: parent.height
                                            radius: 2
                                            opacity: 0.85
                                            color: pageRoot.sponsorCategoryColor(modelData.category)
                                        }
                                    }

                                    // 章节刻度线：每章起点一根，颜色区分已/未播放
                                    Repeater {
                                        model: pageRoot.viewPoints
                                        Rectangle {
                                            // 起点为 0 的章节与进度条左端重合，跳过
                                            visible: modelData.from > 0
                                            x: (modelData.from * 1000 / progressSlider.to) * parent.width - width / 2
                                            y: -3
                                            width: 2
                                            height: 12
                                            radius: 1
                                            color: (modelData.from * 1000 <= progressSlider.value)
                                                   ? FluTheme.primaryColor
                                                   : (FluTheme.dark ? "#3A3A44" : "#FFFFFF")
                                        }
                                    }
                                }
                            }

                            // 悬浮章节气泡：鼠标划过进度条任意位置显示命中章节；
                            // 命中空降助手标注片段时追加片段标注（如"恰饭 1:30-2:30"），
                            // 无章节的视频独立显示片段标注。
                            // HoverHandler 被动监听（不与 slider 的手柄 hover/tooltip
                            // 抢事件，与控制栏悬停检测同一模式）
                            HoverHandler {
                                id: chapterHover
                                enabled: pageRoot.viewPoints.length > 0
                                         || pageRoot.sponsorSegments.length > 0
                            }

                            Rectangle {
                                id: chapterTip
                                visible: chapterHover.hovered
                                         && (pageRoot.viewPoints.length > 0
                                             || chapterTip.hitSegment !== null)
                                property int hitIndex: {
                                    var ratio = chapterHover.point.position.x / Math.max(1, progressWrap.width)
                                    var pos = ratio * (progressSlider.to / 1000)
                                    for (var i = pageRoot.viewPoints.length - 1; i >= 0; i--) {
                                        if (pos >= pageRoot.viewPoints[i].from) return i
                                    }
                                    return 0
                                }
                                // 悬停位置命中的空降片段（null = 未命中）
                                property var hitSegment: {
                                    var ratio = chapterHover.point.position.x / Math.max(1, progressWrap.width)
                                    var pos = ratio * (progressSlider.to / 1000)
                                    for (var i = 0; i < pageRoot.sponsorSegments.length; i++) {
                                        var s = pageRoot.sponsorSegments[i]
                                        if (pos >= s.start && pos < s.end) return s
                                    }
                                    return null
                                }
                                x: Math.max(0, Math.min(chapterHover.point.position.x - width / 2,
                                                        progressWrap.width - width))
                                y: -chapterTip.height - 6
                                width: tipColumn.implicitWidth + 20
                                height: tipColumn.implicitHeight + 12
                                radius: 3
                                color: "#C8202020"

                                Column {
                                    id: tipColumn
                                    anchors.centerIn: parent
                                    spacing: 2
                                    FluText {
                                        // 标题行：章节名（有章节时）+ 片段标注（命中时追加）
                                        text: {
                                            var t = ""
                                            if (pageRoot.viewPoints.length > 0 && chapterTip.hitIndex >= 0) {
                                                t = (chapterTip.hitIndex + 1) + " · "
                                                    + pageRoot.viewPoints[chapterTip.hitIndex].title
                                            }
                                            if (chapterTip.hitSegment) {
                                                var s = chapterTip.hitSegment
                                                var label = pageRoot.sponsorCategoryName(s.category)
                                                            + " " + pageRoot.formatDuration(Math.floor(s.start))
                                                            + "-" + pageRoot.formatDuration(Math.floor(s.end))
                                                t = t === "" ? label : t + " 〔" + label + "〕"
                                            }
                                            return t
                                        }
                                        font: FluTextStyle.Body
                                        color: "#FFFFFF"
                                    }
                                    FluText {
                                        // 时间行：章节时间范围；无章节时片段时间已在标题行，隐藏
                                        text: pageRoot.viewPoints.length > 0 && chapterTip.hitIndex >= 0
                                              ? (pageRoot.formatDuration(Math.floor(pageRoot.viewPoints[chapterTip.hitIndex].from))
                                                 + " – " + pageRoot.formatDuration(Math.floor(pageRoot.viewPoints[chapterTip.hitIndex].to)))
                                              : ""
                                        font: FluTextStyle.Caption
                                        color: "#CCCCCC"
                                        visible: pageRoot.viewPoints.length > 0
                                    }
                                }
                            }
                        }

                        // 第二行：控制按钮
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10

                            // 左侧：播放/暂停 + 时间
                            FluIconButton {
                                iconSource: pageRoot.isPlaying ? FluentIcons.Pause : FluentIcons.Play
                                iconSize: 18
                                iconColor: "#FFFFFF"
                                hoverColor: "#26FFFFFF"   // 15% 白：黑底上可见但不刺眼
                                pressedColor: "#40FFFFFF"
                                onClicked: {
                                    closePopups()
                                    if (mpvPlayer.playing) {
                                        mpvPlayer.pause()
                                    } else if (mpvPlayer.source !== "") {
                                        // 播放到末尾后点击播放，从头开始播放
                                        var duration = mpvPlayer.duration > 0 ? mpvPlayer.duration
                                                                                  : (pageRoot.videoDuration > 0 ? pageRoot.videoDuration * 1000 : 0)
                                        if (duration > 0 && mpvPlayer.position >= duration - 500) {
                                            mpvPlayer.seek(0)
                                        }
                                        mpvPlayer.play()
                                    }
                                }
                            }

                            FluText {
                                text: (mpvPlayer.position > 0 ? pageRoot.formatDuration(Math.floor(mpvPlayer.position / 1000)) : "0:00")
                                      + " / " + (mpvPlayer.duration > 0 ? pageRoot.formatDuration(Math.floor(mpvPlayer.duration / 1000))
                                                : (pageRoot.videoDuration > 0 ? pageRoot.formatDuration(pageRoot.videoDuration) : "--:--"))
                                font: FluTextStyle.Caption
                                color: "#FFFFFF"
                                Layout.alignment: Qt.AlignVCenter
                            }

                            // ===== 弹幕输入框（与直播播放器同款深色定制样式）=====
                            // 文字保留：仅发送成功才 clear（见 onVideoDanmakuSendResult），
                            // 失焦/控制栏隐藏都不清空；输入中经 controlOverlayActive()
                            // 豁免自动隐藏。小窗模式（480px）空间不足，隐藏
                            FluTextBox {
                                id: danmakuInput
                                visible: !pageRoot.isMiniWindow
                                Layout.preferredWidth: 180
                                Layout.maximumWidth: 200
                                Layout.alignment: Qt.AlignVCenter
                                placeholderText: "发个弹幕见证当下"
                                font: FluTextStyle.Caption
                                iconSource: FluentIcons.Send   // 输入框内右侧发送提示（Enter 发送）
                                cleanEnabled: true             // 非空时自动显示清空键（组件内置）
                                maximumLength: 100             // B 站视频弹幕长度限制
                                normalColor: "white"
                                placeholderNormalColor: "#99FFFFFF"
                                placeholderFocusColor: "#99FFFFFF"
                                background: Rectangle {
                                    implicitHeight: 30
                                    radius: 4
                                    color: danmakuInput.activeFocus ? "#59000000" : "#40000000"
                                    border.width: 1
                                    border.color: danmakuInput.activeFocus
                                                   ? FluTheme.primaryColor : "#33FFFFFF"
                                }
                                onCommit: (text) => pageRoot.sendVideoDanmaku(text)
                                Keys.onPressed: (event) => {
                                    // 中文输入法组合期间回车是"上屏候选词"，
                                    // Qt 已处理，无需干预；Esc 交还焦点
                                    if (event.key === Qt.Key_Escape) {
                                        danmakuInput.focus = false
                                        event.accepted = true
                                    }
                                }
                            }

                            // 弹幕颜色选择（FluColorPicker：内置取色面板，
                            // 按钮中央色块实时反映当前弹幕颜色）。小窗模式下隐藏
                            FluColorPicker {
                                id: danmakuColorPicker
                                visible: !pageRoot.isMiniWindow
                                width: 30
                                height: 30
                                current: pageRoot.danmakuColor
                                titleText: "弹幕颜色"
                                cancelText: "取消"
                                okText: "确定"
                                Layout.alignment: Qt.AlignVCenter
                                onAccepted: pageRoot.danmakuColor = current
                            }

                            Item { Layout.fillWidth: true }

                            // 右侧：从右到左依次为全屏、信息、弹幕设置、音量、倍速、清晰度
                            RowLayout {
                                layoutDirection: Qt.RightToLeft
                                spacing: 8
                                Layout.alignment: Qt.AlignVCenter

                                FluIconButton {
                                    id: fullscreenBtn
                                    iconSource: pageRoot.isFullScreen ? FluentIcons.BackToWindow : FluentIcons.FullScreen
                                    iconSize: 16
                                    iconColor: "#FFFFFF"
                                    hoverColor: "#26FFFFFF"
                                    pressedColor: "#40FFFFFF"
                                    onClicked: {
                                        closePopups()
                                        pageRoot.isFullScreen = !pageRoot.isFullScreen
                                    }
                                }

                                // 小窗播放：进入/退出独立置顶小窗
                                FluIconButton {
                                    id: miniWindowBtn
                                    iconSource: pageRoot.isMiniWindow ? FluentIcons.ClosePane : FluentIcons.OpenInNewWindow
                                    iconSize: 16
                                    iconColor: "#FFFFFF"
                                    hoverColor: "#26FFFFFF"
                                    pressedColor: "#40FFFFFF"
                                    onClicked: {
                                        closePopups()
                                        if (pageRoot.isMiniWindow) pageRoot.exitMiniWindow()
                                        else pageRoot.enterMiniWindow()
                                    }
                                }

                                FluIconButton {
                                    id: videoInfoBtn
                                    iconSource: FluentIcons.Info
                                    iconSize: 16
                                    iconColor: "#FFFFFF"
                                    hoverColor: "#26FFFFFF"
                                    pressedColor: "#40FFFFFF"
                                    onClicked: {
                                        closePopups()
                                        if (mpvPlayer.hasVideo) {
                                            videoInfoTimer.restart()
                                        }
                                        pageRoot.showVideoInfo = !pageRoot.showVideoInfo
                                    }
                                }

                                FluIconButton {
                                    id: danmakuBtn
                                    iconSource: FluentIcons.Subtitles
                                    iconSize: 16
                                    iconColor: "#FFFFFF"
                                    hoverColor: "#26FFFFFF"
                                    pressedColor: "#40FFFFFF"
                                    onClicked: {
                                        var wasOpen = danmakuPopup.opened
                                        closePopups()
                                        if (!wasOpen) danmakuPopup.open()
                                    }
                                }

                                FluIconButton {
                                    id: volumeBtn
                                    iconSource: {
                                        if (pageRoot.volume === 0) return FluentIcons.Mute
                                        if (pageRoot.volume <= 0.33) return FluentIcons.Volume1
                                        if (pageRoot.volume <= 0.66) return FluentIcons.Volume2
                                        return FluentIcons.Volume3
                                    }
                                    iconSize: 16
                                    iconColor: "#FFFFFF"
                                    hoverColor: "#26FFFFFF"
                                    pressedColor: "#40FFFFFF"
                                    onClicked: {
                                        var wasOpen = volumePopup.opened
                                        closePopups()
                                        if (!wasOpen) volumePopup.open()
                                    }
                                }

                                FluMenuBar {
                                    Layout.alignment: Qt.AlignVCenter
                                    delegate: FluMenuBarItem {
    id: mbItem
    textColor: "#FFFFFF"
    // 覆写背景：原版悬停色 FluTheme.itemHoverColor（6% 白）在黑色
    // 控制栏上不可见，改为与 FluIconButton 一致的 15%/25% 白。
    // 注意：原组件内部的 control id 外部不可见，须用自身 id 引用
    background: Rectangle {
        implicitWidth: 30
        implicitHeight: 30
        radius: 3
        color: mbItem.pressed ? "#40FFFFFF"
                              : (mbItem.highlighted ? "#26FFFFFF" : "transparent")
    }
}
                                    FluMenu {
                                        id: speedMenu
                                        title: pageRoot.currentSpeed
                                        onAboutToShow: closePopups()
                                        FluMenuItem { text: "0.5x"; onTriggered: pageRoot.playbackSpeed = 0.5 }
                                        FluMenuItem { text: "1.0x"; onTriggered: pageRoot.playbackSpeed = 1.0 }
                                        FluMenuItem { text: "1.25x"; onTriggered: pageRoot.playbackSpeed = 1.25 }
                                        FluMenuItem { text: "1.5x"; onTriggered: pageRoot.playbackSpeed = 1.5 }
                                        FluMenuItem { text: "2.0x"; onTriggered: pageRoot.playbackSpeed = 2.0 }
                                    }
                                }

                                FluMenuBar {
                                    Layout.alignment: Qt.AlignVCenter
                                    delegate: FluMenuBarItem {
    id: mbItem
    textColor: "#FFFFFF"
    // 覆写背景：原版悬停色 FluTheme.itemHoverColor（6% 白）在黑色
    // 控制栏上不可见，改为与 FluIconButton 一致的 15%/25% 白。
    // 注意：原组件内部的 control id 外部不可见，须用自身 id 引用
    background: Rectangle {
        implicitWidth: 30
        implicitHeight: 30
        radius: 3
        color: mbItem.pressed ? "#40FFFFFF"
                              : (mbItem.highlighted ? "#26FFFFFF" : "transparent")
    }
}
                                    FluMenu {
                                        id: codecMenu
                                        title: pageRoot.currentCodecName
                                        onAboutToShow: closePopups()
                                        Repeater {
                                            model: pageRoot.codecOptions
                                            FluMenuItem {
                                                text: modelData.name
                                                onTriggered: {
                                                    var c = modelData.value
                                                    if (c !== pageRoot.currentCodec) {
                                                        pageRoot.currentCodec = c
                                                        Settings.setInt("videoCodec", c)
                                                        if (pageRoot.aid !== "" && pageRoot.cid !== "") {
                                                            pageRoot._savedPosition = mpvPlayer.position
                                                            pageRoot._switchingStream = true
                                                            heartbeatTimer.stop()
                                                            // 【关键修复】番剧模式下走 PGC 专用接口；普通视频走 UGC 接口
                                                            if (pageRoot.isBangumi && pageRoot.epId) {
                                                                // 用户显式切换编码 → 按传入 exact qn 发请求（forceMaxQuality=false），
                                                                // 若 Only-FLV 下服务器拿不到 exact encode 会回退真实 quality，playUrlReady 会校正显示
                                                                PlayUrlManager.getSeasonPlayUrl(
                                                                    pageRoot.cid, pageRoot.currentQualityId,
                                                                    pageRoot.epId, pageRoot.seasonType,
                                                                    pageRoot.bvid, pageRoot.aid,
                                                                    false /* forceMaxQuality */,
                                                                    pageRoot.seasonId || "")
                                                            } else {
                                                                PlayUrlManager.getPlayUrl(pageRoot.aid, pageRoot.cid, pageRoot.currentQualityId)
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }

                                FluMenuBar {
                                    Layout.alignment: Qt.AlignVCenter
                                    delegate: FluMenuBarItem {
    id: mbItem
    textColor: "#FFFFFF"
    // 覆写背景：原版悬停色 FluTheme.itemHoverColor（6% 白）在黑色
    // 控制栏上不可见，改为与 FluIconButton 一致的 15%/25% 白。
    // 注意：原组件内部的 control id 外部不可见，须用自身 id 引用
    background: Rectangle {
        implicitWidth: 30
        implicitHeight: 30
        radius: 3
        color: mbItem.pressed ? "#40FFFFFF"
                              : (mbItem.highlighted ? "#26FFFFFF" : "transparent")
    }
}
                                    FluMenu {
                                        id: qualityMenu
                                        title: pageRoot.currentQuality || "清晰度"
                                        onAboutToShow: closePopups()
                                        Repeater {
                                            model: pageRoot.qualityList
                                            FluMenuItem {
                                                text: modelData.qualityName || ""
                                                onTriggered: {
                                                    var qid = modelData.qualityId || 0
                                                    if (qid > 0 && pageRoot.aid !== "" && pageRoot.cid !== "") {
                                                        pageRoot.currentQualityId = qid
                                                        pageRoot.currentQuality = modelData.qualityName || ""
                                                        pageRoot._savedPosition = mpvPlayer.position
                                                        pageRoot._switchingStream = true
                                                        heartbeatTimer.stop()
                                                        // 【关键修复】番剧模式下走 PGC 专用接口；普通视频走 UGC 接口
                                                        // 注意：只有 FLV 的番剧没有 DASH 缓存，切清晰度必须重新请求 PGC playurl。
                                                        if (pageRoot.isBangumi && pageRoot.epId) {
                                                            // 用户显式点击清晰度 → exact qid（forceMaxQuality=false）。
                                                            // DASH 缓存番剧：直接走缓存切换，完美；
                                                            // Only-FLV 番剧：如果服务器没有该 qid 的 FLV encode 会静默降级，
                                                            // playUrlReady 返回真实 quality，UI 自动校正显示。
                                                            PlayUrlManager.getSeasonPlayUrl(
                                                                pageRoot.cid, qid,
                                                                pageRoot.epId, pageRoot.seasonType,
                                                                pageRoot.bvid, pageRoot.aid,
                                                                false /* forceMaxQuality */,
                                                                pageRoot.seasonId || "")
                                                        } else {
                                                            PlayUrlManager.getPlayUrl(pageRoot.aid, pageRoot.cid, qid)
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // 音量弹出面板
                    Popup {
                        id: volumePopup
                        parent: volumeBtn
                        width: 48
                        height: 160
                        x: (parent.width - width) / 2
                        y: -height - 10
                        modal: false
                        closePolicy: Popup.CloseOnEscape
                        padding: 0
                        background: Rectangle {
                            radius: 5
                            color: "#2B2B2B"
                        }

                        Column {
                            anchors.fill: parent
                            topPadding: 8
                            bottomPadding: 8
                            spacing: 8

                            FluText {
                                id: volumePercent
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: Math.round(pageRoot.volume * 100) + "%"
                                font: FluTextStyle.Caption
                                color: "#FFFFFF"
                            }

                            Item {
                                id: volumeSlider
                                anchors.horizontalCenter: parent.horizontalCenter
                                width: 32
                                height: 120

                                property real trackHeight: 104
                                property real trackTop: (height - trackHeight) / 2

                                // 轨道
                                Rectangle {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    y: volumeSlider.trackTop
                                    width: 4
                                    height: volumeSlider.trackHeight
                                    radius: 2
                                    color: "#808080"
                                }

                                // 填充
                                Rectangle {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    y: volumeSlider.trackTop + volumeSlider.trackHeight * (1 - pageRoot.volume)
                                    width: 4
                                    height: volumeSlider.trackHeight * pageRoot.volume
                                    radius: 2
                                    color: FluTheme.primaryColor
                                }

                                // 手柄
                                Item {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    width: 16
                                    height: 16
                                    y: volumeSlider.trackTop + volumeSlider.trackHeight * (1 - pageRoot.volume) - height / 2

                                    Rectangle {
                                        anchors.fill: parent
                                        radius: 8
                                        color: "#FFFFFF"
                                    }

                                    Rectangle {
                                        anchors.centerIn: parent
                                        width: 8
                                        height: 8
                                        radius: 4
                                        color: FluTheme.primaryColor
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    function updateVolume(mouse) {
                                        var ratio = 1 - (mouse.y - volumeSlider.trackTop) / volumeSlider.trackHeight
                                        pageRoot.volume = Math.max(0, Math.min(1, ratio))
                                    }
                                    onPressed: updateVolume(mouse)
                                    onPositionChanged: updateVolume(mouse)
                                }
                            }
                        }
                    }

                    // 弹幕设置弹出面板
                    Popup {
                        id: danmakuPopup
                        parent: danmakuBtn
                        width: 280
                        height: contentItem.implicitHeight + topPadding + bottomPadding
                        x: parent.width - width
                        y: -height - 10
                        modal: false
                        closePolicy: Popup.CloseOnEscape
                        padding: 16
                        background: Rectangle {
                            radius: 5
                            color: "#2B2B2B"
                        }

                        contentItem: ColumnLayout {
                            width: parent.width - parent.leftPadding - parent.rightPadding
                            spacing: 16

                            FluText {
                                text: "弹幕设置"
                                font: FluTextStyle.Subtitle
                                color: "#FFFFFF"
                            }

                            // 弹幕开关
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8

                                FluText {
                                    text: "显示弹幕"
                                    font: FluTextStyle.Body
                                    color: "#FFFFFF"
                                }

                                Item { Layout.fillWidth: true }

                                FluToggleSwitch {
                                    checked: pageRoot.danmakuEnabled
                                    clickListener: function() { pageRoot.danmakuEnabled = !pageRoot.danmakuEnabled }
                                    normalColor: "#323232"
                                    hoverColor: "#3E3E3E"
                                    borderNormalColor: "#A1A1A1"
                                    dotNormalColor: "#D0D0D0"
                                    dotCheckColor: "#000000"
                                }
                            }

                            // 空降助手开关：自动跳过社区标注的恰饭/片头等片段。
                            // bsb.conf 缺失或本会话被自动禁用时整体隐藏（功能不存在）
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                visible: SponsorBlockManager.available

                                FluText {
                                    text: "空降助手（跳过恰饭）"
                                    font: FluTextStyle.Body
                                    color: "#FFFFFF"
                                }

                                Item { Layout.fillWidth: true }

                                FluToggleSwitch {
                                    checked: pageRoot.sponsorEnabled
                                    clickListener: function() {
                                        pageRoot.sponsorEnabled = !pageRoot.sponsorEnabled
                                        savePlayerSettings()
                                    }
                                    normalColor: "#323232"
                                    hoverColor: "#3E3E3E"
                                    borderNormalColor: "#A1A1A1"
                                    dotNormalColor: "#D0D0D0"
                                    dotCheckColor: "#000000"
                                }
                            }

                            // 常驻 mini 进度条开关：控制栏隐藏后底部显示
                            // 无滑块进度细条（含章节刻度与空降色块）
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8

                                FluText {
                                    text: "常驻进度条"
                                    font: FluTextStyle.Body
                                    color: "#FFFFFF"
                                }

                                Item { Layout.fillWidth: true }

                                FluToggleSwitch {
                                    checked: pageRoot.miniProgressEnabled
                                    clickListener: function() {
                                        pageRoot.miniProgressEnabled = !pageRoot.miniProgressEnabled
                                        savePlayerSettings()
                                    }
                                    normalColor: "#323232"
                                    hoverColor: "#3E3E3E"
                                    borderNormalColor: "#A1A1A1"
                                    dotNormalColor: "#D0D0D0"
                                    dotCheckColor: "#000000"
                                }
                            }

                            // 弹幕帧率限制（高刷屏节流档位；60Hz 屏不节流，禁用）
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8

                                FluText {
                                    text: "弹幕帧率限制"
                                    font: FluTextStyle.Body
                                    color: "#FFFFFF"
                                    opacity: danmakuFpsCombo.enabled ? 1.0 : 0.4
                                }

                                Item { Layout.fillWidth: true }

                                FluComboBox {
                                    id: danmakuFpsCombo
                                    // 候选档位：不超过当前屏幕刷新率（+1 容差，
                                    // 刷新率报告值常略低于名义值），0 = 不限制
                                    readonly property var optionValues: {
                                        var refresh = pageRoot.screenRefreshRate
                                        var vals = [60, 100, 120, 144].filter(
                                            function(r) { return r <= refresh + 1 })
                                        vals.push(0)
                                        return vals
                                    }
                                    // 60Hz 屏（≤63Hz）：本就不节流，禁用控件
                                    enabled: pageRoot.screenRefreshRate > 63
                                    model: optionValues.map(
                                        function(v) { return v === 0 ? "不限制" : v + " fps" })
                                    // 初始/换屏后同步选中项：保存值不在候选内
                                    //（如 144 档换到 120Hz 屏）时回退到 60
                                    function syncIndex() {
                                        var idx = optionValues.indexOf(pageRoot.danmakuFpsLimit)
                                        if (idx < 0)
                                            idx = optionValues.indexOf(60)
                                        currentIndex = idx >= 0 ? idx : 0
                                    }
                                    Component.onCompleted: syncIndex()
                                    onOptionValuesChanged: syncIndex()
                                    // 只响应真实用户选择（activated），模型重建
                                    // 引起的 currentIndex 变化不写设置
                                    onActivated: function(index) {
                                        pageRoot.danmakuFpsLimit = optionValues[index]
                                        FramePacer.setTargetRate(pageRoot.danmakuFpsLimit)
                                        savePlayerSettings()
                                    }
                                }
                            }

                            // 弹幕描边样式（对齐 B 站三档）
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8

                                FluText {
                                    text: "描边样式"
                                    font: FluTextStyle.Body
                                    color: "#FFFFFF"
                                }

                                Item { Layout.fillWidth: true }

                                FluComboBox {
                                    model: ["描边", "重墨", "45°投影"]
                                    currentIndex: pageRoot.danmakuOutlineStyle
                                    onActivated: function(index) {
                                        pageRoot.danmakuOutlineStyle = index
                                        savePlayerSettings()
                                    }
                                }
                            }

                            // 弹幕大小
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 6

                                FluText {
                                    text: "弹幕大小"
                                    font: FluTextStyle.Body
                                    color: "#FFFFFF"
                                }

                                FluSlider {
                                    Layout.fillWidth: true
                                    from: 0.5
                                    to: 2.0
                                    stepSize: 0.1
                                    value: pageRoot.danmakuSize
                                    text: value.toFixed(1) + "x"
                                    onValueChanged: pageRoot.danmakuSize = value
                                }
                            }

                            // 不透明度
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 6

                                FluText {
                                    text: "不透明度"
                                    font: FluTextStyle.Body
                                    color: "#FFFFFF"
                                }

                                FluSlider {
                                    Layout.fillWidth: true
                                    from: 0.1
                                    to: 1.0
                                    stepSize: 0.05
                                    value: pageRoot.danmakuOpacity
                                    text: Math.round(value * 100) + "%"
                                    onValueChanged: pageRoot.danmakuOpacity = value
                                }
                            }

                            // 显示范围
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 6

                                FluText {
                                    text: "显示范围"
                                    font: FluTextStyle.Body
                                    color: "#FFFFFF"
                                }

                                FluRadioButtons {
                                    id: danmakuRangeGroup
                                    orientation: Qt.Horizontal
                                    currentIndex: pageRoot.danmakuRangeIndex
                                    onCurrentIndexChanged: pageRoot.danmakuRangeIndex = currentIndex

                                    FluRadioButton { text: "1/4屏"; textColor: "#FFFFFF" }
                                    FluRadioButton { text: "半屏"; textColor: "#FFFFFF" }
                                    FluRadioButton { text: "3/4屏"; textColor: "#FFFFFF" }
                                    FluRadioButton { text: "全屏"; textColor: "#FFFFFF" }
                                }
                            }

                            // 弹幕速度
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 6

                                FluText {
                                    text: "弹幕速度"
                                    font: FluTextStyle.Body
                                    color: "#FFFFFF"
                                }

                                FluRadioButtons {
                                    id: danmakuSpeedGroup
                                    orientation: Qt.Horizontal
                                    currentIndex: pageRoot.danmakuSpeedIndex
                                    onCurrentIndexChanged: pageRoot.danmakuSpeedIndex = currentIndex

                                    FluRadioButton { text: "慢"; textColor: "#FFFFFF" }
                                    FluRadioButton { text: "中"; textColor: "#FFFFFF" }
                                    FluRadioButton { text: "快"; textColor: "#FFFFFF" }
                                }
                            }
                        }
                    }
                }
            }

            // ---- 底部信息面板 ----
            Column {
                id: bottomPanel
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                visible: !pageRoot.isFullScreen
                spacing: pageRoot.smallSpacing

                // 视频标题
                FluText {
                    id: titleLabel
                    text: pageRoot.videoTitle
                    font: FluTextStyle.Subtitle
                    color: FluTheme.fontPrimaryColor
                    wrapMode: Text.Wrap
                    width: parent.width
                    maximumLineCount: 2
                    elide: Text.ElideRight

                    // 悬停检测（无点击处理，不影响下层交互）
                    MouseArea {
                        id: titleHoverArea
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.NoButton
                    }

                    // 视频简介不为空时，悬停标题显示简介
                    FluTooltip {
                        visible: titleHoverArea.containsMouse && pageRoot.description !== ""
                        text: pageRoot.description
                        delay: 500
                        width: Math.min(implicitWidth, 480)
                    }
                }

                // UP主信息栏
                FluFrame {
                    width: parent.width
                    radius: 6
                    padding: 10

                    RowLayout {
                        anchors.fill: parent
                        spacing: 10

                        Rectangle {
                            width: 44
                            height: 44
                            radius: 22
                            color: "#40FFFFFF"
                            Layout.alignment: Qt.AlignVCenter
                            antialiasing: true

                            AvatarWithPendant {
                                anchors.centerIn: parent
                                avatarSize: 40
                                face: pageRoot.upFace
                                pendantImage: pageRoot.upPendantImage
                                verifyType: pageRoot.upVerify
                                placeholderText: "UP"
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2

                            FluText {
                                text: pageRoot.upName
                                font: FluTextStyle.Body
                                color: pageRoot.upVipType > 0 ? "#FB7299" : FluTheme.fontPrimaryColor
                            }

                            FluText {
                                text: pageRoot.upFans
                                font: FluTextStyle.Caption
                                color: FluTheme.fontSecondaryColor
                                visible: pageRoot.upFans !== ""
                            }
                        }

                        // 未关注：FluFilledButton（主题色实底，醒目）；已关注：
                        // FluButton（普通灰底，低调）。与直播播放页关注按钮一致
                        Loader {
                            Layout.preferredWidth: 70
                            Layout.preferredHeight: 30
                            sourceComponent: pageRoot.isFollowing ? followPlainBtn : followFilledBtn

                            Component {
                                id: followFilledBtn
                                FluFilledButton {
                                    text: "+ 关注"
                                    anchors.fill: parent
                                    onClicked: {
                                        if (pageRoot.mid === "") return
                                        if (!pageRoot.requireLogin()) return
                                        InteractionManager.followUser(pageRoot.mid, 1)
                                        pageRoot.isFollowing = true
                                    }
                                }
                            }
                            Component {
                                id: followPlainBtn
                                FluButton {
                                    text: "已关注"
                                    anchors.fill: parent
                                    onClicked: {
                                        if (pageRoot.mid === "") return
                                        if (!pageRoot.requireLogin()) return
                                        InteractionManager.followUser(pageRoot.mid, 2)
                                        pageRoot.isFollowing = false
                                    }
                                }
                            }
                        }

                        Item { Layout.fillWidth: true }

                        Row {
                            spacing: 12
                            Layout.alignment: Qt.AlignVCenter

                            Row {
                                spacing: 4
                                visible: pageRoot.onlineCount !== ""

                                FluIcon {
                                    iconSource: FluentIcons.Calories
                                    iconSize: 12
                                    color: "#FF6699"
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                FluText {
                                    text: pageRoot.onlineCount
                                    font: FluTextStyle.Caption
                                    color: "#FF6699"
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            FluText {
                                text: pageRoot.viewCount + "播放"
                                font: FluTextStyle.Caption
                                color: FluTheme.fontSecondaryColor
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            FluText {
                                text: pageRoot.danmakuCount + "弹幕"
                                font: FluTextStyle.Caption
                                color: FluTheme.fontSecondaryColor
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            FluText {
                                text: pageRoot.pubDate
                                font: FluTextStyle.Caption
                                color: FluTheme.fontSecondaryColor
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                    }
                }

                // 互动按钮栏
                FluFrame {
                    width: parent.width
                    radius: 6
                    padding: 8

                    RowLayout {
                        anchors.fill: parent
                        spacing: 12

                        FluButton {
                            Layout.preferredHeight: 34
                            Layout.preferredWidth: 100
                            background: Rectangle {
                                color: pageRoot.isLiked ? "#FF6699" : "transparent"
                                radius: 4
                            }
                            contentItem: RowLayout {
                                anchors.fill: parent
                                spacing: 0

                                Item { Layout.fillWidth: true }

                                IconFontIcon {
                                    name: "thumb-up"
                                    Layout.preferredWidth: 20
                                    Layout.preferredHeight: 20
                                    iconColor: pageRoot.isLiked ? "#FFFFFF" : FluTheme.fontPrimaryColor
                                    Layout.alignment: Qt.AlignVCenter
                                }

                                FluText {
                                    text: "点赞" + pageRoot.likeCount
                                    font: FluTextStyle.Body
                                    color: pageRoot.isLiked ? "#FFFFFF" : FluTheme.fontPrimaryColor
                                    Layout.alignment: Qt.AlignVCenter
                                }

                                Item { Layout.fillWidth: true }
                            }
                            onClicked: {
                                if (pageRoot.aid === "") return
                                if (!pageRoot.requireLogin()) return
                                if (pageRoot.isDisliked) {
                                    pageRoot.isDisliked = false
                                }
                                var newLiked = !pageRoot.isLiked
                                InteractionManager.likeVideo(pageRoot.aid, newLiked ? 1 : 2)
                                pageRoot.rawLikeCount += newLiked ? 1 : -1
                                pageRoot.likeCount = pageRoot.formatNumber(pageRoot.rawLikeCount)
                                pageRoot.isLiked = newLiked
                            }
                        }

                        FluButton {
                            Layout.preferredHeight: 34
                            Layout.preferredWidth: 100
                            background: Rectangle {
                                color: pageRoot.isDisliked ? "#999999" : "transparent"
                                radius: 4
                            }
                            contentItem: RowLayout {
                                anchors.fill: parent
                                spacing: 0

                                Item { Layout.fillWidth: true }

                                IconFontIcon {
                                    name: "thumb-down"
                                    Layout.preferredWidth: 20
                                    Layout.preferredHeight: 20
                                    iconColor: pageRoot.isDisliked ? "#FFFFFF" : FluTheme.fontPrimaryColor
                                    Layout.alignment: Qt.AlignVCenter
                                }

                                FluText {
                                    text: "点踩"
                                    font: FluTextStyle.Body
                                    color: pageRoot.isDisliked ? "#FFFFFF" : FluTheme.fontPrimaryColor
                                    Layout.alignment: Qt.AlignVCenter
                                }

                                Item { Layout.fillWidth: true }
                            }
                            onClicked: {
                                if (pageRoot.aid === "") return
                                if (!pageRoot.requireLogin()) return
                                pageRoot.lastDislikeOldLiked = pageRoot.isLiked
                                pageRoot.lastDislikeOldDisliked = pageRoot.isDisliked
                                if (pageRoot.isLiked) {
                                    pageRoot.rawLikeCount -= 1
                                    pageRoot.likeCount = pageRoot.formatNumber(pageRoot.rawLikeCount)
                                    pageRoot.isLiked = false
                                }
                                pageRoot.isDisliked = !pageRoot.lastDislikeOldDisliked
                                InteractionManager.dislikeVideo(pageRoot.aid, pageRoot.isDisliked ? 1 : 0, pageRoot.isLiked ? 1 : 0)
                            }
                        }

                        FluButton {
                            id: coinButton
                            Layout.preferredHeight: 34
                            Layout.preferredWidth: 100
                            background: Rectangle {
                                color: pageRoot.isCoined ? "#00A1D6" : "transparent"
                                radius: 4
                            }
                            contentItem: RowLayout {
                                anchors.fill: parent
                                spacing: 0

                                Item { Layout.fillWidth: true }

                                IconFontIcon {
                                    name: "coin"
                                    Layout.preferredWidth: 20
                                    Layout.preferredHeight: 20
                                    iconColor: pageRoot.isCoined ? "#FFFFFF" : FluTheme.fontPrimaryColor
                                    Layout.alignment: Qt.AlignVCenter
                                }

                                FluText {
                                    text: "投币" + pageRoot.coinCount
                                    font: FluTextStyle.Body
                                    color: pageRoot.isCoined ? "#FFFFFF" : FluTheme.fontPrimaryColor
                                    Layout.alignment: Qt.AlignVCenter
                                }

                                Item { Layout.fillWidth: true }
                            }
                            onClicked: {
                                if (pageRoot.aid === "") return
                                if (!pageRoot.requireLogin()) return
                                coinMenu.popup()
                            }

                            FluMenu {
                                id: coinMenu
                                FluMenuItem {
                                    text: "投一个币"
                                    onClicked: {
                                        if (!pageRoot.requireLogin()) return
                                        pageRoot.lastCoinMultiply = 1
                                        pageRoot.lastCoinSelectLike = 0
                                        InteractionManager.coinVideo(pageRoot.aid, pageRoot.bvid, pageRoot.lastCoinMultiply, pageRoot.lastCoinSelectLike)
                                    }
                                }
                                FluMenuItem {
                                    text: "投两个币"
                                    onClicked: {
                                        if (!pageRoot.requireLogin()) return
                                        pageRoot.lastCoinMultiply = 2
                                        pageRoot.lastCoinSelectLike = 0
                                        InteractionManager.coinVideo(pageRoot.aid, pageRoot.bvid, pageRoot.lastCoinMultiply, pageRoot.lastCoinSelectLike)
                                    }
                                }
                            }
                        }

                        FluButton {
                            Layout.preferredHeight: 34
                            Layout.preferredWidth: 100
                            background: Rectangle {
                                color: pageRoot.isFavorited ? "#FFB800" : "transparent"
                                radius: 4
                            }
                            contentItem: RowLayout {
                                anchors.fill: parent
                                spacing: 0

                                Item { Layout.fillWidth: true }

                                IconFontIcon {
                                    name: "star"
                                    Layout.preferredWidth: 20
                                    Layout.preferredHeight: 20
                                    iconColor: pageRoot.isFavorited ? "#FFFFFF" : FluTheme.fontPrimaryColor
                                    Layout.alignment: Qt.AlignVCenter
                                }

                                FluText {
                                    text: "收藏" + pageRoot.favoriteCount
                                    font: FluTextStyle.Body
                                    color: pageRoot.isFavorited ? "#FFFFFF" : FluTheme.fontPrimaryColor
                                    Layout.alignment: Qt.AlignVCenter
                                }

                                Item { Layout.fillWidth: true }
                            }
                            onClicked: {
                                if (pageRoot.aid === "") return
                                if (!pageRoot.requireLogin()) return
                                if (pageRoot.defaultFavoriteFid === "") {
                                    pageRoot.pendingFavoriteClick = true
                                    InteractionManager.getDefaultFavoriteFolder(pageRoot.aid)
                                    return
                                }
                                if (pageRoot.isFavorited) {
                                    InteractionManager.unfavoriteVideo(pageRoot.aid, pageRoot.defaultFavoriteFid)
                                    pageRoot.rawFavoriteCount -= 1
                                } else {
                                    InteractionManager.favoriteVideo(pageRoot.aid, pageRoot.defaultFavoriteFid, 1)
                                    pageRoot.rawFavoriteCount += 1
                                }
                                pageRoot.favoriteCount = pageRoot.formatNumber(pageRoot.rawFavoriteCount)
                                pageRoot.isFavorited = !pageRoot.isFavorited
                            }
                        }

                        Item { Layout.fillWidth: true }
                    }
                }
            }
        }

        // ========== 右侧：标签切换区 ==========
        ColumnLayout {
            Layout.preferredWidth: pageRoot.rightPanelWidth
            Layout.minimumWidth: pageRoot.rightPanelWidth
            Layout.maximumWidth: pageRoot.rightPanelWidth
            Layout.fillHeight: true
            visible: !pageRoot.isFullScreen
            spacing: 0

            // 顶部标签栏 + 关闭按钮
            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: 40
                spacing: 0

                Item {
                    Layout.fillWidth: true
                    height: 40

                    Row {
                        id: pivotHeader
                        anchors.fill: parent
                        spacing: 0

                        Repeater {
                            model: pageRoot.pivotTabs

                            Rectangle {
                                width: pivotHeader.width / pageRoot.tabCount
                                height: 40
                                color: "transparent"

                                FluText {
                                    anchors.centerIn: parent
                                    text: modelData
                                    font: FluTextStyle.Body
                                    color: pageRoot.stackIndexToTabIndex(rightStack.currentIndex) === index ? FluTheme.primaryColor : FluTheme.fontSecondaryColor
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: pageRoot.switchTab(index)
                                }
                            }
                        }
                    }

                    Rectangle {
                        anchors.bottom: parent.bottom
                        height: 3
                        radius: 1.5
                        color: FluTheme.primaryColor
                        width: parent.width / pageRoot.tabCount * 0.5
                        x: pageRoot.stackIndexToTabIndex(rightStack.currentIndex) * (parent.width / pageRoot.tabCount) + (parent.width / pageRoot.tabCount - width) / 2
                        Behavior on x {
                            NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
                        }
                    }
                }

                FluIconButton {
                    iconSource: FluentIcons.ChromeClose
                    iconSize: 12
                    onClicked: {
                        closePopups()
                        App.closeVideo()
                    }
                }
            }

            // 内容区
            StackLayout {
                id: rightStack
                Layout.fillWidth: true
                Layout.fillHeight: true
                currentIndex: 0
                onCurrentIndexChanged: {
                    // 懒加载推荐页和投稿页
                    // index 3: 推荐, index 4: 投稿
                    var recommendTabIndex = stackIndexOf("推荐")
                    if (currentIndex === recommendTabIndex && !pageRoot._relatedLoaded) {
                        pageRoot._relatedLoaded = true
                        loadRelated()
                    }
                    var uploadTabIndex = stackIndexOf("投稿")
                    if (currentIndex === uploadTabIndex && !pageRoot._uploadsLoaded) {
                        pageRoot._uploadsLoaded = true
                        loadUploads()
                    }
                }

                // ---------- 评论页 ----------
                Rectangle {
                    color: "transparent"
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    ColumnLayout {
                        anchors.fill: parent
                        spacing: 8

                        // 评论头部
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 32

                            FluText {
                                text: pageRoot.commentSortByHeat ? "热门评论" : "最新评论"
                                font: FluTextStyle.Body
                                color: FluTheme.fontPrimaryColor
                                enabled: false
                            }

                            Item { Layout.fillWidth: true }

                            Rectangle {
                                height: sortRow.implicitHeight + 6
                                width: sortRow.implicitWidth + 12
                                color: "transparent"
                                radius: 4
                                Layout.alignment: Qt.AlignVCenter

                                Row {
                                    id: sortRow
                                    anchors.centerIn: parent
                                    spacing: 4

                                    FluIcon {
                                        iconSource: FluentIcons.GlobalNavButton
                                        iconSize: 12
                                        color: FluTheme.fontSecondaryColor
                                        anchors.verticalCenter: parent.verticalCenter
                                    }

                                    FluText {
                                        text: pageRoot.commentSortByHeat ? "按热度" : "按时间"
                                        font: FluTextStyle.Caption
                                        color: FluTheme.fontSecondaryColor
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: { pageRoot.toggleCommentSort() }
                                }
                            }
                        }

                        // 评论列表
                        Flickable {
                            id: commentFlickable
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true
                            contentHeight: commentList.height
                            boundsBehavior: Flickable.StopAtBounds
                            rightMargin: 12

                            ScrollBar.vertical: FluScrollBar {}

                            Column {
                                id: commentList
                                width: parent.width
                                spacing: 0

                                Repeater {
                                    model: pageRoot.commentModel

                                    Rectangle {
                                        id: commentItem
                                        width: parent.width
                                        height: commentItemLayout.height + 16
                                        color: "transparent"
                                        property int commentIndex: index
                                        property var parentModel: model

                                        ColumnLayout {
                                            id: commentItemLayout
                                            anchors.top: parent.top
                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            anchors.topMargin: 8
                                            anchors.leftMargin: 8
                                            anchors.rightMargin: 8
                                            spacing: 6

                                            RowLayout {
                                                Layout.fillWidth: true
                                                spacing: 8

                                                AvatarWithPendant {
                                                    face: model.face || ""
                                                    pendantImage: model.pendantImage || ""
                                                    avatarSize: 32
                                                    verifyType: model.verifyType !== undefined ? model.verifyType : -1
                                                    Layout.alignment: Qt.AlignTop
                                                }

                                                ColumnLayout {
                                                    Layout.fillWidth: true
                                                    spacing: 2

                                                    Row {
                                                        spacing: 4

                                                        FluText {
                                                            text: model.uname || ""
                                                            font: FluTextStyle.Caption
                                                            color: {
                                                                if (model.isTop)
                                                                    return FluTheme.primaryColor
                                                                if (model.isVip)
                                                                    return "#FB7299"
                                                                return FluTheme.fontSecondaryColor
                                                            }
                                                            anchors.verticalCenter: parent.verticalCenter
                                                        }

                                                        Image {
                                                            source: pageRoot.levelIconSource(model.level)
                                                            width: 32
                                                            height: 16
                                                            sourceSize: Qt.size(width * Screen.devicePixelRatio, height * Screen.devicePixelRatio)
                                                            fillMode: Image.PreserveAspectFit
                                                            anchors.verticalCenter: parent.verticalCenter
                                                            visible: model.level > 0
                                                            asynchronous: true
                                                        }

                                                        Image {
                                                            source: "qrc:/BiliQt/icons/level/user-up.svg"
                                                            width: 32
                                                            height: 16
                                                            sourceSize: Qt.size(width * Screen.devicePixelRatio, height * Screen.devicePixelRatio)
                                                            fillMode: Image.PreserveAspectFit
                                                            anchors.verticalCenter: parent.verticalCenter
                                                            visible: pageRoot.isUpAuthor(model.mid)
                                                            asynchronous: true
                                                        }

                                                        FluText {
                                                            text: "置顶"
                                                            font: FluTextStyle.Caption
                                                            color: FluTheme.primaryColor
                                                            anchors.verticalCenter: parent.verticalCenter
                                                            visible: model.isTop
                                                        }
                                                    }

                                                    FluText {
                                                        text: pageRoot.formatCommentContent(model.content, model.emotes, false, model.jumpUrls)
                                                        font: FluTextStyle.Body
                                                        color: FluTheme.fontPrimaryColor
                                                        textFormat: Text.RichText
                                                        wrapMode: Text.Wrap
                                                        Layout.fillWidth: true
                                                        Layout.preferredWidth: 0
                                                        Layout.topMargin: 14
                                                        verticalAlignment: Text.AlignTop
                                                        onLinkActivated: function(link) {
                                                            if (link.indexOf("timestamp:") === 0) {
                                                                var ms = parseInt(link.substring("timestamp:".length), 10)
                                                                mpvPlayer.seek(ms)
                                                            }
                                                        }
                                                    }

                                                    Grid {
                                                        Layout.topMargin: 4
                                                        Layout.fillWidth: true
                                                        columns: 2
                                                        rowSpacing: 8
                                                        columnSpacing: 8

                                                        Repeater {
                                                            model: {
                                                                var pics = commentItem.parentModel.pictures
                                                                var count = pageRoot.commentPicCount(pics)
                                                                return count
                                                            }

                                                            Rectangle {
                                                                id: mainImageContainer
                                                                property var pic: pageRoot.commentPicAt(commentItem.parentModel.pictures, index)
                                                                property int imageSize: pageRoot.calcCommentGridImageSize(commentItemLayout.width - 48)
                                                                property bool picIsSmallerThanContainer: pic.width > 0 && pic.height > 0 && pic.width < imageSize && pic.height < imageSize
                                                                width: imageSize
                                                                height: imageSize
                                                                radius: 6
                                                                color: FluTheme.frameColor
                                                                clip: true
                                                                visible: pic.imgSrc && pic.imgSrc !== ""
                                                                layer.enabled: true
                                                                layer.samples: 4
                                                                layer.smooth: true
                                                                layer.effect: MultiEffect {
                                                                    maskEnabled: true
                                                                    maskSource: ShaderEffectSource {
                                                                        sourceItem: Rectangle {
                                                                            width: mainImageContainer.width
                                                                            height: mainImageContainer.height
                                                                            radius: mainImageContainer.radius
                                                                            color: "black"
                                                                        }
                                                                        hideSource: true
                                                                        live: true
                                                                    }
                                                                }

                                                                Loader {
                                                                    anchors.fill: parent
                                                                    sourceComponent: pic.isAnimated ? commentAnimatedImageComponent : commentStaticImageComponent
                                                                }

                                                                Component {
                                                                    id: commentStaticImageComponent
                                                                    FluImage {
                                                                        anchors.fill: parent
                                                                        source: GlobalState.fixImageUrl(pageRoot.getCommentImageThumbnailUrl(mainImageContainer.pic.imgSrc, mainImageContainer.imageSize, false))
                                                                        fillMode: mainImageContainer.picIsSmallerThanContainer ? Image.PreserveAspectFit : Image.PreserveAspectCrop
                                                                        asynchronous: true
                                                                        cache: true
                                                                        smooth: true
                                                                    }
                                                                }

                                                                Component {
                                                                    id: commentAnimatedImageComponent
                                                                    AnimatedImage {
                                                                        anchors.fill: parent
                                                                        source: GlobalState.fixImageUrl(pageRoot.getCommentImageThumbnailUrl(mainImageContainer.pic.imgSrc, mainImageContainer.imageSize, true))
                                                                        fillMode: mainImageContainer.picIsSmallerThanContainer ? Image.PreserveAspectFit : Image.PreserveAspectCrop
                                                                        cache: true
                                                                        smooth: true
                                                                        playing: true
                                                                    }
                                                                }

                                                                MouseArea {
                                                                    anchors.fill: parent
                                                                    cursorShape: Qt.PointingHandCursor
                                                                    onClicked: {
                                                                        pageRoot.openCommentImagePreview(commentItem.parentModel.pictures, index)
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }

                                            RowLayout {
                                                Layout.fillWidth: true
                                                Layout.topMargin: 6
                                                spacing: 16

                                                FluText {
                                                    text: GlobalState.formatCommentTime(model.ctime)
                                                    font: FluTextStyle.Caption
                                                    color: FluTheme.fontSecondaryColor
                                                    Layout.alignment: Qt.AlignVCenter
                                                }

                                                FluText {
                                                    text: model.ipLocation || ""
                                                    font: FluTextStyle.Caption
                                                    color: FluTheme.fontSecondaryColor
                                                    Layout.alignment: Qt.AlignVCenter
                                                    visible: model.ipLocation && model.ipLocation !== ""
                                                }

                                                FluTextButton {
                                                    text: "回复"
                                                    font: FluTextStyle.Caption
                                                    textColor: FluTheme.fontSecondaryColor
                                                    onClicked: {
                                                        if (!pageRoot.requireLogin()) return
                                                        pageRoot.replyRpid = model.rpid || ""
                                                        pageRoot.replyRootRpid = (model.root && model.root !== "0") ? model.root : (model.rpid || "")
                                                        pageRoot.replyToUser = model.uname || ""
                                                    }
                                                }

                                                Item { Layout.fillWidth: true }

                                                FluTextButton {
                                                    font: FluTextStyle.Caption
                                                    textColor: FluTheme.fontSecondaryColor
                                                    onClicked: {
                                                        if (pageRoot.aid === "" || !model.rpid || !pageRoot.commentModel || index < 0) return
                                                        if (!pageRoot.requireLogin()) return
                                                        var oldAction = model.action || 0
                                                        var newAction = oldAction === 1 ? 0 : 1
                                                        if (oldAction === 2) {
                                                            CommentManager.hateComment(model.rpid, pageRoot.aid, 1, 0)
                                                        }
                                                        CommentManager.likeComment(model.rpid, pageRoot.aid, 1, newAction)
                                                        pageRoot.commentModel.setProperty(index, "action", newAction)
                                                        pageRoot.commentModel.setProperty(index, "like", model.like + (newAction === 1 ? 1 : -1))
                                                    }
                                                    contentItem: RowLayout {
                                                        spacing: 4
                                                        IconFontIcon {
                                                            name: "thumb-up"
                                                            Layout.preferredWidth: 16
                                                            Layout.preferredHeight: 16
                                                            iconColor: model.action === 1 ? FluTheme.primaryColor : FluTheme.fontSecondaryColor
                                                            Layout.alignment: Qt.AlignVCenter
                                                        }
                                                        FluText {
                                                            text: GlobalState.formatNumber(model.like)
                                                            font: FluTextStyle.Caption
                                                            color: model.action === 1 ? FluTheme.primaryColor : FluTheme.fontSecondaryColor
                                                            Layout.alignment: Qt.AlignVCenter
                                                        }
                                                    }
                                                }

                                                FluTextButton {
                                                    font: FluTextStyle.Caption
                                                    textColor: model.action === 2 ? FluTheme.primaryColor : FluTheme.fontSecondaryColor
                                                    onClicked: {
                                                        if (pageRoot.aid === "" || !model.rpid || !pageRoot.commentModel || index < 0) return
                                                        if (!pageRoot.requireLogin()) return
                                                        var oldAction = model.action || 0
                                                        var newAction = oldAction === 2 ? 0 : 2
                                                        if (oldAction === 1) {
                                                            CommentManager.likeComment(model.rpid, pageRoot.aid, 1, 0)
                                                        }
                                                        CommentManager.hateComment(model.rpid, pageRoot.aid, 1, newAction === 2 ? 1 : 0)
                                                        pageRoot.commentModel.setProperty(index, "action", newAction)
                                                        if (oldAction === 1) pageRoot.commentModel.setProperty(index, "like", model.like - 1)
                                                    }
                                                    contentItem: RowLayout {
                                                        spacing: 0
                                                        IconFontIcon {
                                                            name: "thumb-down"
                                                            Layout.preferredWidth: 16
                                                            Layout.preferredHeight: 16
                                                            iconColor: model.action === 2 ? FluTheme.primaryColor : FluTheme.fontSecondaryColor
                                                            Layout.alignment: Qt.AlignVCenter
                                                        }
                                                    }
                                                }
                                            }

                                            // ====== 展开/收起子评论按钮 ======
                                            FluTextButton {
                                                Layout.alignment: Qt.AlignLeft
                                                Layout.topMargin: 2
                                                text: model.repliesExpanded ? "收起回复" : "共" + (model.count || 0) + "条回复>"
                                                font: FluTextStyle.Caption
                                                textColor: "#00A1D6"
                                                topPadding: 0
                                                bottomPadding: 0
                                                visible: (model.count || 0) > 0
                                                onClicked: {
                                                    var before = model.repliesExpanded
                                                    var after = !before
                                                    pageRoot.commentModel.setProperty(index, "repliesExpanded", after)
                                                    pageRoot.commentModel.setProperty(index, "repliesPage", 1)
                                                    if (after && model.aid !== "" && model.rpid !== "") {
                                                        CommentManager.getSubComments(model.aid, model.rpid, 1, 10)
                                                    }
                                                    if (!after) {
                                                        commentFlickable.contentY = commentItem.y
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    // 子评论列表
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 8
                                        visible: model.repliesExpanded
                                        property var subReplies: JSON.parse(model.repliesJson || "[]") || []

                                        Repeater {
                                            model: parent.subReplies

                                            RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 8

                                                // 子评论头像
                                                AvatarWithPendant {
                                                        face: modelData.face || ""
                                                        pendantImage: modelData.pendantImage || ""
                                                        avatarSize: 28
                                                        verifyType: modelData.verifyType !== undefined ? modelData.verifyType : -1
                                                        placeholderText: "?"
                                                        Layout.alignment: Qt.AlignTop
                                                    }

                                                ColumnLayout {
                                                    Layout.fillWidth: true
                                                    spacing: 2

                                                    Row {
                                                        spacing: 4

                                                        FluText {
                                                            text: modelData.uname || ""
                                                            font: FluTextStyle.Caption
                                                            color: modelData.isVip ? "#FB7299" : FluTheme.fontSecondaryColor
                                                            anchors.verticalCenter: parent.verticalCenter
                                                        }

                                                        Image {
                                                            source: pageRoot.levelIconSource(modelData.level)
                                                            width: 32
                                                            height: 16
                                                            sourceSize: Qt.size(width * Screen.devicePixelRatio, height * Screen.devicePixelRatio)
                                                            fillMode: Image.PreserveAspectFit
                                                            anchors.verticalCenter: parent.verticalCenter
                                                            visible: modelData.level > 0
                                                            asynchronous: true
                                                        }

                                                        Image {
                                                            source: "qrc:/BiliQt/icons/level/user-up.svg"
                                                            width: 32
                                                            height: 16
                                                            sourceSize: Qt.size(width * Screen.devicePixelRatio, height * Screen.devicePixelRatio)
                                                            fillMode: Image.PreserveAspectFit
                                                            anchors.verticalCenter: parent.verticalCenter
                                                            visible: pageRoot.isUpAuthor(modelData.mid)
                                                            asynchronous: true
                                                        }
                                                    }

                                                    FluText {
                                                        text: pageRoot.formatCommentContent(modelData.content, modelData.emotes, true, modelData.jumpUrls)
                                                        font: FluTextStyle.Body
                                                        color: FluTheme.fontPrimaryColor
                                                        textFormat: Text.RichText
                                                        wrapMode: Text.Wrap
                                                        Layout.fillWidth: true
                                                        Layout.preferredWidth: 0
                                                        Layout.topMargin: 8
                                                        verticalAlignment: Text.AlignTop
                                                        onLinkActivated: function(link) {
                                                            if (link.indexOf("timestamp:") === 0) {
                                                                var ms = parseInt(link.substring("timestamp:".length), 10)
                                                                mpvPlayer.seek(ms)
                                                            }
                                                        }
                                                    }

                                                    Grid {
                                                        Layout.topMargin: 4
                                                        Layout.fillWidth: true
                                                        columns: 2
                                                        rowSpacing: 8
                                                        columnSpacing: 8

                                                        Repeater {
                                                            model: {
                                                                var pics = modelData.pictures
                                                                var count = pageRoot.commentPicCount(pics)
                                                                return count
                                                            }

                                                            Rectangle {
                                                                id: replyImageContainer
                                                                property var pic: pageRoot.commentPicAt(modelData.pictures, index)
                                                                property int imageSize: pageRoot.calcCommentGridImageSize(commentItemLayout.width - 48)
                                                                property bool picIsSmallerThanContainer: pic.width > 0 && pic.height > 0 && pic.width < imageSize && pic.height < imageSize
                                                                width: imageSize
                                                                height: imageSize
                                                                radius: 6
                                                                color: FluTheme.frameColor
                                                                clip: true
                                                                visible: pic.imgSrc && pic.imgSrc !== ""
                                                                layer.enabled: true
                                                                layer.samples: 4
                                                                layer.smooth: true
                                                                layer.effect: MultiEffect {
                                                                    maskEnabled: true
                                                                    maskSource: ShaderEffectSource {
                                                                        sourceItem: Rectangle {
                                                                            width: replyImageContainer.width
                                                                            height: replyImageContainer.height
                                                                            radius: replyImageContainer.radius
                                                                            color: "black"
                                                                        }
                                                                        hideSource: true
                                                                        live: true
                                                                    }
                                                                }

                                                                Loader {
                                                                    anchors.fill: parent
                                                                    sourceComponent: pic.isAnimated ? replyAnimatedImageComponent : replyStaticImageComponent
                                                                }

                                                                Component {
                                                                    id: replyStaticImageComponent
                                                                    FluImage {
                                                                        anchors.fill: parent
                                                                        source: GlobalState.fixImageUrl(pageRoot.getCommentImageThumbnailUrl(replyImageContainer.pic.imgSrc, replyImageContainer.imageSize, false))
                                                                        fillMode: replyImageContainer.picIsSmallerThanContainer ? Image.PreserveAspectFit : Image.PreserveAspectCrop
                                                                        asynchronous: true
                                                                        cache: true
                                                                        smooth: true
                                                                    }
                                                                }

                                                                Component {
                                                                    id: replyAnimatedImageComponent
                                                                    AnimatedImage {
                                                                        anchors.fill: parent
                                                                        source: GlobalState.fixImageUrl(pageRoot.getCommentImageThumbnailUrl(replyImageContainer.pic.imgSrc, replyImageContainer.imageSize, true))
                                                                        fillMode: replyImageContainer.picIsSmallerThanContainer ? Image.PreserveAspectFit : Image.PreserveAspectCrop
                                                                        cache: true
                                                                        smooth: true
                                                                        playing: true
                                                                    }
                                                                }

                                                                MouseArea {
                                                                    anchors.fill: parent
                                                                    cursorShape: Qt.PointingHandCursor
                                                                    onClicked: {
                                                                        pageRoot.openCommentImagePreview(modelData.pictures, index)
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }

                                                    RowLayout {
                                                        Layout.fillWidth: true
                                                        spacing: 16

                                                        FluText {
                                                            text: GlobalState.formatCommentTime(modelData.ctime)
                                                            font: FluTextStyle.Caption
                                                            color: FluTheme.fontSecondaryColor
                                                            Layout.alignment: Qt.AlignVCenter
                                                        }

                                                        FluText {
                                                            text: modelData.ipLocation || ""
                                                            font: FluTextStyle.Caption
                                                            color: FluTheme.fontSecondaryColor
                                                            Layout.alignment: Qt.AlignVCenter
                                                            visible: modelData.ipLocation && modelData.ipLocation !== ""
                                                        }

                                                        FluTextButton {
                                                            text: "回复"
                                                            font: FluTextStyle.Caption
                                                            textColor: FluTheme.fontSecondaryColor
                                                            onClicked: {
                                                                if (!pageRoot.requireLogin()) return
                                                                pageRoot.replyRpid = modelData.rpid || ""
                                                                pageRoot.replyRootRpid = commentItem.parentModel.rpid || ""
                                                                pageRoot.replyToUser = modelData.uname || ""
                                                            }
                                                        }

                                                        Item { Layout.fillWidth: true }

                                                        FluTextButton {
                                                            font: FluTextStyle.Caption
                                                            textColor: modelData.action === 1 ? FluTheme.primaryColor : FluTheme.fontSecondaryColor
                                                            onClicked: {
                                                                if (modelData.rpid === "" || modelData.oid === "") return
                                                                if (!pageRoot.requireLogin()) return
                                                                var oldAction = modelData.action || 0
                                                                var newAction = oldAction === 1 ? 0 : 1
                                                                if (oldAction === 2) {
                                                                    CommentManager.hateComment(modelData.rpid, modelData.oid, 1, 0)
                                                                }
                                                                CommentManager.likeComment(modelData.rpid, modelData.oid, 1, newAction)
                                                                var list = JSON.parse(commentItem.parentModel.repliesJson || "[]") || []
                                                                var idx = index
                                                                if (idx >= 0 && idx < list.length) {
                                                                    var item = Object.assign({}, list[idx])
                                                                    item.action = newAction
                                                                    if (newAction === 1) item.like = (item.like || 0) + 1
                                                                    else if (oldAction === 1) item.like = (item.like || 0) - 1
                                                                    var newList = list.slice()
                                                                    newList[idx] = item
                                                                    pageRoot.commentModel.setProperty(commentItem.commentIndex, "repliesJson", JSON.stringify(newList))
                                                                }
                                                            }
                                                            contentItem: RowLayout {
                                                                spacing: 4
                                                                IconFontIcon {
                                                                    name: "thumb-up"
                                                                    Layout.preferredWidth: 16
                                                                    Layout.preferredHeight: 16
                                                                    iconColor: modelData.action === 1 ? FluTheme.primaryColor : FluTheme.fontSecondaryColor
                                                                    Layout.alignment: Qt.AlignVCenter
                                                                }
                                                                FluText {
                                                                    text: GlobalState.formatNumber(modelData.like)
                                                                    font: FluTextStyle.Caption
                                                                    color: modelData.action === 1 ? FluTheme.primaryColor : FluTheme.fontSecondaryColor
                                                                    Layout.alignment: Qt.AlignVCenter
                                                                }
                                                            }
                                                        }

                                                        FluTextButton {
                                                            font: FluTextStyle.Caption
                                                            textColor: modelData.action === 2 ? FluTheme.primaryColor : FluTheme.fontSecondaryColor
                                                            onClicked: {
                                                                if (modelData.rpid === "" || modelData.oid === "") return
                                                                if (!pageRoot.requireLogin()) return
                                                                var oldAction = modelData.action || 0
                                                                var newAction = oldAction === 2 ? 0 : 2
                                                                if (oldAction === 1) {
                                                                    CommentManager.likeComment(modelData.rpid, modelData.oid, 1, 0)
                                                                }
                                                                CommentManager.hateComment(modelData.rpid, modelData.oid, 1, newAction === 2 ? 1 : 0)
                                                                var list = JSON.parse(commentItem.parentModel.repliesJson || "[]") || []
                                                                var idx = index
                                                                if (idx >= 0 && idx < list.length) {
                                                                    var item = Object.assign({}, list[idx])
                                                                    item.action = newAction
                                                                    if (oldAction === 1) item.like = (item.like || 0) - 1
                                                                    var newList = list.slice()
                                                                    newList[idx] = item
                                                                    pageRoot.commentModel.setProperty(commentItem.commentIndex, "repliesJson", JSON.stringify(newList))
                                                                }
                                                            }
                                                            contentItem: RowLayout {
                                                                spacing: 0
                                                                IconFontIcon {
                                                                    name: "thumb-down"
                                                                    Layout.preferredWidth: 16
                                                                    Layout.preferredHeight: 16
                                                                    iconColor: modelData.action === 2 ? FluTheme.primaryColor : FluTheme.fontSecondaryColor
                                                                    Layout.alignment: Qt.AlignVCenter
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                                    }
                                                }

                                                FluPaginationNoArrow {
                                                    Layout.topMargin: 8
                                                    Layout.alignment: Qt.AlignHCenter
                                                    visible: model.repliesExpanded && (model.count || 0) > 10
                                                    itemCount: model.count || 0
                                                    pageSize: 10
                                                    pageCurrent: model.repliesPage || 1
                                                    useTotalPages: true
                                                    totalPages: Math.ceil((model.count || 0) / 10)
                                                    onRequestPage: function (page, count) {
                                                        pageRoot.commentModel.setProperty(index, "repliesPage", page)
                                                        commentFlickable.contentY = commentItem.y
                                                        CommentManager.getSubComments(model.aid, model.rpid, page, count)
                                                    }
                                                }

                                                FluTextButton {
                                                    Layout.alignment: Qt.AlignHCenter
                                                    text: "收起回复"
                                                    font: FluTextStyle.Caption
                                                    textColor: "#00A1D6"
                                                    topPadding: 0
                                                    bottomPadding: 0
                                                    visible: model.repliesExpanded
                                                    onClicked: {
                                                        pageRoot.commentModel.setProperty(index, "repliesExpanded", false)
                                                        pageRoot.commentModel.setProperty(index, "repliesPage", 1)
                                                        commentFlickable.contentY = commentItem.y
                                                    }
                                                }
                                            }
                                        }

                                        // 个性装扮 - 评论卡片右上角背景
                                        CommentCardBg {
                            anchors.top: parent.top
                            anchors.right: parent.right
                            anchors.topMargin: -8
                            anchors.rightMargin: 8
                            cardbg: model.cardbg
                        }

                                        FluDivider {
                                            anchors.bottom: parent.bottom
                                            width: parent.width
                                        }
                                    }
                                }

                                Item {
                                    width: parent.width
                                    height: 12
                                    visible: pageRoot.commentTotal > 0
                                }

                                FluPaginationSimple {
                                    width: parent.width
                                    visible: pageRoot.commentTotal > 0
                                    itemCount: pageRoot.commentTotal
                                    pageSize: 20
                                    pageCurrent: pageRoot.commentPage
                                    hasNextPage: pageRoot.commentHasNextPage
                                    onRequestPage: function (page) {
                                        pageRoot.loadCommentsPage(page, 20)
                                    }
                                }

                                FluText {
                                    width: parent.width
                                    text: pageRoot.commentModel.count === 0 ? "暂无评论" : "正在加载评论..."
                                    font: FluTextStyle.Caption
                                    color: FluTheme.fontSecondaryColor
                                    horizontalAlignment: Text.AlignHCenter
                                    padding: 12
                                    visible: pageRoot.commentModel.count === 0
                                }
                            }
                        }

                        // 发布评论
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 40
                            spacing: 8

                            FluTextBox {
                                id: commentInput
                                Layout.fillWidth: true
                                placeholderText: pageRoot.replyToUser !== "" ? "回复 @" + pageRoot.replyToUser + "..." : "说点什么..."
                            }

                            FluTextButton {
                                text: "取消"
                                font: FluTextStyle.Caption
                                textColor: FluTheme.fontSecondaryColor
                                visible: pageRoot.replyToUser !== ""
                                onClicked: { pageRoot.replyToUser = "" }
                            }

                            FluButton {
                                text: "发布"
                                Layout.preferredWidth: 60
                                onClicked: {
                                    if (pageRoot.aid === "" || commentInput.text === "") return
                                    if (!pageRoot.requireLogin()) return
                                    var rootId = pageRoot.replyRootRpid
                                    var parentId = pageRoot.replyRpid
                                    CommentManager.sendComment(pageRoot.aid, commentInput.text, 1, rootId, parentId)
                                    commentInput.text = ""
                                    pageRoot.replyToUser = ""
                                    pageRoot.replyRpid = ""
                                    pageRoot.replyRootRpid = ""
                                }
                            }
                        }
                    }
                }

                // ---------- 分P页 ----------
                Loader {
                    id: pagesTabLoader
                    active: pageRoot.pagesModel.count > 1
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    sourceComponent: Component {
                        Flickable {
                            id: pagesFlickable
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true
                            contentHeight: pageColumn.height + 16
                            boundsBehavior: Flickable.StopAtBounds
                            ScrollBar.vertical: FluScrollBar {}
                            
                            Column {
                                id: pageColumn
                                x: Theme.spacingSmall
                                y: Theme.spacingSmall
                                width: parent.width - Theme.pageMargins * 2 - Theme.scrollBarReserve
                                spacing: Theme.spacingSmall
                                
                                // 分P列表
                                Repeater {
                                    model: pageRoot.pagesModel
                                    
                                    Rectangle {
                                        width: parent.width
                                        height: 44
                                        radius: 4
                                        color: pageRoot.pageCurrentIndex === index 
                                               ? FluTheme.primaryColor
                                               : FluTheme.frameColor
                                        opacity: pageRoot.pageCurrentIndex === index ? 0.2 : 1.0
                                        border.color: pageRoot.pageCurrentIndex === index 
                                                      ? FluTheme.primaryColor 
                                                      : "transparent"
                                        border.width: pageRoot.pageCurrentIndex === index ? 2 : 0
                                        
                                        RowLayout {
                                            anchors.fill: parent
                                            anchors.margins: 8
                                            spacing: 8
                                            
                                            // 序号（番剧显示B站官方集数，普通分P显示顺序号）
                                            FluText {
                                                text: (model.epIndex || model.page).toString()
                                                font: pageRoot.pageCurrentIndex === index 
                                                      ? FluTextStyle.Body
                                                      : FluTextStyle.Caption
                                                color: pageRoot.pageCurrentIndex === index 
                                                       ? FluTheme.fontPrimaryColor
                                                       : FluTheme.fontSecondaryColor
                                                Layout.preferredWidth: 36
                                                horizontalAlignment: Text.AlignHCenter
                                                verticalAlignment: Text.AlignVCenter
                                            }
                                            
                                            // 分P标题
                                            FluText {
                                                text: model.part || ("P" + model.page)
                                                font: pageRoot.pageCurrentIndex === index
                                                      ? FluTextStyle.Body
                                                      : FluTextStyle.Caption
                                                color: pageRoot.pageCurrentIndex === index
                                                       ? FluTheme.fontPrimaryColor
                                                       : FluTheme.fontSecondaryColor
                                                Layout.fillWidth: true
                                                verticalAlignment: Text.AlignVCenter
                                                elide: Text.ElideRight
                                            }

                                            // 官方角标（会员/限免/预告），右对齐
                                            FluText {
                                                visible: (model.badge || "") !== ""
                                                text: model.badge || ""
                                                font: FluTextStyle.Caption
                                                color: {
                                                    var b = model.badge || ""
                                                    if (b === "会员") return "#FA5157"   // 红
                                                    if (b === "限免") return "#FF9A2E"   // 橘
                                                    if (b === "预告") return "#00AEEC"   // 蓝
                                                    return FluTheme.fontSecondaryColor   // 其他标签灰色兜底
                                                }
                                                Layout.alignment: Qt.AlignVCenter
                                                verticalAlignment: Text.AlignVCenter
                                            }
                                        }
                                        
                                        MouseArea {
                                            anchors.fill: parent
                                            onClicked: {
                                                var cid = model.cid
                                                var pageIdx = index
                                                
                                                // 使用统一的switchPage方法，与选集切换逻辑一致
                                                pageRoot.switchPage(cid, pageIdx)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // ---------- 选集页 ----------
                Loader {
                    id: ugcEpisodesTabLoader
                    active: pageRoot.hasUgcSeason
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    sourceComponent: Component {
                        Flickable {
                            id: ugcEpisodesFlickable
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true
                            contentHeight: episodeColumn.height + 16
                            boundsBehavior: Flickable.StopAtBounds
                            ScrollBar.vertical: FluScrollBar {}
                            
                            Column {
                                id: episodeColumn
                                x: Theme.spacingSmall
                                y: Theme.spacingSmall
                                width: parent.width - Theme.pageMargins * 2 - Theme.scrollBarReserve
                                spacing: Theme.spacingSmall
                                
                                // 合集标题
                                FluText {
                                    text: pageRoot.seasonTitle
                                    font: FluTextStyle.Body
                                    color: FluTheme.fontPrimaryColor
                                    visible: pageRoot.seasonTitle !== ""
                                }
                                
                                // 空状态提示
                                FluText {
                                    text: "暂无分集"
                                    font: FluTextStyle.Body
                                    color: FluTheme.fontSecondaryColor
                                    visible: pageRoot.episodesModel.count === 0
                                }
                                
                                // 分集列表
                                Repeater {
                                    model: pageRoot.episodesModel

                                    Rectangle {
                                        property int _delegateModelIndex: model.index  // 存储 model 索引，用于 scrollUgcEpisodesToCurrentIndex 精确定位（children 顺序不保证与 model 顺序一致）
                                        width: parent.width
                                        height: 44
                                        radius: 4
                                        color: pageRoot.seasonCurrentIndex === model.index 
                                               ? FluTheme.primaryColor
                                               : FluTheme.frameColor
                                        opacity: pageRoot.seasonCurrentIndex === model.index ? 0.2 : 1.0
                                        border.color: pageRoot.seasonCurrentIndex === model.index 
                                                      ? FluTheme.primaryColor 
                                                      : "transparent"
                                        border.width: pageRoot.seasonCurrentIndex === model.index ? 2 : 0
                                        
                                        RowLayout {
                                            anchors.fill: parent
                                            anchors.margins: 8
                                            spacing: 8
                                            
                                            // 序号
                                            FluText {
                                                text: (model.index + 1).toString()
                                                font: pageRoot.seasonCurrentIndex === model.index 
                                                      ? FluTextStyle.Body
                                                      : FluTextStyle.Caption
                                                color: pageRoot.seasonCurrentIndex === model.index 
                                                       ? FluTheme.fontPrimaryColor
                                                       : FluTheme.fontSecondaryColor
                                                Layout.preferredWidth: 30
                                                horizontalAlignment: Text.AlignHCenter
                                                verticalAlignment: Text.AlignVCenter
                                            }
                                            
                                            // 标题
                                            FluText {
                                                Layout.fillWidth: true
                                                text: model.title || model.part || ""
                                                font: pageRoot.seasonCurrentIndex === model.index 
                                                      ? FluTextStyle.BodyStrong
                                                      : FluTextStyle.Body
                                                color: FluTheme.fontPrimaryColor
                                                elide: Text.ElideRight
                                                verticalAlignment: Text.AlignVCenter
                                            }
                                            
                                            // 时长
                                            FluText {
                                                text: model.duration > 0 ? pageRoot.formatDuration(model.duration) : ""
                                                font: FluTextStyle.Caption
                                                color: FluTheme.fontSecondaryColor
                                                verticalAlignment: Text.AlignVCenter
                                            }
                                        }
                                        
                                        MouseArea {
                                            anchors.fill: parent
                                            onClicked: {
                                                // 切换到指定分集
                                                if (pageRoot.cid !== model.cid) {
                                                    pageRoot.switchEpisode(model.aid, model.cid, model.bvid)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // ---------- 推荐视频页 ----------
                Flickable {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    contentHeight: recommendGrid.height + 16
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: FluScrollBar {}

                    Grid {
                        id: recommendGrid
                        x: Theme.spacingSmall
                        y: Theme.spacingSmall
                        width: parent.width - Theme.pageMargins * 2 - Theme.scrollBarReserve
                        columns: 1
                        spacing: Theme.spacingMedium
                        rowSpacing: Theme.spacingMedium

                        Repeater {
                            model: pageRoot.recommendModel

                            VideoCard {
                                width: parent.width
                                bvid: model.bvid
                                title: model.title
                                cover: model.cover
                                author: model.author
                                views: model.views
                                danmakus: model.danmakus
                                duration: model.duration
                                pubDate: model.pubDate
                                badgeText: model.badgeText || ""
                                // 番剧推荐卡片专用
                                isBangumiCard: !!model.isBangumiCard
                                score: model.score || 0
                                followCount: model.followCount || ""
                                updateInfo: model.updateInfo || ""
                                seasonId: model.seasonId || ""
                                epId: model.epId || ""
                                // 去掉旧的外层 MouseArea（点击事件已内置在 VideoCard 内，会根据 isBangumiCard 自动切换 App.openVideo / App.openBangumi）
                            }
                        }
                    }
                }

                // ---------- UP主投稿页 ----------
                Flickable {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    contentHeight: upVideoColumn.height + 16
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: FluScrollBar {}

                    Column {
                        id: upVideoColumn
                        x: Theme.spacingSmall
                        y: Theme.spacingSmall
                        width: parent.width - Theme.pageMargins * 2 - Theme.scrollBarReserve
                        spacing: Theme.spacingMedium

                        Grid {
                            id: upVideoGrid
                            width: parent.width
                            columns: 1
                            spacing: Theme.spacingMedium
                            rowSpacing: Theme.spacingMedium

                            Repeater {
                                model: pageRoot.uploadModel

                                VideoCard {
                                    width: parent.width
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
                        }

                        FluPaginationNoArrow {
                            width: parent.width
                            visible: pageRoot.uploadTotalPages > 1
                            useTotalPages: true
                            totalPages: pageRoot.uploadTotalPages
                            pageSize: 20
                            pageCurrent: pageRoot.uploadPage
                            onRequestPage: function (page, count) {
                                pageRoot.loadUploadsPage(page, count)
                            }
                        }
                    }
                }
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        onClicked: (mouse) => {
            // 全屏状态下：右键先退出全屏（符合常见播放器交互预期），再右键才关闭页面
            if (pageRoot.isFullScreen) {
                pageRoot.isFullScreen = false
                mouse.accepted = true
                return
            }
            closePopups()
            App.closeVideo()
        }
    }

    // 评论图片全屏预览
    Rectangle {
        id: commentImagePreviewOverlay
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.9)
        visible: pageRoot.commentImagePreviewVisible
        z: 100

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: (mouse) => {
                pageRoot.closeCommentImagePreview()
                mouse.accepted = true
            }
        }

        ImageViewer {
            id: previewImageViewer
            anchors.centerIn: parent
            width: parent.width - 80
            height: parent.height - 80
            source: pageRoot.previewCurrentImageSource()
            animated: pageRoot.previewCurrentImageIsAnimated()
        }

        // 关闭按钮
        Rectangle {
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: 16
            width: 40
            height: 40
            radius: 20
            color: Qt.rgba(1, 1, 1, 0.15)

            Text {
                anchors.centerIn: parent
                text: "×"
                color: "white"
                font.pixelSize: 24
            }

            MouseArea {
                anchors.fill: parent
                onClicked: pageRoot.closeCommentImagePreview()
            }
        }

        // 左切换按钮
        Rectangle {
            visible: pageRoot.commentPicCount(pageRoot.commentPreviewImages) > 1
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 16
            width: 44
            height: 44
            radius: 22
            color: Qt.rgba(1, 1, 1, 0.15)

            Text {
                anchors.centerIn: parent
                text: "‹"
                color: "white"
                font.pixelSize: 28
            }

            MouseArea {
                anchors.fill: parent
                onClicked: pageRoot.previewPrevImage()
            }
        }

        // 右切换按钮
        Rectangle {
            visible: pageRoot.commentPicCount(pageRoot.commentPreviewImages) > 1
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.rightMargin: 16
            width: 44
            height: 44
            radius: 22
            color: Qt.rgba(1, 1, 1, 0.15)

            Text {
                anchors.centerIn: parent
                text: "›"
                color: "white"
                font.pixelSize: 28
            }

            MouseArea {
                anchors.fill: parent
                onClicked: pageRoot.previewNextImage()
            }
        }

        // 图片计数
        Text {
            visible: pageRoot.commentPicCount(pageRoot.commentPreviewImages) > 1
            anchors.bottom: parent.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottomMargin: 24
            text: (pageRoot.commentPreviewIndex + 1) + " / " + pageRoot.commentPicCount(pageRoot.commentPreviewImages)
            color: "white"
            font.pixelSize: 14
        }
    }

    // ========== 小窗播放 UI 层（单窗口变身方案）==========
    // 主窗口自身变身为置顶小窗（App.enterMiniPlayerMode），本层与播放器/
    // 弹幕层一起 reparent 到 main.qml 的 miniPlayerHost（同窗口，无渲染
    // 上下文重建）。窗口边缘 8px 由 FluFrameless 的原生 WM_NCHITTEST 提供
    // 缩放（与常规窗口边框同路径），无需自绘缩放手柄；拖动视频区移动窗口
    Item {
        id: miniUiRoot
        visible: false
        // 挂到 miniPlayerHost 后填满整个窗口；未挂载时填满页面（不可见）
        anchors.fill: parent

        // 鼠标交互：右键退出小窗、左键播放/暂停、移动唤出迷你控制栏、
        // 按住拖动移动窗口（小窗无标题栏，以拖视频区代替）
        MouseArea {
            id: miniMouseArea
            anchors.fill: parent
            z: 2
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            // 合成 hover 事件过滤：定时器把控制栏藏在静止光标下方时，Qt 会向
            // 重新成为悬停目标的本区域合成一条坐标不变的 hover 移动事件。
            // 不过滤会形成"定时器隐藏→合成事件立即唤出→3s 再隐藏"的循环，
            // 表现为控制栏常亮不隐藏。真实移动坐标必然变化，同坐标事件对
            // 活动检测无意义，直接忽略。（主窗口控制栏是点击切换模式，
            // 移动不唤出，故无此问题）
            property point _lastHoverPos: Qt.point(-99999, -99999)
            // 拖动移动窗口（系统原生）：左键按住位移超过 4px 判定为拖拽，
            // 交给系统原生移动循环（startSystemMove → SC_MOVE 模态循环）。
            // 判定按住的按键必须用 mouse.buttons（复数）——move 事件中
            // mouse.button 恒为 NoButton（只在 press/release/click 有效），
            // 上一版误用 mouse.button 导致判定永不成立：窗口拖不动、
            // 松手还触发播放/暂停。
            // 系统模态循环会吞掉后续 move/release 事件（Qt 不再收到释放）：
            // 拖动后 _winDragging 保持 true 至下次 onPressed 复位；
            // 若 release 意外送达触发 click，也由 _winDragging 拦截
            property bool _winDragging: false
            property point _pressItem
            onPressed: (mouse) => {
                _pressItem = Qt.point(mouse.x, mouse.y)
                _winDragging = false
            }
            onPositionChanged: (mouse) => {
                if (pressed && !_winDragging
                    && (mouse.buttons & Qt.LeftButton)
                    && (Math.abs(mouse.x - _pressItem.x) > 4
                        || Math.abs(mouse.y - _pressItem.y) > 4)) {
                    _winDragging = true
                    App.startSystemMove()
                }
                if (_winDragging)
                    return
                if (mouse.x === _lastHoverPos.x && mouse.y === _lastHoverPos.y)
                    return
                _lastHoverPos = Qt.point(mouse.x, mouse.y)
                pageRoot.playerMouseActivity()   // 复用指针自动隐藏逻辑
                miniControlBar.visible = true
                miniHideTimer.restart()
            }
            onCanceled: _winDragging = false
            onExited: {
                _lastHoverPos = Qt.point(-99999, -99999)   // 离窗重置：重进首事件必坐标不同
                pageRoot.cursorHidden = false
                hideCursorTimer.stop()
                // 不在此隐藏控制栏：控制栏出现在光标下方时其 MouseArea（z 更高）
                // 会抢占悬停并触发本 handler，立即隐藏会与"移动唤出"形成
                // 可见性闪烁循环。与主窗口播放区 onExited 模式一致：控制栏
                // 只由 miniHideTimer 3 秒静止超时隐藏。
            }
            onClicked: (mouse) => {
                if (_winDragging) {   // 拖拽收尾：吞掉点击，不触发播放/暂停
                    _winDragging = false
                    return
                }
                if (mouse.button === Qt.RightButton) {
                    pageRoot.exitMiniWindow()
                } else {
                    pageRoot.miniTogglePlay()
                }
            }
        }

        Timer {
            id: miniHideTimer
            interval: 3000
            // 无条件隐藏（原语义）：3 秒静止后隐藏。恢复需要真实鼠标移动
            // （同坐标合成事件已被 miniMouseArea 过滤，不会立即唤出）
            onTriggered: miniControlBar.visible = false
        }

        // 迷你控制栏：播放/暂停 + 进度 + 退出小窗（悬停/移动时显示）
        Rectangle {
            id: miniControlBar
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 40
            z: 3
            visible: false
            color: "#B3000000"

            // 悬停在控制栏上时保持显示
            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton
                onPositionChanged: {
                    pageRoot.playerMouseActivity()
                    miniHideTimer.restart()
                }
            }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                spacing: 6

                FluIconButton {
                    iconSource: mpvPlayer.playing ? FluentIcons.Pause : FluentIcons.Play
                    iconSize: 16
                    iconColor: "#FFFFFF"
                    onClicked: pageRoot.miniTogglePlay()
                }

                FluSlider {
                    id: miniSlider
                    Layout.fillWidth: true
                    from: 0
                    to: mpvPlayer.duration > 0 ? mpvPlayer.duration : (pageRoot.videoDuration > 0 ? pageRoot.videoDuration * 1000 : 1)
                    value: mpvPlayer.position
                    text: pageRoot.formatDuration(Math.floor(value / 1000))
                    onMoved: mpvPlayer.seek(value)
                }

                FluText {
                    text: pageRoot.formatDuration(Math.floor(mpvPlayer.position / 1000))
                          + " / "
                          + pageRoot.formatDuration(mpvPlayer.duration > 0 ? Math.floor(mpvPlayer.duration / 1000)
                                : (pageRoot.videoDuration > 0 ? pageRoot.videoDuration : 0))
                    color: "#FFFFFF"
                    font.pixelSize: 11
                    Layout.alignment: Qt.AlignVCenter
                }

                // 退出小窗（图标与主控制栏小窗键一致）
                FluIconButton {
                    iconSource: FluentIcons.ClosePane
                    iconSize: 16
                    iconColor: "#FFFFFF"
                    onClicked: pageRoot.exitMiniWindow()
                }
            }
        }
    }
}
