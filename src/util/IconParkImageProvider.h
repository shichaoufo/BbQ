#ifndef ICONPARKIMAGEPROVIDER_H
#define ICONPARKIMAGEPROVIDER_H

#include <QQuickImageProvider>
#include <QImage>
#include <QSize>
#include <QString>

class IconParkImageProvider : public QQuickImageProvider
{
public:
    IconParkImageProvider();

    QImage requestImage(const QString &id, QSize *size, const QSize &requestedSize) override;

private:
    QString resolveIconColor(const QString &queryString) const;
};

#endif // ICONPARKIMAGEPROVIDER_H
