#include "VideoModel.h"
#include <QJsonObject>
#include <QDateTime>

VideoModel::VideoModel()
{
}

VideoModel::~VideoModel()
{
}

VideoInfo VideoModel::fromJson(const QJsonObject &obj)
{
    VideoInfo info;
    
    if (obj.contains("aid")) {
        info.aid = QString::number(obj["aid"].toVariant().toLongLong());
    }
    if (obj.contains("bvid")) {
        info.bvid = obj["bvid"].toString();
    }
    if (obj.contains("title")) {
        info.title = obj["title"].toString();
    }
    if (obj.contains("pic")) {
        info.pic = obj["pic"].toString();
    }
    if (obj.contains("duration")) {
        int duration = obj["duration"].toInt();
        int minutes = duration / 60;
        int seconds = duration % 60;
        info.duration = QString("%1:%2").arg(minutes).arg(seconds, 2, 10, QChar('0'));
    }
    if (obj.contains("stat")) {
        QJsonObject stat = obj["stat"].toObject();
        if (stat.contains("view")) {
            long long view = stat["view"].toVariant().toLongLong();
            if (view >= 10000) {
                info.viewCount = QString::number(view / 10000.0, 'f', 1) + "万";
            } else {
                info.viewCount = QString::number(view);
            }
        }
        if (stat.contains("danmaku")) {
            long long danmaku = stat["danmaku"].toVariant().toLongLong();
            if (danmaku >= 10000) {
                info.danmakuCount = QString::number(danmaku / 10000.0, 'f', 1) + "万";
            } else {
                info.danmakuCount = QString::number(danmaku);
            }
        }
    }
    // 搜索 API 兼容：play/VideoReview 字段
    if (info.viewCount.isEmpty() && obj.contains("play")) {
        long long view = obj["play"].toVariant().toLongLong();
        if (view >= 10000) {
            info.viewCount = QString::number(view / 10000.0, 'f', 1) + "万";
        } else {
            info.viewCount = QString::number(view);
        }
    }
    if (info.danmakuCount.isEmpty() && obj.contains("video_review")) {
        long long danmaku = obj["video_review"].toVariant().toLongLong();
        if (danmaku >= 10000) {
            info.danmakuCount = QString::number(danmaku / 10000.0, 'f', 1) + "万";
        } else {
            info.danmakuCount = QString::number(danmaku);
        }
    }
    // 搜索 API 的时长字段是字符串格式（mm:ss），需要单独处理
    if (info.duration.isEmpty() && obj.contains("duration")) {
        info.duration = obj["duration"].toString();
    }
    if (obj.contains("owner")) {
        QJsonObject owner = obj["owner"].toObject();
        if (owner.contains("name")) {
            info.authorName = owner["name"].toString();
        }
        if (owner.contains("mid")) {
            info.authorMid = QString::number(owner["mid"].toVariant().toLongLong());
        }
        if (owner.contains("face")) {
            info.authorFace = owner["face"].toString();
        }
    }
    // 搜索 API 兼容：author/mid 字段
    if (info.authorName.isEmpty() && obj.contains("author")) {
        info.authorName = obj["author"].toString();
    }
    if (info.authorMid.isEmpty() && obj.contains("mid")) {
        info.authorMid = QString::number(obj["mid"].toVariant().toLongLong());
    }
    if (obj.contains("pubdate")) {
        // B站API返回的pubdate是Unix时间戳（秒）
        qint64 pubTimestamp = obj["pubdate"].toVariant().toLongLong();
        if (pubTimestamp > 0) {
            QDateTime pubDateTime = QDateTime::fromSecsSinceEpoch(pubTimestamp);
            QDateTime now = QDateTime::currentDateTime();
            qint64 daysAgo = pubDateTime.daysTo(now);

            if (daysAgo < 1) {
                // 今天
                info.pubDate = "今天";
            } else if (daysAgo < 7) {
                // 一周内
                info.pubDate = QString("%1天前").arg(daysAgo);
            } else if (daysAgo < 30) {
                info.pubDate = QString("%1周前").arg(daysAgo / 7);
            } else if (daysAgo < 365) {
                info.pubDate = QString("%1月前").arg(daysAgo / 30);
            } else {
                info.pubDate = QString("%1年前").arg(daysAgo / 365);
            }
        }
    }
    // 兼容一些API可能用 ctime/pub_time 字段
    if (info.pubDate.isEmpty() && obj.contains("ctime")) {
        qint64 pubTimestamp = obj["ctime"].toVariant().toLongLong();
        if (pubTimestamp > 0) {
            QDateTime pubDateTime = QDateTime::fromSecsSinceEpoch(pubTimestamp);
            QDateTime now = QDateTime::currentDateTime();
            qint64 daysAgo = pubDateTime.daysTo(now);
            if (daysAgo < 1) info.pubDate = "今天";
            else if (daysAgo < 7) info.pubDate = QString("%1天前").arg(daysAgo);
            else if (daysAgo < 30) info.pubDate = QString("%1周前").arg(daysAgo / 7);
            else if (daysAgo < 365) info.pubDate = QString("%1月前").arg(daysAgo / 30);
            else info.pubDate = QString("%1年前").arg(daysAgo / 365);
        }
    }

    return info;
}
