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
    // 弹出页 Frame 框线：与 FluFrame 同款 1px 分割线边框，主题自适应
    border.width: 1
    border.color: FluTheme.dividerColor

    // 内嵌 12px 内边距：让内容自然回退到搜索页圆角之内，不覆盖外层 Frame 圆角；
    // 也给 GridView 顶部留出富裕空间，避免第一行卡片 hover 上浮(-8px)时被裁剪
    readonly property int innerPad: 12

    // ===== 基本属性 =====
    property string mid: ""
    property string userName: ""
    property string userFace: ""
    property string userSign: ""
    property int userVerify: -1
    property string userFans: ""
    property string userAttention: ""
    property int vipType: 0
    property string pendantImage: ""
    property string level: ""
    property bool isFollowing: false

    // 实例复用换人场景（主页还开着时从视频页打开另一用户的主页）：
    // 已加载数据的 mid 与构造完成标记。Loader 实例不重建、仅 mid 绑定
    // 变化，onCompleted 不会再触发，由 onMidChanged 驱动重置与重载
    property string _loadedMid: ""
    property bool _completed: false

    // ===== 视频分页属性 =====
    property int videoPage: 1
    property int videoPageSize: 30
    property string videoOrder: "pubdate"  // pubdate=最新发布, click=最多播放
    property int videoTotal: 0
    property bool videoHasMore: true
    property bool videoLoading: false

    property ListModel videosModel: ListModel {}

    // ===== 动态卡片尺寸（与 RecommendPage 一致策略：列数固定，cellWidth 拉伸撑满）=====
    // cardWidth 为基准宽度用于计算列数，实际卡片宽度 displayCardWidth 会随窗口宽度变化
    readonly property int _cardWidth: Theme.cardWidth
    readonly property int _minHSpacing: Theme.pageHSpacing
    readonly property int _vSpacing: Theme.pageVSpacing
    readonly property int _columns: Math.max(1, Math.floor((videosGrid.width + _minHSpacing) / (_cardWidth + _minHSpacing)))
    readonly property real _cellWidth: _columns > 1 ? videosGrid.width / _columns : videosGrid.width
    readonly property real _displayCardWidth: Math.max(1, _cellWidth - _minHSpacing)

    FluInfoBar {
        id: pageInfoBar
        root: pageRoot
    }

    // 拦截滚轮事件，防止穿透到底层主页滚动
    MouseArea {
        anchors.fill: parent
        z: 0
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        onWheel: function(wheel) { wheel.accepted = true }
    }

    // ===== 顶部栏：左侧视频排序下拉框，右侧 UP主信息+关注按钮 =====
    // 整体与用户头像中心垂直对齐
    Item {
        id: headerBar
        z: 10
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: pageRoot.innerPad
        anchors.leftMargin: pageRoot.innerPad
        anchors.rightMargin: pageRoot.innerPad
        height: 40

        // 左侧：排序下拉框 —— 与右侧头像中心对齐
        FluComboBox {
            id: videoOrderCombo
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            width: 140
            model: ["最新发布", "最多播放"]
            currentIndex: pageRoot.videoOrder === "click" ? 1 : 0
            onCurrentIndexChanged: {
                var newOrder = currentIndex === 0 ? "pubdate" : "click"
                if (newOrder === pageRoot.videoOrder) return
                pageRoot.videoOrder = newOrder
                pageRoot.videoPage = 1
                pageRoot.videoHasMore = true
                pageRoot.videosModel.clear()
                loadVideos()
            }
        }

        // 右侧：用户头像 + 昵称 + 关注按钮（整体纵向中心对齐）
        Row {
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            spacing: 10

            AvatarWithPendant {
                id: headerAvatar
                avatarSize: 28
                face: pageRoot.userFace || ""
                pendantImage: pageRoot.pendantImage || ""
                verifyType: pageRoot.userVerify
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: pageRoot.userName || ""
                font.pixelSize: 14
                font.bold: true
                color: FluTheme.fontPrimaryColor
                maximumLineCount: 1
                elide: Text.ElideRight
                width: 120
            }

            FluButton {
                anchors.verticalCenter: parent.verticalCenter
                text: pageRoot.isFollowing ? "已关注" : "+ 关注"
                onClicked: {
                    if (pageRoot.mid === "") return
                    if (!Login.isLoggedIn) {
                        pageInfoBar.showWarning("请先登录")
                        return
                    }
                    InteractionManager.followUser(pageRoot.mid, pageRoot.isFollowing ? 2 : 1)
                    pageRoot.isFollowing = !pageRoot.isFollowing
                }
            }
        }
    }

    // ===== 视频卡片网格（顶部分隔线下直接开始）=====
    GridView {
        id: videosGrid
        anchors.top: headerBar.bottom
        anchors.topMargin: 20
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: pageRoot.innerPad
        anchors.rightMargin: pageRoot.innerPad
        anchors.bottomMargin: pageRoot.innerPad
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: FluScrollBar {}
        // 动态尺寸：cellWidth 撑满可用宽度，cellHeight 按卡片宽高比 + 信息区 + 纵向间距计算
        // vSpacing(16) 提供 hover 上浮(-8px) + 阴影(~15px) 的空间，不会被 clip 裁剪
        cellWidth: Math.max(1, pageRoot._cellWidth)
        cellHeight: Math.max(1, pageRoot._displayCardWidth * Theme.cardAspectRatio + Theme.cardInfoHeight + pageRoot._vSpacing)
        model: videosModel
        cacheBuffer: Math.max(0, height * 2)

        onContentYChanged: {
            if (!pageRoot.videoHasMore || pageRoot.videoLoading) return
            if (contentHeight > height && contentY + height >= contentHeight - height) {
                loadVideos(true)
            }
        }

        delegate: Item {
            width: Math.max(1, videosGrid.cellWidth)
            height: Math.max(1, videosGrid.cellHeight)
            VideoCard {
                // 左对齐 + 垂直居中，与 RecommendPage 一致
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                // 卡片宽度撑满 cell 减去滚动条预留，高度由 implicitHeight 自动计算
                width: Math.max(1, pageRoot._displayCardWidth - Theme.scrollBarReserve)
                bvid: model.bvid
                title: model.title
                cover: model.pic
                author: model.author
                views: model.play || ""
                danmakus: model.danmaku || ""
                duration: model.duration || ""
                pubDate: GlobalState.formatVideoCardTime(model.bvid_time || 0)
                isBangumiCard: false
            }
        }

        // 加载中提示
        BusyIndicator {
            visible: pageRoot.videoLoading && videosModel.count === 0
            width: 40
            height: 40
            anchors.centerIn: parent
            running: visible
        }

        // 空状态
        Item {
            visible: !pageRoot.videoLoading && videosModel.count === 0
            width: videosGrid.width
            height: 300
            anchors.centerIn: parent
            Column {
                anchors.centerIn: parent
                spacing: 12
                IconParkIcon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 64
                    height: 64
                    name: "video"
                    iconColor: FluTheme.fontTertiaryColor
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "没有视频"
                    font.pixelSize: 16
                    color: FluTheme.fontPrimaryColor
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "该UP主还没有投稿视频"
                    font.pixelSize: 12
                    color: FluTheme.fontTertiaryColor
                }
            }
        }

        // 加载更多提示
        Text {
            visible: !pageRoot.videoHasMore && videosModel.count > 0
            text: "—— 到底了 ——"
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: videosGrid.contentHeight + 10
            color: FluTheme.fontTertiaryColor
            font.pixelSize: 12
        }
    }

    // ===== 右键关闭 =====
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        onClicked: {
            closePage()
        }
    }

    // ===== 函数 =====
    function closePage() {
        if (pageRoot.parent && pageRoot.parent.parent && pageRoot.parent.parent.closeUserProfile) {
            pageRoot.parent.parent.closeUserProfile()
        } else {
            App.closeUserProfile()
        }
    }

    function loadUserInfo() {
        if (!pageRoot.mid || pageRoot.mid === "") return
        Api.getUserSpaceInfo(pageRoot.mid)
        // 获取关注状态（需登录）
        if (Login.isLoggedIn) {
            InteractionManager.getUserRelation(pageRoot.mid)
        }
    }

    function loadVideos(loadMore) {
        loadMore = loadMore || false
        if (!pageRoot.mid || pageRoot.mid === "") return
        if (!loadMore) {
            pageRoot.videoPage = 1
            pageRoot.videoHasMore = true
            pageRoot.videosModel.clear()
        }
        if (!pageRoot.videoHasMore) return
        pageRoot.videoLoading = true
        Api.getUserSpaceVideos(pageRoot.mid, pageRoot.videoPage, pageRoot.videoPageSize, pageRoot.videoOrder)
    }

    // ===== 实例复用换人：mid 变化时重置并重载 =====
    // _loadedMid 去重保证每个 mid 只加载一次（onCompleted 与 onMidChanged
    // 均调用本函数，构造期信号与完成回调不会重复触发加载）
    function ensureLoaded() {
        if (pageRoot.mid === "" || pageRoot._loadedMid === pageRoot.mid) return
        pageRoot._loadedMid = pageRoot.mid
        delayedLoadVideosTimer.stop()
        // 重置分页与排序（videoOrder 复位会联动排序下拉框，不触发请求）
        pageRoot.videoPage = 1
        pageRoot.videoHasMore = true
        pageRoot.videoLoading = false
        pageRoot.videoOrder = "pubdate"
        // 清掉上一用户由 API 返回的展示字段，避免换人瞬间闪现旧数据
        //（userName/userFace/userVerify 由父级绑定自动更新，无需清）
        pageRoot.userSign = ""
        pageRoot.userFans = ""
        pageRoot.userAttention = ""
        pageRoot.pendantImage = ""
        pageRoot.level = ""
        pageRoot.vipType = 0
        pageRoot.isFollowing = false
        pageRoot.videosModel.clear()
        videosGrid.contentY = 0
        loadUserInfo()
        delayedLoadVideosTimer.start()
    }

    // ===== Connections：用户信息 =====
    Connections {
        target: Api
        function onUserSpaceInfoReceived(data) {
            try {
                var obj = JSON.parse(data)
                if (obj.code !== 0) {
                    return
                }
                var d = obj.data || {}
                // 过期响应防御：换人后上一用户的信息响应才返回时丢弃
                //（space info 响应自带 data.mid）
                if (d.mid !== undefined && String(d.mid) !== String(pageRoot.mid)) return
                pageRoot.userName = d.name || ""
                pageRoot.userFace = d.face || ""
                pageRoot.userSign = d.sign || ""
                pageRoot.level = d.level ? String(d.level.current_level || 0) : ""
                pageRoot.vipType = d.vip ? (d.vip.type || 0) : 0

                if (d.pendant) {
                    pageRoot.pendantImage = d.pendant.image || d.pendant.img || ""
                }
                if (d.official) {
                    pageRoot.userVerify = (d.official.type !== undefined) ? Number(d.official.type) : -1
                }
                if (d.fans) pageRoot.userFans = formatCount(d.fans)
                if (d.attention !== undefined) pageRoot.userAttention = formatCount(d.attention)

            } catch (e) {
            }
        }

        // ===== Connections：用户视频列表 =====
        function onUserSpaceVideosReceived(data) {
            pageRoot.videoLoading = false
            try {
                var obj = JSON.parse(data)
                if (obj.code !== 0) {
                    pageRoot.videoHasMore = false
                    return
                }
                var d = obj.data || {}
                var list = d.list ? d.list.vlist : []
                // 过期响应防御：换人后上一用户的视频响应才返回时丢弃。
                // vlist 条目自带作者 mid；APP API（未登录）路径可能不含
                // mid（为 0/undefined），此时不拦截，保持原行为
                if (list.length > 0 && list[0].mid && String(list[0].mid) !== String(pageRoot.mid)) return
                var pageInfo = d.page || {}
                pageRoot.videoTotal = pageInfo.count || 0
                var totalPages = Math.ceil(pageRoot.videoTotal / pageRoot.videoPageSize)

                var added = 0
                for (var i = 0; i < list.length; i++) {
                    var v = list[i]
                    var item = {
                        bvid: v.bvid || "",
                        aid: v.aid || "",
                        title: v.title || "",
                        pic: v.pic || "",
                        play: formatCount(v.play || 0),
                        danmaku: formatCount(v.video_review || 0),
                        duration: formatDuration(v.length || 0),
                        author: v.author || "",
                        mid: v.mid || 0,
                        bvid_time: v.created || 0
                    }
                    videosModel.append(item)
                    added++
                }

                pageRoot.videoPage++
                // APP API（未登录）使用 has_next 判断分页，web API（已登录）使用 totalPages
                if (obj.has_next !== undefined) {
                    pageRoot.videoHasMore = obj.has_next === true && pageRoot.videoPage < 50
                } else {
                    pageRoot.videoHasMore = (pageRoot.videoPage <= totalPages && pageRoot.videoPage < 50)
                }
            } catch (e) {
                pageRoot.videoHasMore = false
            }
        }
        // 断网等网络错误时 Api 只发 errorOccurred 不发数据信号，
        // 不复位 videoLoading 会让加载更多的守卫永久卡死，且占位转圈常驻
        function onErrorOccurred(error) {
            console.warn("[UserProfilePage] API error:", error)
            if (!pageRoot.videoLoading) return
            pageRoot.videoLoading = false
            pageRoot.videoHasMore = false
        }
    }

    // 关注状态返回
    Connections {
        target: InteractionManager
        function onRelationReady(followed, attribute) {
            pageRoot.isFollowing = followed
        }
    }

    function formatCount(n) {
        if (!n) return "0"
        var num = Number(n)
        if (num >= 100000000) return (num / 100000000).toFixed(1) + "亿"
        if (num >= 10000) return (num / 10000).toFixed(1) + "万"
        return String(n)
    }

    function formatDuration(s) {
        // web API（已登录）的 vlist[].length 是 "MM:SS"/"H:MM:SS" 格式化字符串（分钟可能超 60，如 "75:30"），
        // APP API（未登录）的 length 已由 C++ 转为秒数；统一解析为秒数后按 HH:MM:SS / MM:SS 格式化
        var sec = 0
        if (typeof s === "string" && s.indexOf(":") !== -1) {
            var parts = s.split(":")
            for (var i = 0; i < parts.length && i < 3; i++)
                sec = sec * 60 + (parseInt(parts[i], 10) || 0)
        } else {
            sec = Number(s) || 0
        }
        var h = Math.floor(sec / 3600)
        var m = Math.floor((sec % 3600) / 60)
        var ss = sec % 60
        var hh = (h < 10 ? "0" : "") + h
        var mm = (m < 10 ? "0" : "") + m
        var sss = (ss < 10 ? "0" : "") + ss
        return h > 0 ? hh + ":" + mm + ":" + sss : mm + ":" + sss
    }

    // ===== 数据加载触发 =====
    // loadUserInfo 数据量小（仅更新头像/昵称/粉丝数），可立即执行。
    // loadVideos 返回后会向 videosModel 追加约 20 条数据，触发 GridView 批量创建
    // VideoCard delegate（含封面图加载/文本布局），开销集中在首帧。
    // 若与打开动画（250ms）同步执行，delegate 创建会抢占 GUI 线程导致动画掉帧。
    // 因此用 Timer 延迟到动画结束后再加载视频列表，保证弹出动画流畅。
    Timer {
        id: delayedLoadVideosTimer
        interval: 320  // 打开动画 250ms + 缓冲 70ms
        repeat: false
        onTriggered: {
            if (pageRoot.mid && pageRoot.mid !== "") {
                loadVideos()
            }
        }
    }

    Component.onCompleted: {
        pageRoot._completed = true
        ensureLoaded()
    }

    // 实例复用换人：mid 绑定变化时重置重载。构造期绑定求值也可能触发
    // 本信号，但此时组件未就绪，首次加载统一由 onCompleted 执行
    onMidChanged: {
        if (!pageRoot._completed) return
        ensureLoaded()
    }
}
