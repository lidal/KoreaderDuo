#!/bin/sh
# Asks the reader to stop, and lets its own trap put the framework back.
DUO_HOME=/mnt/us/duo
[ -f "$DUO_HOME/duo.pid" ] || exit 0
PID="$(cat "$DUO_HOME/duo.pid")"
# TERM, not KILL: the app's exit handler is what gives the framebuffer
# back and restores the light, and KILL skips it.
kill -TERM "$PID" 2>/dev/null || true
exit 0
