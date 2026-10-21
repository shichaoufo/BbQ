#include "MasonryView.h"

#include <QtQml/QQmlComponent>
#include <QtQml/QQmlContext>
#include <QtQml/QQmlIncubator>
#include <QtQml/qqml.h>
#include <QtQmlModels/private/qqmldelegatemodel_p.h>
#include <QtQmlModels/private/qqmlchangeset_p.h>

#include <algorithm>

MasonryView::MasonryView(QQuickItem *parent)
    : QQuickItem(parent)
{
    setClip(false);
    m_rebuildTimer.setSingleShot(true);
    m_rebuildTimer.setInterval(0);
    connect(&m_rebuildTimer, &QTimer::timeout, this, [this] { rebuildLayout(); });

    m_scrollIdleTimer.setSingleShot(true);
    m_scrollIdleTimer.setInterval(150);
    connect(&m_scrollIdleTimer, &QTimer::timeout, this, [this] {
        m_scrolling = false;
    });

    // 兜底落地：滚动中攒下的 contentHeight 每 250ms 强制应用一次。
    // 只靠"停手 150ms"的话，用户持续滚动时量程永远不更新，会出现滚不动/空白。
    m_contentFlushTimer.setSingleShot(true);
    m_contentFlushTimer.setInterval(250);
    connect(&m_contentFlushTimer, &QTimer::timeout, this, [this] {
        if (m_pendingContentHeight < 0)
            return;
        const qreal pending = m_pendingContentHeight;
        m_pendingContentHeight = -1;
        if (!qFuzzyCompare(pending + 1, m_contentHeight + 1)) {
            m_contentHeight = pending;
            setImplicitHeight(m_contentHeight);
            emit contentHeightChanged();
        }
    });
}

MasonryView::~MasonryView()
{
    if (m_delegateModel) {
        const auto items = m_items;
        m_items.clear();
        m_itemIndex.clear();
        for (QQuickItem *item : items)
            m_delegateModel->release(item, QQmlInstanceModel::NotReusable);
    }
}

void MasonryView::setModel(const QVariant &v)
{
    if (m_model == v)
        return;
    m_model = v;
    if (m_delegateModel)
        m_delegateModel->setModel(v);
    emit modelChanged();
    onModelCountChanged();
}

void MasonryView::setDelegate(QQmlComponent *c)
{
    if (m_delegate == c)
        return;
    m_delegate = c;
    if (m_delegateModel)
        m_delegateModel->setDelegate(c);
    emit delegateChanged();
    scheduleRebuild();
}

void MasonryView::setColumnCount(int v)
{
    v = qMax(1, v);
    if (m_columnCount == v)
        return;
    m_columnCount = v;
    emit columnCountChanged();
    scheduleRebuild();
}

void MasonryView::setRowSpacing(qreal v)
{
    if (qFuzzyCompare(m_rowSpacing, v))
        return;
    m_rowSpacing = v;
    emit rowSpacingChanged();
    scheduleRebuild();
}

void MasonryView::setColumnSpacing(qreal v)
{
    if (qFuzzyCompare(m_columnSpacing, v))
        return;
    m_columnSpacing = v;
    emit columnSpacingChanged();
    scheduleRebuild();
}

void MasonryView::setViewportY(qreal v)
{
    if (qFuzzyCompare(m_viewportY, v))
        return;
    m_viewportY = v;
    emit viewportYChanged();
    // 滚到最顶端时，如果首项已经被推到 0 以下，立刻重排把它钉回 0，
    // 否则顶部会一直缺一块、且再也滚不上去
    if (m_viewportY <= 0.5 && m_placedCount > 0) {
        bool needPin = false;
        for (int i = 0; i < m_y.size() && i < m_placedCount && !needPin; ++i) {
            if (m_col.value(i, -1) >= 0 && m_y.at(i) < -0.5) {
                // 只关心每列第一项，这里保守处理：任意项为负就重排
                needPin = true;
            }
        }
        if (needPin) {
            rebuildLayout();
            return;
        }
    }

    if (!m_scrolling)
        m_scrolling = true;
    m_scrollIdleTimer.start();
    updateVisibleItems();
}

