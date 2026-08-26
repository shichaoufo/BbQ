#ifndef WBISIGNER_H
#define WBISIGNER_H

#include <QString>

class WbiSigner
{
public:
    static WbiSigner* instance();
    
    QString signParams(const QString& params);
    
    bool fetchKeysSync();
    
    void forceRefreshKeys();
    
private:
    WbiSigner();
    
    QString extractKeyFromUrl(const QString& url);
    QString getMixinKey(const QString& imgKey, const QString& subKey);
    
    QString m_mixinKey;
    qint64 m_lastUpdateTime;
    
    static const int MIXIN_KEY_ENC_TAB[64];
};

#endif // WBISIGNER_H
