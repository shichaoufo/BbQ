#include "QRCodeGenerator.h"
#include "qrencode/qrencode.h"
#include <QImage>
#include <QPainter>


QImage QRCodeGenerator::generate(const QString &text, int size)
{
    if (text.isEmpty()) {
        return QImage();
    }

    // 使用 libqrencode 生成二维码，0 表示自动选择版本
    QRcode *qrcode = QRcode_encodeString(text.toUtf8().constData(),
                                          0,  // version
                                          QR_ECLEVEL_Q,  // 错误纠正等级
                                          QR_MODE_8,
                                          1);  // case sensitive

    if (!qrcode) {

        return QImage();
    }

    int qrWidth = qrcode->width;
    int qrSize = qrcode->width;

    // 创建带白边的图片
    int margin = 4;  // 边框大小（以二维码模块为单位）
    int totalModules = qrSize + margin * 2;
    int scale = size / totalModules;
    if (scale < 1) scale = 1;

    int imageSize = totalModules * scale;

    QImage image(imageSize, imageSize, QImage::Format_RGB32);
    image.fill(Qt::white);

    // 绘制二维码
    for (int y = 0; y < qrSize; y++) {
        for (int x = 0; x < qrSize; x++) {
            unsigned char b = qrcode->data[y * qrSize + x];
            if (b & 0x01) {
                // 黑色模块
                for (int dy = 0; dy < scale; dy++) {
                    for (int dx = 0; dx < scale; dx++) {
                        int px = (x + margin) * scale + dx;
                        int py = (y + margin) * scale + dy;
                        if (px < imageSize && py < imageSize) {
                            image.setPixel(px, py, qRgb(0, 0, 0));
                        }
                    }
                }
            }
        }
    }

    QRcode_free(qrcode);
    return image;
}
