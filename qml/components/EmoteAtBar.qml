import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

import FluentUI 1.0
import BiliQt 1.0

// 输入框右侧的「表情 / @」按钮组 + 两个弹出面板
//
// 用法：
//   EmoteAtBar { targetInput: commentInput; emoteBusiness: "reply" }
//
// 面板结构与动态页转发弹窗、直播页表情面板保持一致：
//   · 分类栏 = Pivot 风格（主题色下划线横移动画 + 悬停变色）
//   · 表情格 = 悬停底色 + 300ms tooltip（72px 放大预览 + 表情名）
//   · @ 面板 = 昵称搜索（300ms 防抖）+ 悬停底色
//
// 表情插入的是触发词（[微笑]），@ 插入的是「@昵称 」，与 B 站网页一致：
// 评论里的 @ 就是纯文本，服务端按昵称关联。
Row {
    id: toolRoot
    spacing: 2

    // 目标输入框（TextField / TextArea 均可，靠 cursorPosition 决定插入点）
    property var targetInput: null
    // 表情包 business：评论用 reply、动态转发用 dynamic
    property string emoteBusiness: "reply"

    // 高度由两个按钮撑开（Row 的 implicitHeight 是只读的，不能赋值）

    // ===== 表情面板状态 =====
    property var emotePackages: []
    property var emoteList: []
    property string emoteFilter: ""
    property bool emotesLoaded: false
    property bool emoteFallbackTried: false
    property string emoteError: ""

    // ===== @ 面板状态 =====
    property var mentionList: []
    property bool mentionLoading: false

    // 插到光标处（插完把光标推到内容之后，继续输入不会覆盖）
    function insertAtCursor(str) {
        if (!targetInput) return
        var pos = targetInput.cursorPosition
        var text = targetInput.text
        targetInput.text = text.substring(0, pos) + str + text.substring(pos)
        targetInput.cursorPosition = pos + str.length
        targetInput.forceActiveFocus()
    }

    // ===== 表情 =====
    function loadEmotePanel() {
        if (emotesLoaded) return
        emoteError = ""
        InteractionManager.getEmotePanel(emoteBusiness)
    }

    // 只有真图片地址才当图渲染：颜文字包的 url 可能是空串，或者干脆是
    // 颜文字本身，当 Image.source 用会刷 "Cannot open: qrc:/.../( ﾟдﾟ)"。
    function isEmoteImageUrl(u) {
        if (!u) return false
        if (u.indexOf("data:image/") === 0) return true
        if (u.indexOf("//") === 0 || u.indexOf("http://") === 0 || u.indexOf("https://") === 0)
            return true
        return /\.(png|jpe?g|gif|webp|avif|bmp)(\?|#|$)/i.test(u)
    }

    function parseEmotePanel(data) {
        var packages = []
        var flat = []
        emoteError = ""
        try {
            var resp = JSON.parse(typeof data === "string" ? data : data.toString())
            var pkgs = (resp && resp.data && resp.data.packages) ? resp.data.packages : []
            for (var i = 0; i < pkgs.length; ++i) {
                var pkg = pkgs[i] || {}
                var arr = pkg.emotes || pkg.emote || []
                var pkgName = pkg.text || pkg.package_name || ("表情" + (i + 1))
                var list = []
                for (var j = 0; j < arr.length; ++j) {
                    var e = arr[j] || {}
                    var text = e.text || e.emoji || ""
                    var url = e.url || ""
                    if (url.indexOf("//") === 0) url = "https:" + url
                    if (!isEmoteImageUrl(url)) url = ""
                    if (text === "" && url === "") continue
                    if (text === "" && url !== "") text = "[表情]"
                    var item = { text: text, url: url, pkgName: pkgName }
                    list.push(item)
                    flat.push(item)
                }
                if (list.length > 0)
                    packages.push({ pkgName: pkgName, emoticons: list })
            }
        } catch (err) {
            console.warn("[EmoteAtBar] parse emote panel failed:", err)
        }
        emotePackages = packages
        emoteList = flat
        emotesLoaded = flat.length > 0
        if (packages.length > 0 && emoteFilter === "")
            emoteFilter = packages[0].pkgName
        // 该 business 拿不到包时兜底试一次 dynamic（两个 business 的包基本一致）
        if (!emotesLoaded && !emoteFallbackTried) {
            emoteFallbackTried = true
            InteractionManager.getEmotePanel(emoteBusiness === "reply" ? "dynamic" : "reply")
        }
    }

    function emoteItems() {
        if (emoteFilter === "") return emoteList
        var out = []
        for (var i = 0; i < emoteList.length; ++i) {
            if (emoteList[i].pkgName === emoteFilter) out.push(emoteList[i])
        }
        return out
    }

    // ===== @ =====
    function loadMention(keyword) {
        mentionLoading = true
        InteractionManager.getDynMention(keyword || "")
    }

    function parseMention(data) {
        mentionLoading = false
        var list = []
        try {
            var resp = JSON.parse(typeof data === "string" ? data : data.toString())
            var groups = (resp && resp.data && resp.data.groups) ? resp.data.groups : []
            for (var i = 0; i < groups.length; ++i) {
                var items = (groups[i] && groups[i].items) ? groups[i].items : []
                for (var j = 0; j < items.length; ++j) {
                    var u = items[j] || {}
                    var name = u.name || u.uname || ""
                    if (name === "") continue
                    list.push({ name: name,
                                uid: String(u.uid || u.mid || ""),
                                face: u.face || u.avatar || "" })
                }
            }
        } catch (err) {
            console.warn("[EmoteAtBar] parse mention failed:", err)
        }
        mentionList = list
    }

    // ===== 按钮 =====
    FluIconButton {
        id: emojiBtn
        iconSource: FluentIcons.Emoji2
        iconSize: 16
        verticalPadding: 6
        horizontalPadding: 6
        onClicked: {
            if (emojiPopup.opened) { emojiPopup.close(); return }
            loadEmotePanel()
            emojiPopup.open()
        }
    }

    FluIconButton {
        id: atBtn
        // FluentIcons 里没有 Mention/At，用 Contact（人像）代替
        iconSource: FluentIcons.Contact
        iconSize: 16
        verticalPadding: 6
        horizontalPadding: 6
        onClicked: {
            if (atPopup.opened) { atPopup.close(); return }
            loadMention("")
            atPopup.open()
        }
    }

    // ===== 表情面板 =====
    Popup {
        id: emojiPopup
        parent: emojiBtn
        // 右边缘与按钮右边缘对齐：工具条在页面右侧，往左展开才不会被窗口边界
        // 修正（被拉回来会让位置看起来"乱跳"）
        x: parent ? (parent.width - width) : 0
        y: -height - 8
        width: 340
        height: 300
        modal: false
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
        padding: 8
        background: Rectangle {
            radius: 6
            color: FluTheme.dark ? Qt.rgba(43/255, 43/255, 43/255, 1)
                                 : Qt.rgba(1, 1, 1, 1)
            border.width: 1
            border.color: FluTheme.dark ? Qt.rgba(58/255, 58/255, 58/255, 1)
                                        : Qt.rgba(226/255, 229/255, 234/255, 1)
            FluShadow { radius: 6 }
        }

        contentItem: ColumnLayout {
            spacing: 4

            // 分类栏（Pivot 风格）
            Item {
                id: tabContainer
                Layout.fillWidth: true
                Layout.preferredHeight: 34
                visible: toolRoot.emotePackages.length > 1

                property real indicatorX: 0
                property real indicatorW: 0
                property Item activeTabItem: null

                Rectangle {
                    height: 3
                    radius: 1.5
                    y: parent.height - 3
                    x: tabContainer.indicatorX
                    width: tabContainer.indicatorW
                    color: FluTheme.primaryColor
                    visible: tabContainer.activeTabItem !== null

                    Behavior on x {
                        NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
                    }
                    Behavior on width {
                        NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
                    }
                }

                ListView {
                    id: tabBar
                    anchors.fill: parent
                    orientation: ListView.Horizontal
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    spacing: 16
                    model: toolRoot.emotePackages
                    onContentXChanged: {
                        if (tabContainer.activeTabItem) {
                            var pos = tabContainer.activeTabItem.mapToItem(tabContainer, 0, 0)
                            tabContainer.indicatorX = pos.x
                            tabContainer.indicatorW = tabContainer.activeTabItem.width
                        }
                    }

                    delegate: Item {
                        id: tabItem
                        width: tabText.width
                        height: tabBar.height
                        property bool activeTab: modelData.pkgName === toolRoot.emoteFilter

                        function updateIndicator() {
                            if (!tabItem.activeTab) return
                            tabContainer.activeTabItem = tabItem
                            var pos = tabItem.mapToItem(tabContainer, 0, 0)
                            tabContainer.indicatorX = pos.x
                            tabContainer.indicatorW = tabItem.width
                        }

                        onActiveTabChanged: updateIndicator()
                        Component.onCompleted: updateIndicator()
                        Component.onDestruction: {
                            if (tabContainer.activeTabItem === tabItem)
                                tabContainer.activeTabItem = null
                        }

                        FluText {
                            id: tabText
                            anchors.centerIn: parent
                            text: modelData.pkgName
                            font: FluTextStyle.Body
                            color: {
                                if (tabItem.activeTab) return FluTheme.primaryColor
                                if (tabMouse.containsMouse) return FluTheme.fontPrimaryColor
                                return FluTheme.fontSecondaryColor
                            }
                        }

                        MouseArea {
                            id: tabMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: toolRoot.emoteFilter = modelData.pkgName
                        }
                    }
                }
            }

            // 表情网格
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                FluText {
                    anchors.centerIn: parent
                    visible: toolRoot.emoteList.length === 0
                    text: toolRoot.emoteError !== ""
                          ? "表情加载失败：" + toolRoot.emoteError
                          : (toolRoot.emoteFallbackTried ? "暂无可用表情" : "加载中…")
                    font: Theme.fontSmall
                    color: FluTheme.fontTertiaryColor
                }

                GridView {
                    id: emoteGrid
                    anchors.fill: parent
                    clip: true
                    visible: toolRoot.emoteList.length > 0
                    readonly property int columns: 7
                    cellWidth: Math.floor(width / columns)
                    cellHeight: 44
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: FluScrollBar {}
                    model: toolRoot.emoteItems()

                    delegate: Item {
                        width: emoteGrid.cellWidth
                        height: 44

                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: 2
                            radius: 4
                            color: cellMouse.containsMouse
                                   ? (FluTheme.dark ? "#40FFFFFF" : "#0F000000")
                                   : "transparent"
                        }

                        RetryImage {
                            anchors.centerIn: parent
                            width: 28
                            height: 28
                            visible: modelData.url !== ""
                            imageSource: modelData.url
                            asynchronous: true
                            cache: true
                            fillMode: Image.PreserveAspectFit
                        }

                        // 颜文字：没有图片地址，直接画文字
                        FluText {
                            anchors.centerIn: parent
                            visible: modelData.url === ""
                            width: parent.width - 8
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.Wrap
                            maximumLineCount: 2
                            elide: Text.ElideRight
                            font.pixelSize: 9
                            lineHeight: 0.95
                            color: FluTheme.fontSecondaryColor
                            text: modelData.text
                        }

                        MouseArea {
                            id: cellMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onContainsMouseChanged: {
                                if (containsMouse) {
                                    tipTimer.restart()
                                } else {
                                    tipTimer.stop()
                                    emoteTip.close()
                                }
                            }
                            onClicked: {
                                emoteTip.close()
                                toolRoot.insertAtCursor(modelData.text)
                                emojiPopup.close()
                            }
                        }

                        Timer {
                            id: tipTimer
                            interval: 300
                            onTriggered: {
                                if (cellMouse.containsMouse)
                                    emoteTip.open()
                            }
                        }

                        FluTooltip {
                            id: emoteTip
                            padding: 8
                            x: parent ? (parent.width - width) / 2 : 0
                            y: -height - 6

                            contentItem: ColumnLayout {
                                spacing: 4

                                RetryImage {
                                    Layout.alignment: Qt.AlignHCenter
                                    visible: modelData.url !== ""
                                    sourceSize.width: 144
                                    imageSource: modelData.url
                                    Layout.preferredWidth: 72
                                    Layout.preferredHeight: 72
                                    fillMode: Image.PreserveAspectFit
                                }

                                FluText {
                                    Layout.alignment: Qt.AlignHCenter
                                    visible: modelData.url === ""
                                    text: modelData.text
                                    font.pixelSize: 15
                                    color: FluTheme.fontPrimaryColor
                                }

                                FluText {
                                    Layout.alignment: Qt.AlignHCenter
                                    visible: modelData.url !== ""
                                    text: modelData.text
                                    font: FluTextStyle.Caption
                                    color: FluTheme.fontSecondaryColor
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ===== @ 面板 =====
    Popup {
        id: atPopup
        parent: atBtn
        x: parent ? (parent.width - width) : 0
        y: -height - 8
        width: 280
        height: 300
        modal: false
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
        padding: 8
        background: Rectangle {
            radius: 6
            color: FluTheme.dark ? Qt.rgba(43/255, 43/255, 43/255, 1)
                                 : Qt.rgba(1, 1, 1, 1)
            border.width: 1
            border.color: FluTheme.dark ? Qt.rgba(58/255, 58/255, 58/255, 1)
                                        : Qt.rgba(226/255, 229/255, 234/255, 1)
            FluShadow { radius: 6 }
        }

        contentItem: ColumnLayout {
            spacing: 6

            FluTextBox {
                id: atSearchBox
                Layout.fillWidth: true
                placeholderText: "搜索昵称"
                onTextChanged: atSearchTimer.restart()
            }

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                ListView {
                    anchors.fill: parent
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: FluScrollBar {}
                    model: toolRoot.mentionList

                    delegate: Item {
                        width: ListView.view.width
                        height: 36

                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: 2
                            radius: 4
                            color: mentionMouse.containsMouse
                                   ? (FluTheme.dark ? "#40FFFFFF" : "#0F000000")
                                   : "transparent"
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 4
                            anchors.rightMargin: 4
                            spacing: 8

                            CircleAvatar {
                                Layout.preferredWidth: 22
                                Layout.preferredHeight: 22
                                Layout.alignment: Qt.AlignVCenter
                                source: modelData.face
                                placeholderText: modelData.name
                            }
                            FluText {
                                Layout.fillWidth: true
                                text: modelData.name
                                font: Theme.fontSmall
                                elide: Text.ElideRight
                            }
                        }

                        MouseArea {
                            id: mentionMouse
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            hoverEnabled: true
                            onClicked: {
                                toolRoot.insertAtCursor("@" + modelData.name + " ")
                                atPopup.close()
                            }
                        }
                    }
                }

                FluText {
                    anchors.centerIn: parent
                    visible: toolRoot.mentionList.length === 0
                    text: toolRoot.mentionLoading ? "加载中…" : "没有可选的用户"
                    font: Theme.fontSmall
                    color: FluTheme.fontTertiaryColor
                }
            }
        }
    }

    Timer {
        id: atSearchTimer
        interval: 300
        onTriggered: toolRoot.loadMention(atSearchBox.text)
    }

    Connections {
        target: InteractionManager

        function onEmotePanelReady(data) {
            toolRoot.parseEmotePanel(data)
        }

        function onDynMentionReady(data) {
            toolRoot.parseMention(data)
        }

        function onActionFailed(action, error) {
            if (action === "dyn_emote") {
                toolRoot.emoteError = error
                toolRoot.emoteFallbackTried = true
            } else if (action === "dyn_mention") {
                toolRoot.mentionLoading = false
            }
        }
    }
}
