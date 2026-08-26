import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import QtQml.Models 2.15

import FluentUI 1.0
import BiliQt 1.0
import "./"

FluPage {
    id: live_page
    title: ""
    launchMode: FluPageType.SingleInstance

    property var areas: GlobalState.liveAreas
    property string currentArea: GlobalState.liveCurrentArea
    property string currentSubArea: GlobalState.liveCurrentSubArea
    property int currentParentAreaId: GlobalState.liveCurrentParentAreaId
    property int currentSubAreaId: GlobalState.liveCurrentSubAreaId
    property bool areasLoaded: GlobalState.liveAreasLoaded

    // 用于防止页面销毁/隐藏时把 Pivot 重置值写回 GlobalState
    property bool _pageReady: false
    property int _lastPivotIndex: 0

    function areaDisplayName() {
        if (currentSubArea !== "全部") return currentSubArea
        return currentArea
    }

    function switchArea(parentId, subId) {
        Api.setLiveArea(parentId, subId)
        Api.setLivePage(1)
        // 通过改变 currentArea/currentSubArea 触发 LiveRecommendPage 的 refresh
        // refresh 会自动根据 currentParentAreaId/currentAreaId 选择正确的 API
    }

    Component.onCompleted: {
        _pageReady = true
        _lastPivotIndex = GlobalState.livePivotIndex
        if (!GlobalState.liveAreasLoaded) {
            Api.getLiveAreaList()
        }
    }

    Component.onDestruction: {
        GlobalState.livePivotIndex = _lastPivotIndex
        // 离开直播页面时强制销毁播放器，释放 D3D11 资源
        playerDestroyTimer.stop()
        if (livePlayerLoader.item) {
            try { livePlayerLoader.item.stopPlayer() } catch (e) {}
        }
        liveOverlay._playerCreated = false
        // 断开弹幕 WebSocket，释放 SSL 资源
        try { sharedDanmakuManager.disconnectRoom() } catch (e) {}
    }

    onVisibleChanged: {
        // 切到其他导航页时保存当前 pivot 索引，并关闭直播播放器避免声音串扰
        if (!visible) {
            // 小窗模式：pageStack.visible=false 使 visible 从父级"流动"为 false
            //（Qt 语义：父项 visible 变化会直接改变全部子孙的 visible 值并触发
            //  visibleChanged），非真实切页，绝不能关闭直播播放器
            if (App.miniPlayerMode) return
            GlobalState.livePivotIndex = _lastPivotIndex
            if (liveOverlay.open) {
                closeLivePlayer()
            }
        }
    }

    function parseAreaList(data) {
        try {
            var dataStr = typeof data === "string" ? data : data.toString()
            var resp = JSON.parse(dataStr)
            if (resp.code !== 0 || !resp.data) {
                console.warn("[LivePage] area list API error, code:", resp.code)
                return
            }
            var newAreas = [
                { name: "全部", subs: [{ name: "全部", id: 0 }], parentId: 0, subId: 0 }
            ]
            var areaList = resp.data.list || resp.data || []
            for (var i = 0; i < areaList.length; i++) {
                var area = areaList[i]
                var areaName = area.name || area.title || ""
                var parentId = area.id || area.area_id || 0
                if (!areaName || parentId === 0) continue
                var subs = [{ name: "全部", id: 0 }]
                var subList = area.list || area.sub_list || area.area_list || area.children || []
                for (var j = 0; j < subList.length; j++) {
                    var sub = subList[j]
                    var subName = sub.name || sub.title || ""
                    var subId = sub.id || sub.area_id || sub.area_v2_id || 0
                    if (subName && subId > 0) {
                        subs.push({ name: subName, id: subId })
                    }
                }
                newAreas.push({
                    name: areaName,
                    parentId: parentId,
                    subs: subs
                })
            }
            if (newAreas.length > 1) {
                GlobalState.liveAreas = newAreas
                GlobalState.liveAreasLoaded = true
            }
        } catch (e) {
            console.warn("[LivePage] parse area list failed:", e)
        }
    }

    FluFrame {
        id: liveFrame
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
            currentIndex: GlobalState.livePivotIndex

            onCurrentIndexChanged: {
                if (live_page.visible && live_page._pageReady) {
                    live_page._lastPivotIndex = currentIndex
                    GlobalState.livePivotIndex = currentIndex
                }
            }

            FluPivotItem {
                title: "推荐"
                contentItem: Component {
                    LiveRecommendPage {
                        anchors.fill: parent
                        liveModel: GlobalState.liveRecommendModel
                        initialContentY: GlobalState.liveRecommendScrollY
                        currentArea: live_page.currentArea
                        currentSubArea: live_page.currentSubArea
                        currentParentAreaId: live_page.currentParentAreaId
                        currentAreaId: live_page.currentSubAreaId
                        onContentYChangedExternally: function(y) {
                            GlobalState.liveRecommendScrollY = y
                        }
                        onOpenLivePlayerRequested: function(roomId, title, streamer) {
                            live_page.openLivePlayer(roomId, title, streamer)
                        }
                    }
                }
            }

            FluPivotItem {
                title: "关注"
                contentItem: Component {
                    Loader {
                        active: pivot.currentIndex === 1
                        sourceComponent: Component {
                            LiveFollowingPage {
                                anchors.fill: parent
                                liveModel: GlobalState.liveFollowingModel
                                initialContentY: GlobalState.liveFollowingScrollY
                                onContentYChangedExternally: function(y) {
                                    GlobalState.liveFollowingScrollY = y
                                }
                                onOpenLivePlayerRequested: function(roomId, title, streamer) {
                                    live_page.openLivePlayer(roomId, title, streamer)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    FluButton {
        id: areaBtn
        z: 10
        x: liveFrame.x + liveFrame.width - width - 24
        y: liveFrame.y + liveFrame.padding + (40 - height) / 2
        text: live_page.areaDisplayName()
        visible: pivot.currentIndex === 0
        onClicked: {
            if (!areaMenu._menuBuilt) {
                areaMenu._menuBuilt = true
            }
            var pos = areaBtn.mapToItem(null, 0, areaBtn.height)
            areaMenu.x = pos.x
            areaMenu.y = pos.y
            areaMenu.open()
        }
    }

    FluMenu {
        id: areaMenu
        parent: Overlay.overlay
        width: 120
        // 首次点击按钮时才真正创建子菜单，避免页面切换时实例化大量菜单项
        property bool _menuBuilt: false

        Instantiator {
            model: areaMenu._menuBuilt ? live_page.areas : []
            delegate: FluMenu {
                property string areaName: modelData.name
                property int areaParentId: modelData.parentId || 0
                title: areaName
                width: 140
                // 限制子菜单最大高度，超出可滚动
                implicitHeight: Math.min(400, contentHeight + 16)

                FluMenuItem {
                    text: "全部"
                    onTriggered: {
                        // 先更新 ID 属性（触发防抖 Timer），再更新显示字符串
                        live_page.currentParentAreaId = areaParentId
                        live_page.currentSubAreaId = 0
                        live_page.currentArea = areaName
                        live_page.currentSubArea = "全部"
                        GlobalState.liveCurrentParentAreaId = areaParentId
                        GlobalState.liveCurrentSubAreaId = 0
                        GlobalState.liveCurrentArea = areaName
                        GlobalState.liveCurrentSubArea = "全部"
                        Api.setLiveArea(areaParentId, 0)
                        Api.setLivePage(1)
                    }
                }
                Repeater {
                    model: modelData.subs
                    FluMenuItem {
                        text: modelData.name || modelData
                        visible: index > 0
                        onTriggered: {
                            // 先更新 ID 属性（触发防抖 Timer），再更新显示字符串
                            live_page.currentParentAreaId = areaParentId
                            live_page.currentSubAreaId = modelData.id || 0
                            live_page.currentArea = areaName
                            live_page.currentSubArea = modelData.name || modelData
                            GlobalState.liveCurrentParentAreaId = areaParentId
                            GlobalState.liveCurrentSubAreaId = modelData.id || 0
                            GlobalState.liveCurrentArea = areaName
                            GlobalState.liveCurrentSubArea = modelData.name || modelData
                            Api.setLiveArea(areaParentId, modelData.id || 0)
                            Api.setLivePage(1)
                        }
                    }
                }
            }
            onObjectAdded: function(index, object) {
                areaMenu.addMenu(object)
            }
            onObjectRemoved: function(index, object) {
                areaMenu.removeMenu(object)
            }
        }
    }

    // 共享弹幕管理器：放在 LivePage 层级，不随 LivePlayerPage 销毁/重建。
    // 避免快速开关直播时频繁创建/销毁 QWebSocket（SSL 握手线程）导致卡死。
    // MpvObject 仍然按视频页策略销毁/重建，仅弹幕 WebSocket 连接持久存在。
    LiveDanmakuManager {
        id: sharedDanmakuManager
    }

    Rectangle {
        id: liveOverlay
        x: liveFrame.x + Theme.overlayMargin
        y: open ? liveFrame.y + Theme.overlayMargin : liveFrame.y + liveFrame.height
        width: liveFrame.width - Theme.overlayMargin * 2
        height: liveFrame.height - Theme.overlayMargin * 2
        z: 30
        color: "black"
        radius: Theme.radiusSmall
        antialiasing: true
        clip: true
        visible: opacity > 0 || open
        opacity: open ? 1 : 0

        property string roomId: ""
        property string streamTitle: ""
        property string streamer: ""
        property bool open: false
        property bool _playerCreated: false
        property string _pendingRoomId: ""  // 延迟到打开动画结束再设 roomId，避免动画期间加载流掉帧

        Component {
            id: livePlayerComponent
            LivePlayerPage {
                anchors.fill: parent
                roomId: liveOverlay.roomId
                streamTitle: liveOverlay.streamTitle
                streamer: liveOverlay.streamer
                danmakuManager: sharedDanmakuManager
                onCloseRequested: live_page.closeLivePlayer()
                onReloadRequested: live_page.reloadLivePlayer()
            }
        }

        Loader {
            id: livePlayerLoader
            anchors.fill: parent
            // 与视频播放页相同策略：active 同时依赖 visible 和 _playerCreated。
            // 关闭直播时 _playerCreated 在 playerDestroyTimer（250ms）后置 false，
            // 期间等退出动画完成再销毁 LivePlayerPage，避免渲染线程仍持有 mpv 上下文时销毁导致卡死。
            // 小窗模式守卫：进入小窗时 pageStack 隐藏使 liveOverlay.visible 从父级
            // "流动"为 false，若不守卫会立即卸载销毁直播页（白屏无声）
            active: (liveOverlay.visible || App.miniPlayerMode) && liveOverlay._playerCreated
            sourceComponent: livePlayerComponent
        }

        // 延迟卸载定时器：等退出动画完成后卸载实例，
        // 避免在渲染线程仍持有 mpv 上下文时销毁导致卡死/闪退。
        Timer {
            id: playerDestroyTimer
            interval: 250
            repeat: false
            onTriggered: {
                if (!liveOverlay.open) {
                    liveOverlay._playerCreated = false
                }
            }
        }

        // 打开动画结束（opacity 到达 1）时，才设 roomId 触发 loadStream。
        // 避免动画期间 D3D11 初始化 + 网络请求 + 解码导致动画掉帧。
        onOpacityChanged: {
            if (open && opacity >= 1.0 && _pendingRoomId !== "") {
                roomId = _pendingRoomId
                _pendingRoomId = ""
            }
        }

        Behavior on y {
            NumberAnimation {
                duration: Theme.animationNormal
                easing.type: Easing.OutCubic
            }
        }

        Behavior on opacity {
            NumberAnimation {
                duration: Theme.animationFast
                easing.type: Easing.OutCubic
            }
        }
    }

    function openLivePlayer(roomId, title, streamer) {
        playerDestroyTimer.stop()
        // 如果播放器实例仍存在且是不同房间，先停旧流再设新 roomId
        if (livePlayerLoader.item && liveOverlay.roomId !== roomId) {
            livePlayerLoader.item.stopPlayer()
        }
        liveOverlay._playerCreated = true
        liveOverlay.streamTitle = title
        liveOverlay.streamer = streamer
        // 记录切换前是否已完全打开（opacity=1），区分两种场景：
        // - 已打开时切换房间：无动画，立即设 roomId
        // - 首次打开/重开：延迟到打开动画结束再设 roomId，避免动画期间加载流掉帧
        var wasFullyOpen = liveOverlay.open && liveOverlay.opacity >= 1.0
        liveOverlay.open = true
        if (wasFullyOpen) {
            liveOverlay.roomId = roomId
        } else {
            liveOverlay._pendingRoomId = roomId
            // 快速"关闭再打开"场景：closeLivePlayer 设 open=false 触发 opacity 1→0 动画，
            // 但如果紧接着 openLivePlayer 设 open=true，且此时 opacity 仍在 1.0 附近，
            // onOpacityChanged 的 opacity>=1.0 条件可能不再触发（值未变化）。
            // 这种情况下直接设 roomId，避免 _pendingRoomId 永远不被应用 → 黑屏不加载。
            if (liveOverlay.opacity >= 1.0) {
                liveOverlay.roomId = roomId
                liveOverlay._pendingRoomId = ""
            }
        }
    }

    function closeLivePlayer() {
        liveOverlay.open = false
        if (livePlayerLoader.item) {
            livePlayerLoader.item.stopPlayer()
        }
        // 清空 roomId：与视频播放页相同的销毁策略，Loader 会在动画结束后销毁 LivePlayerPage。
        // 清空 roomId 确保下次重建时 LivePlayerPage 以 roomId="" 初始化，
        // 不会因旧 roomId 触发 onRoomIdChanged → loadStream() 加载旧房间。
        liveOverlay.roomId = ""
        playerDestroyTimer.start()
    }

    function reloadLivePlayer() {
    }

    Connections {
        target: Api
        function onLiveAreaListReceived(data) {
            live_page.parseAreaList(data)
        }
    }
}
