import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import QtQuick.Window 2.15
import QtQuick.Effects

import FluentUI 1.0
import BiliQt 1.0
import "../components"

Item {
    id: panelRoot

    property ListModel commentModel
    property string oid: ""
    property string aid: ""
    property bool sortByHeat: true
    property int commentTotal: 0
    // 首屏评论是否在请求中。由页面维护（本组件不自己发请求）。
    // 用来区分"还没拿到数据"与"服务端就是没有评论" —— 见下方空列表文案。
    property bool commentLoading: false
    property int commentPage: 1
    property bool commentHasNextPage: true
    property int commentType: 1
    property bool showDislike: true
    property var previewOverlayParent: panelRoot
    property string ownerMid: ""

    // 页面提供的评论永久链接基址（如 "https://www.bilibili.com/video/BVxxx"），
    // 最终格式为 {基址}#reply{rpid}。为空时右键菜单不显示"复制评论链接"。
    property string commentPermalinkBase: ""

    function isUpAuthor(mid) {
        if (!panelRoot.ownerMid || mid === undefined || mid === null || mid === "") return false
        return String(mid) === String(panelRoot.ownerMid)
    }

    // 打开评论作者的用户主页（头像/用户名点击）。视频播放页与动态详情页
    // 共用本组件，统一经 App 广播由当前可见导航页打开主页（并按既定规则
    // 先关闭视频播放页）
    function openUserPage(mid, name, face) {
        if (mid === undefined || mid === null || String(mid) === "") return
        App.openUserProfile(String(mid), String(name || ""), String(face || ""))
    }

    function levelIconSource(level, senior) {
        // 硬核会员：LV6 带闪电（user-lv6p.svg），优先于普通 LV6
        if (senior === true) return "qrc:/BiliQt/icons/level/user-lv6p.svg"
        return "qrc:/BiliQt/icons/level/user-lv" + (level || 0) + ".svg"
    }

    property string replyToUser: ""
    property string replyRpid: ""
    property string replyRootRpid: ""

    // 退出「回复某人」状态。
    // 三个字段必须一起清 —— 只清 replyToUser 会让 replyRpid / replyRootRpid 残留，
    // 用户点完「取消」再直接发一条普通评论时，requestSendComment 会带着上一轮的
    // root/parent 发出去，被服务端当成楼中楼回复挂到旧楼层下面。
    // 取消与发布两条路径都走这里，避免再出现"一处清三个、一处只清一个"的漂移。
    function cancelReply() {
        replyToUser = ""
        replyRpid = ""
        replyRootRpid = ""
    }

    property bool commentImagePreviewVisible: false
    property var commentPreviewImages: []
    property int commentPreviewIndex: 0

    signal requestSort(bool byHeat)
    signal requestPage(int page, int pageSize)
    signal requestSubComments(string aid, string rpid, int page, int pageSize)
    signal requestSendComment(string text, string rootId, string parentId)

    // 供页面在评论数据就绪后调用：旧内容保持原位，新数据渲染时已处于顶部
    function scrollToTop() {
        if (commentFlickable) commentFlickable.contentY = 0
    }

    // ============ 评论右键菜单（复制）============
    // 为什么不直接做"可拖拽选中"：正文所在的 Flickable 用左键拖拽滚动（触摸手势
    // 的桌面模拟）。而 Qt 里 TextEdit 一旦 selectByMouse 为真就会
    // setKeepMouseGrab(true)（见 qquicktextedit.cpp）—— 这正是父 Flickable 判断
    // "能否抢走拖拽"时要看的标志位，于是"鼠标选中"与"拖拽滚动"在 Qt 层面共用同一个
    // 开关，拆不开（Qt 文档也承认拖拽选中"interfered with flicking when TextEdit
    // was used inside a Flickable"）。
    // 右键菜单只接受右键，完全不碰左键事件链 —— 拖拽滚动、链接点击、表情播放
    // 全部零影响，正文也不必从 Text 换成 TextEdit。
    property string contextRawText: ""
    property string contextPermalink: ""

    // 供页面在"兜底右键"里判断：菜单开着时先收菜单，不要关页面/关详情。
    readonly property bool commentMenuOpened: commentMenu.opened
    function closeCommentMenu() { commentMenu.close() }

    // QML 没有直接的剪贴板 API。隐藏 TextEdit 走 selectAll()+copy() 是标准做法：
    // copy() 把 QTextDocument 的选中内容写入系统剪贴板，与控件是否可见无关。
    function copyToClipboard(text) {
        var s = String(text || "")
        if (s === "") return
        clipboardHelper.text = s
        clipboardHelper.selectAll()
        clipboardHelper.copy()
    }

    // 评论永久链接：B 站 web 的锚点约定是 {页面地址}#reply{rpid}，楼中楼也能定位。
    function permalinkOf(rpid) {
        if (commentPermalinkBase === "" || rpid === undefined || rpid === null) return ""
        var id = String(rpid)
        if (id === "" || id === "0") return ""
        return commentPermalinkBase + "#reply" + id
    }

    // 右键的一次「命中」= 一条评论的原文 + 它的永久链接。挂在卡片/楼中楼行上，
    // 由 commentMetaAt() 在右键时取用（见那边的注释）。
    function commentMetaOf(rawText, rpid) {
        return { text: String(rawText || ""), permalink: permalinkOf(rpid) }
    }

    // 从落点解析出「这次右键点的是哪条评论」。
    //
    // 为什么需要它：卡片上的右键 Handler 只有一个（整张卡片一个），但卡片里嵌着
    // 已展开的楼中楼 —— 落点到底属于主评论还是某条子评论，得自己算。
    // 做法是两步：
    //   ① 从卡片往下逐层 childAt，钻到落点处最深的那个可见 Item ——
    //      QQuickItem::childAt() 只看 visible 且 opacity≠0 的子项，所以楼中楼没
    //      展开时天然钻不进它的分支；
    //   ② 再沿 parent 往上找第一个带 commentMeta 标记的祖先。**近者优先**，
    //      于是楼中楼行永远赢过它所属的卡片。
    // 这个判定与声明顺序、与 Qt 的 handler 投递/抓取顺序都无关，是确定性的。
    //
    // 为什么不"主评论挂一个 Handler、楼中楼再挂一个"：两个 Handler 上下重叠时，
    // 这次 tap 给谁由 Qt 的投递与抓取顺序决定（实测外层卡片赢），语义不稳定。
    function commentMetaAt(root, sceneX, sceneY) {
        var it = root
        var guard = 0
        while (it && guard < 64) {
            var local = it.mapFromItem(null, sceneX, sceneY)
            var child = it.childAt(local.x, local.y)
            if (!child) break
            it = child
            guard++
        }
        while (it) {
            var meta = it.commentMeta
            if (meta !== undefined && meta !== null) return meta
            it = it.parent
        }
        return null
    }

    // eventPoint 优先（右键落点）；取不到时退化为被点卡片的左上角，
    // 避免菜单飘到窗口角落。
    function openCommentContextMenu(rawText, permalink, eventPoint, anchorItem) {
        contextRawText = String(rawText || "")
        contextPermalink = String(permalink || "")
        var scene = (eventPoint && eventPoint.scenePosition)
                  ? eventPoint.scenePosition
                  : (anchorItem ? anchorItem.mapToItem(null, 0, 0) : null)
        if (!scene) return
        var p = commentMenu.parent.mapFromItem(null, scene.x, scene.y)
        commentMenu.x = p.x
        commentMenu.y = p.y
        commentMenu.open()
    }

    // 剪贴板助手（不可见，不参与任何布局）
    TextEdit {
        id: clipboardHelper
        visible: false
    }

    // FluMenu 继承自 QtQuick.Controls.Menu，具备 x/y/open()/close()/opened
    FluMenu {
        id: commentMenu

        // 「菜单开着时右键别处 = 先收菜单、不关页面」正是靠这里的 modal 拿到的。
        // Qt 6 qquickpopup.cpp 的 handlePress() 按顺序做两件事：
        //   ① tryClose(point, CloseOnPressOutside) —— 按下那一刻菜单就关了；
        //   ② return blockInput(item, point) —— 决定这次按下要不要拦下来。
        // 而 blockInput() 对**非模态**弹窗一律返回 false（源码注释原话：don't block
        // presses and releases ... outside a non-modal popup）。于是同一次右键的按下
        // 继续传给页面兜底的 MouseArea，等到 release 触发兜底的 onClicked 时 opened
        // 已经是 false —— 兜底判断不出来，就把页面/详情关了。这就是那个 bug 的成因。
        // 设成 modal 后 blockInput() 返回 true，Overlay 的 eventFilter 直接吞掉这次
        // 按下（源码注释也写明了 non-dimming modal popups block the event），页面兜底
        // 根本收不到，只有菜单自己收起来。
        modal: true
        // dim 必须显式关掉：modal 会连带把 dim 置为 true，而 FluMenu 给模态弹窗画的
        // 遮罩是半透明全窗矩形（它自己的 T.Overlay.modal），右键菜单不该把整个窗口压暗。
        // modal + dim=false 时 Qt 不创建 dimmer，blockInput() 里 `!dimmer` 分支成立，
        // 拦截照旧生效 —— 这正是源码里说的 "non-dimming modal popup"。
        dim: false

        FluMenuItem {
            text: "复制评论内容"
            enabled: panelRoot.contextRawText !== ""
            onTriggered: panelRoot.copyToClipboard(panelRoot.contextRawText)
        }
        FluMenuItem {
            text: "复制评论链接"
            visible: panelRoot.contextPermalink !== ""
            onTriggered: panelRoot.copyToClipboard(panelRoot.contextPermalink)
        }
    }

    function escapeHtml(str) {
        return String(str).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    }

    // 用候选用户名集合切分楼中楼的"回复 @xxx"前缀：优先在候选集合中做最长前缀
    // 匹配（候选 = 根评论作者 + 已加载子评论作者，服务端不单独下发被回复者），
    // 匹配失败再回退到首个冒号启发式。返回 {prefix, rest} 或 null。
    function splitReplyPrefix(content, candidateNames) {
        if (!content || !content.startsWith("回复 @")) return null
        var after = content.substring(4) // "@xxx..." 部分
        // 最长前缀匹配：昵称可含任意字符（包括冒号/空格），最长优先避免截断
        var best = -1
        if (candidateNames && candidateNames.length > 0) {
            for (var i = 0; i < candidateNames.length; i++) {
                var n = candidateNames[i]
                if (!n || n.length < 1) continue
                if (after.startsWith("@" + n) && n.length > best) {
                    best = n.length
                }
            }
        }
        if (best >= 0) {
            // 吃掉紧随其后的可选"空格+冒号+空格"分隔组合（实测真实格式
            // 为"回复 @名字 :正文"，冒号前带一个空格，冒号可全角/半角）
            var rest = content.substring(4 + best + 1)
            var consumed = 0
            while (rest.length > consumed && rest[consumed] === " ") consumed++
            if (rest.length > consumed && (rest[consumed] === "：" || rest[consumed] === ":")) consumed++
            while (rest.length > consumed && rest[consumed] === " ") consumed++
            rest = rest.substring(consumed)
            return { prefix: content.substring(0, 4 + best + 1 + consumed), rest: rest }
        }
        // 回退：首个冒号（含位置取最早出现的，修复半角分隔符+正文含全角冒号时
        // 误把正文切进前缀的缺陷）
        var idx1 = content.indexOf("：")
        var idx2 = content.indexOf(":")
        var idx = -1
        if (idx1 >= 0 && idx2 >= 0) idx = Math.min(idx1, idx2)
        else idx = Math.max(idx1, idx2)
        if (idx < 0) return null
        return { prefix: content.substring(0, idx + 1), rest: content.substring(idx + 1) }
    }

    // 取评论的 @提及名单。主评论经 ListModel 存储时数组角色会失效
    //（数组被转成嵌套模型对象，.length 失效），统一序列化为 atNamesJson
    // 字符串；楼中楼经 repliesJson JSON 往返，atNames 可能仍是数组（旧
    // 数据）或 atNamesJson（新发评论），两者兼容。
    function atNamesOf(m) {
        if (!m) return []
        if (m.atNamesJson !== undefined && m.atNamesJson !== null) {
            return JSON.parse(m.atNamesJson || "[]")
        }
        return m.atNames || []
    }

    // 评论正文富文本渲染 —— 统一委托 GlobalState.formatCommentRichText。
    //
    // 旧实现是 4 个正则函数串行在"已生成的 HTML"上跑
    //（replaceJumpUrls → replaceTimeStamps → replaceAtMentions → replaceEmotesInHtml，
    //  见 git 历史）。它有两个根因缺陷：
    //   1) 把服务端下发的全部 jump_url 无差别染蓝。实测 54 条 jump_url 中
    //      36 条（67%）是"词搜索热词"——正文里的普通词语被服务端登记成可跳转项，
    //      唯一判据是 extra.is_word_search，而旧实现把它丢了：该染的没染、
    //      不该染的全蓝。
    //   2) 在结果 HTML 上二次跑正则，先插入的 <a> 标题会被后续正则再次匹配，
    //      生成嵌套 <a> 标签。
    // 新实现只在原始纯文本上扫一遍：服务端 token 优先查表、泛化正则垫底。
    //
    // 参数 jumpUrlInfos：content.jump_url 的完整信息表
    //        （{原文: {title, isWordSearch, appUrlSchema, prefixIcon, ...}}），
    //        不再是旧版的 {原文: 标题} 字符串表。
    // 参数 atNameToMid：正文 @提及的 用户名 -> mid，有 mid 才能点击跳转主页。
    // 本组件是动态详情页评论区，无播放器上下文，故 hasPlayer=false
    //（时间戳只染蓝，不生成跳转链接）。
    function formatCommentContent(content, emotes, isReply, jumpUrlInfos, candidateNames, atNameToMid) {
        var prefixHtml = ""
        var body = content || ""
        if (isReply) {
            // 楼中楼"回复 @xxx："前缀用次要色单独显示（前缀切分逻辑保留原实现）
            var sp = panelRoot.splitReplyPrefix(body, candidateNames)
            if (sp) {
                prefixHtml = '<span style="color:' + FluTheme.fontSecondaryColor + ';">'
                           + panelRoot.escapeHtml(sp.prefix) + '</span>'
                body = sp.rest
            }
        }
        var bodyHtml = GlobalState.formatCommentRichText(body, emotes, {}, atNameToMid, jumpUrlInfos, {
            linkColor: "#00A1D6",
            hasPlayer: false,
            durationMs: 0,
            showPrefixIcon: true
        })
        if (prefixHtml === "") return bodyHtml
        return prefixHtml + '<span style="color:' + FluTheme.fontPrimaryColor + ';">' + bodyHtml + '</span>'
    }

    // 分段版正文 —— 给 CommentRichText 用。
    // 与 formatCommentContent 的唯一区别：把**动态表情**切成独立段，好让渲染层
    // 用 AnimatedImage 播（Qt 富文本的 <img> 只会画第一帧）。静态表情、链接、
    // @提及、话题、热词的行为完全一致。
    // 正文里没有动态表情时，CommentRichText 会把各段拼回单块 HTML，
    // 走与替换前逐字一致的老路径 —— 这是"动图"这个新特性不波及原有排版的保证。
    function commentSegmentsOf(content, emotes, isReply, jumpUrlInfos, candidateNames, atNameToMid) {
        var prefixHtml = ""
        var body = content || ""
        if (isReply) {
            var sp = panelRoot.splitReplyPrefix(body, candidateNames)
            if (sp) {
                prefixHtml = '<span style="color:' + FluTheme.fontSecondaryColor + ';">'
                           + panelRoot.escapeHtml(sp.prefix) + '</span>'
                body = sp.rest
            }
        }
        var segs = GlobalState.formatCommentSegments(body, emotes, {}, atNameToMid, jumpUrlInfos, {
            linkColor: "#00A1D6",
            hasPlayer: false,
            durationMs: 0,
            showPrefixIcon: true
        })
        if (prefixHtml === "") return segs
        // "回复 @xxx：" 前缀拼进第一个文本段；正文若以动态表情开头，
        // 就单独补一个只放前缀的文本段。
        var out = segs.slice()
        if (out.length > 0 && out[0].t === "text") {
            out[0] = { t: "text", html: prefixHtml + out[0].html, breakAfter: out[0].breakAfter }
        } else {
            out.unshift({ t: "text", html: prefixHtml, breakAfter: false })
        }
        return out
    }

    // 取评论的 jump_url 完整信息表。ListModel 存嵌套 map 时角色会失效
    //（m.jumpUrlInfos[key] 取不到值），故 C++ 侧另导出 jumpUrlInfosJson 字符串，
    // 与既有 atNamesJson 同一套路；楼中楼经 JSON 往返后可能已是对象，两者兼容。
    function jumpInfosOf(m) {
        if (!m) return {}
        if (m.jumpUrlInfosJson !== undefined && m.jumpUrlInfosJson !== null) {
            try { return JSON.parse(m.jumpUrlInfosJson || "{}") } catch (e) { return {} }
        }
        return m.jumpUrlInfos || {}
    }

    // 取评论的 @提及 用户名 -> mid 映射（同上，JSON 字符串往返）
    function atMidMapOf(m) {
        if (!m) return {}
        if (m.atNameToMidJson !== undefined && m.atNameToMidJson !== null) {
            try { return JSON.parse(m.atNameToMidJson || "{}") } catch (e) { return {} }
        }
        return m.atNameToMid || {}
    }

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

    // ============================================================
    // 评论区图片排布（参照 PiliPlus ImageGridView._calcGridInfo）
    // ============================================================
    // 对齐 PiliPlus 的部分：
    //   ① 列数：4 张 -> 2 列，其余多图 -> 3 列（PiliPlus: column = isFour ? 2 : 3）
    //   ② 单图：按原始宽高比分三档定宽 + 高度 2.6 倍宽封顶。这是唯一不裁剪的分支，
    //      也是「裁出来总是不是关键部位」这个问题的正解。
    //   ③ 长图：高/宽 > 2.6 时把裁剪锚点从居中改成顶部 —— 长截图的关键内容在顶部。
    // 有意保留的差异：
    //   ① 圆角沿用本项目评论图片的 6（PiliPlus 是 10），且每张图独立圆角，
    //      不用 PiliPlus 那种「只圆整块外圈」的拼图式圆角；
    //   ② 间距沿用本项目的 8（PiliPlus 是 5）；
    //   ③ 4 张时的单元格取「半宽」而不是 PiliPlus 的「1/3 宽」：后者会让 2x2 只占
    //      正文列宽的 2/3，右边空一大块，在评论卡片里观感像没排好。
    readonly property int commentImageSpacing: 8
    readonly property real commentImageMaxRatio: 2.6

    // 网格列数。PiliPlus 内部把「2 张」的 column 记作 3、再单独把单元格取成半宽，
    // 实际效果就是一行 2 张；这里直接按实际行数写，列数才与单元格宽度自洽。
    //   1 张 -> 1 列；2 张 / 4 张 -> 2 列；其余多图 -> 3 列
    function commentGridColumns(count) {
        if (count <= 1) return 1
        if (count === 2 || count === 4) return 2
        return 3
    }

    // 多图单元格边长（正方形）
    function commentSquareCellSize(containerWidth, count) {
        var cols = panelRoot.commentGridColumns(count)
        var usable = containerWidth - panelRoot.commentImageSpacing * (cols - 1)
        return Math.max(1, Math.floor(usable / cols))
    }

    // 单图尺寸：按原始宽高比自适应（PiliPlus isSingle 分支的逐句移植）。
    //   ratioHW = 原始高 / 原始宽；origWidth <= 0 表示接口没给尺寸，此时不做「不放大」约束。
    //   ratioWH > 1.45（很宽）              -> 占满正文列宽
    //   否则 ratioWH >= 1 或 高宽比 < 1.5   -> 2/3 正文列宽
    //   否则（很竖）                        -> 1/2 正文列宽
    // 宽度再取 min(列宽, 原图宽) 以免放大；高度 = 宽度 × min(高宽比, 2.6)。
    function commentSingleImageSize(containerWidth, origWidth, ratioHW) {
        if (containerWidth <= 0) return Qt.size(100, 100)
        var ratio = ratioHW > 0 ? ratioHW : 1
        var ratioWH = 1 / ratio
        var base = (containerWidth - panelRoot.commentImageSpacing * 2) / 3
        var outW
        if (ratioWH > 1.45) {
            outW = containerWidth
        } else if (ratioWH >= 1 || (ratio > 1 && ratio < 1.5)) {
            outW = 2 * base
        } else {
            outW = 1.5 * base
        }
        if (origWidth > 0) outW = Math.min(outW, origWidth)
        outW = Math.max(1, Math.min(outW, containerWidth))
        var outH = outW * Math.min(ratio, panelRoot.commentImageMaxRatio)
        return Qt.size(outW, Math.max(1, outH))
    }

    // 单元格尺寸：单图走按比例分支，多图走正方形分支
    function commentCellSize(containerWidth, count, origWidth, ratioHW) {
        if (count <= 1) return panelRoot.commentSingleImageSize(containerWidth, origWidth, ratioHW)
        var s = panelRoot.commentSquareCellSize(containerWidth, count)
        return Qt.size(s, s)
    }

    // 方形缩略图的裁剪锚点。
    // B 站图床 "@<w>w_<h>h_<anchor>.jpg" 的 anchor 实测（fix3/cdn_crop_probe*.py 逐像素定位）：
    //   1e_1c = 居中；1e_2c = 左上；1e_3c = 右下
    // 锚点是**服务端**裁剪，客户端再设 verticalAlignment 也救不回来 —— 所以必须在这里选对。
    //   竖图/方图（高 >= 宽）在方形格子里有多余的纵向空间 -> 取顶部(1e_2c)，
    //     否则会像官方预设那样把头部、正文开头居中裁掉；
    //   横图（高 < 宽）纵向没有余量，纵向锚点毫无意义，而 1e_2c 会连带变成「靠左裁」，
    //     所以横图继续用居中(1e_1c)。
    function commentCropAnchor(pic) {
        if (pic && pic.width > 0 && pic.height > 0 && pic.height >= pic.width) return "1e_2c"
        return "1e_1c"
    }

    // 评论图片缩略图 URL。
    //   crop=false -> "@<w>w.jpg"             只按宽缩放、保持原始比例，交给客户端适配/裁剪
    //   crop=true  -> "@<w>w_<h>h_<anchor>.jpg"  服务端直接裁成目标尺寸（省流量，锚点见 commentCropAnchor）
    // 请求宽度取显示宽度的 5 倍（沿用 wiliwili 的做法），避免缩略图分辨率过低被过度放大。
    // 动图（.gif/.webp）必须取原图：追加 @ 转换参数会被 CDN 按静态 jpg 返回，只剩第一帧。
    function commentThumbUrl(pic, width, height, crop) {
        if (!pic || !pic.imgSrc) return ""
        var src = pic.imgSrc
        if (pic.isAnimated) return src
        if (src.indexOf("@") >= 0) return src
        // 固定请求宽度（与布局无关）：缩放窗口时不重新下载，只做本地缩放。
        // 高度只按格子比例算（评论区是方形格子），不跟实际像素走。
        if (!crop) return src + "@" + GlobalState.imageFullRequestWidth + "w.jpg"
        var ratio = width > 0 ? height / width : 1
        var w = GlobalState.imageThumbRequestWidth
        var h = Math.max(1, Math.round(w * ratio))
        return src + "@" + w + "w_" + h + "h_" + panelRoot.commentCropAnchor(pic) + ".jpg"
    }

    function openCommentImagePreview(images, startIndex) {
        if (!images || panelRoot.commentPicCount(images) === 0) return
        panelRoot.commentPreviewImages = images
        panelRoot.commentPreviewIndex = Math.max(0, Math.min(startIndex, panelRoot.commentPicCount(images) - 1))
        panelRoot.commentImagePreviewVisible = true
    }

    function closeCommentImagePreview() {
        panelRoot.commentImagePreviewVisible = false
        panelRoot.commentPreviewImages = []
        panelRoot.commentPreviewIndex = 0
    }

    function previewCurrentImageSource() {
        var pic = panelRoot.commentPicAt(panelRoot.commentPreviewImages, panelRoot.commentPreviewIndex)
        return GlobalState.fixImageUrl(pic.imgSrc || "")
    }

    function previewCurrentImageIsAnimated() {
        var pic = panelRoot.commentPicAt(panelRoot.commentPreviewImages, panelRoot.commentPreviewIndex)
        return pic.isAnimated || false
    }

    function previewNextImage() {
        var count = panelRoot.commentPicCount(panelRoot.commentPreviewImages)
        if (count <= 1) return
        panelRoot.commentPreviewIndex = (panelRoot.commentPreviewIndex + 1) % count
    }

    function previewPrevImage() {
        var count = panelRoot.commentPicCount(panelRoot.commentPreviewImages)
        if (count <= 1) return
        panelRoot.commentPreviewIndex = (panelRoot.commentPreviewIndex - 1 + count) % count
    }

    function requireLogin() {
        if (!Login.isLoggedIn) {
            infoBar.showWarning("请先登录")
            return false
        }
        return true
    }

    function toggleCommentSort() {
        panelRoot.sortByHeat = !panelRoot.sortByHeat
        panelRoot.requestSort(panelRoot.sortByHeat)
    }

    FluInfoBar {
        id: infoBar
        root: panelRoot
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 8

        // 评论头部
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 32

            FluText {
                text: panelRoot.sortByHeat ? "热门评论" : "最新评论"
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
                        text: panelRoot.sortByHeat ? "按热度" : "按时间"
                        font: FluTextStyle.Caption
                        color: FluTheme.fontSecondaryColor
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.ArrowCursor
                    onClicked: { panelRoot.toggleCommentSort() }
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
                    model: panelRoot.commentModel

                    Rectangle {
                        id: commentItem
                        width: parent.width
                        height: commentItemLayout.height + 16
                        color: "transparent"
                        property int commentIndex: index
                        property var parentModel: model

                        // 右键"命中归属"标记：commentMetaAt() 从最深的子项往上找它，
                        // 楼中楼行上也有同名标记 —— 近者优先，所以子评论赢过卡片。
                        property var commentMeta: panelRoot.commentMetaOf(model.content, model.rpid)

                        // 评论右键菜单（复制）。整张卡片只此一个右键 Handler，主评论与
                        // 楼中楼都由它经 commentMetaAt() 判定归属（原因见 commentMetaAt
                        // 的注释：两个重叠 Handler 谁赢不稳定）。
                        // 用 TapHandler 而不是铺一层 MouseArea：
                        // ① 只接受右键，左键事件链完全不碰（拖拽滚动 / 链接点击不受影响）；
                        // ② Handler 不是 Item，不参与布局，也不会和卡片里已有的
                        //    头像/用户名/图片等 MouseArea 抢左键。
                        TapHandler {
                            acceptedButtons: Qt.RightButton
                            onTapped: function(eventPoint) {
                                var sp = eventPoint.scenePosition
                                var meta = panelRoot.commentMetaAt(commentItem, sp.x, sp.y)
                                               || commentItem.commentMeta   // 兜底：至少给主评论
                                if (!meta) return
                                panelRoot.openCommentContextMenu(meta.text, meta.permalink,
                                                                 eventPoint, commentItem)
                            }
                        }

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

                                // 头像可点击：打开评论作者的用户主页。
                                // 经 App 广播由当前可见导航页处理（按既定规则
                                // 先关闭视频播放页再开主页）
                                Item {
                                    implicitWidth: 32
                                    implicitHeight: 32
                                    Layout.alignment: Qt.AlignTop

                                    AvatarWithPendant {
                                        anchors.fill: parent
                                        face: model.face || ""
                                        pendantImage: model.pendantImage || ""
                                        avatarSize: 32
                                        verifyType: model.verifyType !== undefined ? model.verifyType : -1
                                        isVip: model.isVip === true
                                        hasCollect: model.hasCollect === true
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.ArrowCursor
                                        onClicked: panelRoot.openUserPage(model.mid, model.uname, model.face)
                                    }
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

                                            MouseArea {
                                                anchors.fill: parent
                                                cursorShape: Qt.ArrowCursor
                                                onClicked: panelRoot.openUserPage(model.mid, model.uname, model.face)
                                            }
                                        }

                                        Image {
                                            source: panelRoot.levelIconSource(model.level, model.isSeniorMember === true)
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
                                            visible: panelRoot.isUpAuthor(model.mid)
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

                                    CommentRichText {
                                        segments: panelRoot.commentSegmentsOf(model.content, model.emotes, false, panelRoot.jumpInfosOf(model), null, panelRoot.atMidMapOf(model))
                                        bodyFont: FluTextStyle.Body
                                        bodyColor: FluTheme.fontPrimaryColor
                                        Layout.fillWidth: true
                                        Layout.preferredWidth: 0
                                        Layout.topMargin: 14
                                        onLinkActivated: function(link) {
                                            // 统一路由：video: / user: / search: / web: 等
                                            // App 必须显式传入：GlobalState 是 pragma Singleton，
                                            // 内部解析不到 main.cpp 的上下文属性 App
                                            // 本组件无播放器上下文，格式化器不会产出 timestamp: 链接
                                            if (!GlobalState.openCommentLink(link, App)) {
                                                console.warn("[CommentPanel] 未识别的评论链接:", link)
                                            }
                                        }
                                    }

                                    Grid {
                                        Layout.topMargin: 4
                                        Layout.fillWidth: true
                                        property int imageCount: panelRoot.commentPicCount(commentItem.parentModel.pictures)
                                        columns: panelRoot.commentGridColumns(imageCount)
                                        rowSpacing: panelRoot.commentImageSpacing
                                        columnSpacing: panelRoot.commentImageSpacing

                                        Repeater {
                                            model: panelRoot.commentPicCount(commentItem.parentModel.pictures)

                                            Rectangle {
                                                id: mainImageContainer
                                                property var pic: panelRoot.commentPicAt(commentItem.parentModel.pictures, index)
                                                property int picCount: panelRoot.commentPicCount(commentItem.parentModel.pictures)
                                                property bool isSinglePic: picCount === 1
                                                // 接口没给 img_width/img_height 时，用解码出来的真实宽高比回填
                                                property real decodedRatio: 0
                                                property real picRatio: {
                                                    if (pic.width > 0 && pic.height > 0)
                                                        return pic.height / pic.width
                                                    if (decodedRatio > 0)
                                                        return decodedRatio
                                                    return 0
                                                }
                                                // 长图：高/宽 超过 2.6 倍（与 PiliPlus isLongPic 同口径）
                                                property bool isLongPic: picRatio > panelRoot.commentImageMaxRatio
                                                // 单图按原始比例、多图正方形（见 commentCellSize 注释）
                                                property size cellSize: panelRoot.commentCellSize(commentItemLayout.width - 48,
                                                                                                 picCount, pic.width, picRatio)

                                                width: cellSize.width
                                                height: cellSize.height
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
                                                        // 单图（非长图）取原比例图不裁；其余（多图任意 / 单图长图）都让 CDN 按容器比例裁；
                                                        // 注意不能用 "@Ww_Hh.jpg"（无 _1c）—— contain 语义会把长图缩成细条再放大，排布就糊了
                                                        source: GlobalState.fixImageUrl(panelRoot.commentThumbUrl(
                                                                                            mainImageContainer.pic,
                                                                                            mainImageContainer.width,
                                                                                            mainImageContainer.height,
                                                                                            !mainImageContainer.isSinglePic || mainImageContainer.isLongPic))
                                                        fillMode: (mainImageContainer.isSinglePic && !mainImageContainer.isLongPic)
                                                                  ? Image.PreserveAspectFit : Image.PreserveAspectCrop
                                                        verticalAlignment: mainImageContainer.isLongPic ? Image.AlignTop : Image.AlignVCenter
                                                        asynchronous: true
                                                        cache: true
                                                        smooth: true
                                                        onSourceSizeChanged: {
                                                            if (mainImageContainer.pic.width <= 0 && sourceSize.width > 0 && sourceSize.height > 0)
                                                                mainImageContainer.decodedRatio = sourceSize.height / sourceSize.width
                                                        }
                                                    }
                                                }

                                                Component {
                                                    id: commentAnimatedImageComponent
                                                    AnimatedImage {
                                                        anchors.fill: parent
                                                        // 动图必须取原图，不能加任何 CDN 转换参数
                                                        source: GlobalState.fixImageUrl(panelRoot.commentThumbUrl(
                                                                                            mainImageContainer.pic,
                                                                                            mainImageContainer.width,
                                                                                            mainImageContainer.height,
                                                                                            false))
                                                        fillMode: (mainImageContainer.isSinglePic && !mainImageContainer.isLongPic)
                                                                  ? Image.PreserveAspectFit : Image.PreserveAspectCrop
                                                        verticalAlignment: mainImageContainer.isLongPic ? Image.AlignTop : Image.AlignVCenter
                                                        cache: true
                                                        smooth: true
                                                        playing: true
                                                        onSourceSizeChanged: {
                                                            if (mainImageContainer.pic.width <= 0 && sourceSize.width > 0 && sourceSize.height > 0)
                                                                mainImageContainer.decodedRatio = sourceSize.height / sourceSize.width
                                                        }
                                                    }
                                                }

                                                // 长图角标：提示这张图只显示了顶部一截，点开可看完整
                                                Rectangle {
                                                    anchors.right: parent.right
                                                    anchors.bottom: parent.bottom
                                                    anchors.margins: 6
                                                    width: mainLongTag.implicitWidth + 10
                                                    height: mainLongTag.implicitHeight + 4
                                                    radius: 4
                                                    color: Qt.rgba(0, 0, 0, 0.55)
                                                    visible: mainImageContainer.isLongPic

                                                    FluText {
                                                        id: mainLongTag
                                                        anchors.centerIn: parent
                                                        text: "长图"
                                                        font: FluTextStyle.Caption
                                                        color: "white"
                                                    }
                                                }

                                                MouseArea {
                                                    anchors.fill: parent
                                                    // z:-1 垫底：让 FluImage 加载失败时的 Reload 按钮可点击，
                                                    // 否则点击被图片预览事件截走
                                                    z: -1
                                                    cursorShape: Qt.ArrowCursor
                                                    onClicked: {
                                                        panelRoot.openCommentImagePreview(commentItem.parentModel.pictures, index)
                                                    }
                                                }
                                            }
                                        }
                                    }

                            // ====== 操作栏（时间、IP、回复、点赞、点踩）======
                            // 关键：必须放在【头像右侧ColumnLayout(L331)】内部，跟用户名/正文在同一个父容器，
                            // 这样它的Layout.left天然跟用户名、正文、图片的左边完全对齐，
                            // 再也不需要靠手动Layout.leftMargin: 40去硬凑Avatar宽度+spacing
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
                                        if (!panelRoot.requireLogin()) return
                                        panelRoot.replyRpid = model.rpid || ""
                                        panelRoot.replyRootRpid = (model.root && model.root !== "0") ? model.root : (model.rpid || "")
                                        panelRoot.replyToUser = model.uname || ""
                                        // 点击回复即聚焦输入框，用户可直接输入
                                        commentInput.forceActiveFocus()
                                    }
                                }

                                Item { Layout.fillWidth: true }

                                FluTextButton {
                                    font: FluTextStyle.Caption
                                    textColor: FluTheme.fontSecondaryColor
                                    onClicked: {
                                        if (!model.rpid || !panelRoot.commentModel || index < 0) return
                                        if (!panelRoot.requireLogin()) return
                                        var oldAction = model.action || 0
                                        var newAction = oldAction === 1 ? 0 : 1
                                        if (panelRoot.aid !== "" && panelRoot.aid !== undefined) {
                                            if (oldAction === 2) {
                                                CommentManager.hateComment(model.rpid, panelRoot.aid, panelRoot.commentType, 0)
                                            }
                                            CommentManager.likeComment(model.rpid, panelRoot.aid, panelRoot.commentType, newAction)
                                        }
                                        panelRoot.commentModel.setProperty(index, "action", newAction)
                                        panelRoot.commentModel.setProperty(index, "like", model.like + (newAction === 1 ? 1 : -1))
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
                                    visible: panelRoot.showDislike
                                    textColor: model.action === 2 ? FluTheme.primaryColor : FluTheme.fontSecondaryColor
                                    onClicked: {
                                        if (!model.rpid || !panelRoot.commentModel || index < 0) return
                                        if (!panelRoot.requireLogin()) return
                                        var oldAction = model.action || 0
                                        var newAction = oldAction === 2 ? 0 : 2
                                        if (panelRoot.aid !== "" && panelRoot.aid !== undefined) {
                                            if (oldAction === 1) {
                                                CommentManager.likeComment(model.rpid, panelRoot.aid, panelRoot.commentType, 0)
                                            }
                                            CommentManager.hateComment(model.rpid, panelRoot.aid, panelRoot.commentType, newAction === 2 ? 1 : 0)
                                        }
                                        panelRoot.commentModel.setProperty(index, "action", newAction)
                                        if (oldAction === 1) panelRoot.commentModel.setProperty(index, "like", model.like - 1)
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
                                        panelRoot.commentModel.setProperty(index, "repliesExpanded", after)
                                        panelRoot.commentModel.setProperty(index, "repliesPage", 1)
                                        if (after && model.aid !== "" && model.aid !== undefined && model.rpid !== "") {
                                            panelRoot.requestSubComments(model.aid, model.rpid, 1, 10)
                                        }
                                        if (!after) {
                                            commentFlickable.contentY = commentItem.y
                                        }
                                    }
                                }
                                }
                            }

                    // 子评论列表（展开的楼中楼）：外层套一个圆角灰底，把这一整块
                    // 包成一个独立区块，与主评论正文拉开层次。
                    //   · 底色 FluTheme.frameColor —— 与本文件里评论图片的占位
                    //     底色同源，且随明暗主题自适应（浅色 ≈ #F3F3F3 / 深色 ≈
                    //     #383838），不会在暗色下露出浅灰；
                    //   · 圆角 Theme.radiusMedium(8) —— 项目里内层 surface 的统一
                    //     圆角（数值 = Theme.frameRadius，且大于块内图片的 6，
                    //     满足「外大内小」）。
                    // 只在外层加壳：内层 ColumnLayout 的子项结构一字未动，块内
                    // `parent.subReplies` / `parent.parent.parent.replyCandidates`
                    // 这些父子链因此完全不受影响。
                    // （内层保留原有缩进，便于对照 diff。）
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.topMargin: 4
                        // 内层改用 anchors 定位，不再是本 Layout 的直接子项，
                        // 所以要显式给出高度：内容高 + 上下各 8px 内边距
                        implicitHeight: subReplyLayout.implicitHeight + 16
                        radius: Theme.radiusMedium
                        color: FluTheme.frameColor
                        visible: model.repliesExpanded

                        ColumnLayout {
                            id: subReplyLayout
                            anchors.fill: parent
                            anchors.margins: 8
                            spacing: 8
                        property var subReplies: JSON.parse(model.repliesJson || "[]") || []
                        // 楼中楼"回复 @xxx"前缀切分的候选用户名：
                        // 根评论作者 + 已加载子评论作者（未加载页/已删评论
                        // 的作者不在集合内，切分回退冒号启发式）
                        property var replyCandidates: {
                            var names = [model.uname]
                            for (var i = 0; i < subReplies.length; i++) {
                                if (subReplies[i].uname) names.push(subReplies[i].uname)
                            }
                            return names
                        }

                        Repeater {
                                    model: parent.subReplies

                                    RowLayout {
                                        id: subReplyRow
                                        Layout.fillWidth: true
                                        spacing: 8

                                        // 右键"命中归属"标记：这条行比外层卡片更靠近落点，
                                        // 所以 commentMetaAt() 往上找时会先撞到它 —— 楼中楼
                                        // 的右键菜单因此拿到的是子评论自己的内容。
                                        // （不需要单独的 TapHandler：卡片上那一个就够了，
                                        //   两个重叠 Handler 谁拿到 tap 由 Qt 投递顺序决定。）
                                        property var commentMeta: panelRoot.commentMetaOf(modelData.content, modelData.rpid)

                                        // 子评论头像可点击：打开评论作者的用户主页
                                        Item {
                                            implicitWidth: 28
                                            implicitHeight: 28
                                            Layout.alignment: Qt.AlignTop

                                            AvatarWithPendant {
                                                anchors.fill: parent
                                                face: modelData.face || ""
                                                pendantImage: modelData.pendantImage || ""
                                                avatarSize: 28
                                                verifyType: modelData.verifyType !== undefined ? modelData.verifyType : -1
                                                isVip: modelData.isVip === true
                                                hasCollect: modelData.hasCollect === true
                                                placeholderText: "?"
                                            }

                                            MouseArea {
                                                anchors.fill: parent
                                                cursorShape: Qt.ArrowCursor
                                                onClicked: panelRoot.openUserPage(modelData.mid, modelData.uname, modelData.face)
                                            }
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

                                                    MouseArea {
                                                        anchors.fill: parent
                                                        cursorShape: Qt.ArrowCursor
                                                        onClicked: panelRoot.openUserPage(modelData.mid, modelData.uname, modelData.face)
                                                    }
                                                }

                                                Image {
                                                    source: panelRoot.levelIconSource(modelData.level, modelData.isSeniorMember === true)
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
                                                    visible: panelRoot.isUpAuthor(modelData.mid)
                                                    asynchronous: true
                                                }
                                            }

                                            CommentRichText {
                                                // 候选用户名 = 根评论作者 + 已加载子评论作者（用于
                                                // "回复 @xxx" 前缀的精确切分，见 splitReplyPrefix）
                                                segments: panelRoot.commentSegmentsOf(modelData.content, modelData.emotes, true, panelRoot.jumpInfosOf(modelData),
                                                                                      parent.parent.parent.replyCandidates, panelRoot.atMidMapOf(modelData))
                                                bodyFont: FluTextStyle.Body
                                                bodyColor: FluTheme.fontPrimaryColor
                                                Layout.fillWidth: true
                                                Layout.preferredWidth: 0
                                                Layout.topMargin: 8
                                                onLinkActivated: function(link) {
                                                    // 统一路由：video: / user: / search: / web: 等
                                                    // App 必须显式传入（原因同上）
                                                    // 本组件无播放器上下文，格式化器不会产出 timestamp: 链接
                                                    if (!GlobalState.openCommentLink(link, App)) {
                                                        console.warn("[CommentPanel] 未识别的评论链接:", link)
                                                    }
                                                }
                                            }

                                            Grid {
                                                Layout.topMargin: 4
                                                Layout.fillWidth: true
                                                property int imageCount: panelRoot.commentPicCount(modelData.pictures)
                                                columns: panelRoot.commentGridColumns(imageCount)
                                                rowSpacing: panelRoot.commentImageSpacing
                                                columnSpacing: panelRoot.commentImageSpacing

                                                Repeater {
                                                    model: panelRoot.commentPicCount(modelData.pictures)

                                                    Rectangle {
                                                        id: replyImageContainer
                                                        property var pic: panelRoot.commentPicAt(modelData.pictures, index)
                                                        property int picCount: panelRoot.commentPicCount(modelData.pictures)
                                                        property bool isSinglePic: picCount === 1
                                                        // 接口没给 img_width/img_height 时，用解码出来的真实宽高比回填
                                                        property real decodedRatio: 0
                                                        property real picRatio: {
                                                            if (pic.width > 0 && pic.height > 0)
                                                                return pic.height / pic.width
                                                            if (decodedRatio > 0)
                                                                return decodedRatio
                                                            return 0
                                                        }
                                                        property bool isLongPic: picRatio > panelRoot.commentImageMaxRatio
                                                        property size cellSize: panelRoot.commentCellSize(commentItemLayout.width - 48,
                                                                                                         picCount, pic.width, picRatio)

                                                        width: cellSize.width
                                                        height: cellSize.height
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
                                                                // 单图（非长图）取原比例图不裁；其余（多图任意 / 单图长图）都让 CDN 按容器比例裁
                                                                source: GlobalState.fixImageUrl(panelRoot.commentThumbUrl(
                                                                                                    replyImageContainer.pic,
                                                                                                    replyImageContainer.width,
                                                                                                    replyImageContainer.height,
                                                                                                    !replyImageContainer.isSinglePic || replyImageContainer.isLongPic))
                                                                fillMode: (replyImageContainer.isSinglePic && !replyImageContainer.isLongPic)
                                                                          ? Image.PreserveAspectFit : Image.PreserveAspectCrop
                                                                verticalAlignment: replyImageContainer.isLongPic ? Image.AlignTop : Image.AlignVCenter
                                                                asynchronous: true
                                                                cache: true
                                                                smooth: true
                                                                onSourceSizeChanged: {
                                                                    if (replyImageContainer.pic.width <= 0 && sourceSize.width > 0 && sourceSize.height > 0)
                                                                        replyImageContainer.decodedRatio = sourceSize.height / sourceSize.width
                                                                }
                                                            }
                                                        }

                                                        Component {
                                                            id: replyAnimatedImageComponent
                                                            AnimatedImage {
                                                                anchors.fill: parent
                                                                // 动图必须取原图，不能加任何 CDN 转换参数
                                                                source: GlobalState.fixImageUrl(panelRoot.commentThumbUrl(
                                                                                                    replyImageContainer.pic,
                                                                                                    replyImageContainer.width,
                                                                                                    replyImageContainer.height,
                                                                                                    false))
                                                                fillMode: (replyImageContainer.isSinglePic && !replyImageContainer.isLongPic)
                                                                          ? Image.PreserveAspectFit : Image.PreserveAspectCrop
                                                                verticalAlignment: replyImageContainer.isLongPic ? Image.AlignTop : Image.AlignVCenter
                                                                cache: true
                                                                smooth: true
                                                                playing: true
                                                                onSourceSizeChanged: {
                                                                    if (replyImageContainer.pic.width <= 0 && sourceSize.width > 0 && sourceSize.height > 0)
                                                                        replyImageContainer.decodedRatio = sourceSize.height / sourceSize.width
                                                                }
                                                            }
                                                        }

                                                        // 长图角标：提示这张图只显示了顶部一截，点开可看完整
                                                        Rectangle {
                                                            anchors.right: parent.right
                                                            anchors.bottom: parent.bottom
                                                            anchors.margins: 6
                                                            width: replyLongTag.implicitWidth + 10
                                                            height: replyLongTag.implicitHeight + 4
                                                            radius: 4
                                                            color: Qt.rgba(0, 0, 0, 0.55)
                                                            visible: replyImageContainer.isLongPic

                                                            FluText {
                                                                id: replyLongTag
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
                                                                panelRoot.openCommentImagePreview(modelData.pictures, index)
                                                            }
                                                        }
                                                    }
                                                }
                                            }

                                            // ====== 回复评论：操作栏（时间/IP/回复/点赞/点踩）======
                                            // 关键：与主评论同样，必须放在【回复头像右侧ColumnLayout(L626)】内部，
                                            // 它的Layout.left就自然和回复用户名、回复正文、回复图片的左边完全对齐，
                                            // 不需要任何额外的Layout.leftMargin去硬凑头像+spacing。
                                            RowLayout {
                                                Layout.fillWidth: true
                                                Layout.topMargin: 6
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
                                                        if (!panelRoot.requireLogin()) return
                                                        panelRoot.replyRpid = modelData.rpid || ""
                                                        panelRoot.replyRootRpid = commentItem.parentModel.rpid || ""
                                                        panelRoot.replyToUser = modelData.uname || ""
                                                        // 点击回复即聚焦输入框，用户可直接输入
                                                        commentInput.forceActiveFocus()
                                                    }
                                                }

                                                Item { Layout.fillWidth: true }

                                                FluTextButton {
                                                    font: FluTextStyle.Caption
                                                    textColor: modelData.action === 1 ? FluTheme.primaryColor : FluTheme.fontSecondaryColor
                                                    onClicked: {
                                                        if (!modelData.rpid || modelData.oid === "" || modelData.oid === undefined) return
                                                        if (!panelRoot.requireLogin()) return
                                                        var oldAction = modelData.action || 0
                                                        var newAction = oldAction === 1 ? 0 : 1
                                                        if (panelRoot.aid !== "" && panelRoot.aid !== undefined) {
                                                            if (oldAction === 2) {
                                                                CommentManager.hateComment(modelData.rpid, modelData.oid, panelRoot.commentType, 0)
                                                            }
                                                            CommentManager.likeComment(modelData.rpid, modelData.oid, panelRoot.commentType, newAction)
                                                        }
                                                        var list = JSON.parse(commentItem.parentModel.repliesJson || "[]") || []
                                                        var idx = index
                                                        if (idx >= 0 && idx < list.length) {
                                                            var item = Object.assign({}, list[idx])
                                                            item.action = newAction
                                                            if (newAction === 1) item.like = (item.like || 0) + 1
                                                            else if (oldAction === 1) item.like = (item.like || 0) - 1
                                                            var newList = list.slice()
                                                            newList[idx] = item
                                                            panelRoot.commentModel.setProperty(commentItem.commentIndex, "repliesJson", JSON.stringify(newList))
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
                                                    visible: panelRoot.showDislike
                                                    textColor: modelData.action === 2 ? FluTheme.primaryColor : FluTheme.fontSecondaryColor
                                                    onClicked: {
                                                        if (!modelData.rpid || modelData.oid === "" || modelData.oid === undefined) return
                                                        if (!panelRoot.requireLogin()) return
                                                        var oldAction = modelData.action || 0
                                                        var newAction = oldAction === 2 ? 0 : 2
                                                        if (panelRoot.aid !== "" && panelRoot.aid !== undefined) {
                                                            if (oldAction === 1) {
                                                                CommentManager.likeComment(modelData.rpid, modelData.oid, panelRoot.commentType, 0)
                                                            }
                                                            CommentManager.hateComment(modelData.rpid, modelData.oid, panelRoot.commentType, newAction === 2 ? 1 : 0)
                                                        }
                                                        var list = JSON.parse(commentItem.parentModel.repliesJson || "[]") || []
                                                        var idx = index
                                                        if (idx >= 0 && idx < list.length) {
                                                            var item = Object.assign({}, list[idx])
                                                            item.action = newAction
                                                            if (oldAction === 1) item.like = (item.like || 0) - 1
                                                            var newList = list.slice()
                                                            newList[idx] = item
                                                            panelRoot.commentModel.setProperty(commentItem.commentIndex, "repliesJson", JSON.stringify(newList))
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
                                        panelRoot.commentModel.setProperty(index, "repliesPage", page)
                                        commentFlickable.contentY = commentItem.y
                                        if (model.aid !== "" && model.aid !== undefined) {
                                            panelRoot.requestSubComments(model.aid, model.rpid, page, count)
                                        }
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
                                        panelRoot.commentModel.setProperty(index, "repliesExpanded", false)
                                        panelRoot.commentModel.setProperty(index, "repliesPage", 1)
                                        commentFlickable.contentY = commentItem.y
                                    }
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
                    visible: panelRoot.commentTotal > 0
                }

                FluPaginationSimple {
                    width: parent.width
                    visible: panelRoot.commentTotal > 0
                    itemCount: panelRoot.commentTotal
                    pageSize: 20
                    pageCurrent: panelRoot.commentPage
                    hasNextPage: panelRoot.commentHasNextPage
                    onRequestPage: function (page) {
                        panelRoot.requestPage(page, 20)
                    }
                }

                FluText {
                    width: parent.width
                    // 空列表时才有意义：请求中显示「正在加载评论...」，请求结束仍为空
                    // 才是「暂无评论」。原写法两个分支都挂在 count === 0 上，而 visible
                    // 又要求 count === 0 —— text 永远只能取到「暂无评论」，
                    // 「正在加载评论...」是一句走不到的死分支。
                    text: panelRoot.commentLoading ? "正在加载评论..." : "暂无评论"
                    font: FluTextStyle.Caption
                    color: FluTheme.fontSecondaryColor
                    horizontalAlignment: Text.AlignHCenter
                    padding: 12
                    visible: panelRoot.commentModel && panelRoot.commentModel.count === 0
                }
            }
        }

        // 发布评论
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 40
            Layout.leftMargin: 8
            Layout.rightMargin: 8
            spacing: 8

            FluTextBox {
                id: commentInput
                Layout.fillWidth: true
                placeholderText: panelRoot.replyToUser !== "" ? "回复 @" + panelRoot.replyToUser + "..." : "说点什么..."
            }

            FluTextButton {
                text: "取消"
                font: FluTextStyle.Caption
                textColor: FluTheme.fontSecondaryColor
                visible: panelRoot.replyToUser !== ""
                onClicked: panelRoot.cancelReply()
            }

            FluButton {
                text: "发布"
                Layout.preferredWidth: 60
                onClicked: {
                    if (commentInput.text === "") return
                    if (!panelRoot.requireLogin()) return
                    if (panelRoot.aid === "" || panelRoot.aid === undefined) {
                        panelRoot.commentModel.insert(0, {
                            rpid: "new_" + Date.now(),
                            uname: "我",
                            face: "",
                            level: 6,
                            content: commentInput.text,
                            ctime: Math.floor(Date.now() / 1000),
                            timeDesc: "刚刚",
                            ipLocation: "",
                            like: 0,
                            action: 0,
                            isTop: false,
                            isVip: false,
                            repliesJson: JSON.stringify([]),
                            emotes: {},
                            jumpUrls: {},
                            pictures: [],
                            count: 0,
                            repliesExpanded: false,
                            repliesPage: 1,
                            aid: "",
                            oid: "",
                            root: "0"
                        })
                    } else {
                        var rootId = panelRoot.replyRootRpid
                        var parentId = panelRoot.replyRpid
                        panelRoot.requestSendComment(commentInput.text, rootId, parentId)
                    }
                    commentInput.text = ""
                    panelRoot.cancelReply()
                }
            }
        }
    }

    // 评论图片全屏预览
    Rectangle {
        id: commentImagePreviewOverlay
        parent: panelRoot.previewOverlayParent
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.9)
        visible: panelRoot.commentImagePreviewVisible
        z: 104

        // 预览层的鼠标交互：左键单击关闭、右键弹菜单。
        // 注意图片本身那一块落在 ImageViewer 自己的左键 MouseArea 上（要做拖动
        // 平移，左键必须先给它），所以那块区域里的「单击关闭」由 ImageViewer 的
        // clicked() 补上，见下面 ImageViewer 的 onClicked；右键 ImageViewer
        // 不接收（它只声明了 LeftButton），会落回这里。
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: (mouse) => {
                if (mouse.button === Qt.RightButton)
                    previewMenu.openAt(mouse.x, mouse.y)
                else
                    panelRoot.closeCommentImagePreview()
                mouse.accepted = true
            }
        }

        ImageViewer {
            id: previewImageViewer
            anchors.centerIn: parent
            width: parent.width - 80
            height: parent.height - 80
            source: panelRoot.previewCurrentImageSource()
            animated: panelRoot.previewCurrentImageIsAnimated()
            // 左键单击（按下到松开之间没拖动）＝ 关闭预览。
            // 放大后按住左键拖动是平移，不会走到这里。
            onClicked: panelRoot.closeCommentImagePreview()
        }

        // 右键菜单：复制图片 / 下载图片 / 重置缩放
        ImagePreviewMenu {
            id: previewMenu
            imageUrl: panelRoot.previewCurrentImageSource()
            zoomed: previewImageViewer.zoomed
            notifyBar: infoBar
            onResetZoomRequested: previewImageViewer.reset()
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
                onClicked: panelRoot.closeCommentImagePreview()
            }
        }

        // 左切换按钮
        Rectangle {
            visible: panelRoot.commentPicCount(panelRoot.commentPreviewImages) > 1
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
                onClicked: panelRoot.previewPrevImage()
            }
        }

        // 右切换按钮
        Rectangle {
            visible: panelRoot.commentPicCount(panelRoot.commentPreviewImages) > 1
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
                onClicked: panelRoot.previewNextImage()
            }
        }

        // 图片计数
        Text {
            visible: panelRoot.commentPicCount(panelRoot.commentPreviewImages) > 1
            anchors.bottom: parent.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottomMargin: 24
            text: (panelRoot.commentPreviewIndex + 1) + " / " + panelRoot.commentPicCount(panelRoot.commentPreviewImages)
            color: "white"
            font.pixelSize: 14
        }
    }
}