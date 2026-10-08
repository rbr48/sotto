#!/usr/bin/env bash
# Downloads appimagetool and the AppImage runtime at pinned versions, and
# checks their SHA-256, into the given directory.
#   packaging/linux/fetch-appimage-tools.sh <dir>
set -euo pipefail

DIR=$1
mkdir -p "$DIR"
fetch() {
  local url=$1 file=$2 sha=$3
  curl -fsSL --retry 3 -o "$DIR/$file" "$url"
  echo "$sha  $DIR/$file" | sha256sum -c -
  chmod +x "$DIR/$file"
}
fetch https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage \
  appimagetool ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
fetch https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-x86_64 \
  runtime-x86_64 2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d
