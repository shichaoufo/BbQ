pragma Singleton
import QtQuick 2.15

QtObject {
    id: root

    // 推荐页全局状态，切换导航栏后仍保持
    property ListModel recommendModel: ListModel {}
    property real recommendScrollY: 0
    property real recommendContentHeight: 0
    property int recommendNextPage: 1
    property bool recommendLoading: false
    property int recommendEmptyStreak: 0
    property bool recommendManualRefresh: false
    property bool recommendHasMore: true

    // 热门页各分类数据（独立缓存，避免切换分类时重新加载）
    property string hotCurrentCategory: "all"
    property ListModel hotsAllModel: ListModel {}
    property real hotsAllScrollY: 0
    property int hotsAllPage: 0
    property bool hotsAllHasMore: true

    property ListModel hotsRankModel: ListModel {}
    property real hotsRankScrollY: 0
    property int hotsRankPage: 0
    property bool hotsRankHasMore: true
    property int hotsRankRid: 0

    property ListModel hotsWeeklyModel: ListModel {}
    property real hotsWeeklyScrollY: 0
    property int hotsWeeklyNumber: 0
    property var hotsWeeklyList: []
    property bool hotsWeeklyHasMore: true

    property ListModel hotsHistoryModel: ListModel {}
    property real hotsHistoryScrollY: 0
    property bool hotsHistoryHasMore: true

    // HomePage 当前 Pivot 索引
    property int homePivotIndex: 0

    // HistoryPage 当前 Pivot 索引（全部/视频/直播）
    property int historyPivotIndex: 0

    // 直播页全局状态
    property ListModel liveRecommendModel: ListModel {}
    property real liveRecommendScrollY: 0
    property real liveRecommendContentHeight: 0
    property ListModel liveFollowingModel: ListModel {}
    property real liveFollowingScrollY: 0
    property real liveFollowingContentHeight: 0
    property int livePivotIndex: 0
    property string liveCurrentArea: "全部"
    property string liveCurrentSubArea: "全部"
    property int liveCurrentParentAreaId: 0
    property int liveCurrentSubAreaId: 0
    property var liveAreas: [
        { name: "全部", subs: [{ name: "全部", id: 0 }], parentId: 0, subId: 0 }
    ]
    property bool liveAreasLoaded: false

    // 动态页全局状态
    property ListModel dynamicModel: ListModel {}
    property real dynamicScrollY: 0

    // 搜索页全局状态
    property string searchKeyword: ""
    property ListModel searchResultModel: ListModel {}
    property real searchScrollY: 0
    property bool searchHasSearched: false

    // ---- 应用内搜索请求（评论关键词 / 标签 / 话题统一走这里）----
    // 以前这些点击都是丢给系统浏览器打开 search.bilibili.com；现在客户端
    // 自己有搜索页，改为切到搜索页并直接弹出结果页。main.qml 监听本信号，
    // 因为它才持有导航容器和 SearchPage 实例（单例里取不到 App/页面对象）。
    signal inAppSearchRequested(string keyword)
    function openInAppSearch(keyword) {
        var kw = String(keyword || "").trim()
        if (kw === "") return false
        inAppSearchRequested(kw)
        return true
    }

    // ===== 页内弹层互斥（只服务还留在页面里的 live / detail）=====
    // 视频 / 用户主页 / 搜索结果已改由下面的牌堆统一管理，不再走这条广播。
    // 直播播放器和动态详情目前仍各自住在 DynamicPage / HistoryPage /
    // SearchResultPage / LivePage 里（不是牌），同一时间只保留一个实例：
    // 打开前广播一次，其它宿主收到后关掉自己那份。exceptHost 是发起方标识。
    signal pageTypeCloseRequested(string type, string exceptHost)
    function requestClosePagesOfType(type, exceptHost) {
        pageTypeCloseRequested(type, exceptHost)
    }

    // ============================================================
    // ===== 弹层牌堆（唯一权威，2026-10-27）=====
    // ============================================================
    // 语义：每种弹层页面 = 一张扑克牌。打开就是往牌堆上叠一张；同类型再次打开
    // = 把这张牌从底下抽出来、叠到最上面（抽出的动作 = 关掉它旧的内容，叠上去
    // = 在同一个实例里装新内容）。不管叠多少层，牌的总数是固定的那几张，
    // 只是在不断重排顺序。
    //
    // 数组顺序 = 叠放顺序，末尾 = 最上面（右键关闭的就是末尾那张）。
    // 以前是每个宿主页面自己维护 videoVisible/_overlayZSeq、再靠
    // requestClosePagesOfType 广播互相"关掉"来模拟，漏一处就出错；
    // 现在只有这一个列表说了算，页面不再持有叠放状态。
    property var _cardStack: []
    // z 只增不减：每次抽牌叠顶就取一个新值，保证"后叠的在上"。
    property int _cardZSeq: 100

    readonly property string topCard: _cardStack.length > 0 ? _cardStack[_cardStack.length - 1] : ""

    function hasCard(type) { return _cardStack.indexOf(type) >= 0 }

    // 抽牌 → 叠到最上面。返回本次分配的 z，调用方赋给牌实例。
    function bringCardToFront(type) {
        if (type === "") return _cardZSeq
        var a = _cardStack.slice()
        var i = a.indexOf(type)
        if (i >= 0) a.splice(i, 1)
        a.push(type)
        _cardStack = a
        _cardZSeq += 1
        console.log("[CardStack] +" + type + " => [" + a.join(" < ") + "] z=" + _cardZSeq)
        return _cardZSeq
    }

    function removeCard(type) {
        var i = _cardStack.indexOf(type)
        if (i < 0) return
        var a = _cardStack.slice()
        a.splice(i, 1)
        _cardStack = a
        console.log("[CardStack] -" + type + " => [" + a.join(" < ") + "]")
    }

    function clearCards() {
        if (_cardStack.length === 0) return
        _cardStack = []
        console.log("[CardStack] clear")
    }

    // 这张牌上面还压着几张（0 = 就在最上面）。被压住时只暂停，不关闭。
    function cardsAbove(type) {
        var i = _cardStack.indexOf(type)
        if (i < 0) return 0
        return _cardStack.length - 1 - i
    }

    // ============================================================
    // 评论 / 动态正文富文本渲染 —— 全项目唯一实现
    // ============================================================
    // BbQ 评论/动态正文富文本渲染 —— 全项目唯一实现
    // 设计依据（对照 PiliPlus reply_item_grpc.dart _buildMessage）：
    //   1) 能查服务端下发的表就绝不用正则猜；
    //   2) 服务端 token 在总正则里排最前，泛化模式垫底；
    //   3) 只在原始纯文本上扫一遍，绝不在已生成的 HTML 上二次扫；
    //   4) 词搜索热词（extra.is_word_search）默认不染。

    // 文本转义（用于正文片段）。
    // 注意：**Qt 富文本里裸换行符不是换行** —— QTextDocument 解析 HTML 时会把
    // 文本里的 \n 当普通空白折叠掉（等价于 HTML 的空白折叠规则）。这正是
    // "官方客户端会换行、我们挤成一行"的原因：B 站评论里 \n 极其常见，随手扫
    // 几十个视频的评论就能捞到一堆多行评论。必须显式换成 <br>。
    // 顺序不能反：先把 & < > 转义掉，再插入我们自己要生效的 <br>。
    function _cmtEscText(s) {
        return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
                        .replace(/\r\n?|\n/g, "<br>")
    }
    // 属性转义（用于 href / src）
    function _cmtEscAttr(s) {
        return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;")
    }
    // 正则元字符转义（把服务端 token 安全地拼进总正则）
    function _cmtEscRe(s) {
        return String(s).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
    }
    // 剥掉 URL 末尾标点（尾字符集与 PiliPlus 的 Constants.urlRegex 一致）
    function _cmtTrimUrlTail(u) {
        var m = /^(https?:\/\/[-A-Za-z0-9+&@#\/%?=~_|!:,.;]*[-A-Za-z0-9+&@#\/%=~_|])/.exec(u)
        return m ? m[1] : u
    }

    // ============ 链接目标解析 ============
    // 一条硬规矩：**绝不把非 http(s) 的 scheme 交给系统去打开**。
    //
    // 实测教训（用户亲历）：
    //   · 词搜索热词的 app_url_schema 是 bilibili://search?...，
    //     Windows 上没有注册 bilibili:// 处理程序时，ShellExecute 会
    //     "跳到微软商店搜索该协议" —— 用户点热词看到的就是这个；
    //   · 商品链接的 schema 还会是 tbopen://（淘宝）/ openapp.jdmobile://（京东）
    //     之类，交给系统则完全没反应。
    // 所以一律先把目标解析成"应用内动作"或"等价网页地址"，解析不出来就
    // 退化成只染色、不可点 —— 宁可点不动，也不能把用户扔到商店去。
    function _cmtSearchUrl(kw) {
        return "https://search.bilibili.com/all?keyword=" + encodeURIComponent(String(kw || ""))
    }
    function _cmtSearchKeyword(s) {
        var m = /[?&]keyword=([^&]*)/.exec(String(s || ""))
        if (!m) return ""
        var kw = m[1].replace(/\+/g, " ")
        try { return decodeURIComponent(kw) } catch (e) { return kw }
    }
    // 是不是站内搜索地址（话题/标签的 jump_url 常常就是 search.bilibili.com 的链接）
    function _cmtIsSearchUrl(u) {
        return /^https?:\/\/search\.bilibili\.com\//i.test(String(u || ""))
    }
    // bilibili:// 官方 scheme -> 等价网页地址；解析不出返回 ""
    function _cmtSchemaToWeb(schema, fallbackKeyword) {
        var s = String(schema || "")
        if (!s) return ""
        if (s.indexOf("http") === 0) return s        // 本来就是网页地址
        if (s.indexOf("bilibili://") !== 0) return "" // 第三方 scheme 一律不认
        var m
        if (s.indexOf("bilibili://search") === 0) {
            return _cmtSearchUrl(_cmtSearchKeyword(s) || fallbackKeyword)
        }
        if ((m = /^bilibili:\/\/video\/(BV[0-9A-Za-z]{10}|av[0-9]+)/i.exec(s))) {
            return "https://www.bilibili.com/video/" + m[1]
        }
        if ((m = /^bilibili:\/\/space\/(\d+)/.exec(s))) {
            return "https://space.bilibili.com/" + m[1]
        }
        if ((m = /^bilibili:\/\/live\/(\d+)/.exec(s))) {
            return "https://live.bilibili.com/" + m[1]
        }
        if ((m = /^bilibili:\/\/bangumi\/play\/(ep|ss)(\d+)/i.exec(s))) {
            return "https://www.bilibili.com/bangumi/play/" + m[1].toLowerCase() + m[2]
        }
        if ((m = /^bilibili:\/\/read\/(?:cv)?(\d+)/.exec(s))) {
            return "https://www.bilibili.com/read/cv" + m[1]
        }
        return ""
    }
    // 解析一条服务端 jump_url 该指向哪里。
    // 返回 { href: 内部目标（空=不可点）, web: 等价网页地址 }
    function _cmtResolveTarget(tok, e) {
        var web = ""
        var http = /^https?:\/\//i

        // 1) 视频号：token / schema / pc_url 任一处认得出 BV|av，就走应用内播放页
        var vid = _cmtVideoIdOf(tok) || _cmtVideoIdOf(e.appUrlSchema) || _cmtVideoIdOf(e.pcUrl)
        if (vid) return { href: "video:" + vid, web: "https://www.bilibili.com/video/" + vid }

        // 2) 词搜索热词：判据是服务端 extra.is_word_search（解析见 CommentManager::jsonFlag）。
        //    产品决定：保持染蓝 + 前置放大镜图标，但点击**改为打开官网搜索**，
        //    不再把 bilibili://search 丢给系统（那会跳微软商店）。
        if (e.isWordSearch === true) {
            var kw = _cmtSearchKeyword(e.appUrlSchema) || String(e.title || tok || "")
            if (!kw) return { href: "", web: "" }
            return { href: "search:" + kw, web: _cmtSearchUrl(kw) }
        }

        // 3) 网页目标优先序：pc_url → app_url_schema（可解析时）→ token 本身。
        //    商品链接实测 key 就是 https://b23.tv/mall-XXXX，必须能兜到这里：
        //    它的 app_url_schema 可能是 tbopen:// 这类打不开的第三方 scheme。
        if (http.test(String(e.pcUrl || ""))) web = e.pcUrl
        if (!web) web = _cmtSchemaToWeb(e.appUrlSchema, String(e.title || tok || ""))
        if (!web && http.test(tok)) web = _cmtTrimUrlTail(tok)
        if (web) return { href: "web:" + web, web: web }

        // 4) 解析不出目标：只染色不可点
        return { href: "", web: "" }
    }

    // ============ 前缀图标 ============
    // 图标渲染要同时满足三条：不裁剪、不变形、不放大。踩过两个坑，都记在这。
    //
    // 坑一：@<w>w_<h>h_1c 是"按目标宽高比取中心最大块，再缩放到目标尺寸"，
    //   **它一定会裁**。用一张 960x600 的封面图实测：
    //     @40h.jpg         → 64x40   等比缩放，画面完整
    //     @40w_40h_1c.jpg  → 40x40   从 960 宽里只取中心一块，横向裁掉 60%
    //   词搜索的放大镜图恰好是 36x66 的极窄长图（图案 27x27 落在第 11..37 行，
    //   上方 11px、下方 28px 是透明留白），所以 _1c 只裁它的上下、看着没问题；
    //   但商品标签是正方形/横幅图，同样的 _1c 会**横向切掉左右**——淘宝"淘"标签
    //   贴边的左边框线因此消失，京东图标内容内缩所以看不出来。
    //   （上一版用的是 @36w_36h_1c，1:1 裁剪对正方形图正好不裁，故"之前正常"。）
    //
    // 坑二：同时给 width 和 height 就是"非等比拉伸"。Qt 的
    //   QTextImageHandler::getSize 只把**已给出的**那一维照搬，另一维按图片
    //   真实比例算：
    //     if (!hasWidth)  size.setWidth (qRound(height * (srcW / srcH)))
    //     if (!hasHeight) size.setHeight(qRound(width  * (srcH / srcW)))
    //   所以"只给 height"就能拿到等比宽度，根本不用我们自己猜比例。
    //
    // 结论：让 CDN 等比缩放（@<h>h，只缩不裁），渲染时只给 height。
    //   源图取 40 像素高，是为了在高 DPI 屏上仍有 2x 采样（显示高度 20）。
    //   代价：放大镜画布上下共 39 行透明留白会被一并等比保留，图案由裁剪版的
    //   11.25px 变成约 8.2px。这是"不裁"的必然结果——留白是这张图的固有属性，
    //   想让它变大只能裁，而任何裁剪都会伤到其它类型的图标。
    // 只对站内 CDN 且未带处理后缀的地址加工；其他来源原样使用，避免改坏。
    function _cmtIconSrc(u) {
        var s = String(u || "")
        if (!s) return ""
        // 服务端给的图标常见协议相对形态（"//i0.hdslb.com/bfs/..."）：
        // Qt 富文本的 <img src> 不会替我们补协议，原样喂进去会加载失败（图标裂）。
        // 评论区的 prefix_icon 与动态的 jump_url/节点图标都可能走这条，统一补全。
        if (s.indexOf("//") === 0) s = "https:" + s
        if (s.indexOf("hdslb.com/") < 0) return s
        if (s.indexOf("@") >= 0) return s
        return s + "@40h.png"
    }
    function _cmtIconImg(u) {
        var src = _cmtIconSrc(u)
        if (!src) return ""
        // 只给 height，宽度交给 Qt 按图片真实比例推（见上）。给死 width 就会变形。
        return '<img src="' + _cmtEscAttr(src)
             + '" height="20" style="vertical-align:middle;">'
    }
    // ============ 断行 ============
    // 长 URL 在 Text.Wrap 下整串被当成一个"词"，没有任何断行机会，
    // 于是连续多个购物链接会横着顶出边界、整段不换行。
    // 在**可见文本**里插入零宽空格提供断点：不可见、不影响复制，
    // 但让 Qt 能在 / - . ? & = 之后换行（href 本身不加）。
    // 协议头（https://）整体保留，避免断成 "https:/" 换行。
    function _cmtBreakable(s) {
        var str = String(s)
        var head = ""
        var m = /^[a-zA-Z][a-zA-Z0-9+.\-]*:\/\//.exec(str)
        if (m) {
            head = m[0]
            str = str.substring(head.length)
        }
        var t = str.replace(/([\/\-_.?&=#,])/g, "$1\u200B")
        // 兜底：不含任何标点的超长拉丁串，每 24 字符插一个断点
        t = t.replace(/[0-9A-Za-z]{25,}/g, function (chunk) {
            var out = ""
            for (var i = 0; i < chunk.length; i += 24) {
                out += (i ? "\u200B" : "") + chunk.substring(i, i + 24)
            }
            return out
        })
        return head + t
    }
    // 从服务端 token / 原文里提取视频号。key 可能本身就是裸 BV/av 号
    //（实测 key="BV1do5ezGEkR"，app_url_schema 为空），旧实现只认带域名的
    // 形态，故裸号一律识别不出 → 不可点。
    // ============ b23.tv 短链解析（评论区链接客户端内跳转）============
    // 背景：评论区里 `https://b23.tv/WW3i6Ml` 这类**不含视频号的短链**在渲染
    // 阶段无法判断目标类型（可能是视频/专栏/直播/动态），只能标记成普通网页
    // 链接；点开时才请求短链、跟随 302 拿到最终地址，再决定走应用内还是浏览器。
    // `https://b23.tv/BV1G38w6BE6V?...` 带视频号的形态由 _cmtVideoIdOf 直接
    // 命中 video:，不会走到这里。
    //
    // 缓存：同一链接被点第二次直接用结果（键=原始短链，值=最终地址）
    property var _shortLinkCache: ({})
    // 等待解析结果的点击：{ 原始短链: { app: <发起点击的页面 App> } }。
    // 解析是异步的，期间用户可能已切页面——保存 App 是为了跳转仍落在发起页
    property var _shortLinkPending: ({})
    // 解析能力挂在 App（AppManager 唯一实例）上，而不是 QML 模块单例 Api：
    // GlobalState 是 pragma Singleton，import 自身模块会构成循环依赖，
    // 而所有 openCommentLink 调用点都把 App 传了进来。Connections 动态挂
    // 到它（target 为变量，换对象会自动重连）
    property var _shortLinkTarget: null
    // 注意：根是 QtObject，**没有 default property**，子对象不能裸声明，
    // 必须挂到某个属性上（否则启动报 "Cannot assign to non-existent
    // default property"）。target 为变量，换 App 对象会自动重连
    property Connections _shortLinkConn: Connections {
        target: root._shortLinkTarget
        function onShortLinkResolved(sourceUrl, finalUrl) {
            root._onShortLinkResolved(sourceUrl, finalUrl)
        }
    }

    // 是否为"需要解析"的短链：b23.tv / bili23.cn 且自身不含 BV/av 号
    function _cmtIsShortLink(u) {
        var s = String(u || "")
        if (!/^https?:\/\/(?:www\.)?(?:b23\.tv|bili23\.cn)\//i.test(s)) return false
        return _cmtVideoIdOf(s) === ""
    }

    // 发起解析（命中缓存则直接跳）
    function _cmtResolveShortLink(u, app) {
        // 没有 App 对象就没法发请求（理论上不会发生：所有调用点都传 App）；
        // 直接交浏览器，不能静默吞掉这次点击
        if (!app) {
            Qt.openUrlExternally(String(u))
            return
        }
        var cached = root._shortLinkCache[String(u)]
        if (cached) {
            root._cmtOpenResolvedUrl(cached, String(u), app)
            return
        }
        var pend = root._shortLinkPending
        pend[String(u)] = { app: app }
        root._shortLinkPending = pend
        root._shortLinkTarget = app
        app.resolveShortLink(String(u))
    }

    // 解析结果回来：缓存 + 分流；失败退回浏览器打开原始短链
    function _onShortLinkResolved(sourceUrl, finalUrl) {
        var pend = root._shortLinkPending[sourceUrl]
        delete root._shortLinkPending[sourceUrl]
        var app = pend ? pend.app : null
        if (!finalUrl) {
            Qt.openUrlExternally(sourceUrl)
            return
        }
        root._shortLinkCache[sourceUrl] = finalUrl
        root._cmtOpenResolvedUrl(finalUrl, sourceUrl, app)
    }

    // 最终地址分流：视频/用户主页走应用内，其余交给浏览器
    // （番剧不内部跳：AppManager.openBangumi 需要 epId/seasonId 等上下文，
    //   评论区链接给不出标题，内部打开体验不完整）
    function _cmtOpenResolvedUrl(finalUrl, sourceUrl, app) {
        var vid = _cmtVideoIdOf(finalUrl)
        if (vid) {
            var bvid = vid
            if (/^[Aa][Vv][0-9]+$/.test(vid)) {
                bvid = _cmtAvToBvid(parseInt(vid.substring(2), 10))
            }
            if (bvid) {
                if (app) app.openVideo(bvid, "")
                else Qt.openUrlExternally("https://www.bilibili.com/video/" + bvid)
                return
            }
        }
        var mm = /^https?:\/\/space\.bilibili\.com\/(\d+)/i.exec(String(finalUrl))
        if (mm && mm[1] !== "0") {
            if (app) app.openUserProfile(mm[1], "", "")
            else Qt.openUrlExternally(String(finalUrl))
            return
        }
        Qt.openUrlExternally(String(finalUrl))
    }

    function _cmtVideoIdOf(s) {
        if (!s) return ""
        var m = /^(BV[0-9A-Za-z]{10}|av[0-9]+)$/.exec(s)
        if (m) return m[1]
        m = /bilibili\.com\/video\/(BV[0-9A-Za-z]{10}|av[0-9]+)/i.exec(s)
        if (m) return m[1]
        m = /b23\.tv\/(BV[0-9A-Za-z]{10}|av[0-9]+)(?:[\/?#]|$)/i.exec(s)
        if (m) return m[1]
        // 服务端 schema 形态：bilibili://video/BV1xxxxxxxxx
        m = /bilibili:\/\/video\/(BV[0-9A-Za-z]{10}|av[0-9]+)/i.exec(s)
        if (m) return m[1]
        return ""
    }
    // 生成可点击链接。可见文本先过 _cmtBreakable 插零宽空格，
    // 否则长 URL 会整串顶出边界（见该函数注释）；href 保持原样不加。
    function _cmtLink(href, text, color, underline) {
        var deco = underline ? "underline" : "none"
        return '<a href="' + _cmtEscAttr(href) + '" style="color:' + color
             + ';text-decoration:' + deco + ';">' + _cmtEscText(_cmtBreakable(text)) + '</a>'
    }
    // 只染蓝、不可点
    function _cmtColorOnly(text, color) {
        return '<span style="color:' + color + ';">' + _cmtEscText(text) + '</span>'
    }

    // 渲染单个服务端 jump_url 条目
    function _cmtRenderJumpUrl(tok, entry, used, color, wordRe, opts) {
        var e = (entry && typeof entry === "object") ? entry
              : { title: (entry === undefined || entry === null) ? tok : String(entry) }

        // 词搜索热词（服务端 extra.is_word_search）：
        //   产品决定为"染蓝 + 前置图标 + 点击跳官网搜索"（默认开启）。
        //   若哪天觉得正文里的普通词被染得吵，调用方传 enableWordRe:false 即可
        //   退回"不染灰字"（PiliPlus 的默认行为）。
        if (e.isWordSearch === true && !wordRe) return _cmtEscText(tok)

        // 去重：同一 token 在同一段正文里只渲染一次可点链接。
        // 默认去重，与 PiliPlus 的 matchedUrls（注释"只显示一次"）一致；
        // 仅当服务端明确给出 match_once=false 时才允许逐次渲染。
        // 实测：词搜索条文带 match_once=true，BV 号那条是 false。
        if (e.matchOnce !== false) {
            if (used[tok]) return _cmtEscText(tok)
            used[tok] = true
        }

        var title = e.title ? String(e.title) : tok
        var t = _cmtResolveTarget(tok, e)

        var icon = ""
        if (opts && opts.showPrefixIcon === true && e.prefixIcon) {
            icon = _cmtIconImg(e.prefixIcon)
        }
        if (!t.href) return icon + _cmtColorOnly(title, color)
        return icon + _cmtLink(t.href, title, color, e.underline === true)
    }

    // 渲染单个 token
    function _cmtRenderToken(tok, at, raw, ctx) {
        // (a) 表情：只在服务端 emote 表里命中才渲染。
        //     注意这里刻意用静态 url 而非 gifUrl —— Qt 富文本 <img> 只画第一帧，
        //     用 gif 只会白白多下载几倍体积。动图要走 segment 方案（另议）。
        var em = ctx.emotes[tok]
        if (em) {
            var eurl = (typeof em === "string") ? em : (em.url || "")
            if (!eurl) return _cmtEscText(tok)
            var sz = (typeof em === "object" && em.width > 0) ? em.width : 24
            return '<img src="' + _cmtEscAttr(_cmtEmoteImgUrl(eurl, sz)) + '" width="' + sz + '" height="' + sz
                 + '" align="middle" style="vertical-align:middle;">'
        }

        // (b) @提及：只有服务端登记过才染，且必须拿到 mid 才可点
        if (tok.charAt(0) === "@") {
            var nm = tok.substring(1)
            if (Object.prototype.hasOwnProperty.call(ctx.atNameToMid, nm)) {
                return _cmtLink("user:" + ctx.atNameToMid[nm], tok, ctx.color)
            }
        }

        // (c) #话题#：同样只认服务端登记。本项目没有话题落地页，
        //     跳官网搜索（比"点不动"好，也不再走 bilibili://tag 那种会被
        //     系统丢给微软商店的 scheme）。
        if (tok.charAt(0) === "#" && tok.length > 2 && tok.charAt(tok.length - 1) === "#") {
            var kw = tok.substring(1, tok.length - 1)
            if (Object.prototype.hasOwnProperty.call(ctx.topics, kw)) {
                return _cmtLink("search:" + kw, tok, ctx.color)
            }
        }

        // (d) 投票：本项目无投票页，也没有等价网页地址 —— 只染色不可点
        //     （旧实现给的是 bili://vote/id，点下去什么都不会发生）
        if (/^\{vote:\d+\}$/.test(tok)) {
            return _cmtColorOnly("投票", ctx.color)
        }

        // (e) 服务端登记的跳转链接
        if (Object.prototype.hasOwnProperty.call(ctx.jumpUrls, tok)) {
            return _cmtRenderJumpUrl(tok, ctx.jumpUrls[tok], ctx.used, ctx.color, ctx.wordRe, ctx.opts)
        }

        // (f) 时间戳兜底：整串必须是时间 + 数字边界 + 时长校验，三者齐了才染
        var tm = /^(\d{1,2})[:：](\d{2})(?:[:：](\d{2}))?$/.exec(tok)
        if (tm) {
            var prev = at > 0 ? raw.charAt(at - 1) : ""
            var next = raw.charAt(at + tok.length)
            // 数字边界：挡住 "共123:45人" 这类从中间截出的 "23:45"
            if (!/[0-9]/.test(prev) && !/[0-9]/.test(next)) {
                var bad, sec
                if (tm[3] !== undefined) {
                    bad = (parseInt(tm[2], 10) >= 60 || parseInt(tm[3], 10) >= 60)
                    sec = parseInt(tm[1], 10) * 3600 + parseInt(tm[2], 10) * 60 + parseInt(tm[3], 10)
                } else {
                    bad = (parseInt(tm[2], 10) >= 60)
                    sec = parseInt(tm[1], 10) * 60 + parseInt(tm[2], 10)
                }
                // 超视频时长一律不染。旧实现是"钳到片尾"→ 点 99:59 会跳到结尾
                if (!bad && !(ctx.durationMs > 0 && sec * 1000 > ctx.durationMs)) {
                    if (ctx.hasPlayer) return _cmtLink("timestamp:" + (sec * 1000), tok, ctx.color)
                    return _cmtColorOnly(tok, ctx.color)
                }
            }
            return _cmtEscText(tok)
        }

        // (g) 裸 URL 兜底
        if (/^https?:\/\//.test(tok)) {
            var u = _cmtTrimUrlTail(tok)
            var tail = tok.substring(u.length)
            return _cmtLink("web:" + u, u, ctx.color) + (tail ? _cmtEscText(tail) : "")
        }

        return _cmtEscText(tok)
    }

    // ===== 主入口 =====
    // message      原始正文（未转义，可含 \n）
    // emotes       { "[微笑]": {url, width, height, gifUrl, isAnimated} }
    // topics       { "话题名": ... }
    // atNameToMid  { "用户名": mid }
    // jumpUrls     { "原文": {title, prefixIcon, appUrlSchema, pcUrl, underline, matchOnce, isWordSearch} }
    //              兼容旧格式：值直接是 title 字符串
    // opts         { durationMs, hasPlayer, enableWordRe, linkColor, showPrefixIcon }
    //              enableWordRe 控制词搜索热词是否染蓝可点，**默认开启**；
    //              传 false 即退回 PiliPlus 的默认行为（热词按普通文字显示）。
    //              enableTimeRe 控制是否识别 "12:34" 时间码，**默认开启**；
    //              传 false 则正文里的时间样式文本按普通文字处理。
    //              动态正文用 false（动态里的 12:34 多半不是视频时间戳，
    //              染蓝会造成误解）；评论区用默认值。

    // 把"收集 token + 组装总正则"抽出来，供下面两个渲染入口共用。
    // 每次调用都新建正则对象 —— 正则带 lastIndex 状态，复用会串味。
    function _cmtBuildScanner(message, emotes, topics, atNameToMid, jumpUrls, opts) {
        var o = opts || {}
        var raw = (message === undefined || message === null) ? "" : String(message)
        var ctx = {
            emotes: emotes || {},
            topics: topics || {},
            atNameToMid: atNameToMid || {},
            jumpUrls: jumpUrls || {},
            used: {},
            color: o.linkColor || "#00A1D6",
            wordRe: (o.enableWordRe !== false),
            hasPlayer: (o.hasPlayer === true),
            durationMs: (o.durationMs > 0) ? o.durationMs : 0,
            opts: o
        }

        // 1) 收集服务端 token（确定该染的），长 token 优先避免被短 token 抢先
        var toks = []
        var k
        for (k in ctx.emotes) if (k) toks.push(k)
        for (k in ctx.topics) if (k) toks.push("#" + k + "#")
        for (k in ctx.atNameToMid) if (k) toks.push("@" + k)
        for (k in ctx.jumpUrls) if (k) toks.push(k)
        toks.sort(function (a, b) { return b.length - a.length })

        // 2) 组装总正则：服务端 token 在前，泛化模式垫底（分组全非捕获，
        //    以免污染替换回调参数）。
        //    时间码模式可由 opts.enableTimeRe=false 关闭（动态正文不识别）。
        var alts = []
        for (var i = 0; i < toks.length; i++) alts.push(_cmtEscRe(toks[i]))
        if (o.enableTimeRe !== false)
            alts.push("(?:\\d{1,2})[:：]\\d{2}(?:[:：]\\d{2})?")
        alts.push("\\{vote:\\d+\\}")
        alts.push("https?:\\/\\/[-A-Za-z0-9+&@#\\/%?=~_|!:,.;]*[-A-Za-z0-9+&@#\\/%=~_|]")
        return { raw: raw, ctx: ctx, re: new RegExp(alts.join("|"), "g") }
    }

    // 单一 HTML 输出（原有行为，绝大多数评论走这条）。
    // 返回可直接给 Text.RichText 的 HTML
    function formatCommentRichText(message, emotes, topics, atNameToMid, jumpUrls, opts) {
        var sc = _cmtBuildScanner(message, emotes, topics, atNameToMid, jumpUrls, opts)
        var raw = sc.raw, re = sc.re, ctx = sc.ctx
        var out = ""
        var last = 0
        var m
        while ((m = re.exec(raw)) !== null) {
            if (m[0].length === 0) { re.lastIndex++; continue }   // 防空匹配死循环
            out += _cmtEscText(raw.substring(last, m.index))
            out += _cmtRenderToken(m[0], m.index, raw, ctx)
            last = m.index + m[0].length
        }
        out += _cmtEscText(raw.substring(last))
        return out
    }

    // 分段输出：把**动态表情**单独切出来交给 QML 侧的 AnimatedImage 播。
    //
    // 为什么非得分段：Qt 富文本里的 <img> 永远只画第一帧（QTextDocument 把图片
    // 当静态资源缓存），而 AnimatedImage 又没法嵌进 Text 内部。所以要让动态表情
    // 动起来，只能把正文拆成若干段、用 Flow 排版：
    //   文本段 -> Text（RichText，排版仍由 Qt 负责）
    //   表情段 -> AnimatedImage
    // 静态表情不受影响，仍然留在文本段里用 <img> 渲染。
    //
    // 返回 [{t:"text", html, breakAfter}, {t:"emote", url, gifUrl, size}]
    //   breakAfter=true 表示该段之后原文有换行 —— 渲染时该段宽度要占满整行，
    //   后续 item 才会从新行开始（等价于原文的换行）。
    //   Flow 的 item 是矩形，若把含 <br> 的一整块交给一个 Text，
    //   它的宽度是最长行的宽度，后面的表情会跑到"最长行"右侧而不是"最后一行"
    //   右侧，位置就错了 —— 所以 <br> 也必须切段。
    function formatCommentSegments(message, emotes, topics, atNameToMid, jumpUrls, opts) {
        var sc = _cmtBuildScanner(message, emotes, topics, atNameToMid, jumpUrls, opts)
        var raw = sc.raw, re = sc.re, ctx = sc.ctx
        var segs = []
        var buf = ""

        // 原文换行在 _cmtEscText 里已经变成 <br>，这里按 <br> 把缓冲再切开。
        // 连续换行产生的空段直接丢弃 —— 代价是"空行"会少一次，
        // 换来的是渲染层少一个"占位空行"的特殊分支。
        function flush() {
            if (buf === "") return
            var parts = buf.split("<br>")
            for (var i = 0; i < parts.length; i++) {
                if (parts[i] === "") continue
                segs.push({ t: "text", html: parts[i], breakAfter: (i < parts.length - 1) })
            }
            buf = ""
        }

        var last = 0
        var m
        while ((m = re.exec(raw)) !== null) {
            if (m[0].length === 0) { re.lastIndex++; continue }
            var em = ctx.emotes[m[0]]
            if (em && _cmtEmoteIsAnimated(em)) {
                buf += _cmtEscText(raw.substring(last, m.index))
                flush()
                segs.push(_cmtEmoteSegment(em))
            } else {
                buf += _cmtEscText(raw.substring(last, m.index))
                buf += _cmtRenderToken(m[0], m.index, raw, ctx)
            }
            last = m.index + m[0].length
        }
        buf += _cmtEscText(raw.substring(last))
        flush()
        return segs
    }

    // 评论表情的 CDN 地址。
    //
    // 为什么要加尺寸参数：富文本 <img> 只认 width/height（逻辑像素，通常 20~24），
    // 原图几十上百像素会被缩到这个尺寸，再由 Qt 按设备像素比放大绘制 ——
    // 缩放比大、又没有 mipmap（富文本图片没有这个开关），细线条（描边/高光）
    // 就会出现锯齿和摩尔纹，看着像糊了一层。
    // 这里直接按"设备像素"请求：size × DPR，纹理与屏幕像素基本 1:1，
    // 100% 缩放请求 24、150% 请求 36、200% 请求 48，不需要再缩放。
    //
    // 用不带扩展名的写法：CDN 按原格式返回（表情是透明底 PNG 就还是 PNG），
    // 强制 .jpg 会变黑底，强制 .png 又多一层格式转换的风险。
    // 已带 @ 参数的 URL 原样返回；带 query 的把参数插在 query 之前。
    function _cmtEmoteImgUrl(url, size) {
        if (!url) return ""
        var u = String(url)
        if (u.indexOf("//") === 0) u = "https:" + u
        if (u.indexOf("@") >= 0) return u
        var q = u.indexOf("?")
        var base = q >= 0 ? u.substring(0, q) : u
        var tail = q >= 0 ? u.substring(q) : ""
        var px = _cmtEmoteRequestPx(size)
        return base + "@" + px + "w_" + px + "h_1e_1c" + tail
    }

    // 表情请求的像素边长：逻辑尺寸 × 设备像素比。
    // 取不到 DPR 时按 2 倍兜底 —— 多下几个像素（48px 的 PNG 也就几 KB）
    // 总比按 1 倍请求、在高 DPI 屏上被放大糊掉强。
    function _cmtEmoteRequestPx(size) {
        var s = size > 0 ? size : 24
        var dpr = 0
        try {
            var screens = Qt.application.screens
            if (screens && screens.length > 0 && screens[0].devicePixelRatio > 0)
                dpr = screens[0].devicePixelRatio
        } catch (e) {
            dpr = 0
        }
        if (dpr <= 0) dpr = 2
        return Math.min(72, Math.max(24, Math.round(s * dpr)))
    }

    // 供"自己拼 <img>"的页面复用（动态正文：DynamicPage 里有一份独立的
    // 富文本生成逻辑）。不共用的话那些地方还是把原图硬塞进富文本，
    // 缩小后一样有锯齿；顺带也避免走 fixImageUrl 给的 "@.jpg" 把表情的
    // 透明底压成黑底。
    function commentEmoteImgUrl(url, size) {
        return _cmtEmoteImgUrl(url, size)
    }

    // 该表情是否带动态版本（服务端在 emote 条目上下发 gif_url）。
    // C++ 侧已把 gifUrl / isAnimated 导出，这里对多种形态做容错。
    function _cmtEmoteIsAnimated(em) {
        if (!em || typeof em !== "object") return false
        if (em.isAnimated === true) return true
        if (em.gifUrl && String(em.gifUrl) !== "") return true
        return /\.(gif|webp)([?#]|$)/i.test(String(em.url || ""))
    }
    function _cmtEmoteSegment(em) {
        var sz = (em.width > 0) ? em.width : 24
        // 这里只补协议相对 URL，**绝不追加 CDN 格式后缀**：
        // fixImageUrl 在未给宽高时会给 URL 拼 "@.jpg"，动图被拼成 jpg 就只剩第一帧了。
        var g = String(em.gifUrl || em.url || "")
        if (g.indexOf("//") === 0) g = "https:" + g
        var u = String(em.url || "")
        if (u.indexOf("//") === 0) u = "https:" + u
        return { t: "emote", url: u, gifUrl: g, size: sz }
    }

    // 通用格式化工具函数
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

    function _formatSmartTime(timestamp) {
        var ts = parseInt(timestamp, 10) || 0
        if (ts <= 0) return ""
        var now = new Date()
        var date = new Date(ts * 1000)
        var nowYear = now.getFullYear()
        var nowMonth = now.getMonth()
        var nowDate = now.getDate()
        var year = date.getFullYear()
        var month = date.getMonth()
        var day = date.getDate()

        if (year === nowYear && month === nowMonth && day === nowDate) {
            var diff = Math.floor(now.getTime() / 1000) - ts
            if (diff < 60) return "刚刚"
            if (diff < 3600) return Math.floor(diff / 60) + "分钟前"
            return Math.floor(diff / 3600) + "小时前"
        }

        var mm = (month + 1 < 10 ? "0" : "") + (month + 1)
        var dd = (day < 10 ? "0" : "") + day
        if (year === nowYear) return mm + "-" + dd
        return year + "-" + mm + "-" + dd
    }

    function formatVideoCardTime(timestamp) {
        return _formatSmartTime(timestamp)
    }

    function formatCommentTime(timestamp) {
        return _formatSmartTime(timestamp)
    }

    function formatDateTime(timestamp) {
        var ts = parseInt(timestamp, 10) || 0
        if (ts <= 0) return ""
        var date = new Date(ts * 1000)
        var y = date.getFullYear()
        var m = (date.getMonth() + 1 < 10 ? "0" : "") + (date.getMonth() + 1)
        var d = (date.getDate() < 10 ? "0" : "") + date.getDate()
        var h = (date.getHours() < 10 ? "0" : "") + date.getHours()
        var min = (date.getMinutes() < 10 ? "0" : "") + date.getMinutes()
        var s = (date.getSeconds() < 10 ? "0" : "") + date.getSeconds()
        return y + "-" + m + "-" + d + " " + h + ":" + min + ":" + s
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

    // 用户头像专用：强制剥离已有的 @ 尺寸参数并按目标尺寸重新请求，
    // 避免接口返回的小图后缀导致头像模糊。
    function fixAvatarUrl(url, size) {
        if (!url) return ""
        if (url.indexOf("//") === 0) url = "https:" + url
        var atIndex = url.indexOf("@")
        if (atIndex >= 0) url = url.substring(0, atIndex)
        // gif（如B站默认头像 noface.gif）不支持格式转换后缀，直接返回原始 URL
        if (url.toLowerCase().indexOf(".gif") >= 0) return url
        var s = size ? Math.round(size) : 96
        if (s <= 0) s = 96
        return url + "@" + s + "w_" + s + "h_1c_100q.jpg"
    }

    // Qt 默认可能不支持 webp，让 B 站 CDN 返回 jpg 格式。
    // 支持传入目标宽高，让 CDN 返回对应分辨率的图片，降低网络占用。
    // crop=true 时使用 1e_1c 中心裁剪，适合 PreserveAspectCrop；否则按给定宽高缩放。
    function fixImageUrl(url, width, height, crop) {
        if (!url) return ""
        // B站部分接口返回 // 开头的协议相对 URL，Qt Image 无法解析，补全为 https://
        if (url.indexOf("//") === 0) {
            url = "https:" + url
        }
        // 已经携带转换参数则不再追加，避免重复
        if (url.indexOf("@") >= 0) return url
        // 动图（.gif/.webp 后缀）：不能追加 @.jpg 等 CDN 格式转换参数，
        // 否则 B站 CDN 会按 jpg 静态图返回，动图变成第一帧静止。
        // Qt 的 AnimatedImage 需要原始动图 URL 才能播放动画。
        var lower = url.toLowerCase()
        var queryIdx = lower.indexOf("?")
        var pathEnd = queryIdx >= 0 ? queryIdx : url.length
        var pathLower = lower.substring(0, pathEnd)
        if (pathLower.endsWith(".gif") || pathLower.endsWith(".webp")) {
            return url
        }
        var w = width ? Math.round(width) : 0
        var h = height ? Math.round(height) : 0
        if (w > 0 && h > 0) {
            if (crop) {
                return url + "@" + w + "w_" + h + "h_1e_1c.jpg"
            }
            return url + "@" + w + "w_" + h + "h.jpg"
        }
        if (w > 0) {
            return url + "@" + w + "w.jpg"
        }
        return url + "@.jpg"
    }

    // 判断是否为动图 URL（.gif/.webp 后缀，忽略查询参数）。
    // 与 fixImageUrl 内部的动图判断保持一致：
    // B站 CDN 对动图保留原始后缀，需用 AnimatedImage 播放，不能追加 CDN 格式转换参数。
    function isAnimatedImageUrl(url) {
        if (!url) return false
        var lower = url.toLowerCase()
        var queryIdx = lower.indexOf("?")
        var pathLower = lower.substring(0, queryIdx >= 0 ? queryIdx : url.length)
        return pathLower.endsWith(".gif") || pathLower.endsWith(".webp")
    }

    // 图片请求宽度：**固定值，与布局尺寸无关**。
    // 之前按"当前布局像素"拼 URL（@640w_400h.jpg），窗口一变 URL 就变，Qt 当新图重新下载。
    // 现在一律用固定宽度请求，缩放窗口只做本地缩放，永不重新下载。
    // 取 480：九宫格/评论缩略图实际显示 100~250px，480 足够；再大一倍纯属浪费内存。
    readonly property int imageThumbRequestWidth: 480
    // 单张原比例图（详情正文、评论单图）：显示宽度可能到 700px+，给 1080 保证不糊
    readonly property int imageFullRequestWidth: 1080

    // 返回固定尺寸（480x270，16:9）的 CDN 图片 URL。
    // 用于视频/直播卡片封面等场景：URL 不随显示尺寸变化，确保只在第一次显示时下载一次，
    // 后续 resize 由 Qt 在本地做 GPU 缩放，避免反复重新下载导致转圈圈和封面闪动。
    function fixImageUrlStatic(url) {
        if (!url) return ""
        if (url.indexOf("//") === 0) {
            url = "https:" + url
        }
        if (url.indexOf("@") >= 0) return url
        return url + "@480w_270h_1e_1c.jpg"
    }

    // ============================================================
    // 评论正文链接路由
    // ============================================================
    // av 号 -> BV 号（B站公开算法，纯本地计算无网络请求）。
    // 仅适用于 2020-03 前的旧号段（av < 2^31）；新视频评论里 av 形态极少，
    // 失配时换算结果无效但不崩溃（openVideo 请求会返回错误）。
    // 原为 CommentPanel / VideoPlayerPage 各存一份，收敛到此处。
    function _cmtAvToBvid(avNum) {
        var table = "fZodR9XQDSUm21yCkr6zBqiveYah8bt4xsWpHnJE7jL5VG3guMTKNPAwcF"
        var tr = {}
        for (var i = 0; i < 58; i++) tr[table[i]] = i
        var s = [11, 10, 3, 8, 4, 6]
        var xor = 177451812
        var add = 8728348608
        var x = (avNum ^ xor) + add
        var r = ['B', 'V', '1', ' ', '4', ' ', '1', ' ', '7', ' ', ' ', ' ']
        for (var j = 0; j < 6; j++) {
            r[s[j]] = table[Math.floor(x / Math.pow(58, j)) % 58]
        }
        return r.join("")
    }

    // 评论正文链接统一路由，供各页面的 onLinkActivated 复用。
    // 《重要》调用时必须把页面的 App 传进来：GlobalState 是 pragma Singleton，
    // 内部解析不到 main.cpp 注册的上下文属性 App（详见函数内说明）。
    //
    // href 契约（由 formatCommentRichText 生成）：
    //   video:<BV|av>            应用内打开视频（裸 BV/av 号，来自服务端 jump_url）
    //   user:<mid>               打开用户主页（@提及）
    //   search:<关键词>          客户端搜索结果页（不再走系统浏览器）
    //   web:<url>                系统浏览器打开（商品/番剧/专栏/直播/opus/任意 http）
    //   timestamp:<毫秒>         跳转播放进度 —— 需要播放器上下文，由页面自行处理
    //   http(s)://...            bili://user/ 等旧形态的兼容兜底
    //
    // 刻意不支持 bilibili:// 之类的 APP scheme：直接交给系统外壳时，Windows 找不到
    // 注册项会跳转微软商店搜索，体验错误。服务端 scheme 一律在下游翻译成 http(s)。
    // 本项目暂无对应页面的类型（tag / vote）返回 false，交由调用方决定。
    // 返回 true 表示已消费该链接。
    function openCommentLink(href, hostApp) {
        if (!href) return false
        var h = String(href)
        // 应用内跳转需要 App 对象。**本文件是 QML 单例，取不到 main.cpp 用
        // setContextProperty 注册的上下文属性 App**（页面里能取到，单例里
        // 解析不到 → ReferenceError 被下面的 catch 吞掉 → 表现为"点了没反应"）。
        // 所以由调用页面把自己的 App 显式传进来；传不进来时退化成用系统
        // 浏览器打开等价网页，而不是静默失败。
        var app = hostApp || null
        try {
            // 时间戳必须由持有 mpvPlayer 的页面处理，这里不接管
            if (h.indexOf("timestamp:") === 0) return false

            if (h.indexOf("video:") === 0) {
                var vid = h.substring("video:".length)
                if (vid.length === 0) return false
                var bvid = vid
                if (/^[Aa][Vv][0-9]+$/.test(vid)) {
                    bvid = _cmtAvToBvid(parseInt(vid.substring(2), 10))
                    if (!bvid) return false
                } else if (!/^[Bb][Vv][A-Za-z0-9]{8,}$/.test(vid)) {
                    return false
                }
                if (app) {
                    app.openVideo(bvid, "")
                } else {
                    Qt.openUrlExternally("https://www.bilibili.com/video/" + bvid)
                }
                return true
            }

            if (h.indexOf("user:") === 0) {
                var mid = h.substring("user:".length)
                var q = mid.indexOf("?")
                if (q >= 0) mid = mid.substring(0, q)
                var sh = mid.indexOf("#")
                if (sh >= 0) mid = mid.substring(0, sh)
                if (!/^[0-9]+$/.test(mid) || mid === "0") return false
                if (app) {
                    app.openUserProfile(mid, "", "")
                } else {
                    Qt.openUrlExternally("https://space.bilibili.com/" + mid)
                }
                return true
            }

            // 词搜索热词 / 话题：走客户端自己的搜索结果页
            if (h.indexOf("search:") === 0) {
                var kw = h.substring("search:".length)
                if (!kw) return false
                openInAppSearch(kw)
                return true
            }

            // 网页地址：只放行 http(s)。**刻意不再支持 scheme: 形态** ——
            // 把 bilibili:// 之类的协议交给系统，Windows 会跳到微软商店。
            if (h.indexOf("web:") === 0) {
                var u = h.substring("web:".length)
                if (u.indexOf("http") !== 0) return false
                // b23.tv 短链（无视频号）：异步解析后再决定内部跳转/浏览器。
                // 解析期间返回 true（本次点击已被消费，避免调用方再走一遍）
                if (_cmtIsShortLink(u)) {
                    _cmtResolveShortLink(u, app)
                    return true
                }
                Qt.openUrlExternally(u)
                return true
            }

            // 兼容可能残留在旧 HTML 里的形态（bili://user/<mid>）
            if (h.indexOf("bili://user/") === 0) {
                var mid2 = h.substring("bili://user/".length).split("?")[0].split("#")[0]
                if (!/^[0-9]+$/.test(mid2) || mid2 === "0") return false
                if (app) {
                    app.openUserProfile(mid2, "", "")
                } else {
                    Qt.openUrlExternally("https://space.bilibili.com/" + mid2)
                }
                return true
            }

            if (h.indexOf("http://") === 0 || h.indexOf("https://") === 0) {
                // 站内搜索链接（话题/标签的 jump_url 常见形态）→ 应用内搜索结果页
                if (_cmtIsSearchUrl(h)) {
                    var skw = _cmtSearchKeyword(h)
                    if (skw) { openInAppSearch(skw); return true }
                }
                Qt.openUrlExternally(h)
                return true
            }
        } catch (e) {
            console.warn("[GlobalState] openCommentLink failed:", e, "href:", h)
        }
        return false
    }
}
