#ifndef APP_SETTINGS_H
#define APP_SETTINGS_H

#include <QObject>
#include <QSettings>

class AppSettings : public QObject
{
    Q_OBJECT

public:
    explicit AppSettings(QObject *parent = nullptr);
    ~AppSettings();

    static AppSettings* instance();

    Q_INVOKABLE QString getString(const QString &key, const QString &defaultValue = QString());
    Q_INVOKABLE void setString(const QString &key, const QString &value);

    Q_INVOKABLE int getInt(const QString &key, int defaultValue = 0);
    Q_INVOKABLE void setInt(const QString &key, int value);

    Q_INVOKABLE double getReal(const QString &key, double defaultValue = 0.0);
    Q_INVOKABLE void setReal(const QString &key, double value);

    Q_INVOKABLE bool getBool(const QString &key, bool defaultValue = false);
    Q_INVOKABLE void setBool(const QString &key, bool value);

    Q_INVOKABLE void remove(const QString &key);
    Q_INVOKABLE bool contains(const QString &key);

    // 播放器相关设置
    Q_INVOKABLE int videoCodec();
    Q_INVOKABLE int getCodecFnval(int codec);
    Q_INVOKABLE int defaultQuality();

private:
    static AppSettings *s_instance;
    QSettings *m_settings;
};

#endif
