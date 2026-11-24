"""Build profile-managed comparison sheets and per-render RGB/luma statistics."""
from collections import defaultdict
from colorsys import rgb_to_hsv
import csv
from io import BytesIO
from pathlib import Path
import sys

from PIL import Image, ImageChops, ImageCms, ImageDraw, ImageFont, ImageOps, ImageStat

ROOT = Path(sys.argv[1])
LOOKS = ["editorial", "leicaM6", "chroma", "afterHours", "sunprint", "atmosphere", "monochrome"]
NAMES = ["EDITORIAL", "LEICA M6", "CHROMA", "AFTER HOURS", "SUNPRINT", "ATMOSPHERE", "MONOCHROME"]
srgb = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB"))
font = ImageFont.load_default(size=14)


def open_rgb(path, proof=True, crop=None):
    with Image.open(path) as source:
        icc = source.info.get("icc_profile")
        if crop:
            x, y = int(source.width * crop[0]), int(source.height * crop[1])
            im = source.crop((x, y, x + 480, y + 480)).convert("RGB")
        else:
            im = ImageOps.exif_transpose(source).convert("RGB")
    if proof and icc:
        im = ImageCms.profileToProfile(im, ImageCms.ImageCmsProfile(BytesIO(icc)), srgb)
    return im


def sheet(rows, path, width, height):
    cols = max(len(row) for _, row in rows)
    image = Image.new("RGB", (cols * width, len(rows) * (height + 51)), "#202020")
    draw = ImageDraw.Draw(image)
    for i, (title, row) in enumerate(rows):
        y = i * (height + 51)
        draw.text((8, y + 4), title, fill="white", font=font)
        for j, (label, asset) in enumerate(row):
            im = open_rgb(asset)
            im.thumbnail((width - 9, height), Image.Resampling.LANCZOS)
            image.paste(im, (j * width + (width - im.width) // 2, y + 25 + (height - im.height) // 2))
            draw.text((j * width + 5, y + height + 27), label, fill="white", font=font)
    image.save(path, quality=94, icc_profile=srgb.tobytes())


def quantile(hist, p):
    total = sum(hist) * p
    for i, count in enumerate(hist):
        total -= count
        if total <= 0:
            return i
    return 255


def stats(path):
    im = open_rgb(path, proof=False)
    # Profile-native encoded luma proxy and RGB spread. Clipping counts use the original profile.
    luma = im.convert("L")
    hist = luma.histogram()
    px = list(im.resize((256, 256)).get_flattened_data())
    spread = sum(max(p) - min(p) for p in px) / len(px)
    n = im.width * im.height
    r, g, b = im.split()
    all_white = sum(ImageChops.darker(ImageChops.darker(r, g), b).histogram()[254:]) / n
    any_white = sum(ImageChops.lighter(ImageChops.lighter(r, g), b).histogram()[254:]) / n
    return [*im.size, *(quantile(hist, q) for q in (.05, .50, .95, .99)),
            round(spread, 2), round(100 * any_white, 4), round(100 * all_white, 4),
            round(100 * sum(hist[:4]) / n, 4)]


images = defaultdict(dict)
for path in sorted((ROOT / "renders").glob("*.jpg")):
    scene, label = path.stem.split("__", 1)
    images[scene][label] = path

out = ROOT / "comparisons"
out.mkdir(exist_ok=True)
for scene, paths in images.items():
    if not all(k in paths for k in LOOKS):
        continue
    sheet([(scene, [(label, paths[k]) for k, label in zip(LOOKS, NAMES)])],
          out / f"{scene}-seven.jpg", 210, 265)
    if all("before-" + k in paths for k in LOOKS[:4]):
        pairs = [(k, label) for k, label in zip(LOOKS[:4], NAMES)]
        sheet([(scene + " / frozen revision 27", [(label, paths["before-" + k]) for k, label in pairs]),
               (scene + " / rebuilt collection", [(label, paths[k]) for k, label in pairs])],
              out / f"{scene}-before-after.jpg", 292, 350)

with (ROOT / "measurements.csv").open("w", newline="") as f:
    writer = csv.writer(f)
    writer.writerow(["scene", "look", "width", "height", "Y05", "Y50", "Y95", "Y99",
                     "mean_channel_spread", "pct_any_channel_254", "pct_all_channels_254", "pct_luma_le_3"])
    for scene, paths in images.items():
        for label, path in paths.items():
            if not label.startswith("archived-"):
                writer.writerow([scene, label, *stats(path)])


native = ROOT / "native"
detail = [("MONOCHROME / 12 MP", native / "IMG_6931__monochrome.jpg", (0.36, 0.32)),
          ("CHROMA / 48 MP", native / "IMG_6932__chroma.jpg", (0.45, 0.31))]
if all(path.exists() for _, path, _ in detail):
    crops = Image.new("RGB", (1000, 535), "#202020")
    draw = ImageDraw.Draw(crops)
    for i, (label, path, (fx, fy)) in enumerate(detail):
        crops.paste(open_rgb(path, crop=(fx, fy)), (i * 500 + 10, 12))
        draw.text((i * 500 + 10, 503), label + " / native pixels", fill="white", font=font)
    crops.save(out / "native-detail.jpg", quality=95, icc_profile=srgb.tobytes())

# The coordinates are normalized to the matched full frames.
regions = {
    "IMG_6931": {"cheek": (.340, .253, .369, .274), "white wall": (.73, .19, .85, .28),
                 "sleeve": (.235, .435, .28, .508), "dark doorway": (.06, .18, .18, .31)},
    "Apple-iPhone-12-Pro": {"blue sky": (.45, .29, .56, .33), "water": (.39, .53, .52, .59),
                           "grasses": (.52, .75, .63, .82)},
}
with (ROOT / "regions.csv").open("w", newline="") as f:
    writer = csv.writer(f)
    writer.writerow(["scene", "look", "region", "RGB mean (P3)", "HSV hue of mean (deg)",
                     "encoded luma mean", "mean horizontal one-pixel luma difference"])
    for scene, boxes in regions.items():
        for label, path in images[scene].items():
            if label.startswith("archived-"):
                continue
            im = open_rgb(path, proof=False)
            for name, (x0, y0, x1, y1) in boxes.items():
                region = im.crop((int(x0 * im.width), int(y0 * im.height),
                                  int(x1 * im.width), int(y1 * im.height)))
                rgb = ImageStat.Stat(region).mean
                hue, saturation, _ = rgb_to_hsv(*[v / 255 for v in rgb])
                luma = region.convert("L")
                pixels = luma.get_flattened_data()
                w, h = luma.size
                edge = sum(abs(pixels[y*w+x] - pixels[y*w+x-1])
                           for y in range(h) for x in range(1, w)) / ((w-1)*h)
                writer.writerow([scene, label, name, "/".join(f"{v:.1f}" for v in rgb),
                                 round(hue * 360, 1) if saturation > 0.015 else "",
                                 round(ImageStat.Stat(luma).mean[0], 2), round(edge, 3)])
