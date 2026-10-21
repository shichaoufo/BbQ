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
    property bool userProfileVisible: false

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
    // 详情区首屏评论是否在请求中（detailCommentLoadingMore 只管"加载更多"）。
    // 经 CommentPanel 的 commentLoading 传入，用于区分"还没拿到数据"与"确实没评论"。
    property bool detailCommentLoading: false
    property bool detailCommentHasNextPage: true
    property bool detailCommentLoadingMore: false

    // 左侧 UP 主列表
    ListModel { id: upListModel }
    // 综合动态列表
    // 两列瀑布流由 C++ 的 MasonryView 负责（单滚动源 + 虚拟化 + 零留白），
    // 这里只保留一个模型：列分配、累计高度、可见项创建/回收都在视图内部完成。
    ListModel { id: feedModel }

    // 触底加载：由外层的 Flickable 触发
    function _feedMaybeLoadMore(view) {
        if (!visible || loading || !hasMore) return
        if (view.contentHeight <= view.height) {
            if (_feedAutoLoadCount < 3) {
                _feedAutoLoadCount++
                loadMoreFeed()
            }
            return
        }
        if (view.contentY + view.height >= view.contentHeight - view.height * 2) {
            _feedAutoLoadCount = 0
            loadMoreFeed()
        }
    }

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

    // 详情页图片列表的修订号。
    // live_url 是 opus 接口异步补回来的，往 currentDynamic.images 的元素里
    // 加字段不会触发绑定通知（普通 JS 对象无变更信号），Repeater 不会重建。
    // 让相关 model / 取值函数都读一下这个计数器，就能在补数据时强制重算。
    property int _detailImagesRev: 0

    // 动态正文图片：单图高宽比超过此值即视为「长图」（容器高度封顶、取顶部一截 + 角标）。
    // 与评论区 commentImageMaxRatio 同口径，也与 PiliPlus imgMaxRatio 一致。
    readonly property real dynamicImageMaxRatio: 2.6

    // 图片网格间距：四处 GridLayout 的 rowSpacing / columnSpacing 都是 4。
    // 单图宽度三档里的 base = (列宽 - 2 * 间距) / 3 要用到它（PiliPlus 的 space 是 5）。
    readonly property int dynamicImageSpacing: 4

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

    // ============================================================================
    // 动态正文图片：排布 / 裁剪辅助（与评论区 commentXxx 系列、PiliPlus ImageGridView 同口径）
    //   图片数据统一为 {src, width, height}
    // ============================================================================

    // 网格列数：1 张 1 列；2 张 / 4 张 2 列；其余多图 3 列。
    //   4 张若按 3 列会排成「上三下一」，最后一张孤零零只占 1/3 宽。
    function dynamicGridColumns(count) {
        if (count <= 1) return 1
        if (count === 2 || count === 4) return 2
        return 3
    }

    // 长图判定（PiliPlus isLongPic 同口径）：高/宽 超过 2.6 倍，且原图足够宽。
    //   origWidth <= 0 表示接口没给尺寸（此时靠解码回填的比值判断，不再额外限宽）；
    //   宽 <= 100 的细长条不做封顶，避免把本来就窄的图再压扁。
    function dynamicImageIsLongPic(picRatio, origWidth) {
        if (picRatio <= 0) return false
        if (picRatio <= dynamicImageMaxRatio) return false
        return origWidth <= 0 || origWidth > 100
    }

    // 单图容器高度 = 单元格宽 × min(高宽比, 2.6)。超出 2.6 倍的部分靠顶部对齐裁掉，
    // 避免一张 1:10 的长图把卡片拉成一条。
    //   picRatio 传调用点的「已含解码回填」的比值（接口没给尺寸时用 onSourceSizeChanged 补上），
    //   传对象反而会让兜底失效（对象里 width=0 时拿不到回填值）。
    function dynamicSingleImageHeight(cellWidth, picRatio) {
        if (cellWidth <= 0) return 0
        var ratio = picRatio > 0 ? picRatio : 1
        return cellWidth * Math.min(ratio, dynamicImageMaxRatio)
    }

    // 单图宽度三档（PiliPlus _calcGridInfo 的 isSingle 分支逐句移植，与评论区
    // commentSingleImageSize 完全同口径）：
    //   picRatio = 原始 高/宽；origWidth = 原图宽（<=0 表示接口没给尺寸，此时不做「不放大」约束）
    //   宽/高 > 1.45（很宽的横图）          -> 占满正文列宽
    //   否则 宽 >= 高 或 高宽比 < 1.5       -> 2/3 列宽（多数横图 / 方图 / 略竖的图）
    //   否则（很竖的图）                     -> 1/2 列宽
    //   最后 min(原图宽) 以免把小图放大。
    function dynamicSingleImageWidth(containerWidth, origWidth, picRatio) {
        if (containerWidth <= 0) return 0
        var ratio = picRatio > 0 ? picRatio : 1
        var ratioWH = 1 / ratio
        var base = (containerWidth - dynamicImageSpacing * 2) / 3
        var outW
        if (ratioWH > 1.45) {
            outW = containerWidth
        } else if (ratioWH >= 1 || ratio < 1.5) {
            outW = 2 * base
        } else {
            outW = 1.5 * base
        }
        if (origWidth > 0) outW = Math.min(outW, origWidth)
        return Math.max(1, Math.min(outW, containerWidth))
    }

    // 网格宽度：单图按三档自适应，多图仍是 2/3 列宽（与视频卡片 1/3 列宽同行）。
    //   网格层只能用列表里的模型数据 —— 拿不到 delegate 里 onSourceSizeChanged 回填的比例，
    //   所以接口没给尺寸时比例记 0，宽度落回 2/3 档（与改造前一致，不会因为缺数据更糟）。
    function dynamicImageGridWidth(containerWidth, images) {
        if (!images || images.length !== 1) return containerWidth * 2 / 3
        var p = images[0] || {}
        var ratio = (p.width > 0 && p.height > 0) ? p.height / p.width : 0
        return dynamicSingleImageWidth(containerWidth, p.width > 0 ? p.width : 0, ratio)
    }

    // 方形缩略图的裁剪锚点。B 站图床 "@<w>w_<h>h_<anchor>.jpg" 的 anchor 实测
    // （fix3/cdn_crop_probe*.py 逐像素定位）：1e_1c = 居中；1e_2c = 左上；1e_3c = 右下。
    // 锚点是**服务端**裁剪，客户端再设 verticalAlignment 也救不回来 —— 必须在这里选对。
    //   竖图/方图（高 >= 宽）在方形格子里有多余的纵向空间 -> 取顶部(1e_2c)，
    //     否则会像官方预设那样把头部、正文开头居中裁掉；
    //   横图（高 < 宽）纵向没有余量，纵向锚点毫无意义，而 1e_2c 会连带变成「靠左裁」，
    //     所以横图继续用居中(1e_1c)。
    function dynamicCropAnchor(pic) {
        if (pic && pic.width > 0 && pic.height > 0 && pic.height >= pic.width) return "1e_2c"
        return "1e_1c"
    }

    // 动态图片 URL：包一层 GlobalState.fixImageUrl，把方形缩略图的服务端裁剪锚点
    // 由固定居中(1e_1c)换成按图片朝向选择（见 dynamicCropAnchor）。crop=false 时与 fixImageUrl 完全一致。
    function dynamicImageUrl(pic, width, height, crop) {
        var url = GlobalState.fixImageUrl(pic && pic.src ? pic.src : "", width, height, crop)
        if (crop && url.indexOf("_1e_1c.") >= 0)
            url = url.replace("_1e_1c.", "_" + dynamicCropAnchor(pic) + ".")
        return url
    }

    // 列表取图 URL（唯一入口）：
    //   · 单图且非长图 -> 取原比例图（不裁），客户端 PreserveAspectFit 完整显示；
    //   · 其余（多图任意 / 单图长图）-> 服务端按**容器比例**裁切：
    //       * 多图容器是正方形        -> 方图（锚点按朝向，见 dynamicCropAnchor）
    //       * 单图长图容器是 1 : 2.6  -> 顶部 2.6 倍高的一段
    //   易踩的坑：绝不能走 GlobalState.fixImageUrl(src, w, h, false) 那条路 ——
    //   它会拼出 "@<w>w_<h>h.jpg"（不带 _1c），语义是「等比塞进 WxH 框」(contain)：
    //   长图会被缩成几十像素宽的细条，再被客户端放大回格子 → 排布时糊、点开预览才清晰。
    function dynamicImageSource(container) {
        if (!container || !container.pic) return ""
        // 固定请求尺寸（见 GlobalState.imageThumbRequestWidth）：URL 与布局完全无关，
        // 窗口缩放时纯本地缩放，不会重新下载。
        // 高度只跟"设计比例"有关（方图 1:1、长图 1:2.6），不跟实际像素走。
        if (container.singleImage && !container.isLongPic)
            return GlobalState.fixImageUrl(container.pic.src,
                                           GlobalState.imageFullRequestWidth, 0, false)
        var ratio = container.isLongPic ? dynamic_page.dynamicImageMaxRatio : 1
        var w = GlobalState.imageThumbRequestWidth
        return dynamicImageUrl(container.pic, w, Math.max(1, Math.round(w * ratio)), true)
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
            // 切到其他导航页时关闭视频/直播播放器，避免声音串扰
            //（与 HomePage/HistoryPage 的既定行为一致）
            if (videoVisible) closeVideoPlayer()
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
            isVip: false,       // 大会员（user.vip.status==1）
            isTop: false,       // 置顶动态（module_author.is_top）
            hasCollect: false,  // 藏品：数字藏品(NFT)头像（user.face_nft==1）
            // 初始化完整 cardbg，show 强制 bool，避免 JSON.parse 回来后 show=undefined 导致 CommentCardBg 的 visible 赋值 bool 失败
            cardbg: { show: false, image: "", fanNumDesc: "", fanColor: "#FB7299" },
            time: "",
            // MODULE_TYPE_TITLE.module_title.text：活动/合集等标签（opus 里也当标题用）
            tagText: "",
            // 动态所属话题（module_dynamic.topic / MODULE_TYPE_TOPIC）：
            // 卡片底部那个可点的“话题”胶囊，链接形如 /v/topic/detail?topic_id=...
            topicName: "",
            topicId: "",
            topicJump: "",
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
                // 接口新版本给的是 pub_text（相对时间字符串），但不少条目（尤其转发内层）
                // 只有 pub_ts，pub_text 为空 —— 这里用时间戳补上，否则转发卡片没有时间
                result.time = authorData.pub_text || ""
                if (!result.time && authorData.pub_ts)
                    result.time = formatTime(Number(authorData.pub_ts))

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

                // ===== 大会员状态（vip.status: 0=无, 1=有效）=====
                if (user.vip) {
                    result.isVip = (Number(user.vip.status) === 1)
                }

                // ===== 置顶标记（module_author.is_top）=====
                // 详情页作者名配色与评论区一致：置顶 > 大会员 > 普通
                result.isTop = (authorData.is_top === true)

                // ===== 藏品：数字藏品（NFT）头像用户（face_nft: 0/1）=====
                result.hasCollect = (Number(user.face_nft) === 1)

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
            } else if (moduleType === "MODULE_TYPE_TITLE") {
                // 活动/合集标签。老格式是 module.module_title，opus 新格式里
                // 同一份数据也可能挂在 module_tag 下，两个都认
                var titleData = module.module_title || module.module_tag || {}
                result.tagText = titleData.text || ""
            } else if (moduleType === "MODULE_TYPE_TOPIC") {
                // opus 风格：话题单独成一个模块
                var topicMod = module.module_topic || {}
                if (topicMod.name) {
                    result.topicName = topicMod.name
                    result.topicId = String(topicMod.id || topicMod.topic_id || "")
                    result.topicJump = topicMod.jump_url || ""
                }
            } else if (moduleType === "MODULE_TYPE_DESC") {
                var descData = module.module_desc || {}
                result.content = descData.text || ""

                // ===== 正文跳转链接 jump_urls（评论区是 content.jump_url，动态是 module_desc.jump_url / desc_urls 等）=====
                //
                // 【2026-10-19】必须保留**完整条目**，不能只取 title 字符串。
                // 服务端在每条 jump_url 里除 title 外还下发：
                //   prefix_icon    前缀小图标（视频=播放图标、抽奖=礼物、商品=店铺图标）
                //   pc_url / app_url_schema  跳转目标（页面/协议的原始形态）
                //   underline / match_once / extra.is_word_search  渲染判据
                // 评论区（CommentManager::parseJumpUrls）就是按这套字段渲染的，
                // 所以那边能显示"播放图标+视频标题"；本页此前压成 {key: title}
                // 字符串，图标和真实标题一起丢掉，正文里只能退回"🔗网页链接"。
                // 注意：formatDynamicContent（列表卡片/转发卡片仍在用）已同步兼容
                // 对象与字符串两种形态。
                if (descData.jump_url) {
                    var jurls = descData.jump_url
                    if (typeof jurls === "object") {
                        var jkeys = Object.keys(jurls)
                        for (var jk = 0; jk < jkeys.length; jk++) {
                            var k = jkeys[jk]
                            var v = jurls[k]
                            if (v && typeof v === "object") {
                                var vExtra = v.extra || {}
                                result.jumpUrls[k] = {
                                    title: v.title || v.desc || k,
                                    prefixIcon: v.prefix_icon || "",
                                    icon: v.icon || "",
                                    pcUrl: v.pc_url || "",
                                    appUrlSchema: v.app_url_schema || "",
                                    underline: v.underline === true,
                                    matchOnce: v.match_once !== false,
                                    isWordSearch: vExtra.is_word_search === true
                                                  || v.is_word_search === true
                                }
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
                        result.jumpUrls[origText] = {
                            title: u.title || origText,
                            prefixIcon: u.prefix_icon || u.icon || "",
                            icon: u.icon || "",
                            pcUrl: u.pc_url || u.pc_url_normal || "",
                            appUrlSchema: u.app_url_schema || "",
                            underline: u.underline === true,
                            matchOnce: u.match_once !== false,
                            isWordSearch: (u.extra && u.extra.is_word_search === true)
                                          || u.is_word_search === true
                        }
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
                                // 节点自带的图标：rich_text_nodes 的 WEB / LOTTERY 节点可能
                                // 带 icon_url / icon_name（服务端下发的礼物、网页等小图）。
                                // jump_url 表里有完整条目时以表为准（那里的 title/prefix_icon
                                // 更权威），这里只在表里没有该 key（或只有字符串）时补一个
                                // 对象，**绝不用字符串覆盖已有的完整字段**
                                var rnIcon = ""
                                if (rn.icon_url != null && String(rn.icon_url).length > 0)
                                    rnIcon = fixHttp(String(rn.icon_url))
                                else if (rn.icon != null && String(rn.icon).length > 0)
                                    rnIcon = fixHttp(String(rn.icon))
                                // 节点的显示文案（rn.text）才是给人看的那一版：
                                //   BV 节点：orig_text 是裸网址，text 是"《XXX》视频标题"
                                //   WEB 节点：text 是"网页链接"
                                // 之前一律拿 orig_text 当标题，正文里就只能显示
                                // "▶ BV号"或一长串 https 网址。这里把 text 取出来当 title，
                                // 只要它不是网址、且不等同于原文占位文本就采用。
                                var rnText = (rn.text != null) ? String(rn.text) : ""
                                var rnTitle = ""
                                if (rnText && rnText !== rAnyText
                                        && !/^(https?:|ftp:|file:)\/\//i.test(rnText)
                                        && !/^\/\//.test(rnText)) {
                                    rnTitle = rnText
                                }
                                if (!result.jumpUrls[rAnyText] || typeof result.jumpUrls[rAnyText] === "string") {
                                    result.jumpUrls[rAnyText] = {
                                        title: rnTitle || rAnyText,
                                        prefixIcon: rnIcon,
                                        pcUrl: rLinkStr
                                    }
                                } else {
                                    var rnExist = result.jumpUrls[rAnyText]
                                    var rnExistTitle = rnExist.title ? String(rnExist.title) : ""
                                    // 表里已有条目但标题是裸网址/空 → 用节点标题补上
                                    if (rnTitle && (!rnExistTitle
                                                    || /^(https?:|ftp:|file:)\/\//i.test(rnExistTitle)
                                                    || rnExistTitle === rAnyText)) {
                                        rnExist.title = rnTitle
                                    }
                                    if (!rnExist.pcUrl) rnExist.pcUrl = rLinkStr
                                    if (!rnExist.prefixIcon && rnIcon) rnExist.prefixIcon = rnIcon
                                }
                                // BV 节点的 rid 就是 BV 号：正文里若出现裸 BV 号，也让它
                                // 能显示标题（同一稿件的两种写法都指向同一目标）
                                var rnRid = (rn.rid != null) ? String(rn.rid) : ""
                                if (/^BV[0-9A-Za-z]{10}$/i.test(rnRid)
                                        && result.content.indexOf(rnRid) >= 0) {
                                    result.jumpUrls[rnRid] = {
                                        title: rnTitle || rnRid,
                                        prefixIcon: rnIcon,
                                        pcUrl: rLinkStr
                                    }
                                }
                                result.urlList.push({
                                    text: rAnyText,
                                    location: rPos,
                                    length: (rLen && rLen > 0 ? rLen : rAnyText.length),
                                    jump_url: rLinkStr,
                                    iconUrl: rnIcon,
                                    iconName: (rn.icon_name != null ? String(rn.icon_name) : "")
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
                        // 动态表情源（gif_url / 个别版本 gifUrl / webp_url）：评论区
                        // CommentRichText 的 AnimatedImage 路径靠它播放动图。服务端不下发
                        // 时留空，_cmtEmoteIsAnimated 会自动退回静态渲染。
                        // 同样剥掉 @ 尺寸后缀，避免动图被拼成静图
                        var gifSrc = evv.gif_url || evv.gifUrl || evv.webp_url || ""
                        if (gifSrc) {
                            var atIdx2 = gifSrc.indexOf("@")
                            entry.gifUrl = atIdx2 >= 0 ? gifSrc.substring(0, atIdx2) : gifSrc
                        }
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
                // 话题（普通动态走这里；opus 走上面的 MODULE_TYPE_TOPIC）
                var dynTopic = dynamicData.topic || {}
                if (dynTopic.name) {
                    result.topicName = dynTopic.name
                    result.topicId = String(dynTopic.id || dynTopic.topic_id || "")
                    if (dynTopic.jump_url)
                        result.topicJump = dynTopic.jump_url
                    else if (result.topicId)
                        result.topicJump = "https://www.bilibili.com/v/topic/detail?topic_id="
                                             + encodeURIComponent(result.topicId)
                                             + "&topic_name=" + encodeURIComponent(result.topicName)
                }
                if (dataType === "MDL_DYN_TYPE_DRAW") {
                    var draw = dynamicData.dyn_draw || {}
                    var drawItems = draw.items || []
                    for (var k = 0; k < drawItems.length; k++) {
                        // 接口在每张图上同时给了 src / width / height，必须一并保留：
                        //   width/height 用于按原始比例决定单图容器高度、判定长图、选择裁剪锚点。
                        //   只存 src 就会丢失比例信息，只能退回「正方形 + 居中裁」，正是要修的问题。
                        var drawItem = drawItems[k]
                        result.images.push({
                            src: drawItem.src || "",
                            width: drawItem.width || 0,
                            height: drawItem.height || 0
                        })
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

    // ===== 动态正文 → 评论区富文本架构的桥接 =====
    //
    // 背景：详情页/列表卡片原来用本页自研的 formatDynamicContent（基于
    // rich_text_nodes 的 location/length 做精准替换 + 若干 fallback 正则）输出
    // 一整块 HTML 给 FluText(RichText)。评论区则走 GlobalState.formatCommentSegments
    // + CommentRichText（token 扫描 + jump_url 富渲染 + 动态表情 AnimatedImage +
    // openCommentLink 统一路由）。两套实现能力有差距：
    //   · 动态表情：评论区能播 gif，本页旧实现只会画第一帧
    //   · jump_url：评论区有 title/prefixIcon/underline/matchOnce 等完整渲染
    //   · 链接路由：评论区统一走 openCommentLink（video:/user:/search:/web:）
    //
    // 字段映射：
    //   content    -> message（原样透传，含 \n）
    //   emotes     -> emotes（补 gifUrl/isAnimated）
    //   atList[type=1] -> atNameToMid（key 去掉 @ 前缀）
    //   topicList  -> topics（token 形态 "#关键词#"，点击跳官网搜索）
    //   jumpUrls   -> jumpUrls（完整对象，含服务端 title/prefixIcon）
    //   urlList    -> jumpUrls 追加（网页/互动抽奖链接）
    //   atList[type=3] -> jumpUrls 追加（投票，📊 前缀）
    //   videos     -> **仅用于本地兜底**：服务端 jump_url 没给标题时，
    //                 用同稿件的动态视频卡片标题补上（见下方 sanitize 段）
    //
    // 该函数是"字段版"，列表 delegate（字段来自 *Json 角色）与详情页
    // （dynamicBodySegments 包装）共用，保证两处渲染完全一致。
    function dynamicSegmentsOf(content, emotesIn, jumpUrlsIn, atList, topicList, urlList, videos) {
        var emotes = {}
        var srcEmotes = emotesIn || {}
        for (var ek in srcEmotes) {
            var e = srcEmotes[ek]
            if (!e || !e.url) continue
            var entry = { url: e.url, width: (e.width > 0) ? e.width : 24, height: (e.height > 0) ? e.height : 24 }
            // 动态表情源：服务端字段名历史上是 gif_url，个别版本是 gifUrl
            var gif = e.gifUrl || e.gif_url || ""
            if (gif) { entry.gifUrl = gif; entry.isAnimated = true }
            emotes[ek] = entry
        }

        var ats = atList || []
        var atNameToMid = {}
        for (var i = 0; i < ats.length; i++) {
            var a = ats[i]
            if (parseInt(a.type) !== 1) continue
            var name = String(a.text || "").replace(/^@+/, "")
            var mid = a.data ? String(a.data) : ""
            if (name && mid && mid !== "0" && mid !== "NaN") atNameToMid[name] = mid
        }

        var topics = {}
        var tls = topicList || []
        for (var j = 0; j < tls.length; j++) {
            var t = tls[j]
            var kw = t.keyword || String(t.text || "").replace(/^#|#$/g, "")
            if (kw) topics[kw] = { jumpUrl: t.jump_url || "" }
        }

        var jumpUrls = {}
        var ju = jumpUrlsIn || {}
        for (var jk in ju) jumpUrls[jk] = ju[jk]
        var urls = urlList || []
        for (var u = 0; u < urls.length; u++) {
            var U = urls[u]
            var txt = String(U.text || "")
            if (!txt) continue
            var jump = (U.jump_url && String(U.jump_url).length > 0) ? String(U.jump_url) : ""
            // jump_url 表里已有完整条目（含服务端 title / prefix_icon）时以它为准，
            // 这里只补 urlList 独有的图标（rich_text_nodes 的 icon_url）
            var exist = jumpUrls[txt]
            if (exist && typeof exist === "object" && exist.title) {
                if (!exist.prefixIcon && U.iconUrl) exist.prefixIcon = U.iconUrl
                if (!exist.pcUrl && jump) exist.pcUrl = jump
                continue
            }
            jumpUrls[txt] = {
                title: txt,
                prefixIcon: U.iconUrl || "",
                pcUrl: jump
            }
        }
        for (var v = 0; v < ats.length; v++) {
            var A = ats[v]
            if (parseInt(A.type) !== 3) continue
            var vt = String(A.text || "")
            if (vt) jumpUrls[vt] = { title: "📊" + vt }
        }

        // ===== 标题/图标兜底（服务端字段不全时的最后一道）=====
        //
        // 实测（2026-10-19 抓包 polymer/web-dynamic 接口，20+ 条样本）：
        //   · LOTTERY 节点只有 {orig_text:"互动抽奖", rid, text:"互动抽奖", jump_url}，
        //     **没有 icon_url / prefix_icon** —— 官方接口根本不给礼物图案，
        //     网页端的礼物图标是前端静态资源。所以礼物只能用本地 emoji 兜底。
        //   · BV 节点 text 字段才是视频标题（orig_text 是裸网址），已在上面的
        //     解析里取用；只有拿不到标题时才退回 BV 号（用户认可）。
        //   · WEB 节点 text = "网页链接"。
        // 兜底规则：
        //   · 能识别出稿件（BV/av 号命中动态自带的 videos 卡片）→ 用卡片标题，
        //     无图标时补 "▶ " 文本前缀
        //   · 链接含 lottery → 一律补 "🎁 互动抽奖"（服务端标题也叫这个，
        //     但**没有图标**，所以这里不管 rawTitle 是否为空都要补 emoji，
        //     否则正文里就是光秃秃四个字 —— 之前"没有礼物图标"就是这个原因）
        //   · 其余长 URL → "🔗 网页链接"（不把原始网址塞进正文）
        // 有 server prefixIcon 时不再叠 emoji（避免"图标+emoji"双重前缀）。
        var vids = videos || []
        var videoTitleFor = function (s) {
            if (!s) return ""
            var m = /BV[0-9A-Za-z]{10}/.exec(String(s))
            var am = m ? null : /[Aa][Vv](\d+)/.exec(String(s))
            for (var vi = 0; vi < vids.length; vi++) {
                var vd = vids[vi] || {}
                if (m && vd.bvid && String(vd.bvid).toLowerCase() === m[0].toLowerCase())
                    return String(vd.title || "")
                if (am && vd.aid && String(vd.aid) === am[1])
                    return String(vd.title || "")
            }
            // 号对不上卡片，但整条动态只有一张稿件卡片、且这个链接确实是稿件：
            // 用那张卡的标题（比裸 BV 号可读）
            if (vids.length === 1 && vids[0] && vids[0].title
                    && (m || am || /bilibili\.com\/video/i.test(String(s)))) {
                return String(vids[0].title)
            }
            // 没匹配到卡片但有明确 BV 号：显示号本身也比裸网址可读
            return m ? m[0] : ""
        }
        for (var key in jumpUrls) {
            var ent = jumpUrls[key]
            if (typeof ent === "string") ent = { title: ent }
            // 话题 token（#xxx#）由扫描器的 topics 分支渲染成搜索链接，
            // 这里的 jumpUrls 条目只是副产品（值往往是 search.bilibili.com 的 URL），
            // 不参与渲染，也不能被下面的网页兜底改成"🔗 网页链接"
            if (/^#[^#]+#$/.test(key)) {
                jumpUrls[key] = ent
                continue
            }
            var rawTitle = ent.title ? String(ent.title) : ""
            var target = String(ent.pcUrl || ent.appUrlSchema || key || "")
            var bareUrl = /^(https?:|ftp:|file:)\/\//i.test(rawTitle)
                           || (rawTitle === key && /^(https?:|ftp:|file:)\/\//i.test(key))
            var vidTitle = videoTitleFor(key) || videoTitleFor(target)
            var hasIcon = !!ent.prefixIcon
            var isLottery = /lottery/i.test(target) || /lottery/i.test(key)
            // 是否真的是一条网页链接（@用户/话题/投票 的 target 不是 http，
            // 它们由扫描器的 at/topic 分支消费，不会走到这里；这里再判一次，
            // 避免给"@某人"这种普通文本挂上链接图标）
            var isWebLink = /^https?:\/\//i.test(target) || /^https?:\/\//i.test(key)
            if (vidTitle) {
                // 播放标签：服务端有 prefix_icon（B站自己的播放小图）就用图，
                // 没有就用 "▶ " —— 注意即使 rawTitle 已经是真实标题也要加，
                // 否则标题一到位图标就没了（上一版就是这个毛病）
                var showTitle = (rawTitle && !bareUrl) ? rawTitle : vidTitle
                ent.title = (hasIcon ? "" : "▶ ") + showTitle.replace(/^▶\s*/, "")
            } else if (isLottery) {
                // 服务端只给"互动抽奖"四个字、没有图标 → 统一补礼物 emoji
                var lotTitle = (rawTitle && !bareUrl) ? rawTitle : "互动抽奖"
                ent.title = (hasIcon ? "" : "🎁 ") + lotTitle.replace(/^🎁\s*/, "")
            } else if (isWebLink || !rawTitle || bareUrl) {
                // 链接标签：同样优先服务端图标，否则 "🔗 "
                var webTitle = (rawTitle && !bareUrl) ? rawTitle : "网页链接"
                ent.title = (hasIcon ? "" : "🔗 ") + webTitle.replace(/^🔗\s*/, "")
            }
            jumpUrls[key] = ent
        }

        return GlobalState.formatCommentSegments(content || "", emotes, topics, atNameToMid, jumpUrls, {
            linkColor: "#00A1D6",
            hasPlayer: false,
            durationMs: 0,
            showPrefixIcon: true,
            enableTimeRe: false   // 动态正文里的 12:34 不是视频时间戳，不染
        })
    }

    // 详情页包装：从 currentDynamic 风格的对象里取字段，转给字段版
    function dynamicBodySegments(d) {
        if (!d) return []
        return dynamicSegmentsOf(d.content || "", d.emotes || {}, d.jumpUrls || {},
                                 d.atList || [], d.topicList || [], d.urlList || [],
                                 d.videos || [])
    }

    // 动态正文富文本链接点击：评论区统一路由先行，其不消费的形态
    // （如 bili://vote/ 提示）回落本页原有 openLinkHelper。
    // App 必须显式传入：GlobalState 是 pragma Singleton，内部取不到
    // main.cpp 注册的上下文属性 App。
    function openDynamicRichLink(link) {
        if (GlobalState.openCommentLink(link, App)) return
        dynamic_page.openLinkHelper(link)
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
                    // jumpUrls 的 value 有两种形态：
                    //   · 2026-10-19 之后：完整对象 {title, prefixIcon, pcUrl, appUrlSchema, ...}
                    //     （与评论区的 JumpUrlInfo 同构，详情页正文交给评论区渲染器用）
                    //   · 旧形态：标题字符串，或可直接打开的 URL
                    // 本函数（列表卡片 / 转发卡片摘要）只需要标题与跳转目标，
                    // 图标不在这里渲染（RichText 路径不支持拼前缀小图）。
                    var jv = jumpUrls[jkey]
                    var jtitle = jkey
                    var jhref = ""
                    if (jv && typeof jv === "object") {
                        jtitle = jv.title || jkey
                        var cand = jv.pcUrl || jv.appUrlSchema || ""
                        if (/^(https?:\/\/|bilibili:\/\/|bili:\/\/)/.test(cand)) jhref = cand
                    } else {
                        jtitle = jv || jkey
                        if (typeof jv === "string" && jv !== jkey
                            && /^(https?:\/\/|bilibili:\/\/|bili:\/\/)/.test(jv)) {
                            jhref = jv
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

    // 把"列表里的 ListModel 元素"还原成详情页能安全使用的普通对象。
    //
    // 为什么需要：openDynamicDetail(itemData) 传进来的 itemData 是 feedModel 的
    // 元素，而 ListModel 对数组/对象 role 的 round-trip 不可靠（见
    // appendDynamicItem 处的长注释）—— 直接读 itemData.images 可能拿到一个
    // **没有 length 的对象**，于是 detailImageGrid.imageCount 被赋成 undefined：
    //   "Unable to assign [undefined] to int"
    // 同一份数据在列表 delegate 里一直是走 imagesJson/forwardJson 解析的
    // （见 itemImages / itemForward），详情页却直接读原 role，两边不一致。
    //
    // 这里统一从 *Json 角色重建数组/对象，保证详情页拿到的永远是真正的数组。
    // 只做浅拷贝 + 覆盖这几个键，其余角色原样带过去。
    // parseDynamicDetail 产出的对象没有 *Json 键，会被原样返回，行为不变。
    function normalizeDynamicForDetail(d) {
        if (!d) return d
        var out = {}
        var k
        for (k in d) out[k] = d[k]
        var jsonKeys = ["images", "videos", "lives", "forward",
                        "emotes", "jumpUrls", "cardbg",
                        "atList", "topicList", "urlList"]
        for (var i = 0; i < jsonKeys.length; i++) {
            var key = jsonKeys[i]
            var jk = key + "Json"
            if (d[jk] !== undefined) {
                try {
                    out[key] = JSON.parse(d[jk])
                } catch (e) {
                    console.warn("[DynamicPage] normalizeDynamicForDetail parse failed:", key, e)
                }
            }
        }
        return out
    }

    function openDynamicDetail(dynamic) {
        // 取消可能 pending 的关闭清理（关闭后 250ms 内又重开），避免清掉新数据
        detailCleanupTimer.stop()
        currentDynamic = normalizeDynamicForDetail(dynamic)
        detailCommentModel.clear()
        detailCommentTotal = 0
        detailCommentLoading = false
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
            detailCommentLoading = false
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
            // --- 1) bili://user/MID → 弹出该用户的主页 ---
            //
            // 与另外两处入口保持完全一致：
            //   · 搜索页搜出用户后点击（SearchPage: App.openUserProfile(m, unm, upic, vType)）
            //   · 评论区点击用户头像（CommentPanel: App.openUserProfile(mid, name, face)）
            // 都是走 App 的全局信号，由当前可见页面弹出 UserProfilePage overlay。
            //
            // 早先这里的做法是「切到动态页左侧 UP 主列表并加载 ta 的动态」，
            // 语义不对：用户点 @人名 预期是看这个人的主页，不是把动态流过滤成 TA。
            // 且那条路径还有 dynamic_page.upListModel 的属性查找 bug（已废弃）。
            //
            // 只传 mid：UserProfilePage.ensureLoaded() 会自行 loadUserInfo()
            // 拉到 name/face/签名/等级等，传空串不会影响展示。
            if (href.indexOf("bili://user/") === 0) {
                var mid = href.substring("bili://user/".length)
                if (mid.indexOf("?") >= 0) mid = mid.substring(0, mid.indexOf("?"))
                if (mid.indexOf("#") >= 0) mid = mid.substring(0, mid.indexOf("#"))
                mid = String(parseInt(mid, 10))
                if (!mid || mid === "NaN" || mid === "0") {
                    infoBar.showWarning("无效的用户ID：" + rawHref)
                    return
                }
                App.openUserProfile(mid, "", "", -1)
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

    // 预览图元素取值：detailPreviewImages 现为 {src,width,height} 对象数组，
    // 这里统一取 src 并兼容可能残留的纯字符串元素。
    function previewImageSrc(pic) {
        if (pic === null || pic === undefined) return ""
        if (typeof pic === "object") return pic.src || ""
        return String(pic)
    }

    function previewCurrentImageUrl() {
        return GlobalState.fixImageUrl(previewImageSrc(detailPreviewImages[detailPreviewIndex]))
    }

    function previewCurrentImageIsAnimated() {
        return GlobalState.isAnimatedImageUrl(previewImageSrc(detailPreviewImages[detailPreviewIndex]))
    }

    // 当前预览图的实况视频地址（live_url）。空串表示不是实况照片。
    // 读一下 _detailImagesRev：live_url 可能在预览已打开后才补回来，
    // 不依赖它这个绑定不会重算，预览里就不会切到视频
    function previewCurrentLiveUrl() {
        var rev = _detailImagesRev
        var pic = detailPreviewImages[detailPreviewIndex]
        if (pic && typeof pic === "object" && pic.liveUrl)
            return String(pic.liveUrl)
        return ""
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
            // 实况照片的 live_url 只有 opus 接口下发，补拉一次。
            // desktop 接口（本函数用的那个）会把 live_url 剥掉，只能另找接口要
            dynamic_page.fetchLiveUrls(dynamic.id_str)
        }
    }

    // 拉取实况照片的动态视频地址（live_url）。
    // 失败/无实况图时静默返回，不影响主流程
    function fetchLiveUrls(idStr) {
        if (!idStr) return
        Api.getOpusDetail(idStr)
    }

    // 把 opus 接口下发的 pics[].live_url 按下标合并进 currentDynamic.images[]。
    //
    // 两个接口的 pics 顺序与数量一致（已用同一动态实测验证），所以能按下标对位。
    // 合并后必须 _detailImagesRev++：currentDynamic 是普通 JS 对象，往它的
    // images 元素里加字段不会触发任何绑定通知，Repeater 不会重建，
    // Live 徽标和预览里的视频都出不来。
    function mergeLiveUrls(data) {
        try {
            var doc = JSON.parse(typeof data === "string" ? data : data.toString())
            if (doc.code !== 0 || !doc.data) return
            var mods = doc.data.item && doc.data.item.modules
            if (!mods) return
            var pics = null
            for (var i = 0; i < mods.length; i++) {
                var top = mods[i] && mods[i].module_top
                var album = top && top.display && top.display.album
                if (album && album.pics && album.pics.length) {
                    pics = album.pics
                    break
                }
            }
            if (!pics) return
            if (!currentDynamic || !currentDynamic.images) return
            var changed = false
            for (var j = 0; j < pics.length && j < currentDynamic.images.length; j++) {
                var lu = pics[j] && pics[j].live_url
                if (lu && currentDynamic.images[j]) {
                    currentDynamic.images[j].liveUrl = lu
                    changed = true
                }
            }
            if (changed) {
                _detailImagesRev++
                dynamic_page.writeBackLiveUrls()
            }
        } catch (e) {
            console.warn("[DynamicPage] mergeLiveUrls failed:", e)
        }
    }

    // 把 live_url 回写进 feedModel 对应项，让「全部动态」列表网格也能显示 Live 角标。
    //
    // 列表接口（desktop/v1/feed/all）和详情接口一样都不下发 live_url，唯一拿到它
    // 的地方就是详情页那次 opus 调用。给每条列表项各发一次 opus 请求太浪费
    // （绝大多数动态根本没有实况照片），所以采用**渐进式回填**：用户第一次点进
    // 某条动态的详情，这条动态的图片就带上 live_url 了，之后在列表里能看到角标。
    //
    // 写 imagesJson 而不是直接改 images：列表 delegate 读的是
    // JSON.parse(itemData.imagesJson)，且 ListModel 只有 setProperty 才会发
    // role 变更通知、触发 delegate 重建
    function writeBackLiveUrls() {
        if (!currentDynamic || !currentDynamic.id_str) return
        var json = ""
        try {
            json = JSON.stringify(currentDynamic.images || [])
        } catch (e) {
            return
        }
        _feedPatchImages(currentDynamic.id_str, json)
    }

    function _feedPatchImages(idStr, json) {
        for (var i = 0; i < feedModel.count; i++) {
            var it = feedModel.get(i)
            if (it && String(it.id_str) === String(idStr)) {
                feedModel.setProperty(i, "imagesJson", json)
                return
            }
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
        detailCommentLoading = true
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
        detailCommentLoading = true
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

                // 自己（当前账号本人）——PiliPlus 同款布局：紧跟「全部动态」，
                // 关注列表之前。点选后走与关注对象完全相同的两条数据链路：
                //   视频 Tab → /x/space/arc/list?mid=<自己的mid>（本人的投稿）
                //   动态 Tab → /feed/all?host_mid=<自己的mid>（本人的动态）
                // 未登录（或拿不到 mid）时整条隐藏——没有 mid 可点
                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 56
                    visible: Login.isLoggedIn && Login.userMid > 0

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 4
                        radius: 8
                        color: Number(currentUpMid) === Login.userMid ? FluTheme.itemCheckColor : "transparent"
                        layer.enabled: Number(currentUpMid) === Login.userMid
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
                            source: Login.userFace
                            placeholderText: Login.userName ? Login.userName.charAt(0) : "我"
                        }

                        FluText {
                            Layout.fillWidth: true
                            text: Login.userName || "我"
                            font: Theme.fontNormal
                            color: Number(currentUpMid) === Login.userMid ? FluTheme.fontPrimaryColor : FluTheme.fontSecondaryColor
                            elide: Text.ElideRight
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: selectUp(Login.userMid, Login.userName, Login.userFace)
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

                                // ===== 两列瀑布流 =====
                                // 滚动只由这一个 Flickable 负责（整页唯一滚动条）；
                                // 列分配、累计高度、可见项的创建与回收都在 MasonryView（C++）里。
                                // 之前用两个 ListView 互为镜像，两份 contentHeight 和两套
                                // 边界夹紧必然错位：滑块乱跳、一列空白、到底后滚轮还能滚。
                                Flickable {
                                    id: feedFlick
                                    anchors.fill: parent
                                    anchors.leftMargin: dynamic_page.margins
                                    anchors.topMargin: dynamic_page.margins
                                    anchors.bottomMargin: dynamic_page.margins
                                    clip: true
                                    boundsBehavior: Flickable.StopAtBounds
                                    contentWidth: width
                                    contentHeight: feedMasonry.contentHeight
                                    ScrollBar.vertical: FluScrollBar {}

                                    onContentYChanged: dynamic_page._feedMaybeLoadMore(feedFlick)

                                    MasonryView {
                                        id: feedMasonry
                                        width: feedFlick.width - Theme.scrollBarReserve
                                        model: feedModel
                                        delegate: feedCardComponent
                                        columnCount: 2
                                        rowSpacing: Theme.spacingMedium
                                        columnSpacing: Theme.spacingMedium
                                        viewportY: feedFlick.contentY
                                        viewportHeight: feedFlick.height
                                        cacheBuffer: 600
                                    }
                                }

                                // 卡片委托：宽度由 MasonryView 统一设置（列宽随窗口变化）
                                Component {
                                    id: feedCardComponent

                                    Rectangle {
                                        // 窄卡时收起装扮卡、放宽内嵌视频/直播卡
                                        readonly property bool narrowCard: width > 0 && width < 520
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
                                        // 两列后卡片只有半宽：不隐藏（详情页有列表却没有会很奇怪），
                                        // 改成等比缩小并保持右边缘对齐
                                        scale: narrowCard ? 0.78 : 1
                                        transformOrigin: Item.Right
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

                                        // ====== 活动/合集标签（MODULE_TYPE_TITLE.module_title.text）======
                                        // 官方卡片把它放在作者行上方，这里保持同样位置；无标签时不占位
                                        Rectangle {
                                            Layout.alignment: Qt.AlignLeft
                                            Layout.preferredWidth: tagTextItem.implicitWidth + Theme.spacingMedium * 2
                                            Layout.preferredHeight: 22
                                            radius: 4
                                            color: FluTheme.frameColor
                                            visible: itemData && itemData.tagText && String(itemData.tagText).length > 0

                                            FluText {
                                                id: tagTextItem
                                                anchors.centerIn: parent
                                                text: itemData && itemData.tagText ? String(itemData.tagText) : ""
                                                font: Theme.fontSmall
                                                color: FluTheme.fontSecondaryColor
                                            }
                                        }

                                        // 头部：头像 + 用户名 + 时间
                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: Theme.spacingSmall
                                            // 右侧给装扮留空间（现在装扮 width=175 + 24px 额外间距），避免头像/昵称行与装扮重叠
                                            // 装扮缩放到 0.78 后视觉宽度约 140，这里按同一比例让位
                                            Layout.rightMargin: (itemCardbg && itemCardbg.show)
                                                                ? (narrowCard ? 152 : 190) : 0

                                            // ====== 头像框 AvatarWithPendant（替代纯 CircleAvatar），与评论区一致 ======
                                            AvatarWithPendant {
                                                face: itemData ? itemData.face : ""
                                                pendantImage: (itemData && itemData.pendantImage) ? itemData.pendantImage : ""
                                                avatarSize: 40
                                                pendantScale: 1.5
                                                verifyType: itemData ? (itemData.verifyType !== undefined ? itemData.verifyType : -1) : -1
                                                isVip: itemData ? (itemData.isVip === true) : false
                                                hasCollect: itemData ? (itemData.hasCollect === true) : false
                                                Layout.alignment: Qt.AlignTop
                                                placeholderText: itemData && itemData.author ? itemData.author.charAt(0) : ""
                                            }

                                            ColumnLayout {
                                                Layout.fillWidth: true
                                                spacing: 2

                                                FluText {
                                                    text: itemData ? itemData.author : ""
                                                    font: Theme.fontNormal
                                                    // 与评论区/详情页一致：置顶 → 主色，
                                                    // 大会员 → 粉 #FB7299，普通 → 次级灰。
                                                    // 之前这里写死 Theme.primary，所有 UP 主
                                                    // 都是粉色，会员身份完全没体现。
                                                    color: (itemData && itemData.isTop === true)
                                                           ? FluTheme.primaryColor
                                                           : ((itemData && itemData.isVip === true)
                                                              ? "#FB7299"
                                                              : FluTheme.fontSecondaryColor)
                                                }

                                                FluText {
                                                    text: itemData ? itemData.time : ""
                                                    font: Theme.fontSmall
                                                    color: FluTheme.fontTertiaryColor
                                                }
                                            }
                                        }

                                        // ====== 话题胶囊（module_dynamic.topic / MODULE_TYPE_TOPIC）======
                                        // 官方位置在正文开头，单独一行；点击进话题详情
                                        Rectangle {
                                            id: topicChip
                                            Layout.alignment: Qt.AlignLeft
                                            Layout.preferredWidth: topicChipText.implicitWidth + Theme.spacingMedium * 2
                                            Layout.preferredHeight: 24
                                            radius: 12
                                            color: topicMa.containsMouse ? FluTheme.itemHoverColor
                                                                          : FluTheme.frameColor
                                            visible: itemData && itemData.topicName
                                                     && String(itemData.topicName).length > 0

                                            FluText {
                                                id: topicChipText
                                                anchors.centerIn: parent
                                                text: itemData && itemData.topicName ? String(itemData.topicName) : ""
                                                font: Theme.fontSmall
                                                color: FluTheme.primaryColor
                                            }

                                            MouseArea {
                                                id: topicMa
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    var url = itemData ? String(itemData.topicJump || "") : ""
                                                    if (!url && itemData && itemData.topicId)
                                                        url = "https://www.bilibili.com/v/topic/detail?topic_id=" + itemData.topicId
                                                    if (url) dynamic_page.openDynamicRichLink(url)
                                                }
                                            }
                                        }

                                        // 文本内容（评论区同款富文本架构，与详情页共用
                                        // dynamicSegmentsOf：@用户/话题/网页·抽奖链接/
                                        // AV·BV 号/静态与动态表情/换行）
                                        // 截断逻辑见 ClampedRichText：按整行裁切 + 独立一行的「查看更多」
                                        ClampedRichText {
                                            Layout.fillWidth: true
                                            Layout.preferredHeight: implicitHeight
                                            maxLines: 5
                                            // 只有视频/图片、没有正文时整个隐藏：
                                            // 否则 ColumnLayout 仍会为它留一段 spacing，
                                            // 表现为"视频和发布时间之间空一大截"
                                            visible: itemData && itemData.content
                                                     && String(itemData.content).length > 0
                                            segments: dynamic_page.dynamicSegmentsOf(
                                                          itemData ? itemData.content : "",
                                                          itemEmotes,
                                                          itemJumpUrls,
                                                          itemAtList,
                                                          itemTopicList,
                                                          itemUrlList,
                                                          itemVideos)
                                            bodyFont: Theme.fontNormal
                                            bodyColor: FluTheme.fontPrimaryColor
                                            onLinkActivated: function(link) {
                                                dynamic_page.openDynamicRichLink(link)
                                            }
                                            onMoreClicked: {
                                                if (itemData) openDynamicDetail(itemData)
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
                                                        verifyType: itemHasForward ? (itemForward.verifyType !== undefined ? itemForward.verifyType : -1) : -1
                                                        isVip: itemHasForward ? (itemForward.isVip === true) : false
                                                        hasCollect: itemHasForward ? (itemForward.hasCollect === true) : false
                                                        placeholderText: itemHasForward && itemForward.author ? itemForward.author.charAt(0) : ""
                                                    }
                                                    FluText {
                                                        text: itemHasForward ? itemForward.author : ""
                                                        font: Theme.fontSmall
                                                        // 与主卡片/评论区一致：大会员粉色，普通灰色
                                                        color: itemHasForward && itemForward.isVip === true
                                                               ? "#FB7299" : FluTheme.fontSecondaryColor
                                                    }
                                                    // 发布时间（接口多数只给 pub_ts，由 parseDynamicItem 兜底格式化）
                                                    FluText {
                                                        text: itemHasForward ? (itemForward.time || "") : ""
                                                        font: Theme.fontSmall
                                                        color: FluTheme.fontTertiaryColor
                                                        visible: text.length > 0
                                                    }
                                                }

                                                // 转发内容：同样按整行截断（3 行）+ 独立一行的「查看更多」
                                                ClampedRichText {
                                                    Layout.fillWidth: true
                                                    Layout.preferredHeight: implicitHeight
                                                    maxLines: 3
                                                    segments: itemHasForward
                                                              ? dynamic_page.dynamicSegmentsOf(
                                                                    itemForward.content || "",
                                                                    itemForward.emotes || {},
                                                                    itemForward.jumpUrls || {},
                                                                    itemForward.atList || [],
                                                                    itemForward.topicList || [],
                                                                    itemForward.urlList || [],
                                                                    itemForward.videos || [])
                                                              : []
                                                    bodyFont: Theme.fontSmall
                                                    bodyColor: FluTheme.fontPrimaryColor
                                                    onLinkActivated: function(link) {
                                                        dynamic_page.openDynamicRichLink(link)
                                                    }
                                                    onMoreClicked: {
                                                        // 转发内容被截断时进原动态详情看全文
                                                        if (itemHasForward && itemForward)
                                                            dynamic_page.openDynamicDetail(itemForward)
                                                    }
                                                }

                                                // 转发图片
                                                GridLayout {
                                                    // 单图按三档宽度自适应；多图撑满转发区宽度
                                                    Layout.fillWidth: itemForwardImageCount > 1
                                                    Layout.alignment: itemForwardImageCount > 1 ? Qt.AlignHCenter : Qt.AlignLeft
                                                    Layout.preferredWidth: itemForwardImageCount === 1
                                                                           ? dynamic_page.dynamicImageGridWidth(forwardColumn.width, itemForward.images)
                                                                           : forwardColumn.width
                                                    columns: dynamic_page.dynamicGridColumns(itemForwardImageCount)
                                                    rowSpacing: dynamic_page.dynamicImageSpacing
                                                    columnSpacing: dynamic_page.dynamicImageSpacing
                                                    visible: itemForwardImageCount > 0

                                                    Repeater {
                                                        model: itemForward.images

                                                        Rectangle {
                                                            id: forwardImageContainer
                                                            Layout.fillWidth: true
                                                            Layout.preferredHeight: forwardImageContainer.singleImage
                                                                                    ? dynamic_page.dynamicSingleImageHeight(forwardImageContainer.width, forwardImageContainer.picRatio)
                                                                                    : forwardImageContainer.width
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

                                                            property var pic: modelData || {}
                                                            property bool singleImage: itemForwardImageCount === 1
                                                            // 接口没给尺寸时，用解码出的真实宽高比回填（与评论区同口径）
                                                            property real decodedRatio: 0
                                                            property real picRatio: {
                                                                if (pic.width > 0 && pic.height > 0) return pic.height / pic.width
                                                                if (decodedRatio > 0) return decodedRatio
                                                                return 0
                                                            }
                                                            property bool isLongPic: dynamic_page.dynamicImageIsLongPic(picRatio, pic.width)

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
                                                                sourceComponent: GlobalState.isAnimatedImageUrl(forwardImageContainer.pic.src) ? cardForwardAnimatedImage : cardForwardStaticImage
                                                            }

                                                            Component {
                                                                id: cardForwardStaticImage
                                                                FluImage {
                                                                    anchors.fill: parent
                                                                    // 单图取原比例图（不裁）；多图非长图让 CDN 裁方省流量；
                                                                    // 多图长图取原比例图，交给客户端顶部对齐裁切
                                                                    source: dynamic_page.dynamicImageSource(forwardImageContainer)
                                                                    fillMode: (forwardImageContainer.singleImage && !forwardImageContainer.isLongPic) ? Image.PreserveAspectFit : Image.PreserveAspectCrop
                                                                    verticalAlignment: forwardImageContainer.isLongPic ? Image.AlignTop : Image.AlignVCenter
                                                                    asynchronous: true
                                                                    cache: true
                                                                    smooth: true
                                                                    onSourceSizeChanged: {
                                                                        if (forwardImageContainer.pic.width <= 0 && sourceSize.width > 0 && sourceSize.height > 0)
                                                                            forwardImageContainer.decodedRatio = sourceSize.height / sourceSize.width
                                                                    }
                                                                }
                                                            }

                                                            Component {
                                                                id: cardForwardAnimatedImage
                                                                AnimatedImage {
                                                                    anchors.fill: parent
                                                                    // 动图走 fixImageUrl 时短路返回原图 URL，保证动画可播放
                                                                    source: dynamic_page.dynamicImageSource(forwardImageContainer)
                                                                    fillMode: (forwardImageContainer.singleImage && !forwardImageContainer.isLongPic) ? Image.PreserveAspectFit : Image.PreserveAspectCrop
                                                                    verticalAlignment: forwardImageContainer.isLongPic ? Image.AlignTop : Image.AlignVCenter
                                                                    cache: true
                                                                    smooth: true
                                                                    playing: true
                                                                    onSourceSizeChanged: {
                                                                        if (forwardImageContainer.pic.width <= 0 && sourceSize.width > 0 && sourceSize.height > 0)
                                                                            forwardImageContainer.decodedRatio = sourceSize.height / sourceSize.width
                                                                    }
                                                                }
                                                            }

                                                            // 长图角标：提示只显示了顶部一截，点开可看完整
                                                            Rectangle {
                                                                anchors.right: parent.right
                                                                anchors.bottom: parent.bottom
                                                                anchors.margins: 6
                                                                width: forwardLongTag.implicitWidth + 10
                                                                height: forwardLongTag.implicitHeight + 4
                                                                radius: 4
                                                                color: Qt.rgba(0, 0, 0, 0.55)
                                                                visible: forwardImageContainer.isLongPic

                                                                FluText {
                                                                    id: forwardLongTag
                                                                    anchors.centerIn: parent
                                                                    text: "长图"
                                                                    font: FluTextStyle.Caption
                                                                    color: "white"
                                                                }
                                                            }
                                                        }
                                                    }
                                                }

                                                // 转发视频：与主卡一致，吃满转发区宽度
                                                ColumnLayout {
                                                    Layout.fillWidth: true
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

                                                // 转发直播：与转发视频一致
                                                ColumnLayout {
                                                    Layout.fillWidth: true
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
                                            // 单图按三档宽度自适应（见 dynamicImageGridWidth）；
                                            // 多图撑满列宽，只留格间间距（与评论区一致）
                                            Layout.fillWidth: itemImageCount > 1
                                            Layout.alignment: itemImageCount > 1 ? Qt.AlignHCenter : Qt.AlignLeft
                                            Layout.preferredWidth: itemImageCount === 1
                                                                   ? dynamic_page.dynamicImageGridWidth(feedCardColumn.width, itemImages)
                                                                   : feedCardColumn.width
                                            columns: dynamic_page.dynamicGridColumns(itemImageCount)
                                            rowSpacing: dynamic_page.dynamicImageSpacing
                                            columnSpacing: dynamic_page.dynamicImageSpacing
                                            visible: itemImageCount > 0

                                            Repeater {
                                                model: itemImages

                                                Rectangle {
                                                    id: feedImageContainer
                                                    Layout.fillWidth: true
                                                    Layout.preferredHeight: feedImageContainer.singleImage
                                                                           ? dynamic_page.dynamicSingleImageHeight(feedImageContainer.width, feedImageContainer.picRatio)
                                                                           : feedImageContainer.width
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

                                                    property var pic: modelData || {}
                                                    property bool singleImage: itemImageCount === 1
                                                    // 接口没给尺寸时，用解码出的真实宽高比回填（与评论区同口径）
                                                    property real decodedRatio: 0
                                                    // 角标基准字号。按容器宽度等比取，并夹在 [11, 20]：
                                                    // 多图格只有约 90px 宽，固定 12px 就小得几乎看不见；
                                                    // 但单图动辄三四百像素，同样字号又显得过小。固定值无法兼顾两者
                                                    readonly property real badgeUnit: Math.max(11, Math.min(20, feedImageContainer.width * 0.055))
                                                    property real picRatio: {
                                                        if (pic.width > 0 && pic.height > 0) return pic.height / pic.width
                                                        if (decodedRatio > 0) return decodedRatio
                                                        return 0
                                                    }
                                                    property bool isLongPic: dynamic_page.dynamicImageIsLongPic(picRatio, pic.width)

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
                                                        sourceComponent: GlobalState.isAnimatedImageUrl(feedImageContainer.pic.src) ? cardFeedAnimatedImage : cardFeedStaticImage
                                                    }

                                                    Component {
                                                        id: cardFeedStaticImage
                                                        FluImage {
                                                            anchors.fill: parent
                                                            // 单图（非长图）取原比例图；多图任意 / 单图长图 都让 CDN 按容器比例裁
                                                            // （走 dynamicImageSource，避免 contain 语义把长图缩糊）
                                                            source: dynamic_page.dynamicImageSource(feedImageContainer)
                                                            fillMode: (feedImageContainer.singleImage && !feedImageContainer.isLongPic) ? Image.PreserveAspectFit : Image.PreserveAspectCrop
                                                            verticalAlignment: feedImageContainer.isLongPic ? Image.AlignTop : Image.AlignVCenter
                                                            asynchronous: true
                                                            cache: true
                                                            smooth: true
                                                            onSourceSizeChanged: {
                                                                if (feedImageContainer.pic.width <= 0 && sourceSize.width > 0 && sourceSize.height > 0)
                                                                    feedImageContainer.decodedRatio = sourceSize.height / sourceSize.width
                                                            }
                                                        }
                                                    }

                                                    Component {
                                                        id: cardFeedAnimatedImage
                                                        AnimatedImage {
                                                            anchors.fill: parent
                                                            // 动图走 fixImageUrl 时短路返回原图 URL，保证动画可播放
                                                            source: dynamic_page.dynamicImageSource(feedImageContainer)
                                                            fillMode: (feedImageContainer.singleImage && !feedImageContainer.isLongPic) ? Image.PreserveAspectFit : Image.PreserveAspectCrop
                                                            verticalAlignment: feedImageContainer.isLongPic ? Image.AlignTop : Image.AlignVCenter
                                                            cache: true
                                                            smooth: true
                                                            playing: true
                                                            onSourceSizeChanged: {
                                                                if (feedImageContainer.pic.width <= 0 && sourceSize.width > 0 && sourceSize.height > 0)
                                                                    feedImageContainer.decodedRatio = sourceSize.height / sourceSize.width
                                                            }
                                                        }
                                                    }

                                                    // 长图角标：提示只显示了顶部一截，点开可看完整。
                                                    // 与 Live 角标互斥（同一位置，对齐 PiliPlus 的
                                                    // if (isLivePhoto) Live else if (isLongPic) 长图）
                                                    Rectangle {
                                                        anchors.right: parent.right
                                                        anchors.bottom: parent.bottom
                                                        anchors.margins: feedImageContainer.badgeUnit * 0.4
                                                        width: feedLongTag.implicitWidth + feedImageContainer.badgeUnit
                                                        height: feedLongTag.implicitHeight + feedImageContainer.badgeUnit * 0.6
                                                        radius: 4
                                                        color: Qt.rgba(0, 0, 0, 0.55)
                                                        visible: feedImageContainer.isLongPic && !feedImageContainer.pic.liveUrl

                                                        FluText {
                                                            id: feedLongTag
                                                            anchors.centerIn: parent
                                                            text: "长图"
                                                            font.pixelSize: feedImageContainer.badgeUnit
                                                            color: "white"
                                                        }
                                                    }

                                                    // 实况照片角标：静态图 + 动态视频，点开预览可播放。
                                                    // 与 PiliPlus 的 PBadge(text: 'Live') 同位置同语义
                                                    Rectangle {
                                                        anchors.right: parent.right
                                                        anchors.bottom: parent.bottom
                                                        anchors.margins: feedImageContainer.badgeUnit * 0.4
                                                        width: feedLiveTag.implicitWidth + feedImageContainer.badgeUnit
                                                        height: feedLiveTag.implicitHeight + feedImageContainer.badgeUnit * 0.6
                                                        radius: 4
                                                        color: Qt.rgba(0, 0, 0, 0.55)
                                                        visible: !!feedImageContainer.pic.liveUrl

                                                        FluText {
                                                            id: feedLiveTag
                                                            anchors.centerIn: parent
                                                            text: "Live"
                                                            font.pixelSize: feedImageContainer.badgeUnit
                                                            color: "white"
                                                        }
                                                    }
                                                }
                                            }
                                        }

                                        // 视频卡片：吃满当前列宽（只留卡片内边距）
                                        ColumnLayout {
                                            Layout.fillWidth: true
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

                                        // 直播卡片：与视频卡一致，吃满列宽
                                        ColumnLayout {
                                            Layout.fillWidth: true
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
                                            feedFlick.contentY = 0
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

    // 视频播放页/直播页/动态详情页/用户主页打开时，兜底拦截滚轮事件，
    // 防止其穿透到底层主页滚动视图。
    MouseArea {
        anchors.fill: parent
        z: 99
        enabled: videoVisible || liveVisible || detailVisible || userProfileVisible
        acceptedButtons: Qt.NoButton
        hoverEnabled: true
        onWheel: function(wheel) { wheel.accepted = true }
    }

    // ===== 用户主页 Overlay（动画/守卫模式与 HomePage userProfileOverlay 一致） =====
    // z 序：详情 101 < 用户主页 102 < 视频/直播 103。
    // 从视频打开主页时视频先关闭（openUserProfile 内处理），从主页打开
    // 视频时视频盖上主页；动态详情保留在主页之下
    Item {
        id: userProfileOverlay
        // 与 detailOverlay/videoOverlay 同几何：Frame 边距 + playerOverlayMargin
        // 内缩，所有弹出页尺寸统一（单边 margin 覆盖 margins 基数，故写成显式和）
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
                onClicked: { /* 仅消费事件，不遮挡内部交互 */ }
            }
            Loader {
                id: userProfileLoader
                anchors.fill: parent
                // 守卫：切导航栏时 dynamic_page.visible=false 会使 overlay 的
                // visible 从父级"流动"为 false，若不守卫会立即卸载销毁用户主
                // 页实例，切回导航时重新加载。userProfileVisible 是逻辑状态，
                // 不受父级隐藏影响（与 HomePage/SearchPage 同一模式）
                active: (userProfileOverlay.visible || dynamic_page.userProfileVisible) && userProfileOverlay._profileCreated
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
        z: 103
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
        z: 103
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

            // ===== 兜底右键（必须是本容器的第一个子项）=====
            // QML 同层"后声明者在上"。这条原本带 z:5 且声明在 RowLayout 之后，
            // 会把整个详情内容盖住 —— 评论卡片上的右键菜单因此永远收不到事件
            //（表现就是"右键任何地方都关掉动态详情"）。
            // 放到最前（并去掉 z:5）它才是真正的"兜底"：详情里没人处理的右键才轮到它。
            MouseArea {
                anchors.fill: parent
                enabled: detailVisible
                acceptedButtons: Qt.RightButton
                onClicked: function(mouse) {
                    if (mouse.button !== Qt.RightButton) return
                    // 评论右键菜单开着时：右键只收菜单，不关详情（右键菜单的通行约定）
                    if (detailCommentPanel.commentMenuOpened) {
                        detailCommentPanel.closeCommentMenu()
                        mouse.accepted = true
                        return
                    }
                    closeDynamicDetail()
                    mouse.accepted = true
                }
            }

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
                                        verifyType: currentDynamic ? (currentDynamic.verifyType !== undefined ? currentDynamic.verifyType : -1) : -1
                                        isVip: currentDynamic ? (currentDynamic.isVip === true) : false
                                        hasCollect: currentDynamic ? (currentDynamic.hasCollect === true) : false
                                        Layout.alignment: Qt.AlignTop
                                        placeholderText: currentDynamic && currentDynamic.author ? currentDynamic.author.charAt(0) : ""
                                    }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 2

                                    FluText {
                                        text: currentDynamic ? (currentDynamic.author || "") : ""
                                        font: Theme.fontNormal
                                        // 与评论区作者名同一规则（见 CommentPanel 的
                                        // color 绑定）：置顶用主色、大会员粉色 #FB7299、
                                        // 普通用户灰色。此前恒用 Theme.primary（粉色），
                                        // 导致普通会员的 UP 主名字也被染成粉色
                                        color: {
                                            if (!currentDynamic) return FluTheme.fontPrimaryColor
                                            if (currentDynamic.isTop === true) return FluTheme.primaryColor
                                            return currentDynamic.isVip === true
                                                   ? "#FB7299" : FluTheme.fontSecondaryColor
                                        }
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

                            // ====== 话题胶囊（与列表卡片一致，放在正文开头）======
                            Rectangle {
                                Layout.alignment: Qt.AlignLeft
                                Layout.preferredWidth: detailTopicText.implicitWidth + Theme.spacingMedium * 2
                                Layout.preferredHeight: 24
                                radius: 12
                                color: detailTopicMa.containsMouse ? FluTheme.itemHoverColor
                                                                   : FluTheme.frameColor
                                visible: currentDynamic && currentDynamic.topicName
                                         && String(currentDynamic.topicName).length > 0

                                FluText {
                                    id: detailTopicText
                                    anchors.centerIn: parent
                                    text: currentDynamic && currentDynamic.topicName ? String(currentDynamic.topicName) : ""
                                    font: Theme.fontSmall
                                    color: FluTheme.primaryColor
                                }

                                MouseArea {
                                    id: detailTopicMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        var url = currentDynamic ? String(currentDynamic.topicJump || "") : ""
                                        if (!url && currentDynamic && currentDynamic.topicId)
                                            url = "https://www.bilibili.com/v/topic/detail?topic_id=" + currentDynamic.topicId
                                        if (url) dynamic_page.openDynamicRichLink(url)
                                    }
                                }
                            }

                            // 文本内容（评论区同款富文本架构：CommentRichText +
                            // GlobalState.formatCommentSegments，见 dynamicBodySegments）
                            // 支持：@用户（点击开主页）/ 话题 / 网页与互动抽奖链接 /
                            // AV·BV 号（应用内播放）/ 静态与**动态**表情（gif 播放）/
                            // 换行；时间码按动态语义不识别
                            CommentRichText {
                                Layout.fillWidth: true
                                // 详情页在 Flickable 内部，显式把高度绑到 implicitHeight，
                                // 保证 ColumnLayout/Flickable.contentHeight 正确累加
                                // （原 FluText 用 contentHeight 绑定解决同一问题）
                                Layout.preferredHeight: implicitHeight
                                segments: dynamic_page.dynamicBodySegments(currentDynamic)
                                bodyFont: Theme.fontNormal
                                bodyColor: FluTheme.fontPrimaryColor
                                onLinkActivated: function(link) {
                                    dynamic_page.openDynamicRichLink(link)
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
                                property var forwardData: hasForwardData ? normalizeDynamicForDetail(currentDynamic.forward || {}) : {}
                                // 同样用 || 0 兜底，理由同 detailImageGrid.imageCount
                                property int forwardImageCount: {
                                    var imgs = forwardData.images
                                    return (imgs && imgs.length) || 0
                                }
                                property int forwardVideoCount: {
                                    var vids = forwardData.videos
                                    return (vids && vids.length) || 0
                                }
                                property int forwardLiveCount: {
                                    var lvs = forwardData.lives
                                    return (lvs && lvs.length) || 0
                                }

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
                                            verifyType: detailForwardCard.hasForwardData ? (detailForwardCard.forwardData.verifyType !== undefined ? detailForwardCard.forwardData.verifyType : -1) : -1
                                            isVip: detailForwardCard.hasForwardData ? (detailForwardCard.forwardData.isVip === true) : false
                                            hasCollect: detailForwardCard.hasForwardData ? (detailForwardCard.forwardData.hasCollect === true) : false
                                            placeholderText: detailForwardCard.forwardData.author ? detailForwardCard.forwardData.author.charAt(0) : ""
                                        }
                                        FluText {
                                            text: detailForwardCard.forwardData.author || ""
                                            font: Theme.fontSmall
                                            // 转发卡片作者名同详情页规则：大会员粉色，普通灰色
                                            color: detailForwardCard.hasForwardData
                                                   && detailForwardCard.forwardData.isVip === true
                                                   ? "#FB7299" : FluTheme.fontSecondaryColor
                                        }
                                    }

                                    // 详情页转发正文（评论区同款富文本架构，maxLines 5）
                                    CommentRichText {
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: implicitHeight
                                        maxLines: 5
                                        segments: detailForwardCard.hasForwardData
                                                  ? dynamic_page.dynamicSegmentsOf(
                                                        detailForwardCard.forwardData.content || "",
                                                        detailForwardCard.forwardData.emotes || {},
                                                        detailForwardCard.forwardData.jumpUrls || {},
                                                        detailForwardCard.forwardData.atList || [],
                                                        detailForwardCard.forwardData.topicList || [],
                                                        detailForwardCard.forwardData.urlList || [],
                                                        detailForwardCard.forwardData.videos || [])
                                                  : []
                                        bodyFont: Theme.fontSmall
                                        bodyColor: FluTheme.fontPrimaryColor
                                        onLinkActivated: function(link) {
                                            dynamic_page.openDynamicRichLink(link)
                                        }
                                    }

                                    GridLayout {
                                        Layout.fillWidth: false
                                        Layout.alignment: Qt.AlignLeft
                                        // 单图按三档宽度自适应（见 dynamicImageGridWidth），多图仍是 2/3 列宽
                                        Layout.preferredWidth: detailForwardCard.forwardImageCount === 1
                                                              ? dynamic_page.dynamicImageGridWidth(detailForwardColumn.width, detailForwardCard.forwardData.images)
                                                              : detailForwardColumn.width * 2 / 3
                                        columns: dynamic_page.dynamicGridColumns(detailForwardCard.forwardImageCount)
                                        rowSpacing: dynamic_page.dynamicImageSpacing
                                        columnSpacing: dynamic_page.dynamicImageSpacing
                                        visible: detailForwardCard.forwardImageCount > 0

                                        Repeater {
                                            model: detailForwardCard.forwardData.images || []

                                            Rectangle {
                                                id: forwardDetailImageContainer
                                                Layout.fillWidth: true
                                                Layout.preferredHeight: forwardDetailImageContainer.singleImage
                                                                        ? dynamic_page.dynamicSingleImageHeight(forwardDetailImageContainer.width, forwardDetailImageContainer.picRatio)
                                                                        : forwardDetailImageContainer.width
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

                                                property var pic: modelData || {}
                                                property bool singleImage: detailForwardCard.forwardImageCount === 1
                                                // 接口没给尺寸时，用解码出的真实宽高比回填（与评论区同口径）
                                                property real decodedRatio: 0
                                                property real picRatio: {
                                                    if (pic.width > 0 && pic.height > 0) return pic.height / pic.width
                                                    if (decodedRatio > 0) return decodedRatio
                                                    return 0
                                                }
                                                property bool isLongPic: dynamic_page.dynamicImageIsLongPic(picRatio, pic.width)

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
                                                    sourceComponent: GlobalState.isAnimatedImageUrl(forwardDetailImageContainer.pic.src) ? detailForwardAnimatedImage : detailForwardStaticImage
                                                }

                                                Component {
                                                    id: detailForwardStaticImage
                                                    FluImage {
                                                        anchors.fill: parent
                                                        // 单图取原比例图（不裁）；多图非长图让 CDN 裁方省流量；
                                                        // 多图长图取原比例图，交给客户端顶部对齐裁切
                                                        source: dynamic_page.dynamicImageSource(forwardDetailImageContainer)
                                                        fillMode: (forwardDetailImageContainer.singleImage && !forwardDetailImageContainer.isLongPic) ? Image.PreserveAspectFit : Image.PreserveAspectCrop
                                                        verticalAlignment: forwardDetailImageContainer.isLongPic ? Image.AlignTop : Image.AlignVCenter
                                                        asynchronous: true
                                                        cache: true
                                                        smooth: true
                                                        onSourceSizeChanged: {
                                                            if (forwardDetailImageContainer.pic.width <= 0 && sourceSize.width > 0 && sourceSize.height > 0)
                                                                forwardDetailImageContainer.decodedRatio = sourceSize.height / sourceSize.width
                                                        }
                                                    }
                                                }

                                                Component {
                                                    id: detailForwardAnimatedImage
                                                    AnimatedImage {
                                                        anchors.fill: parent
                                                        // 动图走 fixImageUrl 时短路返回原图 URL，保证动画可播放
                                                        source: dynamic_page.dynamicImageSource(forwardDetailImageContainer)
                                                        fillMode: (forwardDetailImageContainer.singleImage && !forwardDetailImageContainer.isLongPic) ? Image.PreserveAspectFit : Image.PreserveAspectCrop
                                                        verticalAlignment: forwardDetailImageContainer.isLongPic ? Image.AlignTop : Image.AlignVCenter
                                                        cache: true
                                                        smooth: true
                                                        playing: true
                                                        onSourceSizeChanged: {
                                                            if (forwardDetailImageContainer.pic.width <= 0 && sourceSize.width > 0 && sourceSize.height > 0)
                                                                forwardDetailImageContainer.decodedRatio = sourceSize.height / sourceSize.width
                                                        }
                                                    }
                                                }

                                                // 长图角标：提示只显示了顶部一截，点开可看完整
                                                Rectangle {
                                                    anchors.right: parent.right
                                                    anchors.bottom: parent.bottom
                                                    anchors.margins: 6
                                                    width: forwardDetailLongTag.implicitWidth + 10
                                                    height: forwardDetailLongTag.implicitHeight + 4
                                                    radius: 4
                                                    color: Qt.rgba(0, 0, 0, 0.55)
                                                    visible: forwardDetailImageContainer.isLongPic

                                                    FluText {
                                                        id: forwardDetailLongTag
                                                        anchors.centerIn: parent
                                                        text: "长图"
                                                        font: FluTextStyle.Caption
                                                        color: "white"
                                                    }
                                                }

                                                MouseArea {
                                                    anchors.fill: parent
                                                    // z:-1 垫底：让 FluImage 加载失败时的 Reload 按钮可点击
                                                    z: -1
                                                    cursorShape: Qt.ArrowCursor
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
                                // 单图走三档宽度，需要按内容宽度自适应，所以不再无条件 fillWidth；
                                // 多图保持原来的「占满内容宽度」。
                                Layout.fillWidth: detailImageGrid.imageCount !== 1
                                Layout.alignment: Qt.AlignLeft
                                Layout.preferredWidth: detailImageGrid.imageCount === 1
                                                      ? dynamic_page.dynamicImageGridWidth(detailContentColumn.width, currentDynamic.images)
                                                      : detailContentColumn.width
                                // 用 || 0 兜底：即使 images 因故拿到没有 length 的
                                // 对象，也只会当 0 处理，不会向 int 属性赋 undefined
                                property int imageCount: {
                                    var imgs = currentDynamic ? currentDynamic.images : null
                                    return (imgs && imgs.length) || 0
                                }
                                columns: dynamic_page.dynamicGridColumns(detailImageGrid.imageCount)
                                rowSpacing: dynamic_page.dynamicImageSpacing
                                columnSpacing: dynamic_page.dynamicImageSpacing
                                visible: detailImageGrid.imageCount > 0

                                Repeater {
                                    // 读一下 _detailImagesRev：live_url 是异步补回来的，
                                    // 不依赖它 Repeater 不会重建，Live 徽标出不来
                                    model: {
                                        dynamic_page._detailImagesRev
                                        return currentDynamic ? (currentDynamic.images || []) : []
                                    }

                                    Rectangle {
                                        id: detailImageContainer
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: detailImageContainer.singleImage
                                                                ? dynamic_page.dynamicSingleImageHeight(detailImageContainer.width, detailImageContainer.picRatio)
                                                                : detailImageContainer.width
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

                                        property var pic: modelData || {}
                                        property bool singleImage: detailImageGrid.imageCount === 1
                                        // 接口没给尺寸时，用解码出的真实宽高比回填（与评论区同口径）
                                        property real decodedRatio: 0
                                        // 角标基准字号，随容器宽度等比缩放（理由同 feedImageContainer.badgeUnit）
                                        readonly property real badgeUnit: Math.max(11, Math.min(20, detailImageContainer.width * 0.055))
                                        property real picRatio: {
                                            if (pic.width > 0 && pic.height > 0) return pic.height / pic.width
                                            if (decodedRatio > 0) return decodedRatio
                                            return 0
                                        }
                                        property bool isLongPic: dynamic_page.dynamicImageIsLongPic(picRatio, pic.width)

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
                                            sourceComponent: GlobalState.isAnimatedImageUrl(detailImageContainer.pic.src) ? detailFeedAnimatedImage : detailFeedStaticImage
                                        }

                                        Component {
                                            id: detailFeedStaticImage
                                            FluImage {
                                                anchors.fill: parent
                                                // 单图取原比例图（不裁）；多图非长图让 CDN 裁方省流量；
                                                // 多图长图取原比例图，交给客户端顶部对齐裁切
                                                source: dynamic_page.dynamicImageSource(detailImageContainer)
                                                fillMode: (detailImageContainer.singleImage && !detailImageContainer.isLongPic) ? Image.PreserveAspectFit : Image.PreserveAspectCrop
                                                verticalAlignment: detailImageContainer.isLongPic ? Image.AlignTop : Image.AlignVCenter
                                                asynchronous: true
                                                cache: true
                                                smooth: true
                                                onSourceSizeChanged: {
                                                    if (detailImageContainer.pic.width <= 0 && sourceSize.width > 0 && sourceSize.height > 0)
                                                        detailImageContainer.decodedRatio = sourceSize.height / sourceSize.width
                                                }
                                            }
                                        }

                                        Component {
                                            id: detailFeedAnimatedImage
                                            AnimatedImage {
                                                anchors.fill: parent
                                                // 动图走 fixImageUrl 时短路返回原图 URL，保证动画可播放
                                                source: dynamic_page.dynamicImageSource(detailImageContainer)
                                                fillMode: (detailImageContainer.singleImage && !detailImageContainer.isLongPic) ? Image.PreserveAspectFit : Image.PreserveAspectCrop
                                                verticalAlignment: detailImageContainer.isLongPic ? Image.AlignTop : Image.AlignVCenter
                                                cache: true
                                                smooth: true
                                                playing: true
                                                onSourceSizeChanged: {
                                                    if (detailImageContainer.pic.width <= 0 && sourceSize.width > 0 && sourceSize.height > 0)
                                                        detailImageContainer.decodedRatio = sourceSize.height / sourceSize.width
                                                }
                                            }
                                        }

                                        // 长图角标：提示只显示了顶部一截，点开可看完整。
                                        // 与 Live 角标互斥（同一位置，对齐 PiliPlus 的
                                        // if (isLivePhoto) Live else if (isLongPic) 长图）
                                        Rectangle {
                                            anchors.right: parent.right
                                            anchors.bottom: parent.bottom
                                            anchors.margins: detailImageContainer.badgeUnit * 0.4
                                            width: detailLongTag.implicitWidth + detailImageContainer.badgeUnit
                                            height: detailLongTag.implicitHeight + detailImageContainer.badgeUnit * 0.6
                                            radius: 4
                                            color: Qt.rgba(0, 0, 0, 0.55)
                                            visible: detailImageContainer.isLongPic && !detailImageContainer.pic.liveUrl

                                            FluText {
                                                id: detailLongTag
                                                anchors.centerIn: parent
                                                text: "长图"
                                                font.pixelSize: detailImageContainer.badgeUnit
                                                color: "white"
                                            }
                                        }

                                        // 实况照片角标：静态图 + 动态视频，点开预览可播放。
                                        // 与 PiliPlus 的 PBadge(text: 'Live') 同位置同语义
                                        Rectangle {
                                            anchors.right: parent.right
                                            anchors.bottom: parent.bottom
                                            anchors.margins: detailImageContainer.badgeUnit * 0.4
                                            width: detailLiveTag.implicitWidth + detailImageContainer.badgeUnit
                                            height: detailLiveTag.implicitHeight + detailImageContainer.badgeUnit * 0.6
                                            radius: 4
                                            color: Qt.rgba(0, 0, 0, 0.55)
                                            visible: !!detailImageContainer.pic.liveUrl

                                            FluText {
                                                id: detailLiveTag
                                                anchors.centerIn: parent
                                                text: "Live"
                                                font.pixelSize: detailImageContainer.badgeUnit
                                                color: "white"
                                            }
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            // z:-1 垫底：让 FluImage 加载失败时的 Reload 按钮可点击
                                            z: -1
                                            cursorShape: Qt.ArrowCursor
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
                                visible: {
                                    var vids = currentDynamic ? currentDynamic.videos : null
                                    return !!vids && vids.length > 0
                                }

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
                                visible: {
                                    var lvs = currentDynamic ? currentDynamic.lives : null
                                    return !!lvs && lvs.length > 0
                                }

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
                    // 评论永久链接基址：只有视频类动态（type=1，此时 oid 就是该视频的
                    // aid）能确定；动态/图文评论的链接需要"动态 id ↔ t.bilibili.com/<id>"
                    // 的对应关系，未核实，故留空 —— 留空时右键菜单不显示"复制评论链接"。
                    commentPermalinkBase: detailCommentType() === 1 && detailCommentOid() !== ""
                                          ? "https://www.bilibili.com/video/av" + detailCommentOid()
                                          : ""
                    sortByHeat: detailCommentSortByHeat
                    commentTotal: detailCommentTotal
                    commentLoading: detailCommentLoading
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

        // 预览层的鼠标交互：左键单击关闭、右键弹菜单。
        // 图片本身那一块由 ImageViewer 自己的左键 MouseArea 接管（拖动平移），
        // 那块区域里的「单击关闭」由 ImageViewer 的 clicked() 补上（见下）；
        // 右键 ImageViewer 不接收，会落回这里。
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: function(mouse) {
                if (mouse.button === Qt.RightButton)
                    detailPreviewMenu.openAt(mouse.x, mouse.y)
                else
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
            // 实况照片：非空时改用 MediaPlayer 播放 live_url 的 mp4
            liveUrl: dynamic_page.previewCurrentLiveUrl()
            // 左键单击（未拖动）＝ 关闭预览；放大后的拖动平移不会走到这里
            onClicked: dynamic_page.closeDetailImagePreview()
        }

        // 右键菜单：复制图片 / 下载图片 / 重置缩放
        ImagePreviewMenu {
            id: detailPreviewMenu
            imageUrl: dynamic_page.previewCurrentImageUrl()
            zoomed: detailImageViewer.zoomed
            notifyBar: infoBar
            onResetZoomRequested: detailImageViewer.reset()
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
        function onUserProfileOpenRequested(mid, name, face, verify) {
            if (!dynamic_page.visible) return
            dynamic_page.openUserProfile(mid, name, face, verify)
        }
        function onUserProfileCloseRequested() {
            dynamic_page.closeUserProfile()
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
        // opus 接口响应：只用来补实况照片的 live_url。
        // 不做 visible 守卫 —— 详情页可能已因切页而隐藏，但数据合并无副作用
        function onOpusDetailReceived(data) {
            dynamic_page.mergeLiveUrls(data)
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
        function onCommentsReady(comments, page, total, sort, hasNextPage, oid) {
            // 过滤其他评论面板（如视频播放页）的响应：两处 Connections 监听
            // 同一信号，无归属过滤时会互相覆盖对方的评论模型
            if (String(oid) !== String(detailCommentOid())) return
            // 空尾页回退：热度排序下服务端 is_end/next_offset 不精确，
            // 最后一个有内容的页仍可能报"有下一页"，再翻一页实际返回 0 条。
            // 此时保留上一页内容、页码回退一页并禁用"下一页"，
            // 而不是清空列表显示一个空尾页。预取机制正常时用户到不了这一步
            //（预取已提前禁用按钮），此处兜底预取返回前的点击竞态
            if (comments.length === 0 && detailCommentPage > 1) {
                detailCommentPage -= 1
                detailCommentLoadingMore = false
                detailCommentHasNextPage = false
                return
            }
            if (page > 0) {
                detailCommentPage = page
            }
            detailCommentLoadingMore = false
            detailCommentLoading = false
            if (detailCommentPage <= 1 || detailCommentTotal <= 0) {
                detailCommentTotal = total || comments.length
            }
            // hasNextPage 来自 API cursor.is_end/next_offset（权威）；
            // 数量判断（>=20）会因服务端每页返回数不固定而提前终止翻页
            if (hasNextPage !== undefined) {
                detailCommentHasNextPage = hasNextPage && comments.length > 0
            } else {
                detailCommentHasNextPage = comments.length >= 20
            }
            detailCommentModel.clear()
            var oid = detailCommentOid()
            for (var i = 0; i < comments.length; i++) {
                var c = comments[i]
                c.aid = oid
                c.repliesExpanded = false
                c.repliesJson = JSON.stringify([])
                c.repliesPage = 1
                // atNames 数组过 ListModel 会变嵌套模型对象（.length 失效），
                // 序列化为 JSON 字符串（与 VideoPlayerPage 同方案）
                c.atNamesJson = JSON.stringify(c.atNames || [])
                delete c.atNames
                detailCommentModel.append(c)
            }
            // 数据就位后再复位滚动：避免“先滚回顶部、再等加载”的两段式跳动
            detailCommentPanel.scrollToTop()
            // 预取下一页：后台探明真实尾页（空尾页提前禁用“下一页”），
            // 命中缓存时翻页零网络延迟
            if (detailCommentHasNextPage) {
                CommentManager.prefetchComments(detailCommentOid(), detailCommentType(), detailCommentPage + 1, 20, sort)
            }
        }
        function onPrefetchReady(oid, sort, page, hasContent) {
            // 只处理本动态评论的预取结果（排序切换期间的旧预取按 sort 过滤）
            if (String(oid) !== String(detailCommentOid())) return
            if (sort !== (detailCommentSortByHeat ? 2 : 1)) return
            // 预取的是当前页+1；返回空说明当前页即真实尾页，
            // 无需用户点一次“下一页”才发现
            if (page !== detailCommentPage + 1) return
            if (!hasContent)
                detailCommentHasNextPage = false
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
            // atNames 数组过 ListModel 会变嵌套模型对象，序列化（同上）
            comment.atNamesJson = JSON.stringify(comment.atNames || [])
            delete comment.atNames
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
            // 点赞/点踩失败此前被完全吞掉（空函数），用户点了没反应、计数却已经
            // 乐观地加过。失败一律提示；成功不提示（计数与图标变化即反馈）。
            if (!success) {
                infoBar.showWarning((message && message.length > 0) ? message : "操作失败")
            }
        }
        function onErrorOccurred(error) {
            console.warn("[DynamicPage] CommentManager error:", error)
            detailCommentLoadingMore = false
            // 首屏请求失败也要落闸，否则空列表会永远停在「正在加载评论...」
            detailCommentLoading = false
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

    // ===== 用户主页（状态机：详情 101 < 主页 102 < 视频/直播 103） =====
    // 入口：视频播放页 UP 信息区/评论区头像（先关视频）、动态详情页评论区
    // 头像（详情保留在主页之下）。关视频后若主页在下方则露出主页
    function openUserProfile(mid, name, face, verify) {
        // 若视频/直播打开中，先关闭。顺序必须在 same-mid 去重之前：
        // 下方已开着同用户主页时，也要关闭视频露出主页，而不是因去重
        // 提前返回让视频留在原地
        if (videoVisible) closeVideoPlayer()
        if (liveVisible) closeLiveRoom()
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
}
