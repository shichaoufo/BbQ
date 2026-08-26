#ifndefGITHUB DANMAK#ifndefGITHUB DANMAKUIMAGEPROVIDER_H
#define DANMAK#ifndefGITHUB DANMAKUIMAGEPROVIDER_H
#define DANMAKUIMAGEPROVIDER_H

#include <QQuick#ifndefGITHUB DANMAKUIMAGEPROVIDER_H
#define DANMAKUIMAGEPROVIDER_H

#include <QQuickImageProvider>
#include <QHash>
#include#ifndefGITHUB DANMAKUIMAGEPROVIDER_H
#define DANMAKUIMAGEPROVIDER_H

#include <QQuickImageProvider>
#include <QHash>
#include <QImage>
#include <QMutex>

// 弹#ifndefGITHUB DANMAKUIMAGEPROVIDER_H
#define DANMAKUIMAGEPROVIDER_H

#include <QQuickImageProvider>
#include <QHash>
#include <QImage>
#include <QMutex>

// 弹幕文字预光栅化 Provider
// 将弹#ifndefGITHUB DANMAKUIMAGEPROVIDER_H
#define DANMAKUIMAGEPROVIDER_H

#include <QQuickImageProvider>
#include <QHash>
#include <QImage>
#include <QMutex>

// 弹幕文字预光栅化 Provider
// 将弹幕文字用 QPainter（CPU）渲染为带#ifndefGITHUB DANMAKUIMAGEPROVIDER_H
#define DANMAKUIMAGEPROVIDER_H

#include <QQuickImageProvider>
#include <QHash>
#include <QImage>
#include <QMutex>

// 弹幕文字预光栅化 Provider
// 将弹幕文字用 QPainter（CPU）渲染为带描边的 QImage，并缓存。
// QML#ifndefGITHUB DANMAKUIMAGEPROVIDER_H
#define DANMAKUIMAGEPROVIDER_H

#include <QQuickImageProvider>
#include <QHash>
#include <QImage>
#include <QMutex>

// 弹幕文字预光栅化 Provider
// 将弹幕文字用 QPainter（CPU）渲染为带描边的 QImage，并缓存。
// QML 侧用 Image 代替 Text，每帧只做#ifndefGITHUB DANMAKUIMAGEPROVIDER_H
#define DANMAKUIMAGEPROVIDER_H

#include <QQuickImageProvider>
#include <QHash>
#include <QImage>
#include <QMutex>

// 弹幕文字预光栅化 Provider
// 将弹幕文字用 QPainter（CPU）渲染为带描边的 QImage，并缓存。
// QML 侧用 Image 代替 Text，每帧只做 GPU 纹理 blit，避免每帧重新#ifndefGITHUB DANMAKUIMAGEPROVIDER_H
#define DANMAKUIMAGEPROVIDER_H

#include <QQuickImageProvider>
#include <QHash>
#include <QImage>
#include <QMutex>

// 弹幕文字预光栅化 Provider
// 将弹幕文字用 QPainter（CPU）渲染为带描边的 QImage，并缓存。
// QML 侧用 Image 代替 Text，每帧只做 GPU 纹理 blit，避免每帧重新光栅化文字。
class DanmakuImage#ifndefGITHUB DANMAKUIMAGEPROVIDER_H
#define DANMAKUIMAGEPROVIDER_H

#include <QQuickImageProvider>
#include <QHash>
#include <QImage>
#include <QMutex>

// 弹幕文字预光栅化 Provider
// 将弹幕文字用 QPainter（CPU）渲染为带描边的 QImage，并缓存。
// QML 侧用 Image 代替 Text，每帧只做 GPU 纹理 blit，避免每帧重新光栅化文字。
class DanmakuImageProvider : public QQuickImageProvider
{
public:#ifndefGITHUB DANMAKUIMAGEPROVIDER_H
#define DANMAKUIMAGEPROVIDER_H

#include <QQuickImageProvider>
#include <QHash>
#include <QImage>
#include <QMutex>

// 弹幕文字预光栅化 Provider
// 将弹幕文字用 QPainter（CPU）渲染为带描边的 QImage，并缓存。
// QML 侧用 Image 代替 Text，每帧只做 GPU 纹理 blit，避免每帧重新光栅化文字。
class DanmakuImageProvider : public QQuickImageProvider
{
public:
    DanmakuImageProvider();

