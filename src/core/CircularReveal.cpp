#include "CircularReveal.h"
#include <QPainterPath>

CircularReveal::CircularReveal(QQuickItem *parent) : QQuickPaintedItem(parent) {
    _anim = new QPropertyAnimation(this, "radius", this);
    _anim->setDuration(333);
    _anim->setEasingCurve(QEasingCurve::OutCubic);
    setVisible(false);
    connect(_anim, &QPropertyAnimation::finished, this, [=]() {
        update();
        setVisible(false);
        emit animationFinished();
    });
    connect(this, &CircularReveal::radiusChanged, this, [=]() { update(); });
}

void CircularReveal::paint(QPainter *painter) {
    painter->save();
    // 旧主题截图铺满全屏（首帧半径为 0，整屏即旧主题，视觉无跳变）
    painter->drawImage(QRect(0, 0, static_cast<int>(width()), static_cast<int>(height())), _source);
    // 镂空圆内：圆内透出主题已切换的实时场景（新主题），圆外保留旧主题
    // 截图。圆从按钮位置向四周长大，新主题随圆逐步揭示——两个切换方向
    // 动画一致。不再按 darkToLight 分支反向收缩/整屏镂空，避免"第一帧
    // 整屏变色"与"旧主题回流再闪变"的中间态
    QPainterPath path;
    path.addEllipse(QPointF(_center.x(), _center.y()), _radius, _radius);
    painter->setCompositionMode(QPainter::CompositionMode_Clear);
    painter->fillPath(path, Qt::white);
    painter->restore();
}

void CircularReveal::start(int w, int h, const QPoint &center, int radius) {
    if (_anim->state() == QAbstractAnimation::Running) {
        _anim->stop();
        _anim->setStartValue(_radius);   // 中断续播：从当前半径继续长大
    } else {
        _anim->setStartValue(0);
        _radius = 0;   // 半径与动画起点同步，避免首帧以过期半径绘制
    }
    _anim->setEndValue(radius);
    _center = center;
    _grabResult = _target->grabToImage(QSize(w, h));
    connect(_grabResult.data(), &QQuickItemGrabResult::ready, this,
            &CircularReveal::handleGrabResult);
}

void CircularReveal::handleGrabResult() {
    _source = _grabResult.data()->image();
    // 先置可见再请求重绘：不可见项上的 update() 可能被丢弃，
    // 导致首个可见帧纹理为空、新主题穿透一帧（首帧"滤镜"）
    setVisible(true);
    update();
    emit imageChanged();
    _anim->start();
}
