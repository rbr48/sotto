#!/usr/bin/env python3
"""Draws Sotto's logo and writes every app icon from it.

The mark: a phone handset with two sound waves, the outer one fainter, for
"sotto voce" (speaking quietly, so that only the listener hears), on
Sotto's purple. The wordmark ("sotto", drawn in wordmark.py) ends in the
same two waves.

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
                              (adaptive and themed icons, Android 8+ / 13+),
                              drawable/ic_stat_sotto.xml (notifications)
"""
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageOps

import wordmark

ROOT = Path(__file__).resolve().parents[2]

# Colours: the app's seed colour (lib/core/theme.dart) sits in the middle
# of the gradient; INK is the web app's background.
TOP = (122, 102, 194)  # #7A66C2
BOTTOM = (61, 47, 107)  # #3D2F6B
THEME = (91, 75, 138)  # #5B4B8A, the wordmark's accent
INK = (30, 27, 46)  # #1E1B2E
WHITE = (255, 255, 255)
# The wordmark's accent on dark backgrounds: the purple, lightened.
LIGHT_ACCENT = (160, 140, 230)  # #A08CE6

# The mark, in units of the icon's width (0..1). Every part is a stroke with
# round ends: a phone handset (earpiece top left, mouthpiece bottom right)
# and two sound waves beside it, the outer one fainter (a quiet voice).
# Angles are in degrees, clockwise from 3 o'clock (y points down).
TILT = -45  # the handset is drawn upright, then turned by this much
PIVOT = (0.43, 0.55)  # ...about this point, where its upright drawing is centred
HANDLE_CENTER = (0.11, 0.0)  # relative to PIVOT, upright
HANDLE_RADIUS = 0.24
HANDLE_SPAN = 48  # the handle's arc runs 180 ± this
HANDLE_WIDTH = 0.085
CUP_LENGTH = 0.10  # earpiece and mouthpiece
CUP_WIDTH = 0.135
WAVE_CENTER = (0.47, 0.50)
WAVES = [(0.17, 1.0), (0.27, 0.6)]  # radius, opacity
WAVE_FROM, WAVE_TO = -80, -10
WAVE_WIDTH = 0.06
CORNER = 0.225  # rounded-square corner radius

SUPERSAMPLE = 4


def _turn(point):
    """An upright handset point (relative to PIVOT) in icon units."""
    x, y = point
    a = math.radians(TILT)
    return (PIVOT[0] + x * math.cos(a) - y * math.sin(a), PIVOT[1] + x * math.sin(a) + y * math.cos(a))


def strokes():
    """The mark as strokes: (segment, width, opacity), where a segment is
    ('line', p0, p1) or ('arc', centre, radius, from, to)."""
    cx, cy = HANDLE_CENTER
    a = math.radians(HANDLE_SPAN)
    top = (cx - HANDLE_RADIUS * math.cos(a), cy - HANDLE_RADIUS * math.sin(a))
    bottom = (top[0], 2 * cy - top[1])
    out = [(('arc', _turn(HANDLE_CENTER), HANDLE_RADIUS, 180 - HANDLE_SPAN + TILT, 180 + HANDLE_SPAN + TILT), HANDLE_WIDTH, 1.0)]
    for (x, y), side in ((top, -1), (bottom, 1)):
        tip = (x + CUP_LENGTH * 0.95, y + side * CUP_LENGTH * 0.30)
        out.append((('line', _turn((x, y)), _turn(tip)), CUP_WIDTH, 1.0))
    for radius, opacity in WAVES:
        out.append((('arc', WAVE_CENTER, radius, WAVE_FROM, WAVE_TO), WAVE_WIDTH, opacity))
    return out


def _points(segment, step):
    if segment[0] == 'line':
        (x0, y0), (x1, y1) = segment[1:]
        n = max(1, math.ceil(math.dist((x0, y0), (x1, y1)) / step))
        return [(x0 + (x1 - x0) * i / n, y0 + (y1 - y0) * i / n) for i in range(n + 1)]
    (cx, cy), r, a0, a1 = segment[1:]
    n = max(1, math.ceil(abs(a1 - a0) * math.pi / 180 * r / step))
    return [
        (cx + r * math.cos(math.radians(a0 + (a1 - a0) * i / n)), cy + r * math.sin(math.radians(a0 + (a1 - a0) * i / n)))
        for i in range(n + 1)
    ]


def _gradient(size):
    """Top-left to bottom-right gradient."""
    down = Image.linear_gradient('L').resize((size, size), Image.BILINEAR)
    across = down.transpose(Image.Transpose.ROTATE_90)
    return ImageOps.colorize(Image.blend(down, across, 0.5), TOP, BOTTOM).convert('RGBA')


def _mark(size, scale, colour):
    """The mark alone on a transparent image, scaled about the centre."""
    image = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    for segment, width, opacity in strokes():
        # Each stroke on its own layer, so that a faint one stays even where
        # its round dots overlap.
        layer = Image.new('L', (size, size), 0)
        draw = ImageDraw.Draw(layer)
        radius = width / 2 * scale * size
        for x, y in _points(segment, 0.5 / size):
            px, py = (0.5 + (x - 0.5) * scale) * size, (0.5 + (y - 0.5) * scale) * size
            draw.ellipse((px - radius, py - radius, px + radius, py + radius), fill=255)
        solid = Image.new('RGBA', (size, size), colour + (round(255 * opacity),))
        image.paste(solid, (0, 0), layer)
    return image


