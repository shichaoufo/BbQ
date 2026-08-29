#pragma once

#include <QQuickPaintedItem>
#include <QPainter>
#include <QPropertyAnimation>
#include <QSharedPointer>
#include <QQuickItemGrabResult>

class CircularReveal : public QQuickPaintedItem {
    Q_OBJECT
    Q_PROPERTY(QQuickItem *target READ target WRITE setTarget NOTIFY targetChanged)
    Q_PROPERTY(int radius READ radius WRITE setRadius NOTIFY radiusChanged)
public:
    explicit CircularReveal(QQuickItem *parent = nullptr);
    void paint(QPainter *painter) override;
    Q_INVOKABLE void start(int w, int h, const QPoint &center, int radius);

    QQuickItem *target() const { return _target; }
    void setTarget(QQuickItem *target) { _target = target; emit targetChanged(); }

    int radius() const { return _radius; }
    void setRadius(int radius) { _radius = radius; emit radiusChanged(); }

signals:
    void targetChanged();
    void radiusChanged();
    void imageChanged();
    void animationFinished();

private slots:
    void handleGrabResult();

private:
    QPropertyAnimation *_anim = nullptr;
    QImage _source;
    QPoint _center;
    QSharedPointer<QQuickItemGrabResult> _grabResult;
    QQuickItem *_target = nullptr;
    int _radius = 0;
};
