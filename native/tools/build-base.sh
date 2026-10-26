#!/usr/bin/env bash
#
# Builds koreader-base for a Paperwhite 3.
#
#   tools/build-base.sh
#
# Needs the toolchain from tools/build-toolchain.sh on PATH. Produces the
# engines and the interpreter this app loads:
#
#   libkoreader-cre.so     CREngine: EPUB, CSS, embedded fonts, the lot
#   libkoreader-input.so   the raw input reader
#   libkoreader-lfs.so     filesystem bits ffi/framebuffer wants
#   luajit                 the interpreter
#   ffi/*.lua              blitbuffer, framebuffer_mxcfb, freetype
#
# TARGET=kindlepw2 sets CHOST=arm-kindlepw2-linux-gnueabi and glibc 2.12,
# which is read straight off koreader-base's Makefile.defs. Output lands in
# build/<tuple>/ under the checkout.
set -euo pipefail

TUPLE=arm-kindlepw2-linux-gnueabi
TARGET=kindlepw2
WORK="${DUO_BUILD_DIR:-$HOME/duo-build}"

if ! command -v "$TUPLE-gcc" >/dev/null 2>&1; then
    echo "error: $TUPLE-gcc is not on PATH." >&2
    echo "Run tools/build-toolchain.sh first, then:" >&2
    echo "  export PATH=\"\$HOME/x-tools/$TUPLE/bin:\$PATH\"" >&2
    exit 1
fi

mkdir -p "$WORK"
cd "$WORK"
if [ ! -d koreader-base ]; then
    git clone https://github.com/koreader/koreader-base.git
fi
cd koreader-base
git submodule update --init --recursive

# fetchthirdparty pulls crengine, mupdf, freetype, harfbuzz and the rest.
make fetchthirdparty
make TARGET="$TARGET" -j"$(nproc)"

OUT="$PWD/build/$TUPLE"
echo
if [ -d "$OUT" ]; then
    echo "Built. Artefacts in:"
    echo "  $OUT"
    echo
    echo "What the app needs from there:"
    for f in libs/libkoreader-cre.so libs/libkoreader-input.so luajit; do
        if [ -e "$OUT/$f" ]; then echo "  found    $f"; else echo "  MISSING  $f"; fi
    done
    echo
    echo "Next: tools/package.sh \"$OUT\""
else
    echo "error: expected output directory $OUT does not exist." >&2
    echo "Look for the real one under $PWD/build and pass it to package.sh." >&2
    exit 1
fi
