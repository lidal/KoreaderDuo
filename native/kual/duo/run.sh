#!/bin/sh
# Starts the native Duo reader.
#
# KUAL runs this with the extension's own directory as the working
# directory, so everything here is relative to it.
#
# The framework is stopped first and restarted afterwards. Not optional:
# Kindle's own reader owns the framebuffer and the touchscreen, and two
# processes drawing on one panel is a screen neither of them can predict.
# `stop lab126_gui` is the supported way and it is what KOReader does.
set -e

DUO_HOME=/mnt/us/duo
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
ROLE="${1:-}"

mkdir -p "$DUO_HOME" "$DUO_HOME/cache"

# Already running: do nothing rather than take the panel twice.
if [ -f "$DUO_HOME/duo.pid" ] && kill -0 "$(cat "$DUO_HOME/duo.pid")" 2>/dev/null; then
    exit 0
fi

# The frontlight is left exactly as it was found. A reader whose light is
# on when the battery runs out is a reader that comes back looking broken:
# a deeply discharged Kindle holds its last frame with the light on and
# looks for all the world like a dead one. This is the cheapest insurance
# there is against the failure that cost two devices during the plugin's
# development.
LIGHT_NODE=/sys/class/backlight/max77696-bl/brightness
LIGHT_WAS=""
[ -r "$LIGHT_NODE" ] && LIGHT_WAS="$(cat "$LIGHT_NODE" 2>/dev/null || true)"

stop lab126_gui >/dev/null 2>&1 || true

cleanup() {
    [ -n "$LIGHT_WAS" ] && [ -w "$LIGHT_NODE" ] && \
        echo "$LIGHT_WAS" > "$LIGHT_NODE" 2>/dev/null || true
    rm -f "$DUO_HOME/duo.pid"
    start lab126_gui >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

echo $$ > "$DUO_HOME/duo.pid"

cd "$APP_DIR"
[ -n "$ROLE" ] && export DUO_ROLE="$ROLE"
LD_LIBRARY_PATH="$APP_DIR/libs:$LD_LIBRARY_PATH" \
    ./luajit app/boot.lua >>"$DUO_HOME/duo.log" 2>&1