def render(size, *, shape='rounded', scale=1.0, monochrome=False, background=True):
    """One icon.

    shape: 'rounded' (transparent corners) or 'square' (full bleed, for
    masks that the platform applies).
    scale: size of the mark; smaller for adaptive and maskable icons, whose
    edges may be cut off.
    monochrome: the white mark alone (Android themed icons).
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
    image = Image.alpha_composite(image, _mark(big, scale, WHITE))
    return image.resize((size, size), Image.LANCZOS)


def wordmark_image(height, *, dark=False):
    """The wordmark alone, for light or dark backgrounds."""
    ink, accent = (WHITE, LIGHT_ACCENT) if dark else (INK, THEME)
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


def _path(segment, at):
    """SVG / Android path data for one segment; `at` maps icon units."""
    def f(v):
        return f'{v:.2f}'.rstrip('0').rstrip('.')

    if segment[0] == 'line':
        (x0, y0), (x1, y1) = at(segment[1]), at(segment[2])
        return f'M{f(x0)},{f(y0)}L{f(x1)},{f(y1)}'
    (cx, cy), r, a0, a1 = segment[1:]
    x0, y0 = at((cx + r * math.cos(math.radians(a0)), cy + r * math.sin(math.radians(a0))))
    x1, y1 = at((cx + r * math.cos(math.radians(a1)), cy + r * math.sin(math.radians(a1))))
    radius = abs(at((r, 0))[0] - at((0, 0))[0])
    return f'M{f(x0)},{f(y0)}A{f(radius)},{f(radius)} 0 {int(abs(a1 - a0) > 180)} {int(a1 > a0)} {f(x1)},{f(y1)}'


def svg(*, rounded=True, background=True):
    """The same drawing as SVG (for documents and the web)."""
    at = lambda p: (p[0] * 1024, p[1] * 1024)
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
    colour = '#fff' if background else f'#{bytes(BOTTOM).hex()}'
    for segment, width, opacity in strokes():
        fade = f' stroke-opacity="{opacity}"' if opacity < 1 else ''
        parts.append(
            f'<path d="{_path(segment, at)}" fill="none" stroke="{colour}" stroke-width="{f(width)}" '
            f'stroke-linecap="round"{fade}/>'
        )
    parts.append('</svg>')
    return '\n'.join(parts) + '\n'


def status_bar_icon():
    """Android's notification icon: the mark alone, white (Android tints
    it), filling a 24 dp square."""
    xs, ys = [], []
    for segment, width, _ in strokes():
        for x, y in _points(segment, 0.01):
            xs += [x - width / 2, x + width / 2]
            ys += [y - width / 2, y + width / 2]
    side = max(max(xs) - min(xs), max(ys) - min(ys))
    scale = 22 / side
    ox = 12 - (min(xs) + max(xs)) / 2 * scale
    oy = 12 - (min(ys) + max(ys)) / 2 * scale
    at = lambda p: (ox + p[0] * scale, oy + p[1] * scale)
    lines = [
        '<?xml version="1.0" encoding="utf-8"?>',
        '<!-- Status bar icon: Sotto\'s handset and sound waves (white; Android',
        '     tints it). Generated by tools/icons/generate.py. -->',
        '<vector xmlns:android="http://schemas.android.com/apk/res/android"',
        '    android:width="24dp"',
        '    android:height="24dp"',
        '    android:viewportWidth="24"',
        '    android:viewportHeight="24">',
    ]
    for segment, width, opacity in strokes():
        lines += [
            '    <path',
            '        android:strokeColor="#FFFFFFFF"',
            f'        android:strokeWidth="{width * scale:.2f}"',
            '        android:strokeLineCap="round"',
        ]
        if opacity < 1:
            lines.append(f'        android:strokeAlpha="{opacity}"')
        lines.append(f'        android:pathData="{_path(segment, at)}" />')
    lines.append('</vector>')
    return '\n'.join(lines) + '\n'


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
    (brand / 'sotto-wordmark.svg').write_text(wordmark.svg(hex_colour(INK), hex_colour(THEME)))
    (brand / 'sotto-wordmark-dark.svg').write_text(wordmark.svg('#fff', hex_colour(LIGHT_ACCENT)))
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
    (ROOT / res / 'drawable/ic_stat_sotto.xml').write_text(status_bar_icon())
    for name, density in DENSITIES.items():
        save(render(round(48 * density)), f'{res}/mipmap-{name}/ic_launcher.png')
        layer = round(108 * density)
        save(render(layer, scale=ADAPTIVE_SCALE, background=False), f'{res}/mipmap-{name}/ic_launcher_foreground.png')
        save(render(layer, scale=ADAPTIVE_SCALE, monochrome=True), f'{res}/mipmap-{name}/ic_launcher_monochrome.png')


if __name__ == '__main__':
    main()
