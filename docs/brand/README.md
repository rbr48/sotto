# Sotto's logo

![Sotto](sotto-logo-light.png)

A speech bubble with a small, quiet sound wave: *sotto voce*, speaking quietly so that only the listener hears.

| File | Use |
|---|---|
| `sotto-icon.svg`, `sotto-icon-1024.png` | The app icon (rounded square) |
| `sotto-mark.svg` | The bubble alone, on a transparent background |
| `sotto-logo-light.png`, `sotto-logo-dark.png` | Icon and name, for light and dark backgrounds |

Colours: gradient `#7A66C2` → `#3D2F6B` (top left to bottom right), wave `#5B4B8A` (the app's theme colour), text `#1E1B2E`. The name is set in Roboto Medium.

Everything here and every app icon (Android, Windows, Linux, web, tray) is drawn by [`tools/icons/generate.py`](../../tools/icons/generate.py). To change the logo, edit the script and run it from the repository root:

```bash
python3 tools/icons/generate.py   # needs Pillow
```
