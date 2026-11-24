import sys, glob, os
from PIL import Image, ImageDraw, ImageFont
src, dst = sys.argv[1], sys.argv[2]; os.makedirs(dst, exist_ok=True)
font = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', 22)
names = sorted({os.path.basename(p).split('__')[0] for p in glob.glob(src + '/*__*.jpg')})
for look in ['editorial', 'leicaM6']:
    for n in names:
        order = [('A-apple', 'A  Apple default development'), (f'B-apple+{look}', f'B  Apple dev + {look} (= viewfinder path)'),
                 (f'C-engine2+{look}', f'C  engine 2 (before)'), (f'D-new+{look}', f'D  engine 2 rev 2 (after)')]
        ims = []
        for key, label in order:
            p = f'{src}/{n}__{key}.jpg'
            if not os.path.exists(p): break
            im = Image.open(p); im.thumbnail((560, 560)); ims.append((im, label))
        if len(ims) < 4: continue
        w = sum(i.width for i, _ in ims) + 10 * 3; h = max(i.height for i, _ in ims) + 36
        s = Image.new('RGB', (w, h), (24, 24, 24)); d = ImageDraw.Draw(s); x = 0
        for im, label in ims:
            s.paste(im, (x, 36)); d.text((x + 6, 6), label, fill='white', font=font); x += im.width + 10
        s.save(f'{dst}/{n}__{look}.jpg', quality=90)
print(sorted(os.listdir(dst)))
