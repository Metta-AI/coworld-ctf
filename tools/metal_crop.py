#!/usr/bin/env python3
"""Crop + nearest-upscale helper for the metallic-material eyeball loop.

  metal_crop.py <src.png> <out.png> <cx> <cy> <w> <h> [zoom]

Crops a w x h box centred on (cx, cy) in SOURCE pixels and nearest-upscales it
by `zoom` so a human can see what a 30-screen-pixel cog actually looks like
without any resampling flattering the effect.
"""
import sys
from PIL import Image

src, out = sys.argv[1], sys.argv[2]
cx, cy, w, h = (int(v) for v in sys.argv[3:7])
zoom = int(sys.argv[7]) if len(sys.argv) > 7 else 8

img = Image.open(src).convert("RGB")
box = (cx - w // 2, cy - h // 2, cx - w // 2 + w, cy - h // 2 + h)
crop = img.crop(box)
crop.resize((w * zoom, h * zoom), Image.NEAREST).save(out)
print(f"{out} {w}x{h} @{zoom}x from {src} box={box}")