void MasonryView::setViewportHeight(qreal v)
{
    if (qFuzzyCompare(m_viewportHeight, v))
        return;
    m_viewportHeight = v;
    emit viewportHeightChanged();
    updateVisibleItems();
}

void MasonryView::setCacheBuffer(qreal v)
{
    if (qFuzzyCompare(m_cacheBuffer, v))
        return;
    m_cacheBuffer = v;
    emit cacheBufferChanged();
    updateVisibleItems();
}

void MasonryView::componentComplete()
{
    QQuickItem::componentComplete();

    if (!m_delegate || m_model.isNull())
        return;

    m_delegateModel = new QQmlDelegateModel(qmlContext(this), this);
    m_delegateModel->classBegin();
    m_delegateModel->setDelegate(m_delegate);
    m_delegateModel->setModel(m_model);

    connect(m_delegateModel, &QQmlInstanceModel::countChanged,
            this, &MasonryView::onModelCountChanged);
    connect(m_delegateModel, &QQmlInstanceModel::modelUpdated,
            this, [this](const QQmlChangeSet &, bool reset) {
                if (reset) {
                    // 模型重置：已测高度作废，否则会拿旧高度给新数据排版
                    m_heights.clear();
                    m_col.clear();
                    m_y.clear();
                    m_placedCount = 0;
                }
                onModelCountChanged();
            });
    // 异步孵化完成时补位（本视图用同步孵化，这里只是兜底）
    connect(m_delegateModel, &QQmlInstanceModel::createdItem,
            this, [this](int index, QObject *object) {
                auto *item = qobject_cast<QQuickItem *>(object);
                if (!item)
                    return;
                if (item->parentItem() != this)
                    item->setParentItem(this);
                if (!m_items.contains(index)) {
                    m_items.insert(index, item);
                    m_itemIndex.insert(item, index);
                    connect(item, &QQuickItem::heightChanged, this,
                            [this, item] { onItemHeightChanged(item); });
                }
                if (item->height() > 0)
                    m_heights[index] = item->height();
                scheduleRebuild();
            });

    // 关键：模型 clear/reset 时 DelegateModel 会自己销毁已创建的 delegate，
    // 必须同步把我们的索引表清掉，否则留下悬空指针，后续 release() 会崩。
    connect(m_delegateModel, &QQmlInstanceModel::destroyingItem,
            this, [this](QObject *object) {
                auto *item = qobject_cast<QQuickItem *>(object);
                if (!item)
                    return;
                const auto it = m_itemIndex.find(item);
                if (it == m_itemIndex.end())
                    return;
                m_items.remove(it.value());
                m_itemIndex.erase(it);
            });

    m_delegateModel->componentComplete();
    onModelCountChanged();
}

void MasonryView::geometryChange(const QRectF &newGeometry, const QRectF &oldGeometry)
{
    QQuickItem::geometryChange(newGeometry, oldGeometry);
    if (qFuzzyCompare(newGeometry.width(), oldGeometry.width()))
        return;

    // 宽度变了 = 列宽变了 = 所有卡片的高度都不再有效。
    // 缓存里存的是旧宽度下量到的高度，直接拿来排会让卡片位置一路偏，
    // 表现就是"调整窗口后再往上滚，每张卡片位置都在上下跳"。
    // 这里按列宽比例缩放缓存（图片卡近似线性，文字卡略有误差但远好于沿用旧值），
    // 卡片重新创建时再用真实高度覆盖。
    const int cols = qMax(1, m_columnCount);
    const qreal oldColW = (oldGeometry.width() - m_columnSpacing * (cols - 1)) / cols;
    const qreal newColW = columnWidth();
    if (oldColW > 1 && newColW > 1) {
        const qreal k = newColW / oldColW;
        if (qAbs(k - 1.0) > 0.001) {
            for (int i = 0; i < m_heights.size(); ++i) {
                if (m_heights[i] > 0)
                    m_heights[i] *= k;
            }
        }
    }

    scheduleRebuild();
}

