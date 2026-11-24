"""Build local contact sheets and measure display-referred OkLCh, using Pillow."""
import csv
import io
from functools import lru_cache
from pathlib import Path
from statistics import median
from math import atan2, degrees, hypot

from PIL import Image, ImageCms, ImageDraw, ImageOps

OUTPUT = Path("research/phase22-leica")
REFERENCES = Path("research/leica_m6_pack/references")
PROOF = ImageCms.createProfile("sRGB")
# Normalized source coordinates, measured after applying EXIF orientation.
CROPS = {
    "Scotland": {"sky": (.32, .04, .65, .15), "warm fur": (.40, .35, .65, .53),
                 "green and dry grasses": (.72, .66, .96, .91)},
    "SF-sidewalk": {"sky": (.28, .22, .56, .36), "trim": (.72, .33, .87, .47)},
    "SF-tree": {"canopy": (.27, .35, .55, .53), "brick": (.82, .46, .97, .59)},
    "street2": {"sky": (.19, .08, .51, .24)},
    "Apple-iPhone-12-Pro": {"sky": (.45, .17, .71, .29), "water": (.24, .51, .58, .63)},
    "IMG_6931": {"face": (.29, .19, .39, .31), "white wall": (.73, .10, .92, .36)},
    "IMG_6932": {"face": (.38, .22, .49, .33)},
    "IMG_6934": {"screen": (.57, .40, .80, .51), "shadow texture": (.28, .63, .65, .79)},
    "steve": {"face": (.41, .25, .55, .38), "jacket": (.40, .47, .62, .65)},
    "clouds": {"clouds and sky": (.20, .18, .64, .49)},
}

REFERENCE_CROPS = [
    {"sunset": (.24,.16,.77,.33), "water": (.32,.77,.65,.92)},
    {"water": (.64,.43,.93,.69), "varnish": (.42,.32,.60,.46)},
    {"cabinet": (.71,.66,.93,.84), "floor": (.37,.79,.63,.94)},
    {"teal metal": (.05,.19,.45,.32), "lamp": (.71,.12,.94,.23)},
    {"pink": (.31,.27,.74,.48), "water": (.21,.68,.50,.84)},
    {"sunlit snow": (.55,.82,.86,.95), "sky": (.20,.15,.64,.30)},
    {"dirt track": (.53,.37,.90,.45), "silhouette": (.52,.66,.88,.90)},
    {"lavender water": (.19,.70,.58,.93), "pink": (.19,.21,.59,.42)},
    {"sky": (.37,.13,.68,.24), "rock and foliage": (.72,.65,.92,.86)},
    {"hills": (.56,.42,.77,.48), "white fabric": (.26,.41,.42,.54)},
    {"grass and soil": (.52,.73,.83,.88), "sky": (.34,.10,.58,.24)},
    {"cyan water": (.39,.50,.70,.58), "arch": (.29,.08,.48,.27)},
    {"canopy": (.65,.11,.81,.24), "arm and face": (.39,.40,.55,.55)},
]


def load(path, side):
    with Image.open(path) as source:
        source.draft("RGB", (side, side))
        image = ImageOps.exif_transpose(source)
        image.thumbnail((side, side), Image.Resampling.LANCZOS)
        return image.convert("RGB")


def crop(image, region):
    x0, y0, x1, y1 = region
    return image.crop((round(x0 * image.width), round(y0 * image.height),
                       round(x1 * image.width), round(y1 * image.height)))


