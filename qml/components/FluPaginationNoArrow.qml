import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import FluentUI

Item {
    signal requestPage(int page, int count)

    property int pageCurrent: 0
    property int itemCount: 0
    property int pageButtonCount: 5
    property bool useTotalPages: false
    property int totalPages: 0
    property int pageSize: 10
    property int pageCount: useTotalPages ? (totalPages > 0 ? totalPages : 0) : (itemCount > 0 ? Math.ceil(itemCount / pageSize) : 0)
    property int __pageButtonHalf: Math.floor(pageButtonCount / 2) + 1
    id: control
    implicitHeight: 40
    implicitWidth: content.width
    Row {
        id: content
        height: control.height
        spacing: 10
        padding: 10
        Row {
            spacing: 5
            FluToggleButton {
                property int pageNumber: 1
                visible: control.pageCount > 0
                checked: pageNumber === control.pageCurrent
                text: String(pageNumber)
                clickListener: function () {
                    control.calcNewPage(pageNumber);
                }
            }
            FluText {
                visible: (control.pageCount > control.pageButtonCount &&
                    control.pageCurrent > control.__pageButtonHalf)
                text: "..."
            }
            Repeater {
                id: button_repeator
                model: (control.pageCount < 2) ? 0 : (control.pageCount >= control.pageButtonCount) ? (control.pageButtonCount - 2) : (control.pageCount - 2)
                delegate: FluToggleButton {
                    property int  pageNumber: {
                        return (control.pageCurrent <= control.__pageButtonHalf)
                            ? (2 + index)
                            : (control.pageCount - control.pageCurrent <= control.pageButtonCount - control.__pageButtonHalf)
                                ? (control.pageCount - button_repeator.count + index)
                                : (control.pageCurrent + 2 + index - control.__pageButtonHalf)
                    }
                    text: String(pageNumber)
                    checked: pageNumber === control.pageCurrent
                    clickListener: function () {
                        control.calcNewPage(pageNumber);
                    }
                }
            }
            FluText {
                visible: (control.pageCount > control.pageButtonCount &&
                    control.pageCount - control.pageCurrent > control.pageButtonCount - control.__pageButtonHalf)
                text: "..."
            }
            FluToggleButton {
                property int pageNumber: control.pageCount
                visible: control.pageCount > 1
                checked: pageNumber === control.pageCurrent
                text: String(pageNumber)
                clickListener: function () {
                    control.calcNewPage(pageNumber);
                }
            }
        }
    }
    function calcNewPage(page) {
        if (!page)
            return
        let page_num = Number(page)
        if (page_num < 1 || page_num > control.pageCount || page_num === control.pageCurrent)
            return
        control.pageCurrent = page_num
        control.requestPage(page_num, control.pageSize)
    }
}