void MasonryView::onModelCountChanged()
{
    const int n = m_delegateModel ? m_delegateModel->count() : 0;
    if (m_heights.size() < n)
        m_heights.resize(n);
    else if (m_heights.size() > n)
        m_heights.resize(n);
    scheduleRebuild();
}

void MasonryView::scheduleRebuild()
{
    if (m_layouting) {
        m_pendingRebuild = true;
        return;
    }
    if (!m_rebuildTimer.isActive())
        m_rebuildTimer.start();
}

qreal MasonryView::columnWidth() const
{
    const int cols = qMax(1, m_columnCount);
    const qreal total = width() - m_columnSpacing * (cols - 1);
    return qMax(1.0, total / cols);
}

qreal MasonryView::estimateHeight() const
{
    // 用慢变量而不是实时平均：实时平均会随视口内卡片的进出不断变化，
    // 导致所有未测项位置整体漂移（滑块跳、画面闪）
    return m_estHeight > 0 ? m_estHeight : 320.0;
}

void MasonryView::updateEstimate()
{
    qreal sum = 0;
    int count = 0;
    for (qreal h : m_heights) {
        if (h > 0) {
            sum += h;
            ++count;
        }
    }
    if (count < 6)
        return;

    const qreal avg = sum / count;
    if (m_estHeight <= 0) {
        m_estHeight = avg;
        return;
    }
    // 变化不到 8% 就当没变；变化大时也只走一半，避免估算值抖动
    if (qAbs(avg - m_estHeight) < m_estHeight * 0.08)
        return;
    m_estHeight += (avg - m_estHeight) * 0.5;
}

qreal MasonryView::heightAt(int index) const
{
    if (index >= 0 && index < m_heights.size() && m_heights.at(index) > 0)
        return m_heights.at(index);
    return estimateHeight();
}

