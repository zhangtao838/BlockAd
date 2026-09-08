#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make-icons.py — 生成 BlockAd 设置图标（纯 Python，无第三方依赖）
产物：Prefs/Resources/BlockAdIcon{,.png,@2x,@3x}
图案：圆角蓝底 + 白色盾牌 + 红色斜杠（"拦截"语义），4x 超采样抗锯齿
"""
import pathlib
import struct
import zlib

HERE = pathlib.Path(__file__).resolve().parent.parent
OUT = HERE / "Prefs" / "Resources"


def _png(width, height, pixels):
    def chunk(typ, data):
        c = struct.pack(">I", len(data)) + typ + data
        c += struct.pack(">I", zlib.crc32(typ + data) & 0xFFFFFFFF)
        return c

    raw = b"".join(
        b"\x00" + b"".join(struct.pack("4B", *px) for px in row) for row in pixels
    )
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def _in_rounded_rect(x, y, S, m, r):
    if x < m or x >= S - m or y < m or y >= S - m:
        return False
    # 四个圆角外区
    for cx, cy in ((m + r, m + r), (S - 1 - m - r, m + r),
                   (m + r, S - 1 - m - r), (S - 1 - m - r, S - 1 - m - r)):
        if x < cx - r or x > cx + r or y < cy - r or y > cy + r:
            continue
        if (x - cx) ** 2 + (y - cy) ** 2 > r * r:
            # 该点可能落在圆角矩形外：需要更精确判定
            return False  # 粗略：落在角圆范围外即剔除
    return True


def _in_poly(x, y, poly):
    inside = False
    n = len(poly)
    j = n - 1
    for i in range(n):
        xi, yi = poly[i]
        xj, yj = poly[j]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
            inside = not inside
        j = i
    return inside


def _seg_dist(x, y, ax, ay, bx, by):
    vx, vy = bx - ax, by - ay
    wx, wy = x - ax, y - ay
    t = (wx * vx + wy * vy) / (vx * vx + vy * vy)
    t = max(0.0, min(1.0, t))
    px, py = ax + t * vx, ay + t * vy
    return ((x - px) ** 2 + (y - py) ** 2) ** 0.5


def _render(size, ss=4):
    S = size
    m = S * 0.08        # 边距
    r = S * 0.20        # 圆角半径
    shield = [
        (S * 0.50, S * 0.10),
        (S * 0.82, S * 0.17),
        (S * 0.82, S * 0.52),
        (S * 0.50, S * 0.90),
        (S * 0.18, S * 0.52),
        (S * 0.18, S * 0.17),
    ]
    bg = (0.20, 0.47, 0.96)      # #3478F6
    white = (1.0, 1.0, 1.0)
    red = (1.0, 0.23, 0.19)      # #FF3B30
    slash_a = (S * 0.30, S * 0.32)
    slash_b = (S * 0.70, S * 0.68)
    slash_w = S * 0.075

    supers = size * ss
    buf = []
    for y in range(size):
        row = []
        for x in range(size):
            acc = [0.0, 0.0, 0.0]
            for dy in range(ss):
                for dx in range(ss):
                    sx = x * ss + dx + 0.5
                    sy = y * ss + dy + 0.5
                    if _in_rounded_rect(sx, sy, supers, m * ss, r * ss):
                        if _seg_dist(sx, sy, slash_a[0] * ss, slash_a[1] * ss,
                                    slash_b[0] * ss, slash_b[1] * ss) <= slash_w * ss:
                            c = red
                        elif _in_poly(sx, sy, [(a * ss, b * ss) for a, b in shield]):
                            c = white
                        else:
                            c = bg
                    else:
                        c = (0, 0, 0)
                    acc[0] += c[0] * 255
                    acc[1] += c[1] * 255
                    acc[2] += c[2] * 255
            n = ss * ss
            row.append((int(acc[0] / n + 0.5), int(acc[1] / n + 0.5),
                        int(acc[2] / n + 0.5), 255))
        buf.append(row)
    return _png(size, size, buf)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    targets = {
        "BlockAdIcon.png": 29,
        "BlockAdIcon@2x.png": 58,
        "BlockAdIcon@3x.png": 87,
    }
    for name, size in targets.items():
        data = _render(size)
        (OUT / name).write_bytes(data)
        print(f"[OK] {OUT / name}  ({size}x{size}, {len(data)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())