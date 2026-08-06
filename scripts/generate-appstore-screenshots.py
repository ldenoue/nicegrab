#!/usr/bin/env python3
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "appstore-screenshots"
OUT.mkdir(exist_ok=True)

W, H = 2880, 1800
FONT = "/System/Library/Fonts/SFNS.ttf"
ROUNDED = "/System/Library/Fonts/SFNSRounded.ttf"
hero = Image.open(ROOT / "docs/images/nicegrab-example.png").convert("RGB")
menu = Image.open(ROOT / "docs/images/nicegrab-menu.png").convert("RGB")
icon = Image.open(ROOT / "Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png").convert("RGBA")

def font(size, rounded=False):
    return ImageFont.truetype(ROUNDED if rounded else FONT, size)

def gradient(colors):
    a, b = colors[0], colors[-1]
    def mix(t):
        return tuple(int(a[i] * (1-t) + b[i] * t) for i in range(3))
    small = Image.new("RGB", (2, 2))
    small.putdata([a, mix(.62), mix(.38), b])
    return small.resize((W, H), Image.Resampling.BICUBIC)

def fit(image, box):
    copy = image.copy()
    copy.thumbnail(box, Image.Resampling.LANCZOS)
    return copy

def width(image, target):
    height = round(image.height * target / image.width)
    return image.resize((target, height), Image.Resampling.LANCZOS)

def rounded_image(image, radius):
    mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, *image.size), radius=radius, fill=255)
    result = image.convert("RGBA")
    result.putalpha(mask)
    return result

def paste_shadow(canvas, image, xy, radius=36, shadow=38):
    image = rounded_image(image, radius)
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    shadow_mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(shadow_mask).rounded_rectangle((0, 0, *image.size), radius=radius, fill=190)
    shadow_layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    shadow_layer.paste((0, 0, 0, 180), (xy[0], xy[1] + 22), shadow_mask)
    shadow_layer = shadow_layer.filter(ImageFilter.GaussianBlur(shadow))
    canvas.paste(shadow_layer, (0, 0), shadow_layer)
    layer.paste(image, xy, image)
    canvas.paste(layer, (0, 0), layer)

def centered(draw, text, y, fnt, fill):
    box = draw.textbbox((0, 0), text, font=fnt)
    draw.text(((W - (box[2] - box[0])) / 2, y), text, font=fnt, fill=fill)

def brand(canvas, dark=False):
    small = fit(icon, (86, 86))
    canvas.paste(small, (120, 92), small)
    ImageDraw.Draw(canvas).text((222, 108), "NiceGrab", font=font(42, True), fill=(255,255,255) if dark else (45,34,72))

# 1 — primary benefit
canvas = gradient(((245, 239, 255), (255, 223, 216)))
draw = ImageDraw.Draw(canvas)
brand(canvas)
centered(draw, "Make every screenshot worth sharing.", 170, font(102, True), (47, 31, 78))
centered(draw, "Capture a window. Choose a background. Paste anywhere.", 300, font(44), (91, 70, 112))
shot = fit(hero, (2360, 1328))
paste_shadow(canvas, shot, ((W-shot.width)//2, 445), 42, 44)
canvas.convert("RGB").save(OUT / "01-beautiful-window-screenshots.png", quality=100)

# 2 — menu and workflow
blurred = menu.resize((W, H), Image.Resampling.LANCZOS).filter(ImageFilter.GaussianBlur(52))
overlay = Image.new("RGBA", (W, H), (35, 24, 56, 155))
canvas = blurred.convert("RGBA")
canvas.alpha_composite(overlay)
canvas = canvas.convert("RGB")
draw = ImageDraw.Draw(canvas)
brand(canvas, dark=True)
centered(draw, "Everything you need, right in the menu bar.", 165, font(94, True), (255,255,255))
centered(draw, "Backgrounds, formats, templates, and your own shortcut.", 290, font(43), (230,221,240))
shot = width(menu, 1580)
paste_shadow(canvas, shot, ((W-shot.width)//2, 485), 34, 48)
canvas.convert("RGB").save(OUT / "02-menu-bar-workflow.png", quality=100)

# 3 — use cases and templates
canvas = gradient(((232, 241, 255), (245, 224, 255)))
draw = ImageDraw.Draw(canvas)
brand(canvas)
draw.text((150, 210), "One capture.", font=font(100, True), fill=(47,31,78))
draw.text((150, 320), "Ready everywhere.", font=font(100, True), fill=(47,31,78))
draw.text((154, 455), "Create perfectly sized visuals for every place you share.", font=font(42), fill=(91,70,112))
shot = fit(hero, (1650, 930))
paste_shadow(canvas, shot, (118, 690), 38, 42)

labels = [
    ("Work", "Add a discreet confidential label"),
    ("X / Twitter", "Brand posts with your handle"),
    ("LinkedIn", "Share polished professional updates"),
    ("Presentations", "Make slides look instantly better"),
]
x, y = 1900, 650
for title, subtitle in labels:
    draw.rounded_rectangle((x, y, 2735, y+190), radius=38, fill=(255,255,255), outline=(215,202,232), width=3)
    draw.text((x+55, y+35), title, font=font(42, True), fill=(54,38,80))
    draw.text((x+55, y+101), subtitle, font=font(29), fill=(105,87,126))
    y += 225
canvas.convert("RGB").save(OUT / "03-ready-everywhere.png", quality=100)

print(f"Created screenshots in {OUT}")
