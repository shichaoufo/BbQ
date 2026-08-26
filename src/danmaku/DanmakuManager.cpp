#include "DanmakuManager.h"
#include "DanmakuSettings.h"
#include <QCryptographicHash>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QUrlQuery>
#include <QDateTime>
#include <QXmlStreamReader>
#include <QByteArray>
#include <QTextStream>
#include <algorithm>
#include <iostream>

const QString DanmakuManager::USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
const QString DanmakuManager::REFERER = "https://www.bilibili.com";

DanmakuManager::DanmakuManager(QObject *parent)
    : QObject(parent)
    , m_networkManager(new QNetworkAccessManager(this))
{
}

DanmakuManager::~DanmakuManager()
{
}

void DanmakuManager::getDanmakuList(const QString &cid)
{
    // 使用更简单的弹幕API端点
    QString url = QString("https://comment.bilibili.com/%1.xml").arg(cid);
    
    QUrl qurl(url);
    QNetworkRequest request(qurl);
    request.setRawHeader(QByteArray("User-Agent"), USER_AGENT.toUtf8());
    request.setRawHeader(QByteArray("Referer"), REFERER.toUtf8());
    
    QNetworkReply *reply = m_networkManager->get(request);
    connect(reply, &QNetworkReply::finished, this, &DanmakuManager::onDanmakuReplyFinished);
}

void DanmakuManager::onDanmakuReplyFinished()
{
    QNetworkReply *reply = qobject_cast<QNetworkReply*>(sender());
    if (!reply) return;

    if (reply->error() != QNetworkReply::NoError) {
        QString errorMsg = QString("网络错误");
        std::cout << "[Danmaku] Network error: " << reply->errorString().toStdString() << std::endl;
        emit errorOccurred(errorMsg);
        reply->deleteLater();
        return;
    }

    QByteArray data = reply->readAll();
    std::cout << "[Danmaku] Received danmaku data, size: " << data.size() << std::endl;

    parseDanmakuData(data);

    reply->deleteLater();
}

void DanmakuManager::parseDanmakuData(const QByteArray &data)
{
    // 新的API直接返回XML，不需要解压
    m_danmakuList = parseXMLData(data);

    emit danmakuListReady(m_danmakuList);
}

QList<DanmakuManager::DanmakuItem> DanmakuManager::parseXMLData(const QByteArray &data)
{
    QList<DanmakuItem> result;
    
    QXmlStreamReader xml(data);
    
    while (!xml.atEnd() && !xml.hasError()) {
        xml.readNext();
        
        if (xml.isStartElement() && xml.name().toString() == QLatin1String("d")) {
            // 解析弹幕属性
            QString attributes = xml.attributes().value("p").toString();
            QStringList attrList = attributes.split(",");
            
            DanmakuItem item;
            
            if (attrList.size() >= 6) {
                // 格式: time, type, fontsize, color, timestamp, author, weight, ...
                item.timestamp = (int64_t)(attrList[0].toDouble() * 1000); // 转换为毫秒
                item.type = attrList[1].toInt();
                // attrList[2] = fontsize
                // 弹幕颜色格式是十进制RGB值，如 16777215 表示白色
                // 转换为 QColor 能识别的 RGB 分量
                bool ok;
                uint colorValue = attrList[3].toUInt(&ok, 10);  // 十进制解析
                if (ok && colorValue > 0) {
                    // BiliBili弹幕颜色是十进制RGB值，需要转换为RGB分量
                    // 例如 16777215 = 0xFFFFFF = 白色
                    item.color = QColor((colorValue >> 16) & 0xFF,
                                         (colorValue >> 8) & 0xFF,
                                         colorValue & 0xFF);
                } else {
                    // 默认白色
                    item.color = QColor(255, 255, 255);
                }
                // attrList[4] = timestamp
                item.author = attrList[5];
                // attrList[6] = weight
                if (attrList.size() > 7) {
                    item.id = attrList[7].toInt();
                }
            }
            
            // 读取弹幕文本
            xml.readNext();
            if (xml.isCharacters() && !xml.text().isNull()) {
                item.text = xml.text().toString();
                result.append(item);
            }
        }
    }
    
    if (xml.hasError()) {
        std::cout << "[Danmaku] XML parse error: " << xml.errorString().toStdString() << std::endl;
    }
    
    std::cout << "[Danmaku] Parsed " << result.size() << " danmaku items" << std::endl;
    
    return result;
}

void DanmakuManager::sendDanmaku(const QString &aid, const QString &cid,
                                 const QString &text, int position,
                                 const QColor &color)
{
    // TODO: 实现发送弹幕
    // 需要登录状态和CSRF Token
    Q_UNUSED(aid);
    Q_UNUSED(cid);
    Q_UNUSED(text);
    Q_UNUSED(position);
    Q_UNUSED(color);
    
    emit danmakuSent(false, "Send danmaku not implemented yet");
}

