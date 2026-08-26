#ifndef DANMAKUSETTINGS_H
#define DANMAKUSETTINGS_H

#include <QObject>
#include <QSettings>
#include <QColor>

class DanmakuSettings : public QObject
{
    Q_OBJECT

public:
    static DanmakuSettings* instance();

    // 弹幕大小 (0-100, 默认50)
    int fontSize() const { return m_fontSize; }
    void setFontSize(int size);

    // 弹幕透明度 (0-100, 默认100表示完全不透明)
    int opacity() const { return m_opacity; }
    void setOpacity(int opacity);

    // 是否显示滚动弹幕 (默认true)
    bool showScroll() const { return m_showScroll; }
    void setShowScroll(bool show);

    // 是否显示顶部弹幕 (默认true)
    bool showTop() const { return m_showTop; }
    void setShowTop(bool show);

    // 是否显示底部弹幕 (默认true)
    bool showBottom() const { return m_showBottom; }
    void setShowBottom(bool show);

    // 弹幕速度 (0=慢, 1=中, 2=快, 默认1)
    int speed() const { return m_speed; }
    void setSpeed(int speed);

    // 弹幕区域 (0-100, 默认100表示全区域)
    int area() const { return m_area; }
    void setArea(int area);

    // 弹幕描边 (0=无, 1=描边, 2=阴影, 默认1)
    int outline() const { return m_outline; }
    void setOutline(int outline);

    // 是否显示颜色弹幕 (默认true)
    bool showColor() const { return m_showColor; }
    void setShowColor(bool show);

    // 是否启用弹幕 (默认true)
    bool enabled() const { return m_enabled; }
    void setEnabled(bool enabled);

    // 获取弹幕显示时长(毫秒)，根据速度设置
    int getDisplayDuration() const;

    // 保存设置到文件
    void save();

    // 从文件加载设置
    void load();

signals:
    void settingsChanged();

private:
    explicit DanmakuSettings(QObject *parent = nullptr);
    ~DanmakuSettings();
    DanmakuSettings(const DanmakuSettings&) = delete;
    DanmakuSettings& operator=(const DanmakuSettings&) = delete;

    int m_fontSize;       // 字体大小 (0-100)
    int m_opacity;        // 透明度 (0-100)
    bool m_showScroll;    // 显示滚动弹幕
    bool m_showTop;       // 显示顶部弹幕
    bool m_showBottom;    // 显示底部弹幕
    int m_speed;          // 速度 0=慢, 1=中, 2=快
    int m_area;           // 显示区域 0-100
    int m_outline;        // 描边样式 0=无, 1=描边, 2=阴影
    bool m_showColor;     // 显示颜色
    bool m_enabled;       // 启用弹幕
};

#endif // DANMAKUSETTINGS_H
