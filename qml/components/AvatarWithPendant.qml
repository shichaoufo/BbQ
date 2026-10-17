import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Window 2.15
import FluentUI 1.0
import BiliQt 1.0

Item {
    id: root

    property string face: ""
    property string pendantImage: ""
    property string placeholderText: ""
    property int avatarSize: 32
    property real pendantScale: 1.5
    // 认证类型：-1=无, 0=个人认证(黄闪电), 1=机构认证(蓝闪电)
    property int verifyType: -1
    // 大会员（评论 member.vip.vipStatus==1 / 动态 user.vip.status==1 / card、space 接口 vip.status==1）
    property bool isVip: false
    // 藏品：数字藏品（NFT）头像用户（评论 face_nft_new；card/动态/space 接口 face_nft）
    property bool hasCollect: false

    width: root.avatarSize * root.pendantScale
    height: width

    function pendantImageUrl(url) {
        if (!url) return ""
        if (url.indexOf("//") === 0) url = "https:" + url
        // 剥离已有尺寸参数，按实际显示尺寸请求更高清的 PNG，保留透明通道
        var atIndex = url.indexOf("@")
        if (atIndex >= 0) url = url.substring(0, atIndex)
        var size = Math.round(root.avatarSize * root.pendantScale * Screen.devicePixelRatio)
        if (size <= 0) size = 150
        return url + "@" + size + "w_" + size + "h.png"
    }

    CircleAvatar {
        id: avatar
        anchors.centerIn: parent
        width: root.avatarSize
        height: root.avatarSize
        source: root.face
        placeholderText: root.placeholderText
    }

    // 头像框：居中覆盖在头像上，中心透明露出头像
    Image {
        anchors.centerIn: parent
        width: root.avatarSize * root.pendantScale
        height: width
        source: root.pendantImage ? root.pendantImageUrl(root.pendantImage) : ""
        fillMode: Image.PreserveAspectFit
        visible: root.pendantImage !== "" && status !== Image.Error
        asynchronous: true
        mipmap: true
        smooth: true
        antialiasing: true
        z: 1
    }

    // 认证闪电标（verify0.svg=黄/个人, verify1.svg=蓝/机构）
    // 锚定到头像（avatar）右下角，略微超出边缘
    Image {
        width: root.avatarSize * 0.4
        height: width
        anchors.right: avatar.right
        anchors.bottom: avatar.bottom
        anchors.rightMargin: -width * 0.15
        anchors.bottomMargin: -height * 0.15
        source: root.verifyType === 0 ? "qrc:/BiliQt/icons/level/verify0.svg"
              : root.verifyType === 1 ? "qrc:/BiliQt/icons/level/verify1.svg"
              : ""
        visible: root.verifyType === 0 || root.verifyType === 1
        fillMode: Image.PreserveAspectFit
        sourceSize: Qt.size(64, 64)
        asynchronous: true
        z: 2
    }

    // 大会员 / 藏品角标：仅在没有认证标时显示（优先级：认证 > 大会员 > 藏品）。
    // dahuiyuan.png = 大会员（粉圆“大”字）；cangpin.gif = 藏品（钻石，动图，故用 AnimatedImage）
    AnimatedImage {
        width: root.avatarSize * 0.4
        height: width
        anchors.right: avatar.right
        anchors.bottom: avatar.bottom
        anchors.rightMargin: -width * 0.15
        anchors.bottomMargin: -height * 0.15
        source: root.verifyType >= 0 ? ""
              : root.isVip ? "qrc:/BiliQt/icons/level/dahuiyuan.png"
              : root.hasCollect ? "qrc:/BiliQt/icons/level/cangpin.gif"
              : ""
        visible: source !== ""
        playing: visible
        fillMode: AnimatedImage.PreserveAspectFit
        sourceSize: Qt.size(64, 64)
        asynchronous: true
        z: 2
    }
}
