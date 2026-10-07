#!/usr/bin/env python3
"""Generates the tray icon (PNG for Linux, ICO for Windows) from the
bundled Roboto Bold font: a white "S" on Sotto's purple circle.

    python3 tools/icons/generate.py app/assets/tray
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

PURPLE = (91, 75, 138, 255)


def icon(size):
    scale = 4  # draw large, then downsample for smooth edges
    big = size * scale
    image = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.ellipse((0, 0, big - 1, big - 1), fill=PURPLE)
    font = ImageFont.truetype(str(Path(__file__).parents[2] / 'app/assets/fonts/Roboto-Bold.ttf'), int(big * 0.7))
    draw.text((big / 2, big / 2), 'S', font=font, fill='white', anchor='mm')
    return image.resize((size, size), Image.LANCZOS)


def main(out):
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    icon(64).save(out / 'sotto.png')
    icon(256).save(out / 'sotto.ico', sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (256, 256)])


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else 'app/assets/tray')
