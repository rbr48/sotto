#!/usr/bin/env bash
# Builds Sotto-x86_64.AppImage from the Flutter Linux bundle.
#   packaging/linux/build-appimage.sh <bundle dir> <output dir> <appimagetool> <runtime>
# appimagetool and the AppImage runtime are given as files (downloaded and
# checksum-verified by the caller), so nothing is fetched while building.
set -euo pipefail

BUNDLE=$(realpath "$1")
OUT=$(realpath "$2")
TOOL=$(realpath "$3")
RUNTIME=$(realpath "$4")
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
APP_ID=com.izhaanintellect.sotto

WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
APPDIR=$WORK/Sotto.AppDir

mkdir -p "$APPDIR/usr/share/applications" "$APPDIR/usr/share/icons/hicolor/256x256/apps"
cp -a "$BUNDLE/." "$APPDIR/"
cat >"$APPDIR/AppRun" <<'APPRUN'
#!/bin/sh
HERE=$(dirname "$(readlink -f "$0")")
exec "$HERE/sotto" "$@"
APPRUN
chmod +x "$APPDIR/AppRun"
sed 's/^Exec=.*/Exec=sotto %U/' "$HERE/$APP_ID.desktop" >"$APPDIR/$APP_ID.desktop"
cp "$APPDIR/$APP_ID.desktop" "$APPDIR/usr/share/applications/"
cp "$ROOT/app/assets/brand/icon.png" "$APPDIR/$APP_ID.png"
cp "$ROOT/app/assets/brand/icon.png" "$APPDIR/usr/share/icons/hicolor/256x256/apps/$APP_ID.png"

mkdir -p "$OUT"
# --appimage-extract-and-run: no FUSE needed on build machines.
ARCH=x86_64 "$TOOL" --appimage-extract-and-run --no-appstream \
  --runtime-file "$RUNTIME" "$APPDIR" "$OUT/sotto-linux-x86_64.AppImage" >/dev/null
echo "$OUT/sotto-linux-x86_64.AppImage"
