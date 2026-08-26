#!/usr/bin/env python3
import os
import subprocess
import json
import re
import fontforge

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SVG_DIR = os.path.join(BASE_DIR, "qml", "assets", "icons", "iconpark")
OUT_TTF = os.path.join(BASE_DIR, "qml", "assets", "iconpark.ttf")
OUT_JSON = os.path.join(BASE_DIR, "qml", "assets", "iconpark_mapping.json")
OUT_QML = os.path.join(BASE_DIR, "qml", "components", "IconFontIcon.qml")

EM_SIZE = 48
ICON_SIZE = 48

START_CODEPOINT = 0xE800


def preprocess_svg(src_path, dst_path):
    subprocess.run(
        [
            "inkscape",
            src_path,
            "--export-filename=" + dst_path,
            "--export-type=svg",
            "--export-plain-svg",
            "--actions=select-all;object-stroke-to-path;object-to-path;export-do",
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def clean_svg(svg_path, dst_path):
    """
    清理 Inkscape 预处理后的 SVG：
    1. 移除 fill="none" 的占位 path，避免 FontForge 导入时错误填充内部区域。
    2. 对 coin 等复杂图标保留实际绘制的填充路径。
    """
    with open(svg_path, "r", encoding="utf-8") as f:
        content = f.read()
    content = re.sub(r'<path[^>]*fill\s*=\s*"none"[^>]*/>', "", content)
    content = re.sub(r"<path[^>]*fill\s*=\s*'none'[^>]*/>", "", content)
    with open(dst_path, "w", encoding="utf-8") as f:
        f.write(content)


def main():
    if not os.path.isdir(SVG_DIR):
        raise RuntimeError(f"SVG directory not found: {SVG_DIR}")

    svg_files = sorted([f for f in os.listdir(SVG_DIR) if f.endswith(".svg")])
    if not svg_files:
        raise RuntimeError(f"No SVG files found in {SVG_DIR}")

    tmp_dir = os.path.join(BASE_DIR, "tmp_iconpark_build")
    os.makedirs(tmp_dir, exist_ok=True)

    font = fontforge.font()
    font.fontname = "IconPark"
    font.familyname = "IconPark"
    font.fullname = "IconPark Icons"
    font.em = EM_SIZE
    font.ascent = int(EM_SIZE * 0.875)
    font.descent = EM_SIZE - font.ascent
    font.encoding = "UnicodeFull"

    mapping = {}
    for idx, filename in enumerate(svg_files):
        name = filename[:-4]
        codepoint = START_CODEPOINT + idx
        src_path = os.path.join(SVG_DIR, filename)
        tmp_path = os.path.join(tmp_dir, filename)

        preprocess_svg(src_path, tmp_path)

        cleaned_path = os.path.join(tmp_dir, name + "_cleaned.svg")
        clean_svg(tmp_path, cleaned_path)

        glyph = font.createChar(codepoint, name)
        glyph.importOutlines(cleaned_path)
        glyph.width = EM_SIZE
        glyph.vwidth = EM_SIZE
        # coin 图标内部有精细的 B 字镂空，simplify 会破坏细节
        if name != "coin":
            glyph.simplify()
        glyph.round()
        glyph.addExtrema()

        mapping[name] = f"\\u{codepoint:04X}"

    font.generate(OUT_TTF)
    print(f"Generated TTF: {OUT_TTF}")

    with open(OUT_JSON, "w", encoding="utf-8") as f:
        json.dump(mapping, f, indent=2, ensure_ascii=False)
    print(f"Generated mapping: {OUT_JSON}")

    qml_entries = []
    for name in sorted(mapping.keys()):
        codepoint = int(mapping[name].replace("\\u", ""), 16)
        qml_entries.append(f'        "{name}": "\\u{codepoint:04x}"')

    qml_map = ",\n".join(qml_entries)
    qml_content = f'''import QtQuick
import QtQuick.Layouts
import FluentUI 1.0

Text {{
    id: root
    property string name: ""
    property color iconColor: FluTheme.fontPrimaryColor

    font.family: iconFont.name
    font.pixelSize: 20
    color: root.iconColor
    text: iconMap.map[root.name] || ""
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    renderType: Text.NativeRendering

    FontLoader {{
        id: iconFont
        source: Qt.resolvedUrl("../assets/iconpark.ttf")

        onStatusChanged: {{
            if (status === FontLoader.Error) {{
                console.warn("IconFontIcon: failed to load font", source)
            }} else if (status === FontLoader.Ready) {{
                console.log("IconFontIcon: font loaded", name)
            }}
        }}
    }}

    QtObject {{
        id: iconMap
        property var map: (({{
{qml_map}
        }}))
    }}
}}
'''

    with open(OUT_QML, "w", encoding="utf-8") as f:
        f.write(qml_content)
    print(f"Generated QML: {OUT_QML}")


if __name__ == "__main__":
    main()
