#!/usr/bin/env python3
"""Makes the web build's text fonts smaller, for a faster first visit.

Run it on the output of `flutter build web`:

    python3 tools/web/compact_fonts.py app/build/web

For each text font in the build's FontManifest.json it writes a WOFF2 copy
next to the original and points the manifest at the copy. The TTF files stay
where they are. Native apps keep the TTF files from pubspec.yaml: their font
loaders can't read WOFF2.

Roboto keeps Basic and Latin (with Vietnamese), Greek, Cyrillic and the
punctuation and symbol blocks, so Greek and Cyrillic text still shows on the
web, which has no fallback font for them. Bengali is converted whole.
"""

import json
import os
import sys

from fontTools import subset
from fontTools.ttLib import TTFont

# Unicode blocks kept in the trimmed Roboto (inclusive code point ranges).
ROBOTO_RANGES = [
    (0x0000, 0x024F),  # Basic Latin, Latin-1, Latin Extended-A and -B
    (0x02B0, 0x02FF),  # spacing modifier letters
    (0x0300, 0x036F),  # combining diacritical marks
    (0x0370, 0x03FF),  # Greek
    (0x0400, 0x052F),  # Cyrillic and its supplement
    (0x1E00, 0x1FFF),  # Latin Extended Additional (Vietnamese), Greek Extended
    (0x2000, 0x206F),  # general punctuation
    (0x20A0, 0x20CF),  # currency symbols
    (0x2100, 0x214F),  # letterlike symbols
    (0x2190, 0x21FF),  # arrows
    (0x2200, 0x22FF),  # mathematical operators
    (0x2500, 0x25FF),  # box drawing and geometric shapes
    (0x2600, 0x26FF),  # miscellaneous symbols
    (0x2DE0, 0x2DFF),  # Cyrillic Extended-A
    (0xA640, 0xA69F),  # Cyrillic Extended-B
]

# Font family -> code point ranges to keep, or None to keep every glyph.
TEXT_FAMILIES = {
    'Roboto': ROBOTO_RANGES,
    'NotoSansBengali': None,
}

# Characters each converted family must still have after the conversion.
MUST_HAVE = {
    'Roboto': [0x41, 0xE9, 0x416, 0x3B1],  # A, é, Ж, α
    'NotoSansBengali': [0x995],  # ক
}


def convert(source, target, ranges):
    font = TTFont(source)
    if ranges is not None:
        options = subset.Options()
        # Keep the .notdef outline, so a character a font lacks still shows
        # as the usual box rather than as nothing.
        options.notdef_outline = True
        subsetter = subset.Subsetter(options=options)
        subsetter.populate(unicodes=[cp for lo, hi in ranges for cp in range(lo, hi + 1)])
        subsetter.subset(font)
    font.flavor = 'woff2'
    font.save(target)


def check(family, path):
    cmap = TTFont(path).getBestCmap()
    missing = [hex(cp) for cp in MUST_HAVE[family] if cp not in cmap]
    if missing:
        raise SystemExit(f'{path}: missing {", ".join(missing)} after conversion')


def compact(build_dir):
    assets = os.path.join(build_dir, 'assets')
    manifest_path = os.path.join(assets, 'FontManifest.json')
    with open(manifest_path, encoding='utf-8') as handle:
        manifest = json.load(handle)
    for family in manifest:
        name = family['family']
        if name not in TEXT_FAMILIES:
            continue
        for entry in family['fonts']:
            asset = entry['asset']  # for example assets/fonts/Roboto-Regular.ttf
            source = os.path.join(assets, asset)
            target_asset = os.path.splitext(asset)[0] + '.woff2'
            target = os.path.join(assets, target_asset)
            convert(source, target, TEXT_FAMILIES[name])
            check(name, target)
            entry['asset'] = target_asset
            print(f'{asset}: {os.path.getsize(source)} -> {os.path.getsize(target)} bytes')
    with open(manifest_path, 'w', encoding='utf-8') as handle:
        json.dump(manifest, handle, separators=(',', ':'))


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    compact(sys.argv[1])
