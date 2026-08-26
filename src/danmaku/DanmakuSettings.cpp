#include "DanmakuSettings.h"

static DanmakuSettings* s_danmakuSettingsInstance = nullptr;

DanmakuSettings* DanmakuSettings::instance()
{
    if (!s_danmakuSettingsInstance) {
        s_danmakuSettingsInstance = new DanmakuSettings();
    }
    return s_danmakuSettingsInstance;
}

DanmakuSettings::DanmakuSettings(QObject *parent)
    : QObject(parent)
    , m_fontSize(50)
    , m_opacity(100)
    , m_showScroll(true)
    , m_showTop(true)
    , m_showBottom(true)
    , m_speed(1)
    , m_area(100)
    , m_outline(1)
    , m_showColor(true)
    , m_enabled(true)
{
    load();
}

DanmakuSettings::~DanmakuSettings()
{
}

void DanmakuSettings::setFontSize(int size)
{
    if (size < 0) size = 0;
    if (size > 100) size = 100;
    if (m_fontSize != size) {
        m_fontSize = size;
        emit settingsChanged();
    }
}

void DanmakuSettings::setOpacity(int opacity)
{
    if (opacity < 0) opacity = 0;
    if (opacity > 100) opacity = 100;
    if (m_opacity != opacity) {
        m_opacity = opacity;
        emit settingsChanged();
    }
}

void DanmakuSettings::setShowScroll(bool show)
{
    if (m_showScroll != show) {
        m_showScroll = show;
        emit settingsChanged();
    }
}

void DanmakuSettings::setShowTop(bool show)
{
    if (m_showTop != show) {
        m_showTop = show;
        emit settingsChanged();
    }
}

void DanmakuSettings::setShowBottom(bool show)
{
    if (m_showBottom != show) {
        m_showBottom = show;
        emit settingsChanged();
    }
}

void DanmakuSettings::setSpeed(int speed)
{
    if (speed < 0) speed = 0;
    if (speed > 2) speed = 2;
    if (m_speed != speed) {
        m_speed = speed;
        emit settingsChanged();
    }
}

void DanmakuSettings::setArea(int area)
{
    if (area < 0) area = 0;
    if (area > 100) area = 100;
    if (m_area != area) {
        m_area = area;
        emit settingsChanged();
    }
}

void DanmakuSettings::setOutline(int outline)
{
    if (outline < 0) outline = 0;
    if (outline > 2) outline = 2;
    if (m_outline != outline) {
        m_outline = outline;
        emit settingsChanged();
    }
}

void DanmakuSettings::setShowColor(bool show)
{
    if (m_showColor != show) {
        m_showColor = show;
        emit settingsChanged();
    }
}

void DanmakuSettings::setEnabled(bool enabled)
{
    if (m_enabled != enabled) {
        m_enabled = enabled;
        emit settingsChanged();
    }
}

int DanmakuSettings::getDisplayDuration() const
{
    // 根据速度返回显示时长(毫秒)
    // 速度0=慢: 10秒, 速度1=中: 7秒, 速度2=快: 5秒
    switch (m_speed) {
        case 0: return 10000;
        case 1: return 7000;
        case 2: return 5000;
        default: return 7000;
    }
}

void DanmakuSettings::save()
{
    QSettings settings("BiliQt", "DanmakuSettings");
    settings.beginGroup("Danmaku");
    settings.setValue("fontSize", m_fontSize);
    settings.setValue("opacity", m_opacity);
    settings.setValue("showScroll", m_showScroll);
    settings.setValue("showTop", m_showTop);
    settings.setValue("showBottom", m_showBottom);
    settings.setValue("speed", m_speed);
    settings.setValue("area", m_area);
    settings.setValue("outline", m_outline);
    settings.setValue("showColor", m_showColor);
    settings.setValue("enabled", m_enabled);
    settings.endGroup();
}

void DanmakuSettings::load()
{
    QSettings settings("BiliQt", "DanmakuSettings");
    settings.beginGroup("Danmaku");
    m_fontSize = settings.value("fontSize", 50).toInt();
    m_opacity = settings.value("opacity", 100).toInt();
    m_showScroll = settings.value("showScroll", true).toBool();
    m_showTop = settings.value("showTop", true).toBool();
    m_showBottom = settings.value("showBottom", true).toBool();
    m_speed = settings.value("speed", 1).toInt();
    m_area = settings.value("area", 100).toInt();
    m_outline = settings.value("outline", 1).toInt();
    m_showColor = settings.value("showColor", true).toBool();
    m_enabled = settings.value("enabled", true).toBool();
    settings.endGroup();
}
