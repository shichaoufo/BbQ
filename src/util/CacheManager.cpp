#include "CacheManager.h"
#include <QDir>
#include <QFile>
#include <QStandardPaths>

CacheManager* CacheManager::s_instance = nullptr;

CacheManager* CacheManager::instance()
{
    if (!s_instance) {
        s_instance = new CacheManager();
    }
    return s_instance;
}

CacheManager::CacheManager()
{
}

QString CacheManager::tempDirPath() const
{
    QString path = QStandardPaths::writableLocation(QStandardPaths::TempLocation);
    if (path.isEmpty()) {
        path = QDir::tempPath();
    }
    return path;
}

void CacheManager::cleanupAll()
{
    cleanupDanmakuFiles();
    cleanupVideoTempFiles();
}

void CacheManager::cleanupDanmakuFiles()
{
    cleanupByPrefix("bili_danmaku");
}

void CacheManager::cleanupVideoTempFiles()
{
    cleanupByPrefix("bili_video_");
}

void CacheManager::cleanupByPrefix(const QString &prefix)
{
    QString tempDir = tempDirPath();
    QDir dir(tempDir);
    if (!dir.exists()) {
        return;
    }

    QStringList filters;
    filters << prefix + "*";
    dir.setNameFilters(filters);

    QStringList files = dir.entryList(QDir::Files);
    int removedCount = 0;
    for (const QString &fileName : files) {
        QString filePath = dir.absoluteFilePath(fileName);
        if (QFile::remove(filePath)) {
            removedCount++;
        }
    }
}
