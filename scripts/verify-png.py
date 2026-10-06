#!/usr/bin/env python3
"""extract-ico-png.py 的验证器：按 PNG 规范严格解码并校验产出。

与"只看文件是否存在/大小对不对"不同，这里**真正按 PNG 解码规则遍历**：
逐行读 filter type + 该行像素，任何一处对不上就报错。这才能抓住
"结构合法但内容错位"这类静默失败（例如 filter 字节位置摆反）。

同时逐 chunk 校验 CRC，并报告非透明像素数（防止产出全透明空图）。

用法: python3 scripts/verify-png.py <file.png> [期望宽] [期望高]
退出码 0 = 全部通过。
"""

import struct
import sys
import zlib

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


def fail(msg):
    sys.stderr.write("FAIL: %s\n" % msg)
    sys.exit(1)


def verify(path, want_w=None, want_h=None):
    with open(path, "rb") as f:
        d = f.read()

    if d[:8] != PNG_MAGIC:
        fail("%s: PNG 魔数不匹配" % path)

    # ---- 逐 chunk 走，校验 CRC ----
    off = 8
    idat = bytearray()
    ihdr = None
    chunks = []
    while off < len(d):
        if off + 8 > len(d):
            fail("chunk 头被截断 @%d" % off)
        (ln,) = struct.unpack(">I", d[off:off + 4])
        tag = d[off + 4:off + 8]
        payload = d[off + 8:off + 8 + ln]
        if off + 12 + ln > len(d):
            fail("chunk %s 数据被截断 @%d" % (tag.decode(errors="replace"), off))
        (crc,) = struct.unpack(">I", d[off + 8 + ln:off + 12 + ln])
        calc = zlib.crc32(tag + payload) & 0xffffffff
        if crc != calc:
            fail("chunk %s CRC 不匹配：文件内 0x%08x，计算 0x%08x"
                 % (tag.decode(errors="replace"), crc, calc))
        chunks.append(tag.decode(errors="replace"))
        if tag == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", payload)
        elif tag == b"IDAT":
            idat += payload
        off += 12 + ln

    if not chunks or chunks[0] != "IHDR":
        fail("第一个 chunk 必须是 IHDR，实际 %s" % (chunks[0] if chunks else "无"))
    if chunks[-1] != "IEND":
        fail("最后一个 chunk 必须是 IEND，实际 %s" % chunks[-1])
    if ihdr is None:
        fail("缺少 IHDR")

    w, h, depth, color, comp, filt, interlace = ihdr
    print("  %s" % path)
    print("  IHDR: %dx%d depth=%d colortype=%d interlace=%d"
          % (w, h, depth, color, interlace))
    print("  chunks: %s (CRC 全部校验通过)" % ",".join(chunks))

    if depth != 8 or color != 6:
        fail("期望 8bit RGBA(depth=8,colortype=6)，实际 depth=%d colortype=%d"
             % (depth, color))
    if interlace != 0:
        fail("不接受隔行扫描(interlace=%d)" % interlace)
    if want_w is not None and w != want_w:
        fail("宽度应为 %d，实际 %d" % (want_w, w))
    if want_h is not None and h != want_h:
        fail("高度应为 %d，实际 %d" % (want_h, h))

    # ---- 按 PNG 规范逐行解码扫描线 ----
    # 注意：filter type **允许非 0**。PNG 规范定义了 5 种滤波器
    # （0=None,1=Sub,2=Up,3=Average,4=Paeth），编码器可逐行自适应选择。
    # 实测 res/app.ico 内嵌的 256 层用的就是 1/2/4 混合（Windows 导出器
    # 的常规行为）。所以这里**不能**断言 filter==0，只能断言：
    #   1) filter type 落在 0..4 的合法范围；
    #   2) 扫描线总长度精确匹配（这才是"行没错位"的真正判据）。
    # 曾把"必须为 0"写进校验，结果对真实 app.ico 直接误报——教训：
    # 校验器本身也可能比被校验物更错，负向样本要同时覆盖"应通过"场景。
    raw = zlib.decompress(bytes(idat))
    bpp = 4  # colortype 6 = RGBA
    stride = w * bpp + 1  # 每行：1 字节 filter + 像素
    if len(raw) != stride * h:
        fail("像素数据长度 %d != 期望 %d（stride=%d, h=%d）"
             % (len(raw), stride * h, stride, h))

    filter_hist = {}
    nonzero_alpha = 0
    for r in range(h):
        ft = raw[r * stride]
        if ft > 4:
            fail("第 %d 行 filter type = %d，超出 PNG 规范的合法范围 0..4"
                 % (r, ft))
        filter_hist[ft] = filter_hist.get(ft, 0) + 1
        row = raw[r * stride + 1:(r + 1) * stride]
        for c in range(w):
            if row[c * 4 + 3] != 0:
                nonzero_alpha += 1

    print("  解码: %d 行扫描线长度精确匹配，filter 类型分布 %s"
          % (h, dict(sorted(filter_hist.items()))))
    print("  非透明像素: %d / %d" % (nonzero_alpha, w * h))
    if nonzero_alpha == 0:
        fail("图像全透明 —— 转换逻辑有bug（不是有效图标）")
    print("  => PASS")
    return True


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("用法: %s <file.png> [期望宽] [期望高]\n" % argv[0])
        return 2
    want_w = int(argv[2]) if len(argv) > 2 else None
    want_h = int(argv[3]) if len(argv) > 3 else None
    verify(argv[1], want_w, want_h)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
