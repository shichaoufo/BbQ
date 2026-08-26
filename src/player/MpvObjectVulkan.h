#ifndef MPVOBJECTVULKAN_H
#define MPVOBJECTVULKAN_H

#include <QQuickItem>
#include <QTimer>
#include <QVariant>

#include <private/qrhi_p.h>

struct mpv_handle;
struct mpv_render_context;

struct ID3D11Device;
struct ID3D11DeviceContext;
struct ID3D11Texture2D;

QT_BEGIN_NAMESPACE
class QSGTexture;
class QQuickWindow;
QT_END_NAMESPACE

class MpvObjectVulkan : public QQuickItem
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
    explicit MpvObjectVulkan(QQuickItem *parent = nullptr);
    ~MpvObjectVulkan();

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
    Q_INVOKABLE QVariantMap getVideoInfo();

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
    QSGNode *updatePaintNode(QSGNode *oldNode, UpdatePaintNodeData *data) override;

private slots:
    void onMpvEvents();

private:
    void initMpv();
    void applyHttpHeaders();
    void loadFile(const QString &file);
    void startRenderTimer();
    void stopRenderTimer();

    bool ensureD3D11Resources();
    void releaseD3D11Resources();
    bool ensureStagingResources();
    void renderMpv();
    void uploadToVulkan();

    mpv_handle *m_mpv = nullptr;
    mpv_render_context *m_mpvRender = nullptr;

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

    // mpv 用 D3D11 render API 渲染到该纹理（与 Qt RHI 后端解耦）。
    ID3D11Device *m_d3d11Device = nullptr;
    ID3D11DeviceContext *m_d3d11Context = nullptr;
    ID3D11Texture2D *m_d3d11Texture = nullptr;
    ID3D11Texture2D *m_stagingTexture = nullptr;
    QSize m_textureSize;
    bool m_resourcesDirty = true;

    // 每帧把 D3D11 纹理回读到 CPU，再上传到 QRhiTexture（Vulkan）。
    QByteArray m_pixelBuffer;
    QRhiTexture *m_qrhiTexture = nullptr;
    QSGTexture *m_qsgTexture = nullptr;
    bool m_textureUploaded = false;
};

#endif // MPVOBJECTVULKAN_H
