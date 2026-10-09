#!/usr/bin/env bash
# Builds sotto_<version>_amd64.deb from the Flutter Linux bundle.
#   packaging/linux/build-deb.sh <version> <bundle dir> <output dir>
# Installs to /opt/sotto, with /usr/bin/sotto, a menu entry and an icon.
# Package dependencies are worked out from the bundle's binaries.
set -euo pipefail

VERSION=$1
BUNDLE=$(realpath "$2")
OUT=$(realpath "$3")
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
APP_ID=com.izhaanintellect.sotto

WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
PKG=$WORK/pkg

mkdir -p "$PKG/opt/sotto" "$PKG/usr/bin" "$PKG/usr/share/applications" \
  "$PKG/usr/share/icons/hicolor/256x256/apps" "$PKG/DEBIAN"
cp -a "$BUNDLE/." "$PKG/opt/sotto/"
ln -s /opt/sotto/sotto "$PKG/usr/bin/sotto"
install -m 644 "$HERE/$APP_ID.desktop" "$PKG/usr/share/applications/$APP_ID.desktop"
install -m 644 "$ROOT/app/assets/brand/icon.png" "$PKG/usr/share/icons/hicolor/256x256/apps/$APP_ID.png"

# Shared libraries the bundle needs, as package names (dpkg-shlibdeps reads
# debian/control, so give it a minimal one). The bundle's own libraries are
# found next to the executable.
mkdir -p "$WORK/shlibs/debian"
printf 'Source: sotto\n\nPackage: sotto\nArchitecture: amd64\n' >"$WORK/shlibs/debian/control"
mapfile -t ELFS < <(find "$PKG/opt/sotto" -type f \( -name 'sotto' -o -name '*.so' \) -exec sh -c 'file -b "$1" | grep -q ELF' _ {} \; -print)
DEPENDS=$(cd "$WORK/shlibs" && dpkg-shlibdeps -O -l"$PKG/opt/sotto/lib" "${ELFS[@]}" 2>/dev/null |
  sed -n 's/^shlibs:Depends=//p')
# Built on Ubuntu 24.04, some names carry the "t64" suffix of the 64-bit
# time transition; accept the older names too (Debian 12, Ubuntu 22.04).
DEPENDS=$(printf '%s' "$DEPENDS" | sed -E 's/([a-z0-9.+-]+)t64( \([^)]*\))?/\1t64\2 | \1\2/g')
# Run-time helpers that no binary links against, so dpkg-shlibdeps cannot find
# them: parecord (voice messages on Linux), GStreamer's WAV and AAC decoders
# (playing voice messages).
DEPENDS="${DEPENDS:+$DEPENDS, }pulseaudio-utils, gstreamer1.0-plugins-good, gstreamer1.0-libav"

SIZE=$(du -sk "$PKG/opt" | cut -f1)
cat >"$PKG/DEBIAN/control" <<CONTROL
Package: sotto
Version: $VERSION
Architecture: amd64
Maintainer: Izhaan Intellect <hello@sottocall.com>
Installed-Size: $SIZE
Depends: $DEPENDS
Section: net
Priority: optional
Homepage: https://sottocall.com
Description: Private, end-to-end encrypted voice and video calls
 Sotto connects calls between people directly, encrypted end to end.
 Its servers keep nothing: no accounts, no phone numbers, no call history.
CONTROL

mkdir -p "$OUT"
dpkg-deb --root-owner-group --build "$PKG" "$OUT/sotto-linux-amd64.deb" >/dev/null
echo "$OUT/sotto-linux-amd64.deb"
