pragma Singleton
import QtQuick 2.15

QtObject {
    id: root

    // 推荐页全局状态，切换导航栏后仍保持
    property ListModel recommendModel: ListModel {}
    property real recommendScrollY: 0
    property real recommendContentHeight: 0
    property int recommendNextPage: 1
    property bool recommendLoading: false
    property int recommendEmptyStreak: 0
    property bool recommendManualRefresh: false
    property bool recommendHasMore: true

    // 热门页各分类数据（独立缓存，避免切换分类时重新加载）
    property string hotCurrentCategory: "all"
    property ListModel hotsAllModel: ListModel {}
    property real hotsAllScrollY: 0
    property int hotsAllPage: 0
    property bool hotsAllHasMore: true

    property ListModel hotsRankModel: ListModel {}
    property real hotsRankScrollY: 0
    property int hotsRankPage: 0
    property bool hotsRankHasMore: true
    property int hotsRankRid: 0

    property ListModel hotsWeeklyModel: ListModel {}
    property real hotsWeeklyScrollY: 0
    property int hotsWeeklyNumber: 0
    property var hotsWeeklyList: []
    property bool hotsWeeklyHasMore: true

    property ListModel hotsHistoryModel: ListModel {}
    property real hotsHistoryScrollY: 0
    property bool hotsHistoryHasMore: true

    // HomePage 当前 Pivot 索引
    property int homePivotIndex: 0

    // 直播页全局状态
    property ListModel liveRecommendModel: ListModel {}
    property real liveRecommendScrollY: 0
    property real liveRecommendContentHeight: 0
    property ListModel liveFollowingModel: ListModel {}
    property real liveFollowingScrollY: 0
    property real liveFollowingContentHeight: 0
    property int livePivotIndex: 0
    property string liveCurrentArea: "全部"
    property string liveCurrentSubArea: "全部"
    property int liveCurrentParentAreaId: 0
    property int liveCurrentSubAreaId: 0
    property var liveAreas: [
        { name: "全部", subs: [{ name: "全部", id: 0 }], parentId: 0, subId: 0 }
    ]
    property bool liveAreasLoaded: false

    // 动态页全局状态
    property ListModel dynamicModel: ListModel {}
    property real dynamicScrollY: 0

    // 搜索页全局状态
    property string searchKeyword: ""
    property ListModel searchResultModel: ListModel {}
    property real searchScrollY: 0
    property bool searchHasSearched: false

    // 通用格式化工具函数
    function formatNumber(num) {
        var n = parseInt(num, 10) || 0
        if (n >= 100000000) return (n / 100000000).toFixed(1) + "亿"
        if (n >= 10000) return (n / 10000).toFixed(1) + "万"
        return String(n)
    }

    function formatTimeAgo(timestamp) {
        var now = Date.now() / 1000
        var diff = now - (parseInt(timestamp, 10) || 0)
        if (diff < 60) return "刚刚"
        if (diff < 3600) return Math.floor(diff / 60) + "分钟前"
        if (diff < 86400) return Math.floor(diff / 3600) + "小时前"
        if (diff < 2592000) return Math.floor(diff / 86400) + "天前"
        if (diff < 31536000) return Math.floor(diff / 2592000) + "个月前"
        return Math.floor(diff / 31536000) + "年前"
    }

    function _formatSmartTime(timestamp) {
        var ts = parseInt(timestamp, 10) || 0
        if (ts <= 0) return ""
        var now = new Date()
        var date = new Date(ts * 1000)
        var nowYear = now.getFullYear()
        var nowMonth = now.getMonth()
        var nowDate = now.getDate()
        var year = date.getFullYear()
        var month = date.getMonth()
        var day = date.getDate()

        if (year === nowYear && month === nowMonth && day === nowDate) {
            var diff = Math.floor(now.getTime() / 1000) - ts
            if (diff < 60) return "刚刚"
            if (diff < 3600) return Math.floor(diff / 60) + "分钟前"
            return Math.floor(diff / 3600) + "小时前"
        }

        var mm = (month + 1 < 10 ? "0" : "") + (month + 1)
        var dd = (day < 10 ? "0" : "") + day
        if (year === nowYear) return mm + "-" + dd
        return year + "-" + mm + "-" + dd
    }

    function formatVideoCardTime(timestamp) {
        return _formatSmartTime(timestamp)
    }

    function formatCommentTime(timestamp) {
        return _formatSmartTime(timestamp)
    }

    function formatDateTime(timestamp) {
        var ts = parseInt(timestamp, 10) || 0
        if (ts <= 0) return ""
        var date = new Date(ts * 1000)
        var y = date.getFullYear()
        var m = (date.getMonth() + 1 < 10 ? "0" : "") + (date.getMonth() + 1)
        var d = (date.getDate() < 10 ? "0" : "") + date.getDate()
        var h = (date.getHours() < 10 ? "0" : "") + date.getHours()
        var min = (date.getMinutes() < 10 ? "0" : "") + date.getMinutes()
        var s = (date.getSeconds() < 10 ? "0" : "") + date.getSeconds()
        return y + "-" + m + "-" + d + " " + h + ":" + min + ":" + s
    }

    function getLevelColor(level) {
        switch (level) {
            case 0:
            case 1: return "#BFBFBF"
            case 2: return "#7FD37F"
            case 3: return "#73C9E5"
            case 4: return "#F7B893"
            case 5: return "#F07C3F"
            case 6: return "#E93B3B"
            default: return "#BFBFBF"
        }
    }

    // 用户头像专用：强制剥离已有的 @ 尺寸参数并按目标尺寸重新请求，
    // 避免接口返回的小图后缀导致头像模糊。
    function fixAvatarUrl(url, size) {
        if (!url) return ""
        if (url.indexOf("//") === 0) url = "https:" + url
        var atIndex = url.indexOf("@")
        if (atIndex >= 0) url = url.substring(0, atIndex)
        // gif（如B站默认头像 noface.gif）不支持格式转换后缀，直接返回原始 URL
        if (url.toLowerCase().indexOf(".gif") >= 0) return url
        var s = size ? Math.round(size) : 96
        if (s <= 0) s = 96
        return url + "@" + s + "w_" + s + "h_1c_100q.jpg"
    }

    // Qt 默认可能不支持 webp，让 B 站 CDN 返回 jpg 格式。
    // 支持传入目标宽高，让 CDN 返回对应分辨率的图片，降低网络占用。
    // crop=true 时使用 1e_1c 中心裁剪，适合 PreserveAspectCrop；否则按给定宽高缩放。
    function fixImageUrl(url, width, height, crop) {
        if (!url) return ""
        // B站部分接口返回 // 开头的协议相对 URL，Qt Image 无法解析，补全为 https://
        if (url.indexOf("//") === 0) {
            url = "https:" + url
        }
        // 已经携带转换参数则不再追加，避免重复
        if (url.indexOf("@") >= 0) return url
        // 动图（.gif/.webp 后缀）：不能追加 @.jpg 等 CDN 格式转换参数，
        // 否则 B站 CDN 会按 jpg 静态图返回，动图变成第一帧静止。
        // Qt 的 AnimatedImage 需要原始动图 URL 才能播放动画。
        var lower = url.toLowerCase()
        var queryIdx = lower.indexOf("?")
        var pathEnd = queryIdx >= 0 ? queryIdx : url.length
        var pathLower = lower.substring(0, pathEnd)
        if (pathLower.endsWith(".gif") || pathLower.endsWith(".webp")) {
            return url
        }
        var w = width ? Math.round(width) : 0
        var h = height ? Math.round(height) : 0
        if (w > 0 && h > 0) {
            if (crop) {
                return url + "@" + w + "w_" + h + "h_1e_1c.jpg"
            }
            return url + "@" + w + "w_" + h + "h.jpg"
        }
        if (w > 0) {
            return url + "@" + w + "w.jpg"
        }
        return url + "@.jpg"
    }

    // 判断是否为动图 URL（.gif/.webp 后缀，忽略查询参数）。
    // 与 fixImageUrl 内部的动图判断保持一致：
    // B站 CDN 对动图保留原始后缀，需用 AnimatedImage 播放，不能追加 CDN 格式转换参数。
    function isAnimatedImageUrl(url) {
        if (!url) return false
        var lower = url.toLowerCase()
        var queryIdx = lower.indexOf("?")
        var pathLower = lower.substring(0, queryIdx >= 0 ? queryIdx : url.length)
        return pathLower.endsWith(".gif") || pathLower.endsWith(".webp")
    }

    // 返回固定尺寸（480x270，16:9）的 CDN 图片 URL。
    // 用于视频/直播卡片封面等场景：URL 不随显示尺寸变化，确保只在第一次显示时下载一次，
    // 后续 resize 由 Qt 在本地做 GPU 缩放，避免反复重新下载导致转圈圈和封面闪动。
    function fixImageUrlStatic(url) {
        if (!url) return ""
        if (url.indexOf("//") === 0) {
            url = "https:" + url
        }
        if (url.indexOf("@") >= 0) return url
        return url + "@480w_270h_1e_1c.jpg"
    }
}