def sheet(rows, destination, size=320):
    columns = max(map(len, rows))
    canvas = Image.new("RGB", (columns * size, len(rows) * (size + 24)), "#191919")
    draw = ImageDraw.Draw(canvas)
    for y, row in enumerate(rows):
        for x, (label, image) in enumerate(row):
            image.thumbnail((size - 12, size - 12), Image.Resampling.LANCZOS)
            left = x * size
            top = y * (size + 24)
            if image.info.get("icc_profile"):
                image = ImageCms.profileToProfile(image, io.BytesIO(image.info["icc_profile"]), PROOF)
            canvas.paste(image, (left + (size - image.width) // 2, top + (size - image.height) // 2))
            draw.text((left + 7, top + size), label, fill="white")
    canvas.save(destination, quality=92, icc_profile=ImageCms.ImageCmsProfile(PROOF).tobytes())


@lru_cache(maxsize=65536)
def oklch(rgb):
    def linear(v):
        v /= 255
        return v / 12.92 if v <= .04045 else ((v + .055) / 1.055) ** 2.4

    r, g, b = map(linear, rgb)
    l = (.41222147*r + .53633254*g + .05144599*b)**(1/3)
    m = (.21190350*r + .68069955*g + .10739696*b)**(1/3)
    s = (.08830246*r + .28171884*g + .62997870*b)**(1/3)
    a = 1.97799850*l - 2.42859221*m + .45059371*s
    bb = .02590404*l + .78277177*m - .80867577*s
    return .21045426*l + .79361779*m - .00407205*s, hypot(a, bb), degrees(atan2(bb, a)) % 360


def rgb_pixels(image):
    return image.get_flattened_data() if hasattr(image, "get_flattened_data") else image.getdata()


def measure(name, image, writer):
    if image.info.get("icc_profile"):
        image = ImageCms.profileToProfile(image, io.BytesIO(image.info["icc_profile"]), PROOF)
    image.thumbnail((260, 260), Image.Resampling.LANCZOS)
    pixels = list(rgb_pixels(image))
    labs = [oklch(p) for p in pixels]
    light = sorted(l for l, _, _ in labs)
    n = len(labs)
    subsets = [[c for l, c, _ in labs if lo <= l < hi] for lo, hi in [(0, .38), (.38, .73), (.73, 1.001)]]
    # Hue ranges use medians away from the angular wrap.
    sectors = [[(l, c, h) for l, c, h in labs if lo <= h < hi and c > .035]
               for lo, hi in [(20, 100), (100, 165), (165, 235), (235, 285), (285, 360)]]
    sector_rows = ["/".join(f"{median(v):.3f}" for v in zip(*sector)) if sector else "" for sector in sectors]
    w, h = image.size
    edges = [abs(labs[y*w+x][0] - (labs[y*w+x-1][0] + labs[y*w+x+1][0]
                                  + labs[(y-1)*w+x][0] + labs[(y+1)*w+x][0]) / 4)
             for y in range(1,h-1) for x in range(1,w-1)]
    neutrals = [c for l, c, _ in labs if l >= .78 and c < .028]
    writer.writerow([name, *(f"{light[round((n-1)*q)]:.3f}" for q in [.01, .05, .5, .95, .99]),
                     *(f"{median(v):.3f}" if v else "" for v in subsets),
                     f"{100*sum(max(p)<=2 for p in pixels)/n:.2f}",
                     f"{100*sum(min(p)>=253 for p in pixels)/n:.2f}",
                     f"{100*sum(max(p)>=254 for p in pixels)/n:.2f}",
                     f"{median(neutrals):.3f}" if neutrals else "",
                     f"{1000 * sum(edges) / max(len(edges), 1):.2f}", *sector_rows])


references = sorted(REFERENCES.glob("*.jpg"))
assert len(references) == 13, references
refs = [(p.stem, load(p, 680)) for p in references]
sheet([refs[i:i+4] for i in range(0, len(refs), 4)], OUTPUT / "references.jpg")
modes = ["input", "r26", "m6"]
rows, details = [], []
with (OUTPUT / "oklch.csv").open("w", newline="") as handle:
    writer = csv.writer(handle)
    writer.writerow(["image", "L01", "L05", "L50", "L95", "L99", "C_dark", "C_mid", "C_bright",
                     "black_pct", "white_pct", "high_channel_pct", "near_white_C", "edge_residual_x1000", "warm_L/C/h", "green_L/C/h",
                     "cyan_L/C/h", "blue_L/C/h", "magenta_L/C/h"])
    for (name, image), regions in zip(refs, REFERENCE_CROPS):
        measure(name, image.copy(), writer)
        for label, box in regions.items():
            measure(f"{name} {label}", crop(image, box), writer)
    for path in sorted(OUTPUT.glob("*-input.jpg")):
        stem = path.name.removesuffix("-input.jpg")
        files = [OUTPUT / f"{stem}-{mode}.jpg" for mode in modes]
        if not all(p.exists() for p in files):
            continue
        name = stem
        if stem.startswith("bettercam-"):
            name = "SF-sidewalk" if "-131051-" in stem else "SF-tree"
        images = [load(p, 1200) for p in files]
        rows.append([(f"{name} / {mode}", im.copy()) for mode, im in zip(modes, images)])
        for mode, image in zip(modes, images):
            measure(f"{name}/{mode}", image.copy(), writer)
        for label, box in CROPS.get(name, {}).items():
            row = [(f"{name} {label} / {mode}", crop(im, box)) for mode, im in zip(modes, images)]
            details.append(row)
            for tag, im in row:
                measure(tag, im.copy(), writer)
if rows:
    sheet(rows, OUTPUT / "overview.jpg")
if details:
    sheet(details[:8], OUTPUT / "crops.jpg", size=250)
    sheet(details[8:], OUTPUT / "crops-street-and-portrait.jpg", size=250)
gain_rows = []
for path in sorted(OUTPUT.glob("*-gain-off.jpg")):
    name = path.name.removesuffix("-gain-off.jpg")
    on = OUTPUT / f"{name}-m6.jpg"
    if on.exists():
        gain_rows.append([(f"{name} / gain on", load(on, 640)), (f"{name} / gain off", load(path, 640))])
if gain_rows:
    sheet(gain_rows, OUTPUT / "gain-map.jpg")

native_rows = []
for path in sorted(OUTPUT.glob("*-m6-full.jpg")):
    name = path.name.removesuffix("-m6-full.jpg")
    preview = OUTPUT / f"{name}-m6.jpg"
    if not preview.exists():
        continue
    small, full = [load(p, 300) for p in (preview, path)]
    assert small.size == full.size, name
    errors = sorted(abs(a - b) for p, q in zip(rgb_pixels(small), rgb_pixels(full)) for a, b in zip(p, q))
    print(f"{name}: 300 px small versus native JPEG p95 channel delta = {errors[int(len(errors)*.95)]}/255 (P3)")
    native = [(mode, load(p, 2400)) for mode in modes
              if (p := OUTPUT / f"{name}-{mode}-full.jpg").exists()]
    for label, box in CROPS.get(name, {}).items():
        native_rows.append([(f"{name} {label} / {mode}", crop(im, box)) for mode, im in native])
if native_rows:
    sheet(native_rows, OUTPUT / "crops-native.jpg", size=290)