void MasonryView::rebuildLayout()
{
    if (!m_delegateModel)
        return;

    m_layouting = true;

    const int n = m_delegateModel->count();
    if (m_heights.size() != n)
        m_heights.resize(n);

    const int cols = qMax(1, m_columnCount);
    const qreal colW = columnWidth();

    m_y.resize(n);
    // 列分配一旦确定就固定：卡片高度被修正后如果重新挑"最短列"，
    // 已显示的卡片会整块换列（左右跳 + 该列整体重排），回滚时尤其明显
    if (m_col.size() != n) {
        const int oldSize = m_col.size();
        m_col.resize(n);
        for (int i = oldSize; i < n; ++i)
            m_col[i] = -1;
    }

    // ===== 列分组 =====
    QVector<QVector<int>> colIdx(cols);
    for (int i = 0; i < n; ++i) {
        if (m_col.at(i) >= 0 && m_col.at(i) < cols)
            colIdx[m_col.at(i)].append(i);
    }

    // 新项按"当前最短列"分配（只有新来的才需要决定，已有的保持不动）
    {
        QVector<qreal> colEnd(cols, 0.0);
        for (int c = 0; c < cols; ++c) {
            if (colIdx[c].isEmpty())
                continue;
            const int last = colIdx[c].last();
            colEnd[c] = (last < m_placedCount ? m_y.at(last) : 0.0)
                        + heightAt(last) + m_rowSpacing;
        }
        for (int i = m_placedCount; i < n; ++i) {
            if (m_col.at(i) >= 0)
                continue;
            int c = 0;
            for (int k = 1; k < cols; ++k) {
                if (colEnd.at(k) < colEnd.at(c) - 0.01)
                    c = k;
            }
            m_col[i] = c;
            colIdx[c].append(i);
            colEnd[c] += heightAt(i) + m_rowSpacing;
        }
    }

    // ===== 以"可见锚点"为基准双向链式定位（照搬 Flutter Sliver 的思路）=====
    // 关键：每列的 y 不再从第 0 张累加，而是从锚点往上下两个方向推导。
    // 于是"视口上方某张卡高度变了"只会推动它上方那些（看不见的），
    // 锚点及其下方完全不动 —— 这就是 PiliPlus / Flutter 不跳的原因。
    qreal maxBottom = 0;
    for (int c = 0; c < cols; ++c) {
        const QVector<int> &list = colIdx.at(c);
        if (list.isEmpty())
            continue;

        // 锚点 = 最后一个"顶部还在视口上方"的已定位项；没有则从头开始
        int anchorPos = 0;
        if (m_placedCount > 0) {
            for (int k = 0; k < list.size(); ++k) {
                const int idx = list.at(k);
                if (idx >= m_placedCount)
                    break;
                if (m_y.at(idx) <= m_viewportY)
                    anchorPos = k;
            }
        }

        // 已经在最顶部（contentY == 0）时，把首项钉回 0：
        // 锚点相对布局会把"视口上方多出来的高度"向上吃成负坐标，
        // 而 contentY 最小只能是 0，负掉的部分就永远滚不到、顶部被截断。
        const int first = list.first();
        if (m_placedCount == 0 || m_viewportY <= 0.5) {
            m_y[first] = 0;
            anchorPos = 0;
        }

        for (int k = anchorPos - 1; k >= 0; --k) {
            const int idx = list.at(k);
            const int below = list.at(k + 1);
            m_y[idx] = m_y.at(below) - heightAt(idx) - m_rowSpacing;
        }
        for (int k = anchorPos + 1; k < list.size(); ++k) {
            const int idx = list.at(k);
            const int above = list.at(k - 1);
            m_y[idx] = m_y.at(above) + heightAt(above) + m_rowSpacing;
        }

        const int last = list.last();
        maxBottom = qMax(maxBottom, m_y.at(last) + heightAt(last));
    }

    m_placedCount = n;
    qreal newContentHeight = qMax(0.0, maxBottom);

    // 已创建项重排（相同值不重复写，减少无谓的属性通知与重绘）
    for (auto it = m_items.cbegin(); it != m_items.cend(); ++it) {
        const int idx = it.key();
        if (idx < 0 || idx >= n)
            continue;
        QQuickItem *item = it.value();
        if (!qFuzzyCompare(item->width(), colW))
            item->setWidth(colW);
        const QPointF pos(m_col.at(idx) * (colW + m_columnSpacing), m_y.at(idx));
        if (!qFuzzyCompare(item->position(), pos))
            item->setPosition(pos);
    }

    if (!qFuzzyCompare(newContentHeight + 1, m_contentHeight + 1)) {
        if (m_scrolling) {
            // 滚动中不每帧改 contentHeight（滚动条分母一变滑块就抖），
            // 但也不能像上一版那样只等"停手"——持续滚动时永远等不到。
            // 这里记下来，由 250ms 的兜底定时器强制落一次。
            m_pendingContentHeight = newContentHeight;
            m_contentFlushTimer.start();
        } else {
            m_contentHeight = newContentHeight;
            m_pendingContentHeight = -1;
            setImplicitHeight(m_contentHeight);
            emit contentHeightChanged();
        }
    }

    m_layouting = false;
    updateVisibleItems();

    if (m_pendingRebuild) {
        m_pendingRebuild = false;
        scheduleRebuild();
    }
}

