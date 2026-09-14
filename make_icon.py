#!/usr/bin/env python3
"""Clean macOS app icon: centered gauge + baseline spark bars, no overlap."""
from PIL import Image, ImageDraw
import math
from pathlib import Path

SIZE = 1024
RADIUS = 230

img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

# Vertical gradient background
top = (30, 36, 52, 255)
bottom = (10, 14, 26, 255)
d = ImageDraw.Draw(img)
for y in range(SIZE):
    t = y / SIZE
    d.line([(0, y), (SIZE, y)], fill=(int(top[0] + (bottom[0] - top[0]) * t),
                                      int(top[1] + (bottom[1] - top[1]) * t),
                                      int(top[2] + (bottom[2] - top[2]) * t), 255))

mask = Image.new("L", (SIZE, SIZE), 0)
md = ImageDraw.Draw(mask)
md.rounded_rectangle([0, 0, SIZE - 1, SIZE - 1], radius=RADIUS, fill=255)
img.putalpha(mask)

accent = (74, 160, 255, 255)
white = (255, 255, 255, 235)
faint = (255, 255, 255, 90)

d = ImageDraw.Draw(img)

# --- Gauge: higher, slightly smaller so bars fit below with clear gap ---
cx, cy = SIZE // 2, 420
r = 285

start_deg = 150
sweep = 240
for i in range(25):
    ang = math.radians(start_deg - (sweep * i / 24))
    x1 = cx + (r - 48) * math.cos(ang); y1 = cy - (r - 48) * math.sin(ang)
    x2 = cx + r * math.cos(ang);         y2 = cy - r * math.sin(ang)
    w = 15 if i % 4 == 0 else 9
    col = accent if i >= 20 else faint
    d.line([x1, y1, x2, y2], fill=col, width=w)

needle_deg = start_deg - sweep * 0.78
na = math.radians(needle_deg)
nx = cx + (r - 95) * math.cos(na); ny = cy - (r - 95) * math.sin(na)
d.line([cx, cy, nx, ny], fill=white, width=32)
hub = 42
d.ellipse([cx - hub, cy - hub, cx + hub, cy + hub], fill=white)

# --- Spark bars: centered under the gauge, clear of the dial ---
total_w = 4 * 54 + 3 * 26
bx = (SIZE - total_w) // 2
by = 900
for i, h in enumerate([0.45, 0.65, 0.5, 0.9]):
    bw = 54
    bh = int(150 * h)
    col = accent if h >= 0.85 else (255, 255, 255, 150)
    d.rounded_rectangle([bx, by - bh, bx + bw, by], radius=16, fill=col)
    bx += bw + 26

img.save(Path(__file__).resolve().parent / "icon_1024.png")
print("rendered")
