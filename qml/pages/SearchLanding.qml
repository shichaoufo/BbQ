import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

import FluentUI 1.0
import BiliQt 1.0

// 搜索初始页（搜索落地页）
//
// 结构参考 PiliPlus：
//   · 顶部一个搜索框（回车 / 点「搜索」进入结果页）
//   · 左列：大家都在搜（2 列）、搜索发现（2 列），各带「刷新」
//   · 右列：搜索历史（胶囊标签），带「清空」
//
// 数据来源：
//   · 热词：/x/web-interface/search/square（Api.getSearchSquare）
//     前 12 条给「大家都在搜」，其余给「搜索发现」
//     —— B站没有公开的独立「搜索发现」接口（search/discover、wbi/search/discover、
//        v2/search/recommend、App 端 search/square 全是 404/-400），
//        这里用同一榜单的后半段，内容是真热词，不是占位假数据。
//   · 历史：GlobalState 单例统一管理（本地 QSettings，key = search/history，
//     JSON 数组）。落地页 / 搜索结果页 / 任意导航页呼出的搜索都写入同一份数据
FluPage {
    id: page
    title: ""

    // 热词：[{ word, label, icon }]
    property var hotWords: []
    property var discoverWords: []
    // 历史：字符串数组（最新在前）。直接绑定全局单例 —— 结果页里搜的词也会
    // 立刻反映在这里，不用等本页重新创建 / 重新 loadHistory()。
    property var history: GlobalState.searchHistory

    // 结果页盖着时关掉联想请求，避免和结果页抢 Api 的联想信号
    property bool suggestEnabled: true

    // ===== 联想词（与结果页同一套机制）=====
    // 关键点：FluAutoSuggestBox 的 list_view.model 只在 showSuggest() 里重新过滤赋值，
    // 光把 items 绑定成异步结果不会刷新下拉，必须等结果回来后手动 showSuggest()。
    property var _suggestWords: []
    property int _pendingSuggestSeq: 0
    property int _suggestLastRenderedSeq: 0

    signal searchRequested(string keyword)

    // ================= 数据 =================
    function loadSquare() {
        Api.getSearchSquare(24)
    }

    function _applySquare(data) {
        var arr = []
        try {
            var s = (typeof data === "string") ? data : data.toString()
            if (s && s.length > 2) {
                var root = JSON.parse(s)
                var list = (root.data && root.data.trending && root.data.trending.list) || []
                for (var i = 0; i < list.length; i++) {
                    var it = list[i] || {}
                    var w = String(it.keyword || it.show_name || "")
                    if (w === "") continue
                    arr.push({
                        word: w,
                        label: String(it.show_name || w),
                        icon: String(it.icon || "")
                    })
                }
            }
        } catch (e) {
            console.warn("[SearchLanding] parse square failed:", e)
        }
        page.hotWords = arr.slice(0, 12)
        page.discoverWords = arr.slice(12, 24)
    }

    // 历史读写全部委托给 GlobalState，本页不再自己碰 QSettings —— 否则
    // 结果页写入的新词会被本页的旧内存缓存覆盖掉。
    function loadHistory() { GlobalState.loadSearchHistory() }
    function addHistory(kw) { GlobalState.addSearchHistory(kw) }
    function clearHistory() { GlobalState.clearSearchHistory() }
    // 右键单条删除（左键仍然是"用这个词搜索"）
    function removeHistory(kw) { GlobalState.removeSearchHistory(kw) }

    function submit(kw) {
        var w = String(kw || "").trim()
        if (w === "") return
        // 落地页自己记一次；searchRequested 最终走 GlobalState.openInAppSearch()，
        // 那里还会记一次。addSearchHistory 幂等（去重 + 已置顶不写盘），不会重复入库。
        page.addHistory(w)
        box.updateText(w)
        box.focus = false
        page.searchRequested(w)
    }

    // ===== 联想 =====
    function _requestSuggest() {
        if (!page.suggestEnabled) return
        var txt = box.text.trim()
        if (txt === "") {
            page._suggestWords = []
            return
        }
        page._pendingSuggestSeq += 1
        Api.getSearchSuggest(txt)
    }

    function _applySuggestWords(words) {
        if (!page.suggestEnabled) return
        // 忽略过期返回（先发的请求后到）
        if (page._suggestLastRenderedSeq > 0
                && page._pendingSuggestSeq < page._suggestLastRenderedSeq) {
            return
        }
        page._suggestLastRenderedSeq = page._pendingSuggestSeq
        page._suggestWords = words ? words : []
        if (box.text.trim() === "" || page._suggestWords.length === 0) return
        // 下一帧等 items 绑定刷新后再 showSuggest，否则下拉是空的
        Qt.callLater(function() {
            if (!page.suggestEnabled) return
            if (box.text.trim() === "") return
            box.showSuggest()
        })
    }

    Component.onCompleted: {
        page.loadHistory()
        page.loadSquare()
    }

    // 搜索框的 I 型光标走应用级 override（见搜索框处注释）。override cursor
    // 是全局的：本页隐藏/销毁时必须还原，否则指针会一直停在 I 型。
    onVisibleChanged: if (!visible) App.setTextInputCursor(false)
    Component.onDestruction: App.setTextInputCursor(false)

    Connections {
        target: Api
        function onSearchSquareReceived(data) {
            page._applySquare(data)
        }
        function onSearchSuggestReceived(words) {
            page._applySuggestWords(words)
        }
    }

    Timer {
        id: suggestDebounce
        interval: 300
        repeat: false
        onTriggered: page._requestSuggest()
    }

    // ================= 界面 =================
    // 外框与 HomePage / LivePage / DynamicPage 一致：
    // FluFrame + 相同的外边距与圆角（这就是"边框"）
    FluFrame {
        id: frame
        anchors.fill: parent
        anchors.leftMargin: Theme.homeFrameLeftMargin
        anchors.rightMargin: Theme.homeFrameRightMargin
        anchors.topMargin: Theme.homeFrameTopMargin
        anchors.bottomMargin: Theme.homeFrameBottomMargin
        radius: Theme.frameRadius

        Flickable {
            id: flick
            anchors.fill: parent
            anchors.margins: 16
            clip: true
            contentWidth: width
            contentHeight: content.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: FluScrollBar {}

            ColumnLayout {
                id: content
                width: flick.width
                spacing: 20

                // ---------- 顶部搜索框 ----------
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12

                    FluAutoSuggestBox {
                        id: box
                        Layout.fillWidth: true
                        placeholderText: qsTr("搜索视频、UP主、番剧、话题...")
                        iconSource: FluentIcons.Search
                        cleanEnabled: true
                        itemHeight: 40
                        itemRows: 10

                        // items 绑定：纯字符串 → { title: word }
                        items: (page._suggestWords || []).map(function(w) { return { title: w } })
                        textRole: "title"
                        // 后端已经过滤好了，前端不要再过滤
                        filter: function(item) { return true }
                        // 空列表时不显示 "No results found"
                        emptyText: qsTr("")

                        onTextChanged: suggestDebounce.restart()
                        onCommit: function(text) { page.submit(text) }
                        onItemClicked: function(data) {
                            if (data && data.title) page.submit(data.title)
                        }

                        // 工字形光标：走应用级 override（App.setTextInputCursor）。
                        // QML 常规写法在这里不生效：FluTextBox 自带的
                        // cursorShape=IBeam 的 MouseArea 与文本区是兄弟节点
                        //（Qt 的光标解析只沿父链走），HoverHandler.cursorShape
                        // 也压不过去。
                        //
                        // 这层 Item 只铺"文本区"（右边让出 rightPadding，即图标区），
                        // 鼠标移到清除 ✕ / 搜索图标上时收不到 hover，光标回到默认，
                        // 按钮自己的手型不受影响；Item 不接鼠标事件，点击照常。
                        Item {
                            anchors.left: parent.left
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            anchors.right: parent.right
                            anchors.rightMargin: parent.rightPadding

                            HoverHandler {
                                onHoveredChanged: App.setTextInputCursor(hovered)
                            }
                        }

                        // 右侧"图标"那一小条只显示箭头：图标是普通 FluIcon，
                        // 不设光标，光标会从下面的 TextInput 继承成 I 型。
                        // 不能用 MouseArea 盖（即便 NoButton 也会参与命中检测，
                        // 把清除 ✕ 的 hover / 悬停高亮抢掉）；只报告 hover，
                        // 光标走应用级 override。
                        Item {
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            anchors.right: parent.right
                            anchors.rightMargin: 4
                            width: parent.iconSource > 0 ? 24 : 0

                            HoverHandler {
                                onHoveredChanged: App.setUiArrowCursor(hovered)
                            }
                        }
                    }

                    FluButton {
                        text: qsTr("搜索")
                        Layout.alignment: Qt.AlignVCenter
                        onClicked: page.submit(box.text)
                    }
                }

                // ---------- 主区：左（热词 + 发现） / 右（历史） ----------
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 32

                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.preferredWidth: 620
                        spacing: 20

                        // 大家都在搜
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 10

                            RowLayout {
                                Layout.fillWidth: true
                                FluText {
                                    text: qsTr("大家都在搜")
                                    font.pointSize: 16
                                    font.weight: Font.DemiBold
                                }
                                Item { Layout.fillWidth: true }
                                Row {
                                    Layout.alignment: Qt.AlignVCenter
                                    spacing: 2
                                    FluIcon {
                                        anchors.verticalCenter: parent.verticalCenter
                                        iconSource: FluentIcons.Refresh
                                        iconSize: 12
                                        iconColor: FluTheme.primaryColor
                                    }
                                    FluTextButton {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: qsTr("刷新")
                                        onClicked: page.loadSquare()
                                    }
                                }
                            }

                            Grid {
                                id: hotGrid
                                Layout.fillWidth: true
                                Layout.preferredHeight: implicitHeight
                                columns: 2
                                columnSpacing: 24
                                rowSpacing: 12
                                property real cellW: Math.max(80, (width - columnSpacing) / 2)

                                Repeater {
                                    model: page.hotWords
                                    delegate: Item {
                                        width: hotGrid.cellW
                                        height: 30
                                        Row {
                                            anchors.verticalCenter: parent.verticalCenter
                                            spacing: 6
                                            FluText {
                                                text: modelData.label
                                                font: Theme.fontNormal
                                                color: FluTheme.fontPrimaryColor
                                                elide: Text.ElideRight
                                                // 右侧为放大后的徽章留位：徽章最大约 30px + 6px 间距
                                                width: Math.min(implicitWidth, parent.parent.width - 40)
                                            }
                                            Image {
                                                id: hotBadge
                                                // 徽章是 B 站下发的 PNG（新/梗/热…），保持原始宽高比：
                                                // 只锁高度，宽度按加载后的实际比例推出来，避免拉伸变形。
                                                height: 18
                                                width: (implicitWidth > 0 && implicitHeight > 0)
                                                       ? Math.round(height * implicitWidth / implicitHeight)
                                                       : 30
                                                anchors.verticalCenter: parent.verticalCenter
                                                source: modelData.icon ? modelData.icon : ""
                                                visible: source != "" && status === Image.Ready
                                                fillMode: Image.PreserveAspectFit
                                                asynchronous: true
                                            }
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: page.submit(modelData.word)
                                        }
                                    }
                                }
                            }

                            FluText {
                                visible: page.hotWords.length === 0
                                text: qsTr("加载中…")
                                font: Theme.fontSmall
                                color: FluTheme.fontTertiaryColor
                            }
                        }

                        // 搜索发现
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            visible: page.discoverWords.length > 0

                            RowLayout {
                                Layout.fillWidth: true
                                FluText {
                                    text: qsTr("搜索发现")
                                    font.pointSize: 16
                                    font.weight: Font.DemiBold
                                }
                                Item { Layout.fillWidth: true }
                                Row {
                                    Layout.alignment: Qt.AlignVCenter
                                    spacing: 2
                                    FluIcon {
                                        anchors.verticalCenter: parent.verticalCenter
                                        iconSource: FluentIcons.Refresh
                                        iconSize: 12
                                        iconColor: FluTheme.primaryColor
                                    }
                                    FluTextButton {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: qsTr("刷新")
                                        onClicked: page.loadSquare()
                                    }
                                }
                            }

                            Grid {
                                id: discGrid
                                Layout.fillWidth: true
                                Layout.preferredHeight: implicitHeight
                                columns: 2
                                columnSpacing: 24
                                rowSpacing: 12
                                property real cellW: Math.max(80, (width - columnSpacing) / 2)

                                Repeater {
                                    model: page.discoverWords
                                    delegate: Item {
                                        width: discGrid.cellW
                                        height: 26
                                        FluText {
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: modelData.label
                                            font: Theme.fontNormal
                                            color: FluTheme.fontSecondaryColor
                                            elide: Text.ElideRight
                                            width: Math.min(implicitWidth, parent.width - 4)
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: page.submit(modelData.word)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ---------- 搜索历史 ----------
                    ColumnLayout {
                        Layout.preferredWidth: 380
                        Layout.alignment: Qt.AlignTop
                        spacing: 10

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            FluIcon {
                                iconSource: FluentIcons.History
                                iconSize: 16
                                iconColor: FluTheme.fontSecondaryColor
                            }
                            FluText {
                                text: qsTr("搜索历史")
                                font.pointSize: 16
                                font.weight: Font.DemiBold
                            }
                            Item { Layout.fillWidth: true }
                            FluIconButton {
                                iconSource: FluentIcons.Delete
                                iconSize: 15
                                visible: page.history.length > 0
                                onClicked: page.clearHistory()
                            }
                        }

                        FluText {
                            visible: page.history.length === 0
                            text: qsTr("还没有搜索记录")
                            font: Theme.fontSmall
                            color: FluTheme.fontTertiaryColor
                        }

                        Flow {
                            Layout.fillWidth: true
                            Layout.preferredHeight: implicitHeight
                            spacing: 10

                            Repeater {
                                model: page.history
                                delegate: Rectangle {
                                    height: 32
                                    width: Math.min(300, histLabel.implicitWidth + 24)
                                    radius: 6
                                    color: histMa.containsMouse ? FluTheme.itemHoverColor
                                                                : FluTheme.frameColor

                                    FluText {
                                        id: histLabel
                                        anchors.centerIn: parent
                                        text: modelData
                                        font: Theme.fontNormal
                                        color: FluTheme.fontPrimaryColor
                                        elide: Text.ElideRight
                                        width: Math.min(implicitWidth, parent.width - 24)
                                    }

                                    MouseArea {
                                        id: histMa
                                        anchors.fill: parent
                                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: function(mouse) {
                                            // 左键：用这个词搜索；右键：删掉这一条
                                            if (mouse.button === Qt.RightButton)
                                                page.removeHistory(modelData)
                                            else
                                                page.submit(modelData)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Item { Layout.fillHeight: true }
            }
        }
    }
}
