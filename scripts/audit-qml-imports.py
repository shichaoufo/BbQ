#!/usr/bin/env python3
"""静态核查每个 .qml 文件使用的自定义类型是否有对应的 import。

背景：QML 里"类型不可用"的报错（Type X unavailable / X is not a type）
是**逐个暴露**的——修一个冒一个。因为 QML 的 import 具有传递可见性，
一个页面可能靠main.qml 的 `import "./components"` 隐式拿到组件类型；
一旦 main.qml 改动那份import 就会静默断链，且报错位置指向使用处而非
import 处，很难排查。

本脚本按"每个文件自洽"的标准做检查：对每个 .qml，收集它实际使用到的
自定义类型，再减去它自己显式/传递可用的类型，报告差集。

只读脚本，不修改任何文件。用法：
    python3 scripts/audit-qml-imports.py [qml根目录]
"""

import os
import re
import sys

# Windows 控制台默认编码是 cp1252（GBK 区域设置下为 cp936），本脚本输出的
# 中文提示会触发 UnicodeEncodeError —— GitHub Actions 的 Windows runner 就是
# cp1252，print 第一个中文即崩。reconfigure 把标准输出切到 UTF-8，让脚本
# 在任何 runner 上行为一致。errors="replace" 保证极端情况下（编码不支持）
# 降级为替换字符而非抛异常。
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

# ---- 项目自定义类型清单 ----
# components/ 下的 QML 组件（QML 类型）
COMPONENT_TYPES = {
    "AvatarWithPendant", "CircleAvatar", "CommentCardBg", "CommentPanel",
    "DanmakuOverlay", "FluPaginationNoArrow", "FluPaginationSimple",
    "HistoryCard", "IconFontIcon", "IconParkIcon", "ImageViewer",
    "LiveCard", "LoginPopup", "NavigationBar", "SegmentedDigits",
    "UserCard", "VideoCard",
}

# C++ qmlRegisterType 注册到 "BiliQt" 模块的类型（见 src/main.cpp）
BILIQT_TYPES = {
    "CircularReveal", "MpvObject", "LiveDanmakuManager", "VideoDanmakuManager",
    "DanmakuCanvas",
}

# 全部需要 import 才能用的自定义类型
CUSTOM_TYPES = COMPONENT_TYPES | BILIQT_TYPES

# 同一目录下的其他 QML 文件（同目录类型自动可见，无需 import）
LOCAL_TYPE_RE = re.compile(r"^\s*([A-Z][A-Za-z0-9_]*)\s*\{")
# 必须带 re.MULTILINE：QML 的 import 每行一条且位于文件任意行（不是只在开头），
# 缺了它只会匹配到整个文件的第一行，导致所有 import 都被漏掉
IMPORT_RE = re.compile(r"^[ \t]*import\s+(\S+)", re.MULTILINE)


