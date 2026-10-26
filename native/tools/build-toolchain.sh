#!/usr/bin/env bash
#
# Builds the cross toolchain for a Paperwhite 3.
#
#   tools/build-toolchain.sh
#
# Produces ~/x-tools/arm-kindlepw2-linux-gnueabi, which is the compiler
# everything else needs. Takes a long while -- crosstool-NG builds binutils,
# gcc, glibc and more from source -- and wants about 15GB of disk.
#
# `kindlepw2` is the right platform despite the name: koxtoolchain's own
# table reads "Kindle PW2 & everything since", and a PW3 is since. It
# targets glibc 2.12 and armv7 (Cortex-A9, softfp), which is what the
# device runs.
#
# crosstool-NG refuses to build as root, which is deliberate on its part
# and not worth arguing with. Run this as an ordinary user.
set -euo pipefail

PLATFORM=kindlepw2
TUPLE=arm-kindlepw2-linux-gnueabi
WORK="${DUO_BUILD_DIR:-$HOME/duo-build}"

if [ "$(id -u)" -eq 0 ]; then
    echo "error: crosstool-NG will not build as root. Run this as a normal user." >&2
    exit 1
fi

# The dependency list is koxtoolchain's own, from its README.
missing=()
for tool in git gperf help2man bison flex gawk unzip wget curl make autoconf \
            automake libtool makeinfo file patch; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "error: missing tools: ${missing[*]}" >&2
    echo >&2
    echo "On Debian or Ubuntu:" >&2
    echo "  sudo apt-get install build-essential autoconf automake bison flex \\" >&2
    echo "      gawk libtool libtool-bin libncurses-dev curl file git gperf \\" >&2
    echo "      help2man texinfo unzip wget" >&2
    exit 1
fi

if [ -x "$HOME/x-tools/$TUPLE/bin/$TUPLE-gcc" ]; then
    echo "The toolchain is already built: $HOME/x-tools/$TUPLE"
    echo "Delete it to rebuild, or carry on to tools/build-base.sh."
    exit 0
fi

mkdir -p "$WORK"
cd "$WORK"
if [ ! -d koxtoolchain ]; then
    git clone https://github.com/koreader/koxtoolchain.git
fi
cd koxtoolchain
git pull --ff-only || true

# CI=1 only turns off the progress bar, which makes a log readable.
echo "Building the $PLATFORM toolchain. This takes a long time."
CI=1 ./gen-tc.sh "$PLATFORM"

echo
echo "Done. The compiler is at:"
echo "  $HOME/x-tools/$TUPLE/bin"
echo
echo "Add it to PATH before running tools/build-base.sh:"
echo "  export PATH=\"\$HOME/x-tools/$TUPLE/bin:\$PATH\""
