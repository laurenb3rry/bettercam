"""Comparison sheets: sheet.py out.jpg [--h 900] [--crop x0,y0,x1,y1] label=path ...
Every tile is converted from its embedded ICC profile (Display P3) to sRGB, so the sheet views correctly anywhere.
--crop takes fractions of the frame (applied to every tile; for matched-framing zoom crops)."""
import io, sys
from PIL import Image, ImageCms, ImageDraw

args = sys.argv[1:]
out, h, crop, tiles = args[0], 900, None, []
i = 1
while i < len(args):
    if args[i] == "--h": h = int(args[i + 1]); i += 2; continue
    if args[i] == "--crop": crop = [float(v) for v in args[i + 1].split(",")]; i += 2; continue
    label, _, path = args[i].rpartition("=") if "=" in args[i] else ("", "", args[i])
    tiles.append((label, path)); i += 1

srgb = ImageCms.createProfile("sRGB")
def load(path):
    im = Image.open(path)
    icc = im.info.get("icc_profile")
    im = im.convert("RGB")
    if icc:
        im = ImageCms.profileToProfile(im, ImageCms.ImageCmsProfile(io.BytesIO(icc)), srgb, outputMode="RGB")
    if crop:
        W, H = im.size
        im = im.crop((int(crop[0] * W), int(crop[1] * H), int(crop[2] * W), int(crop[3] * H)))
    return im.resize((max(1, round(im.width * h / im.height)), h), Image.LANCZOS)

ims = [(l, load(p)) for l, p in tiles]
pad, top = 8, 26
W = sum(im.width for _, im in ims) + pad * (len(ims) + 1)
sheet = Image.new("RGB", (W, h + top + pad), (240, 240, 240))
d = ImageDraw.Draw(sheet)
x = pad
for l, im in ims:
    sheet.paste(im, (x, top))
    d.text((x, 6), l, fill=(20, 20, 20))
    x += im.width + pad
sheet.save(out, quality=90)
