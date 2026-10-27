import QtQuick 2.15
import QtQuick.Controls 2.15

import FluentUI 1.0
import BiliQt 1.0

// ===== 用户主页牌（类型 user）=====
//
// 窗口级唯一实例，与 CardVideo 同一套动画/叠放规则。
// 打开来自 App.openUserProfile（评论区头像、播放页 UP 主、搜索结果用户等）。
Item {
    id: card
    anchors.fill: parent
    anchors.margins: 5
    z: 101

    opacity: 0
    visible: opacity > 0 || openAnim.running || closeAnim.running

    property bool opened: false
    property string profileMid: ""
    property string profileName: ""
    property string profileFace: ""
    property int profileVerify: -1
    property bool _profileCreated: false

    Component {
        id: profileComponent
        UserProfilePage {
            anchors.fill: parent
            mid: card.profileMid
            userName: card.profileName
            userFace: card.profileFace
            userVerify: card.profileVerify
        }
    }

    Item {
        id: container
        anchors.fill: parent
        transform: Translate { id: translate; y: 0 }

        MouseArea {
            anchors.fill: parent
            z: -1
            enabled: profileLoader.active
            onClicked: { /* 仅消费事件 */ }
        }

        Loader {
            id: profileLoader
            anchors.fill: parent
            active: (card.visible || App.miniPlayerMode) && card._profileCreated
            sourceComponent: profileComponent
        }
    }

    Timer {
        id: destroyTimer
        interval: 250
        repeat: false
        onTriggered: {
            if (!card.opened && !openAnim.running && !closeAnim.running) {
                card._profileCreated = false
            }
        }
    }

    // req = {mid, name, face, verify}
    function open(req) {
        var mid = String(req.mid || "")
        if (mid === "") return
        var zz = GlobalState.bringCardToFront("user")
        card.z = zz

        // 同一个人的主页已经开着：把牌叠到最上面就行，不重建
        if (card.opened && card.profileMid === mid) return

        card.profileMid = mid
        card.profileName = String(req.name || "")
        card.profileFace = String(req.face || "")
        card.profileVerify = req.verify === undefined ? -1 : req.verify
        card.opened = true
        destroyTimer.stop()
        closeAnim.stop()
        _profileCreated = true
        openAnim.start()
    }

    function close() {
        GlobalState.removeCard("user")
        if (!card.opened) return
        card.opened = false
        openAnim.stop()
        closeAnim.stop()
        destroyTimer.start()
        closeAnim.start()
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
    }
}
