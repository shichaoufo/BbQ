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
        return ""
    }
    // 生成可点击链接
    function _cmtLink(href, text, color, underline) {
        var deco = underline ? "underline" : "none"
        return '<a href="' + _cmtEscAttr(href) + '" style="color:' + color
             + ';text-decoration:' + deco + ';">' + _cmtEscText(text) + '</a>'
    }
    // 只染蓝、不可点
    function _cmtColorOnly(text, color) {
        return '<span style="color:' + color + ';">' + _cmtEscText(text) + '</span>'
    }

    // 渲染单个服务端 jump_url 条目
    function _cmtRenderJumpUrl(tok, entry, used, color, wordRe, opts) {
        var e = (entry && typeof entry === "object") ? entry
              : { title: (entry === undefined || entry === null) ? tok : String(entry) }

        // ★ 核心修复：词搜索热词默认不染
        //   实测 54 条 jump_url 中 36 条（67%）是词搜索热词，正文里就是普通词语
        //   （"一口气看完""先把规矩立住"，甚至人名）。旧实现把判据字段丢了 → 一律染蓝。
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
        var href = ""
        var vid = _cmtVideoIdOf(tok)
        if (vid) href = "video:" + vid
        else if (e.appUrlSchema) href = "schema:" + e.appUrlSchema
        else if (e.pcUrl) href = "web:" + e.pcUrl
        else if (/^https?:\/\//.test(tok)) href = "web:" + tok

        var icon = ""
        if (opts && opts.showPrefixIcon === true && e.prefixIcon) {
            icon = '<img src="' + _cmtEscAttr(e.prefixIcon)
                 + '" width="19" height="19" align="middle" style="vertical-align:middle;">'
        }
        if (!href) return icon + _cmtColorOnly(title, color)
        return icon + _cmtLink(href, title, color, e.underline === true)
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
                return _cmtLink("bili://user/" + ctx.atNameToMid[nm], tok, ctx.color)
            }
        }

        // (c) #话题#：同样只认服务端登记
        if (tok.charAt(0) === "#" && tok.length > 2 && tok.charAt(tok.length - 1) === "#") {
            var kw = tok.substring(1, tok.length - 1)
            if (Object.prototype.hasOwnProperty.call(ctx.topics, kw)) {
                return _cmtLink("bili://tag/" + encodeURIComponent(kw), tok, ctx.color)
            }
        }

        // (d) 投票
        if (/^\{vote:\d+\}$/.test(tok)) {
            return _cmtLink("bili://vote/" + tok.replace(/[^0-9]/g, ""), "投票", ctx.color)
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
            wordRe: (o.enableWordRe === true),
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
    // href 契约（由 formatCommentRichText 生成）：
    //   video:<BV|av>            应用内打开视频（裸 BV/av 号，来自服务端 jump_url）
    //   bili://user/<mid>        打开用户主页（@提及）
    //   web:<url>                系统浏览器打开（商品/番剧/专栏/直播/opus/任意 http）
    //   schema:<bilibili://...>  服务端下发的 APP scheme，交系统处理
    //   timestamp:<毫秒>         跳转播放进度 —— 需要播放器上下文，由页面自行处理
    //   bili://tag|vote/...      本项目暂无对应页面，返回 false 交由调用方决定
    // 返回 true 表示已消费该链接。
    function openCommentLink(href) {
        if (!href) return false
        var h = String(href)
        try {
            // 时间戳必须由持有 mpvPlayer 的页面处理，这里不接管
            if (h.indexOf("timestamp:") === 0) return false

            if (h.indexOf("video:") === 0) {
                var vid = h.substring("video:".length)
                if (vid.length === 0) return false
                if (/^[Bb][Vv][A-Za-z0-9]{8,}$/.test(vid)) {
                    App.openVideo(vid, "")
                    return true
                }
                if (/^[Aa][Vv][0-9]+$/.test(vid)) {
                    var bvid = _cmtAvToBvid(parseInt(vid.substring(2), 10))
                    if (bvid) { App.openVideo(bvid, ""); return true }
                }
                return false
            }

            if (h.indexOf("web:") === 0) {
                var u = h.substring("web:".length)
                if (u.indexOf("http") !== 0) return false
                Qt.openUrlExternally(u)
                return true
            }

            if (h.indexOf("schema:") === 0) {
                var sc = h.substring("schema:".length)
                if (sc.indexOf("http") === 0 || sc.indexOf("bilibili://") === 0) {
                    Qt.openUrlExternally(sc)
                    return true
                }
                return false
            }

            if (h.indexOf("bili://user/") === 0) {
                var mid = h.substring("bili://user/".length)
                var q = mid.indexOf("?")
                if (q >= 0) mid = mid.substring(0, q)
                var sh = mid.indexOf("#")
                if (sh >= 0) mid = mid.substring(0, sh)
                if (/^[0-9]+$/.test(mid) && mid !== "0") {
                    App.openUserProfile(mid, "", "")
                    return true
                }
                return false
            }

            // 话题 / 投票：暂无落地页，交由调用方决定是否提示
            if (h.indexOf("bili://tag/") === 0 || h.indexOf("bili://vote/") === 0) return false

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
