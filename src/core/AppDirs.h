#ifndef BBQ_APPDIRS_H
#define BBQ_APPDIRS_H

#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QStandardPaths>
#include <QString>

// ===========================================================================
// BbQ 运行时数据目录解析（全平台共用）
//
// 设计目标（来自用户决策）：
//   - **Windows 行为必须完全不变**：配置、日志、缓存继续放在 exe 同目录。
//     用户明确要求"windows还是不动，现在这样比较干净，软件删了没有残留"。
//     因此 Windows 分支一律返回 applicationDirPath()，与改动前逐字一致。
//   - **Linux 改用标准用户配置目录** `~/.config/BbQ/`（单层）。
//
// 为什么 Linux 必须离开 exe 目录：
//   1. 权限：.deb 安装后 exe 位于 /opt/bbq/bin/，归root 所有。普通用户
//      进程往那儿写 mpv.log / 表情缓存必然 EACCES 失败 —— mpv 日志会
//      **完全丢失**，直播卡死这类问题就彻底没有排查依据了。
//   2. 卸载残留：绿色版把用户数据混在程序目录里，删程序即丢配置。
//   3. 多用户：exe 目录是全局共享的，无法按用户隔离配置。
//
// 为什么不用 QStandardPaths::AppConfigLocation：
//   它会把 organizationName 与 applicationName **各拼一层**，本项目两者
//   都叫 "BbQ"，展开结果是 `~/.config/BbQ/BbQ` —— 多出一层无意义的
//   重复目录。而我们只想要单层 `~/.config/BbQ/`。故显式用
//   GenericConfigLocation（`~/.config`）+ 手动拼 "BbQ"。
//
// ===========================================================================

namespace AppDirs {

/// 子目录名，同时用作配置目录名与 .desktop 的应用名
inline QString appFolderName()
{
    return QStringLiteral("BbQ");
}

/// 用户配置根目录（末尾带分隔符）。
/// Windows：exe 同目录；Linux：~/.config/BbQ/（不存在则创建）。
inline QString configRoot()
{
#ifdef Q_OS_WIN
    // Windows 保持原样：配置与程序同目录，软件删除无残留。
    return QCoreApplication::applicationDirPath() + QChar('/');
#else
    QString root = QDir(QStandardPaths::writableLocation(
                           QStandardPaths::GenericConfigLocation))
                       .absolutePath()
                   + QChar('/') + appFolderName();
    // mkpath：首次启动时目录不存在。失败（只读 home / 沙箱）不致命 ——
    // 后续各文件操作会各自失败并走各自的降级分支，不应因此崩在启动阶段。
    QDir().mkpath(root);
    return root + QChar('/');
#endif
}

/// 解析一个可能位于"新配置目录"或"旧 exe 目录"的文件，返回首个存在的路径。
///
/// 用于向后兼容：Linux 用户此前从 tar.gz 绿色版（配置在 exe 同目录）
/// 升级到 .deb 包时，旧配置文件仍在 exe 目录。不做回退的话这些用户会
/// 突然"配置全丢"（mpv.conf 里的 vf 偏好、bsb.conf 的 SponsorBlock
/// 地址、外接弹幕字体全部失效）。
///
/// 查找顺序：新配置目录 → 旧 exe 目录（仅非 Windows）。
/// 都不存在时返回新配置目录的路径（供写入方使用）。
inline QString resolveReadable(const QString &relativePath,
                               bool *usedLegacy = nullptr)
{
    const QString primary = configRoot() + relativePath;
    if (QFileInfo::exists(primary)) {
        if (usedLegacy) *usedLegacy = false;
        return primary;
    }
#ifndef Q_OS_WIN
    // 旧布局：exe 同目录（tar.gz 绿色版 / 手工解压）
    const QString legacy = QCoreApplication::applicationDirPath()
                           + QChar('/') + relativePath;
    if (QFileInfo::exists(legacy)) {
        if (usedLegacy) *usedLegacy = true;
        return legacy;
    }
#endif
    if (usedLegacy) *usedLegacy = false;
    return primary;
}

/// 解析一个需要**写入**的文件所在目录（确保目录存在）。
inline QString writableDir(const QString &subDir)
{
    const QString dirPath = configRoot() + subDir;
    QDir().mkpath(dirPath);
    return dirPath + QChar('/');
}

} // namespace AppDirs

#endif // BBQ_APPDIRS_H