void MasonryView::updateVisibleItems()
{
    if (!m_delegateModel || m_layouting)
        return;

    const int n = m_delegateModel->count();
    if (n <= 0) {
        const auto keys = m_items.keys();
        for (int i : keys)
            dropItem(i);
        return;
    }

    // 上下各预留 ~2.5 屏的缓存。
    // 作用不只是"滚回来时不用重建"，更关键的是：**窗口尺寸变化时，这些还活着的
    // delegate 会跟着新列宽真实重排，把新宽度下的准确高度报回来**，
    // 相当于免费的批量重新测量；缓存外的卡片才只能退化成估算。
    // 缓存越大，resize 后"回滚跳变"的范围越小（代价是内存与首次创建耗时）。
    const qreal keepMargin = m_viewportHeight * 2.5;
    const qreal top = m_viewportY - m_cacheBuffer - keepMargin;
    const qreal bottom = m_viewportY + m_viewportHeight + m_cacheBuffer + keepMargin;
    // 回收边界比创建边界再宽一屏：用同一个边界会让卡片在边界上反复销毁重建（闪烁）
    const qreal dropMargin = m_cacheBuffer * 2 + keepMargin + m_viewportHeight;
    const qreal dropTop = m_viewportY - dropMargin;
    const qreal dropBottom = m_viewportY + m_viewportHeight + dropMargin;

    // 回收不可见项
    const auto keys = m_items.keys();
    for (int i : keys) {
        if (i < 0 || i >= m_y.size()) {
            dropItem(i);
            continue;
        }
        const qreal y = m_y.at(i);
        // 已创建的卡片用真实高度判断；高度还没算出来（=0）时先不回收，
        // 否则会出现"卡片刚创建就被判定不可见 → 销毁 → 空白一列"的抖动
        QQuickItem *created = m_items.value(i);
        const qreal h = created ? created->height() : heightAt(i);
        if (h <= 0)
            continue;
        if (y + h < dropTop || y > dropBottom)
            dropItem(i);
    }

    // 创建可见项
    for (int i = 0; i < n && i < m_y.size(); ++i) {
        const qreal y = m_y.at(i);
        if (y + heightAt(i) < top || y > bottom)
            continue;
        if (!m_items.contains(i))
            ensureItem(i);
    }
}

void MasonryView::ensureItem(int index)
{
    if (!m_delegateModel || m_items.contains(index))
        return;

    QObject *obj = m_delegateModel->object(index, QQmlIncubator::Synchronous);
    auto *item = qobject_cast<QQuickItem *>(obj);
    if (!item)
        return;

    item->setParentItem(this);
    item->setWidth(columnWidth());
    if (index < m_y.size())
        item->setPosition(QPointF(m_col.at(index) * (columnWidth() + m_columnSpacing),
                                  m_y.at(index)));

    m_items.insert(index, item);
    m_itemIndex.insert(item, index);
    connect(item, &QQuickItem::heightChanged, this, [this, item] { onItemHeightChanged(item); });

    if (item->height() > 0 && index < m_heights.size())
        m_heights[index] = item->height();
}

void MasonryView::dropItem(int index)
{
    QQuickItem *item = m_items.take(index);
    if (!item)
        return;
    m_itemIndex.remove(item);
    disconnect(item, nullptr, this, nullptr);
    if (m_delegateModel)
        m_delegateModel->release(item, QQmlInstanceModel::NotReusable);
}

void MasonryView::onItemHeightChanged(QQuickItem *item)
{
    const auto it = m_itemIndex.constFind(item);
    if (it == m_itemIndex.cend())
        return;

    const int index = it.value();
    const qreal h = item->height();
    if (index < 0 || index >= m_heights.size())
        return;
    // 高度为 0 说明卡内布局还没跑完，先不记录，否则会把估算值往下拽
    if (h <= 0)
        return;
    if (m_heights.at(index) > 0 && qAbs(m_heights.at(index) - h) < 0.5)
        return;

    m_heights[index] = h;
    updateEstimate();

    // 视口上方或视口内的卡片高度被修正时，必须"这一帧"就重排：
    // 用 0ms 定时器延后到下一轮事件循环的话，会先跳一下再被拉回来，看起来就是闪一下。
    // 视口下方（还没看到）的修正不影响当前画面，交给去抖重排即可。
    const bool affectsVisible =
        index < m_y.size() && m_y.at(index) <= m_viewportY + m_viewportHeight + 0.5;
    if (affectsVisible) {
        if (m_layouting)
            m_pendingRebuild = true;
        else
            rebuildLayout();
        return;
    }

    scheduleRebuild();
}
