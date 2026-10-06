#!/usr/bin/env python3
"""构造测试用 .ico，覆盖 extract-ico-png.py 的两条分支。

真实 res/app.ico 的结构是"layer0-4 = DIB、layer5(256) = PNG"，
但依赖真实文件只能验证其中一条路径。这里合成两类样本：

  mixed.ico   : 16/32/48/64/128 为 DIB，256 为内嵌 PNG（复刻真实结构）
  alldib.ico  : 全部图层都是 DIB，无任何 PNG（强制走转换分支）

同时生成 --truncated（数据长度谎报为超出文件末尾）与 --nopng
（声称有 256 图层但实际最大只有 128）两种异常样本，验证脚本会
明确报错退出而不是静默产出坏文件。

用法: python3 scripts/make-test-ico.py <输出目录>
"""

import os
import struct
import sys
import zlib

# 构造一个可识别的渐变图案，便于肉眼确认方向/顺序没搞反
def make_pixel(x, y, size):
    r = (x * 255) // max(1, size - 1)
    g = (y * 255) // max(1, size - 1)
    b = 128
    a = 255 if (x + y) % 7 != 0 else 64  # 制造少量半透明像素
    # 存成 BGRA（DIB 顺序）
    return bytes((b, g, r, a))


def make_dib_layer(size):
    """构造一个 ICO 内嵌的 DIB 图层（BITMAPINFOHEADER + 像素 + AND 掩码）。

    注意 biHeight 是实际高度的两倍（XOR 位图 + AND 掩码），这是 ICO 的约定。
    像素自下而上存储。
    """
    header = struct.pack("<IiiHHIIiiII",
                         40,          # biSize
                         size,        # biWidth
                         size * 2,    # biHeight（含 AND 掩码）
                         1,           # biPlanes
                         32,          # biBitCount
                         0,           # biCompression = BI_RGB
                         0, 0, 0, 0, 0)
    row_bytes = size * 4  # 32bpp 时天然 4 字节对齐
    pixels = bytearray()
    for row in range(size - 1, -1, -1):  # 自下而上
        for x in range(size):
            pixels += make_pixel(x, row, size)
    # AND 掩码：每行 ceil(size/8) 字节，再按 4 字节对齐。全 0 = 不遮挡。
    mask_row = ((size + 31) // 32) * 4
    and_mask = b"\x00" * (mask_row * size)
    return bytes(header) + bytes(pixels) + and_mask


def make_png_layer(size):
    """构造一个内嵌 PNG 图层（RGBA，带filter type 0）。"""
    raw = bytearray()
    for y in range(size):
        raw += b"\x00"  # filter type 0 = None
        for x in range(size):
            raw += make_pixel(x, y, size)

    def chunk(tag, payload):
        return (struct.pack(">I", len(payload)) + tag + payload
                + struct.pack(">I", zlib.crc32(tag + payload) & 0xffffffff))

    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


def build_ico(layers):
    """layers: [(size, payload_bytes), ...] ->完整 .ico 字节。"""
    n = len(layers)
    header = struct.pack("<HHH", 0, 1, n)
    # 目录项在头部，占6 + 16*n 字节
    data_off = 6 + 16 * n
    dir_entries = bytearray()
    body = bytearray()
    for size, payload in layers:
        dir_entries += struct.pack("<BBBBHHII",
                                   0 if size >= 256 else size,
                                   0 if size >= 256 else size,
                                   0, 0, 1, 32,
                                   len(payload), data_off)
        body += payload
        data_off += len(payload)
    return bytes(header) + bytes(dir_entries) + bytes(body)


def main(argv):
    outdir = argv[1] if len(argv) > 1 else "."
    os.makedirs(outdir, exist_ok=True)

    sizes = [16, 32, 48, 64, 128, 256]

    # 1) mixed：DIB 各层 + 顶层 256 为 PNG（复刻 res/app.ico 结构）
    mixed = []
    for s in sizes:
        mixed.append((s, make_png_layer(s) if s == 256 else make_dib_layer(s)))
    p = os.path.join(outdir, "mixed.ico")
    with open(p, "wb") as f:
        f.write(build_ico(mixed))
    print("生成 %s（256 层为 PNG，其余为 DIB）" % p)

    # 2) alldib：全部 DIB，强制走 dib_to_png
    alldib = [(s, make_dib_layer(s)) for s in sizes]
    p = os.path.join(outdir, "alldib.ico")
    with open(p, "wb") as f:
        f.write(build_ico(alldib))
    print("生成 %s（全部为 DIB）" % p)

    # 3) truncated：把最后一层的 dwBytesInRes 谎报成超大值
    data = bytearray(build_ico(mixed))
    # 最后一个目录项在 6+16*(n-1)，其 size 字段在该项偏移 +8
    last = 6 + 16 * (len(mixed) - 1)
    struct.pack_into("<I", data, last + 8, 0x7FFFFFFF)
    p = os.path.join(outdir, "truncated.ico")
    with open(p, "wb") as f:
        f.write(bytes(data))
    print("生成 %s（dwBytesInRes 越界，应报错）" % p)

    # 4) nopng256：最大只有 128，验证"找不到 >=256 图层"时报错
    small = [(s, make_dib_layer(s)) for s in sizes if s < 256]
    p = os.path.join(outdir, "nopng256.ico")
    with open(p, "wb") as f:
        f.write(build_ico(small))
    print("生成 %s（最大仅 128，应报错）" % p)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
