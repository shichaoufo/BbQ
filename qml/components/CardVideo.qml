import QtQuick 2.15
import QtQuick.Controls 2.15

import FluentUI 1.0
import BiliQt 1.0

// ===== 视频播放牌（类型 video）=====
//
// 窗口级唯一实例。以前 HomePage / DynamicPage / HistoryPage / SearchResultPage
// 各自内联了一份同样的 videoOverlay（约 250 行 × 4 份），谁在最上面要靠
// pushHost/_overlayZSeq/requestClosePagesOfType 三套机制凑；现在只留这一份，
// 叠放顺序由 GlobalState 的牌堆决定。
//
// 对外只用四个函数：
//   open(req)   打开或就地换内容（req = {bvid,title,isBangumi,epId,seasonId}）
//   close()     关闭并出栈
//   raiseZ()    由 CardLayer 在牌堆变化时调用，保证 z 与顺序一致
//   covered     只读：被别的牌压住时为 true（只暂停，不卸载）
Item {
    id: card
    anchors.fill: parent
    // 原实现挂在 homeFrame 上（四周 5px 边框）内，保持同样的观感
    anchors.margins: 5
    z: 100

    opacity: 0
    visible: opacity > 0 || openAnim.running || closeAnim.running

    // 逻辑状态：不受 visible 抖动影响
    property bool opened: false
    property string bvid: ""
    property string videoTitle: ""
    property bool videoIsBangumi: false
    property string videoEpId: ""
    property string videoSeasonId: ""
    property bool _playerCreated: false

    // 被别的牌压住：暂停播放（可嵌套由 VideoPlayerPage 自己计数，这里只保证
    // 状态变化时只推/弹一次）
    readonly property bool covered: opened && GlobalState.topCard !== "video"
    property bool _coverPushed: false
    onCoveredChanged: {
        if (!playerLoader.item) { _coverPushed = false; return }
        if (covered && !_coverPushed) {
            _coverPushed = true
            playerLoader.item.pushCover()
        } else if (!covered && _coverPushed) {
            _coverPushed = false
            playerLoader.item.popCover()
        }
    }

    Component {
        id: playerComponent
        VideoPlayerPage {
            anchors.fill: parent
            bvid: card.bvid
            videoTitle: card.videoTitle
            isBangumi: card.videoIsBangumi
            epId: card.videoEpId
            seasonId: card.videoSeasonId
        }
    }

    Item {
        id: container
        anchors.fill: parent
        transform: Translate { id: translate; y: 0 }

        // 底层拦截鼠标，避免事件穿透到下面的页面/牌
        MouseArea {
            anchors.fill: parent
            z: -1
            enabled: playerLoader.active
            onClicked: { /* 仅消费事件 */ }
        }

        Loader {
            id: playerLoader
            anchors.fill: parent
            // 小窗模式守卫：进入小窗时 CardLayer.visible=false 会让本牌 visible
            // 从父级"流动"为 false，不守卫会立即卸载播放页（mpv 被终止 → 白屏无声）
            active: (card.visible || App.miniPlayerMode) && card._playerCreated
            sourceComponent: playerComponent
        }
    }

    // 退出动画（200ms）完成后再卸载实例，避免渲染线程仍持有 mpv 上下文时销毁
    Timer {
        id: playerDestroyTimer
        interval: 250
        repeat: false
        onTriggered: {
            if (!card.opened && !openAnim.running && !closeAnim.running) {
                card._playerCreated = false
            }
        }
    }

    // 换视频时暂存"下一个 bvid"
    property string _nextBvid: ""

    // 退出流程收尾：卸载旧实例 → 下一帧按新 bvid 重建 → 弹出
    Timer {
        id: rebuildTimer
        interval: 200
        repeat: false
        onTriggered: {
            // 动画可能已经跑完（或本次是静默关闭），这里统一把它停掉
            closeAnim.stop()
            if (!card.opened) return
            // 老方案的销毁：卸载实例，mpv 与画面纹理随之释放
            card._playerCreated = false
            card.bvid = card._nextBvid
            card._nextBvid = ""
            card.opacity = 0
            buildTimer.start()
        }
    }

    // 隔一帧再建新实例并弹出：给渲染线程一帧时间释放旧实例的 QSG 资源
    Timer {
        id: buildTimer
        interval: 16
        repeat: false
        onTriggered: {
            if (!card.opened) return
            openAnim.start()
            card._playerCreated = true
        }
    }

    // ===== 对外 API =====
    // req.bvid 必填。
    function open(req) {
        var nb = String(req.bvid || "")
        if (nb === "") return
        var nBangumi = req.isBangumi === true
        var nEp = String(req.epId || "")
        var nSeason = String(req.seasonId || "")

        // 抽牌叠顶：先把它放到最上面（此时屏幕上还什么都没变）
        var wasCovered = GlobalState.topCard !== "video"
        var zz = GlobalState.bringCardToFront("video")
        card.z = zz

        // 同一条内容已经在播：不重新加载；但如果它刚才是被别的牌压着的，
        // 这次"抽上来"仍然要播一次叠上去的动画（用户点的是同一个视频也一样）
        if (card.opened && card._playerCreated && card.bvid === nb
                && card.videoIsBangumi === nBangumi && card.videoEpId === nEp) {
            if (wasCovered) popIn()
            return
        }

        // 番剧标记必须先于 bvid 生效：VideoPlayerPage 的 loadData 在 bvid 变化时
        // 读 isBangumi，晚一拍就会走普通视频分支 → 黑屏
        card.videoIsBangumi = nBangumi
        card.videoEpId = nEp
        card.videoSeasonId = nSeason
        card.videoTitle = String(req.title || "")

        if (card.opened && card._playerCreated) {
            replaceContent(nb, wasCovered)
        } else {
            card.bvid = nb
            card.opened = true
            doOpen()
        }
    }

    function close() {
        GlobalState.removeCard("video")
        if (!card.opened) return
        card.opened = false
        rebuildTimer.stop()
        buildTimer.stop()
        doClose()
    }

    // ===== 动画 =====
    function doOpen() {
        playerDestroyTimer.stop()
        rebuildTimer.stop()
        buildTimer.stop()
        closeAnim.stop()
        _playerCreated = true
        openAnim.start()
    }

    // 把已经在屏幕上的牌再"叠"一次（内容不变，比如被别的牌压着时又点了同一个视频）
    function popIn() {
        openAnim.stop()
        closeAnim.stop()
        openAnim.start()
        card.opacity = 0
    }

    function doClose() {
        openAnim.stop()
        closeAnim.stop()
        if (playerLoader.item) playerLoader.item.stopPlayer()
        playerDestroyTimer.start()
        closeAnim.start()
    }

    // 同一张牌换视频 = 把当前这支**关掉**，再打开下一支（沿用旧的关闭方案：
    // stopPlayer → 退出动画 → 卸载实例 → 重建 → 弹出）。
    //
    // 区别只在要不要演退出动画：
    //   · 视频牌被别的牌压着（搜索页/用户主页在上）→ 用户根本看不见，
    //     不演退出动画，静默收掉后直接弹出新的；
    //   · 视频页面打开视频页面（牌就在最上面）→ 演退出动画，看完再把新的弹出来。
    // 不再动播放器内部（不加 videoHidden、不改 MpvObject 的可见性）：
    // 换内容一律走"卸载 → 重建"，新实例里不存在上一支视频的画面。
    function replaceContent(nb, wasCovered) {
        openAnim.stop()
        closeAnim.stop()
        playerDestroyTimer.stop()
        rebuildTimer.stop()
        buildTimer.stop()

        card._nextBvid = nb
        // 老方案：关闭前先停播（保存设置、上报旧视频进度）
        if (playerLoader.item) playerLoader.item.stopPlayer()

        if (wasCovered) {
            // 被压着：看不到，不做退出动画
            card.opacity = 0
            rebuildTimer.interval = 16
            rebuildTimer.start()
        } else {
            // 视频 → 视频：演退出动画（200ms），结束后再关闭并重建
            closeAnim.start()
            rebuildTimer.interval = 200
            rebuildTimer.start()
        }
    }

    ParallelAnimation {
        id: openAnim
        NumberAnimation {
            target: card
            property: "opacity"
            from: 0; to: 1; duration: 250
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: translate
            property: "y"
            from: card.height * 0.15; to: 0
            duration: 250
            easing.type: Easing.OutCubic
        }
    }

    ParallelAnimation {
        id: closeAnim
        NumberAnimation {
            target: card
            property: "opacity"
            from: 1; to: 0; duration: 200
            easing.type: Easing.InCubic
        }
        NumberAnimation {
            target: translate
            property: "y"
            from: 0; to: card.height * 0.15
            duration: 200
            easing.type: Easing.InCubic
        }
        onStopped: {
            if (!card.opened) card._playerCreated = false
        }
    }

}
