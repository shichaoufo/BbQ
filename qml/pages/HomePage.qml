import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

import FluentUI 1.0
import BiliQt 1.0
import "./"

FluPage {
    id: home_page
    title: ""
    launchMode: FluPageType.SingleInstance

    property bool videoVisible: false
    property bool userProfileVisible: false

    // 用于防止页面销毁/隐藏时把 Pivot 重置值写回 GlobalState
    property bool _pageReady: false
    property int _lastPivotIndex: 0

    Component.onCompleted: {
        _pageReady = true
        _lastPivotIndex = GlobalState.homePivotIndex
    }

    Component.onDestruction: {
        GlobalState.homePivotIndex = _lastPivotIndex
    }

    onVisibleChanged: {
        if (!visible) {
            // 小窗模式：pageStack.visible=false 使 visible 从父级"流动"为 false
            //（Qt 语义：父项 visible 变化会直接改变全部子孙的 visible 值并触发
            //  visibleChanged），非真实切页，绝不能关闭播放器
            if (App.miniPlayerMode) return
            GlobalState.homePivotIndex = _lastPivotIndex
            // 切到其他导航页时，如果视频播放器还开着，关闭并卸载实例，避免声音串扰
            if (videoVisible) {
                closeVideoPlayer()
            }
        }
    }

    FluFrame {
        id: homeFrame
        radius: Theme.frameRadius
        anchors.fill: parent
        anchors.leftMargin: Theme.homeFrameLeftMargin
        anchors.rightMargin: Theme.homeFrameRightMargin
        anchors.bottomMargin: Theme.homeFrameBottomMargin
        anchors.topMargin: Theme.homeFrameTopMargin
        padding: Theme.homeFramePadding

        FluPivot {
            id: pivot
            anchors.fill: parent
            anchors.leftMargin: Theme.pivotLeftMargin
            font.pixelSize: FluTextStyle.Title.pixelSize * 2 / 3
            currentIndex: GlobalState.homePivotIndex

            onCurrentIndexChanged: {
                if (home_page.visible && home_page._pageReady) {
                    home_page._lastPivotIndex = currentIndex
                    GlobalState.homePivotIndex = currentIndex
                }
            }

            FluPivotItem {
                title: "推荐"
                contentItem: Component {
                    RecommendPage {
                        anchors.fill: parent
                        videoModel: GlobalState.recommendModel
                        initialContentY: GlobalState.recommendScrollY
                        onContentYChangedExternally: function(y) {
                            GlobalState.recommendScrollY = y
                        }
                    }
                }
            }

            FluPivotItem {
                title: "热门"
                contentItem: Component {
                    HotPage {
                        anchors.fill: parent
                    }
                }
            }
        }
    }

    // 热门页右上角分类切换按钮，与直播页分区按钮对齐
    FluButton {
        id: hotCategoryBtn
        z: 10
        x: homeFrame.x + homeFrame.width - width - 24
        y: homeFrame.y + homeFrame.padding + (40 - height) / 2
        text: home_page.hotCategoryTitle()
        visible: pivot.currentIndex === 1
        onClicked: {
            var pos = hotCategoryBtn.mapToItem(null, 0, hotCategoryBtn.height)
            hotCategoryMenu.x = pos.x
            hotCategoryMenu.y = pos.y
            hotCategoryMenu.open()
        }
    }

    FluMenu {
        id: hotCategoryMenu
        parent: Overlay.overlay
        width: 140

        FluMenuItem {
            text: "综合热门"
            onTriggered: GlobalState.hotCurrentCategory = "all"
        }
        FluMenuItem {
            text: "排行榜"
            onTriggered: GlobalState.hotCurrentCategory = "rank"
        }
        FluMenuItem {
            text: "每周必看"
            onTriggered: GlobalState.hotCurrentCategory = "weekly"
        }
        FluMenuItem {
            text: "入站必刷"
            onTriggered: GlobalState.hotCurrentCategory = "history"
        }
    }

    // 视频播放页打开时，兜底拦截滚轮事件，防止其穿透到底层主页滚动视图。
    // 该 MouseArea 位于 homeFrame 之上、videoOverlay 之下，因此不会遮挡视频页交互。
    MouseArea {
        anchors.fill: homeFrame
        z: 99
        enabled: videoVisible || userProfileVisible
        acceptedButtons: Qt.NoButton
        hoverEnabled: true
        onWheel: function(wheel) { wheel.accepted = true }
    }

    Item {
        id: videoOverlay
        anchors.fill: homeFrame
        anchors.margins: Theme.playerOverlayMargin
        z: 103
        visible: opacity > 0 || openVideoAnim.running || closeVideoAnim.running || switchVideoSeqAnim.running
        opacity: 0

        property string videoBvid: ""
        property string videoTitleText: ""
        // 番剧/电影参数：openBangumiPlayer 赋值、VideoPlayerPage 绑定都依赖这三个属性。
        // 之前未声明 → 赋值时报 "Cannot assign to non-existent property" 并中断整个函数
        //（既废了 openBangumiPlayer，也废了后来在 openVideoPlayer 里清标记的逻辑）
        property bool videoIsBangumi: false
        property string videoEpId: ""
        property string videoSeasonId: ""
        property bool _playerCreated: false
        property string _pendingCloseBvid: ""
        property string _pendingSwitchBvid: ""
        property string _pendingSwitchTitle: ""

        Component {
            id: videoPlayerComponent
            VideoPlayerPage {
                anchors.fill: parent
                bvid: videoOverlay.videoBvid
                videoTitle: videoOverlay.videoTitleText
                // 关键修复：番剧/电影参数必须绑定传入。
                // 首次打开靠 App.bangumiOpenRequested 信号（页面可见时）能成功；
                // 关闭后重开时新实例 visible=false，信号被忽略，只能靠这里的绑定。
                // 缺失时 isBangumi 恒为 false → loadData 走普通视频分支 → 黑屏
                isBangumi: videoOverlay.videoIsBangumi
                epId: videoOverlay.videoEpId
                seasonId: videoOverlay.videoSeasonId
            }
        }

        // 使用内部容器做位移动画，避免与 anchors 冲突
        Item {
            id: videoContainer
            anchors.fill: parent
            transform: Translate {
                id: videoTranslate
                y: 0
            }

            // 底层拦截鼠标事件，防止穿透到底层视频卡片。
            // 仅在 Loader 实际加载了播放器时才启用，避免切换/关闭过程中
            // 空 overlay 挡住主页卡片交互。
            MouseArea {
                anchors.fill: parent
                z: -1
                enabled: videoPlayerLoader.active
                onClicked: { /* 仅消费事件，不执行任何操作 */ }
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

        // 延迟卸载定时器：等退出动画（200ms）完成后再卸载实例，
        // 避免在渲染线程仍持有 mpv 上下文时销毁导致卡死/闪退。
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

        // 延迟关闭定时器：切换视频时，等新视频完全显示后再清理旧资源
        Timer {
            id: closeDelayTimer
            interval: 300
            repeat: false
            onTriggered: {
                // 只有当 bvid 还是旧 bvid 时才关闭（防止用户在等待期间又切换了视频）
                if (videoOverlay.videoBvid === videoOverlay._pendingCloseBvid) {
                    videoOverlay._pendingCloseBvid = ""
                } else {
                    // 如果 bvid 已经改变，说明用户又切换了视频，清理 pendingCloseBvid
                    videoOverlay._pendingCloseBvid = ""
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

    Connections {
        target: App
        function onVideoOpenRequested(bvid, title) {
            // 非当前可见页面不响应，避免多实例同时打开视频造成卡顿
            if (!home_page.visible) return
            home_page.openVideoPlayer(bvid, title)
        }
        function onBangumiOpenRequested(bvid, epId, seasonId, title) {
            if (!home_page.visible) return
            home_page.openBangumiPlayer(bvid, epId, seasonId, title)
        }
        function onVideoCloseRequested() {
            home_page.closeVideoPlayer()
        }
    }

    // ===== 用户主页 Overlay（与 videoOverlay 相同动画模式） =====
    Item {
        id: userProfileOverlay
        anchors.fill: homeFrame
        anchors.margins: Theme.playerOverlayMargin
        z: 101
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
                // 守卫：切导航栏时 home_page.visible=false 会使 overlay 的
                // visible 从父级"流动"为 false，若不守卫会立即卸载销毁用户主
                // 页实例，切回导航时重新加载。userProfileVisible 是逻辑状态，
                // 不受父级隐藏影响（与 videoOverlay 的小窗守卫同一模式）
                active: (userProfileOverlay.visible || home_page.userProfileVisible) && userProfileOverlay._profileCreated
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

    function hotCategoryTitle() {
        switch (GlobalState.hotCurrentCategory) {
        case "all": return "综合热门"
        case "rank": return "排行榜"
        case "weekly": return "每周必看"
        case "history": return "入站必刷"
        }
        return "综合热门"
    }

    function openVideoPlayer(bvid, title) {

        // 同一视频已打开时直接忽略，避免重复加载
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
        videoOverlay._pendingCloseBvid = ""
        videoVisible = false
        videoOverlay.doClose()
    }

    function openUserProfile(mid, name, face, verify) {
        if (userProfileVisible && userProfileOverlay.profileMid === mid) return
        // 如果视频打开中，先关闭视频
        if (videoVisible) {
            closeVideoPlayer()
        }
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

    Connections {
        target: App
        function onUserProfileOpenRequested(mid, name, face, verify) {
            if (!home_page.visible) return
            home_page.openUserProfile(mid, name, face, verify)
        }
        function onUserProfileCloseRequested() {
            home_page.closeUserProfile()
        }
    }
}
