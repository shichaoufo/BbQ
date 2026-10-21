#pragma once

#include <QtQuick/QQuickItem>
#include <QtCore/QVariant>
#include <QtCore/QVector>
#include <QtCore/QHash>
#include <QtCore/QTimer>

QT_BEGIN_NAMESPACE
class QQmlComponent;
class QQmlDelegateModel;
QT_END_NAMESPACE

// 瀑布流视图（固定 N 列，单滚动源，虚拟化）
//
// 为什么需要它：QML 没有 Flutter 里 SliverMasonryGrid 的等价物。
// 用两个 ListView 拼两列会得到两份独立的 contentHeight 和两套边界夹紧逻辑，
// 快速拖动滚动条时必然错位（一列空白、滑块乱跳、到顶/到底后滚轮还能滚）。
// 这里把「列分配 + 累计高度 + 可见项创建/回收」全部收进一个对象，
// 滚动交给外面的 Flickable，整页只有一个滚动状态。
//
// 用法：
//   Flickable {
//       contentHeight: view.contentHeight
//       MasonryView {
//           id: view
//           width: parent.width
//           model: someListModel
//           delegate: cardComponent
//           viewportY: parent.contentY      // 必填：用于可见区判定
//           viewportHeight: parent.height
//       }
//   }
class MasonryView : public QQuickItem
{
    Q_OBJECT
    Q_PROPERTY(QVariant model READ model WRITE setModel NOTIFY modelChanged)
    Q_PROPERTY(QQmlComponent *delegate READ delegate WRITE setDelegate NOTIFY delegateChanged)
    Q_PROPERTY(int columnCount READ columnCount WRITE setColumnCount NOTIFY columnCountChanged)
    Q_PROPERTY(qreal rowSpacing READ rowSpacing WRITE setRowSpacing NOTIFY rowSpacingChanged)
    Q_PROPERTY(qreal columnSpacing READ columnSpacing WRITE setColumnSpacing NOTIFY columnSpacingChanged)
    Q_PROPERTY(qreal viewportY READ viewportY WRITE setViewportY NOTIFY viewportYChanged)
    Q_PROPERTY(qreal viewportHeight READ viewportHeight WRITE setViewportHeight NOTIFY viewportHeightChanged)
    Q_PROPERTY(qreal contentHeight READ contentHeight NOTIFY contentHeightChanged)
    Q_PROPERTY(qreal cacheBuffer READ cacheBuffer WRITE setCacheBuffer NOTIFY cacheBufferChanged)

public:
    explicit MasonryView(QQuickItem *parent = nullptr);
    ~MasonryView() override;

    QVariant model() const { return m_model; }
    void setModel(const QVariant &v);

    QQmlComponent *delegate() const { return m_delegate; }
    void setDelegate(QQmlComponent *c);

    int columnCount() const { return m_columnCount; }
    void setColumnCount(int v);

    qreal rowSpacing() const { return m_rowSpacing; }
    void setRowSpacing(qreal v);

    qreal columnSpacing() const { return m_columnSpacing; }
    void setColumnSpacing(qreal v);

    qreal viewportY() const { return m_viewportY; }
    void setViewportY(qreal v);

    qreal viewportHeight() const { return m_viewportHeight; }
    void setViewportHeight(qreal v);

    qreal contentHeight() const { return m_contentHeight; }

    qreal cacheBuffer() const { return m_cacheBuffer; }
    void setCacheBuffer(qreal v);

signals:
    void modelChanged();
    void delegateChanged();
    void columnCountChanged();
    void rowSpacingChanged();
    void columnSpacingChanged();
    void viewportYChanged();
    void viewportHeightChanged();
    void contentHeightChanged();
    void cacheBufferChanged();

protected:
    void componentComplete() override;
    void geometryChange(const QRectF &newGeometry, const QRectF &oldGeometry) override;

private:
    void onModelCountChanged();
    void scheduleRebuild();
    void rebuildLayout();
    void updateVisibleItems();
    void ensureItem(int index);
    void dropItem(int index);
    void onItemHeightChanged(QQuickItem *item);
    qreal heightAt(int index) const;
    qreal estimateHeight() const;
    void updateEstimate();
    qreal columnWidth() const;

    QVariant m_model;
    QQmlComponent *m_delegate = nullptr;
    QQmlDelegateModel *m_delegateModel = nullptr;

    int m_columnCount = 2;
    qreal m_rowSpacing = 8;
    qreal m_columnSpacing = 8;
    qreal m_viewportY = 0;
    qreal m_viewportHeight = 0;
    qreal m_contentHeight = 0;
    qreal m_cacheBuffer = 600;
    // 未测项的估算高度。刻意做成"慢变量"：每帧按平均高度重算会让所有未测项
    // 位置整体漂移，表现为滑块来回跳 + 画面轻微闪烁。
    qreal m_estHeight = 0;

    QVector<qreal> m_heights;     // 已测得高度，0 = 未知
    QVector<qreal> m_y;           // 每项 y（锚点相对定位，持久保存）
    QVector<int> m_col;           // 每项所在列
    // 已经完成定位的项数：新追加的项从这里往后链式排，已有项的位置不再重算
    int m_placedCount = 0;
    QHash<int, QQuickItem *> m_items;      // index -> item
    QHash<QQuickItem *, int> m_itemIndex;  // item -> index

    QTimer m_rebuildTimer;
    // 滚动锚定：布局重排后补偿 contentY，使可见内容不动。
    // 预算按手势重置，避免"上方卡片持续比估算高"时把滚动动作一直抵消掉。
    QTimer m_scrollIdleTimer;
    // 滚动中暂存的 contentHeight：由 m_contentFlushTimer 定期强制落地，
    // 既能压住滑块的逐帧抖动，又不会因为"一直在滚"而永远不更新量程
    QTimer m_contentFlushTimer;
    qreal m_pendingContentHeight = -1;
    bool m_scrolling = false;
    bool m_layouting = false;
    bool m_pendingRebuild = false;
};
