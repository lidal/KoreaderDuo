# A native Duo reader

A two-page reader for a pair of jailbroken Paperwhite 3s, launched from
KUAL, joined by a wire. Not a KOReader plugin: a separate app that uses
Duo's own engine.

The case for it, the costs, and what was decided is in
[FEASIBILITY.md](FEASIBILITY.md). This file is what exists and how to run
it.

**Nothing here changes `duo.koplugin`.** The plugin is required, unmodified,
from one directory up.

## What works

Verified by the suite, on this machine, with no Kindle involved:

- **Two instances, two processes, one wire, one book across both screens.**
  `spec/spread_spec.lua` starts two copies of the app as separate operating
  system processes, joins them with a pseudo-terminal, and drives them with
  the *unmodified* `duo/core.lua` out of the plugin. The pair comes up with
  no pairing code, shows consecutive pages, moves both devices from a tap on
  either one, carries a font-size change across, and ends up with both
  engines reporting identical pagination.
- **A library view**: a grid of covers, pageable, foldable into
  subdirectories, reporting exactly the state shape Duo's existing
  library-spread code reads off KOReader's file browser.
- **A reader**: page turns by tap, key and swipe, chrome top and bottom,
  position remembered per book.
- **Typography**: typeface, size, weight, line and word spacing, all four
  margins, justification, hyphenation, and the book's own styles and fonts —
  each repaginating the book and keeping the reader's place.
- **Determinism**: two engines given the same book and the same layout agree
  on every page break, and say *what* differs when they do not.

## What has not been verified

Taking the plugin's README at its word that a skip which says nothing is a
pass that means nothing:

- **Nothing has run on a Kindle.** Not once. Two files are the whole of the
  gap, and both refuse cleanly off-device rather than pretending:
  - `app/device/kobase.lua` — koreader-base's framebuffer, input and
    blitbuffer
  - `app/engine/cre.lua` — CREngine
  Each lists what it needs in a `NEEDS` table and probes for it at `open()`,
  so the first run on a device names the symbol that has moved instead of
  dying in C. Every name in them came from reading how KOReader drives the
  same engine, and **every one of them should be assumed wrong until a
  device says otherwise.**
- **Whether CREngine can be driven from a frontend that is not KOReader's.**
  This is Stage 2 of the study and the biggest unknown in the project.
  koreader-base publishes itself as a framework for building document
  readers, but nobody appears to have built one on it this way. If it needs
  large parts of KOReader's Lua after all, the approach changes.
- **Anything electrical about the wire.** A pseudo-terminal proves the
  framing, the handshake and the state machine. It proves nothing about baud
  rates, framing errors, a full FIFO, or whether flow control does what it
  says on this driver. Unchanged from the plugin, and not improved by
  anything here.
- **The KUAL scripts.** Syntax-checked and no more. `run.sh` stops
  `lab126_gui`, which is the supported way to take the framebuffer and is
  also the step that makes a mistake here expensive.
- **`engine/stub.lua` is not a renderer** and must never be mistaken for
  one. It wraps words at a measured width so that the app can be built and
  tested without a Kindle. It has no CSS, no shaping and no hyphenation.

## Running it

```sh
make test     # the whole suite
make check    # syntax, Lua and shell
make run      # the app, headless, against ./books
```

`make test` needs `luajit` and `socat`; without socat the spread suite
refuses loudly and counts as a failure rather than quietly passing.

```sh
sudo apt-get install -y luajit lua-socket socat
```

## How it is put together

```
native/
  app/
    boot.lua          the entry point KUAL runs; the only thing that exits
    main.lua          the application: owns device, views and the engine
    platform.lua      the one file that knows which machine this is
    duohost.lua       Duo's engine, hosted here instead of by KOReader
    books.lua         the folder scan
    store.lua         settings that survive a restart
    light.lua         the frontlight, in duo/frontlight's shape
    device/
      api.lua         the device contract — read this one first
      fake.lua        headless, records drawing instead of rasterising
      kobase.lua      the real panel, via koreader-base      [UNVERIFIED]
    engine/
      api.lua         the document engine contract
      stub.lua        a deterministic paginator, for the suite
      cre.lua         CREngine, via koreader-base             [UNVERIFIED]
    ui/widget.lua     rectangles, a view stack, where a tap landed
    views/
      library.lua     the shelf, as one grid across two screens
      reader.lua      the book
      typography.lua  font, margins, spacing, embedded styles
  kual/duo/           the KUAL extension: menu.json and its scripts
  spec/               the suite, incl. the two-process spread test
```

### The one idea worth knowing

`duo/core.lua` reaches its host through three doors and no others: a hooks
table, a reader binding of eight methods, and a browser binding of six.
KOReader is merely the host that answers them today. `app/duohost.lua`
answers them from here, and the entire engine — handshake, signing, roles,
spread arithmetic, typography matching, the step-back-don't-hang-up
behaviour on a silent line — then drives this app with **no changes to the
plugin at all**.

That is why this is a tractable project rather than a rewrite. Roughly
11,500 lines of the plugin carry over untouched; `main.lua`'s 4,710 lines
of KOReader glue are the only part replaced.

### Drawing is a display list

Views never touch a pixel. They emit operations — fill, rect, text, image —
which the fake device records for the suite to assert on and the real device
replays into a blitbuffer. That is what makes a library grid testable
without a framebuffer, and it is why `spec/app_spec.lua` can check that a
page turn refreshes *once*.

The book's own text is the exception: CREngine draws it into the buffer
itself. `engine/cre.lua`'s `render` is the one place in the app that reaches
past the display list, and it is unavoidable.

### Page turns go through one method

`Reader:turn` and `Library:turnPage` are the only ways either ever moves,
and both offer the move to Duo first. With two devices a turn is not a local
event — the leader advances by the width of the spread, and a follower's tap
is a request that may be refused.

Every page change is then reported back to the engine, including ones the
engine itself caused. That looks redundant and is not: leaving it out was a
real bug, and the suite caught it. Turns worked, because a turn passes
through the engine on the way in; a *jump* — the progress bar, a position
restored after a relayout — moved one device and nothing else. The plugin's
own rule is that jumps are noticed rather than intercepted, so something has
to do the noticing.

## Getting it onto a device

Not possible yet. Stage 1 of the study, in order:

1. `koxtoolchain`: `./gen-tc.sh kindlepw2` → `arm-kindlepw2-linux-gnueabi`.
   A prebuilt container image exists if a local build fights back.
2. Build `koreader-base` for `kindlepw2`.
3. `make dist` gives `dist/duo-kual.zip`, which is the Lua and the KUAL
   scripts. The cross-built `luajit` and koreader-base's shared libraries
   have to be added beside them — the archive is deliberately not pretending
   to be complete.
4. Unzip into `/mnt/us/extensions/`, and **have the UART wired and a
   bootloader you can interrupt first.** `run.sh` stops the device's own
   framework; a reader that will not start cannot be fixed from its own
   menus.

Charge both readers on a wall charger before any session that touches the
UART or the framework. Two Paperwhites stopped booting during the plugin's
development and the evidence pointed at a brownout; `run.sh` puts the
frontlight back exactly as it found it for the same reason.

## Licence

Intended to be used with, and distributed under the same terms as, KOReader
itself: **AGPL-3.0**. It requires `duo.koplugin`, which is AGPL, and would
link koreader-base, which is too.
