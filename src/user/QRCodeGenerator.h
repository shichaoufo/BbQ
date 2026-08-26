#ifndef QRCODEGENERATOR_H
#define QRCODEGENERATOR_H

#include <QImage>
#include <QString>

// 纯 C++ 二维码生成类，基于 libqrencode
class QRCodeGenerator
{
public:
    // 根据文本生成二维码图片
    static QImage generate(const QString &text, int size = 280);
};

#endif // QRCODEGENERATOR_H
