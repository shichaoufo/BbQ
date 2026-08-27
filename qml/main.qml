import QtQuick 2.15
import QtQuick.Window 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import QtQml 2.15
import QtQuick.Effects

import FluentUI 1.0
import BiliQt 1.0

import "./pages"
import "./components"

FluWindow {
    id: window
    title: "BbQ"
    windowIcon: "qrc:/BiliQt/res/app.ico"
    color: "black"
    flags: Qt.Window

    // 启动动画方案（替代此前的 opacity 淡入模拟）：FluWindow 默认在
    // Component.onCompleted 里立即 show()，窗口先以默认几何显示、再跳到
    // 保存的几何。现在改为 autoVisible: false 暂不显示，等几何恢复完成
    // 后由 geometryTimer 调 show()——Windows 系统原生的窗口打开动画
    // （与其他软件打开时相同的缩放+淡入）就会在最终位置尺寸上自然播放。
    // 副作用：几何在窗口隐藏期间调整，不产生任何可见跳变；且隐藏窗口
    // 不接收鼠标事件，高 DPI 启动竞态（见 geometryTimer 注释）进一步规避。
    // autoCenter 一并关闭：无保存几何时的居中由 applyWindowGeometry 负责。
    autoVisible: false
    autoCenter: false

    // 默认尺寸，按首页能完整显示 2 行 3 列视频卡片计算，
    // 在 Component.onCompleted 中会根据屏幕可用空间和 DPI 缩放进行限制
    // defaultWidth 需 ≥ minimumWidth(1120)，否则启动时会被钳制
    property int defaultWidth: 1136
    property int defaultHeight: 700

    width: defaultWidth
    height: defaultHeight
    // 搜索页视频搜索时，顶部栏 RowLayout 理论最小内容宽度约 922px，
    // 但 FluComboBox/FluAutoSuggestBox 的实际渲染宽度（含 padding/border/indicator）
    // 比 Layout.minimumWidth 大，实测 SearchPage 宽度 1016px 仍会截断搜索框。
    // 因此取 1120（SearchPage 可用 1070px），留足余量。
    minimumWidth: 1120
    minimumHeight: 640
    launchMode: FluWindowType.SingleTask
    fitsAppBarWindows: true
    property bool isChangingDark: false
    appBar: FluAppBar {
        id: app_bar
        height: 30
        showDark: true
        showMinimize: true
        showMaximize: true
        showClose: true
        showStayTop: true
        z:7
        // 小窗播放模式：主窗口自身变身为小窗，标题栏随常规 UI 一并隐藏
        visible: !App.miniPlayerMode
        darkClickListener:(button)=>handleDarkChanged(button)
        // 默认实现走 QML showMinimized()，最小化后窗口仍持有前台焦点，
        // 必须切走焦点才能通过任务栏图标还原；改走原生 WM_SYSCOMMAND 路径（同任务栏最小化）
        minClickListener: ()=>App.minimizeWindow(window)
    }

    // 小窗播放时关闭窗口（Alt+F4 / 系统关闭）：先退出小窗模式回常规界面，
    // 而不是退出应用（与旧独立小窗的 onClosing 拦截语义一致）
    closeListener: (event) => {
        if (App.miniPlayerMode) {
            App.exitMiniPlayerMode()
            event.accepted = false
            return
        }
        if (autoDestroy) {
            FluRouter.removeWindow(window)
        } else {
            window.visibility = Window.Hidden
            event.accepted = false
        }
    }

    function applyWindowGeometry() {
        // Screen.desktopAvailableWidth/Height 在 Qt 6 QML 中已经是设备无关像素（DIPs），
        // 无需再除以 devicePixelRatio。
        var availableW = Math.floor(Screen.desktopAvailableWidth)
        var availableH = Math.floor(Screen.desktopAvailableHeight)
        if (availableW <= 0 || availableH <= 0) {
            console.warn("[main] Screen desktop available size not ready yet:", availableW, availableH)
            return false
        }

        var geom = App.loadWindowGeometry()
        var savedW = geom.width || window.defaultWidth
        var savedH = geom.height || window.defaultHeight

        var targetW = Math.min(savedW, availableW)
        var targetH = Math.min(savedH, availableH)

        // 保存的尺寸不能小于窗口最小尺寸，否则搜索框等会被截断。
        // 将 target 钳制到 [minimum, available]，而不是降低 minimumWidth。
        targetW = Math.max(window.minimumWidth, targetW)
        targetH = Math.max(window.minimumHeight, targetH)

        window.width = targetW
        window.height = targetH

        var savedX = geom.x || 0
        var savedY = geom.y || 0
        if (savedX === 0 && savedY === 0) {
            window.x = Math.max(0, Math.floor((availableW - targetW) / 2))
            window.y = Math.max(0, Math.floor((availableH - targetH) / 2))
        } else {
            window.x = Math.max(0, Math.min(savedX, availableW - targetW))
            window.y = Math.max(0, Math.min(savedY, availableH - targetH))
        }
        return true
    }

    Component.onCompleted: {
        // 注册主窗口指针给 App（小窗模式窗口变身与系统原生移动用）
        App.registerMainWindow(window)
        // 注册小窗播放器宿主层（页面进入小窗时把播放器 reparent 到这里）
        App.miniPlayerHost = miniPlayerHost
        // 版本标记：小窗模式（单窗口变身）构建验证。若测试日志缺失此行，
        // 说明运行的是旧版 main.qml（文件未同步）
        console.warn("[MiniPlayer] host registered:", App.miniPlayerHost === miniPlayerHost)
        // 恢复上次关闭时的主题（首次运行默认白天）
        FluTheme.darkMode = App.loadTheme() ? FluThemeType.Dark : FluThemeType.Light
        // 主题按钮图标/文案与恢复后的主题同步
        app_bar.buttonDark.iconSource = FluTheme.dark ? FluentIcons.QuietHours : FluentIcons.Brightness
        app_bar.buttonDark.text = FluTheme.dark ? app_bar.darkText : app_bar.lightText
        // 启动流程（autoVisible: false，见上方注释）：本阶段窗口保持隐藏，
        // 由 geometryTimer 延迟 150ms 恢复保存的几何后再 show()——规避
        // 高 DPI 启动竞态（曾在 150% 缩放机器触发 Qt 6.9.3 hover 递归
        // 分发崩溃，见 BbQ_crash.log），且 show() 时系统原生打开动画在
        // 最终几何上播放，无默认尺寸→恢复尺寸的可见跳变。
        geometryTimer.start()
        // 弹幕驱动链自动测试（DANMAKU_AUTOTEST=1）：不依赖视频/交互，
        // 每 1.5s 发射一条滚动弹幕，配合 DANMAKU_DIAG=1 观察定时器链条是否持续
        if (App.environmentVariable("DANMAKU_AUTOTEST") === "1")
            danmakuAutoTestTimer.start()
    }

    Timer {
        id: geometryTimer
        interval: 150
        repeat: true
        // 启动流程：autoVisible:false 暂不显示窗口 → 本定时器恢复保存的
        // 几何（延迟 150ms 规避高 DPI 启动竞态：原先在 onCompleted 里同步
        // 恢复，窗口未显示、QML 场景树仍在构建，DIP 换算与几何变更、首个
        // hover 分发挤在同一窗口期，曾在 150% 缩放机器上触发 Qt 6.9.3
        // hover 递归分发崩溃，见 BbQ_crash.log）→ 几何落位后 show()，
        // Windows 原生窗口打开动画在最终几何上播放。
        // 重试：屏幕可用区域未就绪时 applyWindowGeometry 返回 false，
        // 上限约 10 次（1.5s），放弃后兜底 show()（以默认几何居中显示），
        // 绝不让窗口永远不显示。
        property int attempts: 0
        onTriggered: {
            attempts++
            if (applyWindowGeometry() || attempts >= 10) {
                stop()
                attempts = 0
                window.show()
            }
        }
    }

    Component.onDestruction: {
        App.saveWindowGeometry(window.x, window.y, window.width, window.height)
    }

    // 弹幕驱动链自动测试（DANMAKU_AUTOTEST=1）：不依赖视频/交互，
    // 每 1.5s 发射一条滚动弹幕，配合 DANMAKU_DIAG=1 观察定时器链条是否持续
    Timer {
        id: danmakuAutoTestTimer
        interval: 1500
        repeat: true
        onTriggered: {
            testCanvas.appendScroll("AUTOTEST 弹幕链诊断 " + Math.random(),
                                    "#FFFFFF", 20, 0.12, testCanvas.currentMs())
        }
    }
    DanmakuCanvas {
        id: testCanvas
        z: 3000
        anchors.fill: parent
        visible: danmakuAutoTestTimer.running
        trackHeight: 40
        baseFontSize: 24
    }

    FluNavigationView {
        property int clickCount: 0
        id: nav_view
        width: parent.width
        height: parent.height
        z: 1
        // 小窗播放模式：主窗口变身为小窗，导航栏隐藏
        visible: !App.miniPlayerMode
        pageMode: FluNavigationViewType.Stack
        topPadding: {
            if(window.useSystemAppBar){
                return 0
            }
            return FluTools.isMacos() ? 20 : 0
        }
        displayMode: FluNavigationViewType.Compact
        logo: ""
        title: ""

        items: FluObject {
            FluPaneItem {
                title: "视频"
                icon: FluentIcons.Media
                url: "home"
                onTap: {
                    pageStack.currentIndex = 0
                }
            }

            FluPaneItem {
                title: "直播"
                icon: FluentIcons.Video
                url: "live"
                onTap: {
                    pageStack.currentIndex = 1
                }
            }

            FluPaneItem {
                title: "动态"
                icon: FluentIcons.Bullseye
                url: "dynamic"
                onTap: {
                    pageStack.currentIndex = 2
                }
            }

            FluPaneItem {
                title: "搜索"
                icon: FluentIcons.Search
                url: "search"
                onTap: {
                    pageStack.currentIndex = 3
                }
            }
        }

        footerItems: FluObject {
            FluPaneItemSeparator{}

            FluPaneItem {
                title: "历史"
                icon: FluentIcons.History
                url: "history"
                onTap: {
                    pageStack.currentIndex = 4
                }
            }

        }

        Component.onCompleted: {
            window.setHitTestVisible(nav_view.buttonMenu)
            window.setHitTestVisible(nav_view.buttonBack)
            window.setHitTestVisible(nav_view.imageLogo)
            nav_view.buttonBack.visible = false
            nav_view.imageLogo.visible = false
            setCurrentIndex(0)
            pageStack.currentIndex = 0
        }
    }

    // 自定义页面容器：每个页面只创建一次，切导航时只是隐藏/显示，避免反复销毁重建。
    // 首页立即创建，其他页面首次切换到对应导航项时才创建。
    // 小窗播放模式：页面栈整体隐藏。注意 Qt 语义：父项 visible=false 会把
    // visible 值"流动"给全部子孙（子项 visible 变 false 且 visibleChanged 触发），
    // HomePage/LivePage 的 onVisibleChanged 关闭清理与 videoPlayerLoader/
    // livePlayerLoader 的 active 绑定均已加 App.miniPlayerMode 守卫，
    // 防止进小窗时误关闭播放器/误卸载播放页（白屏无声根因，2026-08-24）
    StackLayout {
        id: pageStack
        z: 2
        visible: !App.miniPlayerMode
        anchors.fill: parent
        anchors.topMargin: app_bar.height
        anchors.leftMargin: nav_view.navCompactWidth
        currentIndex: 0

        onCurrentIndexChanged: {
            // FluNavigationView 的 items 和 footerItems 分别由 nav_list 和 layout_footer 两个 ListView 管理。
            // nav_list 的 model 在 footer 区域是占位用的 FluPaneItemEmpty，不能直接 setCurrentIndex。
            // 这里手动同步两个 ListView 的 currentIndex 来实现高亮。
            if (!nav_view.nav_list || !nav_view.layout_footer) return
            if (currentIndex < 4) {
                nav_view.nav_list.currentIndex = currentIndex
                nav_view.layout_footer.currentIndex = -1
            } else {
                var footerIdx = currentIndex - 4 // 0=历史（separator 不计入）
                nav_view.layout_footer.currentIndex = footerIdx
                nav_view.nav_list.currentIndex = nav_view.nav_list.count - nav_view.layout_footer.count + footerIdx
            }
        }

        Loader {
            id: homeLoader
            property bool _wasLoaded: true
            active: true
            sourceComponent: Component { HomePage {} }
        }
        Loader {
            id: liveLoader
            property bool _wasLoaded: false
            active: pageStack.currentIndex === 1 || _wasLoaded
            onActiveChanged: if (active) _wasLoaded = true
            sourceComponent: Component { LivePage {} }
        }
        Loader {
            id: dynamicLoader
            property bool _wasLoaded: false
            active: pageStack.currentIndex === 2 || _wasLoaded
            onActiveChanged: if (active) _wasLoaded = true
            sourceComponent: Component { DynamicPage {} }
        }
        Loader {
            id: searchLoader
            property bool _wasLoaded: false
            active: pageStack.currentIndex === 3 || _wasLoaded
            onActiveChanged: if (active) _wasLoaded = true
            sourceComponent: Component { SearchPage {} }
        }
        Loader {
            id: historyLoader
            property bool _wasLoaded: false
            active: pageStack.currentIndex === 4 || _wasLoaded
            onActiveChanged: if (active) _wasLoaded = true
            sourceComponent: Component { HistoryPage {} }
        }
    }

    Item {
        id: userInfoBar
        z: 1000
        // 小窗播放模式：随导航栏一并隐藏
        visible: !App.miniPlayerMode
        height: 30
        width: avatarContainer.width + spacing + userNameText.implicitWidth
        y: nav_view.buttonMenu.y + (nav_view.buttonMenu.height - height) / 2
        x: (nav_view.navCompactWidth - avatarContainer.width) / 2

        property int spacing: 8

        Component.onCompleted: {
            window.setHitTestVisible(userInfoBar)
        }

        CircleAvatar {
            id: avatarContainer
            anchors.verticalCenter: parent.verticalCenter
            x: 0
            width: 22
            height: 22
            source: Login.isLoggedIn ? Login.userFace : ""
            placeholderText: ""

            FluIcon {
                anchors.centerIn: parent
                iconSource: FluentIcons.Contact
                iconSize: 12
                visible: !Login.isLoggedIn || Login.userFace === ""
                color: FluTheme.dark ? "#FFFFFF" : "#000000"
            }
        }

        FluText {
            id: userNameText
            anchors.verticalCenter: parent.verticalCenter
            x: avatarContainer.width + parent.spacing
            text: Login.isLoggedIn && Login.userName !== "" ? Login.userName : "未登录"
            font: FluTextStyle.Body
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                if (Login.isLoggedIn) {
                    logout_menu.popup(userInfoBar)
                } else {
                    login_popup.open()
                }
            }
        }
    }

    // ===== 小窗播放宿主层（单窗口变身方案）=====
    // 主窗口自身变身为小窗（App.enterMiniPlayerMode 调整几何/置顶/圆角），
    // 播放页进入小窗时把播放器与迷你控制层 reparent 到这里。
    // 同一窗口内的 reparent：无渲染上下文/场景图/视频链重建，
    // 对播放器只是一次尺寸变化，播放与弹幕完全不中断。
    // z 高于所有常规层（标题栏 7 / 页面栈 2 / 用户栏 1000）
    Item {
        id: miniPlayerHost
        z: 2000
        anchors.fill: parent
        visible: App.miniPlayerMode
    }

    // 预加载图标字体，避免某些页面里异步加载导致图标首次显示乱码
    FontLoader {
        id: fluentIconFontLoader
        source: "qrc:/qt/qml/FluentUI/Font/FluentIcons.ttf"
    }

    FontLoader {
        id: iconParkFontLoader
        source: "qrc:/BiliQt/qml/assets/iconpark.ttf"
    }

    Component{
        id: com_reveal
        CircularReveal{
            id: reveal
            target: window.containerItem()
            anchors.fill: parent
            darkToLight: FluTheme.dark
            onAnimationFinished:{
                loader_reveal.sourceComponent = undefined
                window.isChangingDark = false
            }
            onImageChanged: {
                changeDark()
            }
        }
    }

    LoginPopup {
        id: login_popup
    }

    FluMenu {
        id: logout_menu
        FluMenuItem {
            text: "退出登录"
            onClicked: {
                Login.logout()
            }
        }
    }

    FluLoader{
        id:loader_reveal
        anchors.fill: parent
    }

    function distance(x1,y1,x2,y2){
        return Math.sqrt((x1 - x2) * (x1 - x2) + (y1 - y2) * (y1 - y2))
    }

    function handleDarkChanged(button){
        if(isChangingDark){
            return
        }
        isChangingDark = true
        var willBeDark = !FluTheme.dark
        app_bar.buttonDark.iconSource = willBeDark ? FluentIcons.Brightness : FluentIcons.QuietHours
        app_bar.buttonDark.text = willBeDark ? app_bar.lightText : app_bar.darkText

        if(FluTools.isMacos() || !FluTheme.animationEnabled){
            changeDark()
            isChangingDark = false
        }else{
            loader_reveal.sourceComponent = com_reveal
            var target = window.containerItem()
            var pos = button.mapToItem(target,0,0)
            var mouseX = pos.x + button.width / 2
            var mouseY = pos.y + button.height / 2
            var radius = Math.max(distance(mouseX,mouseY,0,0),distance(mouseX,mouseY,target.width,0),distance(mouseX,mouseY,0,target.height),distance(mouseX,mouseY,target.width,target.height))
            var reveal = loader_reveal.item
            reveal.start(reveal.width*Screen.devicePixelRatio,reveal.height*Screen.devicePixelRatio,Qt.point(mouseX,mouseY),radius)
        }
    }

    function changeDark(){
        if(FluTheme.dark){
            FluTheme.darkMode = FluThemeType.Light
        }else{
            FluTheme.darkMode = FluThemeType.Dark
        }
        // 主题切换即时落盘：即使异常退出也能保留用户选择
        App.saveTheme(FluTheme.dark)
    }
}