def read_text(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def collect_used_types(text, local_types):
    """收集文件中作为类型使用的自定义类型名（`TypeName {` 形式）。"""
    used = set()
    for m in re.finditer(r"\b([A-Z][A-Za-z0-9_]*)\s*\{", text):
        name = m.group(1)
        # 排除 QML 内建类型与 JS 大写开头对象
        if name in CUSTOM_TYPES:
            used.add(name)
    return used


def parse_imports(text):
    """返回 (显式 import 的路径集合, 是否有目录级 import "./")。"""
    paths = set()
    dir_level = False
    for m in IMPORT_RE.finditer(text):
        target = m.group(1)
        if target in ("./", "."):
            dir_level = True
        elif target.startswith('"') or target.endswith('"'):
            paths.add(target.strip('"'))
        else:
            paths.add(target)
    return paths, dir_level


def resolves_to_components(import_path, file_dir):
    """判断某import 是否能提供 components/ 下的类型。

    能提供的方式：
      - `import "<qml_root>/components"`（绝对或相对定位到 components 目录）
      - `import "./"` + 该文件位于能看到 main.qml 传递作用域的位置
        （仅当同目录存在一个自己 import 了 components 的文件时成立，
         这就是"传递可见性"，脆弱）
    """
    if not import_path.startswith("."):
        return False
    resolved = os.path.normpath(os.path.join(file_dir, import_path))
    # import "../components" -> qml/components
    if os.path.basename(resolved) == "components" and os.path.isdir(resolved):
        return True
    return False


def transitive_via_dir_import(file_path, text, qml_root, all_files):
    """`import "./"` 能否通过同目录另一个文件传递拿到 components 类型。

    机制：同目录 import 是**文件级**的，不会跨文件传递。真正能传递的是
    "本文件 import 的另一个 QML 文件里又 import 了 components"——
    这在 QML 里不成立（import 不传递）。

    但实际项目里 HomePage/LivePage 的`import "./"` 确实能用，
    因为它们 import 的是**目录**，而该目录（qml/pages）下的main.qml
    并不在这里。真实机制是：qml/main.qml 同时 import "./pages" 与
    "./components"，QML 的 import 具有传递可见性，pages 目录下的文件
    处于 main.qml 的作用域内，因此能看到 components 的类型。
    这就是脆弱点：依赖 main.qml 持续 import components。
    """
    # 无法从单文件判断 main.qml 是否 import 了 components，
    # 交由调用方用全局事实判断：main.qml 是否 import 了 components。
    return None  # 由 caller 依据 main.qml 的事实决定


def audit(qml_root):
    all_qml = []
    for dirpath, _dirnames, filenames in os.walk(qml_root):
        for fn in filenames:
            if fn.endswith(".qml"):
                all_qml.append(os.path.join(dirpath, fn))
    all_qml.sort()
    qml_root = os.path.abspath(qml_root)

    # main.qml 自身的 import 决定它能看到什么
    main_qml = os.path.join(qml_root, "main.qml")
    main_imports, _ = parse_imports(read_text(main_qml)) if os.path.isfile(main_qml) else (set(), False)

    print("QML 根目录: %s" % qml_root)
    print("共 %d 个 .qml 文件" % len(all_qml))
    print("main.qml 的 import: %s" % ", ".join(sorted(main_imports)))
    print()

    problems = []
    fragile = []
    for path in all_qml:
        text = read_text(path)
        file_dir = os.path.abspath(os.path.dirname(path))
        imports, dir_level = parse_imports(text)
        in_root_dir = (file_dir == qml_root)

        # 本文件显式 import 了 components 目录？
        has_components_import = any(
            resolves_to_components(p, file_dir) for p in imports)
        has_biliqt = any("BiliQt" in p for p in imports)

        # QML 的 import 是**文件级**的，不会跨文件传递。真正的机制是
        # 「目录级 import」：一个文件若写了 `import "./"`，它就把所在目录
        # 作为一个整体纳入自己的作用域；而该目录里的每个文件又各自
        # import 了 components/，于是这些类型在**同一作用域**内可见。
        # 换言之：`import "./"` 让同目录文件的 import 变成彼此可见。
        # 这解释了实测现象——
        #   HomePage / LivePage（有 import "./"）→ 能用 DanmakuOverlay
        #   LivePlayerPage（无 import "./"）      → "DanmakuOverlay is not a type"
        # 这种可见性是**隐式且脆弱**的：main.qml 或任一同目录文件的
        # import 一变，断链就复发，且报错指向使用处而非import 处。
        same_dir_scope = dir_level
        has_components_import = any(
            resolves_to_components(p, file_dir) for p in imports)
        has_biliqt = any("BiliQt" in p for p in imports)

        # 同目录兄弟文件自动可见（QML 同目录类型无需import）
        siblings = {os.path.splitext(os.path.basename(p))[0]
                    for p in all_qml
                    if os.path.abspath(os.path.dirname(p)) == file_dir}

        used = collect_used_types(text, siblings)
        if not used:
            continue

        missing = set()
        for t in sorted(used):
            if t in siblings:
                continue
            if t in BILIQT_TYPES:
                if not has_biliqt:
                    missing.add(t)
                continue
            # components 类型：显式 import，或靠同目录作用域传递
            if has_components_import:
                continue
            if same_dir_scope:
                fragile.append((os.path.relpath(path, os.path.dirname(qml_root)),
                                t, "靠同目录 import \"./\" 传递"))
                continue
            missing.add(t)

        rel = os.path.relpath(path, os.path.dirname(qml_root))
        mode = "显式" if has_components_import else ("传递" if same_dir_scope else "无")
        status = "OK" if not missing else "MISSING"
        print("%-44s components=%-4s BiliQt=%-3s dir=%-3s %s"
              % (rel, mode, "有" if has_biliqt else "无",
                 "有" if dir_level else "无", status))
        if missing:
            problems.append((rel, sorted(missing), mode))

    print()
    if problems:
        print("=== %d 个文件存在【真缺失】import（无法解析任何来源）===" % len(problems))
        for rel, missing, mode in problems:
            print("  %s" % rel)
            print("     缺失: %s" % ", ".join(missing))
    else:
        print("=== 无【真缺失】import：所有自定义类型均可解析 ===")

    if fragile:
        uniq = sorted(set(fragile))
        print()
        print("=== %d 处依赖 main.qml 传递可见性（当前能跑，但脆弱）===" % len(uniq))
        for rel, t, why in uniq:
            print("  %-40s %s" % (rel, t))
    return 1 if problems else 0


def main(argv):
    qml_root = argv[1] if len(argv) > 1 else "qml"
    return audit(qml_root)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
