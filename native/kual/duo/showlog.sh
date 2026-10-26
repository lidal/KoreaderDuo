#!/bin/sh
# Puts the last of the log on the screen, for a reader with no terminal.
DUO_HOME=/mnt/us/duo
eips -c
eips 1 1 "Duo log:"
if [ -f "$DUO_HOME/duo.log" ]; then
    tail -n 12 "$DUO_HOME/duo.log" | awk '{ printf "%d %d %s\n", 1, NR + 2, $0 }' \
        | while read -r x y line; do eips "$x" "$y" "$line"; done
else
    eips 1 3 "(no log yet)"
fi
