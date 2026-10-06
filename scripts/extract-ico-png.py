#!/usr/bin/env python3
"""从 Windows .ico 里提取最大尺寸图层并写成独立 PNG。

为什么不用 ImageMagick：
  - `convert -define icon:auto-resize=256` 是 **ImageMagick 7 专有语法**，
    IM6（Ubuntu 22.04 的 `imagemagick` 元包提供 6.9.x，命令落在
    `convert-im6.q16`）不识别，且遇到不认识的 `-define` 是**静默忽略**
    而非报错 → 产物没生成，CI 才在后续断言处炸。
  - 索引语法 `app.ico[5]` 在 IM6/IM7 之间行为也不一致。
  已经因为"照抄文档/换版本就失效"踩过两次坑（aqt 的 `gcc_64` vs
  `linux_gcc_64`、这次的 `icon:auto-resize`），故本脚本**零外部依赖**，
  只用 Python 标准库（struct / zlib），跨 runner 版本免疫。

ICO 容器结构（均为小端）：
  ICONDIR6 字节   : reserved(u16) type(u16) count(u16)
  ICONDIRENTRY×N : 每层 16 字节
        0..1  bWidth  (0 表示 256)
        2..3  bHeight (0 表示 256)
        4bBpp  4..5 colorCount  6reserved  7reserved
        8..11 dwBytesInRes  该层数据总长度
       12..15 dwImageOffset 该层数据起始偏移
  每层数据要么是独立 PNG（以 89 50 4E 47 0D 0A 1A 0A 开头），
  要么是无文件头的 DIB/BMP（以 BITMAPINFOHEADER 的 40 开头）。

用法：
    python3 scripts/extract-ico-png.py <输入.ico> <输出.png> [最小边长]
默认最小边长256，即"取边长 >= 256 的最大图层"；找不到就报错退出，
绝不静默产出小尺寸或坏文件。
"""

import struct
import sys
import zlib

# PNG 魔数（8 字节，完整签名）
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
# BITMAPINFOHEADER 的 biSize 固定为 40
BITMAPINFOHEADER_SIZE = 40


def die(msg):
    """报错退出。刻意用 stderr + 非零码，让 CI 能立刻看到原因。"""
    sys.stderr.write("ERROR: %s\n" % msg)
    sys.exit(1)


def read_ico_layers(data):
    """解析 ICO，返回 [(index, w, h, bpp, data_offset, data_len)]。"""
    if len(data) < 6:
        die("ICO 文件过短（%d 字节），连ICONDIR 头都不够" % len(data))

    reserved, ico_type, count = struct.unpack("<HHH", data[:6])
    if reserved != 0:
        die("ICONDIR.reserved 应为 0，实际 %d —— 这不是合法 ICO" % reserved)
    if ico_type != 1:
        # type 2 = CUR（光标）。本项目只需要图标。
        die("ICONDIR.type 应为 1（图标），实际 %d（2=光标）" % ico_type)
    if count == 0:
        die("ICONDIR.count 为 0，ICO 里没有图层")

    layers = []
    entry_off = 6
    for i in range(count):
        if entry_off + 16 > len(data):
            die("图层 %d 的目录项被截断（偏移 %d，文件仅 %d 字节）"
                % (i, entry_off, len(data)))
        entry = data[entry_off:entry_off + 16]
        (b_w, b_h, _ncolor, _r1, _planes, bpp,
         size, offset) = struct.unpack("<BBBBHHII", entry)
        # 目录项里的宽高是 u8，0 表示 256
        w = 256 if b_w == 0 else b_w
        h = 256 if b_h == 0 else b_h
        # 越界检查：offset+size 必须落在文件内
        if offset + size > len(data):
            die("图层 %d 的数据越界（offset=%d size=%d，文件仅 %d 字节）"
                % (i, offset, size, len(data)))
        if size == 0:
            die("图层 %d 的 dwBytesInRes 为 0" % i)
        layers.append((i, w, h, bpp, offset, size))
        entry_off += 16
    return layers


