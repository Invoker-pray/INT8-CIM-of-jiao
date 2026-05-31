#!/usr/bin/env python3
"""Convert PNG images to 8-bit non-interlaced format compatible with xdvipdfmx."""
from pathlib import Path
from PIL import Image

paper_dir = Path(__file__).parent

for png in sorted(paper_dir.rglob("*.png")):
    img = Image.open(png)
    # Remove alpha channel if present (convert RGBA → RGB on white bg)
    if img.mode == "RGBA":
        bg = Image.new("RGB", img.size, (255, 255, 255))
        bg.paste(img, mask=img.split()[3])
        img = bg
    elif img.mode != "RGB":
        img = img.convert("RGB")
    img.save(png, "PNG", interlace=False)
    print(f"  Converted: {png.name} ({img.size[0]}×{img.size[1]})")

print(f"\nDone. All PNGs converted to 8-bit RGB, non-interlaced.")