    QImage requestImage(const#ifndefGITHUB DANMAKUIMAGEPROVIDER_H
#define DANMAKUIMAGEPROVIDER_H

#include <QQuickImageProvider>
#include <QHash>
#include <QImage>
#include <QMutex>

// 弹幕文字预光栅化 Provider
// 将弹幕文字用 QPainter（CPU）渲染为带描边的 QImage，并缓存。
// QML 侧用 Image 代替 Text，每帧只做 GPU 纹理 blit，避免每帧重新光栅化文字。
class DanmakuImageProvider : public QQuickImageProvider
{
public:
    DanmakuImageProvider();

    QImage requestImage(const QString &id, QSize *size, const QSize#ifndefGITHUB DANMAKUIMAGEPROVIDER_H
#define DANMAKUIMAGEPROVIDER_H

#include <QQuickImageProvider>
#include <QHash>
#include <QImage>
#include <QMutex>

// 弹幕文字预光栅化 Provider
// 将弹幕文字用 QPainter（CPU）渲染为带描边的 QImage，并缓存。
// QML 侧用 Image 代替 Text，每帧只做 GPU 纹理 blit，避免每帧重新光栅化文字。
class DanmakuImageProvider : public QQuickImageProvider
{
public:
    DanmakuImageProvider();

    QImage requestImage(const QString &id, QSize *size, const QSize &requestedSize) override;

    // id 格式#ifndefGITHUB DANMAKUIMAGEPROVIDER_H
#define DANMAKUIMAGEPROVIDER_H

#include <QQuickImageProvider>
#include <QHash>
#include <QImage>
#include <QMutex>

// 弹幕文字预光栅化 Provider
// 将弹幕文字用 QPainter（CPU）渲染为带描边的 QImage，并缓存。
// QML 侧用 Image 代替 Text，每帧只做 GPU 纹理 blit，避免每帧重新光栅化文字。
class DanmakuImageProvider : public QQuickImageProvider
{
public:
    DanmakuImageProvider();

    QImage requestImage(const QString &id, QSize *size, const QSize &requestedSize) override;

    // id 格式: "fontSize|color|text"，由 Q#ifndefGITHUB DANMAKUIMAGEPROVIDER_H
#define DANMAKUIMAGEPROVIDER_H

#include <QQuickImageProvider>
#include <QHash>
#include <QImage>
#include <QMutex>

// 弹幕文字预光栅化 Provider
// 将弹幕文字用 QPainter（CPU）渲染为带描边的 QImage，并缓存。
// QML 侧用 Image 代替 Text，每帧只做 GPU 纹理 blit，避免每帧重新光栅化文字。
class DanmakuImageProvider : public QQuickImageProvider
{
public:
    DanmakuImageProvider();

    QImage requestImage(const QString &id, QSize *size, const QSize &requestedSize) override;

    // id 格式: "fontSize|color|text"，由 QML 侧拼好后传入
    // 例如: "28#ifndefGITHUB DANMAKUIMAGEPROVIDER_H
#define DANMAKUIMAGEPROVIDER_H

#include <QQuickImageProvider>
#include <QHash>
#include <QImage>
#include <QMutex>

// 弹幕文字预光栅化 Provider
// 将弹幕文字用 QPainter（CPU）渲染为带描边的 QImage，并缓存。
// QML 侧用 Image 代替 Text，每帧只做 GPU 纹理 blit，避免每帧重新光栅化文字。
class DanmakuImageProvider : public QQuickImageProvider
{
public:
    DanmakuImageProvider();

    QImage requestImage(const QString &id, QSize *size, const QSize &requestedSize) override;

    // id 格式: "fontSize|color|text"，由 QML 侧拼好后传入
    // 例如: "28|#ffffff|你好世界"

private:
    struct Cache#ifndefGITHUB DANMAKUIMAGEPROVIDER_H
#define DANMAKUIMAGEPROVIDER_H

#include <QQuickImageProvider>
#include <QHash>
#include <QImage>
#include <QMutex>

// 弹幕文字预光栅化 Provider
// 将弹幕文字用 QPainter（CPU）渲染为带描边的 QImage，并缓存。
// QML 侧用 Image 代替 Text，每帧只做 GPU 纹理 blit，避免每帧重新光栅化文字。
class DanmakuImageProvider : public QQuickImageProvider
{
public:
    DanmakuImageProvider();

    QImage requestImage(const QString &id, QSize *size, const QSize &requestedSize) override;

    // id 格式: "fontSize|color|text"，由 QML 侧拼好后传入
    // 例如: "28|#ffffff|你好世界"

private:
    struct CacheKey {
        int fontSize;
        QString color;
        QString text#ifndefGITHUB DANMAKUIMAGEPROVIDER_H
#define DANMAKUIMAGEPROVIDER_H

#include <QQuickImageProvider>
#include <QHash>
#include <QImage>
#include <QMutex>

// 弹幕文字预光栅化 Provider
// 将弹幕文字用 QPainter（CPU）渲染为带描边的 QImage，并缓存。
// QML 侧用 Image 代替 Text，每帧只做 GPU 纹理 blit，避免每帧重新光栅化文字。
class DanmakuImageProvider : public QQuickImageProvider
{
public:
    DanmakuImageProvider();

    QImage requestImage(const QString &id, QSize *size, const QSize &requestedSize) override;

    // id 格式: "fontSize|color|text"，由 QML 侧拼好后传入
    // 例如: "28|#ffffff|你好世界"

private:
    struct CacheKey {
        int fontSize;
        QString color;
        QString text;
        bool operator==(const CacheKey &other)#ifndefGITHUB DANMAKUIMAGEPROVIDER_H
#define DANMAKUIMAGEPROVIDER_H

#include <QQuickImageProvider>
#include <QHash>
#include <QImage>
#include <QMutex>

// 弹幕文字预光栅化 Provider
// 将弹幕文字用 QPainter（CPU）渲染为带描边的 QImage，并缓存。
// QML 侧用 Image 代替 Text，每帧只做 GPU 纹理 blit，避免每帧重新光栅化文字。
class DanmakuImageProvider : public QQuickImageProvider
{
public:
    DanmakuImageProvider();

    QImage requestImage(const QString &id, QSize *size, const QSize &requestedSize) override;

    // id 格式: "fontSize|color|text"，由 QML 侧拼好后传入
    // 例如: "28|#ffffff|你好世界"

private:
    struct CacheKey {
        int fontSize;
        QString color;
        QString text;
        bool operator==(const CacheKey &other) const {
            return fontSize == other.fontSize && color ==#ifndefGITHUB DANMAKUIMAGEPROVIDER_H
#define DANMAKUIMAGEPROVIDER_H

#include <QQuickImageProvider>
#include <QHash>
#include <QImage>
#include <QMutex>

// 弹幕文字预光栅化 Provider
// 将弹幕文字用 QPainter（CPU）渲染为带描边的 QImage，并缓存。
// QML 侧用 Image 代替 Text，每帧只做 GPU 纹理 blit，避免每帧重新光栅化文字。
class DanmakuImageProvider : public QQuickImageProvider
{
public:
    DanmakuImageProvider();

    QImage requestImage(const QString &id, QSize *size, const QSize &requestedSize) override;

    // id 格式: "fontSize|color|text"，由 QML 侧拼好后传入
    // 例如: "28|#ffffff|你好世界"

private:
    struct CacheKey {
        int fontSize;
        QString color;
        QString text;
        bool operator==(const CacheKey &other) const {
            return fontSize == other.fontSize && color == other.color && text == other.text;
        }
    };#ifndef DANMAKUIMAGEPROVIDER#ifndef DANMAKUIMAGEPROVIDER_H
#define DANMAKUIMAGEPROVIDER#ifndef DANMAKUIMAGEPROVIDER_H
#define DANMAKUIMAGEPROVIDER_H

#include <QQuickImageProvider>
#include#ifndef DANMAKUIMAGEPROVIDER_H
#define DANMAKUIMAGEPROVIDER_H

#include <QQuickImageProvider>
#include <QHash>
#include <QImage>
#include#ifndef DANMAKUIMAGEPROVIDER_H
#define DANMAKUIMAGEPROVIDER_H

#include <QQuickImageProvider>
#include <QHash>
#include <QImage>
#include <QMutex>

// 弹幕文字预光栅#ifndef DANMAKUIMAGEPROVIDER_H
#define DANMAKUIMAGEPROVIDER_H

#include <QQuickImageProvider>
#include <QHash>
#include <QImage>
#include <QMutex>

// 弹幕文字预光栅化 Provider
// 将弹幕文字用 QPainter（#ifndef DANMAKUIMAGEPROVIDER_H
#define DANMAKUIMAGEPROVIDER_H

#include <QQuickImageProvider>
#include <QHash>
#include <QImage>
#include <QMutex>

// 弹幕文字预光栅化 Provider
// 将弹幕文字用 QPainter（CPU）渲染为带描边的 QImage，并#ifndef DANMAKUIMAGEPROVIDER_H
#define DANMAKUIMAGEPROVIDER_H

#include <QQuickImageProvider>
#include <QHash>
#include <QImage>
#include <QMutex>

// 弹幕文字预光栅化 Provider
// 将弹幕文字用 QPainter（CPU）渲染为带描边的 QImage，并缓存。
// QML 侧用 Image 代替 Text#ifndef DANMAKUIMAGEPROVIDER_H
#define DANMAKUIMAGEPROVIDER_H

#include <QQuickImageProvider>
#include <QHash>
#include <QImage>
#include <QMutex>

// 弹幕文字预光栅化 Provider
// 将弹幕文字用 QPainter（CPU）渲染为带描边的 QImage，并缓存。
// QML 侧用 Image 代替 Text，每帧只做 GPU 纹理 blit#ifndef DANMAKUIMAGEPROVIDER_H
#define DANMAKUIMAGEPROVIDER_H

#include <QQuickImageProvider>
#include <QHash>
#include <QImage>
#include <QMutex>

// 弹幕文字预光栅化 Provider
// 将弹幕文字用 QPainter（CPU）渲染为带描边的 QImage，并缓存。
// QML 侧用 Image 代替 Text，每帧只做 GPU 纹理 blit，避免每帧重新光栅化文字。#ifndef DANMAKUIMAGEPROVIDER_H
#define DANMAKUIMAGEPROVIDER_H

#include <QQuickImageProvider>
#include <QHash>
#include <QImage>
#include <QMutex>

// 弹幕文字预光栅化 Provider
// 将弹幕文字用 QPainter（CPU）渲染为带描边的 QImage，并缓存。
// QML 侧用 Image 代替 Text，每帧只做 GPU 纹理 blit，避免每帧重新光栅化文字。
class DanmakuImageProvider : public QQuick#ifndef DANMAKUIMAGEPROVIDER_H
#define DANMAKUIMAGEPROVIDER_H

#include <QQuickImageProvider>
#include <QHash>
#include <QImage>
#include <QMutex>

// 弹幕文字预光栅化 Provider
// 将弹幕文字用 QPainter（CPU）渲染为带描边的 QImage，并缓存。
// QML 侧用 Image 代替 Text，每帧只做 GPU 纹理 blit，避免每帧重新光栅化文字。
class DanmakuImageProvider : public QQuickImageProvider
{
public:
    DanmakuImageProvider#ifndef DANMAKUIMAGEPROVIDER_H
#define DANMAKUIMAGEPROVIDER_H

#include <QQuickImageProvider>
#include <QHash>
#include <QImage>
#include <QMutex>

// 弹幕文字预光栅化 Provider
// 将弹幕文字用 QPainter（CPU）渲染为带描边的 QImage，并缓存。
// QML 侧用 Image 代替 Text，每帧只做 GPU 纹理 blit，避免每帧重新光栅化文字。
class DanmakuImageProvider : public QQuickImageProvider
{
public:
    DanmakuImageProvider();

    QImage requestImage(const QString &id, QSize#ifndef DANMAKUIMAGEPROVIDER_H
#define DANMAKUIMAGEPROVIDER_H

#include <QQuickImageProvider>
#include <QHash>
#include <QImage>
#include <QMutex>

// 弹幕文字预光栅化 Provider
// 将弹幕文字用 QPainter（CPU）渲染为带描边的 QImage，并缓存。
// QML 侧用 Image 代替 Text，每帧只做 GPU 纹理 blit，避免每帧重新光栅化文字。
class DanmakuImageProvider : public QQuickImageProvider
{
public:
    DanmakuImageProvider();

    QImage requestImage(const QString &id, QSize *size, const QSize &requestedSize) override#ifndef DANMAKUIMAGEPROVIDER_H
#define DANMAKUIMAGEPROVIDER_H

#include <QQuickImageProvider>
#include <QHash>
#include <QImage>
#include <QMutex>

// 弹幕文字预光栅化 Provider
// 将弹幕文字用 QPainter（CPU）渲染为带描边的 QImage，并缓存。
// QML 侧用 Image 代替 Text，每帧只做 GPU 纹理 blit，避免每帧重新光栅化文字。
class DanmakuImageProvider : public QQuickImageProvider
{
public:
    DanmakuImageProvider();

    QImage requestImage(const QString &id, QSize *size, const QSize &requestedSize) override;

    // id 格式: "fontSize|color#ifndef DANMAKUIMAGEPROVIDER_H
#define DANMAKUIMAGEPROVIDER_H

#include <QQuickImageProvider>
#include <QHash>
#include <QImage>
#include <QMutex>

// 弹幕文字预光栅化 Provider
// 将弹幕文字用 QPainter（CPU）渲染为带描边的 QImage，并缓存。
// QML 侧用 Image 代替 Text，每帧只做 GPU 纹理 blit，避免每帧重新光栅化文字。
class DanmakuImageProvider : public QQuickImageProvider
{
public:
    DanmakuImageProvider();

    QImage requestImage(const QString &id, QSize *size, const QSize &requestedSize) override;

    // id 格式: "fontSize|color|text"，由 QML 侧拼好后传入