def dib_to_png(layer_bytes, width, height, bpp):
    """把 ICO 内的 DIB/BMP 图层转成 PNG 字节（纯标准库实现）。

    ICO 里的 DIB 没有 'BM' 文件头，直接以 BITMAPINFOHEADER 开头；且
    biHeight 是**实际高度的两倍**（下半部分是 AND 掩码）。像素自下而上存储。
    32bpp 时 BGRA 的 alpha 通道有效，AND 掩码可忽略。
    """
    if len(layer_bytes) < BITMAPINFOHEADER_SIZE:
        die("DIB 图层数据不足 BITMAPINFOHEADER（%d 字节）" % len(layer_bytes))

    # 逐字段命名解包，不用连续下划线跳过：BITMAPINFOHEADER 里几个字段
    # 都是 4 字节，位置错一位不会报错、只会静默取到隔壁字段的值
    # （biBitCount 被读成 biCompression=0 这类），必须按名对齐。
    fields = struct.unpack("<IiiHHIIiiII", layer_bytes[:BITMAPINFOHEADER_SIZE])
    bi_size = fields[0]        # biSize，应为 40
    planes = fields[3]         # biPlanes
    bpp_dib = fields[4]        # biBitCount
    compression = fields[5]    # biCompression
    if bi_size != BITMAPINFOHEADER_SIZE:
        die("只支持 BITMAPINFOHEADER(40)，实际 biSize=%d" % bi_size)
    if compression != 0:
        # 0=BI_RGB。BI_BITFIELDS(3)/BI_ALPHABITFIELDS(6) 的掩码表紧跟
        # 40 字节头之后，像素区起点会偏移，本实现不支持。
        die("DIB 图层只支持未压缩 BI_RGB(0)，实际 biCompression=%d"
            % compression)
    if bpp_dib not in (32, 24):
        die("DIB 图层只支持 24/32bpp，实际 %d bpp" % bpp_dib)
    if planes != 1:
        die("DIB 图层 planes 应为 1，实际 %d" % planes)

    # XOR 位图区起点：40 字节头（+ 调色板，本项目无调色板）
    xor_off = BITMAPINFOHEADER_SIZE
    row_bytes = ((width * bpp_dib + 31) // 32) * 4  # 每行 4 字节对齐
    need = row_bytes * height
    if len(layer_bytes) < xor_off + need:
        die("DIB 像素区不完整：需要 %d 字节，实际 %d"
            % (xor_off + need, len(layer_bytes)))

    # 逐行自下而上翻转为自上而下，同时 BGRA -> RGBA
    raw = bytearray()
    # 一行真实像素的字节数（不含每行末尾的 4 字节对齐填充）。
    # 必须按真实像素数切行，不能直接用整条 row_bytes —— 32bpp 时
    # row_bytes 通常已 4 字节对齐、等于 pixel_row，但 24bpp 等宽度下
    # 会多出padding 字节；把padding 一起卷进像素会让每行多出几个字节，
    # 后续行起点全部错位（表现为花屏）。
    pixel_row = width * (bpp_dib // 8)
    for row in range(height - 1, -1, -1):
        start = xor_off + row * row_bytes
        line = layer_bytes[start:start + pixel_row]
        if len(line) < pixel_row:
            die("DIB 第 %d 行像素不完整：需要 %d 字节，实际 %d"
                % (row, pixel_row, len(line)))
        # PNG 每行必须以 1 字节 filter type **开头**（0 = None，不做预测），
        # 之后才是该行的像素数据。顺序反了会让解码器把每行最后一个像素的
        # alpha 当成 filter 解释 —— 表现为整图花屏/错位，且文件结构仍合法，
        # 所以不会报错、只会静默出错图（开发本脚本时踩过）。
        raw += b"\x00"
        if bpp_dib == 32:
            # BGRA -> RGBA
            raw += b"".join(line[x:x + 4][::-1] for x in range(0, pixel_row, 4))
        else:  # 24bpp BGR -> RGB，末字节补 0xFF 作 alpha
            for x in range(0, pixel_row, 3):
                raw += line[x + 2:x + 3] + line[x + 1:x + 2] + line[x:x + 1] + b"\xff"

    def chunk(tag, payload):
        return (struct.pack(">I", len(payload)) + tag + payload
                + struct.pack(">I", zlib.crc32(tag + payload) & 0xffffffff))

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)  # 8bit RGBA
    return (PNG_MAGIC + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b""))


def png_dimensions(png_bytes):
    """读 PNG 的 IHDR，返回 (width, height)。用于产出后的自校验。"""
    if len(png_bytes) < 24 or png_bytes[:8] != PNG_MAGIC:
        die("产出数据不是合法 PNG（魔数不匹配）")
    if png_bytes[12:16] != b"IHDR":
        die("PNG 第一个 chunk 不是 IHDR（实际 %r）" % png_bytes[12:16])
    w, h = struct.unpack(">II", png_bytes[16:24])
    return w, h


def main(argv):
    if len(argv) < 3:
        sys.stderr.write("用法: %s <输入.ico> <输出.png> [最小边长]\n" % argv[0])
        return 2
    ico_path, out_path = argv[1], argv[2]
    min_side = int(argv[3]) if len(argv) > 3 else 256

    try:
        with open(ico_path, "rb") as f:
            data = f.read()
    except OSError as exc:
        die("无法读取 %s: %s" % (ico_path, exc))

    layers = read_ico_layers(data)
    print("ICO 共 %d 个图层：" % len(layers))
    for i, w, h, bpp, off, size in layers:
        kind = "PNG" if data[off:off + 8] == PNG_MAGIC else "DIB"
        print("  layer%d: %dx%d %dbpp %d bytes @%d (%s)"
              % (i, w, h, bpp, size, off, kind))

    # 选边长 >= min_side 的最大图层；同尺寸时取靠后（后写入的通常是更高质量版本）
    usable = [L for L in layers if L[1] >= min_side and L[2] >= min_side]
    if not usable:
        die("没有边长 >= %d 的图层（现有尺寸：%s）。"
            "请重新导出至少含 256x256 图层的 .ico"
            % (min_side, ", ".join("%dx%d" % (L[1], L[2]) for L in layers)))
    usable.sort(key=lambda L: (L[1] * L[2], L[0]))
    idx, w, h, bpp, off, size = usable[-1]

    payload = data[off:off + size]
    if payload[:8] == PNG_MAGIC:
        print("选中 layer%d（%dx%d），直接抽取内嵌 PNG" % (idx, w, h))
        png = payload
    else:
        print("选中 layer%d（%dx%d），为 DIB，转换为 PNG" % (idx, w, h))
        png = dib_to_png(payload, w, h, bpp)

    # 产出前自校验：必须是合法 PNG 且尺寸与目录项一致
    pw, ph = png_dimensions(png)
    if (pw, ph) != (w, h):
        die("产出 PNG 尺寸 %dx%d 与 ICO 目录项声明的 %dx%d 不一致"
            % (pw, ph, w, h))

    with open(out_path, "wb") as f:
        f.write(png)
    print("已写出 %s（%dx%d，%d 字节）" % (out_path, pw, ph, len(png)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
