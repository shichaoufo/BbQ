#ifndef MPVOBJECT_H
#define MPVOBJECT_H

#include <QQuickFramebufferObject>
#include <QTimer>

struct mpv_handle;
struct mpv_render_context;

class MpvObject : public QQuickFramebufferObject
{
    Q_OBJECT
    Q_PROPERTY(QString source READ source WRITE setSource NOTIFY sourceChanged)
    Q_PROPERTY(QString audioSource READ audioSource WRITE setAudioSource NOTIFY audioSourceChanged)
    Q_PROPERTY(bool playing READ playing WRITE setPlaying NOTIFY playingChanged)
    Q_PROPERTY(int position READ position NOTIFY positionChanged)
    Q_PROPERTY(int duration READ duration NOTIFY durationChanged)
    Q_PROPERTY(qreal volume READ volume WRITE setVolume NOTIFY volumeChanged)
    Q_PROPERTY(qreal speed READ speed WRITE setSpeed NOTIFY speedChanged)
    Q_PROPERTY(bool hasVideo READ hasVideo NOTIFY hasVideoChanged)
    Q_PROPERTY(bool seekable READ seekable NOTIFY seekableChanged)

public:
    explicit MpvObject(QQuickItem *parent = nullptr);
    ~MpvObject();

    QString source() const;
    void setSource(const QString &source);

    QString audioSource() const;
    void setAudioSource(const QString &audioSource);

    bool playing() const;
    void setPlaying(bool playing);

    int position() const;
    int duration() const;

    qreal volume() const;
    void setVolume(qreal volume);

    qreal speed() const;
    void setSpeed(qreal speed);

    bool hasVideo() const;
    bool seekable() const;

    Q_INVOKABLE void play();
    Q_INVOKABLE void pause();
    Q_INVOKABLE void stop();
    Q_INVOKABLE void seek(int position);
    Q_INVOKABLE void updatePosition();
    // 获取实际播放的视频参数（宽、高、codec、fps、bitrate 等），用于验证当前流的真实画质
    Q_INVOKABLE QVariantMap getVideoInfo();

    Renderer *createRenderer() const override;

    mpv_handle *mpv() const { return m_mpv; }

signals:
    void sourceChanged();
    void audioSourceChanged();
    void playingChanged();
    void durationChanged();
    void positionChanged();
    void volumeChanged();
    void speedChanged();
    void hasVideoChanged();
    void seekableChanged();
    void errorOccurred(const QString &error);

protected:
    void geometryChange(const QRectF &newGeometry, const QRectF &oldGeometry) override;
    void itemChange(ItemChange change, const ItemChangeData &value) override;

private slots:
    void onMpvEvents();

private:
    void initMpv();
    void destroyMpv();
    void applyHttpHeaders();
    void loadFile(const QString &file);
    void startRenderTimer();
    void stopRenderTimer();

    mpv_handle *m_mpv = nullptr;
    mutable bool m_rendererWillDestroyMpv = false;

    QString m_source;
    QString m_audioSource;
    bool m_playing = false;
    bool m_desiredPlaying = true;  // 加载新文件后是否自动播放
    int m_position = 0;
    int m_duration = 0;
    qreal m_volume = 1.0;
    qreal m_speed = 1.0;
    bool m_hasVideo = false;
    bool m_seekable = false;
    bool m_paused = true;
    QQuickWindow *m_window = nullptr;
    QTimer *m_renderTimer = nullptr;
};

#endif // MPVOBJECT_H
