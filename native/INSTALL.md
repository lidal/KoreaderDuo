# Getting it onto a pair of Paperwhite 3s

Step by step. Read §0 first — one step in here can leave a reader unable to
start, and the way back in is a wire you have to have fitted *before* you
need it.

**Expect the first run to fail.** That is the design, not pessimism.
`device/kobase.lua` and `engine/cre.lua` have never run on hardware, and
both probe for what they need and name what is missing instead of dying in
C. The first run's job is to produce one clear line in a log. §7 says what
to send me.

---

## 0. Before you start

**Charge both readers on a wall charger.** Not a laptop port — several
hours on a proper charger. A deeply discharged Kindle looks exactly like a
broken one: the light comes on, the screen holds whatever it last drew
(e-ink does that with no power at all), and nothing finishes booting. Two
Paperwhites did this during the plugin's development and the evidence
pointed at a brownout. This is the cheapest insurance in the whole
document.

**Have the UART wired on at least one reader, and prove you can interrupt
the bootloader over it, before step 5.** `run.sh` stops the device's own
framework (`lab126_gui`). If something goes wrong after that, the reader
has no menus to fix it from, and the UART is the only way in. 115200 8N1.

**Check the logic level before connecting a USB serial adapter.** Two
identical readers can be wired to each other *because* they are identical.
A generic adapter usually is not.

**What this does not touch.** Nothing here edits the device's startup. The
app is an extension and a shell script; `run.sh` stops and restarts a
service, which is what every KUAL app does. The one part of Duo that
rewrites startup jobs is the plugin's **Debug → Turn off the login
prompt**, and you only need that if you want the wire — see §6.

---

## 1. Build the toolchain *(on your Linux machine, once)*

```sh
cd native
./tools/build-toolchain.sh
```

Long — crosstool-NG builds binutils, gcc and glibc from source. Wants about
15GB of disk. Must **not** be run as root; crosstool-NG refuses, and it is
right to.

If it stops on a missing tool, it prints the exact `apt-get` line.

Result: `~/x-tools/arm-kindlepw2-linux-gnueabi`. Then:

```sh
export PATH="$HOME/x-tools/arm-kindlepw2-linux-gnueabi/bin:$PATH"
```

> `kindlepw2` is right despite the name. koxtoolchain's own table reads
> "Kindle PW2 & everything since", and a PW3 is since. It targets glibc
> 2.12, armv7 Cortex-A9, softfp — which is what the device runs.

## 2. Build koreader-base

```sh
./tools/build-base.sh
```

Also long. This is CREngine, MuPDF, FreeType, HarfBuzz and LuaJIT. It ends
by listing whether each piece the app needs actually got built:

```
  found    libs/libkoreader-cre.so
  found    libs/libkoreader-input.so
  found    luajit
```

If any says `MISSING`, stop and send me the tail of the build log — there is
no point packaging an archive that cannot run.

## 3. Add the fonts

**The app ships no font files and will not render text without them.**
`app/views/typography.lua` offers five faces by name; CREngine needs the
actual files.

```sh
mkdir -p dist/duo/fonts
# Any TTF/OTF will do to start. Noto Serif and Noto Sans are a safe pair.
cp /usr/share/fonts/truetype/noto/NotoSerif-*.ttf dist/duo/fonts/
cp /usr/share/fonts/truetype/noto/NotoSans-*.ttf  dist/duo/fonts/
```

Whatever you put there, make `Typography.FACES` in
`app/views/typography.lua` list exactly those faces and no others. A face
offered but not present is a book that will not lay out, and — the point of
bundling them — **both readers must have the same files**, or the two
paginate differently and the spread quietly stops lining up.

## 4. Package it

```sh
./tools/package.sh ~/duo-build/koreader-base/build/arm-kindlepw2-linux-gnueabi
```

Gives `dist/duo-kual.zip`. It refuses to build an archive with a missing
interpreter or engine, because such an archive installs perfectly and then
does nothing, on a device with no terminal to ask why.

The archive contains the app, koreader-base's `ffi/` and `libs/`, the
`luajit` binary, **and the plugin's own `duo/` modules** — which is the
whole engine, carried across unchanged.

## 5. Install on the device

USB-connect the Kindle, then:

```sh
unzip dist/duo-kual.zip -d /mnt/us/extensions/
```

Check it landed as `/mnt/us/extensions/duo/` with `app/`, `ffi/`, `libs/`,
`luajit`, `menu.json` and the scripts all directly inside. Then eject
properly and do the same on the second reader.

> Jailbreak and KUAL have to be there already. If `/mnt/us/extensions/`
> does not exist, KUAL is not installed and nothing here will run.

## 6. First run

