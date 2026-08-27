import QtQuick 2.15
import BiliQt 1.0

// 直播/视频弹幕浮层组件（场景图版）
//
// 对外 API 与原版本完全一致，VideoPlayerPage / LivePlayerPage 零改动：
//   属性: danmakuEnabled / opacityValue / fontSizeScale / speedScale
//         displayAreaRatio / areaOffsetRatio / baseFontSize / trackHeight
//         scrollDuration / maxItems
//   方法: addDanmaku(text, color, type) / clear() / pause() / resume()
//
// 内部变化：
//   - 弹幕位置、生命周期、时钟（暂停补偿）全部移入 C++（DanmakuCanvas），
//     渲染期间零 JS 参与；位置在渲染同步点采样，与事件调度抖动隔离
//   - 移除 ListModel 全量同步（原 _syncCanvasItems 每帧跨边界拷贝全部弹幕）
//   - 移除自适应降帧（原瓶颈是 QQuickPaintedItem 全层重绘，场景图版不需要降级）
Item {
    id: root
    opacity: danmakuEnabled ? opacityValue : 0
    visible: true

    property bool danmakuEnabled: true
    property real opacityValue: 1.0
    property real fontSizeScale: 1.0
    property real speedScale: 1.0
    property real displayAreaRatio: 1.0
    property real areaOffsetRatio: 0.0
    property int baseFontSize: 22
    property int trackHeight: 32
    property int scrollDuration: 8000
    property int maxItems: 80
    property int outlineStyle: 0   // 描边样式：0=描边 1=重墨 2=45°投影（B站三档）

    property var _tracks: []
    property var _topTracks: []
    property var _bottomTracks: []

    // 有效轨道高度：固定 trackHeight 与当前字号档实际行高中取大者。
    // 字号调大后弹幕渲染高度（含描边）超过固定轨道高时，相邻轨道的弹幕
    // 会垂直重叠——轨道高度必须跟随字号（B 站网页端同款行为：字号越大
    // 可见轨道越少、行距越大）。lineHeight 由 C++ 按字体实测度量提供
    readonly property int effTrackHeight: Math.max(trackHeight, Math.ceil(_canvas.lineHeight))

    // 暂停与时钟由 C++ 托管（QElapsedTimer 单调时钟 + 暂停补偿）
    function pause()  { _canvas.paused = true }
    function resume() { _canvas.paused = false }

    // 帧驱动完全在 C++ 内：frameSwapped → update() → 同步点采样单调时钟。
    // QML 不参与每帧工作；暂停由 canvas.paused 门控（冻结 + 断链不空转）。
    DanmakuCanvas {
        id: _canvas
        anchors.fill: parent
        baseFontSize: root.baseFontSize
        fontSizeScale: root.fontSizeScale
        trackHeight: root.effTrackHeight   // 居中基准与轨道分配共用同一高度
        danmakuEnabled: root.danmakuEnabled
        maxItems: root.maxItems
        outlineStyle: root.outlineStyle   // 描边样式（C++ 侧切换时重建全部纹理）
        speedScale: root.speedScale   // 调速由 C++ 进度保持式完成
    }

    function _ensureTracks(arr, count) {
        if (arr.length !== count) {
            var newArr = new Array(count).fill(0)
            for (var i = 0; i < arr.length && i < count; i++) newArr[i] = arr[i]
            return newArr
        }
        return arr
    }

    // 找一段从 i 起连续 span 条且全部空闲的轨道（大字号弹幕跨轨道占用）
    function _pickTrackSpan(arr, now, span) {
        for (var i = 0; i + span <= arr.length; i++) {
            var ok = true
            for (var j = 0; j < span; j++) {
                if (arr[i + j] > now) { ok = false; i += j; break }
            }
            if (ok) return i
        }
        return -1
    }

    // 轨道分配与速度计算保持原逻辑不变（仅在发射时执行一次，非每帧热点）
    // dmFontSize：可选，B站弹幕字号字段（25=普通 18=小字），以 25 为基准换算缩放
    // emoticonUrl/emoticonSize：可选，直播纯表情弹幕（text 可为空；size 1=小 2=大）
    // emoticons：可选，文本+表情混排（元素 {text,url,size}，text 为文本内占位符）
    function addDanmaku(text, color, type, dmFontSize, emoticonUrl, emoticonSize, emoticons) {
        if (!danmakuEnabled) return
        var emoList = (emoticons !== undefined && emoticons !== null) ? emoticons : []
        var hasEmo = (emoticonUrl !== undefined && emoticonUrl !== null && emoticonUrl !== "")
                     || emoList.length > 0
        if ((text === undefined || text === null || text === "") && !hasEmo) return
        if (width <= 0 || height <= 0) return

        var dType = type || 1
        var colorStr = color || "#ffffff"
        var now = _canvas.currentMs()   // 与弹幕位置共用 C++ 单调时钟
        var emoSize = (emoticonSize === 2) ? 2 : 1

        // 单条字号缩放：未传/非法值时为 1.0；限制在合理范围防止异常数据撑爆纹理
        var dmScale = (dmFontSize > 0) ? Math.max(0.5, Math.min(2.0, dmFontSize / 25.0)) : 1.0

        var fontSize = baseFontSize * fontSizeScale * dmScale
        var charWidth = fontSize * 0.85
        // 宽度粗估（轨道占用时长用）：纯表情按平均纵横比 1.2 估算；
        // 混排 = 文本宽 + 各表情宽（各自按尺寸系数估高、纵横比 1.2 估宽）
        var emoWidth = 0
        var emoFactor = 1.0
        if (emoticonUrl !== undefined && emoticonUrl !== null && emoticonUrl !== "") {
            var f0 = (emoSize === 2) ? 1.8 : 1.15
            emoFactor = Math.max(emoFactor, f0)
            emoWidth += 1.2 * _canvas.lineHeight * dmScale * f0
        }
        for (var e = 0; e < emoList.length; e++) {
            var fe = (emoList[e].size === 2) ? 1.8 : 1.15
            emoFactor = Math.max(emoFactor, fe)
            emoWidth += 1.2 * _canvas.lineHeight * dmScale * fe
        }
        var textWidth = text.length * charWidth + emoWidth + 30

        var baseDistance = width + 200
        var pixelSpeed = baseDistance / (scrollDuration / speedScale)
        var duration = (width + textWidth) / pixelSpeed
        var occupyTime = (width + textWidth) / pixelSpeed + 200

        // 大字号弹幕/大表情渲染高度超过一条轨道时按实际高度跨轨道占用，
        // 占据的每条轨道都刷新占用时刻，相邻轨道弹幕不会与之重叠
        // （表情高度系数须与 C++ emoticonLogicalSize 保持一致）
        var contentH = _canvas.lineHeight * dmScale * emoFactor
        var span = Math.max(1, Math.ceil(contentH / effTrackHeight))
        var vBase = span * effTrackHeight   // 跨轨道区域总高（C++ 垂直居中基准）

        var trackIdx = -1
        var yPos = 0

        if (dType === 4) {
            var bottomCount = Math.floor((height * displayAreaRatio) / effTrackHeight)
            if (bottomCount < 1) bottomCount = 1
            _bottomTracks = _ensureTracks(_bottomTracks, bottomCount)
            trackIdx = _pickTrackSpan(_bottomTracks, now, span)
            if (trackIdx < 0) return
            for (var b = 0; b < span; b++) _bottomTracks[trackIdx + b] = now + 4000 / speedScale
            yPos = height - (trackIdx + span) * effTrackHeight
            _canvas.appendFixed(text, colorStr, yPos, 4000 / speedScale, now, dmScale, vBase)
        } else if (dType === 5) {
            var topCount = Math.floor((height * displayAreaRatio) / effTrackHeight)
            if (topCount < 1) topCount = 1
            _topTracks = _ensureTracks(_topTracks, topCount)
            trackIdx = _pickTrackSpan(_topTracks, now, span)
            if (trackIdx < 0) return
            for (var t = 0; t < span; t++) _topTracks[trackIdx + t] = now + 4000 / speedScale
            yPos = Math.round(height * areaOffsetRatio) + trackIdx * effTrackHeight
            _canvas.appendFixed(text, colorStr, yPos, 4000 / speedScale, now, dmScale, vBase)
        } else {
            var scrollCount = Math.floor((height * displayAreaRatio) / effTrackHeight)
            if (scrollCount < 1) scrollCount = 1
            _tracks = _ensureTracks(_tracks, scrollCount)
            trackIdx = _pickTrackSpan(_tracks, now, span)
            if (trackIdx < 0) return
            for (var s = 0; s < span; s++) _tracks[trackIdx + s] = now + occupyTime
            yPos = Math.round(height * areaOffsetRatio) + trackIdx * effTrackHeight + 4
            _canvas.appendScroll(text, colorStr, yPos, pixelSpeed, now, dmScale, vBase,
                                 (emoticonUrl !== undefined && emoticonUrl !== null) ? emoticonUrl : "",
                                 emoSize, emoList)
        }
    }

    function clear() {
        _tracks = []
        _topTracks = []
        _bottomTracks = []
        _canvas.paused = false
        _canvas.clear()   // 内含时钟重置
    }

    onWidthChanged: {
        _tracks = []
        _topTracks = []
        _bottomTracks = []
    }
    onHeightChanged: {
        _tracks = []
        _topTracks = []
        _bottomTracks = []
    }
    onDisplayAreaRatioChanged: {
        _tracks = []
        _topTracks = []
        _bottomTracks = []
    }
    onEffTrackHeightChanged: {
        // 字号档切换 → 轨道高度/数量变化，占用数组按新高度重建
        // （已上屏弹幕的 y 已锁定，仅新弹幕按新轨道分配，与 B 站行为一致）
        _tracks = []
        _topTracks = []
        _bottomTracks = []
    }
    onAreaOffsetRatioChanged: {
        _tracks = []
        _topTracks = []
        _bottomTracks = []
    }
}
