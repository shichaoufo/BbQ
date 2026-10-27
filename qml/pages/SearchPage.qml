import QtQuick 2.15
import QtQuick.Controls 2.15

import FluentUI 1.0
import BiliQt 1.0

// 搜索页容器（导航里的"搜索"入口）
//
// 结构（与 PiliPlus 一致）：
//   · 本页 = SearchLanding（搜索初始页：搜索框 / 大家都在搜 / 搜索发现 / 搜索历史）
//   · 搜索结果页**不在本页内**：它是窗口级牌堆里的 search 牌（见 components/CardSearch.qml）。
//     好处是"在搜索结果里打开视频 → 在视频里点标签再搜"时，搜索牌可以被抽到
//     视频牌上面，关掉后又回到视频 —— 如果结果页还留在本页内，它永远被视频盖住。
FluPage {
    id: searchPage
    title: ""

    SearchLanding {
        id: landing
        anchors.fill: parent
        // 搜索牌开着时不再请求联想，避免和结果页内的搜索框抢 Api 的联想信号
        suggestEnabled: !GlobalState.hasCard("search")
        onSearchRequested: function(keyword) {
            GlobalState.openInAppSearch(keyword)
        }
    }
}
