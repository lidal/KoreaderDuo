# KOReader Duo

Two e-readers, side by side, showing one book as a two-page spread.

One device is the **master**: it owns the page number and tells the other
what to display. The other is the **slave**: it shows the page it is given
and can pass page turns back. Put them next to each other and you get a left
page and a right page, and a single tap moves both.

```
   ┌───────────────┐   ┌───────────────┐
   │               │   │               │
   │   page 12     │   │   page 13     │
   │   (master)    │◄─►│   (slave)     │
   │               │   │               │
   └───────────────┘   └───────────────┘
        one tap advances the pair to 14 · 15
```

It also does **mirror mode**, where both devices show the same page — handy
for reading along with somebody else.

Nothing about the design stops at two devices: a third one joins as slot 2,
shows the page after the slave's, and a turn moves all three at once.

## Installing

Copy `duo.koplugin` into KOReader's `plugins` directory on **both** devices
and restart KOReader.

```sh
make install KOREADER=/mnt/us/koreader     # jailbroken Kindle
# or just:
cp -r duo.koplugin /path/to/koreader/plugins/
```

The plugin appears under **☰ → Network → Duo (two-device spread)**, in the
reader and in the file manager.

## Pairing

On the device that should hold the **left** page:

1. **Duo → Connect the two devices…**
2. **This is the master (left page)**
3. Note the pairing code and address it shows you.

On the other device:

1. **Duo → Connect the two devices…**
2. **Connect to a master (right page)** — it searches the network and lists
   whatever it finds, so there is normally no address to type.
3. Pick the master, and type the pairing code if asked.

That is it. Open a book on the master and the slave follows: same book, next
page, and one tap moves the pair.

If the search finds nothing (some networks block broadcasts), choose **Type
the address by hand** and enter the address shown on the master.

## Getting the two devices talking

The link is only a byte pipe, so several things can carry it. What a Kindle
will actually give you differs by route.

### Any Wi-Fi network — works today

A home router, or a phone hotspot with no internet on it. Pair as above.
This is the path with the most testing behind it.

### The two devices, direct — no router, no DHCP

For reading somewhere with no network at all. One reader hosts a Wi-Fi link
and the other joins it:

**Duo → Connect the two devices… → No Wi-Fi network? Link the two directly…**

It asks the device what it can do before touching anything, and tells you
plainly when the answer is no. Where it works, the hosting device becomes an
access point if its driver supports one and an ad-hoc network otherwise,
takes `169.254.13.1`, and starts Duo as master. The other device joins,
takes `169.254.13.2`, and connects — the host address is fixed, so there is
no DHCP server needed and no address for anyone to type.

Whether a particular Kindle can do this comes down to its Wi-Fi driver.
Check before you rely on it, over SSH:

```sh
/mnt/us/koreader/plugins/duo.koplugin/tools/duo-direct-link.sh probe
```

That prints the interface, the driver, the modes it supports, and a verdict.
The same script does the work — `host`, `join`, `status`, `restore` — and
takes `--dry-run` on any of them, so you can read the exact commands before
running them. It takes Wi-Fi over while it is up; **restore** or a reboot
gives it back.

### Bluetooth — not on a stock Kindle

Kindles do not run bluez: there is no `rfcomm` and no `hciconfig`. Amazon's
Bluetooth stack is its own, and the community page-turner projects reach it
with a separate userspace stack that speaks HID only. So on a Kindle today
there is no channel for Duo to bind to.

The plugin side is nonetheless finished. A bound RFCOMM channel appears as a
character device, and Duo's serial transport talks straight to one:

```sh
rfcomm bind /dev/rfcomm0 AA:BB:CC:DD:EE:FF 1     # where rfcomm exists
```

Then on both devices: **Duo → Link → Bluetooth serial (RFCOMM)**, set
**Serial device** to the path, and start one as master and the other as
slave. There is no address to enter — the line *is* the connection — and the
pairing code still applies. This is tested end to end against a
pseudo-terminal pair, which is exactly what an RFCOMM channel looks like, so
it will work on any device that exposes one: a serial bridge over Amazon's
stack, another platform, or a plain serial cable.

**Bluetooth PAN** needs nothing special at all: it presents as an ordinary
network, so leave Duo on **Link → Wi-Fi** and pair as usual.

## Settings

| Setting | What it does |
| --- | --- |
| **Layout → Two-page spread** | Master shows page N, slave shows N+1. A turn moves by two. |
| **Layout → Mirror the same page** | Both show the same page. A turn moves by one. |
| **Layout → This device holds the right-hand page** | Swaps the sides: the slave shows the *earlier* page. |
| **Link** | Wi-Fi (any IP network, including Bluetooth PAN), a direct router-free link, or a Bluetooth/serial device. |
| **Page turns from the other device** | Off makes the slave a display only. |
| **Follow the master's book** | When the master opens a book, open it here too. |
| **Start Duo when KOReader starts** | Reconnect on launch in the last role used. |
| **Pairing code** | Shared secret. Empty means any device may connect. |
| **Device name** | What the other device calls this one. |
| **Port** | TCP port, 9970 by default (UDP 9971 for the search). |

