#!/usr/bin/env python3
"""CIELAB L*, C*, h° of representative materials (median of a small box) across variants. Display P3 JPEGs, D65.
python3 checks/patches.py research/phase1   (patch positions are fractions of width/height, picked by eye on the sheets)"""
import os, sys, math
from PIL import Image, ImageOps
root = sys.argv[1]
PATCHES = {
    "IMG_2026_11_17-15_48_36_7810_6677F5E3": {"brick": (0.50, 0.12), "skin woman": (0.32, 0.40), "skin man": (0.58, 0.40), "leather": (0.70, 0.58), "denim": (0.25, 0.80)},
    "IMG_1791": {"sky": (0.5, 0.08), "skin back": (0.66, 0.70), "foliage": (0.15, 0.55), "water": (0.2, 0.85)},
    "IMG_1927": {"sky": (0.3, 0.10), "snow": (0.68, 0.36), "rock": (0.15, 0.88), "trees": (0.86, 0.62)},
    "IMG_1895": {"snow": (0.3, 0.14), "water": (0.6, 0.55), "trees": (0.12, 0.55), "rock": (0.75, 0.85)},
    "20261117-142955-117": {"window": (0.15, 0.38), "wall": (0.9, 0.6), "exit sign": (0.73, 0.14)},
    "20261117-141652-993": {"skin face": (0.43, 0.28), "leather": (0.27, 0.58), "jeans": (0.45, 0.88), "white wall": (0.6, 0.15)},
    "20261117-134922-340": {"window": (0.32, 0.38), "sofa": (0.3, 0.75), "brick": (0.85, 0.3), "floor": (0.55, 0.7)},
    "20261118-144444-948": {"wall/tile": (0.55, 0.6), "wood": (0.3, 0.9)},
}
M = [[0.4865709, 0.2656677, 0.1982173], [0.2289746, 0.6917385, 0.0792869], [0.0, 0.0451134, 1.0439444]]  # P3→XYZ
def lin(v): v /= 255; return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
def lab(rgb):
    r, g, b = map(lin, rgb)
    X, Y, Z = (m[0] * r + m[1] * g + m[2] * b for m in M)
    f = lambda t: t ** (1 / 3) if t > 0.008856 else 7.787 * t + 16 / 116
    fx, fy, fz = f(X / 0.95047), f(Y), f(Z / 1.08883)
    L, a, bb = 116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)
    return L, math.hypot(a, bb), math.degrees(math.atan2(bb, a)) % 360
def patch(path, u, v):
    im = ImageOps.exif_transpose(Image.open(path)).convert("RGB").reduce(4)
    w, h = im.size; s = max(4, w // 60)
    box = im.crop((int(u * w) - s, int(v * h) - s, int(u * w) + s, int(v * h) + s))
    px = sorted(box.getdata(), key=sum)
    return lab(px[len(px) // 2])
for name, ps in PATCHES.items():
    vs = [("apple", os.path.join(root, "apple", name + ".jpg"))] + [(v, os.path.join(root, "full", f"{name}_{v}.jpg")) for v in "ABCD"]
    vs = [(v, p) for v, p in vs if os.path.exists(p)]
    print(f"\n{name}\n  {'material':12s}" + "".join(f"{v:>20s}" for v, _ in vs))
    for mat, (u, v) in ps.items():
        print(f"  {mat:12s}" + "".join("%20s" % ("L%3.0f C%3.0f h%4.0f" % patch(p, u, v)) for _, p in vs))
