#!/usr/bin/env python3
"""Draws Sotto's logo and writes every app icon from it.

The mark: a speech bubble with a small, quiet sound wave inside, for
"sotto voce" (speaking quietly, so that only the listener hears), on
Sotto's purple. The wordmark ("sotto", drawn in wordmark.py) ends in the
same bubble.

    python3 tools/icons/generate.py          # from the repository root

Writes (all generated; edit this script, not the files):
  docs/brand/                 sotto-icon.svg, sotto-mark.svg,
                              sotto-wordmark{,-dark}.svg, PNG logos
  app/assets/brand/           logo.png, wordmark-{light,dark}.png (in-app),
                              icon.png (Linux window)
  app/assets/tray/            sotto.png, sotto.ico (system tray)
  app/web/                    favicon.png, icons/*.png (PWA, maskable, Apple)
  app/windows/runner/resources/app_icon.ico
  app/android/app/src/main/res/
                              mipmap-*/ic_launcher.png (Android 7 and older),
                              mipmap-*/ic_launcher_{foreground,monochrome}.png
                              (adaptive and themed icons, Android 8+ / 13+)
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageOps

import wordmark

ROOT = Path(__file__).resolve().parents[2]

# Colours: the app's seed colour (lib/core/theme.dart) sits in the middle
# of the gradient; INK is the web app's background.
TOP = (122, 102, 194)  # #7A66C2
BOTTOM = (61, 47, 107)  # #3D2F6B
WAVE = (91, 75, 138)  # #5B4B8A
INK = (30, 27, 46)  # #1E1B2E
WHITE = (255, 255, 255)
# The wordmark's bubble on dark backgrounds: the purple, lightened.
LIGHT_WAVE = (160, 140, 230)  # #A08CE6

# The mark, in units of the icon's width (0..1), centred at (0.5, 0.5).
BUBBLE_CENTER = (0.5, 0.465)
BUBBLE_RADIUS = 0.285
# The bubble's tail, bottom left: two points on the bubble and the tip.
TAIL = [(-0.62, 0.62), (-0.08, 0.98), (-0.98, 1.08)]  # x, y as multiples of the radius
# The sound wave: rounded bars (x offset from the centre, height), quieter
# at the edges.
BAR_WIDTH = 0.046
BARS = [(-0.12, 0.07), (-0.06, 0.14), (0.0, 0.21), (0.06, 0.14), (0.12, 0.07)]
CORNER = 0.225  # rounded-square corner radius

SUPERSAMPLE = 4


def _gradient(size):
    """Top-left to bottom-right gradient."""
    down = Image.linear_gradient('L').resize((size, size), Image.BILINEAR)
    across = down.transpose(Image.Transpose.ROTATE_90)
    return ImageOps.colorize(Image.blend(down, across, 0.5), TOP, BOTTOM).convert('RGBA')


def _mark(draw, size, scale, bubble, wave):
    """Draws the bubble and the wave, scaled about the centre."""
    def p(x, y):
        return ((0.5 + (x - 0.5) * scale) * size, (0.5 + (y - 0.5) * scale) * size)

    cx, cy = BUBBLE_CENTER
    r = BUBBLE_RADIUS
    (x0, y0), (x1, y1) = p(cx - r, cy - r), p(cx + r, cy + r)
    draw.ellipse((x0, y0, x1, y1), fill=bubble)
    draw.polygon([p(cx + dx * r, cy + dy * r) for dx, dy in TAIL], fill=bubble)
    for dx, height in BARS:
        (bx0, by0), (bx1, by1) = p(cx + dx - BAR_WIDTH / 2, cy - height / 2), p(cx + dx + BAR_WIDTH / 2, cy + height / 2)
        draw.rounded_rectangle((bx0, by0, bx1, by1), radius=(bx1 - bx0) / 2, fill=wave)


def render(size, *, shape='rounded', scale=1.0, monochrome=False, background=True):
    """One icon.

    shape: 'rounded' (transparent corners) or 'square' (full bleed, for
    masks that the platform applies).
    scale: size of the mark; smaller for adaptive and maskable icons, whose
    edges may be cut off.
    monochrome: white bubble with the wave cut out, nothing else (Android
    themed icons).
    background: False for a mark on a transparent background (Android
    adaptive foreground).
    """
    big = size * SUPERSAMPLE
    image = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    if background and not monochrome:
        fill = _gradient(big)
        if shape == 'rounded':
            mask = Image.new('L', (big, big), 0)
            ImageDraw.Draw(mask).rounded_rectangle((0, 0, big - 1, big - 1), radius=CORNER * big, fill=255)
            image.paste(fill, (0, 0), mask)
        else:
            image = fill
    draw = ImageDraw.Draw(image)
    if monochrome:
        _mark(draw, big, scale, WHITE + (255,), (0, 0, 0, 0))
    else:
        _mark(draw, big, scale, WHITE + (255,), WAVE + (255,))
    return image.resize((size, size), Image.LANCZOS)


def wordmark_image(height, *, dark=False):
    """The wordmark alone, for light or dark backgrounds."""
    ink, accent = (WHITE, LIGHT_WAVE) if dark else (INK, WAVE)
    return wordmark.render(height, ink + (255,), accent + (255,))


def lockup(height=256, *, dark=False):
    """The icon with the wordmark beside it: the x-height is 40 % of the
    icon and centred on it."""
    icon = render(height)
    x_height = 0.40 * height
    units = x_height / 100  # pixels per wordmark unit
    word = wordmark_image(round((wordmark.BOTTOM - wordmark.TOP) * units), dark=dark)
    gap = round(0.20 * height)
    image = Image.new('RGBA', (height + gap + word.width, height), (0, 0, 0, 0))
    image.paste(icon, (0, 0), icon)
    top = round(height / 2 - x_height / 2 + wordmark.TOP * units)
    image.paste(word, (height + gap, top), word)
    return image


def svg(*, rounded=True, background=True):
    """The same drawing as SVG (for documents and the web)."""
    r = BUBBLE_RADIUS
    cx, cy = BUBBLE_CENTER
    f = lambda v: f'{v * 1024:.1f}'.rstrip('0').rstrip('.')
    parts = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">']
    if background:
        parts.append(
            '<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">'
            f'<stop offset="0" stop-color="#{bytes(TOP).hex()}"/>'
            f'<stop offset="1" stop-color="#{bytes(BOTTOM).hex()}"/>'
            '</linearGradient></defs>'
        )
        radius = f' rx="{f(CORNER)}"' if rounded else ''
        parts.append(f'<rect width="1024" height="1024"{radius} fill="url(#g)"/>')
    bubble = '#fff' if background else f'#{bytes(BOTTOM).hex()}'
    wave = f'#{bytes(WAVE).hex()}' if background else '#fff'
    tail = ' '.join(f'{f(cx + dx * r)},{f(cy + dy * r)}' for dx, dy in TAIL)
    parts.append(f'<circle cx="{f(cx)}" cy="{f(cy)}" r="{f(r)}" fill="{bubble}"/>')
    parts.append(f'<polygon points="{tail}" fill="{bubble}"/>')
    for dx, height in BARS:
        parts.append(
            f'<rect x="{f(cx + dx - BAR_WIDTH / 2)}" y="{f(cy - height / 2)}" width="{f(BAR_WIDTH)}" '
            f'height="{f(height)}" rx="{f(BAR_WIDTH / 2)}" fill="{wave}"/>'
        )
    parts.append('</svg>')
    return '\n'.join(parts) + '\n'


# Android densities: launcher icon 48 dp, adaptive layers 108 dp.
DENSITIES = {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}
# Adaptive icons show the middle 72 of 108 dp (and masks may cut more):
# the mark keeps the size it has in the 48 dp icon, relative to that middle.
ADAPTIVE_SCALE = 72 / 108
# Maskable web icons must keep their content within the middle 80 %.
MASKABLE_SCALE = 0.84
ICO_SIZES = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]


def save(image, path, **options):
    path = ROOT / path
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, **options)


def main():
    # Brand files.
    brand = ROOT / 'docs/brand'
    brand.mkdir(parents=True, exist_ok=True)
    (brand / 'sotto-icon.svg').write_text(svg())
    (brand / 'sotto-mark.svg').write_text(svg(background=False))
    hex_colour = lambda colour: f'#{bytes(colour).hex()}'
    (brand / 'sotto-wordmark.svg').write_text(wordmark.svg(hex_colour(INK), hex_colour(WAVE)))
    (brand / 'sotto-wordmark-dark.svg').write_text(wordmark.svg('#fff', hex_colour(LIGHT_WAVE)))
    save(render(1024), 'docs/brand/sotto-icon-1024.png')
    save(lockup(), 'docs/brand/sotto-logo-light.png')
    save(lockup(dark=True), 'docs/brand/sotto-logo-dark.png')
    save(wordmark_image(240), 'docs/brand/sotto-wordmark-light.png')
    save(wordmark_image(240, dark=True), 'docs/brand/sotto-wordmark-dark.png')

    # In the app.
    save(render(384), 'app/assets/brand/logo.png')
    save(wordmark_image(144), 'app/assets/brand/wordmark-light.png')
    save(wordmark_image(144, dark=True), 'app/assets/brand/wordmark-dark.png')
    save(render(256), 'app/assets/brand/icon.png')
    save(render(64), 'app/assets/tray/sotto.png')
    save(render(256), 'app/assets/tray/sotto.ico', sizes=ICO_SIZES)

    # Windows.
    save(render(256), 'app/windows/runner/resources/app_icon.ico', sizes=ICO_SIZES)

    # Web.
    save(render(32), 'app/web/favicon.png')
    save(render(192), 'app/web/icons/Icon-192.png')
    save(render(512), 'app/web/icons/Icon-512.png')
    save(render(192, shape='square', scale=MASKABLE_SCALE), 'app/web/icons/Icon-maskable-192.png')
    save(render(512, shape='square', scale=MASKABLE_SCALE), 'app/web/icons/Icon-maskable-512.png')
    # iOS fills transparent corners with black and rounds the icon itself.
    save(render(180, shape='square').convert('RGB'), 'app/web/icons/apple-touch-icon.png')

    # Android.
    res = 'app/android/app/src/main/res'
    for name, density in DENSITIES.items():
        save(render(round(48 * density)), f'{res}/mipmap-{name}/ic_launcher.png')
        layer = round(108 * density)
        save(render(layer, scale=ADAPTIVE_SCALE, background=False), f'{res}/mipmap-{name}/ic_launcher_foreground.png')
        save(render(layer, scale=ADAPTIVE_SCALE, monochrome=True), f'{res}/mipmap-{name}/ic_launcher_monochrome.png')


if __name__ == '__main__':
    main()
