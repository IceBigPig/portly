"""Render the code-defined Portly chip mark to desktop/web icon sizes (Pillow)."""
from pathlib import Path
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parent.parent
size = 1024
image = Image.new('RGBA', (size, size))
mask = Image.new('L', (size, size))
ImageDraw.Draw(mask).rounded_rectangle((16, 16, 1008, 1008), radius=248, fill=255)
pixels = image.load()
for y in range(size):
    for x in range(size):
        t = (x + y) / (2 * size)
        pixels[x, y] = (int(84 - 34*t), int(132 - 27*t), int(255 - 9*t), 255)
image.putalpha(mask)
draw = ImageDraw.Draw(image)
draw.rounded_rectangle((296, 296, 728, 728), radius=88, outline='white', width=40)
draw.rounded_rectangle((424, 424, 600, 600), radius=32, outline='white', width=36)
for p in [410, 512, 614]:
    for line in [(p, 216, p, 296), (p, 728, p, 808), (216, p, 296, p), (728, p, 808, p)]:
        draw.line(line, fill='white', width=40)
        for x, y in [line[:2], line[2:]]:
            draw.ellipse((x-20, y-20, x+20, y+20), fill='white')
for n in [16, 32, 64, 128, 256, 512, 1024]:
    image.resize((n, n), Image.Resampling.LANCZOS).save(root / f'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{n}.png')
image.save(root/'assets/brand/portly.png')
image.save(root/'windows/runner/resources/app_icon.ico', sizes=[(16,16), (32,32), (48,48), (64,64), (128,128), (256,256)])
for n in [192, 512]:
    for prefix in ['Icon-', 'Icon-maskable-']:
        image.resize((n,n), Image.Resampling.LANCZOS).save(root/f'web/icons/{prefix}{n}.png')
image.resize((32,32), Image.Resampling.LANCZOS).save(root/'web/favicon.png')
