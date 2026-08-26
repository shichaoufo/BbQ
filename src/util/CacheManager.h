#ifndef CACHEMANAGER_H
#define CACHEMANAGER_H

#include <QString>

class CacheManager
{
public:
    static CacheManager* instance();

    void cleanupAll();
    void cleanupDanmakuFiles();
    void cleanupVideoTempFiles();
    void cleanupByPrefix(const QString &prefix);

private:
    CacheManager();
    static CacheManager *s_instance;

    QString tempDirPath() const;
};

#endif
