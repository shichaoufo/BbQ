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

    // ============================================================
    // 评论 / 动态正文富文本渲染 —— 全项目唯一实现
    // ============================================================
    // BbQ 评论/动态正文富文本渲染 —— 全项目唯一实现
    // 设计依据（对照 PiliPlus reply_item_grpc.dart _buildMessage）：
    //   1) 能查服务端下发的表就绝不用正则猜；
    //   2) 服务端 token 在总正则里排最前，泛化模式垫底；
    //   3) 只在原始纯文本上扫一遍，绝不在已生成的 HTML 上二次扫；
    //   4) 词搜索热词（extra.is_word_search）默认不染。

    // 文本转义（用于正文片段）
    function _cmtEscText(s) {
        return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
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
    // 实测：词搜索的前置放大镜图标，画布是 36x66，而图案本体只有 27x27，
    // 且贴在画布上沿（下方 28px 全是透明留白）。
    // 旧实现硬写 width=19 height=19，Qt 富文本会把图**非等比**塞进这个方框：
    // 横向 36→19、纵向 66→19，纵比横多缩了一倍多 —— 看上去就是"被压扁"。
    // 站内 CDN 支持图片处理后缀，先裁成正方形再等比缩放即可解决：
    //   @36w_36h_1c.png → 32~36 像素的居中方形裁剪（实测返回 36x36）
    // 只对站内 CDN 且未带处理后缀的地址加工；其他来源原样使用，避免改坏。
    function _cmtIconSrc(u) {
        var s = String(u || "")
        if (!s) return ""
        if (s.indexOf("hdslb.com/") < 0) return s
        if (s.indexOf("@") >= 0) return s
        return s + "@36w_36h_1c.png"
    }
    function _cmtIconImg(u) {
        var src = _cmtIconSrc(u)
        if (!src) return ""
        return '<img src="' + _cmtEscAttr(src)
             + '" width="18" height="18" style="vertical-align:middle;">'
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
            return '<img src="' + _cmtEscAttr(eurl) + '" width="' + sz + '" height="' + sz
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
    // emotes       { "[微笑]": {url, width, height} }
    // topics       { "话题名": ... }
    // atNameToMid  { "用户名": mid }
    // jumpUrls     { "原文": {title, prefixIcon, appUrlSchema, pcUrl, underline, matchOnce, isWordSearch} }
    //              兼容旧格式：值直接是 title 字符串
    // opts         { durationMs, hasPlayer, enableWordRe, linkColor, showPrefixIcon }
    //              enableWordRe 控制词搜索热词是否染蓝可点，**默认开启**；
    //              传 false 即退回 PiliPlus 的默认行为（热词按普通文字显示）。
    // 返回可直接给 Text.RichText 的 HTML
    function formatCommentRichText(message, emotes, topics, atNameToMid, jumpUrls, opts) {
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
        //    以免污染替换回调参数）
        var alts = []
        for (var i = 0; i < toks.length; i++) alts.push(_cmtEscRe(toks[i]))
        alts.push("(?:\\d{1,2})[:：]\\d{2}(?:[:：]\\d{2})?")
        alts.push("\\{vote:\\d+\\}")
        alts.push("https?:\\/\\/[-A-Za-z0-9+&@#\\/%?=~_|!:,.;]*[-A-Za-z0-9+&@#\\/%=~_|]")
        var re = new RegExp(alts.join("|"), "g")

        // 3) 单次扫描（QML 没有 splitMapJoin，用 exec 循环等价实现）
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
    //   search:<关键词>          系统浏览器打开 B 站官网搜索（词搜索热词 / #话题#）
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

            // 词搜索热词 / 话题：系统浏览器打开 B 站官网搜索
            if (h.indexOf("search:") === 0) {
                var kw = h.substring("search:".length)
                if (!kw) return false
                Qt.openUrlExternally(_cmtSearchUrl(kw))
                return true
            }

            // 网页地址：只放行 http(s)。**刻意不再支持 scheme: 形态** ——
            // 把 bilibili:// 之类的协议交给系统，Windows 会跳到微软商店。
            if (h.indexOf("web:") === 0) {
                var u = h.substring("web:".length)
                if (u.indexOf("http") !== 0) return false
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
                Qt.openUrlExternally(h)
                return true
            }
        } catch (e) {
            console.warn("[GlobalState] openCommentLink failed:", e, "href:", h)
        }
        return false
    }
}
