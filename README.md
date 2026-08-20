# KOReader Duo

Two e-readers, side by side, showing one book as a two-page spread.

One device is the **leader**: it owns the page number and tells the other
what to show. The other is the **follower**: it displays the page it is
given and can pass page turns back. A single tap moves both.

![One tap on the leader moves both devices on by two](screenshots/page-turn.png)

Two copies of KOReader reading *Alice's Adventures in Wonderland*. The
leader is on page 13, the follower on 14, and the prose runs straight across
the gap — the left screen ends *"she was now the right size for going"* and
the right picks up *"through the little door into that lovely garden."* One
tap takes the pair to 15 and 16, so no page is read twice or skipped.

**Mirror mode** shows the same page on both, for reading along with someone
else. A third device joins as slot 2 and shows the page after the follower's.

## Installing

Copy `duo.koplugin` into KOReader's `plugins` directory on **both** devices
and restart KOReader.

```sh
make install KOREADER=/mnt/us/koreader     # jailbroken Kindle
# or just:
cp -r duo.koplugin /path/to/koreader/plugins/
```

It appears under **☰ → Network → Duo (two-device spread)**, in the reader
and in the file manager.

## Pairing

Two questions, in that order, on each device: **how** the pair should reach
each other, then **which** device this one is.

**Duo → Connect the two devices…**

1. **Over a Wi-Fi network** — both already on the same router or hotspot —
   or **Directly, with no router**, where one device makes the network
   itself.
2. **This device leads (left page)** on one, **This device follows (right
   page)** on the other.

The leader shows a pairing code. The follower searches and lists what it
finds, so there is normally no address to type — pick the leader and enter
the code if asked. Over a direct link there is nothing to pick at all: the
leader is always at a fixed address and the follower goes straight there.

That is it. Open a book on the leader and the follower follows. Closing it
takes both back to the book list, and a book tapped on the *follower* opens on
both: the tap goes to the leader, which leads the way in, so the two never
end up in different books.

If the search finds nothing — some networks block broadcasts — use **Type
the address by hand**.

## Getting the two devices talking

The link is only a byte pipe, so several things can carry it.

### Any Wi-Fi network — works today

A home router, or a phone hotspot with no internet on it. Pair as above.
This is the best-tested path.

### The two devices, direct — no router, no DHCP

For reading somewhere with no network at all: **Duo → Connect the two
devices… → Directly, with no router**, then pick which device this is.

The leading device makes the network — an access point where it can, an
ad-hoc cell otherwise — takes `169.254.13.1`, and starts Duo.

**Then, on the other device** — the step that is easy to miss:

- **Another reader running Duo**: same two taps, choosing **This device
  follows**. It takes `169.254.13.2` and connects on its own, nothing typed.
- **Anything else** — laptop, phone, desktop KOReader — joins the network
  first, the ordinary way. It is called **`KOReaderDuo`**, passphrase
  **`koreaderduo`** (override with `DUO_SSID` and `DUO_PASSPHRASE`). Then
  pair as a follower; the leader is always at `169.254.13.1`.

The host's screen says all of this once the link is up.

**If it fell back to ad-hoc, that second option is gone**, and the screen
says so. An ad-hoc cell carries the spread between two readers perfectly
well, but other devices will not list it: modern Linux Wi-Fi daemons dropped
ad-hoc support, phones never had it, and a laptop scanning for
`KOReaderDuo` will find nothing. Another reader still joins from the menu,
because it joins by name rather than from a list.

Whether a Kindle can do this at all comes down to its Wi-Fi. Check first,
over SSH:

```sh
/mnt/us/koreader/plugins/duo.koplugin/tools/duo-direct-link.sh probe
```

Read the output rather than skimming it. `iw phy phy0 info` reports what the
*driver* can do and says nothing about the software, so `wpa_ap` is the line
that matters. Kindle firmware ships a stripped `wpa_supplicant` built
without `CONFIG_AP` — AP mode drags in most of hostapd, so it is the first
thing dropped — and such a device advertises AP, accepts the configuration,
forks into the background and then silently refuses. The probe reads the
giveaway out of the binary (`AP mode support not included` is compiled in
only when the feature is *missing*) and picks ad-hoc up front. Ad-hoc needs
nothing from `wpa_supplicant`: it goes through `iw` and the kernel.

