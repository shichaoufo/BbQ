import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

import FluentUI 1.0
import BiliQt 1.0
import "./"
import "../components"

FluPage {
    id: home_page
    title: ""
    launchMode: FluPageType.SingleInstance


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
            // 小窗模式：pageStack.visible=false 使 visible 从父级"流动"为 false，
            // 非真实切页，不能写回滚动位置
            if (App.miniPlayerMode) return
            GlobalState.homePivotIndex = _lastPivotIndex
        }
        // 弹层（视频/用户主页）不再由本页管理：切导航栏时 main.qml 统一收牌。
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


    function hotCategoryTitle() {
        switch (GlobalState.hotCurrentCategory) {
        case "all": return "综合热门"
        case "rank": return "排行榜"
        case "weekly": return "每周必看"
        case "history": return "入站必刷"
        }
        return "综合热门"
    }

}
