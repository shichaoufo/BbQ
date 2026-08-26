import QtQuick 2.15

Item {
    id: root

    property string text: ""
    property color color: "#FB7299"
    property real digitWidth: 7
    property real digitHeight: 12
    property real segmentWidth: 2
    property real segmentGap: 1
    property real digitSpacing: 2

    width: digitRow.width
    height: digitHeight

    // 7 段数码管：0-9 的段点亮状态
    // 段顺序：[上, 右上, 右下, 下, 左下, 左上, 中]
    property var segMap: {
        "0": [1, 1, 1, 1, 1, 1, 0],
        "1": [0, 1, 1, 0, 0, 0, 0],
        "2": [1, 1, 0, 1, 1, 0, 1],
        "3": [1, 1, 1, 1, 0, 0, 1],
        "4": [0, 1, 1, 0, 0, 1, 1],
        "5": [1, 0, 1, 1, 0, 1, 1],
        "6": [1, 0, 1, 1, 1, 1, 1],
        "7": [1, 1, 1, 0, 0, 0, 0],
        "8": [1, 1, 1, 1, 1, 1, 1],
        "9": [1, 1, 1, 1, 0, 1, 1]
    }

    Row {
        id: digitRow
        spacing: root.digitSpacing
        Repeater {
            model: root.text.length
            Item {
                width: root.digitWidth
                height: root.digitHeight
                property string ch: index < root.text.length ? root.text[index] : ""
                property var segs: root.segMap[ch] || [0, 0, 0, 0, 0, 0, 0]

                // 上
                Rectangle {
                    x: 1
                    y: 0
                    width: parent.width - 2
                    height: root.segmentWidth
                    color: root.color
                    visible: parent.segs[0]
                }
                // 右上
                Rectangle {
                    x: parent.width - root.segmentWidth
                    y: 1
                    width: root.segmentWidth
                    height: (parent.height - 2) / 2 - 1
                    color: root.color
                    visible: parent.segs[1]
                }
                // 右下
                Rectangle {
                    x: parent.width - root.segmentWidth
                    y: parent.height / 2 + 1
                    width: root.segmentWidth
                    height: (parent.height - 2) / 2 - 1
                    color: root.color
                    visible: parent.segs[2]
                }
                // 下
                Rectangle {
                    x: 1
                    y: parent.height - root.segmentWidth
                    width: parent.width - 2
                    height: root.segmentWidth
                    color: root.color
                    visible: parent.segs[3]
                }
                // 左下
                Rectangle {
                    x: 0
                    y: parent.height / 2 + 1
                    width: root.segmentWidth
                    height: (parent.height - 2) / 2 - 1
                    color: root.color
                    visible: parent.segs[4]
                }
                // 左上
                Rectangle {
                    x: 0
                    y: 1
                    width: root.segmentWidth
                    height: (parent.height - 2) / 2 - 1
                    color: root.color
                    visible: parent.segs[5]
                }
                // 中
                Rectangle {
                    x: 1
                    y: parent.height / 2 - root.segmentWidth / 2
                    width: parent.width - 2
                    height: root.segmentWidth
                    color: root.color
                    visible: parent.segs[6]
                }
            }
        }
    }
}
