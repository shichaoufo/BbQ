import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import QtQuick.Window 2.15

import FluentUI 1.0
import BiliQt 1.0

Rectangle {
    id: root
    color: "black"
    radius: Theme.radiusSmall
    antialiasing: true
    clip: true

    property string roomId: ""
    property string streamTitle: ""
    property string streamer: ""
    property string cover: ""
    property string face: ""
    property string mid: ""
    property int onlineCount: 0
    property int liveStatus: 0
    property bool isFollowing: false
    property string currentQuality: "原画"
    property int currentQn: 10000
    // 可用画质列表（来自 API）
    property var qualityList: []
    // 可用播放地址（来自 API，按 codec/format 分组后的首选）
    property string streamUrl: ""
    property var streamUrlCandidates: []
    property int currentCandidateIndex: 0
    property bool loadingStream: false

    property real volume: 1.0
    property bool danmakuEnabled: true
    property real danmakuSize: 1.0
    property real danmakuOpacity: 1.0
    property int danmakuRangeIndex: 3 // 0=1/4屏, 1=半屏, 2=3/4屏, 3=全屏
    property int danmakuSpeedIndex: 1 // 0=慢, 1=中, 2=快
    property int danmakuOutlineStyle: 0 // 描边样式：0=描边 1=重墨 2=45°投影（与视频页共用三档）

    // 弹幕速度倍率映射：0=慢(0.7x), 1=中(1.0x), 2=快(1.4x)
    function _danmakuSpeedScale(idx) { return [0.7, 1.0, 1.4][idx] || 1.0 }

    property bool controlsVisible: false
    property bool cursorHidden: false   // 鼠标在播放区静止3秒后自动隐藏指针
    // 指针隐藏走应用级 override cursor（App.setPlayerCursorHidden）：
    // MouseArea.cursorShape 依赖叠层光标解析，静止鼠标下叠层/visible
    // 变化时窗口光标不会重新求值，会出现指针残留不隐藏的问题
    onCursorHiddenChanged: App.setPlayerCursorHidden(cursorHidden)
    property bool isMiniWindow: false   // 小窗播放：播放器迁入独立置顶窗口，主窗口隐藏
    property bool loadFailed: false
    property string loadErrorMsg: ""

    // 弹幕管理器由外部注入（LivePage 层级共享实例），不随 LivePlayerPage 销毁/重建。
    // 避免 QWebSocket（SSL 握手线程）频繁创建/销毁导致卡死。
    property var danmakuManager: null
    
    // 加载状态跟踪
    property int loadRetryCount: 0
    property int maxLoadRetries: 3
    property bool _waitingForVideo: false
    property bool _wasPlaying: false
    property real _loadStartTime: 0
    property bool _loadingInProgress: false  // 防止重复调用 loadStream
    property int _loadGeneration: 0  // 每次 loadStream/stopPlayer 递增，用于丢弃过期的异步 API 响应
    property int _danmuReqGen: -1    // 发起 getLiveDanmuInfo 时记录的代次，响应到达时比对，丢弃过期响应
    property bool _stopped: false  // stopPlayer 防重入标志，避免多次调用导致 savePlayerSettings 重复执行
    property bool _everLoaded: false  // 标记是否曾加载过流，防止未使用的实例保存默认值覆盖用户设置
    property bool _fullReloadAttempted: false  // 完整重载兜底标志：所有线路失败后重新调 API 一次，避免无限重试

    // 实际播放的视频参数（来自 mpv，用于验证当前流的真实画质）
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
    property bool showVideoInfo: false

    signal closeRequested()
    signal reloadRequested()
    signal qualityChanged(string quality)

    function closePopups() {
        if (volumePopup.opened) volumePopup.close()
        if (danmakuPopup.opened) danmakuPopup.close()
    }

    // 自动隐藏豁免：鼠标悬停在控制栏区域内，或任一弹出面板/菜单
    //（音量、弹幕设置、画质菜单，含面板内的下拉框）打开时，
    // 控制栏与鼠标指针均不进入自动隐藏
    function controlOverlayActive() {
        return controlBarHover.hovered
            || volumePopup.opened || danmakuPopup.opened
            || qualityMenu.opened
    }

    function showControls() {
        root.controlsVisible = true
        root.cursorHidden = false
        hideControlsTimer.restart()
        hideCursorTimer.restart()
    }

    function toggleControls() {
        if (root.controlsVisible) {
            root.controlsVisible = false
            closePopups()
            hideCursorTimer.restart()   // 指针再静止3秒后隐藏
        } else {
            root.showControls()
        }
    }

    // 播放区任意鼠标活动：恢复指针并重置自动隐藏计时器
    function playerMouseActivity() {
        if (root.cursorHidden) root.cursorHidden = false
        hideCursorTimer.restart()
        if (root.controlsVisible) hideControlsTimer.restart()
    }

    // ========== 小窗播放（单窗口变身方案，与视频页同方案）==========
    // 主窗口自身变身为置顶小窗（App.enterMiniPlayerMode 调整几何/最小尺寸/
    // 置顶/圆角），播放器与弹幕层 reparent 到 main.qml 的 miniPlayerHost。
    // 同一窗口内 reparent：无渲染上下文/场景图/视频链重建——对播放器只是
    // 一次尺寸变化，直播流与弹幕接收完全不中断，音画天然同步
    //（旧跨窗口迁移方案的"迁移暂停+视频链重建恢复"机制已随之移除）。
    function enterMiniWindow() {
        if (root.isMiniWindow) return
        if (mpvPlayer.source === "" && !mpvPlayer.hasVideo) return   // 无流时不进小窗
        closePopups()
        root.controlsVisible = false
        root.cursorHidden = false
        hideControlsTimer.stop()
        hideCursorTimer.stop()

        // 小窗初始尺寸：按实际流宽高比（未知时 16:9），基准宽 480
        var vw = root.actualWidth > 0 ? root.actualWidth : 16
        var vh = root.actualHeight > 0 ? root.actualHeight : 9
        var w = 480
        var h = Math.max(120, Math.round(w * vh / vw))

        // 宿主层防护：host 为空时 reparent 会把播放器挂到无窗口父项，
        // mpv itemChange 将误判"彻底离开场景"走销毁分支（白屏无声）
        if (!App.miniPlayerHost) {
            console.warn("[MiniPlayer][Diag] live host is null, refusing mini mode")
            return
        }

        // 主窗口变身（C++ 完成：几何收缩/屏幕居中/置顶/圆角；信号同步触发
        // main.qml 隐藏导航与页面栈、显示宿主层）
        App.enterMiniPlayerMode(w, h)
        if (!App.miniPlayerMode) return   // 变身失败（无主窗口等），保持原状

        root.isMiniWindow = true
        // 进小窗主动清掉 SC 横幅与未消费队列：banner 挂在主窗口 Overlay 上，
        // 不随播放器 reparent，窗口收缩后会飘在错误位置（onSuperChatReceived
        // 对小窗期间的 SC 直接 return，这里的清理只兜底"进小窗前已在显示"的）
        root._scQueue = []
        try { scInfoBar.clearAllInfo() } catch (e) {}
        // 同窗口 reparent：迷你 UI 层挂到宿主，播放器与弹幕层挂到迷你 UI 层。
        // anchors.fill: parent 绑定自动重新求值，各项填满新父级
        miniUiRoot.parent = App.miniPlayerHost
        miniUiRoot.visible = true
        mpvPlayer.parent = miniUiRoot
        danmakuOverlay.parent = miniUiRoot
        mpvPlayer.z = 0
        danmakuOverlay.z = 1
    }

    function exitMiniWindow() {
        if (!root.isMiniWindow) return
        // C++ 退出变身：miniPlayerModeChanged(false) 同步触发本页
        // _restoreFromMini（reparent 回页面布局）与 main.qml 恢复常规 UI，
        // 随后恢复窗口几何/最小尺寸/状态/置顶
        App.exitMiniPlayerMode()
    }

    // 小窗模式恢复：播放器与弹幕层挂回 playerLayer（root 的第一个子项，
    // 专用底层容器，叠层由声明位置保证）。任何退出路径（本页按钮/右键/
    // Esc/窗口关闭/页面销毁）都经 miniPlayerModeChanged 到这里
    function _restoreFromMini() {
        if (!root.isMiniWindow) return
        root.isMiniWindow = false
        mpvPlayer.parent = playerLayer
        danmakuOverlay.parent = playerLayer
        mpvPlayer.z = 0
        danmakuOverlay.z = 0
        miniUiRoot.visible = false
        miniUiRoot.parent = root
        miniControlBar.visible = false
        root.cursorHidden = false
    }

    // 小窗内暂停/恢复直播（直播无进度条，仅暂停恢复）
    function miniTogglePlay() {
        if (mpvPlayer.playing) {
            mpvPlayer.pause()
        } else if (mpvPlayer.source !== "") {
            mpvPlayer.play()
        }
    }

    function formatOnline(num) {
        var n = parseInt(num, 10) || 0
        if (n >= 100000000) return (n / 100000000).toFixed(1) + "亿"
        if (n >= 10000) return (n / 10000).toFixed(1) + "万"
        return String(n)
    }

    // 解析直播流地址，返回所有候选线路/协议 URL，供失败时自动切换
    function parseStreamUrls(playUrlInfo) {
        try {
            var dataStr = typeof playUrlInfo === "string" ? playUrlInfo : playUrlInfo.toString()
            var resp = JSON.parse(dataStr)
            if (resp.code !== 0 || !resp.data) {
                console.warn("[LivePlayerPage] playUrl API error, code:", resp.code)
                return null
            }
            var result = { qualities: [], candidates: [], qn: root.currentQn }

            var playurlInfo = resp.data.playurl_info || resp.data
            if (playurlInfo && playurlInfo.playurl) {
                var playurl = playurlInfo.playurl

                // current_qn：API 实际返回的清晰度（可能与请求的 qn 不同，如未登录时请求原画会返回超清）
                var actualQn = playurl.current_qn || 0
                // 未登录时 B站直播最高清晰度为超清(qn=250)，API 不返回 current_qn（为0），
                // 但实际播放的是超清流。若请求 qn > 250 且未登录，实际清晰度应为 250。
                if (actualQn === 0 && !Login.isLoggedIn && root.currentQn > 250) {
                    actualQn = 250
                }
                if (actualQn > 0 && actualQn !== root.currentQn) {
                    result.qn = actualQn
                }

                // 画质列表 - v2 接口字段为 g_qn_desc
                var qDesc = playurl.g_qn_desc || playurl.quality_description || []
                for (var qi = 0; qi < qDesc.length; qi++) {
                    var qItem = qDesc[qi]
                    var qn = qItem.qn || 0
                    var desc = qItem.desc || qItem.hdr_desc || ""
                    if (qn > 0 && desc !== "") {
                        result.qualities.push({ qn: qn, desc: desc })
                    }
                }

                var streamList = playurl.stream || []

                // 收集实际可用的 qn 列表
                var availableQns = {}
                // 先收集 avc 候选，再收集其它编码作为兜底
                var avcCandidates = []
                var fallbackCandidates = []

                for (var si = 0; si < streamList.length; si++) {
                    var stream = streamList[si]
                    var protocolName = stream.protocol_name || ""
                    var formatList = stream.format || []
                    for (var fi = 0; fi < formatList.length; fi++) {
                        var format = formatList[fi]
                        var codecList = format.codec || []
                        for (var ci = 0; ci < codecList.length; ci++) {
                            var codec = codecList[ci]
                            var acceptQn = codec.accept_qn || []
                            for (var aqi = 0; aqi < acceptQn.length; aqi++) {
                                availableQns[acceptQn[aqi]] = true
                            }

                            var baseUrl = codec.base_url || ""
                            var urlList = codec.url_info || []
                            for (var ui = 0; ui < urlList.length; ui++) {
                                var urlInfo = urlList[ui]
                                var host = urlInfo.host || ""
                                var extra = urlInfo.extra || ""
                                if (host === "") continue
                                var url = host + baseUrl + extra
                                var lineName = (protocolName ? protocolName + " " : "") + (codec.codec_name || "") + " 线路" + (ui + 1)
                                if (codec.codec_name === "avc" || codec.codec_name === "h264") {
                                    avcCandidates.push(url)
                                } else {
                                    fallbackCandidates.push(url)
                                }
                            }
                        }
                    }
                }

                result.candidates = avcCandidates.concat(fallbackCandidates)

                // 只保留实际可用的画质
                var filteredQualities = []
                for (var qi2 = 0; qi2 < result.qualities.length; qi2++) {
                    if (availableQns[result.qualities[qi2].qn]) {
                        filteredQualities.push(result.qualities[qi2])
                    }
                }
                result.qualities = filteredQualities
            }
            return result
        } catch (e) {
            console.warn("[LivePlayerPage] parse playUrl failed:", e)
            return null
        }
    }

    function playCandidate(index) {
        // 可见性守卫：播放器不可见时（已关闭/正在关闭）不加载新流，防止关闭后声音继续
        if (!root.visible) {
            return
        }
        if (!root.streamUrlCandidates || root.streamUrlCandidates.length === 0) {
            root.loadFailed = true
            root.loadErrorMsg = "没有可用播放地址"
            return
        }
        if (index < 0 || index >= root.streamUrlCandidates.length) {
            root.loadFailed = true
            root.loadErrorMsg = "所有线路均无法播放"
            return
        }
        root.currentCandidateIndex = index
        root.streamUrl = root.streamUrlCandidates[index]
        root.loadFailed = false
        root.loadErrorMsg = ""
        // setSource(newUrl) → loadFile() 内部已先发 stop 再发 loadfile replace，
        // 此处不再额外调 mpvPlayer.stop()，避免房间切换时堆积 4+ 个冗余 async stop
        // 命令导致 mpv 内部状态混乱（直播流 FLV/HLS 切换尤其敏感）。
        mpvPlayer.source = root.streamUrl
        mpvPlayer.audioSource = ""
        root._waitingForVideo = true
        root._wasPlaying = false
        root._loadStartTime = Date.now()
        loadTimeoutTimer.start()
        videoInfoTimer.start()
        // 延迟启动播放，确保源已就绪
        delayedPlayTimer.start()
    }
    
    // 延迟播放定时器 - 在源设置完成后再调用 play()
    Timer {
        id: delayedPlayTimer
        interval: 300
        repeat: false
        onTriggered: {
            // 可见性守卫 + source 非空检查：防止关闭后延迟播放仍触发 → 声音继续
            if (root.visible && mpvPlayer.source !== "") {
                mpvPlayer.play()
            } else {
            }
        }
    }

    // 统一处理加载失败：首次失败时完整重载（重新调 API 获取新 URL），再次失败才报错
    function handleLoadFailure(msg) {
        if (!root._fullReloadAttempted) {
            console.warn("[LivePlayerPage] all candidates failed, attempting full reload...")
            root._fullReloadAttempted = true
            root._loadingInProgress = false
            root.loadRetryCount = 0
            loadTimeoutTimer.stop()
            videoInfoTimer.stop()
            root.loadStream()
        } else {
            console.warn("[LivePlayerPage] full reload also failed, giving up:", msg)
            root.loadFailed = true
            root.loadErrorMsg = msg
            root._waitingForVideo = false
            root.loadRetryCount = 0
            loadTimeoutTimer.stop()
        }
    }

    function tryNextCandidate() {
        var next = root.currentCandidateIndex + 1
        if (next < root.streamUrlCandidates.length) {
            playCandidate(next)
        } else {
            root.handleLoadFailure("所有线路均无法播放")
        }
    }

    function loadStream() {
        if (!root.roomId || root.roomId === "") return
        if (root._loadingInProgress) {
            return
        }
        // 停止弹幕延迟加载定时器：避免上一房间的 timer 过期触发，请求错误房间的弹幕
        danmuLoadTimer.stop()
        // 每次加载直播流前，从 Settings 重新读取弹幕设置。
        // loadStream() 每次打开直播都会调用（经 onRoomIdChanged 触发），是最可靠的设置同步点。
        try { loadPlayerSettings() } catch (e) {}
        root._stopped = false  // 重置 stopPlayer 防重入标志，允许后续 stopPlayer 再次执行
        root._everLoaded = true  // 标记已加载过流，允许后续 savePlayerSettings 保存设置
        root._loadingInProgress = true
        root._loadGeneration++  // 递增代次，使之前所有 pending 的异步 API 响应作废
        root.loadingStream = true
        root.loadFailed = false
        root.loadErrorMsg = ""
        root.loadRetryCount = 0
        root.streamUrlCandidates = []
        root.currentCandidateIndex = 0
        root.streamUrl = ""
        root._waitingForVideo = false
        root._wasPlaying = false
        // setSource("") 内部会调 stop() + stopRenderTimer()，无需额外调 mpvPlayer.stop()
        mpvPlayer.source = ""
        loadTimeoutTimer.stop()
        Api.reportLiveHistory(root.roomId)
        Api.getLiveStreamInfo(root.roomId, root.currentQn)
        Api.getLiveRoomInfo(root.roomId)
        // 弹幕加载移至 onHasVideoChanged（视频加载成功后延迟 1s），
        // 避免快速切换时频繁创建/关闭 WebSocket，减少 SSL 竞争导致的卡死。
        // 快速浏览直播间时，停留不足 1s 的房间不会发起弹幕连接。
    }

    function parseDanmuInfo(data) {
        // 代次检查：发起 getLiveDanmuInfo 时记录的代次若与当前不一致，
        // 说明期间发生了 loadStream/stopPlayer，此响应过期，丢弃。
        // （原 respGen 方案无效：QML 单线程，同步解析期间 _loadGeneration 不可能变化）
        if (root._danmuReqGen !== root._loadGeneration) return
        try {
            var dataStr = typeof data === "string" ? data : data.toString()
            var resp = JSON.parse(dataStr)
            var token = ""
            var host = ""
            var port = 0

            if (resp.code === 0 && resp.data) {
                token = resp.data.token || ""
                var hostList = resp.data.host_list || []
                if (hostList.length > 0) {
                    var h = hostList[hostList.length - 1]
                    host = h.host || ""
                    port = h.wss_port || h.ws_port || h.port || 0
                }
            }

            if (host && port > 0 && root.danmakuManager) {
                if (root.danmakuManager.isConnected()) {
                    root.danmakuManager.disconnectRoom()
                }
                root.danmakuManager.setDanmakuInfo(host, port, token)
                root.danmakuManager.connectRoom(parseInt(root.roomId, 10))
            }
        } catch (e) {
            console.warn("[LivePlayerPage] parse danmuInfo failed:", e)
        }
    }

    onRoomIdChanged: {
        // 切换直播间时，彻底清理上一个直播的状态
        // 1. 关闭所有弹出面板（音量、弹幕设置等），保证新直播是干净的初始状态
        closePopups()
        // 2. 重置控件可见性
        root.controlsVisible = false
        root.cursorHidden = false
        hideControlsTimer.stop()
        hideCursorTimer.stop()
        // 3. 断开旧的弹幕连接并清空残留弹幕
        if (root.danmakuManager) root.danmakuManager.disconnectRoom()
        danmakuOverlay.clear()
        root._scQueue = []  // 清空未消费的 SuperChat 队列
        // 4. 重置视频信息和加载状态
        root.loadFailed = false
        root.loadErrorMsg = ""
        root._fullReloadAttempted = false  // 新房间，重置完整重载标志
        root.actualWidth = 0
        root.actualHeight = 0
        root.showVideoInfo = false
        root._waitingForVideo = false
        root._wasPlaying = false
        root.loadRetryCount = 0
        root._loadingInProgress = false
        loadTimeoutTimer.stop()
        delayedPlayTimer.stop()
        videoInfoTimer.stop()
        // 5. 重置关注状态（新直播间需要重新获取）
        root.mid = ""
        root.isFollowing = false

        if (root.roomId !== "") {
            loadStream()
        }
    }

    Component.onCompleted: {
        loadPlayerSettings()
        hideControlsTimer.start()
        // 不在此处调用 loadStream()！
        // 因为此时 liveOverlay.liveRoomId 可能还是旧房间号（openLiveAnim.onStopped 还没执行），
        // 会导致为旧房间发起 API 请求，与新房间的 loadStream 竞争 → 旧流 URL 覆盖新流 → 关闭后声音继续。
        // 流的加载统一由 openLiveAnim.onStopped → onRoomIdChanged → loadStream() 或手动 loadStream() 处理。
    }

    // 加载直播播放器设置（与视频分别保存）
    function loadPlayerSettings() {
        root.volume = Settings.getReal("live/volume", 1.0)
        root.danmakuEnabled = Settings.getBool("live/danmaku/enabled", true)
        root.danmakuSize = Settings.getReal("live/danmaku/size", 1.0)
        root.danmakuOpacity = Settings.getReal("live/danmaku/opacity", 1.0)
        root.danmakuRangeIndex = Settings.getInt("live/danmaku/rangeIndex", 3)
        root.danmakuSpeedIndex = Settings.getInt("live/danmaku/speedIndex", 1)
        root.danmakuOutlineStyle = Settings.getInt("live/danmaku/outlineStyle", 0)
    }

    function savePlayerSettings() {
        // 防止未使用过的实例（如刚创建尚未 loadStream 的 LivePlayerPage）保存默认值覆盖用户设置
        if (!root._everLoaded) return
        Settings.setReal("live/volume", root.volume)
        Settings.setBool("live/danmaku/enabled", root.danmakuEnabled)
        Settings.setReal("live/danmaku/size", root.danmakuSize)
        Settings.setReal("live/danmaku/opacity", root.danmakuOpacity)
        Settings.setInt("live/danmaku/rangeIndex", root.danmakuRangeIndex)
        Settings.setInt("live/danmaku/speedIndex", root.danmakuSpeedIndex)
        Settings.setInt("live/danmaku/outlineStyle", root.danmakuOutlineStyle)
    }

    // 供外部在卸载前主动停止播放，避免延迟销毁期间仍有声音输出
    // 注意：必须在 "LivePlayerPage 子对象还活着" 时调用（在 Loader._playerCreated=false 之前）
    // 否则 danmakuOverlay 可能已被 QML 先析构，访问就是 use-after-free 崩溃。
    function stopPlayer() {
        // 防重入：stopPlayer 可能被 onVisibleChanged、closeLivePlayer、Component.onDestruction 等多个路径调用，
        // 只执行第一次，后续调用直接返回（避免 savePlayerSettings 被调 5 次、_loadGeneration 多次递增等问题）
        if (root._stopped) return
        root._stopped = true
        // 停止弹幕延迟加载定时器：关闭直播时取消未触发的弹幕加载
        danmuLoadTimer.stop()
        // 重置加载标志：快速切换时，上一个房间的 loadStream 可能设了 _loadingInProgress=true
        // 但还未加载完成就被 stopPlayer 中断，若不重置，下一个房间的 loadStream 会被跳过 → 黑屏
        root._loadingInProgress = false
        // 0. 先保存弹幕设置到 Settings（onVisibleChanged 在 QML 中不因父级 visible 变化而触发，
        //    所以 savePlayerSettings 必须在此处调用——stopPlayer 是所有关闭路径的必经之路）
        try { savePlayerSettings() } catch (e) {}
        // 1. 先停弹幕 tickTimer（不然 canvas 销毁后，_tick 仍在访问释放内存）
        //    访问要 try 包裹：如果 tickTimer 已因切换直播间而被异常销毁，至少别炸
        try {
            if (danmakuOverlay && danmakuOverlay._tickTimer && danmakuOverlay._tickTimer.running) {
                danmakuOverlay._tickTimer.stop()
            }
        } catch (e) {
            console.warn("[LivePlayerPage] stop tickTimer skipped:", e)
        }
        try {
            if (danmakuOverlay) danmakuOverlay.clear()
        } catch (e) {
            console.warn("[LivePlayerPage] danmakuOverlay.clear skipped:", e)
        }
        // 2. 再断开弹幕 WebSocket（其内部可能还在 pending signals，断开后 Qt 会自动取消 queued 到已销毁对象的 slot）
        try {
            if (root.danmakuManager && root.danmakuManager.isConnected()) {
                root.danmakuManager.disconnectRoom()
            }
        } catch (e) {
            console.warn("[LivePlayerPage] disconnectRoom skipped:", e)
        }
        // 2.5 清理 SuperChat：关闭直播间时立即清掉悬浮在 Overlay 上的 SC 横幅及未消费队列
        try {
            root._scQueue = []
            scInfoBar.clearAllInfo()
        } catch (e) {
            console.warn("[LivePlayerPage] clear SuperChat skipped:", e)
        }
        // 3. 最后停 mpv（保持它在弹幕断开之后也 OK）
        if (mpvPlayer.source !== "") {
            mpvPlayer.stop()
            mpvPlayer.source = ""
        }
        root._waitingForVideo = false
        root._wasPlaying = false
        root.loadRetryCount = 0
        root._fullReloadAttempted = false
        root._loadingInProgress = false
        root._loadGeneration++  // 递增代次，使所有 pending 的异步 API 响应（streamInfo/danmuInfo）作废
        loadTimeoutTimer.stop()
        delayedPlayTimer.stop()
        videoInfoTimer.stop()
    }

    Component.onDestruction: {
        // 只保存设置！
        // 其它清理（停 tickTimer、clear 弹幕、disconnectRoom、stop mpv）必须在 stopPlayer() 里先执行，
        // 因为 onDestruction 触发时，子对象（danmakuOverlay、mpvPlayer）可能已经先于 root 被销毁。
        // 在 onDestruction 里访问子对象 100% 是 use-after-free，会触发 0xc0000005 AV 崩溃。
        // 小窗模式下被销毁（外部关闭直播的兜底路径）：退出小窗模式，恢复
        // 主窗口几何与常规 UI。播放器/迷你 UI 层随本页子树由 Loader 统一
        // 销毁（不做 reparent——销毁中移动子对象会 use-after-free），
        // Connections 监听可能已失效，必须先置标志再退出，_restoreFromMini
        // 由 isMiniWindow=false 短路跳过
        if (root.isMiniWindow) {
            root.isMiniWindow = false
            App.exitMiniPlayerMode()
        }
        // 恢复被隐藏的鼠标指针（override cursor 是应用级的，不恢复会全局无指针）
        App.setPlayerCursorHidden(false)
        try { savePlayerSettings() } catch (e) {}
    }

    onVisibleChanged: {
        if (!visible) {
            // 小窗模式下页面变为不可见（外部关闭直播的兜底路径）：
            // 退出小窗模式，恢复主窗口。播放器随本页子树由 Loader 统一销毁
            if (root.isMiniWindow) {
                root.isMiniWindow = false
                App.exitMiniPlayerMode()
                return   // 后续清理由 Component.onDestruction 兜底
            }
            // 进入小窗时 pageStack.visible=false 使本页 visible 从父级"流动"
            // 为 false（Qt 语义：父项 visible 变化直接改变全部子孙的 visible
            // 值并触发 visibleChanged），非真实关闭——播放器随后 reparent 到
            // miniPlayerHost 继续播放，绝不能走下面的 stopPlayer 清理
            if (App.miniPlayerMode) return
            // 关闭直播时清理所有状态（savePlayerSettings 已在 stopPlayer 内部调用）
            closePopups()
            root.controlsVisible = false
            root.cursorHidden = false
            hideControlsTimer.stop()
            hideCursorTimer.stop()
            // 直接复用 stopPlayer：按安全顺序清理（tickTimer→clear弹幕→disconnectRoom→mpv stop）
            try {
                stopPlayer()
            } catch (e) {
                // onVisibleChanged 可能在组件部分销毁时才触发，兜底忽略
                console.warn("[LivePlayerPage] onVisibleChanged stopPlayer caught:", e)
                // 最后保底：只要 mpvPlayer 还没销毁就强行 stop
                try {
                    if (mpvPlayer.source !== "") { mpvPlayer.stop(); mpvPlayer.source = "" }
                } catch (_) {}
            }
        } else {
            // 重新可见时，从 Settings 重新读取弹幕设置（兜底，销毁策略下 Component.onCompleted 已会调用）。
            // 注意：不在此处调 loadStream()（roomId 可能还没更新，会导致旧房间流竞争问题）
            try { loadPlayerSettings() } catch (e) {
                console.warn("[LivePlayerPage] onVisibleChanged loadPlayerSettings caught:", e)
            }
        }
    }

    Timer {
        id: hideControlsTimer
        interval: 3000
        onTriggered: {
            // 豁免：悬停控制栏 / 弹出面板或菜单打开时不隐藏，继续等待
            if (controlOverlayActive()) {
                hideControlsTimer.restart()
                return
            }
            root.controlsVisible = false
            root.cursorHidden = true
        }
    }

    // 鼠标指针静止 3 秒后隐藏（控制栏可见时随控制栏一起隐藏）
    Timer {
        id: hideCursorTimer
        interval: 3000
        onTriggered: {
            if (controlOverlayActive()) {
                hideCursorTimer.restart()
                return
            }
            if (root.controlsVisible)
                hideCursorTimer.restart()
            else
                root.cursorHidden = true
        }
    }

    // 延迟获取 mpv 实际视频参数（流加载需要时间）
    Timer {
        id: videoInfoTimer
        interval: 3000
        repeat: false
        onTriggered: {
            if (!mpvPlayer.hasVideo) {
                // 还没加载出来，再等一下
                videoInfoTimer.start()
                return
            }
            var info = mpvPlayer.getVideoInfo()
            root.actualWidth = info["width"] || 0
            root.actualHeight = info["height"] || 0
            root.actualVideoCodec = info["videoCodec"] || ""
            root.actualVideoFormat = info["videoFormat"] || ""
            root.actualContainerFormat = info["containerFormat"] || ""
            root.actualFps = info["fps"] || 0
            root.actualVideoBitrate = info["videoBitrate"] || 0
            root.actualAudioBitrate = info["audioBitrate"] || 0
            root.actualAudioCodec = info["audioCodec"] || ""
            root.actualPath = info["path"] || ""
        }
    }

    Connections {
        target: Api
        function onLiveStreamInfoReceived(data) {
            // ====== 代次检查：丢弃过期的 API 响应 ======
            // loadStream() 时 _loadGeneration++，stopPlayer() 时也 _loadGeneration++。
            // 如果在 API 请求发出后、响应返回前发生了 stopPlayer 或新的 loadStream，
            // _loadGeneration 已经变了，此响应属于"旧代次"，必须丢弃。
            // 否则旧房间的流 URL 会覆盖新房间的流，或关闭后仍有流被加载 → 声音继续。
            var respGen = root._loadGeneration
            root.loadingStream = false

            // 解析响应中的 room_id，校验是否与当前 roomId 匹配
            var dataStr = typeof data === "string" ? data : data.toString()
            var respJson = null
            try { respJson = JSON.parse(dataStr) } catch (e) {}
            var respRoomId = respJson && respJson.data ? String(respJson.data.room_id || "") : ""
            if (respRoomId && respRoomId !== String(root.roomId)) {
                return
            }

            var result = root.parseStreamUrls(data)
            if (!result || !result.candidates || result.candidates.length === 0) {
                console.warn("[LivePlayerPage] no stream url found")
                root._loadingInProgress = false
                root.handleLoadFailure("未获取到直播流地址")
                return
            }
            // 二次代次检查：parseStreamUrls 可能耗时，期间可能又变了
            if (respGen !== root._loadGeneration) {
                return
            }
            root.streamUrlCandidates = result.candidates
            if (result.qualities && result.qualities.length > 0) {
                root.qualityList = result.qualities
            } else {
            }
            // 若 API 返回的 current_qn 与请求的 qn 不同（如未登录时请求原画实际返回超清），
            // 更新当前清晰度，使控制栏显示与实际播放一致
            if (result.qn && result.qn !== root.currentQn) {
                root.currentQn = result.qn
                // 从画质列表中查找对应的描述文本
                var foundDesc = ""
                for (var qIdx = 0; qIdx < root.qualityList.length; qIdx++) {
                    if (root.qualityList[qIdx].qn === result.qn) {
                        foundDesc = root.qualityList[qIdx].desc
                        break
                    }
                }
                if (foundDesc !== "") {
                    root.currentQuality = foundDesc
                }
            }
            root._loadingInProgress = false
            root.playCandidate(0)
        }
        function onLiveRoomInfoReceived(data) {
            try {
                var dataStr = typeof data === "string" ? data : data.toString()
                var resp = JSON.parse(dataStr)
                if (resp.code !== 0 || !resp.data) {
                    console.warn("[LivePlayerPage] roomInfo API error, code:", resp.code)
                    return
                }
                var info = resp.data.room_info || {}
                if (info.title) root.streamTitle = info.title
                if (info.cover) root.cover = info.cover
                if (info.online !== undefined) root.onlineCount = info.online
                if (info.live_status !== undefined) root.liveStatus = info.live_status
                var anchor = resp.data.anchor_info || {}
                if (anchor.base_info) {
                    if (anchor.base_info.uname) root.streamer = anchor.base_info.uname
                    if (anchor.base_info.face) root.face = anchor.base_info.face
                    if (anchor.base_info.mid) root.mid = String(anchor.base_info.mid)
                }
                // getInfoByRoom 的 anchor_info.base_info 不含 mid 字段，
                // 主播 uid 在 room_info.uid，取不到时回退
                if (root.mid === "" && info.uid) {
                    root.mid = String(info.uid)
                }
                
                if (root.mid !== "") {
                    InteractionManager.getUserRelation(root.mid)
                }
            } catch (e) {
                console.warn("[LivePlayerPage] parse roomInfo failed:", e)
            }
        }
        function onLiveDanmuInfoReceived(data) {
            root.parseDanmuInfo(data)
        }
        function onErrorOccurred(error) {
            console.warn("[LivePlayerPage] API error:", error)
            root.loadingStream = false
            root.loadFailed = true
            root.loadErrorMsg = error
        }
    }

    // SuperChat（醒目留言）：数据暂存队列，横幅组件创建时消费（FIFO）
    // （FluInfoBar.showCustom 动态创建组件时无法直接传参）
    property var _scQueue: []

    FluInfoBar {
        id: scInfoBar
        root: root
    }

    // SC 横幅组件：对标B站官方SC样式——上半部纯色块（头像+昵称+¥金额，background_color），
    // 下半部纯色块（留言，background_color2），两色硬分界不渐变，到期由 InfoBar 自动销毁
    Component {
        id: scBannerComponent
        Rectangle {
            id: scBanner
            // 默认占位对象；实际 SC 数据在 onCompleted 中从队列取（避免绑定内副作用）
            property var scData: ({ username: "", face: "", message: "", price: 0,
                                    bgColor: "#E17F00", bgBottomColor: "#FC6B00" })
            Component.onCompleted: {
                if (root._scQueue.length > 0) {
                    scData = root._scQueue.shift()
                }
            }
            width: 480
            // 头部区（10 + 36 + 10）+ 留言区（10 + 文本高 + 10）
            height: scHeaderRow.height + scMessageText.implicitHeight + 40
            radius: 6
            // 上半部底色
            color: scBanner.scData.bgColor !== "" ? scBanner.scData.bgColor : "#E17F00"
            FluShadow { radius: 6 }

            // 下半部：留言色块，顶边即上下分界线
            Rectangle {
                id: scBottomBlock
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: scMessageText.implicitHeight + 20
                radius: 6
                color: scBanner.scData.bgBottomColor !== "" ? scBanner.scData.bgBottomColor : "#FC6B00"
                // 补平顶部圆角：仅保留底部圆角与外框对齐
                Rectangle {
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: parent.radius
                    color: parent.color
                }
            }

            // 上半部内容：头像 + 昵称 + ¥金额（单行）
            Row {
                id: scHeaderRow
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: 10
                spacing: 10

                // 头像（圆形裁剪）
                Rectangle {
                    width: 36
                    height: 36
                    radius: 18
                    color: "transparent"
                    clip: true
                    anchors.verticalCenter: parent.verticalCenter
                    FluImage {
                        anchors.fill: parent
                        source: scBanner.scData.face !== "" ? GlobalState.fixImageUrl(scBanner.scData.face, 72, 72, true) : ""
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        cache: false
                        visible: scBanner.scData.face !== ""
                    }
                }
                FluText {
                    text: scBanner.scData.username
                    font: FluTextStyle.BodyStrong
                    color: "#4B2B00"  // 深棕黑，在SC头部浅色背景上更清晰
                    anchors.verticalCenter: parent.verticalCenter
                }
                FluText {
                    text: "¥ " + scBanner.scData.price
                    font: FluTextStyle.BodyStrong
                    color: "#FFD700"
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            // 留言正文（位于下半部色块内，最多3行超出省略）
            FluText {
                id: scMessageText
                anchors.top: scBottomBlock.top
                anchors.left: scBottomBlock.left
                anchors.right: scBottomBlock.right
                anchors.margins: 10
                text: scBanner.scData.message
                font: FluTextStyle.Body
                color: "#FFFFFF"
                wrapMode: Text.Wrap
                maximumLineCount: 3
                elide: Text.ElideRight
            }
        }
    }

    // 弹幕管理器信号处理（danmakuManager 由外部页面注入的共享实例）
    Connections {
        target: root.danmakuManager
        // 50ms 合批后的弹幕批次（C++ 侧聚合，一批仅一次信号）
        function onDanmakuBatchReceived(batch) {
            for (var i = 0; i < batch.length; i++)
                danmakuOverlay.addDanmaku(batch[i].text, batch[i].color, batch[i].type,
                                          0, batch[i].emoticonUrl || "", batch[i].emoticonSize || 1,
                                          batch[i].emoticons || [])
        }
        function onSuperChatReceived(username, face, message, price, scTime, bgColor, bgBottomColor) {
            root._scQueue.push({ username: username, face: face, message: message,
                                 price: price, bgColor: bgColor, bgBottomColor: bgBottomColor })
            scInfoBar.showCustom(scBannerComponent, scTime * 1000)
        }
        function onConnected() {
        }
        function onDisconnected() {
        }
        function onDanmakuError(errorString) {
            console.warn("[LivePlayerPage] danmaku error:", errorString)
        }
        function onRoomInfo(online, roomName) {
            if (online > 0) root.onlineCount = online
        }
    }

    // 互动管理器信号处理（关注功能）
    Connections {
        target: InteractionManager
        function onActionSuccess(action, message) {
            if (action === "follow" || action === "unfollow") {
                root.isFollowing = !root.isFollowing
            }
        }
        function onActionFailed(action, error) {
            console.warn("[LivePlayerPage] InteractionManager action failed:", action, error)
        }
        function onRelationReady(followed, attribute) {
            root.isFollowing = followed
        }
    }

    // 阻挡鼠标事件穿透到下方，左键切换控制栏，右击关闭播放页；
    // 同时跟踪鼠标：移动恢复指针，静止3秒自动隐藏
    MouseArea {
        anchors.fill: parent
        z: -1
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onPositionChanged: root.playerMouseActivity()
        // 鼠标离开播放区：恢复指针并停止计时
        onExited: {
            root.cursorHidden = false
            hideCursorTimer.stop()
        }
        onClicked: function(mouse) {
            if (mouse.button === Qt.RightButton) {
                root.closeRequested()
            } else {
                // 有弹窗打开时，先关闭弹窗
                if (volumePopup.opened || danmakuPopup.opened) {
                    closePopups()
                } else {
                    root.toggleControls()
                }
            }
        }
    }

    // 小窗往返的 reparent 挂载点：reparent 会把项追加到目标容器子项列表
    // 末尾，直接挂回 root 会把播放器排到控制栏/弹窗等兄弟层之后（视频盖
    // 住控制栏）；挂回这个专用底层容器后叠层关系与初始声明完全一致
    Item {
        id: playerLayer
        anchors.fill: parent
    }

    // 直播播放器
    MpvObject {
        id: mpvPlayer
        anchors.fill: parent
        liveMode: true  // 直播模式：小cache低延迟（5s/8M），覆盖视频默认的大cache配置
        volume: root.volume
        onPlayingChanged: {
            // 检测异常停止：之前在播放，现在停止了，但还没有视频
            if (!playing && root._wasPlaying && root._waitingForVideo && !hasVideo) {
                console.warn("[LivePlayerPage] mpv stopped unexpectedly without video, retrying...")
                root.loadRetryCount++
                if (root.loadRetryCount >= root.maxLoadRetries) {
                    root.handleLoadFailure("播放失败，请点击重新加载")
                } else {
                    root.tryNextCandidate()
                }
            }
            root._wasPlaying = playing
        }
        onErrorOccurred: {
            console.warn("[LivePlayerPage] mpv error:", error)
            root.loadRetryCount++
            if (root.loadRetryCount >= root.maxLoadRetries) {
                root.handleLoadFailure(error)
            } else {
                root.tryNextCandidate()
            }
        }
        onHasVideoChanged: {
            if (hasVideo) {
                // 视频加载成功
                root._waitingForVideo = false
                root.loadRetryCount = 0
                loadTimeoutTimer.stop()
                // 确保视频自动播放（处理 hasVideo: true 但 playing: false 的情况）
                if (!playing) {
                    mpvPlayer.play()
                }
                // 视频加载成功后延迟 1s 再加载弹幕：
                // 1. 错开 D3D11 硬解初始化与 SSL 握手的资源竞争
                // 2. 快速切换直播间时，停留不足 1s 的房间不发起弹幕连接，减少 WebSocket churn
                // stopPlayer/loadStream 会停止此 timer，避免过期触发
                danmuLoadTimer.stop()
                danmuLoadTimer.start()
            }
        }
    }

    // 弹幕延迟加载定时器：视频加载成功后 1s 触发 getLiveDanmuInfo
    Timer {
        id: danmuLoadTimer
        interval: 1000
        repeat: false
        onTriggered: {
            // 记录发起请求时的代次，parseDanmuInfo 响应到达时比对，
            // 若期间发生 loadStream/stopPlayer（_loadGeneration 递增），响应会被丢弃
            root._danmuReqGen = root._loadGeneration
            Api.getLiveDanmuInfo(root.roomId)
        }
    }
    
    // 加载超时定时器 - 检测视频是否在规定时间内加载完成
    Timer {
        id: loadTimeoutTimer
        interval: 8000  // 8秒超时
        repeat: false
        onTriggered: {
            if (root._waitingForVideo && !mpvPlayer.hasVideo) {
                console.warn("[LivePlayerPage] load timeout, retrying... attempt:", root.loadRetryCount + 1)
                root.loadRetryCount++
                if (root.loadRetryCount >= root.maxLoadRetries) {
                    root.handleLoadFailure("加载超时，请点击重新加载")
                } else {
                    root.tryNextCandidate()
                }
            }
        }
    }

    // 直播弹幕管理器（WebSocket 连接 B 站弹幕服务器）
    // 弹幕管理器由外部注入（LivePage 层级共享实例），此处不再创建。

    // 弹幕显示浮层（覆盖在视频上方，鼠标事件穿透）
    DanmakuOverlay {
        id: danmakuOverlay
        anchors.fill: parent
        danmakuEnabled: root.danmakuEnabled
        opacityValue: root.danmakuOpacity
        fontSizeScale: root.danmakuSize
        outlineStyle: root.danmakuOutlineStyle
        speedScale: root._danmakuSpeedScale(root.danmakuSpeedIndex)
        // 显示范围：弹幕从顶部开始向下排列，范围越小底部空出越多
        // 0=1/4屏, 1=半屏, 2=3/4屏, 3=全屏
        displayAreaRatio: [0.25, 0.5, 0.75, 1.0][root.danmakuRangeIndex] || 1.0
        areaOffsetRatio: 0.0


    }

    // 直播封面占位（流加载前显示）
    FluImage {
        anchors.fill: parent
        source: GlobalState.fixImageUrl(root.cover,
                                       parent.width * Screen.devicePixelRatio,
                                       parent.height * Screen.devicePixelRatio,
                                       true)
        fillMode: Image.PreserveAspectCrop
        visible: !mpvPlayer.hasVideo && root.cover !== "" && !root.loadFailed
        asynchronous: true
        cache: false
        sourceSize: Qt.size(parent.width * Screen.devicePixelRatio,
                            parent.height * Screen.devicePixelRatio)
    }

    // 加载中提示
    Column {
        anchors.centerIn: parent
        spacing: 12
        visible: root.loadingStream && !mpvPlayer.hasVideo && !root.loadFailed

        FluProgressRing {
            anchors.horizontalCenter: parent.horizontalCenter
        }

        FluText {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "正在加载直播流..."
            color: "#FFFFFF"
            font: FluTextStyle.Body
        }
    }

    // 加载失败提示
    Column {
        anchors.centerIn: parent
        spacing: 12
        visible: root.loadFailed

        FluIcon {
            anchors.horizontalCenter: parent.horizontalCenter
            iconSource: FluentIcons.Error
            iconSize: 48
            color: "#FF4444"
        }

        FluText {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "直播加载失败"
            color: "#FFFFFF"
            font: FluTextStyle.Body
        }

        FluText {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.loadErrorMsg
            color: "#AAAAAA"
            font: FluTextStyle.Caption
            visible: root.loadErrorMsg !== ""
        }

        FluButton {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "重新加载"
            onClicked: root.loadStream()
        }
    }

    // 视频信息浮层（用于验证实际播放画质）
    Rectangle {
        id: videoInfoPanel
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Theme.spacingMedium
        width: infoColumn.width + 24
        height: infoColumn.height + 24
        color: "#E6000000"
        radius: 6
        visible: root.showVideoInfo
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
                width: infoColumn.width
                height: 1
                color: "#444444"
            }

            FluText {
                text: "请求清晰度: qn=" + root.currentQn + " (" + root.currentQuality + ")"
                font: FluTextStyle.Caption
                color: "#FFD700"
            }

            FluText {
                text: "分辨率: " + root.actualWidth + " x " + root.actualHeight
                font: FluTextStyle.Caption
                color: "#FFFFFF"
                visible: root.actualWidth > 0
            }

            FluText {
                text: "视频编码: " + (root.actualVideoCodec || "未知")
                font: FluTextStyle.Caption
                color: "#FFFFFF"
            }

            FluText {
                text: "视频格式: " + (root.actualVideoFormat || "未知")
                font: FluTextStyle.Caption
                color: "#FFFFFF"
            }

            FluText {
                text: "容器格式: " + (root.actualContainerFormat || "未知")
                font: FluTextStyle.Caption
                color: "#FFFFFF"
            }

            FluText {
                text: "帧率: " + (root.actualFps > 0 ? root.actualFps.toFixed(2) + " fps" : "未知")
                font: FluTextStyle.Caption
                color: "#FFFFFF"
            }

            FluText {
                text: "视频码率: " + (root.actualVideoBitrate > 0 ? Math.round(root.actualVideoBitrate) + " kbps" : "未知")
                font: FluTextStyle.Caption
                color: "#FFFFFF"
            }

            FluText {
                text: "音频编码: " + (root.actualAudioCodec || "未知")
                font: FluTextStyle.Caption
                color: "#FFFFFF"
            }

            FluText {
                text: "音频码率: " + (root.actualAudioBitrate > 0 ? Math.round(root.actualAudioBitrate) + " kbps" : "未知")
                font: FluTextStyle.Caption
                color: "#FFFFFF"
            }

            Rectangle {
                width: infoColumn.width
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
                text: root.actualPath
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
            onPositionChanged: root.playerMouseActivity()
        }
    }

    // 顶部渐变阴影 + 直播标题
    // 阴影高度独立于文字区：文字区之下再延伸 110px，为渐变提供足够的
    // 竖直空间展开。渐变 alpha 严格线性衰减（0.8 → 0，每 10% 一档）：
    // 白背景下人眼感知的是灰度（1-alpha），线性 alpha 即均匀的灰度坡，
    // 中段不额外压暗、尾段不加速，避免渐变被读成一块边界清晰的"条带"
    Rectangle {
        id: topBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: titleColumn.height + Theme.spacingMedium * 2 + 110
        gradient: Gradient {
            GradientStop { position: 0.00; color: "#CC000000" }
            GradientStop { position: 0.10; color: "#B8000000" }
            GradientStop { position: 0.20; color: "#A3000000" }
            GradientStop { position: 0.30; color: "#8F000000" }
            GradientStop { position: 0.40; color: "#7A000000" }
            GradientStop { position: 0.50; color: "#66000000" }
            GradientStop { position: 0.60; color: "#52000000" }
            GradientStop { position: 0.70; color: "#3D000000" }
            GradientStop { position: 0.80; color: "#29000000" }
            GradientStop { position: 0.90; color: "#14000000" }
            GradientStop { position: 1.00; color: "#00000000" }
        }
        opacity: root.controlsVisible ? 1 : 0
        // 不能直接绑 controlsVisible：enabled 瞬间翻false会立刻抽掉按钮的
        // 阴影/描边（FluControlBackground 依赖 enabled），在淡出动画中途
        // 突变产生残影。改为跟随 opacity：淡出全程保持 enabled（阴影随
        // 整体平滑淡出），完全透明后才禁用整棵子树，拦截幽灵点击
        enabled: opacity > 0
        Behavior on opacity {
            NumberAnimation {
                duration: Theme.animationFast
                easing.type: Easing.OutCubic
            }
        }

        Column {
            id: titleColumn
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.leftMargin: Theme.spacingMedium
            anchors.topMargin: Theme.spacingMedium
            spacing: 4

            FluText {
                text: root.streamTitle || "直播间标题"
                font: FluTextStyle.Body
                color: "white"
            }

            FluText {
                text: root.streamer ? (root.streamer + "  ·  " + root.formatOnline(root.onlineCount) + "人观看") : ""
                font: FluTextStyle.Caption
                color: "#CCCCCC"
                visible: root.streamer !== ""
            }
        }

        // 必须声明在按钮之前（z 序垫底）：hoverEnabled 的 MouseArea 会
        // 独占悬停事件，盖在按钮上方会吞掉按钮的 hovered 导致悬停动效失效
        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
            onPositionChanged: { if (root.controlsVisible) hideControlsTimer.restart() }
        }

        // 未关注：FluFilledButton（主题色实底，醒目）；已关注：FluButton
        //（普通灰底，低调）。两种状态视觉差异明显
        Loader {
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.rightMargin: Theme.spacingMedium
            anchors.topMargin: Theme.spacingMedium
            sourceComponent: root.isFollowing ? followPlainBtn : followFilledBtn
            active: root.mid !== ""
        }
        Component {
            id: followFilledBtn
            FluFilledButton {
                text: "+ 关注"
                font: FluTextStyle.Caption
                onClicked: {
                    closePopups()
                    if (root.mid !== "") {
                        InteractionManager.followUser(root.mid, 1)
                    }
                }
            }
        }
        Component {
            id: followPlainBtn
            FluButton {
                text: "已关注"
                font: FluTextStyle.Caption
                onClicked: {
                    closePopups()
                    if (root.mid !== "") {
                        InteractionManager.followUser(root.mid, 2)
                    }
                }
            }
        }
    }

    // 控制栏
    // 高度 = 按钮行（liveControlBarHeight）+ 上方 55px 纯渐变区：渐变
    // 铺展在更多像素上，与顶部标题栏对称。按钮行锚定底部（见 RowLayout），
    // 视觉位置不变；55px 渐变区同时充当按钮上方的"悬停保持"缓冲区
    // （悬停在按钮附近即保持控制栏不隐藏）
    // 渐变 alpha 严格线性上升（0 → 0.8，每 10% 一档），白背景下灰度坡
    // 均匀，无可见边界（与顶部标题栏同一套曲线，仅方向镜像）
    // radius 使底部两角为圆角（与视频播放页控制栏一致）；顶部两角处于
    // 渐变全透明区，圆角裁切不可见
    Rectangle {
        id: controlBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: Theme.liveControlBarHeight + 55
        radius: 6
        gradient: Gradient {
            GradientStop { position: 0.00; color: "#00000000" }
            GradientStop { position: 0.10; color: "#14000000" }
            GradientStop { position: 0.20; color: "#29000000" }
            GradientStop { position: 0.30; color: "#3D000000" }
            GradientStop { position: 0.40; color: "#52000000" }
            GradientStop { position: 0.50; color: "#66000000" }
            GradientStop { position: 0.60; color: "#7A000000" }
            GradientStop { position: 0.70; color: "#8F000000" }
            GradientStop { position: 0.80; color: "#A3000000" }
            GradientStop { position: 0.90; color: "#B8000000" }
            GradientStop { position: 1.00; color: "#CC000000" }
        }
        opacity: root.controlsVisible ? 1 : 0
        // 同 topBar：跟随 opacity 而非 controlsVisible，避免 enabled 瞬间
        // 翻 false 抽掉按钮阴影/描边产生残影；完全透明后才禁用（拦截幽灵点击）
        enabled: opacity > 0
        Behavior on opacity {
            NumberAnimation {
                duration: Theme.animationFast
                easing.type: Easing.OutCubic
            }
        }

        // 控制栏区域悬停检测（HoverHandler 为被动监听，不与子控件
        // MouseArea 抢事件）：悬停期间不触发自动隐藏
        HoverHandler { id: controlBarHover }

        // 必须声明在按钮之前（z 序垫底）：hoverEnabled 的 MouseArea 会
        // 独占悬停事件，盖在按钮上方会吞掉按钮的 hovered 导致悬停动效失效
        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
            onPositionChanged: root.playerMouseActivity()
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Theme.spacingMedium
            anchors.rightMargin: Theme.spacingMedium
            spacing: Theme.spacingMedium

            FluIconButton {
                iconSource: FluentIcons.Sync
                iconSize: Theme.iconSizeMedium
                iconColor: "white"
                hoverColor: "#26FFFFFF"   // 15% 白：黑底上可见但不刺眼
                pressedColor: "#40FFFFFF"
                Layout.alignment: Qt.AlignVCenter
                onClicked: {
                    closePopups()
                    root.loadStream()
                }
            }

            Item { Layout.fillWidth: true }

            FluIconButton {
                id: volumeBtn
                iconSource: {
                    if (root.volume === 0) return FluentIcons.Mute
                    if (root.volume <= 0.33) return FluentIcons.Volume1
                    if (root.volume <= 0.66) return FluentIcons.Volume2
                    return FluentIcons.Volume3
                }
                iconSize: Theme.iconSizeMedium
                iconColor: "white"
                hoverColor: "#26FFFFFF"
                pressedColor: "#40FFFFFF"
                Layout.alignment: Qt.AlignVCenter
                onClicked: {
                    var wasOpen = volumePopup.opened
                    closePopups()
                    if (!wasOpen) volumePopup.open()
                }
            }

            FluIconButton {
                id: danmakuBtn
                iconSource: FluentIcons.Subtitles
                iconSize: Theme.iconSizeMedium
                iconColor: "white"
                hoverColor: "#26FFFFFF"
                pressedColor: "#40FFFFFF"
                Layout.alignment: Qt.AlignVCenter
                onClicked: {
                    var wasOpen = danmakuPopup.opened
                    closePopups()
                    if (!wasOpen) danmakuPopup.open()
                }
            }

            // 画质选项
            FluMenuBar {
                Layout.alignment: Qt.AlignVCenter
                delegate: FluMenuBarItem {
                    id: mbItem
                    textColor: "white"
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
                    title: root.currentQuality
                    onAboutToShow: closePopups()
                    // 动态生成画质菜单
                    Instantiator {
                        model: root.qualityList
                        delegate: FluMenuItem {
                            text: modelData.desc
                            onTriggered: {
                                root.currentQuality = modelData.desc
                                root.currentQn = modelData.qn
                                root.qualityChanged(modelData.desc)
                                root.loadStream()
                            }
                        }
                        onObjectAdded: function(index, object) {
                            qualityMenu.addItem(object)
                        }
                        onObjectRemoved: function(index, object) {
                            qualityMenu.removeItem(object)
                        }
                    }
                }
            }

            // 视频信息按钮（用于验证实际播放画质）
            FluIconButton {
                iconSource: FluentIcons.Info
                iconSize: Theme.iconSizeMedium
                iconColor: "white"
                hoverColor: "#26FFFFFF"
                pressedColor: "#40FFFFFF"
                Layout.alignment: Qt.AlignVCenter
                onClicked: {
                    closePopups()
                    // 立即刷新一次实际参数
                    if (mpvPlayer.hasVideo) {
                        var info = mpvPlayer.getVideoInfo()
                        root.actualWidth = info["width"] || 0
                        root.actualHeight = info["height"] || 0
                        root.actualVideoCodec = info["videoCodec"] || ""
                        root.actualVideoFormat = info["videoFormat"] || ""
                        root.actualContainerFormat = info["containerFormat"] || ""
                        root.actualFps = info["fps"] || 0
                        root.actualVideoBitrate = info["videoBitrate"] || 0
                        root.actualAudioBitrate = info["audioBitrate"] || 0
                        root.actualAudioCodec = info["audioCodec"] || ""
                        root.actualPath = info["path"] || ""
                    }
                    root.showVideoInfo = !root.showVideoInfo
                }
            }

            // 小窗播放：进入/退出独立置顶小窗
            FluIconButton {
                id: miniWindowBtn
                iconSource: root.isMiniWindow ? FluentIcons.ClosePane : FluentIcons.OpenInNewWindow
                iconSize: Theme.iconSizeMedium
                iconColor: "white"
                hoverColor: "#26FFFFFF"
                pressedColor: "#40FFFFFF"
                Layout.alignment: Qt.AlignVCenter
                onClicked: {
                    closePopups()
                    if (root.isMiniWindow) root.exitMiniWindow()
                    else root.enterMiniWindow()
                }
            }

            FluIconButton {
                iconSource: FluentIcons.BackToWindow
                iconSize: Theme.iconSizeMedium
                iconColor: "white"
                hoverColor: "#26FFFFFF"
                pressedColor: "#40FFFFFF"
                Layout.alignment: Qt.AlignVCenter
                onClicked: {
                    closePopups()
                    root.closeRequested()
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
                text: Math.round(root.volume * 100) + "%"
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

                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: volumeSlider.trackTop
                    width: 4
                    height: volumeSlider.trackHeight
                    radius: 2
                    color: "#808080"
                }

                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: volumeSlider.trackTop + volumeSlider.trackHeight * (1 - root.volume)
                    width: 4
                    height: volumeSlider.trackHeight * root.volume
                    radius: 2
                    color: FluTheme.primaryColor
                }

                Item {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 16
                    height: 16
                    y: volumeSlider.trackTop + volumeSlider.trackHeight * (1 - root.volume) - height / 2

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
                        root.volume = Math.max(0, Math.min(1, ratio))
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
                    checked: root.danmakuEnabled
                    clickListener: function() { root.danmakuEnabled = !root.danmakuEnabled }
                    normalColor: "#323232"
                    hoverColor: "#3E3E3E"
                    borderNormalColor: "#A1A1A1"
                    dotNormalColor: "#D0D0D0"
                    dotCheckColor: "#000000"
                }
            }

            // 弹幕帧率限制（高刷屏节流档位；60Hz 屏不节流，禁用）。
            // 与视频播放页共用同一 FramePacer 档位与持久化键
            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                FluText {
                    text: "弹幕帧率限制"
                    font: FluTextStyle.Body
                    color: "#FFFFFF"
                    opacity: liveDanmakuFpsCombo.enabled ? 1.0 : 0.4
                }

                Item { Layout.fillWidth: true }

                FluComboBox {
                    id: liveDanmakuFpsCombo
                    // DWM 权威刷新率（Screen.refreshRate 高刷屏常误报 60）
                    readonly property real refreshRate: FramePacer.refreshRate
                    readonly property var optionValues: {
                        var vals = [60, 100, 120, 144].filter(
                            function(r) { return r <= refreshRate + 1 })
                        vals.push(0)
                        return vals
                    }
                    enabled: refreshRate > 63
                    model: optionValues.map(
                        function(v) { return v === 0 ? "不限制" : v + " fps" })
                    function syncIndex() {
                        // live 命名空间（与页面内其他弹幕设置一致）；曾误用
                        // video/danmaku/fpsLimit 导致与视频页互相覆盖
                        var saved = Settings.getInt("live/danmaku/fpsLimit", 60)
                        var idx = optionValues.indexOf(saved)
                        if (idx < 0)
                            idx = optionValues.indexOf(60)
                        currentIndex = idx >= 0 ? idx : 0
                    }
                    Component.onCompleted: syncIndex()
                    onOptionValuesChanged: syncIndex()
                    onActivated: function(index) {
                        FramePacer.setTargetRate(optionValues[index])
                        Settings.setInt("live/danmaku/fpsLimit", optionValues[index])
                    }
                }
            }

            // 弹幕描边样式（对齐 B 站三档，与视频页同款）
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
                    currentIndex: root.danmakuOutlineStyle
                    onActivated: function(index) {
                        root.danmakuOutlineStyle = index
                        savePlayerSettings()
                    }
                }
            }

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
                    value: root.danmakuSize
                    text: value.toFixed(1) + "x"
                    onValueChanged: root.danmakuSize = value
                }
            }

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
                    value: root.danmakuOpacity
                    text: Math.round(value * 100) + "%"
                    onValueChanged: root.danmakuOpacity = value
                }
            }

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
                    currentIndex: root.danmakuRangeIndex
                    onCurrentIndexChanged: root.danmakuRangeIndex = currentIndex

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
                    currentIndex: root.danmakuSpeedIndex
                    onCurrentIndexChanged: root.danmakuSpeedIndex = currentIndex

                    FluRadioButton { text: "慢"; textColor: "#FFFFFF" }
                    FluRadioButton { text: "中"; textColor: "#FFFFFF" }
                    FluRadioButton { text: "快"; textColor: "#FFFFFF" }
                }
            }
        }
    }

    // Esc 退出小窗（页面级快捷键，主窗口激活时生效）
    //（小窗模式下页面 visible 从父级"流动"为 false，只认 isMiniWindow）
    Shortcut {
        sequence: "Esc"
        enabled: root.isMiniWindow
        onActivated: root.exitMiniWindow()
    }

    // 小窗模式退出监听：非本页发起的退出路径（main.qml 窗口关闭拦截等）
    // 经 App.miniPlayerModeChanged 驱动本页恢复
    Connections {
        target: App
        function onMiniPlayerModeChanged() {
            if (!App.miniPlayerMode)
                root._restoreFromMini()
        }
    }

    // ========== 小窗播放 UI 层（单窗口变身方案，与视频页同方案）==========
    // 主窗口自身变身为置顶小窗（App.enterMiniPlayerMode），本层与播放器/
    // 弹幕层一起 reparent 到 main.qml 的 miniPlayerHost（同窗口，无渲染
    // 上下文重建）。窗口边缘 8px 由 FluFrameless 的原生 WM_NCHITTEST 提供
    // 缩放（与常规窗口边框同路径），无需自绘缩放手柄；拖动视频区移动窗口
    Item {
        id: miniUiRoot
        visible: false
        // 挂到 miniPlayerHost 后填满整个窗口；未挂载时填满页面（不可见）
        anchors.fill: parent

        // 鼠标交互：右键退出小窗、左键暂停/恢复、移动唤出迷你控制栏、
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
            // 活动检测无意义，直接忽略
            property point _lastHoverPos: Qt.point(-99999, -99999)
            // 拖动移动窗口（系统原生）：左键按住位移超过 4px 判定为拖拽，
            // 交给系统原生移动循环（startSystemMove → SC_MOVE 模态循环）。
            // 判定按住的按键必须用 mouse.buttons（复数）——move 事件中
            // mouse.button 恒为 NoButton（只在 press/release/click 有效）
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
                root.playerMouseActivity()   // 复用指针自动隐藏逻辑
                miniControlBar.visible = true
                miniHideTimer.restart()
            }
            onCanceled: _winDragging = false
            onExited: {
                _lastHoverPos = Qt.point(-99999, -99999)   // 离窗重置：重进首事件必坐标不同
                root.cursorHidden = false
                hideCursorTimer.stop()
                // 不在此隐藏控制栏：控制栏出现在光标下方时其 MouseArea（z 更高）
                // 会抢占悬停并触发本 handler，立即隐藏会与"移动唤出"形成
                // 可见性闪烁循环。控制栏只由 miniHideTimer 3 秒静止超时隐藏
            }
            onClicked: (mouse) => {
                if (_winDragging) {   // 拖拽收尾：吞掉点击，不触发暂停/恢复
                    _winDragging = false
                    return
                }
                if (mouse.button === Qt.RightButton) {
                    root.exitMiniWindow()
                } else {
                    root.miniTogglePlay()
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

        // 迷你控制栏：暂停/恢复 + 直播信息 + 退出小窗（悬停/移动时显示）
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
                    root.playerMouseActivity()
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
                    onClicked: root.miniTogglePlay()
                }

                // 直播信息：主播名 + 标题（超长省略）
                FluText {
                    Layout.fillWidth: true
                    text: (root.streamer !== "" ? root.streamer + " · " : "") + root.streamTitle
                    color: "#FFFFFF"
                    font.pixelSize: 11
                    elide: Text.ElideRight
                    Layout.alignment: Qt.AlignVCenter
                }

                // 退出小窗（图标与主控制栏小窗键一致）
                FluIconButton {
                    iconSource: FluentIcons.ClosePane
                    iconSize: 16
                    iconColor: "#FFFFFF"
                    onClicked: root.exitMiniWindow()
                }
            }
        }
    }
}
