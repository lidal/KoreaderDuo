#!/usr/bin/env bash
#
# Assembles the KUAL extension from a koreader-base build.
#
#   tools/package.sh /path/to/koreader-base/build/arm-kindlepw2-linux-gnueabi
#
# Produces dist/duo-kual.zip, laid out as the app expects to find itself
# (see the package.path note in app/boot.lua):
#
#   duo/
#     app/      this frontend
#     ffi/      koreader-base's Lua modules
#     libs/     koreader-base's .so modules
#     luajit    the interpreter
#     *.sh, menu.json
#
# Checks that each piece is really there rather than zipping a hole: an
# archive that is missing the interpreter installs perfectly and then does
# nothing at all, on a device with no terminal to ask why.
set -euo pipefail

BASE_BUILD="${1:-}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/dist"
STAGE="$OUT/duo"

if [ -z "$BASE_BUILD" ] || [ ! -d "$BASE_BUILD" ]; then
    echo "usage: tools/package.sh <koreader-base build dir>" >&2
    exit 1
fi

BASE_SRC="$(cd "$BASE_BUILD/../.." && pwd)"

rm -rf "$STAGE"
mkdir -p "$STAGE/libs"

cp -r "$HERE/app" "$STAGE/"
cp "$HERE/kual/duo/"* "$STAGE/"
chmod +x "$STAGE"/*.sh

# The plugin's own engine, which this app requires unchanged.
mkdir -p "$STAGE/duo"
cp -r "$HERE/../duo.koplugin/duo/." "$STAGE/duo/"

# koreader-base's Lua side.
if [ -d "$BASE_SRC/ffi" ]; then
    cp -r "$BASE_SRC/ffi" "$STAGE/"
else
    echo "warning: no ffi/ directory found at $BASE_SRC/ffi" >&2
fi

# ... and its compiled side.
missing=()
for f in libkoreader-cre.so libkoreader-input.so libkoreader-lfs.so; do
    if [ -e "$BASE_BUILD/libs/$f" ]; then
        cp "$BASE_BUILD/libs/$f" "$STAGE/libs/"
    elif [ -e "$BASE_BUILD/$f" ]; then
        cp "$BASE_BUILD/$f" "$STAGE/libs/"
    else
        missing+=("$f")
    fi
done
if [ -e "$BASE_BUILD/luajit" ]; then
    cp "$BASE_BUILD/luajit" "$STAGE/"
    chmod +x "$STAGE/luajit"
else
    missing+=("luajit")
fi

# Any other shared libraries the build produced; harmless to carry, and
# cheaper than discovering a missing one on the device.
find "$BASE_BUILD" -maxdepth 2 -name '*.so*' -exec cp -n {} "$STAGE/libs/" \; 2>/dev/null || true

if [ ${#missing[@]} -gt 0 ]; then
    echo "error: these are missing from $BASE_BUILD:" >&2
    for f in "${missing[@]}"; do echo "  $f" >&2; done
    echo >&2
    echo "Not packaging an archive that cannot run. Check the build output." >&2
    exit 1
fi

cd "$OUT"
rm -f duo-kual.zip
zip -qr duo-kual.zip duo
echo "dist/duo-kual.zip"
du -h duo-kual.zip | cut -f1 | sed 's/^/  size: /'
echo
echo "Install with:"
echo "  unzip duo-kual.zip -d /mnt/us/extensions/"
