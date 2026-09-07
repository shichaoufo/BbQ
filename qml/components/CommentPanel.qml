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
    property int commentPage: 1
    property bool commentHasNextPage: true
    property int commentType: 1
    property bool showDislike: true
    property var previewOverlayParent: panelRoot
    property string ownerMid: ""

    function isUpAuthor(mid) {
        if (!panelRoot.ownerMid || mid === undefined || mid === null || mid === "") return false
        return String(mid) === String(panelRoot.ownerMid)
    }

    function levelIconSource(level) {
        return "qrc:/BiliQt/icons/level/user-lv" + (level || 0) + ".svg"
    }

    property string replyToUser: ""
    property string replyRpid: ""
    property string replyRootRpid: ""

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

    // 判断 jump_url 的 key 是否为可跳转的视频链接，返回 BV/av 号（大写 BV）或空串。
    // 仅静态识别两类：bilibili.com/video/BVxxx|avxxx 直链、b23.tv/BVxxx|avxxx 直书短链
    //（b23.tv 随机码短链目标不确定，mall/link 外链为商品页，均不跳转）。
    function videoIdFromJumpKey(key) {
        if (!key) return ""
        var m = key.match(/bilibili\.com\/video\/(BV[0-9A-Za-z]{10}|av[0-9]+)/i)
        if (m) return m[1]
        m = key.match(/b23\.tv\/(BV[0-9A-Za-z]{10}|av[0-9]+)(?:[/?#]|$)/i)
        if (m) return m[1]
        return ""
    }

    // 返回结果已经过 HTML 转义，可直接用于 RichText。
    // 视频类链接（bilibili.com/video 直链 / b23.tv 直书短链）替换为可点击链接，
    // 其余（商品外链、搜索热词等）仅染蓝不可点击。
    function replaceJumpUrls(htmlText, jumpUrls) {
        if (!jumpUrls) return panelRoot.escapeHtml(htmlText)
        var keys = Object.keys(jumpUrls)
        if (keys.length === 0) return panelRoot.escapeHtml(htmlText)
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
                    var videoId = panelRoot.videoIdFromJumpKey(key)
                    if (videoId !== "") {
                        result += '<a href="video:' + panelRoot.escapeHtml(videoId) + '" style="color:#00A1D6;text-decoration:none;">' + panelRoot.escapeHtml(title) + '</a>'
                    } else {
                        result += '<span style="color:#00A1D6;">' + panelRoot.escapeHtml(title) + '</span>'
                    }
                    pos += key.length
                    matched = true
                    break
                }
            }
            if (!matched) {
                result += panelRoot.escapeHtml(htmlText[pos])
                pos++
            }
        }
        return result
    }

    // 时间戳（MM:SS 或 HH:MM:SS，冒号支持半角/全角）仅染蓝——动态评论区无播放器
    // 上下文，不做进度跳转链接。输入必须是已经过 HTML 转义的文本。
    function replaceTimeStamps(htmlText) {
        return htmlText.replace(/(\d{1,2})[：:](\d{2})(?:[：:](\d{2}))?/g, function(match, p1, p2, p3) {
            var hours = 0, minutes = 0, seconds = 0
            if (p3 !== undefined && p3 !== "") {
                hours = parseInt(p1, 10)
                minutes = parseInt(p2, 10)
                seconds = parseInt(p3, 10)
            } else {
                minutes = parseInt(p1, 10)
                seconds = parseInt(p2, 10)
            }
            if (minutes >= 60 || seconds >= 60) return match
            return '<span style="color:#00A1D6;">' + match + '</span>'
        })
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

    // 将正文中所有出现的 token 替换为染蓝 span（非重叠、顺序扫描，
    // 不会重复匹配已插入的 span 内容）
    function colorAllOccurrences(htmlText, token) {
        var out = ""
        var pos = 0
        var idx = htmlText.indexOf(token)
        while (idx >= 0) {
            out += htmlText.substring(pos, idx)
                + '<span style="color:#00A1D6;">' + token + '</span>'
            pos = idx + token.length
            idx = htmlText.indexOf(token, pos)
        }
        return out + htmlText.substring(pos)
    }

    // 将正文中的 @提及（@昵称）染蓝（与链接同色）。
    // 仅用服务端 content.members 数据精确匹配（@面板插入的真提及），
    // 手打 @ 服务端不登记、此处也不染——与官方客户端行为完全一致。
    // 输入必须是已经过 HTML 转义的文本。
    function replaceAtMentions(htmlText, atNames) {
        if (!atNames || atNames.length === 0) return htmlText
        for (var i = 0; i < atNames.length; i++) {
            var n = atNames[i]
            if (!n || n.length < 1) continue
            // 名字需与已转义文本做同样转义后匹配
            htmlText = panelRoot.colorAllOccurrences(htmlText, "@" + panelRoot.escapeHtml(n))
        }
        return htmlText
    }

    // av 号转 BV 号（B站公开算法，mcfx 逆向，纯本地计算无网络请求）。
    // 仅适用于 2020-03 前的旧号段（av < 2^31），新视频评论里 av 形态极少，
    // 失配时换算结果无效但不崩溃（openVideo 请求会返回错误）。
    function avToBvid(avNum) {
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

    // 评论中的视频链接跳转：videoId 为 BVxxx 或 avxxx（来自 videoIdFromJumpKey）。
    // av 号本地换算成 BV 后统一走 App.openVideo 广播，由可见页面打开播放页
    //（动态页监听该信号打开自己的视频 overlay）。
    function openVideoFromComment(videoId) {
        if (!videoId || videoId === "") return
        if (videoId.startsWith("BV")) {
            App.openVideo(videoId, "")
        } else if (/^av\d+$/i.test(videoId)) {
            var avNum = parseInt(videoId.substring(2), 10)
            var bvid = panelRoot.avToBvid(avNum)
            if (bvid) App.openVideo(bvid, "")
        }
    }

    function formatCommentContent(content, emotes, isReply, jumpUrls, candidateNames, atNames) {
        var text
        var sp = isReply ? panelRoot.splitReplyPrefix(content, candidateNames) : null
        if (sp) {
            var gray = FluTheme.fontSecondaryColor
            var primary = FluTheme.fontPrimaryColor
            text = '<span style="color:' + gray + ';">' + panelRoot.escapeHtml(sp.prefix) + '</span>'
                 + '<span style="color:' + primary + ';">' + panelRoot.replaceAtMentions(panelRoot.replaceTimeStamps(panelRoot.replaceJumpUrls(sp.rest, jumpUrls)), atNames) + '</span>'
        } else {
            text = panelRoot.replaceAtMentions(panelRoot.replaceTimeStamps(panelRoot.replaceJumpUrls(content || "", jumpUrls)), atNames)
        }
        return panelRoot.replaceEmotesInHtml(text, emotes)
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

    function calcCommentGridImageSize(containerWidth) {
        var spacing = 8
        var half = Math.floor(containerWidth / 2)
        var size = half - spacing
        return Math.max(1, size)
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

    function getCommentImageThumbnailUrl(src, width, isAnimated) {
        if (!src) return ""
        if (isAnimated) return src
        if (src.indexOf("@") >= 0) return src
        var w = Math.round(width * 5)
        return src + "@" + w + "w_85q_!note-comment-multiple.jpg"
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
                    cursorShape: Qt.PointingHandCursor
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
                                            source: panelRoot.levelIconSource(model.level)
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

                                    FluText {
                                        text: panelRoot.formatCommentContent(model.content, model.emotes, false, model.jumpUrls, null, panelRoot.atNamesOf(model))
                                        font: FluTextStyle.Body
                                        color: FluTheme.fontPrimaryColor
                                        textFormat: Text.RichText
                                        wrapMode: Text.Wrap
                                        Layout.fillWidth: true
                                        Layout.preferredWidth: 0
                                        Layout.topMargin: 14
                                        verticalAlignment: Text.AlignTop
                                        onLinkActivated: function(link) {
                                            if (link.indexOf("video:") === 0) {
                                                panelRoot.openVideoFromComment(link.substring("video:".length))
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
                                                var count = panelRoot.commentPicCount(pics)
                                                return count
                                            }

                                            Rectangle {
                                                id: mainImageContainer
                                                property var pic: panelRoot.commentPicAt(commentItem.parentModel.pictures, index)
                                                property int imageSize: panelRoot.calcCommentGridImageSize(commentItemLayout.width - 48)
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
                                                        source: GlobalState.fixImageUrl(panelRoot.getCommentImageThumbnailUrl(mainImageContainer.pic.imgSrc, mainImageContainer.imageSize, false))
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
                                                        source: GlobalState.fixImageUrl(panelRoot.getCommentImageThumbnailUrl(mainImageContainer.pic.imgSrc, mainImageContainer.imageSize, true))
                                                        fillMode: mainImageContainer.picIsSmallerThanContainer ? Image.PreserveAspectFit : Image.PreserveAspectCrop
                                                        cache: true
                                                        smooth: true
                                                        playing: true
                                                    }
                                                }

                                                MouseArea {
                                                    anchors.fill: parent
                                                    // z:-1 垫底：让 FluImage 加载失败时的 Reload 按钮可点击，
                                                    // 否则点击被图片预览事件截走
                                                    z: -1
                                                    cursorShape: Qt.PointingHandCursor
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

                    // 子评论列表
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        visible: model.repliesExpanded
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
                                                    source: panelRoot.levelIconSource(modelData.level)
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

                                            FluText {
                                                // 候选用户名 = 根评论作者 + 已加载子评论作者（用于
                                                // "回复 @xxx" 前缀的精确切分，见 splitReplyPrefix）
                                                text: panelRoot.formatCommentContent(modelData.content, modelData.emotes, true, modelData.jumpUrls,
                                                                                   parent.parent.parent.replyCandidates, panelRoot.atNamesOf(modelData))
                                                font: FluTextStyle.Body
                                                color: FluTheme.fontPrimaryColor
                                                textFormat: Text.RichText
                                                wrapMode: Text.Wrap
                                                Layout.fillWidth: true
                                                Layout.preferredWidth: 0
                                                Layout.topMargin: 8
                                                verticalAlignment: Text.AlignTop
                                                onLinkActivated: function(link) {
                                                    if (link.indexOf("video:") === 0) {
                                                        panelRoot.openVideoFromComment(link.substring("video:".length))
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
                                                        var count = panelRoot.commentPicCount(pics)
                                                        return count
                                                    }

                                                    Rectangle {
                                                        id: replyImageContainer
                                                        property var pic: panelRoot.commentPicAt(modelData.pictures, index)
                                                        property int imageSize: panelRoot.calcCommentGridImageSize(commentItemLayout.width - 48)
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
                                                                source: GlobalState.fixImageUrl(panelRoot.getCommentImageThumbnailUrl(replyImageContainer.pic.imgSrc, replyImageContainer.imageSize, false))
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
                                                                source: GlobalState.fixImageUrl(panelRoot.getCommentImageThumbnailUrl(replyImageContainer.pic.imgSrc, replyImageContainer.imageSize, true))
                                                                fillMode: replyImageContainer.picIsSmallerThanContainer ? Image.PreserveAspectFit : Image.PreserveAspectCrop
                                                                cache: true
                                                                smooth: true
                                                                playing: true
                                                            }
                                                        }

                                                        MouseArea {
                                                            anchors.fill: parent
                                                            // z:-1 垫底：让 FluImage 加载失败时的 Reload 按钮可点击
                                                            z: -1
                                                            cursorShape: Qt.PointingHandCursor
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
                    text: panelRoot.commentModel && panelRoot.commentModel.count === 0 ? "暂无评论" : "正在加载评论..."
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
                onClicked: { panelRoot.replyToUser = "" }
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
                    panelRoot.replyToUser = ""
                    panelRoot.replyRpid = ""
                    panelRoot.replyRootRpid = ""
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

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: (mouse) => {
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