#ifndef VIDEOMODEL_H
#define VIDEOMODEL_H

#include <QString>
#include <QStringList>
#include <QJsonObject>

struct VideoInfo
{
    QString aid;
    QString bvid;
    QString title;
    QString pic;
    QString duration;
    QString viewCount;
    QString danmakuCount;
    QString authorName;
    QString authorMid;
    QString authorFace;  // UP主头像URL
    QString pubDate;     // 发布日期字符串
};

class VideoModel
{
public:
    VideoModel();
    ~VideoModel();

    static VideoInfo fromJson(const QJsonObject &obj);
};

#endif // VIDEOMODEL_H