Duo also registers two actions for gestures and hardware keys, under
Dispatcher: **Duo: start/stop** and **Duo: resync now**.

## How it works

- **One authority.** The master is the only device that decides what page
  anything shows. A tap on the slave is a *request*: it is sent to the
  master, which moves and then tells everyone where they now stand. The two
  screens cannot drift apart, because only one of them is ever deciding.
- **Page turns are intercepted, not simulated.** Every tap, swipe, gesture
  and hardware button ends up in the reader's `onGotoViewRel`, so Duo wraps
  that one method and multiplies the distance by the number of devices.
  Absolute jumps — table of contents, the go-to dialog, a link — are left
  alone; they change the page, and the spread follows from the resulting
  `PageUpdate`.
- **The connection outlives the plugin.** KOReader destroys and rebuilds a
  plugin instance every time you open a book, so the engine lives in a
  module singleton (`duo/core.lua`) and the plugin instance only attaches a
  binding to the current document. Changing books does not drop the link.
- **Pairing without sending the secret.** The master challenges with a
  nonce; each side answers with `SHA-256(nonce:code)`. The code itself never
  goes on the wire, and a captured proof is useless next time. This keeps
  the wrong device from connecting; it is not protection against somebody
  who controls your network.
- **Wire format** is one line per message — `STATE page=13 pages=300` —
  percent-encoded so titles and paths survive. No JSON library, and legible
  in a packet dump.
- **Polling** happens inside KOReader's own UI loop, which visits registered
  sockets at least every 50ms. Nothing here spawns a thread, blocks a read
  or keeps the CPU awake between page turns.

## Things worth knowing

- **Match the two devices' typography.** Page numbers only line up if both
  paginate the book identically, so use the same font, size, line spacing
  and margins. Duo checks the page counts when it connects and warns you
  once when they differ.
- **Keep Wi-Fi on.** If KOReader is set to drop Wi-Fi after a while, the
  link goes with it. Duo reconnects by itself, but the gap is visible.
- **Sleep.** Duo shuts its sockets down cleanly on suspend and brings them
  back on resume, rather than leaving the other device timing out.
- **Kindle firewall.** Kindles drop incoming connections by default; the
  master opens the port with `iptables` while it runs and closes it again
  when it stops.
- **Battery.** The heartbeat is one small packet every four seconds on an
  already-open socket. Wi-Fi being on at all is the real cost.

## Tests

```sh
make test          # everything, on LuaJIT
make test LUA=lua5.1
```

106 tests, no mocking of the interesting parts:

| Suite | Tests | What it covers |
| --- | --- | --- |
| `protocol_spec` | 23 | Framing, escaping, byte-at-a-time reassembly, SHA-256 vectors, reading our own address out of `ip`/`ifconfig` |
| `link_spec` | 13 | Real loopback sockets: connect, refuse, partial writes, handshake, heartbeats, and a check that the pairing code never appears on the wire |
| `plugin_spec` | 23 | The real `main.lua` under a stub KOReader: menus, page-turn interception, the reader binding |
| `integration_spec` | 22 | **Two and three device processes over real TCP**: spreads, turns from either device, absolute jumps, mirror, reverse, end of book, reconnects, document following, pagination mismatch |
| `serial_spec` | 7 | The same two processes over a pseudo-terminal pair, standing in for a bound RFCOMM channel |
| `directlink_spec` | 13 | Driver capability probing against real `iw` output shapes, and the exact commands each method issues |
| `directlink_net_spec` | 5 | **Two network namespaces on a link-local /16**: the router-free network, with search, connection and spread across it |

Two tools double as documentation, and both print live data:

```sh
luajit tools/duo-demo.lua 3      # run three devices, print what each displayed
luajit tools/duo-menu-dump.lua   # print the menu exactly as the device builds it
```

KOReader itself cannot be built in this environment (it needs a compiled C
core), so `spec/harness` provides the frontend API the plugin uses — the same
module names, signatures and event-propagation rules — and the plugin file is
loaded unmodified, exactly as KOReader's plugin loader does it. The devices in
the integration tests are separate operating-system processes sharing no state
but a socket.

## Layout

```
duo.koplugin/
  main.lua                  KOReader glue: menus, events, page-turn wrapping
  _meta.lua
  duo/
    core.lua                the engine: roles, links, who shows which page
    spread.lua              spread arithmetic, kept dependency-free
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

This plugin is intended to be used with, and distributed under the same terms
as, KOReader itself: **AGPL-3.0**.
