import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import QtQuick.Window 2.15
import QtQuick.Effects

import FluentUI 1.0
import BiliQt 1.0
import "../components"

Rectangle {
    id: root
    color: FluTheme.backgroundColor
    radius: 8   // 与视频播放页/用户主页一致
    antialiasing: true
    clip: true
    // 弹出页 Frame 框线：与 FluFrame 同款 1px 分割线边框，主题自适应
    border.width: 1
    border.color: FluTheme.dividerColor

    property string roomId: ""
    property string streamTitle: ""
    property string streamer: ""
    property string cover: ""
    property string face: ""
    property string mid: ""
    property int onlineCount: 0
    property int liveStatus: 0
    // 开播时间戳（unix 秒）：getInfoByRoom 的 room_info.live_start_time。
    // 顶部/底部控制栏的「开播X小时Y分钟」由它本地计算，无该字段（未开播或
    // 接口未下发）时相关文案隐藏。0 = 无数据
    property int liveStartTime: 0
    // 高能观众数：弹幕 WS 的 ONLINE_RANK_COUNT 实时推送（PiliPlus 同源），
    // 未收到推送时为 0，此时顶部不显示「高能观众」段
    property int energyViewerCount: 0
    // 开播时长文本（由 liveStartTime + liveDurationTimer 驱动，见 formatLiveDuration）
    property string liveDurationText: ""
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

    // ===== 发送弹幕 =====
    // 发送中防抖：B 站限频 1条/秒，期间回车不再发请求
    property bool _danmakuSending: false
    // 表情包数据（GetEmoticons 响应）：[{pkgName, emoticons:[{unique, text, url}]}]
    property var _emoticonPackages: []
    // 平铺表情列表（面板渲染用，含 pkgName 供分类过滤）：[{unique, text, url, pkgName}]
    property var _emoticonList: []
    // 当前选中的分类（空串=尚未初始化，解析完成后默认选第一个包）
    property string _emoticonFilter: ""
    // 面板打开过一次后不再重复请求（同一房间会话内表情包不变）
    property bool _emoticonsLoaded: false

    // 分类过滤（绑定引用 _emoticonList/_emoticonFilter，二者变化自动重算）
    function filteredEmoticons() {
        if (_emoticonFilter === "") return _emoticonList
        var out = []
        for (var i = 0; i < _emoticonList.length; i++) {
            if (_emoticonList[i].pkgName === _emoticonFilter) out.push(_emoticonList[i])
        }
        return out
    }

    // 看过人数原文（如 "251人看过" / "1.2万人看过"）：与官网播放器同源。
    // 初始值来自 getInfoByRoom 的 data.watched_show.text_large，之后由弹幕 WS
    // 的 WATCHED_CHANGE 实时刷新（B站服务端自己格式化的文案，直接展示，
    // 不再用 formatOnline 二次加工）。空串 = 接口未下发，此时顶部回退用
    // online 字段拼「XX人看过」
    property string watchedShowText: ""

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
    property int _eofRetryCount: 0      // 直播中途断流（EOF）自动重连计数，重新拉到流后清零
    property int maxEofRetries: 5        // 断流重连上限，超过则判定直播已断开并显示错误提示
    property string _eofRoomId: ""       // 发起断流重连时的房间号，期间切换房间则取消重连

    // ===== 断流重连两段式 =====
    // 第 1~3 次断流：用**当前 URL** 原地重开（不重新请求 playurl，省一次 HTTPS，
    //               覆盖瞬时抖动、连接被 CDN 重置这类"流还在、只是本地断了"）；
    // 第 4 次起    ：重新请求 playurl + 换候选（覆盖 URL 过期、CDN 节点故障、
    //               主播断流重推导致旧 session 失效）。
    // 计数只在"连续播放满 6 秒"后才清零（见 stablePlayTimer）：坏节点常能出
    // 几秒画面又断，一出画面就清零会让它永远停在原地重开阶段升不上去。
    property int _sameUrlRetries: 0
    property int maxSameUrlRetries: 3
    property bool _pendingSameUrlReload: false  // 本次重连走"原地重开"还是"重取地址"
    property bool _playedOnce: false            // 本次加载是否出过画面（区分中途断流/首次加载失败）

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
        if (emoticonPopup.opened) emoticonPopup.close()
        // 设置抽屉挂在窗口 overlay 上，不受本页裁剪：小窗/退出/关页前必须
        // 主动关闭，否则会留在屏幕上盖住新页面（加存在性判断：页面初始化
        // 期间子项可能还没创建）
        if (settingsSheet && settingsSheet.opened) settingsSheet.close()
        // 天选对话框同为模态：小窗/退出前必须关掉，否则 modal 遮层会盖在
        // 480x270 的小窗视频上，且高度会被 overlay 裁剪
        if (anchorLotteryDialog.opened) anchorLotteryDialog.close()
        root._anchorLotteryId = ""
    }

    // 设置抽屉：右侧滑入，宽度与视频播放页的设置抽屉一致（360），
    // 高度与纵向位置贴住直播播放页本身（不是整窗），否则会盖住上面的标签栏
    function openSettingsSheet() {
        closePopups()
        // FluSheet 的 Right 分支会把 width 绑成 size、height 绑成整窗高；
        // 打开后再改成"贴住本页"的范围（enter 动画只动 x，不会覆盖这些值）
        settingsSheet.open(FluSheetType.Right)
        settingsSheet.width = Math.min(360, root.width)
        settingsSheet.height = root.height
        settingsSheet.y = root.mapToItem(null, 0, 0).y
    }

    // 自动隐藏豁免：鼠标悬停在控制栏区域内，或任一弹出面板/菜单
    //（音量、设置抽屉、画质菜单、表情面板，含面板内的下拉框）打开，
    // 或弹幕输入框持有焦点（输入中）时，控制栏与鼠标指针均不进入自动隐藏
    function controlOverlayActive() {
        return controlBarHover.hovered
            || topBarHover.hovered
            || volumePopup.opened
            || (settingsSheet && settingsSheet.opened)
            || qualityMenu.opened
            || danmakuInput.activeFocus
            || emoticonPopup.opened
    }

    function showControls() {
        root.controlsVisible = true
        root.cursorHidden = false
        hideControlsTimer.restart()
        hideCursorTimer.restart()
    }

    // ===== 发送弹幕 =====
    // 前置校验：未登录直接提示，不发注定失败的请求
    function sendLiveDanmaku(text) {
        if (root._danmakuSending) return
        var msg = (text || "").trim()
        if (msg === "") return
        if (!Login.isLoggedIn) {
            scInfoBar.showWarning("请先登录后发送弹幕")
            return
        }
        root._danmakuSending = true
        Api.sendLiveDanmaku(String(root.roomId), msg)
        // 1.2s 超时自复位（网络异常漏掉响应时不永久卡死）
        _danmakuSendGuard.restart()
    }

    // 发送大表情弹幕（来自表情面板）
    function sendLiveEmoticon(unique, text) {
        if (root._danmakuSending) return
        if (!Login.isLoggedIn) {
            scInfoBar.showWarning("请先登录后发送弹幕")
            return
        }
        root._danmakuSending = true
        Api.sendLiveDanmakuEmoticon(String(root.roomId), unique, text)
        _danmakuSendGuard.restart()
    }

    Timer {
        id: _danmakuSendGuard
        interval: 1200
        onTriggered: root._danmakuSending = false
    }

    function toggleControls() {
        if (root.controlsVisible) {
            root.controlsVisible = false
            closePopups()
            hideControlsTimer.stop()
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

    // 小窗模式恢复：播放器与弹幕层挂回 videoLayer（playerLayer 内声明
    // 在最前的专用透明挂载层，与视频页 playerLayer 同方案）。reparent
    // 会把项追加到目标容器子项列表末尾，但因 videoLayer 本身是
    // playerLayer 的第一个子项，任何挂入项都在补角层（z=10）、控制栏/
    // 顶栏（z=20）之下，叠层关系与初始声明一致，z 无需负值压底
    // （负 z 会绘制到父项背景之下造成黑屏）。任何退出路径（本页按钮/
    // 右键/Esc/窗口关闭/页面销毁）都经 miniPlayerModeChanged 到这里
    function _restoreFromMini() {
        if (!root.isMiniWindow) return
        root.isMiniWindow = false
        mpvPlayer.parent = videoLayer
        danmakuOverlay.parent = videoLayer
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

    // 开播时长：由 live_start_time 本地计算（该字段是开播时的 unix 秒戳，
    // 播中不会变，所以文本靠定时器重算，不走接口轮询）。
    // 格式对齐需求「开播hh小时mm分钟」：不足 1 小时只显示分钟，不足 1 分钟
    // 显示「刚刚开播」；无时间戳返回空串（调用方据此隐藏）
    function formatLiveDuration(startTs) {
        if (!startTs || startTs <= 0) return ""
        var secs = Math.floor(Date.now() / 1000) - startTs
        if (secs < 0) secs = 0
        var h = Math.floor(secs / 3600)
        var m = Math.floor((secs % 3600) / 60)
        if (h > 0) return "开播" + h + "小时" + m + "分钟"
        if (m > 0) return "开播" + m + "分钟"
        return "刚刚开播"
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

    // 断流重连调度（两段式）。reason 只用于日志区分来源（eof / error）。
    function scheduleDisconnectRetry(reason) {
        if (root._stopped || root.roomId === "" || root._loadingInProgress) return
        // 去重：同一次断流 mpv 可能先报 error 再报 EOF（或反过来）。
        // 第一次信号已经把重连排进 eofReconnectTimer；定时器还在跑就说明
        // 这次断流已安排过，直接忽略。定时器触发（重连已执行）后再断才是新的一次。
        if (eofReconnectTimer.running) return

        root._eofRetryCount++
        if (root._eofRetryCount > root.maxEofRetries) {
            console.warn("[LivePlayerPage] disconnect retries exhausted, reason:", reason)
            root.handleLoadFailure("直播连接已断开，请点击重新加载")
            return
        }
        root._eofRoomId = root.roomId

        var sameUrl = root._sameUrlRetries < root.maxSameUrlRetries
        if (sameUrl) root._sameUrlRetries++
        root._pendingSameUrlReload = sameUrl

        var interval
        if (sameUrl) {
            // 原地重开很便宜：1s / 1.5s / 2s，尽快恢复
            interval = 1000 + 500 * (root._sameUrlRetries - 1)
        } else {
            // 重取地址：退避拉长，避免把风控/限流打得更多
            interval = Math.min(2000 * Math.pow(2, root._eofRetryCount - root.maxSameUrlRetries - 1), 10000)
        }

        console.warn("[LivePlayerPage] disconnect (" + reason + "), attempt", root._eofRetryCount,
                     sameUrl ? "SAME-URL" : "RELOAD-PLAYURL", "in", interval, "ms")
        eofReconnectTimer.interval = interval
        eofReconnectTimer.restart()
    }

    // 快路径：不重新请求 playurl，直接把当前地址再交给 mpv。
    // 注意不能写 mpvPlayer.source = root.streamUrl —— setSource 对相同值会直接
    // return（避免 QML 绑定重复触发），所以改用 mpvPlayer.reload()。
    function reloadSameSource() {
        if (!root.visible) return
        if (root.streamUrl === "") {
            root.loadStream()
            return
        }
        console.warn("[LivePlayerPage] reconnecting with same url, same-url attempt", root._sameUrlRetries)
        root.loadFailed = false
        root.loadErrorMsg = ""
        root._waitingForVideo = true
        root._wasPlaying = false
        root._loadStartTime = Date.now()
        mpvPlayer.reload()
        loadTimeoutTimer.start()
        videoInfoTimer.start()
        delayedPlayTimer.start()
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
        // 开播时长/高能观众/看过人数随房间重置：旧房间的开播时刻、WS 计数与
        // 看过文案不清，会在新房间的 roomInfo/WS 推送到达前显示上一个房间的数据
        root.liveStartTime = 0
        root.liveDurationText = ""
        root.energyViewerCount = 0
        root.watchedShowText = ""
        root._waitingForVideo = false
        root._wasPlaying = false
        // 注意：这里**不清零** _sameUrlRetries / _eofRetryCount。
        // 它们表达的是"这一轮断流已经重试了几次"，只在三种情况下归零：
        // 连续播稳 6 秒（stablePlayTimer）、切房间、用户换清晰度。
        // 若在这里清零，第 4 次断流刚升级到"重取地址"，第 5 次又会退回
        // "原地重开 3 次"，永远升不上去。
        root._pendingSameUrlReload = false
        root._playedOnce = false
        stablePlayTimer.stop()
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
                // 诊断：WS 连上就被踢时，靠这行确认应用选的 host/token
                // （与 Node 实测对照：Node 用 host_list[0] 稳定 15s 不断）
                console.warn("[LivePlayerPage] danmu connect:", host + ":" + port,
                             "room:", root.roomId, "tokenLen:", token.length,
                             "hostCount:", hostList.length)
                if (root.danmakuManager.isConnected()) {
                    root.danmakuManager.disconnectRoom()
                }
                root.danmakuManager.setDanmakuInfo(host, port, token)
                root.danmakuManager.connectRoom(parseInt(root.roomId, 10))
            } else {
                console.warn("[LivePlayerPage] danmu info incomplete, host:", host,
                             "port:", port, "code:", resp.code)
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
        root._eofRetryCount = 0
        root._sameUrlRetries = 0
        root._pendingSameUrlReload = false
        root._playedOnce = false
        eofReconnectTimer.stop()
        stablePlayTimer.stop()
        loadTimeoutTimer.stop()
        delayedPlayTimer.stop()
        videoInfoTimer.stop()
        // 5. 重置关注状态（新直播间需要重新获取）
        root.mid = ""
        root.isFollowing = false
        // 5.1 清理天选时刻状态：新直播间不继承上一场的抽奖按钮/去重记录
        root._lotteryId = ""
        root._lotteryAward = ""
        root._lotteryDeadline = 0
        root._lotteryRemain = 0
        root._lotteryJoinedId = ""
        root._lotteryPendingJoinId = ""
        root._lotteryRequireType = 0
        root._lotteryDanmu = ""
        root._lotteryGiftPrice = 0
        root._lastAnchorLotteryPromptId = ""
        root._anchorLotteryId = ""
        if (anchorLotteryDialog.opened) anchorLotteryDialog.close()
        // 6. 重置发送弹幕状态：新房间表情包重新拉取，输入框清空
        root._emoticonsLoaded = false
        root._emoticonPackages = []
        root._emoticonList = []
        root._emoticonFilter = ""
        root._danmakuSending = false
        danmakuInput.text = ""

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
        // 关直播立刻交还电源策略
        App.setScreenWakeLock(false, "live")
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
        root._eofRetryCount = 0  // 关闭播放器，取消未触发的断流重连
        root._sameUrlRetries = 0
        root._pendingSameUrlReload = false
        root._playedOnce = false
        root._loadGeneration++  // 递增代次，使所有 pending 的异步 API 响应（streamInfo/danmuInfo）作废
        eofReconnectTimer.stop()
        stablePlayTimer.stop()
        loadTimeoutTimer.stop()
        delayedPlayTimer.stop()
        videoInfoTimer.stop()
    }

    Component.onDestruction: {
        // 兜底释放防息屏锁（App 是全局单例，此处访问安全；不要碰子对象）
        App.setScreenWakeLock(false, "live")
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
            // 防护：鼠标已离开播放区时只隐藏控制栏，不藏播放区外的指针
            // 小窗模式豁免：playerHoverArea 留在页面布局里，小窗有自己的离开处理
            var mouseOutside = !root.isMiniWindow && playerHoverArea && !playerHoverArea.containsMouse
            root.controlsVisible = false
            if (!mouseOutside) root.cursorHidden = true
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
            // 防护：鼠标已离开播放区时不隐藏（否则会藏掉播放区外的指针）
            // 小窗模式豁免：playerHoverArea 留在页面布局里，小窗有自己的离开处理
            if (!root.isMiniWindow && playerHoverArea && !playerHoverArea.containsMouse)
                return
            if (root.controlsVisible)
                hideCursorTimer.restart()
            else
                root.cursorHidden = true
        }
    }

    // 读取 mpv 实际流参数（分辨率/编码/码率等），供「视频信息」浮层显示。
    // 返回值 = 是否读到（流可能还没加载出来）
    function refreshVideoInfo() {
        if (!mpvPlayer.hasVideo) return false
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
        return true
    }

    // 延迟获取 mpv 实际视频参数（流加载需要时间）
    Timer {
        id: videoInfoTimer
        interval: 3000
        repeat: false
        onTriggered: {
            // 还没加载出来就再等一下
            if (!root.refreshVideoInfo())
                videoInfoTimer.start()
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
                // 看过人数原文（如 "251人看过"）：与官网播放器同源，优先用它展示；
                // 之后由 WS WATCHED_CHANGE 实时刷新。接口未下发时留空，顶部回退 online
                var watchedShow = resp.data.watched_show
                if (watchedShow && watchedShow.text_large)
                    root.watchedShowText = watchedShow.text_large
                // 开播时刻（unix 秒）：未开播的房间为 0，此时底部不显示开播时长
                if (info.live_start_time !== undefined) root.liveStartTime = info.live_start_time
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
        // 发送弹幕响应（文字/表情共用）：code=0 成功，非 0 展示错误信息
        function onLiveDanmakuSendResult(data) {
            root._danmakuSending = false
            _danmakuSendGuard.stop()
            try {
                var dataStr = typeof data === "string" ? data : data.toString()
                var resp = JSON.parse(dataStr)
                if (resp.code === 0) {
                    // 成功后清空输入框；内容经服务端广播（DANMU_MSG）正常
                    // 上屏显示，自己发的也会收到，无需本地回显
                    danmakuInput.text = ""
                } else {
                    var errMsg = resp.message || ("错误码: " + resp.code)
                    // -101 未登录/凭证失效：提示登录；其余直接透出后端信息
                    if (resp.code === -101) errMsg = "请先登录后发送弹幕"
                    scInfoBar.showWarning("发送失败: " + errMsg)
                }
            } catch (e) {
                scInfoBar.showWarning("发送失败: 响应解析错误")
            }
        }
        // 表情包列表响应。真实结构（实测）：data.data 为表情包数组，
        // 每包含 emoticons 数组；表情项字段：emoticon_unique(发送标识)、
        // emoji(触发词)、descript、url、perm(1=可发送)、width/height
        function onLiveEmoticonsReceived(data) {
            try {
                var dataStr = typeof data === "string" ? data : data.toString()
                var resp = JSON.parse(dataStr)
                root._emoticonPackages = []
                if (resp.code !== 0 || !resp.data) {
                    // 失败也结束"加载中"状态并提示（下次打开面板会重新请求）
                    root._emoticonsLoaded = true
                    scInfoBar.showWarning("表情包加载失败: " + (resp.message || ("错误码: " + resp.code)))
                    return
                }
                var pkgs = (resp.data && resp.data.data) ? resp.data.data : []
                // 临时数组构建完毕后一次性赋值：property var 的重新赋值才
                // 会触发视图模型重置；同时构建平铺列表供 GridView 渲染
                var packages = []
                var flat = []
                for (var i = 0; i < pkgs.length; i++) {
                    var pkg = pkgs[i]
                    var emos = pkg["emoticons"] || []
                    var list = []
                    for (var j = 0; j < emos.length; j++) {
                        var emo = emos[j]
                        var unique = emo["emoticon_unique"] || ""
                        var text = emo["emoji"] || emo["descript"] || ""
                        if (unique === "" && text === "") continue
                        // perm=1 所有人可发送；0 为锁定表情（需礼物/等级解锁）
                        if (emo["perm"] !== undefined && emo["perm"] !== 1) continue
                        // 黄豆类表情无 emoticon_unique：unique 留空，
                        // 点击时走文字弹幕路径（网页端同款行为，[dog] 等
                        // 触发词服务器会自动转为表情显示）
                        var item = { unique: unique,
                                     text: text,
                                     // url 偶见被反引号包裹（异常数据），清洗掉
                                     url: String(emo["url"] || "").replace(/`/g, ""),
                                     pkgName: pkg["pkg_name"] || "" }
                        list.push(item)
                        flat.push(item)
                    }
                    if (list.length > 0) {
                        packages.push({ pkgName: pkg["pkg_name"] || "", emoticons: list })
                    }
                }
                root._emoticonPackages = packages
                root._emoticonList = flat
                // 默认选中第一个分类（无“全部”聚合视图）
                if (packages.length > 0) {
                    root._emoticonFilter = packages[0].pkgName
                }
                if (flat.length === 0) {
                    console.warn("[LivePlayerPage] emoticons parsed empty, raw data head:",
                                 dataStr.substring(0, 300))
                }
                root._emoticonsLoaded = true
            } catch (e) {
                console.warn("[LivePlayerPage] parse emoticons failed:", e)
                root._emoticonsLoaded = true
            }
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

    // SC 横幅显示时长：固定 10 秒。B站官方按时长/金额分档（几块钱几秒钟、
    // 大会员大额几十秒），我们不做金额分档，统一 10 秒，多个 SC 排队时
    // 每个都占 10 秒（scInfoBar 的 showCustom 行为）
    readonly property int scDisplayDuration: 10000

    // ===== 天选时刻 =====
    // 已提示过的 lottery id：服务端对同一场天选只推一次 ANCHOR_LOT_START，
    // 但重连/切画质等场景可能重复收到，这里兜底去重（只影响"弹窗"，
    // 常驻按钮的状态记录不受此限制）
    property string _lastAnchorLotteryPromptId: ""
    // 当前待参与的 lottery id（对话框打开期间有效）
    property string _anchorLotteryId: ""

    // 进行中的天选（单条模型：同房间连开两场时后到者覆盖前者——实际极罕见，
    // 用户也只关心最近一场）。常驻按钮的可见性由这份状态驱动，与弹窗解耦：
    // 点"取消"只关弹窗，不影响按钮
    property string _lotteryId: ""
    property string _lotteryAward: ""
    property double _lotteryDeadline: 0      // Date.now() 毫秒时间戳
    property int _lotteryRemain: 0           // 剩余秒（lotteryTick 每秒刷新）
    // 参与条件：ANCHOR_LOT_START 的 require_type（0 无 / 1 关注 / 2 粉丝勋章 / 3 大航海）、
    // 需要发送的口令弹幕 danmu、以及单个礼物价格（>0 表示必须先送礼物，本端不支持）
    property int _lotteryRequireType: 0
    property string _lotteryDanmu: ""
    property int _lotteryGiftPrice: 0
    // 已参与的 lottery id：按钮文案切换为"已抽奖"并停止重复请求
    property string _lotteryJoinedId: ""
    // 正在请求参与中的 id（响应回来时据此标记已参与；-101 等失败则不标记）
    property string _lotteryPendingJoinId: ""
    // 按钮是否有内容可显示（是否有未结束的天选）。
    // 注意：真正的"隐藏/出现"由 topBar 的 opacity 统一控制（与控制栏其他
    // 组件一致），这里只管"有没有抽奖"这一维度
    readonly property bool lotteryButtonVisible: _lotteryId !== "" && _lotteryRemain > 0

    // 结束/到点时的统一清理：状态归零 + 关掉仍挂着的提示弹窗。
    // 弹窗一直没选（既没点参与也没点取消）的情况下，倒计时结束必须让它
    // 自己消失——否则会留下一个内容已过期、点了也没用的对话框
    function _clearLotteryState() {
        root._lotteryId = ""
        root._lotteryAward = ""
        root._lotteryRemain = 0
        root._lotteryRequireType = 0
        root._lotteryDanmu = ""
        root._lotteryGiftPrice = 0
        if (anchorLotteryDialog.opened) anchorLotteryDialog.close()
        root._anchorLotteryId = ""
    }

    // 每秒刷新剩余秒；归零即清空状态（按钮消失）。与服务端 ANCHOR_LOT_END
    // 互为兜底——推送先到就直接清，推送丢了本地倒计时也能收尾
    function _refreshLotteryRemain() {
        if (root._lotteryId === "") {
            root._lotteryRemain = 0
            return
        }
        var remain = Math.ceil((root._lotteryDeadline - Date.now()) / 1000)
        if (remain <= 0) {
            root._clearLotteryState()
        } else {
            root._lotteryRemain = remain
        }
    }

    Timer {
        id: lotteryTick
        interval: 1000
        repeat: true
        running: root._lotteryId !== ""
        onTriggered: root._refreshLotteryRemain()
    }

    // 参与当前天选（弹窗按钮与常驻按钮共用）
    function joinCurrentLottery() {
        if (root._lotteryId === "") {
            // 竞态兜底：点击瞬间正好到点（弹窗/按钮已在收起），给个明确反馈
            // 而不是静默无响应
            scInfoBar.showWarning("本场天选已结束")
            return
        }
        if (root._lotteryJoinedId === root._lotteryId) {
            scInfoBar.showInfo("已参与本场天选，静候开奖~")
            return
        }
        if (!Login.isLoggedIn) {
            scInfoBar.showWarning("请先登录后参与抽奖")
            return
        }
        // 需送礼物的天选本端不支持（没有送礼链路），提前说明，别让用户
        // 点了按钮只看到一句服务端的失败提示
        if (root._lotteryGiftPrice > 0) {
            scInfoBar.showWarning("该天选需要赠送礼物，暂不支持自动参与")
            return
        }
        if (root._lotteryRequireType === 2 || root._lotteryRequireType === 3) {
            scInfoBar.showWarning("该天选要求粉丝勋章/大航海，无法自动满足")
            return
        }
        root._lotteryPendingJoinId = root._lotteryId
        // 关注 + 口令弹幕由接口层按顺序补做（服务端不代做），
        // anchorMid 只在 require_type==1（关注主播）时才用得上
        Api.joinLiveLottery(String(root.roomId), root._lotteryId,
                            String(root.mid), root._lotteryRequireType,
                            root._lotteryDanmu)
        var tip = "正在参与"
        if (root._lotteryRequireType === 1 && !root.isFollowing) tip += "（自动关注主播）"
        if (root._lotteryDanmu !== "") tip += "（自动发送口令弹幕）"
        scInfoBar.showInfo(tip + "，请稍候…")
    }

    FluInfoBar {
        id: scInfoBar
        root: root
    }

    // 天选时刻提示对话框：收到 ANCHOR_LOT_START 时弹出一次（参与/取消）。
    // 点了参与或取消都只关窗，不做官方那种开奖前常驻选项
    FluContentDialog {
        id: anchorLotteryDialog
        title: "天选时刻"
        message: ""
        positiveText: "参与抽奖"
        negativeText: "取消"
        // 必须用 positiveClicked / negativeClicked 这两个**信号**。
        // 不能用 onPositiveClickListener（那是 `property var`）：给它写
        // JS 代码块会被当成绑定表达式，而在体内又改了 _anchorLotteryId
        // ——读同一属性 → 触发绑定重算 → 循环，引擎报 Binding loop，
        // 结果处理函数在弹窗刚打开时就被执行了一遍（发请求 + close()），
        // 表现就是"对话框一闪而过"、抽奖按钮留在控制栏上。
        onPositiveClicked: {
            // 统一走 joinCurrentLottery：用进行中状态里的 id（与本次弹窗同一
            // 个 id）；若已到点被清空，该函数首行直接 return，不会发无效请求
            if (root._anchorLotteryId !== "") root.joinCurrentLottery()
            root._anchorLotteryId = ""
        }
        onNegativeClicked: {
            root._anchorLotteryId = ""
        }
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
            // 小窗模式下不显示 SC：banner 挂在主窗口 Overlay 上，不随播放器
            // reparent，小窗期间显示会飘在小窗的错误位置（进小窗时的清理
            // 只兜底"进小窗前已在显示"的，这里的 return 挡住小窗期间新到的 SC）
            if (root.isMiniWindow) return
            root._scQueue.push({ username: username, face: face, message: message,
                                 price: price, bgColor: bgColor, bgBottomColor: bgBottomColor })
            // scTime 是服务端按金额设计的展示秒数，已弃用：统一走固定 10 秒
            scInfoBar.showCustom(scBannerComponent, root.scDisplayDuration)
        }
        // 天选时刻开启推送（WS ANCHOR_LOT_START）。
        // ① 状态记录：无论小窗与否都记进进行中状态 → 常驻抽奖按钮据此显示；
        //    小窗期间控制栏不显示，恢复普通窗口后按钮自然出现（按需求不补弹）
        // ② 提示弹窗：仅非小窗、且同一 id 只弹一次
        function onAnchorLotteryStarted(lotteryId, awardName, awardNum, requireType,
                                        requireText, danmu, maxTime, giftPrice) {
            if (!lotteryId) return
            root._lotteryId = lotteryId
            root._lotteryAward = awardName || ""
            root._lotteryRequireType = requireType > 0 ? requireType : 0
            root._lotteryDanmu = danmu || ""
            root._lotteryGiftPrice = giftPrice > 0 ? giftPrice : 0
            root._lotteryDeadline = Date.now() + Math.max(1, maxTime) * 1000
            root._refreshLotteryRemain()

            // 小窗不弹提示：模态对话框会遮死 480x270 小窗视频且高度被 overlay 裁剪
            if (root.isMiniWindow) return
            if (lotteryId === root._lastAnchorLotteryPromptId) return
            root._lastAnchorLotteryPromptId = lotteryId
            root._anchorLotteryId = lotteryId
            var lines = []
            lines.push("奖品：" + (awardName || "未知奖品") + " ×" + (awardNum > 0 ? awardNum : 1))
            if (requireText) lines.push("条件：" + requireText)
            // 把"我们来帮你做什么"说清楚：关注和口令弹幕由客户端自动补做，
            // 送礼/勋章这类满足不了的条件提前讲明
            if (root._lotteryRequireType === 1) lines.push("参与方式：自动关注主播后抽奖")
            if (root._lotteryDanmu !== "") lines.push("口令弹幕：" + root._lotteryDanmu + "（自动发送）")
            if (root._lotteryGiftPrice > 0) lines.push("⚠ 需先赠送礼物，本端暂不支持")
            if (root._lotteryRequireType === 2 || root._lotteryRequireType === 3)
                lines.push("⚠ 要求粉丝勋章/大航海，无法自动满足")
            if (maxTime > 0) {
                var mins = Math.floor(maxTime / 60), secs = maxTime % 60
                lines.push("有效期：" + (mins > 0 ? mins + " 分钟" : "") + (secs > 0 && mins === 0 ? secs + " 秒" : ""))
            }
            lines.push("取消后仍可在顶部控制栏点「抽奖」参与")
            anchorLotteryDialog.message = lines.join("\n")
            anchorLotteryDialog.open()
        }
        // 天选结束（WS ANCHOR_LOT_END）：立刻清掉进行中状态，常驻按钮消失；
        // 若提示弹窗还开着（用户一直没选）也一并关闭
        function onAnchorLotteryEnded(lotteryId) {
            if (lotteryId && lotteryId !== root._lotteryId) return
            root._clearLotteryState()
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
        // 高能观众数实时推送（WS ONLINE_RANK_COUNT）。PiliPlus 的「高能观众(N)」
        // 即此值，认证连接后由服务端不定期推送，无需轮询
        function onOnlineRankCountChanged(count) {
            if (count > 0) root.energyViewerCount = count
        }
        // 看过人数实时推送（WS WATCHED_CHANGE，text_large 如 "1.2万人看过"）：
        // 与官网播放器同源的同一种数据，顶部「XX人看过」展示的就是它
        function onWatchedShowChanged(textLarge) {
            root.watchedShowText = textLarge
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

    // 天选时刻参与结果（Api.joinLiveLottery 的响应）
    Connections {
        target: Api
        function onAnchorLotteryJoinResult(data) {
            var pendingId = root._lotteryPendingJoinId
            root._lotteryPendingJoinId = ""
            try {
                var dataStr = typeof data === "string" ? data : data.toString()
                var resp = JSON.parse(dataStr)
                if (resp.code === 0) {
                    // 标记该 id 已参与：顶部常驻按钮文案切为"已抽奖"（按钮在
                    // 天选结束前一直保留），并阻止重复请求
                    if (pendingId !== "") root._lotteryJoinedId = pendingId
                    scInfoBar.showSuccess("已参与天选时刻，静候开奖~")
                } else {
                    var errMsg = resp.message || resp.msg || ("错误码: " + resp.code)
                    // 常见业务码给中文解释（其余原样展示服务端文案）
                    switch (resp.code) {
                    case -101: errMsg = "请先登录后参与抽奖"; break
                    case -400: errMsg = "请求参数有误"; break
                    case -403: errMsg = "风控拦截，稍后再试"; break
                    case 400080: errMsg = "你已参与过本场天选"; break
                    case 400090: errMsg = "抽奖已结束"; break
                    }
                    scInfoBar.showWarning("参与失败: " + errMsg)
                }
            } catch (e) {
                console.warn("[LivePlayerPage] anchorLotteryJoinResult parse error:", e)
                scInfoBar.showWarning("参与失败: 响应解析错误")
            }
        }
    }

    // 阻挡鼠标事件穿透到下方，左键切换控制栏，右击关闭播放页；
    // 同时跟踪鼠标：移动恢复指针，静止3秒自动隐藏
    MouseArea {
        id: playerHoverArea
        anchors.fill: parent
        z: -1
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onPositionChanged: root.playerMouseActivity()
        // 鼠标离开播放区：恢复指针、停指针计时，
        // 但保留控制栏的自动隐藏（触发时只隐藏控制栏，不藏播放区外指针）
        onExited: {
            root.cursorHidden = false
            hideCursorTimer.stop()
            hideControlsTimer.restart()
        }
        onClicked: function(mouse) {
            if (mouse.button === Qt.RightButton) {
                root.closeRequested()
            } else {
                // 有弹窗/抽屉打开时，先关闭它们
                if (volumePopup.opened || (settingsSheet && settingsSheet.opened)) {
                    closePopups()
                } else {
                    root.toggleControls()
                }
            }
        }
    }

    // 黑色播放容器（视频播放页 videoContainer 同款结构）：
    // 铺满 root，播放器/弹幕/补角层/控制栏都挂在这里。root 改为
    // backgroundColor（页面背景色），补角层填色与之同源自洽——
    // 主题切换（CircularReveal 截图 z 序低于页面内容）不再穿帮。
    Rectangle {
        id: playerLayer
        anchors.fill: parent
        color: "black"
        radius: root.radius
        clip: true
        anchors.margins: 3
        // 播放器挂载层（视频页 playerLayer 同款方案）：playerLayer 的
        // 第一个子项，始终最底层。小窗往返的 reparent 挂载点——
        // reparent 会把项追加到目标容器子项列表末尾，直接挂回
        // playerLayer 本体要么排到补角层（z=10）/控制栏（z=20）之后，
        // 要么需负 z 压底；而负 z 子项会绘制到父项自身背景之下，
        // 被容器黑色背景挡住（播放区黑屏）。挂回这个专用透明容器后，
        // 因其声明在最前，叠层关系与初始声明完全一致，z 无需调整
        Item {
            id: videoLayer
            anchors.fill: parent
        }

        // 直播播放器
        MpvObject {
            id: mpvPlayer
            anchors.fill: parent
            liveMode: true  // 直播模式：小cache低延迟（10s/16M），覆盖视频默认的大cache配置
            volume: root.volume
            onPlayingChanged: {
                // 播放期间阻止系统息屏/自动睡眠
                App.setScreenWakeLock(playing, "live")
                // 同上：直播也会被 mpv 写成媒体标题
                if (playing) App.fixAudioSessionIdentity()
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
                // 一旦掉线就停"稳定播放"计时，避免把刚断的流算成稳定
                if (!playing) stablePlayTimer.stop()
                root._wasPlaying = playing
            }
            onErrorOccurred: {
                console.warn("[LivePlayerPage] mpv error:", error)
                // 出过画面又报错 = 播放中途断流，走两段式重连；
                // 从未出过画面属于首次加载失败，仍按"换候选 → 完整重载"处理。
                if (root._playedOnce) {
                    root.scheduleDisconnectRetry("error")
                    return
                }
                root.loadRetryCount++
                if (root.loadRetryCount >= root.maxLoadRetries) {
                    root.handleLoadFailure(error)
                } else {
                    root.tryNextCandidate()
                }
            }
            onLiveStreamEof: {
                // 直播中途断流（主播推流中断 / CDN 掐连接）。两段式重连见
                // scheduleDisconnectRetry：前 3 次原地重开同一 URL，第 4 次起重取地址。
                root.scheduleDisconnectRetry("eof")
            }
            onHasVideoChanged: {
                if (hasVideo) {
                    // 视频加载成功
                    root._waitingForVideo = false
                    root.loadRetryCount = 0
                    root._playedOnce = true
                    // 这里**不再**立刻清零 _eofRetryCount / _sameUrlRetries：
                    // 坏节点常常能出几秒画面又断，一出画面就清零会让它永远停在
                    // "原地重开"阶段、永远升不到"重取地址"。改由 stablePlayTimer
                    // 在连续播放满 6 秒后清零。
                    eofReconnectTimer.stop()
                    loadTimeoutTimer.stop()
                    stablePlayTimer.restart()
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
        // ===== 播放区圆角补角层（与视频播放页同一套方案）=====
        // 直播画面（mpv 方形纹理）会凸出到 playerLayer 圆弧之外的角部
        // 区域，露出直角。两层修复（声明在播放器/弹幕之后、控制栏之前：
        // 同 z 下按声明顺序绘制，盖住视频但不压控制栏）。
        // 结构改为视频页同款后，cornerFix 底下是 root 的背景层
        // （FluTheme.backgroundColor，不参与 CircularReveal 揭示动画），
        // 填色与之间源同帧翻转，主题切换天然不穿帮
        Item {
            id: cornerFix
            anchors.fill: parent
            z: 10   // 压视频/弹幕，低于控制栏（z=20）

            // (a) 直角填补：反转遮罩把"圆弧之外、外接矩形之内"的四个角
            // 填成 root 背景色（FluTheme.backgroundColor），恢复圆角轮廓。
            // mask 与 playerLayer 几何严格一致，textureSize 必须与
            // sourceItem 几何一致（否则 MultiEffect 拉伸采样产生方向性
            // 偏移 → 对角性外露）。纹理按 2x DPR 分配抗锯齿
            Item {
                anchors.fill: parent
                layer.enabled: true
                layer.samples: 4
                layer.effect: MultiEffect {
                    maskEnabled: true
                    maskInverted: true
                    maskSource: ShaderEffectSource {
                        sourceItem: Rectangle {
                            width: Math.max(1, cornerFix.width)
                            height: Math.max(1, cornerFix.height)
                            radius: playerLayer.radius
                            color: "black"
                        }
                        textureSize: Qt.size(Math.max(1, cornerFix.width * Screen.devicePixelRatio * 2),
                                             Math.max(1, cornerFix.height * Screen.devicePixelRatio * 2))
                        hideSource: true
                        live: true
                    }
                }
                Rectangle {
                    anchors.fill: parent
                    color: FluTheme.backgroundColor
                }
            }

            // (b) 圆角描边：与页面背景同色（白天纯白、黑夜纯黑、不透明），
            // 视觉上"隐形"——压住遮罩软边处视频的隐约透出。playerLayer 的
            // clip 会裁掉 margins:-1 外扩的 1px（该区域视频本就画不到），
            // 不影响角部覆盖
            Rectangle {
                anchors.fill: parent
                anchors.margins: -1
                radius: playerLayer.radius
                color: "transparent"
                border.width: 3
                border.color: FluTheme.dark ? Qt.rgba(0, 0, 0, 1.0) : Qt.rgba(1, 1, 1, 1.0)
            }
        }
        // 顶部渐变阴影 + 直播标题
        // 阴影高度独立于文字区：文字区之下再延伸 110px，为渐变提供足够的
        // 竖直空间展开。渐变 alpha 严格线性衰减（0.8 → 0，每 10% 一档）：
        // 白背景下人眼感知的是灰度（1-alpha），线性 alpha 即均匀的灰度坡，
        // 中段不额外压暗、尾段不加速，避免渐变被读成一块边界清晰的"条带"
        // 渐变 Rectangle 的 gradient 填充不遵循 radius（QtQuick 限制）：渐变按
        // 外接矩形直角填充，呼出时黑色直角超出页面圆角形成黑三角。改用
        // FluClip（OpacityMask 真圆角裁剪）承载圆角，渐变 Rectangle 只管填色
        FluClip {
            id: topBar
            z: 20   // 压补角层（z=10）；reparent 回归后也稳定在视频之上
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: titleColumn.height + Theme.spacingMedium * 2 + 110
            // 仅上两角圆角，半径与页面 Frame(root.radius) 一致；
            // 下两角直角与视频画面衔接
            radius: [root.radius, root.radius, 0, 0]
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

            Rectangle {
                anchors.fill: parent
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
                    // 「UP主 · XX人看过 · 高能观众（YY）」：
                    // - XX = 官网同源的看过人数：优先用 getInfoByRoom 下发的
                    //   watched_show.text_large（B站自己格式化的 "251人看过"/
                    //   "1.2万人看过"），并由 WS WATCHED_CHANGE 实时刷新；
                    //   接口未下发该字段时回退用 room_info.online 拼「XX人看过」
                    // - YY = 高能观众，WS ONLINE_RANK_COUNT 实时推送（PiliPlus 同源），
                    //   未收到推送时不显示该段，避免出现"高能观众（0）"
                    text: {
                        if (root.streamer === "") return ""
                        var watched = root.watchedShowText !== ""
                                ? root.watchedShowText
                                : (root.formatOnline(root.onlineCount) + "人看过")
                        var s = root.streamer + "  ·  " + watched
                        if (root.energyViewerCount > 0)
                            s += "  ·  高能观众（" + root.formatOnline(root.energyViewerCount) + "）"
                        return s
                    }
                    font: FluTextStyle.Caption
                    color: "#CCCCCC"
                    visible: root.streamer !== ""
                }
            }

            // 悬停在顶部标题栏时保持控制栏与指针可见（与控制栏同方案：
            // HoverHandler 被动监听，不与子控件 MouseArea 抢事件）
            HoverHandler { id: topBarHover }

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
                id: followLoader
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

            // 天选时刻常驻抽奖按钮：位于关注按钮左侧，样式沿用关注按钮的
            // 两态方案（未参与=FluFilledButton 主题色实底醒目；已参与=
            // FluButton 灰底低调）。显隐完全跟随 topBar（控制栏隐藏时整棵
            // 子树 opacity=0，不单独处理）；小窗模式显式不显示
            Loader {
                anchors.right: followLoader.left
                anchors.rightMargin: Theme.spacingSmall
                anchors.top: parent.top
                anchors.topMargin: Theme.spacingMedium
                active: root.lotteryButtonVisible && !root.isMiniWindow
                sourceComponent: root._lotteryJoinedId === root._lotteryId
                                 ? lotteryJoinedBtn : lotteryJoinBtn
            }
            Component {
                id: lotteryJoinBtn
                FluFilledButton {
                    text: "抽奖"
                    font: FluTextStyle.Caption
                    onClicked: {
                        closePopups()
                        root.joinCurrentLottery()
                    }
                }
            }
            Component {
                id: lotteryJoinedBtn
                FluButton {
                    text: "已抽奖"
                    font: FluTextStyle.Caption
                    onClicked: {
                        closePopups()
                        root.joinCurrentLottery()   // 内部提示已参与，不重复请求
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
        // 同 topBar：FluClip 真圆角裁剪渐变栏（gradient 填充不遵循 radius）
        FluClip {
            id: controlBar
            z: 20   // 压补角层（z=10）；reparent 回归后也稳定在视频之上
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Theme.liveControlBarHeight + 55
            // 仅下两角圆角，半径与页面 Frame(root.radius) 一致；
            // 上两角直角（处于渐变全透明区，不可见）
            radius: [0, 0, root.radius, root.radius]
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

            Rectangle {
                anchors.fill: parent
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
                // 按钮行贴底对齐：渐变衬底高度大于按钮行时，垂直居中会把
                // 按钮整体抬离底部，这里改为锚定底边、固定为控制栏行高
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.leftMargin: Theme.spacingMedium
                anchors.rightMargin: Theme.spacingMedium
                height: Theme.liveControlBarHeight
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

                // 开播时长（PiliPlus 同款）：由 live_start_time 本地计算，
                // 30s 定时刷新文本；未开播/无时间戳时隐藏（text 为空）
                FluText {
                    text: root.liveDurationText
                    font: FluTextStyle.Caption
                    color: "#CCCCCC"
                    Layout.alignment: Qt.AlignVCenter
                    visible: text !== ""
                }

                Item { Layout.fillWidth: true }

                // ===== 弹幕输入框（FluTextBox 定制深色样式）=====
                // 文字保留：仅发送成功才 clear（见 onLiveDanmakuSendResult），
                // 失焦/控制栏隐藏都不清空；输入中经 controlOverlayActive()
                // 豁免自动隐藏。样式覆盖仅此实例，不影响全局主题。
                // 小窗模式（480px）空间不足，隐藏
                FluTextBox {
                    id: danmakuInput
                    visible: !root.isMiniWindow
                    Layout.preferredWidth: 220
                    Layout.maximumWidth: 260
                    Layout.alignment: Qt.AlignVCenter
                    placeholderText: "发个弹幕见证当下"
                    font: FluTextStyle.Caption
                    iconSource: FluentIcons.Send   // 输入框内右侧发送提示（Enter 发送）
                    cleanEnabled: true             // 非空时自动显示清空键（组件内置）
                    maximumLength: 40              // B 站直播弹幕长度限制
                    // 深色半透明定制（仅此实例，不影响全局主题）：
                    // 文字白色（normalColor 为组件公有属性），
                    // 底色半透明黑 + 细白边，聚焦时主题色描边
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
                    onCommit: (text) => root.sendLiveDanmaku(text)
                    Keys.onPressed: (event) => {
                        // 中文输入法组合期间回车是"上屏候选词"，
                        // Qt 已处理，这里无需干预；Esc 交还焦点
                        if (event.key === Qt.Key_Escape) {
                            danmakuInput.focus = false
                            event.accepted = true
                        }
                    }
                }

                // 表情按钮：弹出表情面板（大表情发送）。小窗模式下隐藏
                FluIconButton {
                    id: emoticonBtn
                    visible: !root.isMiniWindow
                    iconSource: FluentIcons.Emoji2
                    iconSize: Theme.iconSizeMedium
                    iconColor: "white"
                    hoverColor: "#26FFFFFF"
                    pressedColor: "#40FFFFFF"
                    Layout.alignment: Qt.AlignVCenter
                    onClicked: {
                        var wasOpen = emoticonPopup.opened
                        closePopups()
                        if (!wasOpen) {
                            if (!root._emoticonsLoaded) {
                                if (Login.isLoggedIn) {
                                    Api.getLiveEmoticons(String(root.roomId))
                                } else {
                                    scInfoBar.showWarning("请先登录后发送弹幕")
                                    return
                                }
                            }
                            emoticonPopup.open()
                        }
                    }
                }

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
                                    // 换清晰度拿到的是全新地址：断流计数归零，
                                    // 让新流重新享有"前 3 次原地重开"的快路径
                                    root._sameUrlRetries = 0
                                    root._eofRetryCount = 0
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

                // 设置：弹幕设置 / 视频信息合并入口，位于小窗键左侧。
                // 弹出的抽屉与视频播放页同款（右侧滑入、同宽、同圆角与阴影）
                FluIconButton {
                    id: settingsBtn
                    iconSource: FluentIcons.Settings
                    iconSize: Theme.iconSizeMedium
                    iconColor: "white"
                    hoverColor: "#26FFFFFF"
                    pressedColor: "#40FFFFFF"
                    Layout.alignment: Qt.AlignVCenter
                    onClicked: root.openSettingsSheet()
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
        // Esc 退出小窗（页面级快捷键，主窗口激活时生效）
        //（小窗模式下页面 visible 从父级"流动"为 false，只认 isMiniWindow）
        Shortcut {
            sequence: "Esc"
            enabled: root.isMiniWindow
            onActivated: root.exitMiniWindow()
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

    // 开播时长刷新定时器：live_start_time 是固定开播时刻，文本需靠本地重算
    // 才能走动。PiliPlus 用 5 分钟刷新（分钟显示会滞后最多 5 分钟），这里取
    // 30 秒——只是字符串格式化，开销可忽略，分钟显示始终准确。
    // running 绑定 liveStartTime：无开播时间（未开播/换房/关闭）时自动停，
    // 页面销毁时随组件一起回收
    Timer {
        id: liveDurationTimer
        interval: 30000
        repeat: true
        running: root.liveStartTime > 0
        onTriggered: root.liveDurationText = root.formatLiveDuration(root.liveStartTime)
    }

    // 开播时间戳到达/变化（loadStream 重置为 0、roomInfo 响应写入）时立即重算文本，
    // 不必等定时器下一个节拍
    onLiveStartTimeChanged: root.liveDurationText = root.formatLiveDuration(root.liveStartTime)

    // 直播断流重连定时器。触发时按 scheduleDisconnectRetry 预先决定的策略执行：
    //   _pendingSameUrlReload=true  → 原地重开当前 URL（快路径，前 3 次）
    //   _pendingSameUrlReload=false → loadStream() 重新请求 playurl + 换候选（第 4 次起）
    Timer {
        id: eofReconnectTimer
        interval: 2000
        repeat: false
        onTriggered: {
            // 房间已切换/播放器已关闭，取消本次重连
            if (root._stopped || root.roomId === "" || root.roomId !== root._eofRoomId) return
            if (root._pendingSameUrlReload) {
                root._pendingSameUrlReload = false
                root.reloadSameSource()
                return
            }
            console.warn("[LivePlayerPage] re-fetching playurl, attempt:", root._eofRetryCount)
            root._fullReloadAttempted = false  // 重取视为新一轮尝试，恢复完整重载兜底
            root.loadStream()
        }
    }

    // 稳定播放计时：连续播满 6 秒才认为断流重连真的成功，此时才清零断流计数。
    // 目的：坏节点能出几秒画面但反复断，若一出画面就清零，计数永远停在
    // 1~3，永远升不到"重新请求 playurl 换节点"那一段。
    Timer {
        id: stablePlayTimer
        interval: 6000
        repeat: false
        onTriggered: {
            if (!mpvPlayer.hasVideo) return
            // 缓冲中（playing=false）不算数，延后一轮再判，
            // 否则恰好在缓冲时触发就永远等不到下一次清零机会
            if (!mpvPlayer.playing) { stablePlayTimer.restart(); return }
            if (root._eofRetryCount !== 0 || root._sameUrlRetries !== 0) {
                console.warn("[LivePlayerPage] playback stable, reset disconnect counters",
                             "eof:", root._eofRetryCount, "sameUrl:", root._sameUrlRetries)
            }
            root._eofRetryCount = 0
            root._sameUrlRetries = 0
        }
    }

    // 直播弹幕管理器（WebSocket 连接 B 站弹幕服务器）
    // 弹幕管理器由外部注入（LivePage 层级共享实例），此处不再创建。









    // 表情面板：GridView 统一网格 + FluScrollBar 滚动 + Pivot 风格分类栏。
    // （FluPivot 的 tab 集合是静态子项，不支持按房间动态生成分类，
    //  故分类栏按 Pivot 视觉规范手绘：主题色下划线高亮 + 悬停变色）
    Popup {
        id: emoticonPopup
        parent: emoticonBtn
        // 尺寸比原来的 360×340 放大一圈：格子按列宽自适应、预览图跟着格子走
        // （原来是格子 48 / 图 36，大表情看着像缩略图，太费眼）
        width: 460
        height: 420
        x: (parent.width - width) / 2
        y: -height - 10
        modal: false
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
        padding: 12
        background: Rectangle {
            radius: 6
            // 跟主题走（暗色 43,43,43 / 亮色纯白 + 主题分割线色边框），
            // 原来固定 #2B2B2B，亮色主题下完全不搭
            color: FluTheme.dark ? Qt.rgba(43/255, 43/255, 43/255, 1)
                                 : Qt.rgba(1, 1, 1, 1)
            border.width: 1
            border.color: FluTheme.dark ? Qt.rgba(58/255, 58/255, 58/255, 1)
                                        : Qt.rgba(226/255, 229/255, 234/255, 1)
            FluShadow { radius: 6 }
        }

        contentItem: Column {
            spacing: 0

            // ===== 分类栏（Pivot 风格）=====
            Item {
                id: emoTabContainer
                width: parent.width
                height: 34
                visible: root._emoticonPackages.length > 1
                // 滑动下划线的目标位置/宽度（由激活的 tab 项上报）
                property real indicatorX: 0
                property real indicatorW: 0
                property Item activeTabItem: null

                // 选中项主题色下划线：单一实例横移切换（Pivot 同款动效）
                Rectangle {
                    height: 3
                    radius: 1.5
                    y: parent.height - 3
                    x: emoTabContainer.indicatorX
                    width: emoTabContainer.indicatorW
                    color: FluTheme.primaryColor
                    visible: emoTabContainer.activeTabItem !== null

                    Behavior on x {
                        NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
                    }
                    Behavior on width {
                        NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
                    }
                }

                // 分类横向列表：超出宽度可拖动滚动
                ListView {
                    id: emoTabBar
                    anchors.fill: parent
                    orientation: ListView.Horizontal
                    clip: true
                    interactive: true
                    boundsBehavior: Flickable.StopAtBounds
                    spacing: 16
                    // 分类项：各表情包名（黄豆包 pkg_name 固定为 "emoji"，
                    // 通用/UP主/房间专属等为中文包名，由服务器返回）
                    model: root._emoticonPackages.map(function(p) { return p.pkgName })
                    // 列表横向拖动后下划线需跟随重算位置
                    onContentXChanged: {
                        if (emoTabContainer.activeTabItem) {
                            var pos = emoTabContainer.activeTabItem.mapToItem(emoTabContainer, 0, 0)
                            emoTabContainer.indicatorX = pos.x
                            emoTabContainer.indicatorW = emoTabContainer.activeTabItem.width
                        }
                    }

                    delegate: Item {
                        id: emoTabItem
                        width: emoTabText.width
                        height: emoTabBar.height
                        property bool activeTab: modelData === root._emoticonFilter

                        function updateIndicator() {
                            if (!emoTabItem.activeTab) return
                            emoTabContainer.activeTabItem = emoTabItem
                            var pos = emoTabItem.mapToItem(emoTabContainer, 0, 0)
                            emoTabContainer.indicatorX = pos.x
                            emoTabContainer.indicatorW = emoTabItem.width
                        }

                        onActiveTabChanged: updateIndicator()
                        Component.onCompleted: updateIndicator()
                        // 声明周期：激活项被销毁时清除引用，避免悬空
                        Component.onDestruction: {
                            if (emoTabContainer.activeTabItem === emoTabItem)
                                emoTabContainer.activeTabItem = null
                        }

                        FluText {
                            id: emoTabText
                            anchors.centerIn: parent
                            text: modelData
                            font: FluTextStyle.Body
                            color: {
                                if (emoTabItem.activeTab) return FluTheme.primaryColor
                                if (emoTabMouse.containsMouse) return FluTheme.fontPrimaryColor
                                return FluTheme.fontSecondaryColor
                            }
                        }

                        MouseArea {
                            id: emoTabMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root._emoticonFilter = modelData
                        }
                    }
                }
            }

            // ===== 表情网格 =====
            Item {
                width: parent.width
                height: parent.height - (parent.children[0].visible ? 34 : 0)

                // 空/加载中占位
                FluText {
                    visible: root._emoticonList.length === 0
                    anchors.centerIn: parent
                    text: root._emoticonsLoaded ? "本房间暂无可用表情" : "加载中..."
                    font: FluTextStyle.Caption
                    color: FluTheme.fontSecondaryColor
                }

                GridView {
                    id: emoGrid
                    anchors.fill: parent
                    visible: root._emoticonList.length > 0
                    clip: true
                    // 每行 6 格、格宽按面板宽度自适应：换分辨率/改缩放都不会
                    // 出现"右边空一条"或"最后被裁掉半格"
                    readonly property int columns: 6
                    cellWidth: Math.floor(width / columns)
                    cellHeight: cellWidth
                    model: root.filteredEmoticons()
                    boundsBehavior: Flickable.StopAtBounds

                    ScrollBar.vertical: FluScrollBar {
                        policy: ScrollBar.AsNeeded
                    }

                    delegate: Item {
                        width: emoGrid.cellWidth
                        height: emoGrid.cellHeight

                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: 2
                            radius: 4
                            color: emoMouse.containsMouse
                                   ? (FluTheme.dark ? "#40FFFFFF" : "#0F000000")
                                   : "transparent"
                        }

                        Image {
                            id: emoImage
                            anchors.centerIn: parent
                            // 通用/UP主/房间专属这类是整张贴图，铺满格子（只留 4px 边），
                            // 不再压在 48px——之前缩到 48 就只剩个轮廓；
                            // 黄豆类（pkg_name 固定 "emoji"）是文字小表情，放太大会糊，
                            // 维持略大于原尺寸即可。分类是分 Tab 显示的，不会大小参差
                            width: modelData.pkgName === "emoji"
                                   ? Math.min(parent.width - 20, 40)
                                   : Math.min(parent.width - 8, 68)
                            height: width
                            source: modelData.url
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                            cache: true
                        }

                        // 图片加载失败/URL 为空时降级显示触发词文本
                        // （发送凭 unique/触发词，不依赖图 URL 可用）
                        FluText {
                            anchors.centerIn: parent
                            visible: emoImage.status !== Image.Ready
                            text: modelData.text
                            font.pixelSize: 12
                            color: FluTheme.fontSecondaryColor
                        }

                        MouseArea {
                            id: emoMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                // 黄豆 emoji 包（pkg_name 固定为 "emoji"）：插入
                                // 输入框与文字混合编辑，回车一起发送（网页端同款；
                                // 此类表情 emoticon_unique 也非空，不能凭 unique 判断）
                                if (modelData.pkgName === "emoji") {
                                    var cur = danmakuInput.text
                                    // 40 字上限（触发词按字符数计）
                                    if (cur.length + modelData.text.length <= 40) {
                                        danmakuInput.text = cur + modelData.text
                                        danmakuInput.cursorPosition = danmakuInput.text.length
                                        // 面板保持打开便于连续插入多个 emoji；
                                        // 点击面板外自然关闭
                                        danmakuInput.forceActiveFocus()
                                    }
                                } else {
                                    // 大表情（通用/UP主/房间专属等）：点击即发送
                                    emoticonPopup.close()
                                    root.sendLiveEmoticon(modelData.unique, modelData.text)
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
            // 跟主题走：暗色 43,43,43 / 亮色纯白，配方与 FluPopup 自带背景一致。
            // 原先是固定 #2B2B2B，亮色主题下就是一块黑板
            color: FluTheme.dark ? Qt.rgba(43/255, 43/255, 43/255, 1)
                                 : Qt.rgba(1, 1, 1, 1)
            FluShadow { radius: 5 }
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
                color: FluTheme.fontPrimaryColor
            }

            // 音量条：与视频播放页同款，直接用 FluentUI 的垂直 Slider。
            // 高度按剩余空间算——Column 不拉伸子项，而垂直 FluSlider 的
            // implicitHeight 固定 180，塞进 160 高的弹层会顶掉上面的百分比
            FluSlider {
                id: volumeSlider
                anchors.horizontalCenter: parent.horizontalCenter
                width: 32
                height: Math.max(80, parent.height - parent.topPadding
                                    - parent.bottomPadding
                                    - volumePercent.height - parent.spacing)
                orientation: Qt.Vertical
                from: 0
                to: 1
                stepSize: 0.01
                value: root.volume
                tooltipEnabled: false
                onMoved: root.volume = value
            }
        }
    }

    // ===== 播放设置面板（右侧抽屉）=====
    // 与视频播放页同款：右侧滑入、同宽（由 openSettingsSheet() 设成 360）、
    // 同样的左侧圆角与阴影。弹幕设置与视频信息合并到这里，控制栏只留一个设置键
    FluSheet {
        id: settingsSheet
        title: "设置"
        // Right 模式下 size 表示宽度，openSettingsSheet() 打开时会再校正一次
        size: 360

        // 背景与视频播放页的设置/简介抽屉一致：只圆左侧两角（右边缘贴着
        // 窗口边，右上/右下若也圆会露出下面的遮罩），阴影半径跟着圆角走
        background: Rectangle {
            radius: Theme.radiusMedium
            topLeftRadius: Theme.radiusMedium
            bottomLeftRadius: Theme.radiusMedium
            topRightRadius: 0
            bottomRightRadius: 0
            border.width: 1
            border.color: FluTheme.dark
                          ? (Window.active ? Qt.rgba(55/255, 55/255, 55/255, 1)
                                           : Qt.rgba(45/255, 45/255, 45/255, 1))
                          : Qt.rgba(226/255, 229/255, 234/255, 1)
            color: FluTheme.dark
                   ? (Window.active ? Qt.rgba(38/255, 44/255, 54/255, 1)
                                    : Qt.rgba(39/255, 39/255, 39/255, 1))
                   : Qt.rgba(251/255, 251/255, 253/255, 1)
            FluShadow { radius: Theme.radiusMedium }
        }

        Flickable {
            id: settingsFlick
            anchors.fill: parent
            anchors.leftMargin: 16
            anchors.rightMargin: 8
            // 顶部留 12：第一条是分组分隔线，贴着头部的标题会显得粘在一起
            anchors.topMargin: 12
            anchors.bottomMargin: 16
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            contentWidth: width
            contentHeight: settingsCol.implicitHeight
            ScrollBar.vertical: FluScrollBar { policy: ScrollBar.AsNeeded }

            ColumnLayout {
                id: settingsCol
                width: settingsFlick.width - 12
                spacing: 12

                // ---------- 弹幕 ----------
                // 分隔线放在分组标题**上方**：标题与它下面的各设置项属于同一组，
                // 线只负责和上一组隔开。原来线在标题下面，等于把标题孤立出去
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 1
                    color: FluTheme.dividerColor
                }

                FluText {
                    text: "弹幕"
                    font: FluTextStyle.Subtitle
                    color: FluTheme.fontPrimaryColor
                }

                // 弹幕总开关
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12

                    FluText {
                        text: "显示弹幕"
                        font: FluTextStyle.Body
                        color: FluTheme.fontPrimaryColor
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                    }

                    FluToggleSwitch {
                        checked: root.danmakuEnabled
                        clickListener: function() { root.danmakuEnabled = !root.danmakuEnabled }
                    }
                }

                // 弹幕帧率限制（高刷屏节流档位；60Hz 屏不节流，禁用）。
                // 与视频播放页共用同一 FramePacer 档位，但持久化键独立
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12

                    FluText {
                        text: "弹幕帧率限制"
                        font: FluTextStyle.Body
                        color: FluTheme.fontPrimaryColor
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                        opacity: liveDanmakuFpsCombo.enabled ? 1.0 : 0.4
                    }

                    FluComboBox {
                        id: liveDanmakuFpsCombo
                        Layout.preferredWidth: 132
                        // DWM 权威刷新率（Screen.refreshRate 高刷屏常误报 60）
                        readonly property real refreshRate: FramePacer.refreshRate
                        readonly property var optionValues: {
                            // 等于刷新率的档位与"不限制"功能等价（vsync 钳制渲染
                            // 上限即刷新率），严格过滤掉，避免出现冗余选项
                            var vals = [60, 100, 120, 144].filter(
                                function(r) { return r < refreshRate - 1 })
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
                    spacing: 12

                    FluText {
                        text: "描边样式"
                        font: FluTextStyle.Body
                        color: FluTheme.fontPrimaryColor
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                    }

                    FluComboBox {
                        Layout.preferredWidth: 132
                        model: ["描边", "重墨", "45°投影"]
                        currentIndex: root.danmakuOutlineStyle
                        onActivated: function(index) {
                            root.danmakuOutlineStyle = index
                            savePlayerSettings()
                        }
                    }
                }

                // 弹幕大小
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 4

                    FluText {
                        text: "弹幕大小"
                        font: FluTextStyle.Body
                        color: FluTheme.fontPrimaryColor
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

                // 不透明度
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 4

                    FluText {
                        text: "不透明度"
                        font: FluTextStyle.Body
                        color: FluTheme.fontPrimaryColor
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

                // 显示范围
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 4

                    FluText {
                        text: "显示范围"
                        font: FluTextStyle.Body
                        color: FluTheme.fontPrimaryColor
                    }

                    FluRadioButtons {
                        orientation: Qt.Horizontal
                        currentIndex: root.danmakuRangeIndex
                        onCurrentIndexChanged: root.danmakuRangeIndex = currentIndex

                        FluRadioButton { text: "1/4屏" }
                        FluRadioButton { text: "半屏" }
                        FluRadioButton { text: "3/4屏" }
                        FluRadioButton { text: "全屏" }
                    }
                }

                // 弹幕速度
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 4

                    FluText {
                        text: "弹幕速度"
                        font: FluTextStyle.Body
                        color: FluTheme.fontPrimaryColor
                    }

                    FluRadioButtons {
                        orientation: Qt.Horizontal
                        currentIndex: root.danmakuSpeedIndex
                        onCurrentIndexChanged: root.danmakuSpeedIndex = currentIndex

                        FluRadioButton { text: "慢" }
                        FluRadioButton { text: "中" }
                        FluRadioButton { text: "快" }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 1
                    color: FluTheme.dividerColor
                }

                // ---------- 视频信息 ----------
                // 打开后播放器右下角叠加实时流参数（分辨率/编码/码率），
                // 打开时先同步刷新一次，避免出现"先空一下再出数"
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12

                    FluText {
                        text: "视频信息"
                        font: FluTextStyle.Body
                        color: FluTheme.fontPrimaryColor
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                    }

                    FluToggleSwitch {
                        checked: root.showVideoInfo
                        clickListener: function() {
                            root.refreshVideoInfo()
                            root.showVideoInfo = !root.showVideoInfo
                        }
                    }
                }

                // 底部留白：最后一项贴着窗口下沿会显得很挤
                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 8
                }
            }
        }
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
