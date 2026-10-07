# Sotto's logo

![Sotto](sotto-logo-light.png)

A speech bubble with a small, quiet sound wave: *sotto voce*, speaking quietly so that only the listener hears.

The wordmark is drawn, not typed: lowercase (a quiet voice), geometric and rounded, in one stroke weight like the icon. The two t's share one crossbar, and the last o is the icon's speech bubble, in purple.

| File | Use |
|---|---|
| `sotto-icon.svg`, `sotto-icon-1024.png` | The app icon (rounded square) |
| `sotto-mark.svg` | The bubble alone, on a transparent background |
| `sotto-logo-light.png`, `sotto-logo-dark.png` | Icon and wordmark, for light and dark backgrounds |
| `sotto-wordmark.svg`, `sotto-wordmark-dark.svg`, `sotto-wordmark-{light,dark}.png` | The wordmark alone |

Colours: gradient `#7A66C2` → `#3D2F6B` (top left to bottom right), wave and bubble `#5B4B8A` (the app's theme colour), letters `#1E1B2E`. On dark backgrounds: white letters and a `#A08CE6` bubble. Keep clear space around the logo of at least the height of the wordmark's o.

Everything here and every app icon (Android, Windows, Linux, web, tray) is drawn by [`tools/icons/generate.py`](../../tools/icons/generate.py) (the wordmark's letters by [`wordmark.py`](../../tools/icons/wordmark.py)). To change the logo, edit the script and run it from the repository root:

```bash
python3 tools/icons/generate.py   # needs Pillow
```
