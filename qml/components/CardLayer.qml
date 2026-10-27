import QtQuick 2.15
import QtQuick.Controls 2.15

import FluentUI 1.0
import BiliQt 1.0

// ===== 弹层牌堆宿主（窗口级）=====
//
// 所有会"叠"的页面都在这里，每种类型只有一个实例：
//   video  → CardVideo   用户从任何列表/搜索结果/动态/历史点开的视频
//   user   → CardUser    用户主页
//   search → CardSearch  搜索结果页（含评论区关键词/标签/话题跳转）
//
// 为什么必须放在窗口层：搜索结果牌要能**压在视频牌下面**（在视频里点标签
// 搜索 → 关掉搜索回到视频），而视频牌也要能压在搜索牌上面（搜索结果里点视频）。
// 只要两者不在同一个父级里，这个相对顺序就没法表达 —— 以前用"搜索层 z=300
// 永远在最上"凑，才会出现两层搜索实例那种补丁。
//
// 叠放顺序由 GlobalState._cardStack 唯一决定；本文件只负责把 App 的打开/关闭
// 请求翻译成"开牌/关牌"，不再有任何页面自己维护 visible/z/host 栈。
Item {
    id: layer
    anchors.fill: parent
    z: 250
    // 小窗播放时主窗口变身成小窗，牌面随常规 UI 一并隐藏
    //（牌内部 Loader 有 App.miniPlayerMode 守卫，不会因此卸载播放器）
    visible: !App.miniPlayerMode

    readonly property bool anyCard: GlobalState._cardStack.length > 0

    // 有牌时吃掉滚轮，防止滚轮穿透到下面的页面。
    // z:0 在牌下面；牌自己不透明且铺满，正常不会落到这里。
    MouseArea {
        anchors.fill: parent
        z: 0
        enabled: layer.anyCard
        acceptedButtons: Qt.NoButton
        hoverEnabled: true
        onWheel: function(wheel) { wheel.accepted = true }
    }

    CardVideo { id: videoCard }
    CardUser { id: userCard }
    CardSearch { id: searchCard }

    // ===== 统一入口（页面只发意图，不碰叠放状态）=====
    function openVideo(bvid, title) {
        videoCard.open({ bvid: bvid, title: title })
    }

    function openBangumi(bvid, epId, seasonId, title) {
        // 番剧没有真实 bvid 时用 bangumi_<epId|seasonId> 占位（与旧实现一致）
        var b = String(bvid || "")
        if (b === "" || b.indexOf("bangumi_") === 0) b = "bangumi_" + (epId || seasonId)
        videoCard.open({
            bvid: b,
            title: title,
            isBangumi: true,
            epId: epId,
            seasonId: seasonId
        })
    }

    function openUser(mid, name, face, verify) {
        userCard.open({ mid: mid, name: name, face: face, verify: verify })
    }

    function openSearch(keyword) {
        searchCard.open(keyword)
    }

    // 一次性收掉所有牌（切导航栏等场景）：从最上面一张开始收
    function closeAll() {
        if (searchCard.opened) searchCard.close()
        if (userCard.opened) userCard.close()
        if (videoCard.opened) videoCard.close()
        GlobalState.clearCards()
    }

    Connections {
        target: App
        function onVideoOpenRequested(bvid, title) {
            layer.openVideo(bvid, title)
        }
        function onBangumiOpenRequested(bvid, epId, seasonId, title) {
            layer.openBangumi(bvid, epId, seasonId, title)
        }
        function onVideoCloseRequested() {
            videoCard.close()
        }
        function onUserProfileOpenRequested(mid, name, face, verify) {
            layer.openUser(mid, name, face, verify)
        }
        function onUserProfileCloseRequested() {
            userCard.close()
        }
    }

    Connections {
        target: GlobalState
        // 应用内搜索：评论区关键词 / 动态标签 / 话题 / 播放页标签 / 搜索初始页提交
        function onInAppSearchRequested(keyword) {
            layer.openSearch(keyword)
        }
    }
}