The gap cuts the other way off a Kindle. A desktop whose card plainly does
AP mode still gets a no without `wpa_supplicant` installed — a machine
running iwd or NetworkManager often has none — and a wired-only desktop has
no wireless phy at all.

Three methods are driven automatically: AP where it works, ad-hoc where it
does not, and old-style ad-hoc through `iwconfig` for pre-`iw` drivers. A
fourth is reported but not driven: a device advertising only Wi-Fi Direct
(`P2P-GO`) can host a group Duo will pair across, but setting one up means
choosing an SSID and passphrase, so that part is yours.

The script also does `host`, `join`, `status` and `restore`, and takes
`--dry-run` on any of them so you can read the commands first.

It does not matter whether the link was set up from the menu or by hand
over SSH: Duo works out which side it is on from the addresses, which are
fixed and used by nothing else. A link built over SSH used to leave nothing
behind saying so, and every automatic check politely decided it was none of
its business.

**Duo → Link → Check the direct link now** asks the same question from the
menu and answers on screen: whether the link is still there, that it is
rebuilding one that has gone, and the script's own words if the rebuild
fails. It is the same check that runs by itself, with the waiting taken
out — worth reaching for before assuming a sleep is to blame.

**restore** gives Wi-Fi back, and does the whole job: it leaves the cell,
puts the interface back to managed — an interface left in ad-hoc is one the
system's Wi-Fi daemon cannot use, and it never says so, it simply never
connects — and flicks the device's own Wi-Fi switch off and on, which is
the airplane-mode toggle people otherwise end up doing by hand. Duo then
asks KOReader to rejoin the usual network so its idea of things matches the
device's.

**It verifies the link appeared** rather than trusting that the commands
ran. The interface is watched until it really is an AP or an ad-hoc cell;
if it never gets there the script says so and quotes wpa_supplicant. Its
last line is `mode=`, so there is never any doubt which kind of network is
up. `status` reports the same afterwards: `type AP` or `Mode:Master` for an
access point, `type IBSS` or `Mode:Ad-Hoc` for ad-hoc, `Mode:Managed` for
neither.

### Bluetooth — not on a stock Kindle

Kindles do not run bluez: no `rfcomm`, no `hciconfig`. Amazon's stack is its
own, and the community page-turner plugins reach it through a userspace
stack that speaks HID only — a one-way keypress channel, not a byte stream.
So there is nothing for Duo to bind to.

The plugin side is finished regardless. A bound RFCOMM channel is a
character device, and Duo's serial transport talks straight to one:

```sh
rfcomm bind /dev/rfcomm0 AA:BB:CC:DD:EE:FF 1     # where rfcomm exists
```

Then on both devices: **Duo → Link → Serial line (RFCOMM or UART)**, set
**Serial device**, and start one as leader. There is no address — the line
*is* the connection — and the pairing code still applies. This is tested
end to end against a pseudo-terminal pair, which is what an RFCOMM channel
looks like, so it works on anything exposing one.

**Bluetooth PAN** needs nothing special: it presents as an ordinary
network, so leave Duo on **Link → Wi-Fi**.

### A cable between the two — not with USB alone

A micro-USB cable with a plug at each end cannot work. A Kindle's port is a
USB *device* port: it waits to be enumerated and never enumerates. USB needs
exactly one host and one device, so joining two device ports gives neither —
nothing enumerates and no interface appears.

**USBNetwork does not change this**, which is worth saying because it looks
as though it should. It is `g_ether`, the gadget half: it makes the reader
appear to a *host* as a USB Ethernet adapter. Run it on both ends and you
have two devices waiting for a host that is not there.

Host mode is the only way round, and a plain cable would not select it even
on hardware that could: it is chosen by grounding the ID pin, and the host
must supply power out of a port built to take it in. That is a
soldering-and-kernel project, and whether a given model can do it at all is
a question for people who hack Kindle kernels.

What does work is a host in the middle. Anything that can be a USB host and
route between two Ethernet gadgets — a Pi, an Android phone with OTG
tethering, a laptop — gives both readers a `usb0` with an address, and Duo
sees a network like any other. It takes whatever interface has an address,
so no special setting is needed. Only worth it if you already have such a
thing; a phone hotspot works anywhere.

