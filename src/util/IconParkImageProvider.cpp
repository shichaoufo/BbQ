#include "IconParkImageProvider.h"

#include <QFile>
#include <QPainter>
#include <QSvgRenderer>
#include <QUrl>
#include <QUrlQuery>

IconParkImageProvider::IconParkImageProvider()
    : QQuickImageProvider(QQuickImageProvider::Image)
{
}

QImage IconParkImageProvider::requestImage(const QString &id, QSize *size, const QSize &requestedSize)
{
    // id 格式：thumb-up?color=%23FFFFFF
    QUrl url(QStringLiteral("image://iconpark/") + id);
    QString iconName = url.path();
    QString iconColor = resolveIconColor(url.query());

    if (iconColor.isEmpty()) {
        iconColor = QStringLiteral("#000000");
    }

    QString resourcePath = QStringLiteral(":/BiliQt/qml/assets/icons/iconpark/%1.svg").arg(iconName);
    QFile file(resourcePath);
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
        return QImage();
    }

    QByteArray svgData = file.readAll();
    file.close();

    QString svgText = QString::fromUtf8(svgData);
    svgText.replace(QStringLiteral("currentColor"), iconColor);

    QSvgRenderer renderer(svgText.toUtf8());
    if (!renderer.isValid()) {
        return QImage();
    }

    QSize renderSize = requestedSize.isValid() ? requestedSize : renderer.defaultSize();
    if (size) {
        *size = renderSize;
    }

    QImage image(renderSize, QImage::Format_ARGB32_Premultiplied);
    image.fill(Qt::transparent);

    QPainter painter(&image);
    renderer.render(&painter);
    painter.end();

    return image;
}

QString IconParkImageProvider::resolveIconColor(const QString &queryString) const
{
    QUrlQuery query(queryString);
    return query.queryItemValue(QStringLiteral("color"), QUrl::FullyDecoded);
}
