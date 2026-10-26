# A native Duo app, launched from KUAL

A study. No code here changes the plugin; nothing here is built yet.

**The question.** Replace `duo.koplugin` with a native two-page reader app
launched from KUAL on a pair of jailbroken Paperwhite 3s — library view, a
real reader with font selection, embedded styles and fonts, margins — the two
devices joined by the wired serial link and never by Wi-Fi.

**The answer.** Yes, and more cheaply than it looks, but not the way the
question is phrased. Writing a reader is not the work; the work is already
done and is called CREngine. The honest project is *a new frontend on
koreader-base*, which is a different and much smaller thing than a reader
written from scratch and is still, precisely, a native app launched from KUAL
with no KOReader on top of it.

One thing has to be settled before any of it is worth starting, and it is not
a software question. See [The wire is the
risk](#the-wire-is-the-risk-and-it-is-the-only-one-that-can-sink-this).

---

## 1. What "font selection, embedded styles, margins" actually means

Those three items in the request are not three features. They are one
component, and it is the largest component in any e-reader:

| What you asked for | What it is underneath |
| --- | --- |
| Font selection | font enumeration, FreeType face loading, fallback chains |
| Embedded fonts | `@font-face` out of the EPUB's zip, into the rasteriser |
| Embedded styles | a CSS cascade over XHTML, per-document stylesheet merging |
| Margin adjustment | full reflow and repagination of the whole document |
| (implied) justified text | HarfBuzz shaping, kerning, language-aware hyphenation |

That list is a document layout engine. CREngine is roughly 100k lines of C++
and has had twenty years of other people's bug reports in it — hyphenation
dictionaries for dozens of languages, CJK line breaking, the EPUB files in
the wild that are malformed in interesting ways. Reimplementing it is a
multi-year project with a bad ending, and the result would paginate *worse*
than what you have today.

So the only sensible readings of the request are the ones that keep CREngine.

## 2. Three paths, and which one to take

**A. From scratch.** Own engine, own layout. Rejected, per above. Years, and
the typography would be worse than the plugin's on day one and on day one
thousand.

**B. Fork KOReader and strip the frontend.** Workable, but you inherit the
whole frontend in order to delete most of it, and every upstream pull becomes
a merge against code you have gutted. You would spend the project fighting a
codebase that is organised around being KOReader.

**C. Build a new frontend on `koreader-base`. ← recommended.**
[koreader-base](https://github.com/koreader/koreader-base) describes itself as
a "Base framework offering a Lua scriptable environment for creating document
readers." That is not an accident of wording — it is the layer KOReader itself
is a frontend *on*, and it is published for exactly this use. It gives you,
already cross-compiled for the device:

- **CREngine** for EPUB and the reflowable formats — the whole of §1
- **MuPDF** for PDF, **DjVuLibre** for DjVu
- the **per-device framebuffer, e-ink and input layer**, including the Kindle
  refresh-mode handling that is years of accumulated hardware grief
- **LuaJIT**, with the engines exposed through FFI bindings
- an **SDL2 desktop build**, so most of the frontend can be developed and
  tested on a laptop

Path C is a native binary, started by a KUAL shell script, that takes the
framebuffer and draws a reader. There is no KOReader in the picture. It is
what you asked for, and the engine question is answered by a dependency
instead of by a year of work.

## 3. The part that is already done

This is the finding that moves the estimate most, and it is in your own
repository.

`duo/` has **no host dependencies**. Every module imports only other `duo/`
modules, LuaJIT's `ffi`/`bit`, and — for the network transports only —
`socket`. The document is reached exclusively through an injected binding:

```lua
Core:attachReader{ getPage, getPageCount, gotoPage, turnRelative,
                   getDocument, openDocument,
                   getTypography, applyTypography, getPagesPerView }
Core:attachBrowser{ getState, goToPage, changeDir, refresh, setPerPage }
```

Eight methods and five methods. That is the entire coupling surface between
Duo's engine and its host. KOReader is simply the host that supplies them
today, and `main.lua` — 4,710 lines of "KOReader glue: menus, events,
page-turn wrapping" — is the only thing that would be thrown away.

| | lines | fate in a native app |
| --- | --- | --- |
| `duo/` engine, protocol, link, spread, crypto | 12,515 | **carries over** |
| └ of which TCP/discovery/direct-link/netutil | 943 | drops out (serial only) |
| `main.lua` KOReader glue | 4,710 | replaced by the new frontend |
| `spec/` suite and two-device harness | ~12,000 | mostly carries over |

`transport_serial.lua` already talks to the line through raw `open`/`read`/
`write` over LuaJIT FFI, with no KOReader anywhere in it. On koreader-base,
which ships the same LuaJIT, **it would run unchanged.**

So the wire protocol, the handshake, the signing, the role logic, the spread
arithmetic, the typography matching and the step-back-don't-hang-up behaviour
on a silent line are not work to be redone. They are a library you already
own, and it was — whether by intent or by good instinct — written to be
portable.

## 4. What a native app actually buys you

Worth being clear-eyed, because "it would be cleaner" is not a reason.

The plugin's structural weakness is stated in your own README:

> A spread only works if both devices break lines in the same places.

It achieves that by *matching settings* and trusting two independent CREngine
instances to agree. The README then lists where that trust fails: a typeface
only one device has, different screen sizes, the reload question answered two
ways, PDFs. Plus the fragility note — "which field holds a view's menu has
changed between KOReader releases" — which is what depending on another
program's internals costs.

A native app can make pagination **correct by construction** instead of by
coincidence, because you control both ends:

- **one pinned engine version** on both devices, shipped in the app bundle
- **the fonts shipped with the app**, so "a typeface only one device has"
  stops being a category of failure
- **one settings store**, with the leader as the only writer
- identical hardware, identical screen, identical build

Then the leader lays the book out, and what crosses the wire is *layout
state* — "page 14 begins at this position, these are its breaks" — not
pixels and not a hopeful set of matched preferences. The follower renders a
range it was told to render. That is a different architecture, and it is the
one real argument for doing this.

### The bandwidth that makes the choice

8N1 is ten bits to the byte, so:

| | bytes/sec |
| --- | --- |
| 115200 baud (console speed, the safe answer) | 11,520 |
| 921600 baud (the chip's ceiling, **unverified**) | 92,160 |

A PW3 screen is 1072 × 1448 = 1,552,256 pixels. One frame:

| depth | raw | zlib'd text page (est.) | @115200 | @921600 |
| --- | --- | --- | --- | --- |
| 1bpp | 189 KiB | ~10 KB | ~0.9 s | ~0.11 s |
| 4bpp (16 grey, antialiased) | 758 KiB | ~75 KB | ~6.5 s | ~0.8 s |
| **layout state only** | — | **~200 B** | **<0.1 s** | **<0.01 s** |

A PW3 panel refresh is itself 150–500 ms. So:

- **Shipping pixels is out.** 4bpp — which is what antialiased type needs —
  is 0.8 s per page at a baud rate you have not yet proven, and 6.5 s at the
  one you have. 1bpp at 921600 would work and would cost you font smoothing
  on a 300 ppi panel.
- **Shipping layout state is free**, at any baud rate, with the whole page-turn
  budget left for the panel. It is also the only option that survives the wire
  turning out to be a 115200 wire.

That settles the design: **deterministic layout at both ends, layout state on
the wire.** Keep pixel-shipping in the back pocket for PDF, where there is
nothing to reflow and the page is the page.

One free saving while you are there: the current protocol is line-based and
base64s its payloads, which costs 33%. A native app has no reason not to use
binary framing.

## 5. The wire is the risk, and it is the only one that can sink this

Everything above is tractable. This is not, yet.

You want the serial link exclusively. In the plugin, serial is the **least
finished and least verified** thing there is, and your own README is blunt
about it:

> **Work in progress, and the only part of Duo that can leave a reader unable
> to start.**

and

> The electrical half of this — baud rates, framing errors, a full FIFO,
> whether flow control does what it says on this driver — is not covered by
> the tests and cannot be; a pseudo-terminal proves the framing, the handshake
> and the state machine, and nothing about a wire.

Two PW3s stopped booting during the session that built it. The cause was
tracked to a probable brownout rather than to anything written to disk, and
two genuine faults found on the way were fixed — but the shape of the risk
stands: this is the one subsystem that opens the debug UART and edits the
device's own startup, and a reader that will not start cannot be fixed from
its own menus.

For the plugin, serial is one transport among three, and an experimental one.
For this app it would be **the only one**. The entire design rests on a
component whose electrical behaviour is unmeasured. Specifically unknown:

1. Does the line hold 921600 on this wiring, or does it fall back to 115200?
   §4's table shows this changes what is architecturally possible.
2. Does XON/XOFF do what the driver claims when a device stalls on an e-ink
   refresh? The README predicts a 4 KB overrun and garbled mid-message bytes,
   and notes that `Call down the wire` **cannot** reproduce it because both
   ends only read during the test.
3. What is the real loss rate under load, and does it rise or fall with baud?
   (The README's own principle: if losses fall as speed rises, they are not
   electrical.)

**This is step zero and it needs no new code.** The plugin already ships the
instrument — `Duo → Debug → Call down the wire` measures throughput and loss
on real copper. Run it before anything else is started.

If the answer is "115200, with overruns under refresh", that does not kill the
project — layout-state sync fits in 200 bytes — but it does kill any thought
of pixels, and it means flow control needs solving properly rather than
optimistically.

## 6. Is it worth it?

**It depends on something I can't read off the repository: is this a software
project or a device project?**

The README mentions 3D files for a shell. If the end state is *an object* — a
hinged two-screen reader, two PW3 boards with a permanent soldered link
between them, running your software and nothing else — then yes, this is worth
doing, and path C is how. A bespoke appliance has no use for KOReader's
breadth, wants a UI designed for two screens rather than one patched into
spreading, and makes a soldered wire the natural link rather than an exotic
one. Everything about the request fits that reading, including the insistence
on serial.

If the end state is *reading books more pleasantly on two Kindles you also use
for other things*, then no. You would spend months to arrive at something that
is better at exactly one thing and worse at everything else — formats,
dictionaries, hyphenation languages, annotations, OTA updates, and the fact
that someone else fixes the bugs.

### The cheaper 80%, if the pain is pagination

If what actually irritates you is spreads going subtly out of alignment, that
is attackable inside the plugin for a fraction of the cost, and it is worth
knowing before committing to a rewrite:

- **Bundle the fonts with Duo.** Removes "a typeface only one device has" as a
  class of failure — the single most likely cause of misalignment.
- **Add a layout fingerprint exchange.** Both devices hash their pagination
  (page count plus a handful of page-start offsets) and compare. Today a
  mismatch is silent and shows up as a spread that looks wrong; it could
  instead say so. This is small — the typography module already has a
  `signature(snapshot)` function to build on.

Neither is in scope here and I have not touched the plugin, but if the goal is
correct spreads rather than owning the stack, that is the honest first move.

## 7. What needs to be done

Ordered so the things that can kill the project come first and cost least.
Each stage answers a question; if the answer is bad, stop there.

### Stage 0 — Prove the wire *(hardware; no new code)*
- [ ] `Call down the wire` on both devices, at every offered baud, repeatedly.
- [ ] Find the real ceiling. Record loss, and whether it rises or falls with baud.
- [ ] Provoke the overrun case 2 above says the test cannot: a bulk transfer
      while the receiving device is forced into full e-ink refreshes.
- [ ] Decide: is flow control usable on this driver, or does the protocol need
      its own windowing?
- **Gate:** if the line will not carry a steady 115200 with recoverable loss,
  stop. Nothing above this works.

### Stage 1 — Toolchain and a native binary that starts *(mostly me)*
- [ ] `koxtoolchain`: `./gen-tc.sh kindlepw2` → `arm-kindlepw2-linux-gnueabi`
      (confirmed as the platform name; PW3 is an i.MX6 PW2-era device).
      A prebuilt container image exists if a local build fights back.
- [ ] Build `koreader-base` for `kindlepw2`.
- [ ] A KUAL extension (`extensions/duo/menu.json` + launcher script) that
      starts a binary which clears the screen, draws text, reads a tap, exits
      cleanly, and gives the framebuffer back.
- **Gate:** proves glibc compatibility, KUAL integration, framebuffer and
  input on the real device. Cheap, and everything else assumes it.

### Stage 2 — One page of a real EPUB on the real screen *(mostly me, then device)*
- [ ] Drive CREngine through koreader-base's FFI bindings from your own Lua —
      open an EPUB, lay it out, blit a page.
- [ ] Same binary against the SDL desktop build, for the development loop.
- **Gate:** the biggest unknown in path C. koreader-base is *published* for
  this, but "build a reader on it without KOReader's frontend" is not a
  well-trodden path. If CREngine turns out to be impractical to drive without
  large parts of KOReader's Lua, path C collapses toward path B.

### Stage 3 — Determinism *(desktop first, then two devices)*
- [ ] Two processes, same EPUB, same bundled fonts, same pinned engine, same
      params → identical page breaks, asserted byte-for-byte.
- [ ] Then the same across the two physical devices.
- **Gate:** this is what §4 is built on. If identical inputs do not give
  identical pagination, the architecture changes to pixel-shipping, which
  Stage 0's answer may already have ruled out.

### Stage 4 — Reader
- [ ] Page render, tap/swipe/button input, page turn, position persistence
- [ ] Font selection over bundled + user fonts; size, weight
- [ ] Margins, line and word spacing, justification
- [ ] Embedded styles on/off, embedded fonts on/off
- [ ] Table of contents, progress, bookmarks as far as you want them
- The bulk of the UI work. Lua against koreader-base, not C++.

### Stage 5 — Library view
- [ ] Scan the books folder; EPUB metadata and cover extraction
- [ ] Cover cache (the plugin's `epubstub.lua` already does cover-only stand-ins)
- [ ] A grid designed as **one grid across two screens**, rather than a
      single-device list that gets spread — the thing a native app can do that
      a patched `Menu` widget cannot.

### Stage 6 — Duo over the wire
- [ ] Port `duo/` across: drop the four network modules, keep the rest.
- [ ] Implement the two bindings — 8 reader methods, 5 browser methods.
- [ ] Replace line-based base64 framing with binary framing.
- [ ] Add the layout-state message from §4 and make the leader the sole layout
      authority.
- Much less work than its size suggests, for the reasons in §3.

### Stage 7 — Living on the device
- [ ] Suspend and resume; the README's note that a Kindle can suspend
      underneath the app without telling it
- [ ] Frontlight, battery, screensaver
- [ ] **Never leave the frontlight on** — that is what flattened the two
      readers that stopped booting
- [ ] Getting books onto the devices. At 11.5 KB/s a 1 MB EPUB is 87 seconds;
      your README already says books travel better by other means. Recommend
      v1 simply does not transfer books over the wire — sideload both and
      skip the entire subsystem.

### Effort, honestly
Stages 0–3 are the real question and are a few weeks, most of it Stage 2.
Stages 4–5 are the bulk and are months — a reader UI with full typography
control is not small, even with the engine handed to you. Stage 6 is weeks.
Reaching parity with KOReader+Duo *as it is today* is a serious project; the
difference is that it is a tractable serious project rather than an
impossible one, and about a third of it is already written.

## 8. What I need from you

I can do a lot of this without touching a Kindle, and nothing past Stage 1
without one.

**Without hardware, now:** Stages 1 and 2 on the desktop/SDL build, the
toolchain, the KUAL scaffolding, Stage 3's determinism harness as a
two-process desktop test, and the Stage 6 port — the existing `spec/` harness
already runs two instances against each other over real sockets and a
pseudo-terminal, so most of Duo's logic can be re-tested without a device.

**Needs you at the hardware:**

1. **Stage 0, the wire measurement.** This is the blocking one and it is
   yours — I cannot solder, and I cannot read a UART. What I need back is the
   `Call down the wire` output at each baud rate, and the Duo log alongside
   it. Paste it as text; that is enough for me to work from.
2. **A way to get a binary onto a device and run it.** Any of: you run the
   commands and paste output; USB networking plus SSH; or — the best option if
   you want this to move quickly — **link your computer via Remote Control**,
   and I can drive the cross-compile-and-push loop directly, which turns a
   many-round-trip conversation into something I can iterate on. Ask me and
   I'll walk through setting it up.
3. **A serial console on at least one device, wired and tested, before Stage 1
   runs anything.** Your own README: a reader that will not start cannot be
   fixed from its own menus, and the UART is the way back in. Please also
   confirm you can interrupt the bootloader over it.

**Photographs, at checkpoints.** Useful, with a caveat about what helps: I
cannot watch a live webcam feed, so a streaming camera buys nothing. Still
photos uploaded into the conversation do, and for two specific things that no
amount of log output substitutes for — **the two screens side by side**, to
judge whether a spread actually reads as one page (gutter, alignment, baseline
match across the bezel gap), and **the panel itself**, for ghosting and
refresh artefacts. A phone photo at each UI milestone is the right cadence.

**Battery discipline, as a standing request.** Both readers on a wall charger
before any session that touches the UART or startup. The two that stopped
booting came back after being run flat and charged properly, and the evidence
pointed at a brownout rather than at anything written to disk. Cheapest
insurance available.

## 9. Recommendation

1. **Run Stage 0 before deciding anything.** It needs no new code, the
   instrument is already in your plugin, and it is the one unknown that can
   invalidate the design. Everything else waits on it.
2. If the wire holds up, **take path C** — a new Lua frontend on
   `koreader-base`, with `duo/` ported across and the leader as sole layout
   authority.
3. **Do Stages 1–3 before writing any UI.** They are cheap, they are where the
   project can die, and Stage 2 is the one that decides whether path C is real.
4. Treat it as a **device project**. If it is not one, the two cheap fixes in
   §6 get most of the benefit for a fraction of the cost.

---

*Sources for the platform specifics:
[koreader-base](https://github.com/koreader/koreader-base),
[koxtoolchain](https://github.com/koreader/koxtoolchain)
(`gen-tc.sh` platform list, where `kindlepw2` → `arm-kindlepw2-linux-gnueabi`),
[KOReader build docs](https://github.com/koreader/koreader/blob/master/doc/Building_targets.md).
Everything about Duo's own structure is from this repository; everything about
the wire is from its README, which is the only record of what the hardware has
actually been observed to do.*
