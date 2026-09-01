import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import QtQuick.Window 2.15
import QtQuick.Effects

import FluentUI 1.0
import BiliQt 1.0
import "../components"

FluPage {
    id: dynamic_page
    title: ""
    launchMode: FluPageType.SingleInstance

    FluInfoBar {
        id: infoBar
        root: dynamic_page
    }

    property bool videoVisible: false
    property bool liveVisible: false

    // 页面状态
    property bool _pageReady: false
    property int _pivotIndex: 0
    property var currentUpMid: 0   // 0 表示全部动态
    property string currentUpName: "全部动态"
    property string currentUpFace: ""

    // 动态详情
    property var currentDynamic: null
    property bool detailVisible: false
    property ListModel detailCommentModel: ListModel {}
    property bool detailCommentSortByHeat: true
    property int detailCommentPage: 1
    property int detailCommentTotal: 0
    property bool detailCommentHasNextPage: true
    property bool detailCommentLoadingMore: false

    // 左侧 UP 主列表
    ListModel { id: upListModel }
    // 综合动态列表
    ListModel { id: feedModel }

    // 视频卡片布局参数（与 SearchPage / RecommendPage 一致）
    property int cardWidth: Theme.cardWidth
    property int margins: Theme.pageMargins
    property int vSpacing: Theme.pageVSpacing
    property int minHSpacing: Theme.pageHSpacing
    property int pageSize: Theme.pageSize

    property bool loading: false
    property bool hasMore: true
    property bool _loginWarnShown: false
    property string videoOffset: ""
    property string feedOffset: ""
    property int videoPageNumber: 1
    property int _nextVideoPageNumber: 1
    property bool _scrollRestored: false
    property real _lastContentY: 0
    property var _pendingSelectUp: null
    property int _autoLoadCount: 0
    property int _feedAutoLoadCount: 0

    // 关注列表分页状态（/x/relation/followings 接口，每页 50 条）
    property int _followingsPage: 0
    property int _followingsTotal: -1
    property int _followingsGeneration: 0  // 每次 loadUpList 递增，用于丢弃过期的分页响应

    // 动态详情图片预览
    property bool detailImagePreviewVisible: false
    property var detailPreviewImages: []
    property int detailPreviewIndex: 0

    Timer {
        id: selectUpTimer
        interval: 150
        repeat: false
        onTriggered: {
            if (!_pendingSelectUp) return
            var mid = _pendingSelectUp.mid
            _pendingSelectUp = null
            loadVideos(mid)
            loadFeed(mid)
        }
    }

    function _sizeValid() {
        return dynamic_page.width > 0 && dynamic_page.height > 0
    }

    function showLoginWarning() {
        if (!_loginWarnShown && dynamic_page.visible) {
            _loginWarnShown = true
            infoBar.showWarning("请先登录")
        }
    }

    Component.onCompleted: {
        _pageReady = true
        loadUpList()
        loadVideos(currentUpMid)
        loadFeed(currentUpMid)
    }

    onVisibleChanged: {
        if (!visible) {
            // 小窗模式：pageStack.visible=false 使 visible 从父级"流动"为 false
            //（Qt 语义：父项 visible 变化会直接改变全部子孙的 visible 值并触发
            //  visibleChanged），非真实切页，绝不能关闭直播播放器
            if (App.miniPlayerMode) return
            _loginWarnShown = false
            // 切到其他导航页时关闭直播播放器，避免声音串扰
            if (liveVisible) closeLiveRoom()
        }
    }

    function loadUpList() {
        // 登录时使用 /x/relation/followings 接口获取完整关注列表（支持分页）
        // 未登录时回退到 uplist 接口（会触发登录提示）
        if (Login.isLoggedIn) {
            _followingsGeneration++
            _followingsPage = 0
            _followingsTotal = -1
            upListModel.clear()
            _loadFollowingsPage(1)
        } else {
            Api.getDynamicUpList()
        }
    }

    function _loadFollowingsPage(pn) {
        _followingsPage = pn
        Api.getFollowings(pn, 50)
    }

    function parseFollowings(data) {
        var respGen = _followingsGeneration
        var doc = JSON.parse(data)
        if (doc.code !== 0) {
            console.warn("[DynamicPage] getFollowings error:", doc.code, doc.message)
            // 回退到 uplist 接口
            Api.getDynamicUpList()
            return
        }
        var list = (doc.data && doc.data.list) ? doc.data.list : []
        var total = (doc.data && doc.data.total !== undefined) ? doc.data.total : 0
        _followingsTotal = total

        for (var i = 0; i < list.length; i++) {
            var item = list[i]
            upListModel.append({
                mid: Number(item.mid) || 0,
                name: item.uname || "",
                face: item.face || "",
                hasUpdate: false
            })
        }

        // 代次检查：如果在解析期间又触发了新的 loadUpList，丢弃后续分页
        if (respGen !== _followingsGeneration) {
            return
        }
        // 还有更多，继续加载下一页
        var loadedCount = upListModel.count
        if (list.length > 0 && loadedCount < total) {
            _loadFollowingsPage(_followingsPage + 1)
        }
    }

    function loadVideos(mid) {
        loading = true
        videoOffset = ""
        videoPageNumber = 1
        _nextVideoPageNumber = 1
        _autoLoadCount = 0
        if (mid === 0) {
            Api.getDynamicVideos("", pageSize, 0)
        } else {
            Api.getUserUploadedVideos(String(mid), videoPageNumber, pageSize)
        }
    }

    function loadMoreVideos() {
        if (loading || !hasMore) return
        loading = true
        if (Number(currentUpMid) === 0) {
            Api.getDynamicVideos(videoOffset, pageSize, 0)
        } else {
            _nextVideoPageNumber = videoPageNumber + 1
            Api.getUserUploadedVideos(String(currentUpMid), _nextVideoPageNumber, pageSize)
        }
    }

    function loadFeed(mid) {
        feedModel.clear()
        feedOffset = ""
        hasMore = true
        loading = true
        _feedAutoLoadCount = 0
        Api.getDynamicArticleList("", pageSize, mid)
    }

    function loadMoreFeed() {
        if (loading || !hasMore) return
        loading = true
        Api.getDynamicArticleList(feedOffset, pageSize, currentUpMid)
    }

    function selectUp(mid, name, face) {
        var midNum = Number(mid)
        if (Number(currentUpMid) === midNum) return
        currentUpMid = midNum
        currentUpName = name
        currentUpFace = face || ""
        _pendingSelectUp = { mid: midNum, name: name, face: face }
        selectUpTimer.restart()
    }

    function parseDynamicUpList(data) {
        var doc = JSON.parse(data)
        if (doc.code !== 0) {
            console.warn("getDynamicUpList error:", doc.message)
            var msg = doc.message || ""
            if (doc.code === -101 || msg.indexOf("未登录") >= 0 || msg.indexOf("账号未登录") >= 0) {
                showLoginWarning()
            }
            return
        }
        upListModel.clear()
        var items = doc.data && doc.data.items ? doc.data.items : []
        for (var i = 0; i < items.length; i++) {
            var item = items[i]
            upListModel.append({
                mid: Number(item.mid) || 0,
                name: item.uname || "",
                face: item.face || "",
                hasUpdate: item.has_update || false
            })
        }
    }

    function parseDynamicVideos(data) {
        var doc = JSON.parse(data)
        if (doc.code !== 0) {
            console.warn("getDynamicVideos error:", doc.message)
            var msg = doc.message || ""
            if (doc.code === -101 || msg.indexOf("未登录") >= 0 || msg.indexOf("账号未登录") >= 0) {
                showLoginWarning()
            }
            loading = false
            return
        }
        loading = false
        if (videoOffset === "") {
            GlobalState.dynamicModel.clear()
        }
        var items = doc.data && doc.data.items ? doc.data.items : []
        for (var i = 0; i < items.length; i++) {
            var item = items[i]
            var owner = item.owner || item.author || {}
            var stat = item.stat || {}
            GlobalState.dynamicModel.append({
                bvid: item.bvid || "",
                title: item.title || "",
                cover: item.pic || "",
                author: owner.name || owner.uname || "",
                views: formatNumber(stat.view || 0),
                danmakus: formatNumber(stat.danmaku || 0),
                duration: formatDuration(item.duration_text || item.duration || 0),
                pubDate: GlobalState.formatVideoCardTime(item.pubdate || 0)
            })
        }
        videoOffset = doc.data && doc.data.offset ? doc.data.offset : ""
        hasMore = (doc.data && doc.data.has_more) || false
    }

    function parseUserUploadedVideos(data) {
        var doc = JSON.parse(data)
        if (doc.code !== 0) {
            console.warn("getUserUploadedVideos error:", doc.message)
            loading = false
            return
        }
        loading = false
        videoPageNumber = _nextVideoPageNumber
        if (videoPageNumber <= 1) {
            GlobalState.dynamicModel.clear()
        }
        var archives = doc.data && doc.data.archives ? doc.data.archives : []
        for (var i = 0; i < archives.length; i++) {
            var item = archives[i]
            var owner = item.owner || item.author || {}
            var stat = item.stat || {}
            GlobalState.dynamicModel.append({
                bvid: item.bvid || "",
                title: item.title || "",
                cover: item.pic || "",
                author: owner.name || owner.uname || currentUpName,
                views: formatNumber(stat.view || 0),
                danmakus: formatNumber(stat.danmaku || 0),
                duration: formatDuration(item.duration_text || item.duration || 0),
                pubDate: GlobalState.formatVideoCardTime(item.pubdate || 0)
            })
        }
        var page = doc.data && doc.data.page ? doc.data.page : {}
        var count = page.count || 0
        var ps = page.ps || pageSize
        var totalPages = Math.ceil(count / ps)
        hasMore = archives.length > 0 && videoPageNumber < totalPages
    }

    function parseDynamicArticleList(data) {
        var doc = JSON.parse(data)
        if (doc.code !== 0) {
            console.warn("getDynamicArticleList error:", doc.message)
            var msg = doc.message || ""
            if (doc.code === -101 || msg.indexOf("未登录") >= 0 || msg.indexOf("账号未登录") >= 0) {
                showLoginWarning()
            }
            loading = false
            return
        }
        var items = doc.data && doc.data.items ? doc.data.items : []
        for (var i = 0; i < items.length; i++) {
            var item = items[i]
            if (!item.visible) continue
            var dynamic = parseDynamicItem(item)
            if (dynamic) {
                // ListModel 对数组/对象的 role 支持不稳定，序列化为 JSON 字符串
                dynamic.imageCount = dynamic.images ? dynamic.images.length : 0
                dynamic.videoCount = dynamic.videos ? dynamic.videos.length : 0
                dynamic.liveCount = dynamic.lives ? dynamic.lives.length : 0
                dynamic.hasForward = !!dynamic.forward
                dynamic.imagesJson = JSON.stringify(dynamic.images || [])
                dynamic.videosJson = JSON.stringify(dynamic.videos || [])
                dynamic.livesJson = JSON.stringify(dynamic.lives || [])
                dynamic.forwardJson = JSON.stringify(dynamic.forward || {})
                // ====== 对象/字典角色也 JSON.stringify 存储（ListModel 对嵌套对象 role 不稳定）======
                dynamic.emotesJson = JSON.stringify(dynamic.emotes || {})
                dynamic.jumpUrlsJson = JSON.stringify(dynamic.jumpUrls || {})
                dynamic.cardbgJson = JSON.stringify(dynamic.cardbg || { show: false, image: "", fanNumDesc: "", fanColor: "#FB7299" })
                dynamic.atListJson = JSON.stringify(dynamic.atList || [])
                dynamic.topicListJson = JSON.stringify(dynamic.topicList || [])
                dynamic.urlListJson = JSON.stringify(dynamic.urlList || [])
                // ====== 关键：QML ListModel.append(obj) 会尝试把 obj 的所有键都注册为 role，
                // 如果某 key 的 value 为 null，就触发警告：
                //   "Adding an object with a null member does not create a role for it."
                // parseDynamicItem 里只有 forward 初始化为 null（其他都是 []/{}/字符串/数字/布尔，不会是 null），
                // 所以只要把 forward 从 null 转成空对象 {}，就消除所有警告，
                // 同时不 delete 其他任何属性，保证 openDynamicDetail(itemData) 还能拿到完整嵌套数据。
                // （hasForward/forwardJson 已经预先保存了正确的值，把 forward=null 改成 {} 不影响任何 delegate 读取）
                if (dynamic.forward == null) dynamic.forward = {}
                feedModel.append(dynamic)
            }
        }
        feedOffset = (doc.data && doc.data.offset) ? doc.data.offset : ""
        hasMore = (doc.data && doc.data.has_more) || false
        loading = false
    }

    function parseDynamicItem(item, depth) {
        depth = depth || 0
        if (depth > 2) return null

        var result = {
            id_str: item.id_str || "",
            mid: 0,
            author: "",
            face: "",
            pendantImage: "",   // UP主头像框（装扮）
            verifyType: -1,     // 认证类型（-1=无, 0=个人, 1=机构）
            // 初始化完整 cardbg，show 强制 bool，避免 JSON.parse 回来后 show=undefined 导致 CommentCardBg 的 visible 赋值 bool 失败
            cardbg: { show: false, image: "", fanNumDesc: "", fanColor: "#FB7299" },
            time: "",
            content: "",
            emotes: {},         // 表情包字典：key = "[微笑]" value = {url, width, height}
            jumpUrls: {},       // 正文中的跳转链接：key = "AV号/BV号/话题词" value = 显示标题
            atList: [],         // biliuwp-lite ctrl/at_control 精准 @ 列表：[{text:"@用户", location:1, length:5}]
            topicList: [],      // rich_text_nodes 精准 #话题# 列表：[{text:"#xxx#", keyword:"xxx", jump_url:"...", location, length}]
            urlList: [],        // rich_text_nodes 精准 网页/抽奖 链接列表：[{text, jump_url, location, length}]
            images: [],
            videos: [],
            lives: [],
            forward: null,
            forwards: 0,
            comments: 0,
            likes: 0,
            likeState: false,
            commentId: "",
            commentType: 0,
            rid_str: "",
            rtype: 0
        }

        var basic = item.basic || {}
        result.rid_str = basic.rid_str || ""
        result.rtype = basic.rtype || 0

        var modules = item.modules || []
        for (var j = 0; j < modules.length; j++) {
            var module = modules[j]
            var moduleType = module.module_type || ""

            if (moduleType === "MODULE_TYPE_AUTHOR") {
                var authorData = module.module_author || {}
                var user = authorData.user || {}
                result.mid = user.mid || 0
                result.author = user.name || user.uname || ""
                result.face = user.face || ""
                result.time = authorData.pub_text || ""

                // ===== 头像框 pendant（装扮）=====
                if (user.pendant) {
                    result.pendantImage = user.pendant.image || user.pendant.img || ""
                }

                // ===== 认证信息 official（0=个人, 1=机构）=====
                // B站动态API中认证字段名为 user.official（非 official_verify）
                // 结构: { type: 0/1, desc: "...", role: 0/1/2/3 }
                var ov = user.official
                if (ov) {
                    result.verifyType = (ov.type !== undefined) ? Number(ov.type) : -1
                }

                // ===== 个性装扮 - 卡片背景 cardbg =====
                // 优先级 1：module_author.decorate_card（列表接口/详情接口 V2 新装扮字段，biliuwp-lite 用它 DecorateImage）
                //          结构：{ card_url, big_card_url, fan:{color, num_desc, is_fan, number}, card_type }
                var dcard = authorData.decorate_card
                if (dcard && typeof dcard === "object" && (dcard.card_url || dcard.fan)) {
                    var dcardFan = dcard.fan || {}
                    var showDecorate = !!(dcardFan.num_desc && String(dcardFan.num_desc) !== "")
                    var cardImage = dcard.card_url || dcard.big_card_url || dcard.image || ""
                    result.cardbg = {
                        show: showDecorate,
                        image: cardImage,
                        fanNumDesc: dcardFan.num_desc || "",
                        fanColor: dcardFan.color || "#FB7299"
                    }
                } else {
                    // 优先级 2：旧 user_sailing.cardbg / module_author.cardbg（与评论区一致）
                    var userSailing = user.user_sailing || user.sailing || {}
                    if (userSailing.cardbg) {
                        var cardbg = userSailing.cardbg
                        var fan = cardbg.fan || {}
                        result.cardbg = {
                            image: cardbg.image || "",
                            fanNumDesc: fan.num_desc || "",
                            fanColor: fan.color || "#FB7299",
                            show: !!(fan.num_desc && fan.num_desc !== "")
                        }
                    } else if (authorData.cardbg) {
                        var bg = authorData.cardbg
                        var fan2 = bg.fan || {}
                        result.cardbg = {
                            image: bg.image || "",
                            fanNumDesc: fan2.num_desc || "",
                            fanColor: fan2.color || "#FB7299",
                            show: !!(fan2.num_desc && fan2.num_desc !== "")
                        }
                    }
                }
            } else if (moduleType === "MODULE_TYPE_DESC") {
                var descData = module.module_desc || {}
                result.content = descData.text || ""

                // ===== 正文跳转链接 jump_urls（评论区是 content.jump_url，动态是 module_desc.jump_url / desc_url / orig_text_map 等）=====
                if (descData.jump_url) {
                    var jurls = descData.jump_url
                    if (typeof jurls === "object") {
                        var jkeys = Object.keys(jurls)
                        for (var jk = 0; jk < jkeys.length; jk++) {
                            var k = jkeys[jk]
                            var v = jurls[k]
                            if (v && typeof v === "object") {
                                result.jumpUrls[k] = v.title || v.desc || k
                            } else {
                                result.jumpUrls[k] = v || k
                            }
                        }
                    }
                }
                if (descData.desc_urls && descData.desc_urls.length) {
                    for (var du = 0; du < descData.desc_urls.length; du++) {
                        var u = descData.desc_urls[du] || {}
                        var origText = u.orig_text || u.text || ""
                        if (!origText) continue
                        result.jumpUrls[origText] = u.title || origText
                    }
                }

                // ====== 正文 @用户精准识别（V2 优先：rich_text_nodes）====================
                // B站V2动态接口现在把 @/链接/话题 全部塞在 descData.rich_text_nodes 数组里，
                // biliuwp-lite DynamicParseExtensions.HandelWordNodes 就是解析这个结构。
                // 常见字段组合（各版本API不完全一致，所以这里做全兼容）：
                //   node_type / type / NodeType          = "At" | "at" | 1
                //   text / raw_text / RawText / orig     = "@用户名"
                //   link / Link                          = 对象 {url, Link, pc_url, uid, mid}
                //                                        或 字符串 "https://space.bilibili.com/UID" / "bilibili://space/UID"
                //   position / offset / index / start    = 起始位置
                //   length / size / span / len           = 长度
                // =====================================================================
                var rtnForParse = descData.rich_text_nodes
                if (rtnForParse && typeof rtnForParse === "object" && rtnForParse.length != null) {
                    var rtnUidReg = /(?:space\.bilibili\.com\/|bilibili:\/\/space\/|bili:\/\/user\/|space\/)\/?(\d+)|^(\d+)$/i
                    // 另外，由于 rich_text_nodes 节点里没有显式的 position/length 字段（DESC_DEBUG 显示节点只带 orig_text/rid/text/type/jump_url），
                    // 我们只能"按节点 text 在 content 中顺序出现"推导位置：维护一个 searchFrom 游标，按顺序 indexOf 找下次出现位置，避免重复匹配。
                    var searchFrom = 0
                    for (var rpi = 0; rpi < rtnForParse.length; rpi++) {
                        var rn = rtnForParse[rpi] || {}
                        // 1) 找 type
                        var nt = (rn.node_type != null ? rn.node_type : (rn.NodeType != null ? rn.NodeType : (rn.type != null ? rn.type : null)))
                        var ntStr = nt != null ? String(nt) : ""
                        var ntNum = nt != null ? parseInt(nt) : NaN
                        var isAt = (ntStr === "At" || ntStr === "at" || ntStr === "RICH_TEXT_NODE_TYPE_AT" || ntNum === 1)
                        var isTopic = (ntStr === "Topic" || ntStr === "topic" || ntStr === "RICH_TEXT_NODE_TYPE_TOPIC")
                        // 2) 找 text（优先 orig_text，再 text；因为中奖场景等特殊格式，orig_text 更可靠）
                        var rt = ""
                        if (rn.orig_text != null && String(rn.orig_text).length > 0) rt = String(rn.orig_text)
                        else if (rn.orig != null && String(rn.orig).length > 0) rt = String(rn.orig)
                        else if (rn.text != null && String(rn.text).length > 0) rt = String(rn.text)
                        else if (rn.raw_text != null && String(rn.raw_text).length > 0) rt = String(rn.raw_text)
                        else if (rn.RawText != null && String(rn.RawText).length > 0) rt = String(rn.RawText)
                        else if (rn.orig_text != null && String(rn.orig_text).length > 0) rt = String(rn.orig_text)
                        if (!rt && rn.word && typeof rn.word === "object") {
                            if (rn.word.text != null) rt = String(rn.word.text)
                            else if (rn.word.raw_text != null) rt = String(rn.word.raw_text)
                        }
                        // 3) 找 link / uid
                        //    @节点：rid字段就是用户UID纯数字（DESC_DEBUG确认：{"orig_text":"@xxx","rid":"38089769","text":"@xxx","type":"RICH_TEXT_NODE_TYPE_AT"}）
                        //    话题节点：jump_url字段是 "//search.bilibili.com/all?keyword=xxx"
                        var rLinkRaw = null
                        if (rn.link != null) rLinkRaw = rn.link
                        else if (rn.Link != null) rLinkRaw = rn.Link
                        else if (rn.jump_url != null) rLinkRaw = rn.jump_url
                        else if (rn.url != null) rLinkRaw = rn.url
                        var rLinkStr = ""
                        var rUid = ""
                        if (rn.rid != null && String(rn.rid).length > 0) rUid = String(rn.rid)
                        if (rn.mid != null && !rUid) rUid = String(rn.mid)
                        if (rn.uid != null && !rUid) rUid = String(rn.uid)
                        if (typeof rLinkRaw === "string") {
                            rLinkStr = rLinkRaw
                        } else if (rLinkRaw && typeof rLinkRaw === "object") {
                            if (rLinkRaw.Link != null) rLinkStr = String(rLinkRaw.Link)
                            else if (rLinkRaw.link != null) rLinkStr = String(rLinkRaw.link)
                            else if (rLinkRaw.url != null) rLinkStr = String(rLinkRaw.url)
                            else if (rLinkRaw.pc_url != null) rLinkStr = String(rLinkRaw.pc_url)
                            if (!rUid && rLinkRaw.uid != null) rUid = String(rLinkRaw.uid)
                            if (!rUid && rLinkRaw.mid != null) rUid = String(rLinkRaw.mid)
                            if (!rUid && rLinkRaw.user_id != null) rUid = String(rLinkRaw.user_id)
                            if (!rUid && rLinkRaw.rid != null) rUid = String(rLinkRaw.rid)
                        }
                        // 从link字符串里提取UID（仅当rid没给时兜底）
                        if (!rUid && rLinkStr) {
                            var mt = rLinkStr.match(rtnUidReg)
                            if (mt) rUid = mt[1] || mt[2] || ""
                        }
                        // 【所有节点】的 jump_url / link 统一补 https 前缀：相对协议 // 开头、/ 开头（不是bili:///bilibili:///http(s):// 的都补）
                        // 这样互动抽奖的 //t.bilibili.com/lottery/... 变成 https://t.bilibili.com/lottery/... 才可以打开
                        var fixHttp = function(s) {
                            if (!s || typeof s !== "string") return s || ""
                            if (/^(https?:\/\/|bilibili:\/\/|bili:\/\/)/i.test(s)) return s
                            if (s.indexOf("//") === 0) return "https:" + s
                            if (s.indexOf("/") === 0) return "https://www.bilibili.com" + s
                            return s
                        }
                        rLinkStr = fixHttp(rLinkStr)
                        // 话题的 jump_url 也补全（上面 fixHttp 已处理，这里就不重复了）
                        // 4) 推 position + length
                        //    rich_text_nodes 没给 position，只能按顺序在 result.content 里找 text 的下一次出现位置
                        var rPos = -1
                        var rLen = rt ? rt.length : 0
                        if (rn.position != null) rPos = parseInt(rn.position)
                        else if (rn.offset != null) rPos = parseInt(rn.offset)
                        else if (rn.index != null) rPos = parseInt(rn.index)
                        else if (rn.start != null) rPos = parseInt(rn.start)
                        // 否则按顺序 indexOf 推导位置（不会后退，避免多个相同@用户名重复匹配错位）
                        if ((rPos < 0 || rPos >= result.content.length) && rt.length > 0) {
                            var tryIdx = result.content.indexOf(rt, searchFrom)
                            if (tryIdx < 0) tryIdx = result.content.indexOf(rt)
                            if (tryIdx >= 0) rPos = tryIdx
                        }
                        if (rPos >= 0 && rt.length > 0) {
                            searchFrom = rPos + rt.length
                        }
                        if (rn.length != null) rLen = parseInt(rn.length)
                        else if (rn.size != null) rLen = parseInt(rn.size)
                        else if (rn.span != null) rLen = parseInt(rn.span)
                        else if (rn.len != null) rLen = parseInt(rn.len)
                        else rLen = rt ? rt.length : 0
                        // 5) @节点 登记到 atList
                        if (isAt) {
                            var atStr2 = rt
                            var fromRtn = (rt.length > 0)
                            if (!atStr2 && rPos >= 0 && rLen > 0 && (rPos + rLen) <= result.content.length) {
                                atStr2 = result.content.substring(rPos, rPos + rLen)
                            }
                            if (atStr2) {
                                if (rPos < 0 || rPos + rLen > result.content.length) {
                                    var fidx = result.content.indexOf(atStr2)
                                    if (fidx >= 0) { rPos = fidx; rLen = atStr2.length }
                                }
                                result.atList.push({
                                    text: atStr2,
                                    _textFromCtrl: fromRtn,
                                    _source: "rich_text_nodes",
                                    type: 1,
                                    location: rPos,
                                    length: rLen,
                                    data: rUid || ""
                                })
                                result.jumpUrls[atStr2] = atStr2
                            }
                        } else if (isTopic) {
                            // 话题节点：登记到 jumpUrls（话题跳转），同时也登记到专门的 topicList 用于格式化替换
                            var tText = rt
                            if (!tText && rPos >= 0 && rLen > 0 && (rPos + rLen) <= result.content.length) {
                                tText = result.content.substring(rPos, rPos + rLen)
                            }
                            if (tText) {
                                // 从 jump_url 里解出 keyword：//search.bilibili.com/all?keyword=XXXX
                                var tKeyword = ""
                                try {
                                    var qIdx = rLinkStr.indexOf("?")
                                    if (qIdx >= 0) {
                                        var query = rLinkStr.substring(qIdx + 1)
                                        var pairs = query.split(/[&;]/)
                                        for (var qi = 0; qi < pairs.length; qi++) {
                                            var eq = pairs[qi].indexOf("=")
                                            if (eq < 0) continue
                                            var pk = pairs[qi].substring(0, eq)
                                            var pv = pairs[qi].substring(eq + 1)
                                            if (pk === "keyword") { tKeyword = decodeURIComponent(pv); break }
                                        }
                                    }
                                } catch(eqE) {}
                                result.topicList.push({
                                    text: tText,
                                    location: rPos,
                                    length: tText.length,
                                    keyword: tKeyword,
                                    jump_url: rLinkStr
                                })
                                // 也往 jumpUrls 登记一份，给后面逐字符扫描用
                                if (rLinkStr) result.jumpUrls[tText] = rLinkStr
                                else if (tKeyword) result.jumpUrls[tText] = tKeyword
                            }
                        } else {
                            // 其他带link节点：普通网页链接/互动抽奖/游戏详情页/视频外链 等
                            var rAnyText = rt.length > 0 ? rt : ""
                            if (!rAnyText && rPos >= 0 && rLen > 0 && (rPos + rLen) <= result.content.length) {
                                rAnyText = result.content.substring(rPos, rPos + rLen)
                            }
                            if (rAnyText && rLinkStr) {
                                result.jumpUrls[rAnyText] = rLinkStr
                                result.urlList.push({
                                    text: rAnyText,
                                    location: rPos,
                                    length: (rLen && rLen > 0 ? rLen : rAnyText.length),
                                    jump_url: rLinkStr
                                })
                            }
                        }
                    }
                }

                // ====== 正文 @用户精准识别（V1 兜底：ctrl/at_control）======================
                // 优先用 ctrl/at_control，把每个 Type=1(@) / Type=3(投票) 的登记到 atList
                var extendJson = descData.extend_json || {}
                if (typeof extendJson === "string") {
                    try { extendJson = JSON.parse(extendJson) } catch(e) { extendJson = {} }
                }
                var ctrlsRaw = null
                if (extendJson && extendJson.ctrl) ctrlsRaw = extendJson.ctrl
                else if (extendJson && extendJson.at_control) ctrlsRaw = extendJson.at_control
                else if (descData.ctrl) ctrlsRaw = descData.ctrl
                else if (descData.at_control) ctrlsRaw = descData.at_control
                if (typeof ctrlsRaw === "string") {
                    try { ctrlsRaw = JSON.parse(ctrlsRaw) } catch(e) { ctrlsRaw = null }
                }
                if (ctrlsRaw && ctrlsRaw.length) {
                    for (var ci = 0; ci < ctrlsRaw.length; ci++) {
                        var ctrlItem = ctrlsRaw[ci]
                        var cType = ctrlItem.type != null ? ctrlItem.type : ctrlItem.Type
                        var cLoc = ctrlItem.location != null ? ctrlItem.location : ctrlItem.Location
                        var cLen = ctrlItem.length != null ? ctrlItem.length : ctrlItem.Length
                        var cData = ctrlItem.data != null ? ctrlItem.data : ctrlItem.Data
                        // ====== 关键：ctrl[i].Text / .text（Bili API UserDynamicCtrlItem 直接给出原文）优先级最高 ======
                        // 因为 location/length 在某些特殊字符/表情后可能出现偏移（UTF-16 代理对），但 Text 字段永远是对的
                        var cText = ctrlItem.Text != null ? ctrlItem.Text
                                    : (ctrlItem.text != null ? ctrlItem.text : null)
                        cType = cType != null ? parseInt(cType) : -1
                        cLoc = cLoc != null ? parseInt(cLoc) : -1
                        cLen = cLen != null ? parseInt(cLen) : 0
                        // type=1 是 @用户；type=3 是 投票
                        if (cType === 1 || cType === 3) {
                            var atStr = ""
                            var fromCtrlText = false
                            if (cText != null && String(cText).length > 0) {
                                atStr = String(cText)
                                fromCtrlText = true
                            } else if (cLoc >= 0 && cLen > 0 && cLoc + cLen <= result.content.length) {
                                atStr = result.content.substring(cLoc, cLoc + cLen)
                            }
                            if (atStr) {
                                result.atList.push({
                                    text: atStr,
                                    _textFromCtrl: fromCtrlText,
                                    _source: "ctrl",
                                    type: cType,
                                    location: cLoc,
                                    length: cLen,
                                    data: cData != null ? String(cData) : ""
                                })
                                if (cType === 1) result.jumpUrls[atStr] = atStr
                            }
                        }
                    }
                }

                // ===== 表情包 emote（与评论区结构完全一致：content.emote）=====
                var emote = descData.emote || {}
                if (typeof emote === "object") {
                    // 用一个辅助函数登记，除原始 key 外，也登记 ev.emoji / ev.en / ev.name 作为备用 key（B 站不同版本 API 返回字段名不同）
                    var registerEmote = function(key, evv) {
                        if (!key || !evv || !evv.url) return
                        var metaSize2 = 0
                        if (evv.meta) {
                            var mss = evv.meta.size || 0
                            if (mss === 1) metaSize2 = 20
                            else if (mss === 2) metaSize2 = 36
                            else metaSize2 = 24
                        }
                        var eW = metaSize2 || evv.width || 24
                        var eH = metaSize2 || evv.height || 24
                        // 先剥掉 @xxx.png/@xxx 尺寸后缀，避免 RichText 再拼接一次；fixImageUrl 会处理 http→https
                        var rawUrl = evv.url || ""
                        var atIdx1 = rawUrl.indexOf("@")
                        var fixedSrc = atIdx1 >= 0 ? rawUrl.substring(0, atIdx1) : rawUrl
                        var entry = { text: key, url: fixedSrc, width: eW, height: eH }
                        if (!result.emotes[key]) result.emotes[key] = entry
                    }
                    var ekeys = Object.keys(emote)
                    for (var ek = 0; ek < ekeys.length; ek++) {
                        var et = ekeys[ek]
                        var ev = emote[et] || {}
                        registerEmote(et, ev)
                        // 额外的备用键：emote 对象里可能有 emoji / name / en 字段，都拿来再登记一次，提高命中率
                        if (ev.emoji) registerEmote(ev.emoji, ev)
                        if (ev.name) registerEmote(ev.name, ev)
                        if (ev.en) registerEmote(ev.en, ev)
                    }
                }
            } else if (moduleType === "MODULE_TYPE_STAT") {
                var statData = module.module_stat || {}
                result.comments = statData.comment && statData.comment.count ? statData.comment.count : 0
                result.forwards = statData.forward && statData.forward.count ? statData.forward.count : 0
                result.likes = statData.like && statData.like.count ? statData.like.count : 0
                result.likeState = statData.like && statData.like.like_state ? true : false
                if (statData.comment) {
                    result.commentId = statData.comment.comment_id || ""
                    result.commentType = statData.comment.comment_type || 0
                }
            } else if (moduleType === "MODULE_TYPE_DYNAMIC") {
                var dynamicData = module.module_dynamic || {}
                var dataType = dynamicData.type || ""
                if (dataType === "MDL_DYN_TYPE_DRAW") {
                    var draw = dynamicData.dyn_draw || {}
                    var drawItems = draw.items || []
                    for (var k = 0; k < drawItems.length; k++) {
                        result.images.push(drawItems[k].src || "")
                    }
                } else if (dataType === "MDL_DYN_TYPE_ARCHIVE") {
                    var archive = dynamicData.dyn_archive || {}
                    var archiveStat = archive.stat || {}
                    result.videos.push({
                        aid: archive.aid || "",
                        bvid: archive.bvid || "",
                        cover: archive.cover || "",
                        title: archive.title || "",
                        duration: archive.duration_text ? formatDuration(archive.duration_text) : "",
                        views: formatNumber(archiveStat.view || archiveStat.play || archiveStat.vt || 0),
                        danmakus: formatNumber(archiveStat.danmaku || archiveStat.danmaku_count || 0)
                    })
                } else if (dataType === "MDL_DYN_TYPE_LIVE_RCMD") {
                    var live = dynamicData.dyn_live_rcmd || {}
                    var cardInfo = live.card_info || {}
                    var livePlayInfo = cardInfo.live_play_info || {}
                    var watchedShow = livePlayInfo.watched_show || {}
                    result.lives.push({
                        roomId: String(livePlayInfo.room_id || ""),
                        cover: livePlayInfo.cover || "",
                        title: livePlayInfo.title || "",
                        parentArea: livePlayInfo.parent_area_name || "",
                        area: livePlayInfo.area_name || "",
                        streamer: result.author,
                        viewers: watchedShow.text_large || ""
                    })
                } else if (dataType === "MDL_DYN_TYPE_FORWARD") {
                    var forwardData = dynamicData.dyn_forward || {}
                    var forwardItem = forwardData.item
                    if (forwardItem) {
                        result.forward = parseDynamicItem(forwardItem, depth + 1)
                    }
                }
            }
        }

        return result
    }

    function formatDuration(seconds) {
        // 兼容 API 原始 duration_text 字符串（"MM:SS"/"H:MM:SS"，分钟可能超 60）与秒数，
        // 统一解析为秒数后按 HH:MM:SS / MM:SS 格式化
        var s = 0
        if (typeof seconds === "string" && seconds.indexOf(":") !== -1) {
            var parts = seconds.split(":")
            for (var i = 0; i < parts.length && i < 3; i++)
                s = s * 60 + (parseInt(parts[i], 10) || 0)
        } else {
            s = parseInt(seconds, 10) || 0
        }
        var h = Math.floor(s / 3600)
        var m = Math.floor((s % 3600) / 60)
        var sec = s % 60
        if (h > 0) {
            return h.toString().padStart(2, "0") + ":" + m.toString().padStart(2, "0") + ":" + sec.toString().padStart(2, "0")
        }
        return m.toString().padStart(2, "0") + ":" + sec.toString().padStart(2, "0")
    }

    function formatTime(timestamp) {
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
            var diff = Math.floor(now.getTime() / 1000) - timestamp
            if (diff < 60) return "刚刚"
            if (diff < 3600) return Math.floor(diff / 60) + "分钟前"
            return Math.floor(diff / 3600) + "小时前"
        }
        if (yesterday(now, date)) {
            return "昨天 " + hm
        }
        var mm = pad(date.getMonth() + 1)
        var dd = pad(date.getDate())
        if (date.getFullYear() !== now.getFullYear()) {
            return date.getFullYear() + "年" + mm + "月" + dd + "日 " + hm
        }
        return mm + "月" + dd + "日 " + hm
    }

    function formatNumber(num) {
        if (typeof num === "string") {
            var trimmed = num.trim()
            if (trimmed.indexOf("万") !== -1 || trimmed.indexOf("亿") !== -1) {
                return trimmed
            }
        }
        var n = parseInt(num, 10) || 0
        if (n >= 100000000) return (n / 100000000).toFixed(1) + "亿"
        if (n >= 10000) return (n / 10000).toFixed(1) + "万"
        return String(n)
    }

    // ========== 动态正文 HTML 渲染工具（参照 biliuwp-lite DynamicParseExtensions.UserDynamicStringToRichText 顺序和策略实现）==========
    // 处理顺序严格参考：escape → 换行 → 原始 URL(正则) → #话题# → AV/BV/CV 号 → @用户 → API 返回 jumpUrls → 表情
    function escapeHtml(str) {
        return String(str).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    }

    // 应用"文本替换规则"到 htmlText 上：pattern 匹配成功就替换为 replacement(htmlText, matchKey)
    // 使用逐字符扫描 + 最长优先匹配，**避免**已经生成的 HTML 片段（<span>、<img> 等）再次被误识别
    function _applyReplacements(htmlText, matchers) {
        var allKeys = []
        var i, k
        for (i = 0; i < matchers.length; i++) {
            var m = matchers[i]
            if (m.keys) {
                for (k = 0; k < m.keys.length; k++) allKeys.push({ key: m.keys[k], type: "static", matcher: m })
            }
            if (m.regexes) {
                for (k = 0; k < m.regexes.length; k++) allKeys.push({ regex: m.regexes[k], type: "regex", matcher: m })
            }
        }
        allKeys.sort(function(a, b) {
            // 静态 key 按长度降序；regex 放后面
            if (a.type === "static" && b.type === "static") return b.key.length - a.key.length
            if (a.type === "static") return -1
            if (b.type === "static") return 1
            return 0
        })
        var result = ""
        var pos = 0
        var text = String(htmlText || "")
        while (pos < text.length) {
            var matched = false
            // 1) 静态 key 匹配
            for (i = 0; i < allKeys.length; i++) {
                var ent = allKeys[i]
                if (ent.type === "static") {
                    if (text.substring(pos, pos + ent.key.length) === ent.key) {
                        result += ent.matcher.replace(ent.key, null)
                        pos += ent.key.length
                        matched = true
                        break
                    }
                }
            }
            if (matched) continue
            // 2) 正则匹配（只从 pos 位置开始）
            for (i = 0; i < allKeys.length; i++) {
                var ent2 = allKeys[i]
                if (ent2.type === "regex") {
                    var sub = text.substring(pos)
                    // 给正则加 ^ 锚点？不，直接用 exec 判断第一个捕获是否从 index=0 开始
                    var lastIndex = ent2.regex.lastIndex
                    ent2.regex.lastIndex = 0
                    var mm = ent2.regex.exec(sub)
                    ent2.regex.lastIndex = lastIndex
                    if (mm && mm.index === 0) {
                        result += ent2.matcher.replace(mm[0], mm)
                        pos += mm[0].length
                        matched = true
                        break
                    }
                }
            }
            if (matched) continue
            result += text[pos]
            pos++
        }
        return result
    }

    function formatDynamicContent(content, emotes, jumpUrls, atList, topicList, urlList, skipTimestamp) {
        // 顺序 1:1 对齐老项目 CommentPanel.formatCommentContent + biliuwp-lite HandelAtAndVote
        //   skipTimestamp: 动态卡片传 true（不识别00:00时间戳，不跳转播放器进度条）
        //                  评论区传 false/undefined（保留时间戳识别，跳转播放器）
        //   0. 保存未转义原始文本 origin
        //   0a. 网页/抽奖链接 精准替换（rich_text_nodes urlList）
        //   0b. #话题# 精准替换（rich_text_nodes topicList）
        //   1. @ + 投票（ctrl/at_control 先处理）
        //   2. 逐字符扫描 escape + jumpUrls
        //   3. 时间戳
        //   4. URL → 🔗网页链接（fallback正则）
        //   5. 表情 [xxx] → <img>
        //   6. 话题 #xxx# → 蓝字（fallback 正则）
        //   7. AV/BV/CV → 蓝字（fallback 正则）
        var origin = content || ""

        var input = origin

        // ==================================================================
        // 【统一精准替换总表：解决先替换后替换导致location错位！】
        // 所有rich_text_nodes + ctrl 给出的location/length 全是基于origin（纯文本原始内容）。
        // 如果我们先替换靠后的内容，input长度就会变长，靠前的替换虽然位置不受影响，但
        // 每个列表之间是独立排序的，比如 urlList(最靠后=331) → 然后topicList(最靠后=331右边没有)
        // → 然后atList(最靠后=280，在331左边，那在替换完331之后，280位置的input和origin的280位置还是一致的！)
        // 但为了 100% 绝对不出现任何错位，我们把所有精准替换生成一个 replacePlan，
        // 按全局 location 从大→小（从后往前）排序，再在同一个 input(初始就是 origin) 上执行。
        // ==================================================================
        var replacePlan = []

        // --- (A) 把 urlList 条目加入 replacePlan ---
        if (urlList && urlList.length > 0) {
            for (var uj = 0; uj < urlList.length; uj++) {
                var uJ = urlList[uj]
                var uLocJ = typeof uJ.location === "number" ? uJ.location : -1
                var uLenJ = typeof uJ.length === "number" ? uJ.length : (uJ.text ? String(uJ.text).length : 0)
                var udJ = ""
                if (uLocJ >= 0 && uLenJ > 0 && uLocJ + uLenJ <= origin.length) udJ = origin.substring(uLocJ, uLocJ + uLenJ)
                if (!udJ && uJ.text != null) udJ = String(uJ.text)
                if (!udJ) continue
                var looksLikeLongUrlJ = /^(https?:|ftp:|file:)\/\//i.test(udJ) || udJ.length > 40
                var uDisplayJ = looksLikeLongUrlJ ? "🔗网页链接" : udJ
                var uHrefJ = (uJ.jump_url && String(uJ.jump_url).length > 0) ? uJ.jump_url : udJ
                var uReplJ = '<a href="' + uHrefJ + '" style="text-decoration:none; color:#00A1D6;">' + dynamic_page.escapeHtml(uDisplayJ) + '</a>'
                replacePlan.push({
                    location: uLocJ, length: uLenJ, origText: udJ,
                    replacement: uReplJ, kind: "url",
                    debugSrc: "URL", debugOrig: udJ, debugDisp: uDisplayJ, debugJmp: uHrefJ
                })
            }
        }

        // --- (B) 把 topicList 条目加入 replacePlan ---
        if (topicList && topicList.length > 0) {
            for (var tj = 0; tj < topicList.length; tj++) {
                var tJ = topicList[tj]
                var tLocJ = typeof tJ.location === "number" ? tJ.location : -1
                var tLenJ = typeof tJ.length === "number" ? tJ.length : (tJ.text ? String(tJ.text).length : 0)
                var tdJ = ""
                if (tLocJ >= 0 && tLenJ > 0 && tLocJ + tLenJ <= origin.length) tdJ = origin.substring(tLocJ, tLocJ + tLenJ)
                if (!tdJ && tJ.text != null) tdJ = String(tJ.text)
                if (!tdJ) continue
                var tKeywordJ = tJ.keyword || ""
                var tHrefJ = ""
                if (tKeywordJ) tHrefJ = "bili://tag/" + encodeURIComponent(tKeywordJ)
                else if (tJ.jump_url) tHrefJ = tJ.jump_url
                else tHrefJ = "bili://tag/" + encodeURIComponent(tdJ.replace(/^#|#$/g, ""))
                var tReplJ = '<a href="' + tHrefJ + '" style="text-decoration:none; color:#00A1D6;">' + dynamic_page.escapeHtml(tdJ) + '</a>'
                replacePlan.push({
                    location: tLocJ, length: tLenJ, origText: tdJ,
                    replacement: tReplJ, kind: "topic",
                    debugSrc: "TOPIC", debugOrig: tdJ, debugKw: tKeywordJ, debugJmp: tJ.jump_url || ""
                })
            }
        }

        // --- (C) 把 atList 条目（type=1 @用户, type=3 投票）加入 replacePlan ---
        if (atList && atList.length > 0) {
            for (var cj = 0; cj < atList.length; cj++) {
                var cJ = atList[cj]
                var ctypeJ = parseInt(cJ.type)
                if (ctypeJ !== 1 && ctypeJ !== 3) continue
                var cLocJ = typeof cJ.location === "number" ? cJ.location : -1
                var cLenJ = typeof cJ.length === "number" ? cJ.length : 0
                var cdJ = ""
                if (cLocJ >= 0 && cLenJ > 0 && cLocJ + cLenJ <= origin.length) cdJ = origin.substring(cLocJ, cLocJ + cLenJ)
                if (!cdJ && cJ.text != null && String(cJ.text).length > 0) cdJ = String(cJ.text)
                if (!cdJ) continue
                var cReplJ = ""
                if (ctypeJ === 1) {
                    var cHrefJ = "bili://user/" + (cJ.data ? String(cJ.data) : "0")
                    cReplJ = '<a href="' + cHrefJ + '" style="text-decoration:none; color:#00A1D6;">' + dynamic_page.escapeHtml(cdJ) + '</a>'
                } else if (ctypeJ === 3) {
                    var voteHrefJ = "bili://vote/" + (cJ.data ? String(cJ.data) : "0")
                    cReplJ = '<a href="' + voteHrefJ + '" style="text-decoration:none; color:#00A1D6;">📊' + dynamic_page.escapeHtml(cdJ) + '</a>'
                }
                if (!cReplJ) continue
                replacePlan.push({
                    location: cLocJ, length: cLenJ, origText: cdJ,
                    replacement: cReplJ, kind: (ctypeJ === 1 ? "at" : "vote"),
                    debugSrc: (cJ._textFromCtrl ? (ctypeJ === 1 ? "@ctrlText" : "VOTEctrlText") : (ctypeJ === 1 ? "@" : "VOTE")),
                    debugOrig: cdJ, debugData: cJ.data ? String(cJ.data) : ""
                })
            }
        }

        // --- 全局按 location 从大→小排序（从后往前替换 → 前面的location永远不变！）---
        replacePlan.sort(function(a, b) {
            var la = typeof a.location === "number" ? a.location : -1
            var lb = typeof b.location === "number" ? b.location : -1
            if (la < 0 && lb >= 0) return 1
            if (lb < 0 && la >= 0) return -1
            // 同位置：按length大的先替换（防止大区间叠小区间时被覆盖）
            if (la === lb) {
                var la2 = typeof a.length === "number" ? a.length : 0
                var lb2 = typeof b.length === "number" ? b.length : 0
                return lb2 - la2
            }
            return lb - la
        })

        // --- 执行统一替换 ---
        var planApplied = 0
        for (var pi = 0; pi < replacePlan.length; pi++) {
            var P = replacePlan[pi]
            var PLoc = typeof P.location === "number" ? P.location : -1
            var PLen = typeof P.length === "number" ? P.length : 0
            // 如果 loc 无效（比如 rich_text_nodes 没给 position 只能靠 indexOf fallback 的时候），退化到 input.indexOf(origText) 找一次
            if (PLoc < 0) {
                if (!P.origText) continue
                var fpi = input.indexOf(P.origText)
                if (fpi < 0) continue
                PLoc = fpi
                PLen = P.origText.length
            }
            // 边界检查
            if (PLoc < 0 || PLen <= 0 || PLoc + PLen > input.length) continue
            // 一致性检查：input 的 [PLoc, PLoc+PLen] 应该等于 P.origText（因为从后往前替换，当前位置后面的还没被替换过！前面的替换都在更大的loc上）
            var actualIn = input.substring(PLoc, PLoc + PLen)
            var effectiveRepl = P.replacement
            var expectedText = P.origText
            if (actualIn !== expectedText) {
                // 极少见冲突：比如两个词条完全重叠（理论上全局排序+length大的先已处理），就跳过
                console.warn("[DynamicPage] replacePlan mismatch at loc=", PLoc,
                             "input=", JSON.stringify(actualIn), "expected=", JSON.stringify(expectedText),
                             "kind=", P.kind, "skip.")
                continue
            }
            input = input.substring(0, PLoc) + effectiveRepl + input.substring(PLoc + PLen)
            planApplied++
        }

        // 如果没有任何精准替换，@需要走fallback正则（老分支）
        var hasAtCtrl = atList && atList.length > 0
        if (!(hasAtCtrl && planApplied > 0)) {
            // fallback 正则（跟原来一样，只有当没有精准atList时才触发）
            // 严格匹配规则：
            // 1) @ 后面必须紧跟"合法用户名首字符集"（字母/数字/下划线/汉字/日文假名/中点·/连字符-），其他字符绝不匹配
            // 2) 贪心匹配后做"两层截短"：
            //    a) 黑尾词截短：结尾落在 "等/位/同/学/名/单/中/奖/公/告/好/评/的/们/说/和/与/及/或..." 就逐字往前截
            //    b) 数量词截短：结尾是"数字序列"(如10/20/100)，说明这是后面"等10位用户"的10，不属于用户名，往前截掉
            //       → 做法：黑尾词截完后，如果结尾最后连续字符全是数字，并且当前整个匹配还包含非数字用户名，就把数字尾巴再去掉
            //    c) 尾部分隔符清理：最后再剥掉末尾的 -·_ 这些"结尾非用户名合法字符"
            input = input.replace(/@[A-Za-z0-9_\u4e00-\u9fff\u3040-\u30ff·\-]+/g, function(full) {
                var blackEndWords = /(等|位|同|学|名|单|中|奖|公|告|好|评|的|们|说|和|与|及|或|都|也|去|在|是|有|要|不|还|就|个|组|队|群|人)$/
                var best = full
                var trimmed = full
                // Step a: 黑尾词逐字截短
                while (trimmed.length > 2 && blackEndWords.test(trimmed)) {
                    trimmed = trimmed.substring(0, trimmed.length - 1)
                }
                // Step b: 数字尾巴截短（等10位用户中奖场景 → 10属于数量词）
                if (trimmed.length > 2) {
                    var numTrimmed = trimmed
                    // 从末尾逐字截，只要最后一个字是数字就截，直到最后一个字非数字或只剩@1个字符
                    while (numTrimmed.length > 2 && /[0-9]$/.test(numTrimmed)) {
                        // 额外保护：如果剩下的除了@全是数字，就停（防止 @12345 这种纯数字用户名被截没）
                        var behindAt = numTrimmed.substring(1)
                        if (/^[0-9]+$/.test(behindAt)) break
                        numTrimmed = numTrimmed.substring(0, numTrimmed.length - 1)
                    }
                    if (numTrimmed.length >= 2 && numTrimmed.length < trimmed.length) {
                        trimmed = numTrimmed
                    }
                }
                if (trimmed.length >= 2 && trimmed.length < full.length) {
                    best = trimmed
                }
                // Step c: 剥掉末尾非用户名合法结尾字符（- · _）
                while (best.length > 2 && /[\-·_\s]$/.test(best)) best = best.substring(0, best.length - 1)
                return '<span style="color:#00A1D6;">' + best + '</span>'
            })
        }

        // ==================================================================
        // 2. 逐字符扫描：escapeHtml + jumpUrls 静态 key 替换（与老项目 CommentPanel.replaceJumpUrls 1:1）
        //    这样保证换行 \n 被原封不动保留、&<>"' 只在非 span 文本里转义
        // ==================================================================
        var resultHtml = ""
        var jumpKeys = jumpUrls ? Object.keys(jumpUrls) : []
        if (jumpKeys.length > 0) jumpKeys.sort(function(a, b) { return b.length - a.length })
        var pos = 0
        while (pos < input.length) {
            // 2.1 如果当前位置是我们刚插入的 <a ...><span...>xxx</span></a> 或 <span...>xxx</span> 标签结构，整段原样拷贝
            if (input.charCodeAt(pos) === 60 /*'<'*/) {
                if (input.substring(pos, pos + 2) === "<a") {
                    // 是 <a href="..."> 开头，找到 </a> 结束
                    var aEnd = input.indexOf("</a>", pos)
                    if (aEnd >= 0) {
                        resultHtml += input.substring(pos, aEnd + 4)
                        pos = aEnd + 4
                        continue
                    }
                } else if (input.substring(pos, pos + 5) === "<span") {
                    var closeEnd = input.indexOf("</span>", pos)
                    if (closeEnd >= 0) {
                        resultHtml += input.substring(pos, closeEnd + 7)
                        pos = closeEnd + 7
                        continue
                    }
                }
            }
            // 2.2 如果 jumpUrls 有匹配，直接染蓝（跳转链接、话题前缀等 API 直接登记的 key）
            var jumped = false
            for (var jki = 0; jki < jumpKeys.length; jki++) {
                var jkey = jumpKeys[jki]
                if (!jkey) continue
                if (input.substring(pos, pos + jkey.length) === jkey) {
                    var jtitle = jumpUrls[jkey] || jkey
                    var jhref = ""
                    // 如果 jumpUrls 的 value 是合法 URL/自定义协议，直接挂 a 链接打开；否则（与key相同，或纯标题）只高亮
                    if (typeof jumpUrls[jkey] === "string" && jumpUrls[jkey] !== jkey) {
                        if (/^(https?:\/\/|bilibili:\/\/|bili:\/\/)/.test(jumpUrls[jkey])) {
                            jhref = jumpUrls[jkey]
                        }
                    }
                    if (jhref) {
                        resultHtml += '<a href="' + jhref + '" style="text-decoration:none; color:#00A1D6;">' + dynamic_page.escapeHtml(jtitle) + '</a>'
                    } else {
                        resultHtml += '<span style="color:#00A1D6;">' + dynamic_page.escapeHtml(jtitle) + '</span>'
                    }
                    pos += jkey.length
                    jumped = true
                    break
                }
            }
            if (jumped) continue
            // 2.3 普通字符：只做 escapeHtml
            var ch = input[pos]
            if (ch === "&") resultHtml += "&amp;"
            else if (ch === "<") resultHtml += "&lt;"
            else if (ch === ">") resultHtml += "&gt;"
            else resultHtml += ch
            pos++
        }

        // ==================================================================
        // 3. 时间戳（与老项目 CommentPanel.replaceTimeStamps 相同，动态卡片不需要时跳过）
        // ==================================================================
        if (!skipTimestamp) {
            resultHtml = resultHtml.replace(/(\d{1,2}):(\d{2})(?::(\d{2}))?/g, function(match, p1, p2, p3) {
                if (p3 !== undefined && p3 !== "") {
                    var hh = parseInt(p1, 10), mm = parseInt(p2, 10), ss = parseInt(p3, 10)
                    if (hh >= 24 || mm >= 60 || ss >= 60) return match
                } else {
                    var mm2 = parseInt(p1, 10), ss2 = parseInt(p2, 10)
                    if (mm2 >= 60 || ss2 >= 60) return match
                }
                return '<span style="color:#00A1D6;">' + match + '</span>'
            })
        }

        // ==================================================================
        // 4. 原始 URL → 🔗网页链接（注意：只在 span 标签【外部】做扫描，避免破坏 span 内部文本）
        // ==================================================================
        function _replaceUrlsOutsideSpan(src) {
            var out = ""
            var p = 0
            var urlRe = /(https?|ftp|file):\/\/[A-Za-z0-9\-._~:/?#[\]@!$&'()*+,;=%-]+/g
            while (p < src.length) {
                if (src.charCodeAt(p) === 60 && src.substring(p, p + 5) === "<span") {
                    var ce = src.indexOf("</span>", p)
                    if (ce >= 0) {
                        out += src.substring(p, ce + 7)
                        p = ce + 7
                        continue
                    }
                }
                if (src.charCodeAt(p) === 60 && src.substring(p, p + 2) === "<a") {
                    var aEnd = src.indexOf("</a>", p)
                    if (aEnd >= 0) {
                        out += src.substring(p, aEnd + 4)
                        p = aEnd + 4
                        continue
                    }
                }
                urlRe.lastIndex = p
                var m = urlRe.exec(src)
                if (m && m.index === p) {
                    var fullUrl = m[0]
                    // 🔗网页链接：style 去掉下划线 + 指定颜色
                    out += '<a href="' + fullUrl + '" style="text-decoration:none; color:#00A1D6;">🔗网页链接</a>'
                    p += m[0].length
                    continue
                }
                out += src[p]
                p++
            }
            return out
        }
        resultHtml = _replaceUrlsOutsideSpan(resultHtml)

        // ==================================================================
        // 5. 表情 [xxx] → <img>（在 span 外部匹配；内部的比如 <span>文字[微笑]</span> 也要匹配，所以直接全局正则也 OK——表情 [xxx] 不会出现在标签名/属性里）
        // ==================================================================
        if (emotes) {
            resultHtml = resultHtml.replace(/\[[^\[\]]{1,40}\]/g, function(match) {
                var e = emotes[match]
                if (!e || !e.url) return match
                var size = e.width || 24
                if (size <= 0) size = 24
                var fixedUrl = GlobalState.fixImageUrl(e.url)
                return '<img src="' + fixedUrl + '" width="' + size + '" height="' + size + '" align="middle" style="vertical-align:middle;">'
            })
        }

        // ==================================================================
        // 6. #话题#（在 span 外部匹配）
        // ==================================================================
        function _replaceTagsOutsideSpan(src) {
            var out = ""
            var p = 0
            var tagRe = /#[^#\s][^#]*?#/g
            while (p < src.length) {
                if (src.charCodeAt(p) === 60 && src.substring(p, p + 5) === "<span") {
                    var ce = src.indexOf("</span>", p)
                    if (ce >= 0) {
                        out += src.substring(p, ce + 7)
                        p = ce + 7
                        continue
                    }
                }
                if (src.charCodeAt(p) === 60 && src.substring(p, p + 2) === "<a") {
                    var aEnd = src.indexOf("</a>", p)
                    if (aEnd >= 0) {
                        out += src.substring(p, aEnd + 4)
                        p = aEnd + 4
                        continue
                    }
                }
                if (src.charCodeAt(p) === 60 && src.substring(p, p + 4) === "<img") {
                    // 跳过 <img ...> 自闭合标签
                    var imgEnd = src.indexOf(">", p + 4)
                    if (imgEnd >= 0) {
                        out += src.substring(p, imgEnd + 1)
                        p = imgEnd + 1
                        continue
                    }
                }
                tagRe.lastIndex = p
                var m = tagRe.exec(src)
                if (m && m.index === p) {
                    // #话题#：style 去掉下划线 + 指定颜色
                    var tagContent = m[0].substring(1, m[0].length - 1)
                    var tagHref = "bili://tag/" + encodeURIComponent(tagContent)
                    out += '<a href="' + tagHref + '" style="text-decoration:none; color:#00A1D6;">' + m[0] + '</a>'
                    p += m[0].length
                    continue
                }
                out += src[p]
                p++
            }
            return out
        }
        resultHtml = _replaceTagsOutsideSpan(resultHtml)

        // ==================================================================
        // 7. AV/BV/CV（在 span 外部匹配）
        // ==================================================================
        function _replaceVideoIdsOutsideSpan(src) {
            var out = ""
            var p = 0
            var idRe = /\b([Bb][Vv][A-Za-z0-9]{8,}|[Aa][Vv]\d+|[Cc][Vv]\d+)\b/g
            while (p < src.length) {
                if (src.charCodeAt(p) === 60 && src.substring(p, p + 5) === "<span") {
                    var ce = src.indexOf("</span>", p)
                    if (ce >= 0) {
                        out += src.substring(p, ce + 7)
                        p = ce + 7
                        continue
                    }
                }
                if (src.charCodeAt(p) === 60 && src.substring(p, p + 2) === "<a") {
                    var aEnd = src.indexOf("</a>", p)
                    if (aEnd >= 0) {
                        out += src.substring(p, aEnd + 4)
                        p = aEnd + 4
                        continue
                    }
                }
                if (src.charCodeAt(p) === 60 && src.substring(p, p + 4) === "<img") {
                    var imgEnd = src.indexOf(">", p + 4)
                    if (imgEnd >= 0) {
                        out += src.substring(p, imgEnd + 1)
                        p = imgEnd + 1
                        continue
                    }
                }
                idRe.lastIndex = p
                var m = idRe.exec(src)
                if (m && m.index === p) {
                    // AV/BV/CV 号：style 去掉下划线 + 指定颜色
                    var vid = m[0]
                    out += '<a href="bili://video/' + vid + '" style="text-decoration:none; color:#00A1D6;">' + vid + '</a>'
                    p += m[0].length
                    continue
                }
                out += src[p]
                p++
            }
            return out
        }
        resultHtml = _replaceVideoIdsOutsideSpan(resultHtml)

        // ==================================================================
        // 8. 换行：QML Text.RichText 使用 QTextDocument HTML 4 解析器，源码中的 \n 默认只是
        //    普通空白字符（和空格合并），要真正换行必须用 HTML4 标签 <br>（不能自闭合 <br/>）。
        //    老项目 CommentPanel 之所以看起来 \n 生效，是因为其 escapeHtml 后 \n 没被处理，
        //    实际上 QTextDocument 对裸 \n 的处理并不稳定；此处统一把所有 \r\n/\n 转成 <br>。
        // ==================================================================
        resultHtml = resultHtml.replace(/\r\n/g, "<br>").replace(/\n/g, "<br>").replace(/\r/g, "<br>")

        return resultHtml
    }

    function openDynamicDetail(dynamic) {
        // 取消可能 pending 的关闭清理（关闭后 250ms 内又重开），避免清掉新数据
        detailCleanupTimer.stop()
        currentDynamic = dynamic
        detailCommentModel.clear()
        detailCommentTotal = 0
        detailCommentHasNextPage = true
        if (dynamic && dynamic.id_str) {
            Api.getDynamicDetail(dynamic.id_str)
        }
        detailVisible = true
        detailOverlay.doOpen()
    }

    function closeDynamicDetail() {
        detailVisible = false
        closeDetailImagePreview()
        detailOverlay.doClose()
        // 延迟到关闭动画结束后再清数据（动画 200ms，Timer 250ms 兜底）。
        // 立即清 currentDynamic=null 会让动画期间 FluImage source 变空 → 画面瞬间空白。
        // 延迟清理触发 pixmap 引用计数归零：
        // - currentDynamic=null：详情图片 FluImage source 解绑 → 原图解码位图可回收（9张4000x3000 ≈ 432MB）
        // - detailCommentModel.clear()：销毁评论 Repeater delegate → 评论图片 pixmap 引用归零（~77-154MB）
        // 之前需打开新详情页才会释放，改为关闭即释放，避免峰值跨详情页累积。
        detailCleanupTimer.restart()
    }

    // 详情页关闭后的数据清理定时器（等关闭动画结束）
    Timer {
        id: detailCleanupTimer
        interval: 250
        repeat: false
        onTriggered: {
            // 若期间又打开了新详情页，则跳过清理（openDynamicDetail 会 stop 本 timer）
            if (detailVisible) return
            currentDynamic = null
            detailCommentModel.clear()
            detailCommentTotal = 0
            detailCommentHasNextPage = true
            detailCommentPage = 1
            detailCommentSortByHeat = true
        }
    }

    function openDetailImagePreview(images, startIndex) {
        if (!images || images.length === 0) return
        detailPreviewImages = images
        detailPreviewIndex = Math.max(0, Math.min(startIndex, images.length - 1))
        detailImagePreviewVisible = true
    }

    function closeDetailImagePreview() {
        detailImagePreviewVisible = false
        detailPreviewImages = []
        detailPreviewIndex = 0
    }

    // ============================================================================
    // 富文本链接点击跳转辅助函数
    // 链接格式统一：
    //   bili://user/<MID>        → 切到"动态"标签页，选中该UP主并加载 ta 的视频+动态
    //   bili://tag/<话题文字>    → 预留：打开话题页（当前项目没有话题页，暂时弹提示）
    //   bili://video/<AV/BV号>  → 打开视频播放页（AV/BV/CV号）
    //   bili://vote/<投票ID>    → 预留：打开投票详情
    //   http(s)://...            → 用系统浏览器打开外链
    //   bilibili://...            → 用系统浏览器打开 B 站客户端协议
    // ============================================================================
    function openLinkHelper(rawHref) {
        if (!rawHref || String(rawHref).length === 0) return
        var href = String(rawHref).trim()
        try {
            // --- 1) bili://user/MID → 打开UP主动态页 ---
            if (href.indexOf("bili://user/") === 0) {
                var mid = href.substring("bili://user/".length)
                if (mid.indexOf("?") >= 0) mid = mid.substring(0, mid.indexOf("?"))
                if (mid.indexOf("#") >= 0) mid = mid.substring(0, mid.indexOf("#"))
                mid = String(parseInt(mid, 10))
                if (!mid || mid === "NaN" || mid === "0") {
                    infoBar.showWarning("无效的用户ID：" + rawHref)
                    return
                }
                // 1. 确保在"动态"导航页
                // main.qml 中 pageStack.currentIndex：0=视频 1=直播 2=动态 3=搜索 4=历史
                // 这里通过 window 顶层的 pageStack 切过去；找不到也没关系，至少加载UP主数据
                try {
                    var topWin = dynamic_page.Window ? dynamic_page.Window.window : null
                    if (topWin && topWin.pageStack) topWin.pageStack.currentIndex = 2
                    else if (window && window.pageStack) window.pageStack.currentIndex = 2
                } catch(ee) {}
                // 2. 找到匹配的UP主列表项（匹配成功会高亮选中），加载 ta 的视频+动态
                var matchIdx = -1
                for (var ui = 0; ui < dynamic_page.upListModel.count; ui++) {
                    var uitem = dynamic_page.upListModel.get(ui)
                    if (uitem && String(uitem.mid) === mid) { matchIdx = ui; break }
                }
                if (matchIdx >= 0) {
                    _pendingSelectUp = { mid: parseInt(mid, 10), index: matchIdx }
                    selectUpTimer.restart()
                } else {
                    // UP主不在关注列表里，也直接加载（视频/动态接口支持任意mid）
                    currentUpMid = parseInt(mid, 10)
                    loadVideos(currentUpMid)
                    loadFeed(currentUpMid)
                }
                infoBar.showInfo("跳转到UP主：mid=" + mid)
                return
            }
            // --- 2) bili://video/AV|BVID|CVxxx → 打开视频播放页 ---
            if (href.indexOf("bili://video/") === 0) {
                var vid = href.substring("bili://video/".length)
                infoBar.showInfo("准备打开：" + vid)
                try {
                    var playMgr = GlobalState ? GlobalState.playerManager : null
                    if (!playMgr) return
                    if (/^[Bb][Vv][A-Za-z0-9]{8,}$/.test(vid)) playMgr.openVideoByBvid(vid)
                    else if (/^[Aa][Vv]\d+$/.test(vid)) playMgr.openVideoByAid(vid.replace(/^[Aa][Vv]/, ""))
                    else if (/^[Cc][Vv]\d+$/.test(vid)) infoBar.showWarning("专栏暂不支持：" + vid)
                    else infoBar.showWarning("无效的视频ID：" + vid)
                } catch (eplay) { console.warn("[DynamicPage] open video failed:", eplay) }
                return
            }
            // --- 3) bili://tag/<话题> → 预留（暂不弹错误提示，避免点击话题没反应也提示）---
            if (href.indexOf("bili://tag/") === 0) {
                var tagRaw = decodeURIComponent(href.substring("bili://tag/".length))
                infoBar.showInfo("话题：" + tagRaw + "（话题页暂未实现）")
                return
            }
            // --- 4) bili://vote → 预留 ---
            if (href.indexOf("bili://vote/") === 0) {
                infoBar.showInfo("投票详情暂未实现")
                return
            }
            // --- 5) http/https / bilibili:// 其他协议 → 系统浏览器打开 ---
            if (href.indexOf("http://") === 0 || href.indexOf("https://") === 0
                || href.indexOf("bilibili://") === 0) {
                Qt.openUrlExternally(href)
                return
            }
            // --- 6) 兜底 ---
            console.warn("[DynamicPage] unrecognized link:", href)
        } catch (e) {
            console.warn("[DynamicPage] openLinkHelper exception:", e, "href:", href)
        }
    }

    function previewCurrentImageUrl() {
        var url = detailPreviewImages[detailPreviewIndex] || ""
        return GlobalState.fixImageUrl(url)
    }

    function previewCurrentImageIsAnimated() {
        var url = detailPreviewImages[detailPreviewIndex] || ""
        return GlobalState.isAnimatedImageUrl(url)
    }

    function previewNextImage() {
        var count = detailPreviewImages.length
        if (count <= 1) return
        detailPreviewIndex = (detailPreviewIndex + 1) % count
    }

    function previewPrevImage() {
        var count = detailPreviewImages.length
        if (count <= 1) return
        detailPreviewIndex = (detailPreviewIndex - 1 + count) % count
    }

    function parseDynamicDetail(data) {
        var doc = JSON.parse(data)
        if (doc.code !== 0) {
            console.warn("getDynamicDetail error:", doc.message)
            return
        }
        var item = doc.data && doc.data.item ? doc.data.item : {}
        if (!item) return
        var dynamic = parseDynamicItem(item)
        if (dynamic) {
            currentDynamic = dynamic
            loadDetailComments()
        }
    }

    function detailCommentOid() {
        if (!currentDynamic) return ""
        if (currentDynamic.commentId) return String(currentDynamic.commentId)
        if (currentDynamic.rid_str) return String(currentDynamic.rid_str)
        if (currentDynamic.videos && currentDynamic.videos.length > 0 && currentDynamic.videos[0].aid) {
            return String(currentDynamic.videos[0].aid)
        }
        return currentDynamic.id_str ? String(currentDynamic.id_str) : ""
    }

    function detailCommentType() {
        if (!currentDynamic) return 17
        if (currentDynamic.commentType) return currentDynamic.commentType
        if (currentDynamic.rtype === 1 || currentDynamic.rtype === 8) return 1
        if (currentDynamic.videos && currentDynamic.videos.length > 0) return 1
        if (currentDynamic.images && currentDynamic.images.length > 0) return 11
        return 17
    }

    function loadDetailComments() {
        var oid = detailCommentOid()
        var type = detailCommentType()
        if (!oid) return
        detailCommentModel.clear()
        detailCommentPage = 1
        detailCommentTotal = 0
        detailCommentLoadingMore = false
        detailCommentHasNextPage = true
        var sort = detailCommentSortByHeat ? 2 : 1
        CommentManager.getComments(oid, type, 1, 20, sort)
    }

    function loadDetailCommentsPage(page, count) {
        var oid = detailCommentOid()
        var type = detailCommentType()
        if (!oid) return
        if (detailCommentLoadingMore) return
        if (page < 1) page = 1
        detailCommentPage = page
        detailCommentLoadingMore = true
        var sort = detailCommentSortByHeat ? 2 : 1
        CommentManager.getComments(oid, type, page, count || 20, sort)
    }

    function detailCommentRequireLogin() {
        if (!Login.isLoggedIn) {
            showInfo("请先登录")
            return false
        }
        return true
    }

    function showInfo(msg) {
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Theme.homeFrameLeftMargin
        anchors.rightMargin: Theme.homeFrameRightMargin
        anchors.bottomMargin: Theme.homeFrameBottomMargin
        anchors.topMargin: Theme.homeFrameTopMargin
        spacing: 12

        // 左侧：UP 主列表
        FluFrame {
            id: leftFrame
            radius: Theme.frameRadius
            Layout.preferredWidth: 260
            Layout.fillHeight: true
            padding: 0

            ColumnLayout {
                anchors.fill: parent
                spacing: 0

                // 全部动态
                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 56

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 4
                        radius: 8
                        color: Number(currentUpMid) === 0 ? FluTheme.itemCheckColor : "transparent"
                        layer.enabled: Number(currentUpMid) === 0
                        layer.effect: MultiEffect {
                            shadowEnabled: true
                            shadowColor: "#80000000"
                            shadowOpacity: 0.25
                            shadowBlur: 0.6
                            shadowVerticalOffset: 2
                            shadowScale: 1
                        }
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.pageMargins
                        anchors.rightMargin: Theme.pageMargins
                        spacing: 12

                        Rectangle {
                            Layout.preferredWidth: 36
                            Layout.preferredHeight: 36
                            radius: 18
                            color: Theme.primary
                            clip: true

                            FluIcon {
                                anchors.centerIn: parent
                                iconSource: FluentIcons.AllApps
                                iconSize: 18
                                color: "white"
                            }
                        }

                        FluText {
                            Layout.fillWidth: true
                            text: "全部动态"
                            font: Theme.fontNormal
                            color: Number(currentUpMid) === 0 ? FluTheme.fontPrimaryColor : FluTheme.fontSecondaryColor
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: selectUp(0, "全部动态", "")
                    }
                }

                // UP 主列表
                ListView {
                    id: upListView
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: FluScrollBar {}

                    model: upListModel

                    delegate: Item {
                        width: upListView.width
                        height: 56

                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: 4
                            radius: 8
                            color: Number(model.mid) === Number(currentUpMid) ? FluTheme.itemCheckColor : "transparent"
                            layer.enabled: Number(model.mid) === Number(currentUpMid)
                            layer.effect: MultiEffect {
                                shadowEnabled: true
                                shadowColor: "#80000000"
                                shadowOpacity: 0.25
                                shadowBlur: 0.6
                                shadowVerticalOffset: 2
                                shadowScale: 1
                            }
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: Theme.pageMargins
                            anchors.rightMargin: Theme.pageMargins
                            spacing: 12

                            CircleAvatar {
                                Layout.preferredWidth: 36
                                Layout.preferredHeight: 36
                                source: model.face
                                placeholderText: model.name ? model.name.charAt(0) : ""
                            }

                            FluText {
                                Layout.fillWidth: true
                                text: model.name
                                font: Theme.fontNormal
                                color: Number(model.mid) === Number(currentUpMid) ? FluTheme.fontPrimaryColor : FluTheme.fontSecondaryColor
                                elide: Text.ElideRight
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: selectUp(model.mid, model.name, model.face)
                        }
                    }
                }
            }
        }

        // 右侧：Pivot 内容
        FluFrame {
            id: rightFrame
            radius: Theme.frameRadius
            Layout.fillWidth: true
            Layout.fillHeight: true
            padding: Theme.homeFramePadding

            ColumnLayout {
                anchors.fill: parent
                spacing: 0

                FluPivot {
                    id: pivot
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    anchors.leftMargin: Theme.pivotLeftMargin
                    font.pixelSize: FluTextStyle.Title.pixelSize * 2 / 3
                    currentIndex: dynamic_page._pivotIndex

                    onCurrentIndexChanged: {
                        if (dynamic_page._pageReady) {
                            dynamic_page._pivotIndex = currentIndex
                        }
                    }

                    // 视频页
                    FluPivotItem {
                        title: "视频"
                        contentItem: Component {
                            Item {
                                id: videoPageRoot
                                property int columns: Math.max(1, Math.floor((videoGrid.width + dynamic_page.minHSpacing) / (dynamic_page.cardWidth + dynamic_page.minHSpacing)))
                                property real cellWidth: columns > 1 ? videoGrid.width / columns : videoGrid.width
                                property real displayCardWidth: Math.max(1, cellWidth - dynamic_page.minHSpacing)

                                GridView {
                                    id: videoGrid
                                    anchors.fill: parent
                                    anchors.leftMargin: dynamic_page.margins
                                    anchors.rightMargin: dynamic_page.margins + 20
                                    anchors.topMargin: dynamic_page.margins
                                    anchors.bottomMargin: dynamic_page.margins
                                    clip: true
                                    boundsBehavior: Flickable.StopAtBounds
                                    ScrollBar.vertical: FluScrollBar {}

                                    model: GlobalState.dynamicModel
                                    cellWidth: Math.max(1, videoPageRoot.cellWidth)
                                    cellHeight: Math.max(1, videoPageRoot.displayCardWidth * Theme.cardAspectRatio + Theme.cardInfoHeight + dynamic_page.vSpacing)
                                    cacheBuffer: Math.max(0, videoGrid.height * 2)
                                    flow: GridView.LeftToRight
                                    layoutDirection: Qt.LeftToRight
                                    verticalLayoutDirection: GridView.TopToBottom

                                    onContentYChanged: {
                                        if (!dynamic_page.visible || dynamic_page.loading || !dynamic_page.hasMore) return
                                        if (contentHeight <= height) {
                                            if (dynamic_page._autoLoadCount < 3) {
                                                dynamic_page._autoLoadCount++
                                                dynamic_page.loadMoreVideos()
                                            }
                                            return
                                        }
                                        if (contentY + height >= contentHeight - videoGrid.height) {
                                            dynamic_page._autoLoadCount = 0
                                            dynamic_page.loadMoreVideos()
                                        }
                                    }

                                    delegate: Item {
                                        width: Math.max(1, videoPageRoot.cellWidth)
                                        height: Math.max(1, videoGrid.cellHeight)

                                        VideoCard {
                                            anchors.left: parent.left
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: Math.max(1, videoPageRoot.displayCardWidth - Theme.scrollBarReserve)
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

                                FluIconButton {
                                    width: 50
                                    height: 50
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    anchors.rightMargin: 20
                                    anchors.bottomMargin: 20
                                    iconSource: FluentIcons.Refresh
                                    iconSize: 20
                                    z: 1
                                    onClicked: {
                                        if (!dynamic_page.loading) {
                                            // 统一刷新左侧关注列表，便于登录后立即加载
                                            dynamic_page.loadUpList()
                                            dynamic_page.loadVideos(dynamic_page.currentUpMid)
                                            videoGrid.positionViewAtBeginning()
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // 综合页
                    FluPivotItem {
                        title: "综合"
                        contentItem: Component {
                            Item {
                                id: feedPageRoot

                                ListView {
                                    id: feedListView
                                anchors.fill: parent
                                anchors.leftMargin: dynamic_page.margins
                                anchors.rightMargin: dynamic_page.margins + 20
                                anchors.topMargin: dynamic_page.margins
                                anchors.bottomMargin: dynamic_page.margins
                                clip: true
                                boundsBehavior: Flickable.StopAtBounds
                                ScrollBar.vertical: FluScrollBar {}
                                spacing: Theme.spacingMedium

                                onContentYChanged: {
                                    if (!dynamic_page.visible || dynamic_page.loading || !dynamic_page.hasMore) return
                                    if (contentHeight <= height) {
                                        if (dynamic_page._feedAutoLoadCount < 3) {
                                            dynamic_page._feedAutoLoadCount++
                                            dynamic_page.loadMoreFeed()
                                        }
                                        return
                                    }
                                    if (contentY + height >= contentHeight - feedListView.height) {
                                        dynamic_page._feedAutoLoadCount = 0
                                        dynamic_page.loadMoreFeed()
                                    }
                                }

                                model: feedModel

                                delegate: Rectangle {
                                    width: Math.max(0, feedListView.width - Theme.scrollBarReserve)
                                    height: itemData ? feedCardColumn.height + Theme.spacingLarge * 2 : 0
                                    radius: Theme.radiusMedium
                                    color: FluTheme.itemNormalColor
                                    border.color: FluTheme.dividerColor
                                    border.width: 1
                                    visible: !!itemData

                                    property var itemData: model
                                    property var itemImages: itemData && itemData.imagesJson ? JSON.parse(itemData.imagesJson) : []
                                    property var itemVideos: itemData && itemData.videosJson ? JSON.parse(itemData.videosJson) : []
                                    property var itemLives: itemData && itemData.livesJson ? JSON.parse(itemData.livesJson) : []
                                    property var itemForward: itemData && itemData.forwardJson ? JSON.parse(itemData.forwardJson) : {}
                                    // ====== 表情/链接/装扮卡片背景 JSON→对象 ======
                                    property var itemEmotes: itemData && itemData.emotesJson ? JSON.parse(itemData.emotesJson) : {}
                                    property var itemJumpUrls: itemData && itemData.jumpUrlsJson ? JSON.parse(itemData.jumpUrlsJson) : {}
                                    property var itemCardbg: itemData && itemData.cardbgJson ? JSON.parse(itemData.cardbgJson) : { show: false, image: "", fanNumDesc: "", fanColor: "#FB7299" }
                                    property var itemAtList: itemData && itemData.atListJson ? JSON.parse(itemData.atListJson) : []
                                    property var itemTopicList: itemData && itemData.topicListJson ? JSON.parse(itemData.topicListJson) : []
                                    property var itemUrlList: itemData && itemData.urlListJson ? JSON.parse(itemData.urlListJson) : []
                                    property int itemImageCount: itemData ? itemData.imageCount : 0
                                    property int itemVideoCount: itemData ? itemData.videoCount : 0
                                    property int itemLiveCount: itemData ? itemData.liveCount : 0
                                    property bool itemHasForward: itemData ? itemData.hasForward : false
                                    property int itemForwardImageCount: itemHasForward && itemForward.images ? itemForward.images.length : 0
                                    property int itemForwardVideoCount: itemHasForward && itemForward.videos ? itemForward.videos.length : 0
                                    property int itemForwardLiveCount: itemHasForward && itemForward.lives ? itemForward.lives.length : 0
                                    // 转发卡片也有表情/链接：itemForward.emotes / itemForward.jumpUrls 直接从 forwardJson 里取（parseDynamicItem 里已经把 forward 的这几个字段一起保存了）

                                    // ====== 个性装扮（卡片右上角，装扮Y中心与UP主头像Y中心对齐）======
                                    // 注：必须放在 delegate Rectangle 直接子级（不要在 ColumnLayout 内部，否则 ColumnLayout 会接管布局+禁止anchors）
                                    // 垂直对齐计算：
                                    //   feedCardColumn anchors.margins = Theme.spacingLarge
                                    //   AvatarWithPendant avatarSize = 40 → 头像中心 Y = delegate.top + spacingLarge + 20
                                    //   CommentCardBg height=54 → 装扮中心 Y = topMargin + 27
                                    //   令两者相等：topMargin = spacingLarge + 20 - 27 = spacingLarge - 7
                                    CommentCardBg {
                                        anchors.top: parent.top
                                        anchors.right: parent.right
                                        anchors.topMargin: Theme.spacingLarge - 7
                                        // 用户要求"再往右挪一些"→减小margin；列表页装扮width=180，这里再减小8px让数字更靠右边
                                        anchors.rightMargin: Theme.spacingLarge + 2
                                        z: 3
                                        showNoPrefix: false
                                        numberPosition: "left"
                                        cardbg: {
                                            // 兜底：如果 JSON.parse 出来是空对象 {}，构造 show=false 的默认值，避免 CommentCardBg 里 visible = undefined 警告
                                            var c = itemCardbg
                                            if (!c || typeof c !== "object") {
                                                return { show: false, image: "", fanNumDesc: "", fanColor: "#FB7299" }
                                            }
                                            if (typeof c.show !== "boolean") {
                                                c.show = !!c.show
                                            }
                                            return c
                                        }
                                    }

                                    ColumnLayout {
                                        id: feedCardColumn
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.top: parent.top
                                        anchors.margins: Theme.spacingLarge
                                        spacing: Theme.spacingMedium

                                        // 头部：头像 + 用户名 + 时间
                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: Theme.spacingSmall
                                            // 右侧给装扮留空间（现在装扮 width=175 + 24px 额外间距），避免头像/昵称行与装扮重叠
                                            Layout.rightMargin: (itemCardbg && itemCardbg.show) ? 190 : 0

                                            // ====== 头像框 AvatarWithPendant（替代纯 CircleAvatar），与评论区一致 ======
                                            AvatarWithPendant {
                                                face: itemData ? itemData.face : ""
                                                pendantImage: (itemData && itemData.pendantImage) ? itemData.pendantImage : ""
                                                avatarSize: 40
                                                pendantScale: 1.5
                                                verifyType: itemData ? (itemData.verifyType || -1) : -1
                                                Layout.alignment: Qt.AlignTop
                                                placeholderText: itemData && itemData.author ? itemData.author.charAt(0) : ""
                                            }

                                            ColumnLayout {
                                                Layout.fillWidth: true
                                                spacing: 2

                                                FluText {
                                                    text: itemData ? itemData.author : ""
                                                    font: Theme.fontNormal
                                                    color: Theme.primary
                                                }

                                                FluText {
                                                    text: itemData ? itemData.time : ""
                                                    font: Theme.fontSmall
                                                    color: FluTheme.fontTertiaryColor
                                                }
                                            }
                                        }

                                        // 文本内容（RichText：@用户链接🔗/网页链接/话题/AV号/表情/换行 — 点击 @ 或链接会触发 onLinkActivated）
                                        FluText {
                                            Layout.fillWidth: true
                                            text: dynamic_page.formatDynamicContent(
                                                      itemData ? itemData.content : "",
                                                      itemEmotes,
                                                      itemJumpUrls,
                                                      itemAtList,
                                                      itemTopicList,
                                                      itemUrlList,
                                                      true /* skipTimestamp: 动态卡片不识别时间戳 */)
                                            font: Theme.fontNormal
                                            color: FluTheme.fontPrimaryColor
                                            textFormat: Text.RichText
                                            wrapMode: Text.Wrap
                                            maximumLineCount: 5
                                            elide: Text.ElideRight
                                            // 富文本链接点击处理（@用户跳转UP主主页/外链浏览器/视频AV号）
                                            // FluText 最终是 QtQuick Text 的封装，所以 onLinkActivated 信号存在；
                                            // 这里直接赋值给 DynamicPage 的公共 helper 函数即可。
                                            onLinkActivated: function(link) {
                                                dynamic_page.openLinkHelper(link)
                                            }
                                        }

                                        // 转发引用
                                        Rectangle {
                                            Layout.fillWidth: true
                                            Layout.preferredHeight: forwardColumn.implicitHeight + Theme.spacingMedium * 2
                                            color: FluTheme.frameColor
                                            radius: Theme.radiusSmall
                                            visible: itemHasForward
                                            border.color: FluTheme.dividerColor
                                            border.width: 1

                                            ColumnLayout {
                                                id: forwardColumn
                                                anchors.left: parent.left
                                                anchors.right: parent.right
                                                anchors.top: parent.top
                                                anchors.margins: Theme.spacingMedium
                                                spacing: Theme.spacingSmall

                                                // 转发作者
                                                RowLayout {
                                                    spacing: Theme.spacingSmall
                                                    // ====== 转发卡片同样支持头像框 ======
                                                    AvatarWithPendant {
                                                        face: itemHasForward ? itemForward.face : ""
                                                        pendantImage: (itemHasForward && itemForward.pendantImage) ? itemForward.pendantImage : ""
                                                        avatarSize: 28
                                                        pendantScale: 1.5
                                                        verifyType: itemHasForward ? (itemForward.verifyType || -1) : -1
                                                        placeholderText: itemHasForward && itemForward.author ? itemForward.author.charAt(0) : ""
                                                    }
                                                    FluText {
                                                        text: itemHasForward ? itemForward.author : ""
                                                        font: Theme.fontSmall
                                                        color: Theme.primary
                                                    }
                                                }

                                                // 转发内容（RichText：@/链接/表情 — 点击同样走跳转逻辑）
                                                FluText {
                                                    Layout.fillWidth: true
                                                    text: itemHasForward ? dynamic_page.formatDynamicContent(
                                                                              itemForward.content || "",
                                                                              itemForward.emotes || {},
                                                                              itemForward.jumpUrls || {},
                                                                              itemForward.atList || [],
                                                                              itemForward.topicList || [],
                                                                              itemForward.urlList || [],
                                                                              true /* skipTimestamp: 动态卡片不识别时间戳 */)
                                                                         : ""
                                                    font: Theme.fontSmall
                                                    color: FluTheme.fontPrimaryColor
                                                    textFormat: Text.RichText
                                                    wrapMode: Text.Wrap
                                                    maximumLineCount: 3
                                                    elide: Text.ElideRight
                                                    onLinkActivated: function(link) { dynamic_page.openLinkHelper(link) }
                                                }

                                                // 转发图片
                                                GridLayout {
                                                    Layout.fillWidth: false
                                                    Layout.alignment: Qt.AlignLeft
                                                    Layout.preferredWidth: forwardColumn.width * 2 / 3
                                                    columns: (itemForwardImageCount === 1) ? 1 : 3
                                                    rowSpacing: 4
                                                    columnSpacing: 4
                                                    visible: itemForwardImageCount > 0

                                                    Repeater {
                                                        model: itemForward.images

                                                        Rectangle {
                                                            id: forwardImageContainer
                                                            Layout.fillWidth: true
                                                            Layout.preferredHeight: width
                                                            radius: 6
                                                            color: FluTheme.frameColor
                                                            clip: true
                                                            layer.enabled: forwardImageContainer.width > 0 && forwardImageContainer.height > 0
                                                            layer.samples: 4
                                                            layer.effect: MultiEffect {
                                                                maskEnabled: true
                                                                maskSource: ShaderEffectSource {
                                                                    sourceItem: forwardImageMask
                                                                    hideSource: true
                                                                    live: true
                                                                }
                                                            }

                                                            property var imageUrl: modelData || ""
                                                            property bool singleImage: itemForwardImageCount === 1

                                                            Rectangle {
                                                                id: forwardImageMask
                                                                x: -10000
                                                                y: -10000
                                                                width: forwardImageContainer.width
                                                                height: forwardImageContainer.height
                                                                radius: forwardImageContainer.radius
                                                                color: "black"
                                                                visible: true
                                                            }

                                                            // 动图（.gif/.webp）用 AnimatedImage 播放，静态图用 FluImage
                                                            Loader {
                                                                anchors.fill: parent
                                                                sourceComponent: GlobalState.isAnimatedImageUrl(imageUrl) ? cardForwardAnimatedImage : cardForwardStaticImage
                                                            }

                                                            Component {
                                                                id: cardForwardStaticImage
                                                                FluImage {
                                                                    anchors.fill: parent
                                                                    source: forwardImageContainer.singleImage
                                                                                 ? GlobalState.fixImageUrl(forwardImageContainer.imageUrl, forwardImageContainer.width * Screen.devicePixelRatio, 0, false)
                                                                                 : GlobalState.fixImageUrl(forwardImageContainer.imageUrl, forwardImageContainer.width * Screen.devicePixelRatio, forwardImageContainer.height * Screen.devicePixelRatio, true)
                                                                    fillMode: forwardImageContainer.singleImage ? Image.PreserveAspectFit : Image.PreserveAspectCrop
                                                                    asynchronous: true
                                                                    cache: true
                                                                    smooth: true
                                                                    onSourceSizeChanged: {
                                                                        if (forwardImageContainer.singleImage && sourceSize.width > 0 && forwardImageContainer.width > 0) {
                                                                            forwardImageContainer.Layout.preferredHeight = forwardImageContainer.width * sourceSize.height / sourceSize.width
                                                                        }
                                                                    }
                                                                }
                                                            }

                                                            Component {
                                                                id: cardForwardAnimatedImage
                                                                AnimatedImage {
                                                                    anchors.fill: parent
                                                                    // fixImageUrl 对 .gif/.webp 返回原始 URL，保证动画可播放
                                                                    source: forwardImageContainer.singleImage
                                                                                 ? GlobalState.fixImageUrl(forwardImageContainer.imageUrl, forwardImageContainer.width * Screen.devicePixelRatio, 0, false)
                                                                                 : GlobalState.fixImageUrl(forwardImageContainer.imageUrl, forwardImageContainer.width * Screen.devicePixelRatio, forwardImageContainer.height * Screen.devicePixelRatio, true)
                                                                    fillMode: forwardImageContainer.singleImage ? Image.PreserveAspectFit : Image.PreserveAspectCrop
                                                                    cache: true
                                                                    smooth: true
                                                                    playing: true
                                                                    onSourceSizeChanged: {
                                                                        if (forwardImageContainer.singleImage && sourceSize.width > 0 && forwardImageContainer.width > 0) {
                                                                            forwardImageContainer.Layout.preferredHeight = forwardImageContainer.width * sourceSize.height / sourceSize.width
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }

                                                // 转发视频
                                                ColumnLayout {
                                                    Layout.fillWidth: false
                                                    Layout.preferredWidth: forwardColumn.width / 3
                                                    spacing: Theme.spacingSmall
                                                    visible: itemForwardVideoCount > 0

                                                    Repeater {
                                                        model: itemForward.videos

                                                        VideoCard {
                                                            Layout.fillWidth: true
                                                            Layout.preferredHeight: implicitHeight

                                                            property var videoData: modelData || {}

                                                            bvid: videoData.bvid || ""
                                                            title: videoData.title || ""
                                                            cover: videoData.cover || ""
                                                            author: itemHasForward && itemForward.author ? itemForward.author : ""
                                                            views: videoData.views || "0"
                                                            danmakus: videoData.danmakus || "0"
                                                            duration: videoData.duration || ""
                                                            pubDate: ""
                                                        }
                                                    }
                                                }

                                                // 转发直播
                                                ColumnLayout {
                                                    Layout.fillWidth: false
                                                    Layout.preferredWidth: forwardColumn.width / 3
                                                    spacing: Theme.spacingSmall
                                                    visible: itemForwardLiveCount > 0

                                                    Repeater {
                                                        model: itemForward.lives || []

                                                        LiveCard {
                                                            Layout.fillWidth: true
                                                            Layout.preferredHeight: implicitHeight

                                                            property var liveData: modelData || {}

                                                            roomId: liveData.roomId || ""
                                                            title: liveData.title || ""
                                                            cover: liveData.cover || ""
                                                            streamer: liveData.streamer || (itemHasForward && itemForward.author) || ""
                                                            viewers: liveData.viewers || ""
                                                            category: (liveData.parentArea ? liveData.parentArea + " " : "") + (liveData.area || "")

                                                            onClicked: dynamic_page.openLiveRoom(liveData.roomId || "", liveData.title || "", liveData.streamer || "")
                                                        }
                                                    }
                                                }
                                            }

                                            MouseArea {
                                                anchors.fill: parent
                                                z: -1
                                                onClicked: {
                                                    if (itemHasForward) openDynamicDetail(itemForward)
                                                }
                                            }
                                        }

                                        // 图片网格
                                        GridLayout {
                                            Layout.fillWidth: false
                                            Layout.alignment: Qt.AlignLeft
                                            Layout.preferredWidth: feedCardColumn.width * 2 / 3
                                            columns: itemImageCount === 1 ? 1 : 3
                                            rowSpacing: 4
                                            columnSpacing: 4
                                            visible: itemImageCount > 0

                                            Repeater {
                                                model: itemImages

                                                Rectangle {
                                                    id: feedImageContainer
                                                    Layout.fillWidth: true
                                                    Layout.preferredHeight: width
                                                    radius: 6
                                                    color: FluTheme.frameColor
                                                    clip: true
                                                    layer.enabled: feedImageContainer.width > 0 && feedImageContainer.height > 0
                                                    layer.samples: 4
                                                    layer.effect: MultiEffect {
                                                        maskEnabled: true
                                                        maskSource: ShaderEffectSource {
                                                            sourceItem: feedImageMask
                                                            hideSource: true
                                                            live: true
                                                        }
                                                    }

                                                    property var imageUrl: modelData || ""
                                                    property bool singleImage: itemImageCount === 1

                                                    Rectangle {
                                                        id: feedImageMask
                                                        x: -10000
                                                        y: -10000
                                                        width: feedImageContainer.width
                                                        height: feedImageContainer.height
                                                        radius: feedImageContainer.radius
                                                        color: "black"
                                                        visible: true
                                                    }

                                                    // 动图（.gif/.webp）用 AnimatedImage 播放，静态图用 FluImage
                                                    Loader {
                                                        anchors.fill: parent
                                                        sourceComponent: GlobalState.isAnimatedImageUrl(imageUrl) ? cardFeedAnimatedImage : cardFeedStaticImage
                                                    }

                                                    Component {
                                                        id: cardFeedStaticImage
                                                        FluImage {
                                                            anchors.fill: parent
                                                            source: feedImageContainer.singleImage
                                                                         ? GlobalState.fixImageUrl(feedImageContainer.imageUrl, feedImageContainer.width * Screen.devicePixelRatio, 0, false)
                                                                         : GlobalState.fixImageUrl(feedImageContainer.imageUrl, feedImageContainer.width * Screen.devicePixelRatio, feedImageContainer.height * Screen.devicePixelRatio, true)
                                                            fillMode: feedImageContainer.singleImage ? Image.PreserveAspectFit : Image.PreserveAspectCrop
                                                            asynchronous: true
                                                            cache: true
                                                            smooth: true
                                                            onSourceSizeChanged: {
                                                                if (feedImageContainer.singleImage && sourceSize.width > 0 && feedImageContainer.width > 0) {
                                                                    feedImageContainer.Layout.preferredHeight = feedImageContainer.width * sourceSize.height / sourceSize.width
                                                                }
                                                            }
                                                        }
                                                    }

                                                    Component {
                                                        id: cardFeedAnimatedImage
                                                        AnimatedImage {
                                                            anchors.fill: parent
                                                            // fixImageUrl 对 .gif/.webp 返回原始 URL，保证动画可播放
                                                            source: feedImageContainer.singleImage
                                                                         ? GlobalState.fixImageUrl(feedImageContainer.imageUrl, feedImageContainer.width * Screen.devicePixelRatio, 0, false)
                                                                         : GlobalState.fixImageUrl(feedImageContainer.imageUrl, feedImageContainer.width * Screen.devicePixelRatio, feedImageContainer.height * Screen.devicePixelRatio, true)
                                                            fillMode: feedImageContainer.singleImage ? Image.PreserveAspectFit : Image.PreserveAspectCrop
                                                            cache: true
                                                            smooth: true
                                                            playing: true
                                                            onSourceSizeChanged: {
                                                                if (feedImageContainer.singleImage && sourceSize.width > 0 && feedImageContainer.width > 0) {
                                                                    feedImageContainer.Layout.preferredHeight = feedImageContainer.width * sourceSize.height / sourceSize.width
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }

                                        // 视频卡片
                                        ColumnLayout {
                                            Layout.fillWidth: false
                                            Layout.preferredWidth: feedCardColumn.width / 3
                                            spacing: Theme.spacingSmall
                                            visible: itemVideoCount > 0

                                            Repeater {
                                                model: itemVideos

                                                VideoCard {
                                                    Layout.fillWidth: true
                                                    Layout.preferredHeight: implicitHeight

                                                    property var videoData: modelData || {}

                                                    bvid: videoData.bvid || ""
                                                    title: videoData.title || ""
                                                    cover: videoData.cover || ""
                                                    author: itemData && itemData.author ? itemData.author : ""
                                                    views: videoData.views || "0"
                                                    danmakus: videoData.danmakus || "0"
                                                    duration: videoData.duration || ""
                                                    pubDate: ""
                                                }
                                            }
                                        }

                                        // 直播卡片
                                        ColumnLayout {
                                            Layout.fillWidth: false
                                            Layout.preferredWidth: feedCardColumn.width / 3
                                            spacing: Theme.spacingSmall
                                            visible: itemLiveCount > 0

                                            Repeater {
                                                model: itemLives

                                                LiveCard {
                                                    Layout.fillWidth: true
                                                    Layout.preferredHeight: implicitHeight

                                                    property var liveData: modelData || {}

                                                    roomId: liveData.roomId || ""
                                                    title: liveData.title || ""
                                                    cover: liveData.cover || ""
                                                    streamer: liveData.streamer || (itemData && itemData.author) || ""
                                                    viewers: liveData.viewers || ""
                                                    category: (liveData.parentArea ? liveData.parentArea + " " : "") + (liveData.area || "")

                                                    onClicked: dynamic_page.openLiveRoom(liveData.roomId || "", liveData.title || "", liveData.streamer || "")
                                                }
                                            }
                                        }

                                        // 互动数据
                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: Theme.spacingLarge

                                            Item { Layout.fillWidth: true }

                                            RowLayout {
                                                spacing: 4
                                                FluIcon {
                                                    iconSource: FluentIcons.Share
                                                    iconSize: 14
                                                    color: FluTheme.fontTertiaryColor
                                                }
                                                FluText {
                                                    text: GlobalState.formatNumber(itemData ? itemData.forwards : 0)
                                                    font: Theme.fontSmall
                                                    color: FluTheme.fontTertiaryColor
                                                }
                                            }

                                            RowLayout {
                                                spacing: 4
                                                FluIcon {
                                                    iconSource: FluentIcons.Comment
                                                    iconSize: 14
                                                    color: FluTheme.fontTertiaryColor
                                                }
                                                FluText {
                                                    text: GlobalState.formatNumber(itemData ? itemData.comments : 0)
                                                    font: Theme.fontSmall
                                                    color: FluTheme.fontTertiaryColor
                                                }
                                            }

                                            RowLayout {
                                                spacing: 4
                                                FluIcon {
                                                    iconSource: FluentIcons.Like
                                                    iconSize: 14
                                                    color: FluTheme.fontTertiaryColor
                                                }
                                                FluText {
                                                    text: GlobalState.formatNumber(itemData ? itemData.likes : 0)
                                                    font: Theme.fontSmall
                                                    color: FluTheme.fontTertiaryColor
                                                }
                                            }
                                        }
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        z: -1
                                        onClicked: {
                                            if (itemData) openDynamicDetail(itemData)
                                        }
                                    }
                                }
                            }

                                FluIconButton {
                                    width: 50
                                    height: 50
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    anchors.rightMargin: 20
                                    anchors.bottomMargin: 20
                                    iconSource: FluentIcons.Refresh
                                    iconSize: 20
                                    z: 1
                                    onClicked: {
                                        if (!dynamic_page.loading) {
                                            // 统一刷新左侧关注列表，便于登录后立即加载
                                            dynamic_page.loadUpList()
                                            dynamic_page.loadFeed(dynamic_page.currentUpMid)
                                            feedListView.positionViewAtBeginning()
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

    // 视频播放页打开时，兜底拦截滚轮事件，防止其穿透到底层主页滚动视图。
    MouseArea {
        anchors.fill: parent
        z: 99
        enabled: videoVisible || liveVisible
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
        z: 102
        visible: opacity > 0 || openVideoAnim.running || closeVideoAnim.running || switchVideoSeqAnim.running
        opacity: 0

        property string videoBvid: ""
        property string videoTitleText: ""
        // 番剧/电影参数：openBangumiPlayer 赋值、VideoPlayerPage 绑定都依赖这三个属性。
        // 之前未声明 → 赋值时报 "Cannot assign to non-existent property" 并中断整个函数
        property bool videoIsBangumi: false
        property string videoEpId: ""
        property string videoSeasonId: ""
        property bool _playerCreated: false
        property string _pendingSwitchBvid: ""
        property string _pendingSwitchTitle: ""

        Component {
            id: videoPlayerComponent
            VideoPlayerPage {
                anchors.fill: parent
                bvid: videoOverlay.videoBvid
                videoTitle: videoOverlay.videoTitleText
                // 关键修复：番剧/电影参数必须绑定传入。
                // 重开时新实例 visible=false，App.bangumiOpenRequested 信号被忽略，
                // 只能靠这里的绑定；缺失时 isBangumi 恒为 false → 黑屏
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
                onClicked: { }
            }

            Loader {
                id: videoPlayerLoader
                anchors.fill: parent
                // 小窗模式守卫：进入小窗时 pageStack 隐藏使 videoOverlay.visible
                // 从父级"流动"为 false，若不守卫会立即卸载销毁播放页（播放器
                // 尚未 reparent 出去 → mpv 被终止 → 白屏无声）
                active: (videoOverlay.visible || App.miniPlayerMode) && videoOverlay._playerCreated
                sourceComponent: videoPlayerComponent
            }
        }

        Timer {
            id: playerDestroyTimer
            interval: 250
            repeat: false
            onTriggered: {
                if (!videoVisible && !openVideoAnim.running && !closeVideoAnim.running) {
                    videoOverlay._playerCreated = false
                }
            }
        }

        function doOpen() {
            playerDestroyTimer.stop()
            closeVideoAnim.stop()
            switchVideoSeqAnim.stop()
            _playerCreated = true
            openVideoAnim.start()
        }

        function doClose() {
            openVideoAnim.stop()
            closeVideoAnim.stop()
            switchVideoSeqAnim.stop()
            if (videoPlayerLoader.item) {
                videoPlayerLoader.item.stopPlayer()
            }
            playerDestroyTimer.start()
            closeVideoAnim.start()
        }

        function doSwitch(bvid, title) {
            switchVideoSeqAnim.stop()
            closeVideoAnim.stop()
            openVideoAnim.stop()

            _pendingSwitchBvid = bvid
            _pendingSwitchTitle = title
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
            onStopped: {
                if (!videoVisible) {
                    videoOverlay._playerCreated = false
                }
            }
        }

        SequentialAnimation {
            id: switchVideoSeqAnim

            // 第一步：旧视频向下滑走 + 淡出
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

            // 第二步：更新数据
            ScriptAction {
                script: {
                    videoOverlay.videoBvid = videoOverlay._pendingSwitchBvid
                    videoOverlay.videoTitleText = videoOverlay._pendingSwitchTitle
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

    // 共享弹幕管理器：放在 DynamicPage 层级，不随 LivePlayerPage 销毁/重建。
    // 避免 QWebSocket（SSL 握手线程）频繁创建/销毁导致卡死。
    LiveDanmakuManager {
        id: sharedDanmakuManager
    }

    // 直播播放页覆盖层
    Item {
        id: liveOverlay
        // 基准与 videoOverlay 一致：Frame 边距 + playerOverlayMargin 内缩，
        // 所有弹出页尺寸统一（单边 margin 覆盖 margins 基数，故写成显式和）
        anchors.fill: parent
        anchors.leftMargin: Theme.homeFrameLeftMargin + Theme.playerOverlayMargin
        anchors.rightMargin: Theme.homeFrameRightMargin + Theme.playerOverlayMargin
        anchors.bottomMargin: Theme.homeFrameBottomMargin + Theme.playerOverlayMargin
        anchors.topMargin: Theme.homeFrameTopMargin + Theme.playerOverlayMargin
        z: 102
        visible: opacity > 0 || openLiveAnim.running || closeLiveAnim.running
        opacity: 0

        property string liveRoomId: ""
        property string liveTitleText: ""
        property string liveStreamerName: ""
        property bool _playerCreated: false
        property string _pendingOpenLiveRoomId: ""
        property string _pendingOpenLiveTitle: ""
        property string _pendingOpenLiveStreamer: ""

        Component {
            id: livePlayerComponent
            LivePlayerPage {
                anchors.fill: parent
                roomId: liveOverlay.liveRoomId
                streamTitle: liveOverlay.liveTitleText
                streamer: liveOverlay.liveStreamerName
                danmakuManager: sharedDanmakuManager
                onCloseRequested: dynamic_page.closeLiveRoom()
            }
        }

        Item {
            anchors.fill: parent
            transform: Translate { id: liveTranslate; y: 0 }

            MouseArea {
                anchors.fill: parent
                z: -1
                enabled: livePlayerLoader.active
                onClicked: { }
            }

            Loader {
                id: livePlayerLoader
                anchors.fill: parent
                // 小窗模式守卫：同 videoPlayerLoader，防止进小窗时误卸载直播页
                active: (liveOverlay.visible || App.miniPlayerMode) && liveOverlay._playerCreated
                sourceComponent: livePlayerComponent
            }
        }

        Timer {
            id: livePlayerDestroyTimer
            interval: 250
            repeat: false
            onTriggered: {
                if (!liveVisible && !openLiveAnim.running && !closeLiveAnim.running) {
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
            openLiveAnim.stop()
            if (livePlayerLoader.item) {
                livePlayerLoader.item.stopPlayer()
            }
            // 清空 roomId：与视频播放页相同的销毁策略，Loader 会在动画结束后销毁 LivePlayerPage。
            liveOverlay.liveRoomId = ""
            livePlayerDestroyTimer.start()
            closeLiveAnim.start()
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
            // 动画结束后设置 roomId，触发 onRoomIdChanged → loadStream
            onStopped: {
                if (liveOverlay._pendingOpenLiveRoomId) {
                    liveOverlay.liveTitleText = liveOverlay._pendingOpenLiveTitle
                    liveOverlay.liveStreamerName = liveOverlay._pendingOpenLiveStreamer
                    var newRoomId = liveOverlay._pendingOpenLiveRoomId
                    liveOverlay._pendingOpenLiveRoomId = ""
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

    // 动态详情弹窗（从下往上弹出，覆盖两个 Frame）
    Item {
        id: detailOverlay
        // 与 videoOverlay 同几何：Frame 边距 + playerOverlayMargin 内缩，
        // 所有弹出页尺寸统一（单边 margin 覆盖 margins 基数，故写成显式和）
        anchors.fill: parent
        anchors.leftMargin: Theme.homeFrameLeftMargin + Theme.playerOverlayMargin
        anchors.rightMargin: Theme.homeFrameRightMargin + Theme.playerOverlayMargin
        anchors.bottomMargin: Theme.homeFrameBottomMargin + Theme.playerOverlayMargin
        anchors.topMargin: Theme.homeFrameTopMargin + Theme.playerOverlayMargin
        z: 101
        visible: opacity > 0 || openDetailAnim.running || closeDetailAnim.running
        opacity: 0

        FluFrame {
            id: detailPanel
            anchors.fill: parent
            padding: 0
            radius: Theme.frameRadius
            color: FluTheme.backgroundColor

            RowLayout {
                anchors.fill: parent
                spacing: 0

                // 左侧：动态正文（个性装扮放在 Flickable 外层，y 绑定 contentY 跟随滚动）
                Item {
                    Layout.fillHeight: true
                    Layout.preferredWidth: Math.max(400, parent.width * 0.65)
                    // clip: true 裁剪个性装扮向上滚动时溢出到窗框栏的部分，
                    // 让装扮超出本区域上边缘就消失（与其他元素行为一致）
                    clip: true

                    // ====== 个性装扮（详情页卡片右上角，随 Flickable 滚动）======
                    // 注：Column 子项不能用 anchors.top/right，所以装扮不能放进 Column。
                    // 放在 Flickable 外层 Item，y 绑定 detailDynamicFlickable.contentY，
                    // 滚动时 y 随内容偏移，装扮即向上滚出视野。
                    // 垂直对齐计算：
                    //   detailDynamicColumn 顶部 padding = Theme.spacingMedium (Item spacer 高度)
                    //   AvatarWithPendant avatarSize = 40 → 头像中心 Y = spacingMedium + 20
                    //   CommentCardBg height=54 → 装扮中心 Y = y + 27
                    //   令两者相等：y = spacingMedium + 20 - 27 = spacingMedium - 7
                    //   滚动时减去 contentY，装扮随内容向上移动
                    CommentCardBg {
                        x: parent.width - width - Theme.pageMargins - 2
                        y: Theme.spacingMedium - 7 - detailDynamicFlickable.contentY
                        z: 5
                        showNoPrefix: false
                        numberPosition: "left"
                        cardbg: {
                            var c = currentDynamic ? currentDynamic.cardbg : null
                            if (!c || typeof c !== "object") {
                                return { show: false, image: "", fanNumDesc: "", fanColor: "#FB7299" }
                            }
                            if (typeof c.show !== "boolean") c.show = !!c.show
                            return c
                        }
                    }

                    Flickable {
                        id: detailDynamicFlickable
                        anchors.fill: parent
                        clip: true
                        contentHeight: detailDynamicColumn.height
                        boundsBehavior: Flickable.StopAtBounds
                        ScrollBar.vertical: FluScrollBar {}

                        Column {
                            id: detailDynamicColumn
                            width: parent.width
                            spacing: 0

                            Item {
                                width: 1
                                height: Theme.spacingMedium
                            }

                            ColumnLayout {
                                id: detailContentColumn
                                width: parent.width - Theme.pageMargins * 2
                                anchors.horizontalCenter: parent.horizontalCenter
                                spacing: Theme.spacingMedium

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Theme.spacingSmall
                                    // 右侧给装扮留 190px 空间（装扮 width=175 + 额外 15px 间距），避免头像/昵称行与装扮重叠
                                    Layout.rightMargin: currentDynamic && currentDynamic.cardbg && currentDynamic.cardbg.show ? 190 : 0

                                    // ====== 头像框 AvatarWithPendant ======
                                    AvatarWithPendant {
                                        face: currentDynamic ? (currentDynamic.face || "") : ""
                                        pendantImage: currentDynamic && currentDynamic.pendantImage ? currentDynamic.pendantImage : ""
                                        avatarSize: 40
                                        pendantScale: 1.5
                                        verifyType: currentDynamic ? (currentDynamic.verifyType || -1) : -1
                                        Layout.alignment: Qt.AlignTop
                                        placeholderText: currentDynamic && currentDynamic.author ? currentDynamic.author.charAt(0) : ""
                                    }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 2

                                    FluText {
                                        text: currentDynamic ? (currentDynamic.author || "") : ""
                                        font: Theme.fontNormal
                                        color: Theme.primary
                                    }

                                    FluText {
                                        text: currentDynamic ? (currentDynamic.time || "") : ""
                                        font: Theme.fontSmall
                                        color: FluTheme.fontTertiaryColor
                                    }
                                }

                                Item { Layout.fillWidth: true }

                                // 关闭按钮已删除（用户要求）
                            }

                            // 文本内容（RichText：@用户链接🔗/网页链接/话题/AV号/表情/换行 — 点击 @ 或链接会触发 onLinkActivated）
                            FluText {
                                Layout.fillWidth: true
                                // 详情页在 Flickable 内部，RichText 模式下 ColumnLayout 可能不会正确计算文本高度；
                                // 显式绑定 preferredHeight 到 contentHeight，保证 Flickable.contentHeight 正确累加（解决无法向下滚动的问题）
                                Layout.preferredHeight: contentHeight > 0 ? contentHeight : implicitHeight
                                text: dynamic_page.formatDynamicContent(
                                          currentDynamic ? (currentDynamic.content || "") : "",
                                          currentDynamic ? (currentDynamic.emotes || {}) : {},
                                          currentDynamic ? (currentDynamic.jumpUrls || {}) : {},
                                          currentDynamic ? (currentDynamic.atList || []) : [],
                                          currentDynamic ? (currentDynamic.topicList || []) : [],
                                          currentDynamic ? (currentDynamic.urlList || []) : [],
                                          true /* skipTimestamp: 动态卡片不识别时间戳 */)
                                font: Theme.fontNormal
                                color: FluTheme.fontPrimaryColor
                                textFormat: Text.RichText
                                wrapMode: Text.Wrap
                                onLinkActivated: function(link) {
                                    dynamic_page.openLinkHelper(link)
                                }
                            }

                            // 被引用（转发）卡片
                            Rectangle {
                                id: detailForwardCard
                                Layout.fillWidth: true
                                Layout.preferredHeight: detailForwardColumn.implicitHeight + Theme.spacingMedium * 2
                                color: FluTheme.frameColor
                                radius: Theme.radiusSmall
                                // visible 必须和 hasForwardData 完全对齐，不能直接用 !!currentDynamic.forward（forward={}时为true会显示空卡片）
                                visible: detailForwardCard.hasForwardData
                                border.color: FluTheme.dividerColor
                                border.width: 1

                                // ====== 判断当前动态是否包含转发卡片 ======
                                // 两种场景兼容：
                                // 1) 列表动态打开详情（currentDynamic是主动态）→ 用预先算好的 currentDynamic.hasForward（append前算的，bool，不受后面forward=null→{}的影响）
                                // 2) 点击转发卡片上的UP主头像打开的详情（openDynamicDetail(itemForward)）→ 此时对象本身就是被转发的动态，没有hasForward字段，fallback到!!forward
                                property bool hasForwardData: !!currentDynamic && (
                                    typeof currentDynamic.hasForward === "boolean"
                                        ? currentDynamic.hasForward
                                        : !!currentDynamic.forward
                                )
                                property var forwardData: hasForwardData ? (currentDynamic.forward || {}) : {}
                                property int forwardImageCount: hasForwardData && forwardData.images ? forwardData.images.length : 0
                                property int forwardVideoCount: hasForwardData && forwardData.videos ? forwardData.videos.length : 0
                                property int forwardLiveCount: hasForwardData && forwardData.lives ? forwardData.lives.length : 0

                                ColumnLayout {
                                    id: detailForwardColumn
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.top: parent.top
                                    anchors.margins: Theme.spacingMedium
                                    spacing: Theme.spacingSmall

                                    RowLayout {
                                        spacing: Theme.spacingSmall
                                        // ====== 转发卡片同样带头像框 ======
                                        AvatarWithPendant {
                                            face: detailForwardCard.forwardData.face || ""
                                            pendantImage: detailForwardCard.hasForwardData && detailForwardCard.forwardData.pendantImage ? detailForwardCard.forwardData.pendantImage : ""
                                            avatarSize: 28
                                            pendantScale: 1.5
                                            verifyType: detailForwardCard.hasForwardData ? (detailForwardCard.forwardData.verifyType || -1) : -1
                                            placeholderText: detailForwardCard.forwardData.author ? detailForwardCard.forwardData.author.charAt(0) : ""
                                        }
                                        FluText {
                                            text: detailForwardCard.forwardData.author || ""
                                            font: Theme.fontSmall
                                            color: Theme.primary
                                        }
                                    }

                                    // 详情页转发正文（RichText）
                                    FluText {
                                        Layout.fillWidth: true
                                        text: detailForwardCard.hasForwardData ? dynamic_page.formatDynamicContent(
                                                                                   detailForwardCard.forwardData.content || "",
                                                                                   detailForwardCard.forwardData.emotes || {},
                                                                                   detailForwardCard.forwardData.jumpUrls || {},
                                                                                   detailForwardCard.forwardData.atList || [],
                                                                                   detailForwardCard.forwardData.topicList || [],
                                                                                   detailForwardCard.forwardData.urlList || [],
                                                                                   true /* skipTimestamp: 动态卡片不识别时间戳 */)
                                                                              : ""
                                        font: Theme.fontSmall
                                        color: FluTheme.fontPrimaryColor
                                        textFormat: Text.RichText
                                        wrapMode: Text.Wrap
                                        maximumLineCount: 5
                                        elide: Text.ElideRight
                                        onLinkActivated: function(link) { dynamic_page.openLinkHelper(link) }
                                    }

                                    GridLayout {
                                        Layout.fillWidth: false
                                        Layout.alignment: Qt.AlignLeft
                                        Layout.preferredWidth: detailForwardColumn.width * 2 / 3
                                        columns: detailForwardCard.forwardImageCount === 1 ? 1 : 3
                                        rowSpacing: 4
                                        columnSpacing: 4
                                        visible: detailForwardCard.forwardImageCount > 0

                                        Repeater {
                                            model: detailForwardCard.forwardData.images || []

                                            Rectangle {
                                                id: forwardDetailImageContainer
                                                Layout.fillWidth: true
                                                Layout.preferredHeight: width
                                                radius: 6
                                                color: FluTheme.frameColor
                                                clip: true
                                                layer.enabled: forwardDetailImageContainer.width > 0 && forwardDetailImageContainer.height > 0
                                                layer.samples: 4
                                                layer.effect: MultiEffect {
                                                    maskEnabled: true
                                                    maskSource: ShaderEffectSource {
                                                        sourceItem: forwardDetailImageMask
                                                        hideSource: true
                                                        live: true
                                                    }
                                                }

                                                property var imageUrl: modelData || ""
                                                property bool singleImage: detailForwardCard.forwardImageCount === 1

                                                Rectangle {
                                                    id: forwardDetailImageMask
                                                    x: -10000
                                                    y: -10000
                                                    width: forwardDetailImageContainer.width
                                                    height: forwardDetailImageContainer.height
                                                    radius: forwardDetailImageContainer.radius
                                                    color: "black"
                                                    visible: true
                                                }

                                                // 动图（.gif/.webp）用 AnimatedImage 播放，静态图用 FluImage
                                                Loader {
                                                    anchors.fill: parent
                                                    sourceComponent: GlobalState.isAnimatedImageUrl(forwardDetailImageContainer.imageUrl) ? detailForwardAnimatedImage : detailForwardStaticImage
                                                }

                                                Component {
                                                    id: detailForwardStaticImage
                                                    FluImage {
                                                        anchors.fill: parent
                                                        source: forwardDetailImageContainer.singleImage
                                                                     ? GlobalState.fixImageUrl(forwardDetailImageContainer.imageUrl, forwardDetailImageContainer.width * Screen.devicePixelRatio, 0, false)
                                                                     : GlobalState.fixImageUrl(forwardDetailImageContainer.imageUrl, forwardDetailImageContainer.width * Screen.devicePixelRatio, forwardDetailImageContainer.height * Screen.devicePixelRatio, true)
                                                        fillMode: forwardDetailImageContainer.singleImage ? Image.PreserveAspectFit : Image.PreserveAspectCrop
                                                        asynchronous: true
                                                        cache: true
                                                        smooth: true
                                                        onSourceSizeChanged: {
                                                            if (forwardDetailImageContainer.singleImage && sourceSize.width > 0 && forwardDetailImageContainer.width > 0) {
                                                                forwardDetailImageContainer.Layout.preferredHeight = forwardDetailImageContainer.width * sourceSize.height / sourceSize.width
                                                            }
                                                        }
                                                    }
                                                }

                                                Component {
                                                    id: detailForwardAnimatedImage
                                                    AnimatedImage {
                                                        anchors.fill: parent
                                                        // fixImageUrl 对 .gif/.webp 返回原始 URL，保证动画可播放
                                                        source: forwardDetailImageContainer.singleImage
                                                                     ? GlobalState.fixImageUrl(forwardDetailImageContainer.imageUrl, forwardDetailImageContainer.width * Screen.devicePixelRatio, 0, false)
                                                                     : GlobalState.fixImageUrl(forwardDetailImageContainer.imageUrl, forwardDetailImageContainer.width * Screen.devicePixelRatio, forwardDetailImageContainer.height * Screen.devicePixelRatio, true)
                                                        fillMode: forwardDetailImageContainer.singleImage ? Image.PreserveAspectFit : Image.PreserveAspectCrop
                                                        cache: true
                                                        smooth: true
                                                        playing: true
                                                        onSourceSizeChanged: {
                                                            if (forwardDetailImageContainer.singleImage && sourceSize.width > 0 && forwardDetailImageContainer.width > 0) {
                                                                forwardDetailImageContainer.Layout.preferredHeight = forwardDetailImageContainer.width * sourceSize.height / sourceSize.width
                                                            }
                                                        }
                                                    }
                                                }

                                                MouseArea {
                                                    anchors.fill: parent
                                                    // z:-1 垫底：让 FluImage 加载失败时的 Reload 按钮可点击
                                                    z: -1
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: {
                                                        openDetailImagePreview(detailForwardCard.forwardData.images, index)
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    ColumnLayout {
                                        Layout.fillWidth: false
                                        Layout.preferredWidth: detailForwardColumn.width / 3
                                        spacing: Theme.spacingSmall
                                        visible: detailForwardCard.forwardVideoCount > 0

                                        Repeater {
                                            model: detailForwardCard.forwardData.videos || []

                                            VideoCard {
                                                Layout.fillWidth: true
                                                Layout.preferredHeight: implicitHeight

                                                property var videoData: modelData || {}

                                                bvid: videoData.bvid || ""
                                                title: videoData.title || ""
                                                cover: videoData.cover || ""
                                                author: detailForwardCard.forwardData.author || ""
                                                views: videoData.views || "0"
                                                danmakus: videoData.danmakus || "0"
                                                duration: videoData.duration || ""
                                                pubDate: ""
                                            }
                                        }
                                    }

                                    ColumnLayout {
                                        Layout.fillWidth: false
                                        Layout.preferredWidth: detailForwardColumn.width / 3
                                        spacing: Theme.spacingSmall
                                        visible: detailForwardCard.forwardLiveCount > 0

                                        Repeater {
                                            model: detailForwardCard.forwardData.lives || []

                                            LiveCard {
                                                Layout.fillWidth: true
                                                Layout.preferredHeight: implicitHeight

                                                property var liveData: modelData || {}

                                                roomId: liveData.roomId || ""
                                                title: liveData.title || ""
                                                cover: liveData.cover || ""
                                                streamer: liveData.streamer || detailForwardCard.forwardData.author || ""
                                                viewers: liveData.viewers || ""
                                                category: (liveData.parentArea ? liveData.parentArea + " " : "") + (liveData.area || "")

                                                onClicked: dynamic_page.openLiveRoom(liveData.roomId || "", liveData.title || "", liveData.streamer || "")
                                            }
                                        }
                                    }
                                }
                            }

                            GridLayout {
                                id: detailImageGrid
                                Layout.fillWidth: true
                                columns: currentDynamic && currentDynamic.images && currentDynamic.images.length === 1 ? 1 : 3
                                rowSpacing: 4
                                columnSpacing: 4
                                visible: currentDynamic && currentDynamic.images && currentDynamic.images.length > 0

                                Repeater {
                                    model: currentDynamic ? (currentDynamic.images || []) : []

                                    Rectangle {
                                        id: detailImageContainer
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: width
                                        radius: 6
                                        color: FluTheme.frameColor
                                        clip: true
                                        layer.enabled: detailImageContainer.width > 0 && detailImageContainer.height > 0
                                        layer.samples: 4
                                        layer.effect: MultiEffect {
                                            maskEnabled: true
                                            maskSource: ShaderEffectSource {
                                                sourceItem: detailImageMask
                                                hideSource: true
                                                live: true
                                            }
                                        }

                                        property var imageUrl: modelData || ""
                                        property bool singleImage: currentDynamic && currentDynamic.images && currentDynamic.images.length === 1

                                        Rectangle {
                                            id: detailImageMask
                                            x: -10000
                                            y: -10000
                                            width: detailImageContainer.width
                                            height: detailImageContainer.height
                                            radius: detailImageContainer.radius
                                            color: "black"
                                            visible: true
                                        }

                                        // 动图（.gif/.webp）用 AnimatedImage 播放，静态图用 FluImage
                                        Loader {
                                            anchors.fill: parent
                                            sourceComponent: GlobalState.isAnimatedImageUrl(detailImageContainer.imageUrl) ? detailFeedAnimatedImage : detailFeedStaticImage
                                        }

                                        Component {
                                            id: detailFeedStaticImage
                                            FluImage {
                                                anchors.fill: parent
                                                source: detailImageContainer.singleImage
                                                             ? GlobalState.fixImageUrl(detailImageContainer.imageUrl, detailImageContainer.width * Screen.devicePixelRatio, 0, false)
                                                             : GlobalState.fixImageUrl(detailImageContainer.imageUrl, detailImageContainer.width * Screen.devicePixelRatio, detailImageContainer.height * Screen.devicePixelRatio, true)
                                                fillMode: detailImageContainer.singleImage ? Image.PreserveAspectFit : Image.PreserveAspectCrop
                                                asynchronous: true
                                                cache: true
                                                smooth: true
                                                onSourceSizeChanged: {
                                                    if (detailImageContainer.singleImage && sourceSize.width > 0 && detailImageContainer.width > 0) {
                                                        detailImageContainer.Layout.preferredHeight = detailImageContainer.width * sourceSize.height / sourceSize.width
                                                    }
                                                }
                                            }
                                        }

                                        Component {
                                            id: detailFeedAnimatedImage
                                            AnimatedImage {
                                                anchors.fill: parent
                                                // fixImageUrl 对 .gif/.webp 返回原始 URL，保证动画可播放
                                                source: detailImageContainer.singleImage
                                                             ? GlobalState.fixImageUrl(detailImageContainer.imageUrl, detailImageContainer.width * Screen.devicePixelRatio, 0, false)
                                                             : GlobalState.fixImageUrl(detailImageContainer.imageUrl, detailImageContainer.width * Screen.devicePixelRatio, detailImageContainer.height * Screen.devicePixelRatio, true)
                                                fillMode: detailImageContainer.singleImage ? Image.PreserveAspectFit : Image.PreserveAspectCrop
                                                cache: true
                                                smooth: true
                                                playing: true
                                                onSourceSizeChanged: {
                                                    if (detailImageContainer.singleImage && sourceSize.width > 0 && detailImageContainer.width > 0) {
                                                        detailImageContainer.Layout.preferredHeight = detailImageContainer.width * sourceSize.height / sourceSize.width
                                                    }
                                                }
                                            }
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            // z:-1 垫底：让 FluImage 加载失败时的 Reload 按钮可点击
                                            z: -1
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                openDetailImagePreview(currentDynamic.images, index)
                                            }
                                        }
                                    }
                                }
                            }

                            ColumnLayout {
                                Layout.fillWidth: false
                                Layout.preferredWidth: detailContentColumn.width / 3
                                spacing: Theme.spacingSmall
                                visible: currentDynamic && currentDynamic.videos && currentDynamic.videos.length > 0

                                Repeater {
                                    model: currentDynamic ? (currentDynamic.videos || []) : []

                                    VideoCard {
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: implicitHeight

                                        property var videoData: modelData || {}

                                        bvid: videoData.bvid || ""
                                        title: videoData.title || ""
                                        cover: videoData.cover || ""
                                        author: currentDynamic ? (currentDynamic.author || "") : ""
                                        views: videoData.views || "0"
                                        danmakus: videoData.danmakus || "0"
                                        duration: videoData.duration || ""
                                        pubDate: ""
                                    }
                                }
                            }

                            ColumnLayout {
                                Layout.fillWidth: false
                                Layout.preferredWidth: detailContentColumn.width / 3
                                spacing: Theme.spacingSmall
                                visible: currentDynamic && currentDynamic.lives && currentDynamic.lives.length > 0

                                Repeater {
                                    model: currentDynamic ? (currentDynamic.lives || []) : []

                                    LiveCard {
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: implicitHeight

                                        property var liveData: modelData || {}

                                        roomId: liveData.roomId || ""
                                        title: liveData.title || ""
                                        cover: liveData.cover || ""
                                        streamer: liveData.streamer || (currentDynamic ? currentDynamic.author : "") || ""
                                        viewers: liveData.viewers || ""
                                        category: (liveData.parentArea ? liveData.parentArea + " " : "") + (liveData.area || "")

                                        onClicked: dynamic_page.openLiveRoom(liveData.roomId || "", liveData.title || "", liveData.streamer || "")
                                    }
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacingLarge

                                Item { Layout.fillWidth: true }

                                RowLayout {
                                    spacing: 4
                                    FluIcon { iconSource: FluentIcons.Share; iconSize: 14; color: FluTheme.fontTertiaryColor }
                                    FluText { text: GlobalState.formatNumber(currentDynamic ? (currentDynamic.forwards || 0) : 0); font: Theme.fontSmall; color: FluTheme.fontTertiaryColor }
                                }
                                RowLayout {
                                    spacing: 4
                                    FluIcon { iconSource: FluentIcons.Comment; iconSize: 14; color: FluTheme.fontTertiaryColor }
                                    FluText { text: GlobalState.formatNumber(currentDynamic ? (currentDynamic.comments || 0) : 0); font: Theme.fontSmall; color: FluTheme.fontTertiaryColor }
                                }
                                RowLayout {
                                    spacing: 4
                                    FluIcon { iconSource: FluentIcons.Like; iconSize: 14; color: FluTheme.fontTertiaryColor }
                                    FluText { text: GlobalState.formatNumber(currentDynamic ? (currentDynamic.likes || 0) : 0); font: Theme.fontSmall; color: FluTheme.fontTertiaryColor }
                                }
                            } // end: 点赞/评论/分享 RowLayout
                        }     // end: detailContentColumn (ColumnLayout)
                    }         // end: detailDynamicColumn (Column)
                }             // end: detailDynamicFlickable (Flickable)
            }                 // end: Item（包裹 Flickable + 装扮，避免 Column 子项 anchors 警告）

                Rectangle {
                    Layout.fillHeight: true
                    width: 1
                    color: Theme.divider
                }

                // 右侧：评论区（与视频播放页完全一致）
                CommentPanel {
                    id: detailCommentPanel
                    Layout.fillHeight: true
                    Layout.fillWidth: true
                    commentModel: detailCommentModel
                    aid: detailCommentOid()
                    oid: detailCommentOid()
                    commentType: detailCommentType()
                    showDislike: false
                    previewOverlayParent: dynamic_page
                    ownerMid: currentDynamic ? String(currentDynamic.mid) : ""
                    sortByHeat: detailCommentSortByHeat
                    commentTotal: detailCommentTotal
                    commentPage: detailCommentPage
                    commentHasNextPage: detailCommentHasNextPage
                    onRequestSort: function(byHeat) {
                        detailCommentSortByHeat = byHeat
                        detailCommentPage = 1
                        loadDetailComments()
                    }
                    onRequestPage: function(page, pageSize) {
                        loadDetailCommentsPage(page, pageSize)
                    }
                    onRequestSubComments: function(aid, rpid, page, pageSize) {
                        CommentManager.getSubComments(aid, rpid, page, pageSize, detailCommentType())
                    }
                    onRequestSendComment: function(text, rootId, parentId) {
                        if (!detailCommentRequireLogin()) return
                        var oid = detailCommentOid()
                        var type = detailCommentType()
                        if (!oid) return
                        CommentManager.sendComment(oid, text, type, rootId, parentId)
                    }
                }
            }
        }

        MouseArea {
            anchors.fill: parent
            z: 5
            enabled: detailVisible
            acceptedButtons: Qt.RightButton
            onClicked: function(mouse) {
                if (mouse.button === Qt.RightButton) {
                    closeDynamicDetail()
                    mouse.accepted = true
                }
            }
        }

        transform: Translate { id: detailTranslate; y: 0 }

        function doOpen() {
            closeDetailAnim.stop()
            openDetailAnim.start()
        }

        function doClose() {
            openDetailAnim.stop()
            closeDetailAnim.start()
        }

        ParallelAnimation {
            id: openDetailAnim
            NumberAnimation {
                target: detailOverlay
                property: "opacity"
                from: 0
                to: 1
                duration: 250
                easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: detailTranslate
                property: "y"
                from: detailOverlay.height
                to: 0
                duration: 250
                easing.type: Easing.OutCubic
            }
        }

        ParallelAnimation {
            id: closeDetailAnim
            NumberAnimation {
                target: detailOverlay
                property: "opacity"
                from: 1
                to: 0
                duration: 200
                easing.type: Easing.InCubic
            }
            NumberAnimation {
                target: detailTranslate
                property: "y"
                from: 0
                to: detailOverlay.height
                duration: 200
                easing.type: Easing.InCubic
            }
        }
    }

    // 动态详情图片全屏预览
    Rectangle {
        id: detailImagePreviewOverlay
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.9)
        visible: dynamic_page.detailImagePreviewVisible
        z: 103

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: function(mouse) {
                dynamic_page.closeDetailImagePreview()
                mouse.accepted = true
            }
        }

        ImageViewer {
            id: detailImageViewer
            anchors.centerIn: parent
            width: parent.width - 80
            height: parent.height - 80
            source: dynamic_page.previewCurrentImageUrl()
            animated: dynamic_page.previewCurrentImageIsAnimated()
        }

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
                onClicked: dynamic_page.closeDetailImagePreview()
            }
        }

        Rectangle {
            visible: dynamic_page.detailPreviewImages.length > 1
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
                onClicked: dynamic_page.previewPrevImage()
            }
        }

        Rectangle {
            visible: dynamic_page.detailPreviewImages.length > 1
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
                onClicked: dynamic_page.previewNextImage()
            }
        }
    }

    Connections {
        target: App
        function onVideoOpenRequested(bvid, title) {
            if (!dynamic_page.visible) return
            dynamic_page.openVideoPlayer(bvid, title)
        }
        function onBangumiOpenRequested(bvid, epId, seasonId, title) {
            if (!dynamic_page.visible) return
            dynamic_page.openBangumiPlayer(bvid, epId, seasonId, title)
        }
        function onVideoCloseRequested() {
            dynamic_page.closeVideoPlayer()
        }
    }

    Connections {
        target: Api
        function onDynamicUpListReceived(data) {
            if (!dynamic_page.visible) return
            dynamic_page.parseDynamicUpList(data)
        }
        function onFollowingsReceived(data) {
            if (!dynamic_page.visible) return
            dynamic_page.parseFollowings(data)
        }
        function onDynamicVideosReceived(data) {
            if (!dynamic_page.visible) return
            dynamic_page.parseDynamicVideos(data)
        }
        function onUserUploadedVideosReceived(data) {
            if (!dynamic_page.visible) return
            dynamic_page.parseUserUploadedVideos(data)
        }
        function onDynamicArticleListReceived(data) {
            if (!dynamic_page.visible) return
            dynamic_page.parseDynamicArticleList(data)
        }
        function onDynamicDetailReceived(data) {
            if (!dynamic_page.visible) return
            dynamic_page.parseDynamicDetail(data)
        }
        // 断网等网络错误时 Api 只发 errorOccurred 不发数据信号，loading 卡死
        // 会让刷新按钮的 !loading 守卫永久失效（只能重启）
        function onErrorOccurred(error) {
            console.warn("[DynamicPage] API error:", error)
            if (!dynamic_page.loading) return
            dynamic_page.loading = false
            dynamic_page.hasMore = false
        }
    }

    Connections {
        target: CommentManager
        function onCommentsReady(comments, page, total, sort) {
            if (page > 0) {
                detailCommentPage = page
            }
            detailCommentLoadingMore = false
            if (detailCommentPage <= 1 || detailCommentTotal <= 0) {
                detailCommentTotal = total || comments.length
            }
            if (comments.length === 0 && detailCommentPage > 1) {
                detailCommentTotal = (detailCommentPage - 1) * 20
            }
            detailCommentHasNextPage = comments.length >= 20
            detailCommentModel.clear()
            var oid = detailCommentOid()
            for (var i = 0; i < comments.length; i++) {
                var c = comments[i]
                c.aid = oid
                c.repliesExpanded = false
                c.repliesJson = JSON.stringify([])
                c.repliesPage = 1
                detailCommentModel.append(c)
            }
            // 数据就位后再复位滚动：避免“先滚回顶部、再等加载”的两段式跳动
            detailCommentPanel.scrollToTop()
        }
        function onSubCommentsReady(rootRpid, comments) {
            var targetRpid = String(rootRpid || "")
            var oid = detailCommentOid()
            for (var i = 0; i < detailCommentModel.count; i++) {
                var item = detailCommentModel.get(i)
                if (String(item.rpid || "") === targetRpid) {
                    for (var j = 0; j < comments.length; j++) {
                        comments[j].aid = oid
                    }
                    detailCommentModel.setProperty(i, "repliesJson", JSON.stringify(comments))
                    detailCommentModel.setProperty(i, "repliesExpanded", true)
                    break
                }
            }
        }
        function onCommentPosted(success, message, comment, root, parent) {
            if (!success || !comment || !comment.rpid) {
                console.warn("[DynamicPage] commentPosted invalid data")
                return
            }
            var oid = detailCommentOid()
            comment.aid = oid
            comment.repliesExpanded = false
            comment.repliesJson = JSON.stringify([])
            comment.repliesPage = 1
            var rootId = String(root || "")
            if (rootId === "" || rootId === "0") {
                detailCommentModel.insert(0, comment)
                detailCommentTotal = (detailCommentTotal || 0) + 1
            } else {
                for (var i = 0; i < detailCommentModel.count; i++) {
                    var item = detailCommentModel.get(i)
                    if (String(item.rpid || "") === rootId) {
                        var list = JSON.parse(item.repliesJson || "[]") || []
                        list.push(comment)
                        detailCommentModel.setProperty(i, "repliesJson", JSON.stringify(list))
                        detailCommentModel.setProperty(i, "repliesExpanded", true)
                        detailCommentModel.setProperty(i, "count", (item.count || 0) + 1)
                        break
                    }
                }
            }
        }
        function onActionSuccess(action, rpid, success, message) {
        }
        function onErrorOccurred(error) {
            console.warn("[DynamicPage] CommentManager error:", error)
            detailCommentLoadingMore = false
        }
    }

    function openVideoPlayer(bvid, title) {
        if (videoVisible && videoOverlay.videoBvid === bvid) {
            return
        }

        var oldBvid = videoOverlay.videoBvid
        var hasOldVideo = videoVisible && oldBvid !== "" && oldBvid !== bvid

        // 普通视频：清空番剧标记，防止上一次番剧/电影的 isBangumi/epId 残留
        // 导致本次普通视频被当成番剧加载
        videoOverlay.videoIsBangumi = false
        videoOverlay.videoEpId = ""
        videoOverlay.videoSeasonId = ""

        if (hasOldVideo) {
            // 切换视频：旧页面先向下滑走，再弹出新页面
            videoVisible = true
            videoOverlay.doSwitch(bvid, title)
        } else {
            // 首次打开：直接播放打开动画
            videoOverlay.videoBvid = bvid
            videoOverlay.videoTitleText = title
            videoVisible = true
            videoOverlay.doOpen()
        }
    }

    function openBangumiPlayer(bvid, epId, seasonId, title) {
        var videoBvid = bvid
        if (!videoBvid || videoBvid.indexOf("bangumi_") === 0) {
            videoBvid = "bangumi_" + (epId || seasonId)
        }
        
        if (videoVisible && videoOverlay.videoBvid === videoBvid) {
            return
        }
        
        videoOverlay.videoTitleText = title
        videoOverlay.videoIsBangumi = true
        videoOverlay.videoEpId = epId
        videoOverlay.videoSeasonId = seasonId
        videoOverlay.videoBvid = videoBvid
        
        if (videoVisible && videoOverlay._playerCreated) {
            videoVisible = true
            videoOverlay.doSwitch(videoBvid, title, true, epId, seasonId)
        } else {
            videoVisible = true
            videoOverlay.doOpen()
        }
    }

    function closeVideoPlayer() {
        if (!videoVisible) return
        videoVisible = false
        videoOverlay.doClose()
    }

    function openLiveRoom(roomId, title, streamer) {
        if (liveVisible && liveOverlay.liveRoomId === roomId) {
            return
        }
        if (liveVisible && liveOverlay.liveRoomId !== roomId) {
            liveOverlay.doClose()
        }
        // 延迟到动画结束再设置 roomId，触发 onRoomIdChanged → loadStream
        liveOverlay._pendingOpenLiveRoomId = roomId
        liveOverlay._pendingOpenLiveTitle = title
        liveOverlay._pendingOpenLiveStreamer = streamer
        liveVisible = true
        liveOverlay.doOpen()
    }

    function closeLiveRoom() {
        if (!liveVisible) return
        liveVisible = false
        liveOverlay.doClose()
    }
}