### A wire with no third device: the debug UART

There is one wired route between two readers alone, and it is not the USB
port. Kindles have a serial console on test pads inside the case — the one
used to rescue a bricked device. Two of those joined TX-to-RX with a common
ground are a serial line, and Duo's serial transport talks to any character
device. Set **Link → Serial line** and name the port on each side.

It is a soldering job, with three things to get right:

- **Free the port first.** The UART is normally the kernel console with a
  login on it. Drop the `console=` argument and stop the getty.
- **Match the levels.** These pads are 1.8 V on many models, 3.3 V on
  others. Two of the same model are fine wired directly; mixing them may
  need a level shifter, and getting it wrong damages a reader.
- **Expect it to be slow.** At 115200 baud, about 8 KB of book a second.
  Page turns are a few dozen bytes and feel instant; a 500 KB novel takes a
  minute; a whole library is an argument for leaving *covers now, books when
  you open them* on. Raise **Serial baud** if the port allows.

## Settings

Everything is under **☰ → Network → Duo (two-device spread)**. The top line
is the live connection: role, peer, and the pages on show.

![Both pages of Duo's menu, with the status line "Leader · Kindle-Right · pages 7–8"](screenshots/duo-menu.png)

Taken on the leader of a pair reading *Alice*. *Fetch any missing books now*
is greyed out because this is the device the books come **from**.

| Setting | What it does |
| --- | --- |
| **Layout → Two-page spread** | Leader shows page N, follower shows N+1. A turn moves by two. |
| **Layout → Mirror the same page** | Both show the same page. A turn moves by one. |
| **Layout → This device holds the right-hand page** | Swaps the sides: the follower shows the *earlier* page. |
| **Link** | Wi-Fi (any IP network, including Bluetooth PAN), a direct router-free link, or a Bluetooth/serial device. |
| **Match typography** | Keep both devices laying the book out identically. On by default. |
| **Match the frontlight** | Keep both at the same brightness, and warmth where they have it. On by default. |
| **Share the book list too** | Spread the file browser across the devices as well. On by default. |
| **Lock one, lock both** | Sleeping either device sleeps the other. On by default. |
| **Keep the whole library in step** | Fetch whatever books the shared folder is missing here. On by default. |
| **Stop copying now** | Stops whatever is being copied, at both ends. |
| **Covers now, books when you open them** | Fill the shelf with covers and titles, fetch each book when first opened. **Off by default**, EPUB only, and may be removed. |
| **Page turns from the other device** | Off makes the follower a display only. |
| **Follow the leader's book** | When the leader opens a book, open it here too. |
| **Send the book if the other device lacks it** | Hand the file over the same link. On by default. |
| **Start Duo when KOReader starts** | Reconnect on launch in the last role used. |
| **Pairing code** | Shared secret. Empty means any device may connect. |
| **Device name** | What the other device calls this one. |
| **Port** | TCP port, 9970 by default (UDP 9971 for the search). |

Two Dispatcher actions are registered for gestures and hardware keys: **Duo:
start/stop** and **Duo: resync now**.

**The settings above are shared, and the leader is the tiebreaker.** Every
row that describes how the *pair* behaves — the layout, page turns from the
other device, the book list, typography, the frontlight, library syncing and
its limits — crosses the link. On connecting, the leader's values win, so
two devices configured differently end up agreeing rather than racing.
Change one afterwards on either device and the other follows; a follower hands
its change to the leader, which applies it and passes it on.

Not shared, deliberately: the port, the pairing code, the peer address, the
device name and the transport. Those are what let the two find each other,
and levelling them would be a fine way for a pair to talk itself into
silence.

This matters more than it sounds. Several features are checked on *both*
devices — page turns from the follower for one — so switching such a thing off
on one device used to disable it silently, and which device you had to look
at differed from feature to feature.

## The book list, spread too

The same idea one level up: the leader shows the first screenful of a
folder, the next device the screenful after, and one swipe moves the row.
Twice the library in view.

![One book list across two screens](screenshots/library-spread.png)

The halves only line up if both devices hold the same books, so **Duo
fetches what is missing**. The device that is behind asks for the other's
listing, works out what it lacks, and pulls those books across one at a
time, counted off in the status line.

![The follower with three books, then with the leader's ten, on the second screenful](screenshots/library-sync.png)

That is **Keep the whole library in step**, on by default. Off, Duo still
spreads the list but only reports the difference — the left-hand screen
above.

**Only books are ever copied.** The shared folder is whichever one the
leader is looking at, so a wrong turn into a downloads folder is easy, and
the file browser hides unopenable files only until someone turns that
setting off. Duo works from an allowlist of the formats KOReader opens —
EPUB, MOBI, PDF, DjVu, CBZ, plain text and the rest — checked in three
places: the leader leaves non-books out of the listing, the receiver drops
them from what it asks for, and the leader refuses one asked for by name.
That last gate is the one that would otherwise put a file's bytes on the
wire.

There is **no ceiling** on how much a sync may copy. There used to be one,
and it was the wrong shape of help: a refusal, delivered with a number
nobody had chosen, on a feature that then needed a setting raised before it
would work at all. What Duo owes you instead is a warning and a way out, so
a folder past about 100 MB says how long it is likely to take and suggests
copying the books across yourself, and **Stop copying now** in the menu ends
a transfer at both ends whenever you have had enough. The status line
carries the percentage, and it is announced every tenth of the way.

A book that will not come is remembered for the session, so a folder that
cannot be made to match stops asking for the same file over and over, and
says at the end how many did not arrive.

### Covers now, books when you open them

Copying a library before anything can be read is a lot of waiting for books
you may never open. So Duo sends a **stand-in** for each: a real EPUB
carrying the cover and title and nothing else. The shelf fills at once, the
halves line up straight away, and the book itself arrives the first time you
open it, landing over the stand-in.

![A shelf of covers, and one of them opened after a tap](screenshots/covers-first.png)

Ten Gutenberg books came to 2.2 MB as stand-ins against 6.2 MB whole, and
the one opened took five seconds. The saving depends on the covers: these
are big scans on small books, and a more usual library saves far more.

It is **off by default**, and not settled. Fetching on first open puts a
transfer between the tap and the page: the link has to be up, the other
device has to still be holding the file, and the wait lands at the one
moment a reader cannot do anything else. It reads well and behaves less
well, and it may be removed rather than patched around further. On, the
shelf fills at once; off, the whole library is copied up front.

Two limits. It is **EPUB only** — a stand-in must carry the name of the book
it replaces, so it must share the format, and there is no such thing as a
PDF with no pages. And no book can be *read* while it downloads: an EPUB is
a zip whose index sits at the end, so there is no first page until the last
byte lands. Duo starts the moment you tap and opens the moment it is there.

Only the folder on show is involved. A request carries a bare file name that
must appear in that listing, and the path is rebuilt from the shared folder,
so nothing outside it can be reached however the name is spelled.

Items per page is matched along with the typography, since it decides where
one screenful ends. Three widgets can draw that list and they disagree about
where the number comes from — the plain browser reads KOReader's setting,
the cover browser's list mode computes its own and ignores it, and mosaic
mode has only a grid. Duo tells whichever is in charge, in its own terms.

**Mosaic works too**, spread included: the shape travels with the page, so a
device showing 2 × 3 covers puts the other on the same grid with the next
six books.

![Two cover grids of real books, the leader showing the first screenful and the follower the next](screenshots/mosaic-spread.png)

Ten Gutenberg EPUBs at `/tmp/kolib`, seven of which the right-hand device
did not have a minute earlier.

A grid can only be matched against a grid. Told only that the other device
fits eight, there is no telling whether that is 2 × 4 or 1 × 8, and guessing
would rearrange your screen — so with one device on a grid and the other on
a list, Duo leaves both alone and says the halves will not line up.

A turn moves the row by as many screenfuls as there are devices, exactly as
in a book: two devices on screens 1 and 2 go to 3 and 4. That holds in the
grid too, and a swipe on either device moves the pair. Unlike KOReader's own
paging the list stops at the end rather than wrapping, since wrapping would
put the devices on unrelated parts of it.

Switch it off with **Share the book list too** to browse independently and
share only the reading.

### Only KOReader's own file browser, for now

The shared book list works in KOReader's file browser and nowhere else. Duo
binds to the `FileChooser` the file manager builds, so plugins that replace
the browser with a home screen or a library grid of their own are not
covered: those are their own widgets, not a file chooser, and Duo will not
spread them. Nothing breaks — the listing simply is not shared while you are
on such a screen, and stepping into the real file browser brings it back.

One consequence is worth knowing, because it is not obvious. Such plugins
usually open books by calling `ReaderUI:showReader` directly rather than
going through the file manager, which is the point Duo intercepts. So on the
follower, a book tapped on one of those screens opens **locally only** — it
is not handed to the leader, and the two devices end up in different books.
With *covers now, books when you open them* on, tapping a stand-in there
opens the placeholder rather than fetching the real book.

Reading itself is unaffected: such plugins do not touch the reader's page
turns, so the spread, typography, the frontlight and book transfer all work
normally once a book is open.

## Sending the book

Following someone's reading is no use if you cannot open what they are
reading. When the leader opens a book the other device lacks, that device
asks for it, the file comes down the same link as the page numbers, and it
opens at the right page. On by default; no server, cable or account. The
status line shows progress.

- **Only the open book can be asked for.** The leader answers a request only
  if it names the book it actually has open. No arbitrary paths.
- **Books land in a `Duo` folder** inside your library.
- **Half a book is never left behind.** Written to a part-file, moved into
  place only once it has all arrived and the size matches.
- **There is no size limit.** A book past about 100 MB says so before it
  starts, and can be stopped from the menu at any point.
- **A transfer that dies says so.** A failed chunk is reported rather than
  abandoned, and a book that goes thirty seconds without a byte is written
  off at the receiving end, so one bad transfer cannot wedge the rest.

Over Wi-Fi, a few hundred kilobytes takes a handful of seconds — about
100 KB/s, since the bytes travel as text on the same line-based link. Over
serial it takes as long as the line takes: the transfer is paced by how fast
the other end drains it, so a slow link is slow rather than broken.

Books travel base64-encoded in the **URL-safe** alphabet. That detail
matters more than it looks. The protocol's lines carry a restricted
character set and escape everything else; `+` and `/` are not in it, and a
compressed file — which every EPUB is — produces enough of them to push a
chunk past the line limit. The result was transfers that failed part way
through a real book while sailing through any test written with tidy data.
Two characters' difference, and nothing needs escaping at all.

## Matching typography

A spread only works if both devices break lines in the same places, and
"please set the same font size on both" is an instruction nobody follows.

**On connecting, the leader's settings win.** Afterwards a change on
*either* device moves the rest, leader included — a follower hands its change
over and the leader applies it and passes it on, so the leader is still the
only device deciding.

Matched — everything that moves a line break:

> typeface · font size · font weight · hinting · kerning · line spacing ·
> word spacing · word expansion · CJK width scaling · left/right margins ·
> top and bottom margins · view mode · columns · block rendering mode ·
> zoom (render DPI) · embedded styles · embedded fonts · status bar

Left alone, being yours or particular to one device:

> rotation · night mode · frontlight · image smoothing · refresh settings ·
> anything not affecting where the text falls

Changed the wrong device? **Undo: restore my own typography** puts back what
this device had before Duo first touched it. The snapshot is only recorded
when something really changed, so the undo is never offered for a change
that never happened.

Two caveats:

- **A typeface has to exist on both devices.** If the leader uses one this
  device lacks, Duo says so rather than leaving the pages misaligned.
- **Different screen sizes cannot be matched.** Two Kindle models paginate
  differently whatever the settings. Duo warns about it once, after matching
  has been tried and the pages still disagree — and stays quiet about a
  mismatch it is about to fix itself.

Reflowable formats only: a PDF has the pages the file says it has.

## Matching the frontlight

Two readers held side by side as one book look wrong when one is brighter
than the other — more obviously wrong than a mismatched font size, since
the eye compares the two halves directly. So **Match the frontlight** keeps
them level, warmth included on the devices that have it.

Brightness is not a number two devices can agree on, though. KOReader drives
a Kindle's light from 0 to 24 and a Kobo's from 0 to 100, so nothing here
sends a level: it sends a *proportion* of each device's own range, and each
end scales it back to whatever hardware it has. A Kindle and a Kobo agree
about "three quarters" without either knowing what the other's numbers mean.
A reader with no warm light quietly ignores the warmth and still matches the
brightness, and one that cannot turn its light off is given its lowest step
instead of darkness.

Percentages rounded onto a 24-step light rarely land exactly, so a
step-either-way tolerance stops the two devices politely correcting each
other for ever. As with typography, the leader wins on connect and a change
on either device afterwards moves the rest.

## How it works

- **One authority.** Only the leader decides what page anything shows. A tap
  on the follower is a *request*: it goes to the leader, which moves and then
  tells everyone where they stand. The screens cannot drift apart because
  only one of them is ever deciding.
- **Page turns are intercepted, not simulated.** Every tap, swipe, gesture
  and button ends up in the reader's `onGotoViewRel`, so Duo wraps that one
  method and multiplies the distance by the number of devices. Absolute
  jumps are left alone; the spread follows from the resulting `PageUpdate`.
- **The connection outlives the plugin.** KOReader rebuilds a plugin
  instance every time you open a book, so the engine lives in a module
  singleton (`duo/core.lua`) and the instance only attaches a binding to the
  current document.
- **Pairing without sending the secret.** The leader challenges with a
  nonce; each side answers `SHA-256(nonce:code)`. The code never goes on the
  wire and a captured proof is useless next time. This keeps the wrong
  device out; it is not protection against someone who controls your
  network.
- **Wire format** is one line per message — `STATE page=13 pages=300` —
  percent-encoded so titles and paths survive. No JSON, and legible in a
  packet dump.
- **Polling** happens in KOReader's own UI loop, which visits registered
  sockets at least every 50 ms. No threads, no blocking reads, nothing
  keeping the CPU awake between page turns.

## Things worth knowing

- **Keep Wi-Fi on.** If KOReader drops Wi-Fi after a while, the link goes
  with it. Duo reconnects by itself, but the gap is visible.
- **Sleep.** Sockets are shut down cleanly on suspend rather than left to
  time out, and coming back is a retry rather than one attempt: a device
  wakes well before its radio does. A router-free link is checked a few
  seconds after waking, on **both** devices, because such a link does not
  survive a deep sleep at all — the reader's own Wi-Fi daemon takes the
  interface back into managed mode.

  Over an ordinary Wi-Fi network none of this is needed: the reader
  restores its own connection on waking and Duo's reconnect loop simply
  walks back in. It is only a link Duo built itself that has nobody else to
  put it back.

  That check also runs **without being asked**, a couple of seconds after
  the pair stops being able to reach each other — and at that point it
  rebuilds rather than asking whether it needs to. Three separate waits
  used to stack up here and made recovery take twenty seconds: how long
  before a dead link is noticed at all, how long before the network is
  rebuilt, and how long the reconnect backoff had grown to meanwhile. All
  three are now sized for a link with exactly one device on the other end.
  A pair that has *never* connected is left alone for longer, since that is
  usually somebody midway through setting it up. Running the setup script by hand fixes
  this every time, and the only difference is that the script does not
  first talk itself out of the work. A link that still looks well after
  twenty seconds of silence plainly is not. Waking is not something to depend on
  being told about: the notification travels through the reader's power
  daemon, its screensaver handling and an event broadcast, and if any of
  that does not fire on a particular firmware then nothing would ever look
  at the network again. Being disconnected is its own reason to look. It
  costs one status call a minute and rebuilds only when the link really has
  gone.
- **Locking one locks both.** Whichever device is put down, the other
  follows, rather than sitting lit on a page nobody is reading. Sleeping a
  Kindle means asking its power daemon to press the power button, and a
  press is a toggle — so a device already asleep is never prodded, and two
  readers put down within a few seconds of each other are treated as one
  decision rather than two instructions. Without both rules the pair take
  turns waking each other. Switch it off under **Lock one, lock both** if
  you would rather handle sleep yourself, with a magnetic cover or
  otherwise.
- **The pair dozes together.** Duo has no timer of its own — it is polled by
  the UI loop, and a reader in standby stops polling, so a sleeping follower
  stops following. Rather than hold two devices awake, only the leader
  decides: it stays up while the book is being read and lets go five minutes
  after the last turn, and the follower does exactly the same. A transfer in
  flight holds both, half a book being worse than a minute of battery.

  A sleeping follower cannot be woken by the leader — nothing arrives to
  wake it, which is the point of being asleep. Waking them is a tap each,
  and the follower asks where it belongs the moment it comes back.
- **Kindle firewall.** Kindles drop incoming connections; the leader opens
  the port with `iptables` while it runs and closes it after.
- **Battery.** The heartbeat is one small packet every two seconds on an
  open socket. Wi-Fi being on at all is the real cost.

## Tests

```sh
make test          # everything, on LuaJIT
make test LUA=lua5.1
```

279 tests, no mocking of the interesting parts:

| Suite | Tests | What it covers |
| --- | --- | --- |
| `protocol_spec` | 24 | Framing, escaping, byte-at-a-time reassembly, SHA-256 vectors, reading our own address out of `ip`/`ifconfig` |
| `link_spec` | 13 | Real loopback sockets: connect, refuse, partial writes, handshake, heartbeats, and a check that the pairing code never appears on the wire |
| `plugin_spec` | 42 | The real `main.lua` under a stub KOReader: menus, page-turn interception, the reader binding, and coming back from a sleep the network has not finished waking from |
| `integration_spec` | 66 | **Two and three device processes over real TCP**: spreads, turns from either device, absolute jumps, mirror, reverse, end of book, reconnects, document following, typography and settings and the frontlight converging from both directions, a book sent between devices, and one book list spread across two screens |
| `serial_spec` | 7 | The same two processes over a pseudo-terminal pair, standing in for a bound RFCOMM channel |
| `typography_spec` | 12 | Reading, encoding and applying layout settings, including margin pairs and a missing typeface |
| `library_spec` | 14 | **The whole library brought into step**: the follower in its own mount namespace with a different folder at the same path, so the books really have to travel — plus a firmware image in that folder that stays where it is |
| `browser_spec` | 15 | Reading and paging the book list, the listing hash, matching a screenful through all three widgets that draw it, and refusing a folder the device does not have |
| `booktransfer_spec` | 19 | Both base64 alphabets against the published vectors, every byte value round-tripped, a full chunk of the worst bytes that exist kept inside the line limit, short and oversized transfers refused, and a peer that tries to name its own destination |
| `frontlight_spec` | 17 | The brightness arithmetic: a level read as a share of one device's range and put back on another's, every step of a 24-step light surviving the round trip, and warmth skipped where there is none |
| `epubstub_spec` | 16 | Reading the cover out of an OPF the three ways EPUBs name one, and building a stand-in that survives being read back |
| `directlink_spec` | 30 | Driver capability probing against real `iw` output shapes, the exact commands each method issues, and that the link is verified rather than assumed |
| `directlink_net_spec` | 5 | **Two network namespaces on a link-local /16**: the router-free network, with search, connection and spread across it |

Two tools double as documentation, and both print live data:

```sh
luajit tools/duo-demo.lua 3      # run three devices, print what each displayed
luajit tools/duo-menu-dump.lua   # print the menu exactly as the device builds it
```

The suite runs the plugin against `spec/harness`, which provides KOReader's
frontend API — same module names, signatures and event-propagation rules —
with `main.lua` loaded unmodified. That keeps it fast and lets it stage
things that are tedious in a running application: a yanked connection, a
wrong pairing code, two network namespaces. Devices in the integration
suites are separate OS processes sharing nothing but a socket.

The harness is not the last word, though — see below.

## Verified in KOReader itself

The screenshots are two copies of **KOReader v2026.03** running the plugin:
separate processes and settings directories, paired over a real socket,
reading Gutenberg's *Alice in Wonderland* laid out by crengine, with page
turns arriving as real events. The status line — `Leader · Kindle-Right ·
pages 7–8` — is the plugin reporting the live connection.

Checked there, not only in the suite:

- **Typography.** Raising the font size on the leader moved the follower with
  it. The follower relaid the book out, put itself back on the right page
  without waiting for a turn, and said nothing about the disagreement while
  the change was in flight.
- **Sending the book.** With the leader's library hidden from the follower (a
  tmpfs over it in a private mount namespace, so the file really was
  missing), the follower asked, received all 174,311 bytes — identical MD5 —
  and opened it as page 10 against the leader's 9.
- **The whole library.** Same trick one folder up: three books on the follower
  against the leader's ten real Gutenberg EPUBs at the same path. The follower
  fetched the seven it lacked, 4.2 MB in forty seconds, every MD5 matching,
  and moved to the second screenful unprompted. Real books are also what
  turned up the base64 bug above; fixtures would not have.
- **Paging the grid.** Thirty books in a 2 × 3 grid, six screenfuls. One tap
  took the pair from 1 and 2 to 3 and 4, then 5 and 6, then stopped rather
  than wrapping. A swipe on the *follower* moved the row back.
- **Covers first.** Ten books arrived as stand-ins — 2.2 MB against 6.2 MB —
  covers drawn by KOReader's own cover browser out of files holding no book
  at all. Tapping *Wuthering Heights* fetched the real 587,526 bytes in five
  seconds and opened at page 1 of 705.
- **Matching the screenful.** Against all three widgets that draw the list.
  Plain browser: the follower went from 6 items a screen to the leader's 10.
  Cover browser list mode, where the global setting does nothing: 6 to 10
  through that plugin's own `files_per_page`. Mosaic: a 2 × 2 grid to the
  leader's 2 × 3, taking books 6–10. Given a screen too short for ten rows
  the widget overrode the count back to nine, and Duo said so rather than
  pretending the halves lined up.

To repeat it on a desktop:

```sh
# any recent release; assets are per-tag, so check the name for yours
curl -L -o koreader.AppImage \
  https://github.com/koreader/koreader/releases/download/v2026.03/koreader-v2026.03-x86_64.AppImage
chmod +x koreader.AppImage && ./koreader.AppImage --appimage-extract
cp -r duo.koplugin squashfs-root/usr/lib/koreader/plugins/

# two instances, each with its own HOME so their settings stay apart
cd squashfs-root/usr/lib/koreader
KO_MULTIUSER=1 HOME=/tmp/ko1 ./reader.lua /path/to/book.epub &
KO_MULTIUSER=1 HOME=/tmp/ko2 ./reader.lua /path/to/book.epub &
```

One difference from a Kindle, if you compare against the screenshots: the
desktop build reports a keyboard, so KOReader draws a Q/W/E/R shortcut
beside every browser row. To match, drop this in
`$HOME/.config/koreader/patches/2-no-item-shortcuts.lua`:

```lua
require("ui/widget/menu").is_enable_shortcut = false
```

Then pair them as usual, the second connecting to `127.0.0.1`. Setting
`["autostart"] = true` and `["autostart_role"]` in
`$HOME/.config/koreader/settings/duo.lua` skips the tapping.

## Layout

```
duo.koplugin/
  main.lua                  KOReader glue: menus, events, page-turn wrapping
  _meta.lua
  duo/
    core.lua                the engine: roles, links, who shows which page
    spread.lua              spread arithmetic, kept dependency-free
    typography.lua          keeping both devices laying the book out alike
    browser.lua             the book list, spread across the devices
    booktransfer.lua        sending the book file itself, a chunk at a time
    epubstub.lua            cover-only stand-ins, for covers-first syncing
    frontlight.lua          matching brightness across different light ranges
    base64.lua              so a book fits down a line-based link
    link.lua                one authenticated connection: handshake, heartbeat
    protocol.lua            message framing
    transport_tcp.lua       non-blocking TCP, for Wi-Fi and Bluetooth PAN
    transport_serial.lua    non-blocking character device, for RFCOMM
    discovery.lua           UDP search, so nobody types an IP address
    directlink.lua          the router-free link: probe, host, join
    netutil.lua             local address, Kindle firewall
    sha256.lua              for the pairing proof
    util.lua
  tools/
    duo-direct-link.sh      brings the router-free Wi-Fi link up and down
spec/                       tests and the KOReader harness
tools/
  duo-demo.lua              runs a real session and prints what each device showed
  duo-menu-dump.lua         prints the menu as the device builds it
```

## License

Intended to be used with, and distributed under the same terms as, KOReader
itself: **AGPL-3.0**.
