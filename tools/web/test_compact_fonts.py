"""Tests for compact_fonts.py. Run from the repository root with:

    python3 -m unittest discover -s tools/web -p 'test_*.py'
"""

import contextlib
import io
import json
import os
import shutil
import tempfile
import unittest

from fontTools.ttLib import TTFont

import compact_fonts

FONT_SOURCE = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'app', 'assets', 'fonts')
FONT_FILES = [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
    'NotoSansBengali-Regular.ttf',
    'NotoSansBengali-Bold.ttf',
]
# The manifest shape flutter build web writes (paths are relative to build/web/assets).
MANIFEST = [
    {'family': 'MaterialIcons', 'fonts': [{'asset': 'fonts/MaterialIcons-Regular.otf'}]},
    {'family': 'Roboto', 'fonts': [
        {'asset': 'assets/fonts/Roboto-Regular.ttf'},
        {'weight': 500, 'asset': 'assets/fonts/Roboto-Medium.ttf'},
        {'weight': 700, 'asset': 'assets/fonts/Roboto-Bold.ttf'},
    ]},
    {'family': 'NotoSansBengali', 'fonts': [
        {'asset': 'assets/fonts/NotoSansBengali-Regular.ttf'},
        {'weight': 700, 'asset': 'assets/fonts/NotoSansBengali-Bold.ttf'},
    ]},
]


def is_woff2(path):
    with open(path, 'rb') as handle:
        return handle.read(4) == b'wOF2'


class CompactFontsTest(unittest.TestCase):
    def setUp(self):
        self.build = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.build)
        fonts = os.path.join(self.build, 'assets', 'assets', 'fonts')
        os.makedirs(fonts)
        for name in FONT_FILES:
            shutil.copy(os.path.join(FONT_SOURCE, name), fonts)
        with open(os.path.join(self.build, 'assets', 'FontManifest.json'), 'w', encoding='utf-8') as handle:
            json.dump(MANIFEST, handle)
        with contextlib.redirect_stdout(io.StringIO()):
            compact_fonts.compact(self.build)
        with open(os.path.join(self.build, 'assets', 'FontManifest.json'), encoding='utf-8') as handle:
            self.manifest = json.load(handle)

    def font(self, name):
        return os.path.join(self.build, 'assets', 'assets', 'fonts', name)

    def test_the_manifest_points_the_text_fonts_at_woff2(self):
        roboto = [e['asset'] for e in self.manifest[1]['fonts']]
        bengali = [e['asset'] for e in self.manifest[2]['fonts']]
        self.assertEqual(roboto, [
            'assets/fonts/Roboto-Regular.woff2',
            'assets/fonts/Roboto-Medium.woff2',
            'assets/fonts/Roboto-Bold.woff2',
        ])
        self.assertEqual(bengali, [
            'assets/fonts/NotoSansBengali-Regular.woff2',
            'assets/fonts/NotoSansBengali-Bold.woff2',
        ])
        # Other families (icons) are left alone.
        self.assertEqual(self.manifest[0], MANIFEST[0])

    def test_the_woff2_files_are_real_woff2_and_smaller(self):
        for name in ['Roboto-Regular', 'Roboto-Bold', 'NotoSansBengali-Regular']:
            woff2 = self.font(name + '.woff2')
            self.assertTrue(is_woff2(woff2), name)
            self.assertLess(os.path.getsize(woff2), os.path.getsize(self.font(name + '.ttf')), name)

    def test_roboto_keeps_latin_greek_and_cyrillic(self):
        cmap = TTFont(self.font('Roboto-Regular.woff2')).getBestCmap()
        for char in ['A', 'é', 'ệ', 'α', 'Ж', '€', '—', '…', '•']:
            self.assertIn(ord(char), cmap, char)

    def test_the_bengali_font_keeps_every_glyph(self):
        original = TTFont(self.font('NotoSansBengali-Regular.ttf')).getGlyphOrder()
        converted = TTFont(self.font('NotoSansBengali-Regular.woff2')).getGlyphOrder()
        self.assertEqual(len(converted), len(original))

    def test_the_ttf_files_stay_in_place(self):
        for name in FONT_FILES:
            self.assertTrue(os.path.exists(self.font(name)), name)


if __name__ == '__main__':
    unittest.main()
