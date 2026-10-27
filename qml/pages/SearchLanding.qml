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
//   · 历史：本地 QSettings（key = search/history，JSON 数组）
FluPage {
    id: page
    title: ""

    // 热词：[{ word, label, icon }]
    property var hotWords: []
    property var discoverWords: []
    // 历史：字符串数组（最新在前）
    property var history: []

    // 结果页盖着时关掉联想请求，避免和结果页抢 Api 的联想信号
    property bool suggestEnabled: true

    // ===== 联想词（与结果页同一套机制）=====
    // 关键点：FluAutoSuggestBox 的 list_view.model 只在 showSuggest() 里重新过滤赋值，
    // 光把 items 绑定成异步结果不会刷新下拉，必须等结果回来后手动 showSuggest()。
    property var _suggestWords: []
    property int _pendingSuggestSeq: 0
    property int _suggestLastRenderedSeq: 0

    signal searchRequested(string keyword)

    readonly property string _histKey: "search/history"
    readonly property int _histMax: 20

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

    function loadHistory() {
        var arr = []
        try {
            var s = Settings.getString(page._histKey, "")
            if (s && s.length > 2) {
                var v = JSON.parse(s)
                if (Array.isArray(v)) arr = v
            }
        } catch (e) {}
        page.history = arr
    }

    function _saveHistory() {
        Settings.setString(page._histKey, JSON.stringify(page.history))
    }

    function addHistory(kw) {
        var w = String(kw || "").trim()
        if (w === "") return
        var arr = page.history ? page.history.slice(0) : []
        // 去重：同一个词只留最新一次
        for (var i = arr.length - 1; i >= 0; i--) {
            if (arr[i] === w) arr.splice(i, 1)
        }
        arr.unshift(w)
        if (arr.length > page._histMax) arr = arr.slice(0, page._histMax)
        page.history = arr
        page._saveHistory()
    }

    function clearHistory() {
        page.history = []
        page._saveHistory()
    }

    // 右键单条删除（左键仍然是"用这个词搜索"）
    function removeHistory(kw) {
        var w = String(kw || "")
        var arr = page.history ? page.history.slice(0) : []
        for (var i = arr.length - 1; i >= 0; i--) {
            if (arr[i] === w) arr.splice(i, 1)
        }
        page.history = arr
        page._saveHistory()
    }

    function submit(kw) {
        var w = String(kw || "").trim()
        if (w === "") return
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