On **one** device, charged and on the charger:

KUAL → **Duo** → **Start Duo**

Three things can happen.

**It draws a shelf.** Better than expected. Go to §6.1.

**The screen goes blank and comes back to the Kindle home screen.** The app
refused to start and put the framework back, which is the designed failure.
KUAL → Duo → **Show the last boot log**, or over USB read
`/mnt/us/duo/boot.log` and `/mnt/us/duo/duo.log`. The line you want looks
like one of:

```
Duo cannot start: koreader-base is missing: ffi/blitbuffer, ...
Duo cannot start: libs/libkoreader-cre did not load (is koreader-base built?)
Duo cannot start: ffi/framebuffer_mxcfb would not open: ...
Duo cannot start: a CREngine document has no setFontFace; the bindings have moved
```

Each of those is a specific, small fix. Send me the line.

**The screen freezes and the home screen does not come back.** Hold power
for 40 seconds and release. There are no button combinations on a
Paperwhite; duration is the only control. If it comes back, send me
`/mnt/us/duo/duo.log`. If it does not, §8.

### 6.1 If it starts

Check, in order, and photograph anything that looks wrong:

1. **The shelf** lists the books in `/mnt/us/documents`.
2. **A tap in the middle-right quarter** of a book's cell opens it.
3. **The text renders.** If you get a blank page with chrome around it, the
   font files are the first suspect (§3).
4. **A tap in the right quarter** turns the page; the left quarter turns
   back.
5. **A tap in the header** opens the typography panel. Change the font size
   and tap `done` — the book should repaginate and keep your place.
6. **Stop Duo** from KUAL. The Kindle home screen must come back and the
   frontlight must be where you left it.

Step 6 is the one I would check hardest. A reader that cannot give the panel
back is the one failure here that is actually annoying.

## 7. The wire, and the pair

Only once a single device works on its own.

The app is **serial-only** — there is no Wi-Fi path in it at all. So the
wire has to carry everything, and the console has to be off it first. That
part is the plugin's, not this app's:

1. Install `duo.koplugin` in KOReader on both readers (it can coexist).
2. In KOReader: **Duo → Debug → Read this first**.
3. **Duo → Debug → What the wire looks like** — confirms the device node
   opens and says whether a login prompt is holding it.
4. **Duo → Debug → Free the line**, then **Turn off the login prompt**, on
   both devices. This is the entry that writes to the device's own startup.
   Do not do it without §0's UART.
5. **Duo → Debug → Call down the wire**, on both within a few seconds, to
   confirm the line carries bytes at your baud rate.

Then start the native app on both — one as leader, one as follower:

KUAL → Duo → **Start Duo (as leader)** on the left-hand reader
KUAL → Duo → **Start Duo (as follower)** on the right-hand one

What should happen: the footer shows two page numbers rather than one, a tap
on either device moves both, and the follower sits one page ahead of the
leader. A font-size change on either moves the other.

**Photograph the two side by side.** That is the one thing no log can tell
me: whether the spread reads as a single page across the bezel gap —
baselines level, gutter even, no page ending mid-line.

> The device node defaults to `/dev/ttymxc0`, 115200. You said the wire
> holds the top speed; set **Link → Speed** to 921600 on both if so, and
> leave **Link → Let the line ask the other end to wait** alone — it is on
> by default and it is what stops a device stalled on an e-ink refresh
> overrunning the other end's buffer.

## 8. If a reader will not start

Charge it first, on a wall charger, for several hours. Then hold power 40
seconds.

Then the UART: 115200 8N1, power on, and watch.

- **Nothing at all** — the trouble is not software.
- **U-Boot and then a stall** — read what it says last.
- **`fsck` or mount errors** — the filesystem, not the jobs.

Nothing in this app moves a startup job. If you ran §7 step 4, the plugin's
own recovery applies, and every job it moved is sitting beside its old name
with `.duo-off` on the end:

```sh
mount -o remount,rw /
for f in /etc/init/*.duo-off /etc/upstart/*.duo-off; do mv "$f" "${f%.duo-off}"; done
[ -f /etc/inittab.duo-original ] && mv /etc/inittab.duo-original /etc/inittab
mount -o remount,ro /
```

To get a shell on a reader that will not boot: interrupt the bootloader over
the UART and boot with `init=/bin/sh`.

---

## What to send me

Whatever happens, these three are what I can act on:

1. `/mnt/us/duo/boot.log` and `/mnt/us/duo/duo.log`
2. The output of `./tools/build-base.sh`'s final `found`/`MISSING` list
3. A photo of the two screens side by side, if you get that far

A single error line from the log is usually enough. The probes exist so that
the first run on a device is one round trip rather than ten.