void DanmakuManager::likeDanmaku(const QString &dmid, const QString &oid, bool like)
{
    // TODO: 实现弹幕点赞
    Q_UNUSED(dmid);
    Q_UNUSED(oid);
    Q_UNUSED(like);
    
    emit danmakuLikeResult(false);
}

QList<DanmakuManager::DanmakuItem> DanmakuManager::filterDanmaku(
    const QList<DanmakuItem> &list, const QString &keyword)
{
    if (keyword.isEmpty()) {
        return list;
    }
    
    QList<DanmakuItem> result;
    for (const DanmakuItem &item : list) {
        if (item.text.contains(keyword, Qt::CaseInsensitive)) {
            result.append(item);
        }
    }
    
    return result;
}

QString DanmakuManager::generateTimestamp()
{
    return QString::number(QDateTime::currentSecsSinceEpoch());
}

QString DanmakuManager::getCSRFToken()
{
    // TODO: 从登录会话中获取CSRF Token
    return "";
}

static QString formatASS(int ms) {
    int total_seconds = ms / 1000;
    int hours = total_seconds / 3600;
    int minutes = (total_seconds % 3600) / 60;
    int seconds = total_seconds % 60;
    int centiseconds = (ms % 1000) / 10;
    return QString("%1:%2:%3.%4")
        .arg(hours, 2, 10, QChar('0'))
        .arg(minutes, 2, 10, QChar('0'))
        .arg(seconds, 2, 10, QChar('0'))
        .arg(centiseconds, 2, 10, QChar('0'));
}

static QString toASSColor(QColor color) {
    return QString("&H00%1%2%3")
        .arg(color.blue(), 2, 16, QChar('0'))
        .arg(color.green(), 2, 16, QChar('0'))
        .arg(color.red(), 2, 16, QChar('0'));
}

