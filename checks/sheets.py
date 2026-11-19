#!/usr/bin/env python3
"""Contact sheets for checks/compare output (needs Pillow): python3 checks/sheets.py research/phase1 [apple_originals_dir]
Per source: variants side by side, L* histogram under each, then 100% crops of the brightest and a dark-but-textured
400 px tile (picked automatically on the D render so every variant is cropped at the same place)."""
import json, os, sys
from PIL import Image, ImageDraw, ImageOps, ImageStat

root = sys.argv[1]
apple = sys.argv[2] if len(sys.argv) > 2 else None
metrics = json.load(open(os.path.join(root, "metrics.json")))
os.makedirs(os.path.join(root, "sheets"), exist_ok=True)
NAMES = {"A": "A production (Editorial)", "B": "B fixed decode + old curve", "C": "C fixed decode + new curve",
         "D": "D Natural Reference", "apple": "Apple Camera original",
         "A_sunStudy": "A Sun Study", "C_sunStudy": "C Sun Study", "A_alpine": "A Alpine", "C_alpine": "C Alpine"}
TILE, W = 400, 640


def histogram(hist, w=W, h=90):
    im = Image.new("RGB", (w, h), (24, 24, 24))
    d = ImageDraw.Draw(im)
    top = max(hist[1:-1]) or 1
    for i, v in enumerate(hist):
        x = int(i * (w - 1) / 100)
        d.line([(x, h - 1), (x, h - 1 - int(min(v / top, 1) * (h - 14)))], fill=(200, 200, 200), width=max(1, w // 101))
    for L in (25, 50, 75):  # quarter marks in L*
        x = int(L * (w - 1) / 100); d.line([(x, 0), (x, 6)], fill=(255, 80, 80))
    return im


def pick_tiles(img):
    """(bright, dark) tile boxes: brightest mean L; darkest tile that still has texture (stddev)."""
    f = 8
    small = img.convert("L").reduce(f)
    tiles = []
    for y in range(0, img.height - TILE, TILE // 2):
        for x in range(0, img.width - TILE, TILE // 2):
            st = ImageStat.Stat(small.crop((x // f, y // f, (x + TILE) // f, (y + TILE) // f)))
            tiles.append((st.mean[0], st.stddev[0], (x, y, x + TILE, y + TILE)))
    bright = max(tiles, key=lambda t: t[0])[2]
    textured = [t for t in tiles if t[1] > 6 and t[0] > 8] or tiles
    dark = min(textured, key=lambda t: t[0])[2]
    return bright, dark


def sheet(name, variants, out):
    imgs = {}
    for v in variants:
        p = os.path.join(root, "full", f"{name}_{v}.jpg") if v != "apple" else apple_path(name)
        if p and os.path.exists(p):
            imgs[v] = ImageOps.exif_transpose(Image.open(p)).convert("RGB")
    ref = imgs.get("D") or next(iter(imgs.values()))
    bright, dark = pick_tiles(ref)
    cols = list(imgs)
    th = int(W * ref.height / ref.width)
    H = 24 + th + 90 + 2 * (W // 2 + 24) + 40
    canvas = Image.new("RGB", (W * len(cols), H), (12, 12, 12))
    d = ImageDraw.Draw(canvas)
    for i, v in enumerate(cols):
        im = imgs[v]
        x0 = i * W
        d.text((x0 + 6, 6), NAMES.get(v, v), fill=(255, 255, 255))
        canvas.paste(im.resize((W, th), Image.LANCZOS), (x0, 24))
        o = metrics.get(name, {}).get("outputs", {}).get(v)
        if o:
            canvas.paste(histogram(o["Lhist"]), (x0, 24 + th))
            L = o["Lpct"]
            d.text((x0 + 6, 24 + th + 2), f"L* p5 {L['p5']:.0f}  p50 {L['p50']:.0f}  p99 {L['p99']:.0f}  p99.9 {L['p99_9']:.0f}", fill=(255, 220, 120))
        y = 24 + th + 90
        for label, box in (("100% highlight", bright), ("100% shadow", dark)):
            crop = im.crop(box) if im.size == ref.size else im.resize(ref.size).crop(box)
            d.text((x0 + 6, y + 4), label, fill=(160, 160, 160))
            canvas.paste(crop.resize((W // 2, W // 2), Image.NEAREST), (x0 + W // 4, y + 24))
            y += W // 2 + 24
    canvas.save(out, quality=88)


def apple_path(name):
    if not apple:
        return None
    for ext in (".HEIC", ".JPEG", ".jpg"):
        p = os.path.join(apple, name + ext)
        if os.path.exists(p):
            return p


for name, e in metrics.items():
    base = ["A", "B", "C", "D"] if e["raw"] else ["apple", "A", "C", "D"]
    sheet(name, base, os.path.join(root, "sheets", f"{name}.jpg"))
    sheet(name, ["A_sunStudy", "C_sunStudy", "A_alpine", "C_alpine", "D"], os.path.join(root, "sheets", f"{name}_presets.jpg"))
    print(name)
