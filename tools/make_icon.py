#!/usr/bin/env python3
"""Génère l'icône de Pal (1024x1024, sans transparence) avec la seule bibliothèque standard,
puis crée le catalogue d'assets Sources/Assets.xcassets/AppIcon.appiconset."""
import json
import math
import os
import struct
import sys
import zlib

SIZE = 1024
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
CATALOG = os.path.join(ROOT, "Sources", "Assets.xcassets")
ICONSET = os.path.join(CATALOG, "AppIcon.appiconset")


def clamp(v, lo=0.0, hi=1.0):
    return lo if v < lo else hi if v > hi else v


def smooth(edge_dist, width=1.6):
    """Couverture anti-crénelée à partir d'une distance signée (négatif = dedans)."""
    return clamp(0.5 - edge_dist / width)


def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def rounded_rect(px, py, cx, cy, hw, hh, r):
    qx = abs(px - cx) - (hw - r)
    qy = abs(py - cy) - (hh - r)
    outside = math.hypot(max(qx, 0.0), max(qy, 0.0))
    inside = min(max(qx, qy), 0.0)
    return outside + inside - r


def triangle(px, py, a, b, c):
    def edge(p, q):
        ex, ey = q[0] - p[0], q[1] - p[1]
        t = clamp(((px - p[0]) * ex + (py - p[1]) * ey) / (ex * ex + ey * ey))
        return math.hypot(px - (p[0] + ex * t), py - (p[1] + ey * t))

    d = min(edge(a, b), edge(b, c), edge(c, a))

    def side(p, q):
        return (q[0] - p[0]) * (py - p[1]) - (q[1] - p[1]) * (px - p[0])

    s1, s2, s3 = side(a, b), side(b, c), side(c, a)
    inside = (s1 >= 0 and s2 >= 0 and s3 >= 0) or (s1 <= 0 and s2 <= 0 and s3 <= 0)
    return -d if inside else d


def sparkle(px, py, cx, cy, radius, pinch=0.16):
    """Étoile à 4 branches : distance approchée par une astroïde adoucie."""
    x, y = abs(px - cx), abs(py - cy)
    n = 0.62
    f = (x / radius) ** n + (y / radius) ** n
    # f == 1 sur le contour ; on convertit en pseudo-distance en pixels
    return (f - 1.0) * radius * pinch * 3.2


def build():
    top = (38, 28, 140)       # indigo profond
    bottom = (30, 140, 255)   # bleu vif
    glow = (120, 90, 255)
    white = (255, 255, 255)
    spark_col = (255, 196, 64)

    rows = []
    for y in range(SIZE):
        row = bytearray()
        for x in range(SIZE):
            t = clamp((x * 0.35 + y * 0.65) / SIZE)
            color = mix(top, bottom, t)

            # halo lumineux en haut à gauche
            gx, gy = x - SIZE * 0.25, y - SIZE * 0.18
            g = clamp(1.0 - math.hypot(gx, gy) / (SIZE * 0.75)) ** 2
            color = mix(color, glow, g * 0.45)

            # bulle de discussion (corps arrondi + queue)
            d_body = rounded_rect(x, y, SIZE * 0.5, SIZE * 0.47, SIZE * 0.30, SIZE * 0.235, SIZE * 0.115)
            d_tail = triangle(
                x, y,
                (SIZE * 0.33, SIZE * 0.62),
                (SIZE * 0.30, SIZE * 0.80),
                (SIZE * 0.50, SIZE * 0.68),
            )
            d_bubble = min(d_body, d_tail)

            # ombre douce sous la bulle
            shadow = clamp(1.0 - max(d_bubble + 6, 0) / 46.0) ** 2 * 0.28
            color = mix(color, (10, 10, 60), shadow)

            cov = smooth(d_bubble)
            if cov > 0:
                color = mix(color, white, cov)

                # étincelle dorée dans la bulle
                d_star = sparkle(x, y, SIZE * 0.5, SIZE * 0.47, SIZE * 0.17)
                c2 = smooth(d_star, 2.0)
                if c2 > 0:
                    color = mix(color, spark_col, c2 * cov)

            row += bytes((int(clamp(color[0] / 255) * 255),
                          int(clamp(color[1] / 255) * 255),
                          int(clamp(color[2] / 255) * 255)))
        rows.append(bytes(row))
    return rows


def write_png(path, rows):
    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + r for r in rows)
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0))  # RGB 8 bits, sans alpha
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def main():
    os.makedirs(ICONSET, exist_ok=True)
    write_png(os.path.join(ICONSET, "icon.png"), build())
    with open(os.path.join(CATALOG, "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
    with open(os.path.join(ICONSET, "Contents.json"), "w") as f:
        json.dump({
            "images": [{"filename": "icon.png", "idiom": "universal",
                        "platform": "ios", "size": "1024x1024"}],
            "info": {"author": "xcode", "version": 1},
        }, f, indent=2)
    print("Icône générée :", os.path.join(ICONSET, "icon.png"))


if __name__ == "__main__":
    sys.exit(main())