QString DanmakuManager::generateASS(const QList<DanmakuItem> &list, int videoWidth, int videoHeight) {
    QString ass;
    QTextStream out(&ass);

    DanmakuSettings* settings = DanmakuSettings::instance();

    // 按时间排序弹幕（轨道分配算法依赖时间顺序）
    QList<DanmakuItem> sortedList = list;
    std::sort(sortedList.begin(), sortedList.end(), [](const DanmakuItem &a, const DanmakuItem &b) {
        return a.timestamp < b.timestamp;
    });

    // 优化：限制弹幕数量，避免ASS文件过大导致卡顿
    const int MAX_DANMAKU_COUNT = 2000;
    if (sortedList.size() > MAX_DANMAKU_COUNT) {
        int step = sortedList.size() / MAX_DANMAKU_COUNT;
        QList<DanmakuItem> reducedList;
        for (int i = 0; i < sortedList.size(); i += step) {
            reducedList.append(sortedList[i]);
        }
        sortedList = reducedList;
    }

    // 计算实际字体大小
    int baseFontSize = videoHeight / 15;
    int fontSize = baseFontSize * (50 + settings->fontSize()) / 100;
    if (fontSize < 12) fontSize = 12;

    // 优化：降低默认轨道数量，减少弹幕密度
    int danmakuHeight = qMax(fontSize + 6, 24);
    int areaPercent = settings->area();
    int scrollAreaHeight = videoHeight * areaPercent / 100;
    int trackCount = scrollAreaHeight / danmakuHeight;
    if (trackCount < 3) trackCount = 3;
    if (trackCount > 8) trackCount = 8;

    // 计算透明度 (ASS格式: &HAARRGGBB, AA=00表示完全透明, FF表示完全不透明)
    int opacity = settings->opacity();
    int alpha = (100 - opacity) * 255 / 100;
    QString alphaStr = QString("%1").arg(alpha, 2, 16, QChar('0')).toUpper();

    // 基础显示时长（用于顶部/底部弹幕，以及作为滚动速度的基准）
    int baseDuration = settings->getDisplayDuration();

    // 常量速度模型：所有滚动弹幕以相同的线速度移动，避免追尾重叠
    // 速度定义：弹幕前沿从屏幕右边缘到左边缘的时间 = baseDuration
    // speed = videoWidth / baseDuration (像素/毫秒)
    double scrollSpeed = (double)videoWidth / baseDuration;

    // 弹幕进入屏幕前的外扩距离（避免从边缘突然出现）
    const int ENTER_MARGIN = 30;
    // 弹幕完全离开屏幕后的外扩距离
    const int EXIT_MARGIN = 30;

    // 计算描边宽度
    int outlineWidth = 0;
    if (settings->outline() == 1) {
        outlineWidth = 2;
    } else if (settings->outline() == 2) {
        outlineWidth = 3;
    }

    // 生成 ASS 文件头
    out << "[Script Info]\n";
    out << "Title: Danmaku\n";
    out << "ScriptType: v4.00+\n";
    out << "WrapStyle: 0\n";
    out << "PlayResX: " << videoWidth << "\n";
    out << "PlayResY: " << videoHeight << "\n";
    out << "ScaledBorderAndShadow: yes\n";
    out << "YCbCr Matrix: None\n\n";

    // 生成样式定义
    out << "[V4+ Styles]\n";
    out << "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, "
           "Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, "
           "Alignment, MarginL, MarginR, MarginV, Encoding\n";

    QString outlineColor = "&H00000000";

    // 滚动弹幕样式
    out << "Style: Scroll,SimHei," << fontSize
        << ",&H" << alphaStr << "FFFFFF,&H" << alphaStr << "FFFFFF,&H" << alphaStr << "000000,&H" << alphaStr << "000000"
        << ",0,0,0,0,100,100,0,0,1," << outlineWidth << "," << (settings->outline() == 2 ? outlineWidth : 0)
        << ",8,0,0,0,1\n";

    // 顶部弹幕样式
    out << "Style: Top,SimHei," << fontSize
        << ",&H" << alphaStr << "FFFFFF,&H" << alphaStr << "FFFFFF,&H" << alphaStr << "000000,&H" << alphaStr << "000000"
        << ",0,0,0,0,100,100,0,0,1," << outlineWidth << "," << (settings->outline() == 2 ? outlineWidth : 0)
        << ",8,0,0,0,1\n";

    // 底部弹幕样式
    out << "Style: Bottom,SimHei," << fontSize
        << ",&H" << alphaStr << "FFFFFF,&H" << alphaStr << "FFFFFF,&H" << alphaStr << "000000,&H" << alphaStr << "000000"
        << ",0,0,0,0,100,100,0,0,1," << outlineWidth << "," << (settings->outline() == 2 ? outlineWidth : 0)
        << ",2,0,0,0,1\n\n";

    out << "[Events]\n";
    out << "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n";

    // 轨道占用时间数组（存储该轨道上下一条弹幕可进入的最早时间）
    const int MAX_TRACKS = 100;
    int scrollTracks[MAX_TRACKS];
    int topTracks[MAX_TRACKS];
    int bottomTracks[MAX_TRACKS];

    for (int i = 0; i < MAX_TRACKS; ++i) {
        scrollTracks[i] = 0;
        topTracks[i] = 0;
        bottomTracks[i] = 0;
    }

    // 字符宽度估算：中文字符约等于字号，英文约为字号的一半
    // 这里用字号作为平均宽度（偏保守，宁可算宽一点避免重叠）
    int charWidth = fontSize;

    int totalCount = 0;
    int scrollCount = 0;
    int droppedCount = 0;

    for (const auto &item : sortedList) {
        // 根据设置过滤弹幕类型
        if (item.type == 1 || item.type == 2 || item.type == 3) {
            if (!settings->showScroll()) continue;
        } else if (item.type == 5) {
            if (!settings->showTop()) continue;
        } else if (item.type == 4) {
            if (!settings->showBottom()) continue;
        } else {
            continue;  // 其他类型跳过
        }

        totalCount++;

        QString tag;
        QString style;
        int itemDuration = baseDuration;

        if (item.type == 1 || item.type == 2 || item.type == 3) {
            // 滚动弹幕：从右到左匀速移动
            style = "Scroll";

            // 估算弹幕宽度（文字宽度 + 左右余量）
            int textWidth = item.text.length() * charWidth;
            int danmakuWidth = textWidth + 20;  // 左右各10px余量

            // 移动总距离 = 屏幕宽度 + 弹幕宽度 + 外扩距离
            int totalDistance = videoWidth + danmakuWidth + ENTER_MARGIN + EXIT_MARGIN;
            // 实际持续时间 = 总距离 / 速度
            itemDuration = (int)(totalDistance / scrollSpeed);
            if (itemDuration < 2000) itemDuration = 2000;

            // 轨道占用时间：当前弹幕尾部完全进入屏幕右边缘所需时间
            // = (danmakuWidth + ENTER_MARGIN) / speed
            // 即：下一条弹幕可以进入该轨道的最早时间
            int trackOccupied = (int)((danmakuWidth + ENTER_MARGIN) / scrollSpeed);
            // 加安全间隔，避免紧挨
            trackOccupied += 100;
            int trackFreeTime = (int)item.timestamp + trackOccupied;

            // 找到最早空闲的轨道（贪心：选最早可用的轨道，使弹幕分布更均匀）
            int bestLine = -1;
            int earliestFree = 0x7FFFFFFF;
            for (int i = 0; i < trackCount; ++i) {
                if (item.timestamp >= scrollTracks[i]) {
                    if (scrollTracks[i] < earliestFree) {
                        earliestFree = scrollTracks[i];
                        bestLine = i;
                    }
                }
            }

            // 如果找不到空闲轨道，跳过这条弹幕
            if (bestLine < 0) {
                droppedCount++;
                continue;
            }

            scrollTracks[bestLine] = trackFreeTime;
            scrollCount++;

            // 计算Y位置
            int startY = 10 + bestLine * danmakuHeight;

            // 移动起点和终点（与 itemDuration 精确匹配，确保速度恒定）
            int x1 = videoWidth + ENTER_MARGIN;
            int x2 = -danmakuWidth - EXIT_MARGIN;

            // 颜色标签
            QString colorTag;
            if (settings->showColor() && item.color.isValid() && item.color != QColor(255, 255, 255)) {
                int r = item.color.red();
                int g = item.color.green();
                int b = item.color.blue();
                colorTag = QString("{\\c&H%1%2%3%4}").arg(alphaStr).arg(b, 2, 16, QChar('0')).arg(g, 2, 16, QChar('0')).arg(r, 2, 16, QChar('0'));
            }

            tag = QString("{\\an8}{\\move(%1,%2,%3,%2)}%4")
                .arg(x1).arg(startY).arg(x2).arg(colorTag);

        } else if (item.type == 5) {
            // 顶部弹幕：居中静止
            style = "Top";

            int topAreaHeight = scrollAreaHeight / 4;
            int topTrackCount = topAreaHeight / danmakuHeight;
            if (topTrackCount < 2) topTrackCount = 2;
            if (topTrackCount > MAX_TRACKS) topTrackCount = MAX_TRACKS;

            int line = -1;
            for (int i = 0; i < topTrackCount; ++i) {
                if (item.timestamp >= topTracks[i]) {
                    line = i;
                    break;
                }
            }

            if (line < 0) {
                droppedCount++;
                continue;
            }

            topTracks[line] = (int)item.timestamp + baseDuration;

            int startY = 10 + line * danmakuHeight;

            QString colorTag;
            if (settings->showColor() && item.color.isValid() && item.color != QColor(255, 255, 255)) {
                int r = item.color.red();
                int g = item.color.green();
                int b = item.color.blue();
                colorTag = QString("{\\c&H%1%2%3%4}").arg(alphaStr).arg(b, 2, 16, QChar('0')).arg(g, 2, 16, QChar('0')).arg(r, 2, 16, QChar('0'));
            }

            tag = QString("{\\an8}{\\pos(%1,%2)}%3")
                .arg(videoWidth / 2).arg(startY).arg(colorTag);

        } else if (item.type == 4) {
            // 底部弹幕：居中静止
            style = "Bottom";

            int bottomTrackCount = scrollAreaHeight / danmakuHeight;
            if (bottomTrackCount < 1) bottomTrackCount = 1;
            if (bottomTrackCount > MAX_TRACKS) bottomTrackCount = MAX_TRACKS;

            int line = -1;
            for (int i = 0; i < bottomTrackCount; ++i) {
                if (item.timestamp >= bottomTracks[i]) {
                    line = i;
                    break;
                }
            }

            if (line < 0) {
                droppedCount++;
                continue;
            }

            bottomTracks[line] = (int)item.timestamp + baseDuration;

            int startY = scrollAreaHeight - 10 - line * danmakuHeight;

            QString colorTag;
            if (settings->showColor() && item.color.isValid() && item.color != QColor(255, 255, 255)) {
                int r = item.color.red();
                int g = item.color.green();
                int b = item.color.blue();
                colorTag = QString("{\\c&H%1%2%3%4}").arg(alphaStr).arg(b, 2, 16, QChar('0')).arg(g, 2, 16, QChar('0')).arg(r, 2, 16, QChar('0'));
            }

            tag = QString("{\\an2}{\\pos(%1,%2)}%3")
                .arg(videoWidth / 2).arg(startY).arg(colorTag);
        }

        // 处理弹幕文本转义
        QString text = item.text;
        text.replace("\\", "\\\\");
        text.replace("{", "\\{");
        text.replace("}", "\\}");
        text.replace("\n", "\\N");
        text.replace("\r", "");

        // 输出 ASS 格式弹幕
        out << "Dialogue: 0," << formatASS((int)item.timestamp) << ","
            << formatASS((int)item.timestamp + itemDuration) << "," << style
            << ",,0,0,0,," << tag << text << "\n";
    }

    return ass;
}
