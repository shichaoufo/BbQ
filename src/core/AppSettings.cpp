#include "AppSettings.h"

AppSettings* AppSettings::s_instance = nullptr;

AppSettings::AppSettings(QObject *parent)
    : QObject(parent)
{
    m_settings = new QSettings("BiliQt", "BiliQtQuick", this);
    s_instance = this;
}

AppSettings::~AppSettings() = default;

AppSettings* AppSettings::instance()
{
    return s_instance;
}

QString AppSettings::getString(const QString &key, const QString &defaultValue)
{
    return m_settings->value(key, defaultValue).toString();
}

void AppSettings::setString(const QString &key, const QString &value)
{
    m_settings->setValue(key, value);
    m_settings->sync();
}

int AppSettings::getInt(const QString &key, int defaultValue)
{
    return m_settings->value(key, defaultValue).toInt();
}

void AppSettings::setInt(const QString &key, int value)
{
    m_settings->setValue(key, value);
    m_settings->sync();
}

double AppSettings::getReal(const QString &key, double defaultValue)
{
    return m_settings->value(key, defaultValue).toDouble();
}

void AppSettings::setReal(const QString &key, double value)
{
    m_settings->setValue(key, value);
    m_settings->sync();
}

bool AppSettings::getBool(const QString &key, bool defaultValue)
{
    return m_settings->value(key, defaultValue).toBool();
}

void AppSettings::setBool(const QString &key, bool value)
{
    m_settings->setValue(key, value);
    m_settings->sync();
}

void AppSettings::remove(const QString &key)
{
    m_settings->remove(key);
}

bool AppSettings::contains(const QString &key)
{
    return m_settings->contains(key);
}

int AppSettings::videoCodec()
{
    // 0: H.264, 1: H.265, 2: AV1
    return m_settings->value("videoCodec", 0).toInt();
}

int AppSettings::getCodecFnval(int codec)
{
    Q_UNUSED(codec)
    // 请求 DASH 格式，并声明支持 4K/8K/HDR/AV1 等能力
    // 服务器会返回所有可用流，由 PlayUrlManager 按 videoCodec 筛选
    return 4048;
}

int AppSettings::defaultQuality()
{
    // 默认 1080P
    return m_settings->value("defaultQuality", 80).toInt();
}
