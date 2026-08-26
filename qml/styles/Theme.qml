pragma Singleton
import QtQuick 2.15

QtObject {
    readonly property color primary: "#FB7299"
    readonly property color primaryDark: "#E95C7D"
    readonly property color primaryLight: "#FFA2B6"

    readonly property color background: "#FFFFFF"
    readonly property color backgroundDark: "#F4F5F7"
    readonly property color surface: "#FFFFFF"
    readonly property color surfaceVariant: "#F0F1F3"

    readonly property color textPrimary: "#18191C"
    readonly property color textSecondary: "#61666D"
    readonly property color textTertiary: "#9499A0"
    readonly property color textInverse: "#FFFFFF"

    readonly property color border: "#E3E5E7"
    readonly property color divider: "#F1F2F3"

    readonly property color success: "#52C41A"
    readonly property color warning: "#FAAD14"
    readonly property color error: "#FF4D4F"
    readonly property color info: "#1890FF"

    readonly property int radiusSmall: 4
    readonly property int radiusMedium: 8
    readonly property int radiusLarge: 12
    readonly property int radiusXLarge: 16

    readonly property int spacingTiny: 4
    readonly property int spacingSmall: 8
    readonly property int spacingMedium: 12
    readonly property int spacingLarge: 16
    readonly property int spacingXLarge: 24

    readonly property font fontTiny: Qt.font({ pointSize: 10 })
    readonly property font fontSmall: Qt.font({ pointSize: 12 })
    readonly property font fontNormal: Qt.font({ pointSize: 14 })
    readonly property font fontMedium: Qt.font({ pointSize: 16, weight: Font.Medium })
    readonly property font fontLarge: Qt.font({ pointSize: 18, weight: Font.Medium })
    readonly property font fontTitle: Qt.font({ pointSize: 24, weight: Font.Bold })

    readonly property int navWidth: 72
    readonly property int navExpandedWidth: 240
    readonly property int headerHeight: 56
    readonly property int playerControlHeight: 48

    readonly property int iconSizeSmall: 16
    readonly property int iconSizeMedium: 20
    readonly property int iconSizeLarge: 24

    readonly property int liveControlBarHeight: 50

    // 视频/直播卡片
    readonly property int cardWidth: 260
    readonly property int cardInfoHeight: 90
    readonly property real cardAspectRatio: 9 / 16
    readonly property int cardRadius: 10
    readonly property int cardBorderWidth: 1
    readonly property color cardBorderColor: "#808080"
    readonly property int cardSpacing: 6
    readonly property int cardBadgeSpacing: 6
    readonly property int cardBadgeBottomMargin: 3
    readonly property int cardBadgeRadius: 4
    readonly property int cardBadgeWidth: 24
    readonly property int cardBadgeHeight: 16
    readonly property int cardBadgeIconSize: 13
    readonly property int cardCoverPlaceholderIconSize: 36
    readonly property int cardLiveBadgeHeight: 18
    readonly property int cardLiveBadgeDotSize: 6

    // 页面布局
    readonly property int pageMargins: 16
    readonly property int pageVSpacing: 16
    readonly property int pageHSpacing: 10
    readonly property int pageSize: 24
    readonly property int scrollBarReserve: 12

    // 首页/播放器 overlay
    readonly property int overlayMargin: 1

    // 首页布局
    readonly property int homeFrameLeftMargin: 5
    readonly property int homeFrameRightMargin: 5
    readonly property int homeFrameBottomMargin: 5
    readonly property int homeFrameTopMargin: 5
    readonly property int homeFramePadding: 10
    readonly property int pivotLeftMargin: 20

    // 视频播放页
    readonly property int playerRightPanelWidth: 360

    readonly property int animationFast: 150
    readonly property int animationNormal: 250
    readonly property int animationSlow: 400

    readonly property string easing: "Cubic.Out"
}
