# Sotto's logo

![Sotto](sotto-logo-light.png)

A phone handset with two sound waves, the outer one fainter: a call, in a quiet voice. *Sotto voce*: speaking quietly, so that only the listener hears.

The wordmark is drawn, not typed: lowercase (a quiet voice), geometric and rounded, in one stroke weight like the icon. The two t's share one crossbar, and the last o, in purple, gives out the icon's two sound waves.

| File | Use |
|---|---|
| `sotto-icon.svg`, `sotto-icon-1024.png` | The app icon (rounded square) |
| `sotto-mark.svg` | The handset and waves alone, on a transparent background |
| `sotto-logo-light.png`, `sotto-logo-dark.png` | Icon and wordmark, for light and dark backgrounds |
| `sotto-wordmark.svg`, `sotto-wordmark-dark.svg`, `sotto-wordmark-{light,dark}.png` | The wordmark alone |

Colours: gradient `#7A66C2` → `#3D2F6B` (top left to bottom right), the mark white on it (the outer wave at 60 %). In the wordmark: letters `#1E1B2E`, the last o and its waves `#5B4B8A` (the app's theme colour); on dark backgrounds, white letters and `#A08CE6`. Keep clear space around the logo of at least the height of the wordmark's o.

Everything here and every app icon (Android launcher and notification icons, Windows, Linux, web, tray) is drawn by [`tools/icons/generate.py`](../../tools/icons/generate.py) (the wordmark's letters by [`wordmark.py`](../../tools/icons/wordmark.py)). To change the logo, edit the script and run it from the repository root:

```bash
python3 tools/icons/generate.py   # needs Pillow
```
