--[[--
The engine behind the plugin.

`main.lua` is the part of Duo that knows about KOReader: menus, events,
widgets. This module is the part that knows about *pairing*: it owns the
sockets, decides which page each device should be showing, and survives
things the plugin instance does not.

That last point matters. KOReader throws away and rebuilds every plugin
instance each time a document is opened or closed, so a connection owned by
the plugin instance would die every time the user changed books. This module
is a singleton held by `package.loaded`, so the link stays up across
document switches; the plugin instance simply attaches and detaches a
"reader binding" as documents come and go.

The reader binding is the only way this module touches the document, which
also means the whole engine can be driven by a test harness.

@module duo.core
--]]--

local Discovery = require("duo/discovery")
local Link = require("duo/link")
local NetUtil = require("duo/netutil")
local Protocol = require("duo/protocol")
local SerialTransport = require("duo/transport_serial")
local Spread = require("duo/spread")
local TcpTransport = require("duo/transport_tcp")
local Util = require("duo/util")

local Core = {
    role = "off",              -- "off" | "leader" | "follower"
    links = {},                -- leader: one per follower. follower: at most one.
    reader = nil,              -- reader binding, or nil outside a document
    settings = nil,
    hooks = nil,
    server = nil,
    responder = nil,
    connector = nil,
    scanner = nil,
    instance_id = nil,
    last_error = nil,
    reconnect_at = nil,
    reconnect_delay = 1,
    applying_remote = false,   -- guards against echoing a remote page change
    warned_pagination = false,
}

Core.ROLE_OFF = "off"
Core.ROLE_LEADER = "leader"
Core.ROLE_FOLLOWER = "follower"

--[[--
Reconnection backoff, in seconds.

Backing off protects a server from a crowd. There is no crowd here: one
device is dialling exactly one other, on a network with nothing else on it,
and a fifteen-second wait between attempts protected nothing while costing
the pair the time they were most obviously broken.
--]]--
local RECONNECT_MIN = 1
local RECONNECT_MAX = 4

--- How long a book may go without a byte before it is written off, in
--- seconds. Generous: a slow link is not the same as a dead one.
local BOOK_SILENCE = 30

--[[--
A transfer past this is worth a word before it starts, in bytes.

Not a limit. The link between two readers carries a few hundred kilobytes a
second on a good day, so a hundred megabytes is somewhere around ten
minutes of watching a progress figure -- which is fine if you were told, and
maddening if you were not.
--]]--
local BIG_TRANSFER = 100 * 1024 * 1024

--- How much of a book has to arrive between one word about it and the next.
local PROGRESS_STEP = 0.1

--[[--
Coming back after a sleep, in seconds and attempts.

Waking is gradual: the screen is back long before the radio is, and a
device that binds a socket the instant it opens its eyes binds nothing.
Retrying for a couple of minutes covers a Wi-Fi network reassociating, a
link-local cell re-forming, and a peer that woke up later than this device
did. Past that the network really is gone and saying so beats retrying into
a flat battery.
--]]--
local RESUME_RETRY = 4
local RESUME_MAX_ATTEMPTS = 30

--[[--
How long after waking to check on a link Duo built itself, in seconds.

Long enough for the radio to finish coming back — checking the instant the
screen lights up reports whatever the driver happens to be doing mid-resume
— and short enough that nobody is left staring at two devices that have
stopped talking.
--]]--
local LINK_CHECK_DELAY = 2

--[[--
Healing a link Duo built, without waiting to be told to, in seconds.

The wake-up notification is a nice-to-have and not something to depend on:
it travels through the reader's power daemon, its screensaver handling and
an event broadcast, and if any of that does not fire on a particular
firmware then nothing ever checks the network again. So the check also runs
simply because the pair has been apart for a while. It costs one status
call, and only rebuilds when the link really has gone.
--]]--
local LINK_HEAL_AFTER = 2
local LINK_HEAL_EVERY = 20

--[[--
How long to leave a pair alone that has never managed to connect at all.

A link that has worked and stopped is broken and worth rebuilding at once.
One that has never worked is usually somebody midway through setting it up
— reading a code off the other screen, typing it in — and tearing the
network down under them would be its own kind of unhelpful.
--]]--
local LINK_HEAL_FIRST = 30

--[[--
How close together two sleeps count as one decision, in seconds.

Both readers get put down at once often enough that it is the ordinary
case, not an edge one, and each tells the other. Pressing a power button
that has just been pressed wakes the device back up, so a message that
arrives inside this window is treated as the other person having done the
same thing at the same moment rather than as an instruction.
--]]--
--[[--
How long the two devices are given to agree on a book's length after a
layout change, before the difference is treated as real.

Generous, because relaying out a long book is not quick and real rendering
engines finish a little after the event that started them returns. Declared
up here with the other constants because it is read from two very different
places -- deciding whether a page number can be trusted, and deciding
whether a mismatch is worth complaining about -- and a local declared
between them is visible to only one of them.
--]]--
local PAGINATION_SETTLE = 8

--[[--
How long a device is given to say what became of a book it was told to
open, and how many times it is told again before the pair gives up.

Opening a book on an e-reader is slow and very visible, so the wait is
generous, and a device that says it is working on it pushes the wait back
rather than being asked again. What this catches is silence -- the message
that arrived while the other device was between documents, or rebuilding
its plugin, or otherwise in no state to act on it -- which is how the two
ended up in different books with nothing to put them right.
--]]--
local DOC_ACK_WAIT = 8
local DOC_ACK_TRIES = 3

local SLEEP_RACE = 10

--[[--
How long the pair stays up after the last page turn, in seconds.

This is the one number that decides when two readers doze off together, and
it has to be longer than reading a page takes. Too short and they nod off
between turns — and since a sleeping follower cannot be woken by the leader,
that would mean a tap turning one screen and not the other. Five minutes is
comfortably longer than a page and short enough to save something real when
the book goes down.
--]]--
local IDLE_HOLD = 300

Core.TRANSPORT_TCP = "tcp"
Core.TRANSPORT_SERIAL = "serial"

local DEFAULTS = {
    transport = "tcp",
    serial_device = "/dev/rfcomm0",
    serial_baud = 115200,
    port = 9970,
    discovery_port = Discovery.PORT,
    token = "",
    peer_host = "",
    peer_port = 9970,
    mode = Spread.SPREAD,
    reverse = false,
    follower_can_turn = true,
    follow_document = true,
    match_typography = true,
    share_browser = true,
    sleep_together = true,
    sync_frontlight = true,
    sync_books = true,
    sync_library = true,
    --[[
    Off by default, and on probation.

    Filling the shelf with stand-ins and fetching each book on the first tap
    puts a transfer in the way of opening a book, which is the moment a
    reader can least afford one: the link has to be up, the leader has to
    still be holding the file, and the wait lands between the tap and the
    page. It reads well and behaves badly, and the honest fix may be to take
    it out rather than to keep patching around it. Until that is decided it
    stays, switched off, for whoever wants it.
    ]]
    covers_first = false,
    --[[
    The one folder Duo copies books to and from.

    Anchored rather than followed. Duo used to sync whichever folder the
    file browser happened to be showing, which meant what got copied
    depended on where somebody had wandered to, and a device reading a book
    -- with no browser at all -- had nothing to answer with. A folder named
    once is a folder both devices can agree on, whatever either of them is
    looking at.
    ]]
    shared_folder = "/books",
    -- Off, and deliberately not shared: a log is about this device, and
    -- switching one on should never quietly switch on the other's.
    debug_log = false,
    -- Empty means "wherever this device keeps its books", worked out at the
    -- time. Not shared: it describes this device's disk, and the two rarely
    -- have the same one.
    book_dir = "",
    device_name = "",
    autostart = false,
    autostart_role = "off",
}

--------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------

--[[--
Connects the engine to its surroundings. Called by every plugin instance;
only the first call takes effect for a given KOReader run.

@tparam table options
    settings  persisted settings table (mutated in place)
    hooks     log / notify / alert / save / onChanged callbacks
--]]--
--[[--
Brings a settings file written by an older version up to date.

The two roles used to be called master and slave, and both the name of the
setting and the value saved in it changed with them. A file on a device
that has been running Duo for a while still says the old thing, and a pair
that silently stopped autostarting — or quietly stopped taking page turns
from the other device — after an update would be a poor way to find out.
--]]--
local RENAMED_SETTINGS = { slave_can_turn = "follower_can_turn" }
local RENAMED_ROLES = { master = "leader", slave = "follower" }

local function migrate(settings)
    for old_key, new_key in pairs(RENAMED_SETTINGS) do
        if settings[old_key] ~= nil and settings[new_key] == nil then
            settings[new_key] = settings[old_key]
        end
        settings[old_key] = nil
    end
    local role = RENAMED_ROLES[settings.autostart_role]
    if role then settings.autostart_role = role end
    return settings
end

function Core:configure(options)
    self.hooks = options.hooks or self.hooks or {}
    if not self.settings then
        self.settings = migrate(options.settings or {})
        for key, value in pairs(DEFAULTS) do
            if self.settings[key] == nil then
                self.settings[key] = value
            end
        end
        self.instance_id = Util.randomHex(6)
    end
    return self
end

function Core:log(...)
    if self.hooks and self.hooks.log then self.hooks.log(...) end
end

function Core:notify(text)
    self:log("notify:", text)
    if self.hooks and self.hooks.notify then self.hooks.notify(text) end
end

function Core:alert(text)
    self:log("alert:", text)
    if self.hooks and self.hooks.alert then self.hooks.alert(text) end
end

function Core:save()
    if self.hooks and self.hooks.save then self.hooks.save(self.settings) end
end

--- Tells the UI that the status line or menu needs redrawing.
function Core:changed()
    if self.hooks and self.hooks.onChanged then self.hooks.onChanged(self) end
end

function Core:get(key)
    local value = self.settings and self.settings[key]
    if value == nil then return DEFAULTS[key] end
    return value
end

--[[--
The settings that describe how the pair behaves, as opposed to what this
particular device is.

Everything here is a decision about the two devices together — whether a
turn on the follower counts, whether the book list is shared, how big a
library may be — and a pair that disagrees about one of them misbehaves in
a way that looks like a bug rather than a setting. Switching page turns off
on one device silently disabled them, and which device you had to look at
differed from feature to feature.

Deliberately not in the list: anything that identifies this device or says
how to reach the other one. A port, a pairing code, a peer address or a
device name are exactly the things that must *not* be levelled, and pushing
a transport across the link would be a fine way to hang up on yourself.
--]]--
local SHARED_SETTINGS = {
    "mode",
    "reverse",
    "follower_can_turn",
    "follow_document",
    "match_typography",
    "share_browser",
    "sleep_together",
    "sync_books",
    "sync_library",
    "covers_first",
    -- Shared, so the pair cannot disagree about what is being copied.
    "shared_folder",
    "sync_frontlight",
}

local IS_SHARED = {}
for _, key in ipairs(SHARED_SETTINGS) do IS_SHARED[key] = true end

function Core:set(key, value)
    local changed = self.settings[key] ~= value
    self.settings[key] = value
    self:save()
    self:changed()
    -- Told, rather than discovered by polling: every route into a setting —
    -- the menu, a gesture, a profile — comes through here.
    if changed and IS_SHARED[key] and not self.applying_settings then
        self:pushSettings(key)
    end
end

--- This device's half of the shared configuration, ready for the wire.
function Core:settingsPayload()
    local payload = {}
    for _, key in ipairs(SHARED_SETTINGS) do
        local value = self:get(key)
        if type(value) == "boolean" then
            payload[key] = value and 1 or 0
        else
            payload[key] = value
        end
    end
    return payload
end

function Core:sendSettingsTo(link)
    link:send(Protocol.CONF, self:settingsPayload())
end

--[[--
Shares a setting somebody just changed on this device.

The leader tells everyone. A follower can only ask: it hands the change to the
leader, which applies it and passes it on, so there is one account of what
the pair is doing rather than two devices talking over each other.
--]]--
function Core:pushSettings(reason)
    if not self:isActive() or not self:isConnected() then return end
    self:log("sharing settings:", reason)
    for _, link in ipairs(self:getReadyLinks()) do
        self:sendSettingsTo(link)
    end
end

--[[--
Takes the shared settings from the other device.

On connect this arrives from the leader and the leader wins, which is what
makes it a tiebreaker rather than a race: two devices that were configured
differently end up agreeing, and agreeing on the one that is leading.
--]]--
function Core:applySettings(msg, from_link)
    local adopted = {}
    self.applying_settings = true
    for _, key in ipairs(SHARED_SETTINGS) do
        local raw = msg[key]
        if raw ~= nil then
            local current = self:get(key)
            local value
            if type(current) == "boolean" then
                value = raw == "1"
            elseif type(current) == "number" then
                value = tonumber(raw)
            else
                value = raw
            end
            if value ~= nil and value ~= current then
                self.settings[key] = value
                adopted[#adopted+1] = key
            end
        end
    end
    self.applying_settings = false

    if #adopted > 0 then
        self:save()
        self:changed()
        self:log("adopted settings:", table.concat(adopted, ", "))
        if self:isLeader() then
            -- A change made on a follower has to reach the other followers, and
            -- the leader is the only device that talks to all of them.
            self:broadcastState()
            for _, link in ipairs(self:getReadyLinks()) do
                if link ~= from_link then self:sendSettingsTo(link) end
            end
        end
    end
end

--- The pairing token, generated on first use so pairing is secure by default.
function Core:ensureToken()
    local token = Util.normalizeToken(self:get("token"))
    if token == "" then
        token = Util.newPairingToken(6)
        self.settings.token = token
        self:save()
    end
    return token
end

function Core:getDeviceName()
    local name = self:get("device_name")
    if name and name ~= "" then return name end
    if self.hooks and self.hooks.defaultDeviceName then
        return self.hooks.defaultDeviceName()
    end
    return "KOReader"
end

--------------------------------------------------------------------------
-- Reader binding
--------------------------------------------------------------------------

--[[--
Attaches the currently open document.

@tparam table binding
    getPage()        current page number
    getPageCount()   pages in this document
    gotoPage(page)   jump to an absolute page
    turnRelative(n)  turn n pages, exactly as the reader normally would
    getDocument()    { file=, title=, digest= }
    openDocument(f)  open another file
--]]--
function Core:attachReader(binding)
    self.reader = binding
    self.warned_pagination = false
    self.warned_short_book = false
    self.opening_file = nil -- whatever we were opening has now arrived
    -- A different document has its own typography; nothing carries over.
    self.typography_snapshot = nil
    self.typography_checked_at = nil
    self.typography_backup = nil
    self:changed()
    if not self:isActive() then return end
    if self:isLeader() then
        self:broadcastDocument()
        self:pushTypography("document opened")
        self:broadcastState()
    else
        local link = self:getReadyLinks()[1]
        if link then
            -- We may have been reopened on a different book; ask where we
            -- should be rather than sitting on whatever page we landed on.
            link:send(Protocol.SYNC, {})
        end
        -- And the book is now really open, which is the answer the leader
        -- has been waiting for rather than the promise it got earlier.
        local document = binding and binding.getDocument and binding.getDocument()
        if document and document.file then
            self:sendDocumentAck("open", document.file)
        end
    end
end

--- Drops the binding when its document goes away.
-- The `binding` argument guards against a stale plugin instance tearing down
-- the binding that a newer one has already installed: when KOReader switches
-- documents the old instance is closed after the new one exists, and
-- unhooking then would silently stop syncing.
function Core:detachReader(binding)
    if binding and self.reader and self.reader ~= binding then return end
    self.reader = nil
    -- Page numbers mean nothing once the book they counted is gone.
    self.assigned_page = nil
    self.assigned_pages = nil
    self.pending_page = nil
    self.layout_differed_at = nil
    self.last_seen_pages = nil
    self.relayout_at = nil
    self:changed()
end

function Core:hasReader()
    return self.reader ~= nil
end

--------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------

function Core:isActive()
    return self.role ~= Core.ROLE_OFF
end

function Core:isLeader()
    return self.role == Core.ROLE_LEADER
end

function Core:isFollower()
    return self.role == Core.ROLE_FOLLOWER
end

--[[--
Decides whether this device should stay awake, and says so.

Duo has no timer of its own: it is polled by the UI loop, and a reader in
standby stops polling. Holding that off costs battery, so it is held only
where it buys something.

A **follower** holds it while the leader is awake. It has nobody tapping it
to wake it up, and a follower asleep while the other device turns pages is
simply wrong.

A **leader** does not, because someone is holding it: any tap wakes it, and
holding standby off there would also stop KOReader ever telling us the
reader has gone idle — which is the signal the followers need. When it does
go idle it says so, and the followers go with it.

Either way a transfer in flight holds it, on both devices: a book that
stops halfway is worse than a minute of battery.

Balanced by construction — a second hold, or a release with nothing held,
does nothing, because KOReader counts these and asserts on a mismatch.
--]]--
function Core:shouldStayAwake()
    if not self:isActive() then return false end
    -- Bytes in flight, at either end.
    if self.book_sender or self.book_receiver or self.library then return true end
    if self:isLeader() then
        return Util.now() - (self.last_activity or 0) < IDLE_HOLD
    end
    return self:isConnected() and not self.peer_napping
end

--- Somebody is reading: whichever device the turn came from, the leader is
--- the one that decides how long the pair stays up.
function Core:noteActivity()
    self.last_activity = Util.now()
    self:updateAwake()
end

--- Brings the standby hold in line with what this device now needs.
function Core:updateAwake()
    self:setAwake(self:shouldStayAwake())
end

function Core:setAwake(awake)
    if awake == (self.awake_held or false) then return end
    if not self.hooks or not self.hooks.setAwake then return end
    local ok, err = pcall(self.hooks.setAwake, awake)
    if not ok then
        self:log("could not change the standby hold:", tostring(err))
        return
    end
    self.awake_held = awake
end

--- Links that finished the handshake.
function Core:getReadyLinks()
    local ready = {}
    for _, link in ipairs(self.links) do
        if link:isReady() then ready[#ready+1] = link end
    end
    return ready
end

function Core:isConnected()
    return #self:getReadyLinks() > 0
end

function Core:followerCount()
    if self:isLeader() then return #self:getReadyLinks() end
    return self:isConnected() and 1 or 0
end

--- How many pages one turn should move the leader.
function Core:getStep()
    if not self:isActive() or not self:isConnected() then return 1 end
    return Spread.stepFor(self:get("mode"), self:followerCount())
end

function Core:getSpreadOptions()
    return {
        mode = self:get("mode"),
        reverse = self:get("reverse"),
        page_count = self.reader and self.reader.getPageCount() or nil,
        pages_per_view = self.reader and self.reader.getPagesPerView
            and self.reader.getPagesPerView() or 1,
    }
end

--------------------------------------------------------------------------
-- Starting and stopping
--------------------------------------------------------------------------

--[[--
Starts Duo in the given role.

@string role Core.ROLE_LEADER or Core.ROLE_FOLLOWER
@tparam[opt] table options host and port for a follower
@treturn boolean success
--]]--
--- True when Duo is talking over a serial device (a Bluetooth RFCOMM link,
-- typically) rather than over the network.
function Core:usesSerial()
    return self:get("transport") == Core.TRANSPORT_SERIAL
end

--[[--
Brings up the serial link.

There is no dialling on a serial line: both devices open the same channel
and the leader starts talking. Whoever gets there first waits for the other.
--]]--
function Core:openSerialLink()
    self.reconnect_at = nil
    local path = self:get("serial_device")
    local stream, err = SerialTransport.open(path, { baud = self:get("serial_baud") })
    if not stream then
        self.last_error = err
        self:scheduleReconnect()
        return false
    end
    self:adoptStream(stream, self:isLeader())
    self:changed()
    return true
end

function Core:start(role, options)
    options = options or {}
    role = RENAMED_ROLES[role] or role
    self:stop("restarting")

    self:ensureToken()
    self.last_error = nil
    self.reconnect_delay = RECONNECT_MIN
    -- Starting is something an awake device does, so whatever this was
    -- following the other one into is over — including its own last word
    -- on the subject, which would otherwise go on excusing it from the
    -- next one.
    self.sleeping_for_peer = false
    self.sleep_announced_at = nil

    if self:usesSerial() then
        if role ~= Core.ROLE_LEADER and role ~= Core.ROLE_FOLLOWER then return false end
        if not SerialTransport.isAvailable() then
            self:alert("This build of KOReader cannot use a serial link.")
            return false
        end
        self.role = role
        self.settings.autostart_role = role
        self:save()
        if not self:openSerialLink() then
            self:alert(("Could not open %s.\n%s\n\nBind the Bluetooth channel first, for example:\n  rfcomm bind %s <address> 1"):format(
                self:get("serial_device"), tostring(self.last_error), self:get("serial_device")))
            self:stop("serial device unavailable")
            return false
        end
        self.last_activity = Util.now()
        self:updateAwake()
        self:changed()
        return true
    end

    if role == Core.ROLE_LEADER then
        local port = self:get("port")
        local server, err = TcpTransport.listen(port)
        if not server then
            self.last_error = err
            if not options.quiet then
                self:alert(("Could not listen on port %d.\n%s"):format(port, tostring(err)))
            end
            self:changed()
            return false
        end
        self.server = server
        -- Opened only once we know we are really listening, so a failed
        -- start does not leave firewall rules behind.
        if self.hooks and self.hooks.openFirewall then
            self.hooks.openFirewall(port)
            self.hooks.openFirewall(self:get("discovery_port"))
        end
        self.responder = Discovery.newResponder{
            port = self:get("discovery_port"),
            describe = function()
                local document = self.reader and self.reader.getDocument() or nil
                return {
                    id = self.instance_id,
                    name = self:getDeviceName(),
                    port = self:get("port"),
                    book = document and document.title or "",
                    locked = Util.normalizeToken(self:get("token")) ~= "",
                }
            end,
        }
        self.role = Core.ROLE_LEADER
        self:log("started as leader on port", port)
    elseif role == Core.ROLE_FOLLOWER then
        local host = tostring(options.host or self:get("peer_host") or ""):gsub("%s", "")
        local port = options.port or self:get("peer_port")
        if host == "" then
            if not options.quiet then
                self:alert("No leader address yet. Search for one, or type its address.")
            end
            return false
        end
        -- Refuse an address we cannot reach *before* saving it, so a typo
        -- does not become a reconnect loop against a host that never existed.
        local resolved = NetUtil.resolve(host)
        if not resolved then
            self.last_error = ("no device answers to %s"):format(host)
            if not options.quiet then
                self:alert(("No device answers to \"%s\".\n\nCheck the address shown on the leader."):format(host))
            end
            return false
        end
        host = resolved
        self.settings.peer_host = host
        self.settings.peer_port = port
        self:save()
        self.role = Core.ROLE_FOLLOWER
        self:beginConnect()
        self:log("started as follower, dialing", host, port)
    else
        return false
    end

    self.settings.autostart_role = self.role
    self.last_activity = Util.now()
    self:updateAwake()
    self:save()
    self:changed()
    return true
end

--- Stops everything and lets the peer know when possible.
function Core:stop(reason)
    for _, link in ipairs(self.links) do
        link:close(reason or "stopped", true)
    end
    self.links = {}
    if self.server then
        self.server:close()
        self.server = nil
        if self.hooks and self.hooks.closeFirewall then
            self.hooks.closeFirewall(self:get("port"))
            self.hooks.closeFirewall(self:get("discovery_port"))
        end
    end
    if self.responder then
        self.responder:close()
        self.responder = nil
    end
    if self.connector then
        self.connector:cancel()
        self.connector = nil
    end
    self.reconnect_at = nil
    -- Stopping is a decision, and it outranks a sleep this device has not
    -- finished waking from.
    self.paused_role = nil
    --[[
    And what the layout and the light looked like last time is forgotten.

    Both are remembered so a change made here can be told apart from the
    state this device has been sitting in. Kept across a disconnection, the
    memory says the wrong thing: whatever drifted while the two were apart
    reads as a change somebody just made, and gets pushed the moment the
    link comes back -- from a device that is about to be told what the
    settings are anyway.
    ]]
    self.typography_snapshot = nil
    self.frontlight_snapshot = nil
    -- A fresh start is a fair reason to try a book that would not come.
    self.library_failed = nil
    self:dropTransfers()
    self.peer_napping = false
    self:setAwake(false)
    if self.role ~= Core.ROLE_OFF then
        self.role = Core.ROLE_OFF
        self.settings.autostart_role = Core.ROLE_OFF
        self:save()
        self:changed()
    end
end

--[[--
Throws away anything half-transferred.

There is no link left to finish it on, and a book left on the asking list
would block every book after it: only one is ever in flight, and nothing
would come to clear this one.
--]]--
function Core:dropTransfers()
    if self.book_receiver then
        self.book_receiver:abort()
        self.book_receiver = nil
    end
    if self.book_sender then
        self.book_sender.sender:close()
        self:clearTemporary(self.book_sender)
        self.book_sender = nil
    end
    self.book_request = nil
    self.library = nil
end

function Core:beginConnect()
    self.connector = nil
    self.reconnect_at = nil
    local host, port = self:get("peer_host"), self:get("peer_port")
    local connector, err = TcpTransport.connect(host, port, 8)
    if not connector then
        self.last_error = err
        self:scheduleReconnect()
        return
    end
    self.connector = connector
    self:changed()
end

function Core:scheduleReconnect()
    self.connector = nil
    self.reconnect_at = Util.now() + self.reconnect_delay
    self.reconnect_delay = math.min(self.reconnect_delay * 2, RECONNECT_MAX)
    self:changed()
end

--------------------------------------------------------------------------
-- The pump
--------------------------------------------------------------------------

--[[--
Starts looking for a leader on the network.

Scanning happens while Duo is still off, which is exactly when the user is
standing there waiting, so it is driven from the same poll loop as
everything else rather than blocking the UI for four seconds.

@tparam function on_done called with the array of offers found
--]]--
function Core:startScan(on_done)
    if self.scanner then
        self.scanner:close()
    end
    local scanner, err = Discovery.newScanner{
        port = self:get("discovery_port"),
        duration = 4,
    }
    if not scanner then
        self:alert(("Could not search the network: %s"):format(tostring(err)))
        return false
    end
    self.scanner = scanner
    self.scan_callback = on_done
    return true
end

function Core:isScanning()
    return self.scanner ~= nil
end

function Core:pollScanner()
    if not self.scanner then return end
    self.scanner:poll()
    if not self.scanner:isDone() then return end
    local results = self.scanner:getResults()
    local callback = self.scan_callback
    self.scanner:close()
    self.scanner = nil
    self.scan_callback = nil
    if callback then callback(results) end
end

--- Drives every socket. Called from KOReader's UI loop, ~20 times a second.
function Core:poll()
    self:pollScanner() -- runs even while Duo is off: this is how pairing starts
    self:checkResume() -- also while off: this is how a sleep is recovered from
    self:checkLink()   -- and this is how the network under it is
    if self.role == Core.ROLE_OFF then return end

    if self.responder then self.responder:poll() end

    if self:usesSerial() then
        -- One line, one link: reopen it when it has gone away.
        if #self.links == 0 and self.reconnect_at and Util.now() >= self.reconnect_at then
            self:openSerialLink()
        end
    else
        if self:isLeader() and self.server then
            while true do
                local stream = self.server:accept()
                if not stream then break end
                self:adoptStream(stream, true)
            end
        end

        if self:isFollower() then
            if self.connector then
                local result, err = self.connector:poll()
                if result then
                    self.connector = nil
                    self:adoptStream(result, false)
                elseif result == false then
                    self.last_error = err
                    self:scheduleReconnect()
                end
            elseif self.reconnect_at and Util.now() >= self.reconnect_at then
                self:beginConnect()
            end
        end
    end

    for index = #self.links, 1, -1 do
        local link = self.links[index]
        link:poll()
        if link:isClosed() then
            table.remove(self.links, index)
        end
    end

    -- Watching the settings rather than listening for a change event: the
    -- user can reach these from the config dialog, a gesture, a profile or
    -- another plugin, and a poll every second and a half catches all of it.
    self:checkTypography()
    self:checkFrontlight()
    self:checkLinkHealth()
    self:checkDocumentAcks()
    self:checkLibrary()
    -- A page the leader sent while this device was still relaying the book
    -- out. The leader only broadcasts when something changes, so a page held
    -- back has to be picked up here or not at all.
    self:applyPendingPage()
    self:checkBrowser()
    self:pumpBookSender()
    self:checkBookRequest()
    self:reportTransferProgress()
    -- Connections come and go and transfers start and finish in all of the
    -- above, and each changes whether this device can afford to doze.
    self:updateAwake()
end

--[[--
Gives up on a book that stopped arriving.

Only one book is asked for at a time, so a request that never gets an
answer — the other device restarted, the reply went missing, a send failed
somewhere it could not be reported — would otherwise sit there for good,
and no book could ever be fetched again. Waiting is right; waiting forever
is not.
--]]--
function Core:checkBookRequest()
    local request = self.book_request
    if not request then return end
    -- Anything set without a clock reading starts its clock here, rather
    -- than counting from the epoch and being written off at once.
    request.started = request.started or Util.now()
    local since = Util.now() - (request.progress_at or request.started)
    if since < BOOK_SILENCE then return end

    local was_library = request.library and not request.open_when_done
    self.book_request = nil
    if self.book_receiver then
        self.book_receiver:abort()
        self.book_receiver = nil
    end
    self:log("gave up on", request.title or request.file, "after", math.floor(since), "seconds of silence")
    self:changed()
    if was_library then
        -- One book going quiet is not a reason to abandon the rest.
        self:noteLibraryFailure(request, "it stopped arriving")
        self:pumpLibrary()
        return
    end
    self:alert(("Duo could not fetch %s: the other device stopped sending."):format(
        request.title ~= "" and request.title or "the book"))
end

--- Wraps a freshly opened stream in an authenticated link.
-- @tparam table stream anything with send / receive / close
-- @bool is_leader true when this device drives the handshake
function Core:adoptStream(stream, is_leader)
    local link
    link = Link.new{
        stream = stream,
        is_leader = is_leader,
        token = self:get("token"),
        name = self:getDeviceName(),
        slot = is_leader and self:nextFreeSlot() or 1,
        on_message = function(_, msg) self:handleMessage(link, msg) end,
        on_ready = function() self:onLinkReady(link) end,
        on_close = function(_, reason) self:onLinkClosed(link, reason) end,
    }
    self.links[#self.links+1] = link
    return link
end

--- Lowest follower index not currently taken, so a reconnecting device lands
-- back on the page it had rather than being pushed to the end of the spread.
function Core:nextFreeSlot()
    local taken = {}
    for _, link in ipairs(self.links) do
        taken[link.slot] = true
    end
    local slot = 1
    while taken[slot] do slot = slot + 1 end
    return slot
end

function Core:onLinkReady(link)
    self.reconnect_delay = RECONNECT_MIN
    self.last_error = nil
    self:notify(("Duo: connected to %s"):format(link.peer_name or "peer"))
    if self:isLeader() then
        -- The leader pushes; the follower does not need to ask. Asking as well
        -- would have it told twice, and a second DOC can mean opening the
        -- same book twice.
        -- Settings first of all: they decide whether the rest of this is
        -- wanted at all, and the leader is the tiebreaker when the two
        -- devices were configured differently.
        self:sendSettingsTo(link)
        self:sendDocumentTo(link)
        -- Typography before the page: the layout decides what page numbers
        -- even mean, so sending the page first would only move it twice.
        self:sendTypographyTo(link)
        self:sendFrontlightTo(link)
        self:sendStateTo(link)
        self:broadcastBrowser()
    else
        --[[
        A follower takes its bearings from what it is holding right now.

        Not from what it was holding before the link went away: the leader
        is about to say what the layout and the light should be, and a
        difference against a stale memory is not a change anybody made. Left
        in place it is pushed at the leader the instant the link is ready,
        which is a follower overruling the device that is supposed to be
        the tiebreaker -- and whether it won came down to which message
        happened to arrive first.
        ]]
        if self.reader and self.reader.getTypography then
            self.typography_snapshot = self.reader.getTypography()
        end
        self.frontlight_snapshot = self:frontlightSnapshot()
        if self.browser and not self.reader then
            -- A follower in the file manager. The leader pushes the listing
            -- from its side too, but only when it has one to push: it may be
            -- deep in a book, or between file managers, and asking costs a
            -- line and settles it either way.
            link:send(Protocol.SYNC, {})
        end
    end
    self:changed()
end

function Core:onLinkClosed(link, reason)
    self:log("link closed:", reason)
    if self:isActive() then
        self:notify(("Duo: %s"):format(reason or "disconnected"))
    end
    -- Whoever dialled is the one who redials. On a serial line neither side
    -- dialled, so both keep the channel open and wait for the other.
    if self:isActive() and (self:isFollower() or self:usesSerial()) then
        self:scheduleReconnect()
    end
    self:changed()
end

--------------------------------------------------------------------------
-- Talking about pages
--------------------------------------------------------------------------

function Core:sendStateTo(link)
    if not self.reader then return end
    local leader_page = self.reader.getPage()
    if not leader_page then return end
    local options = self:getSpreadOptions()
    local page, clamped = Spread.pageForSlot(leader_page, link.slot, options)
    link:send(Protocol.STATE, {
        page = page,
        leader_page = leader_page,
        pages = self.reader.getPageCount() or 0,
        slot = link.slot,
        mode = options.mode,
        beyond = clamped,
        -- What this device's layout looks like right now, so a page count
        -- that disagrees can be told from settings that disagree.
        typo = self:typographySignature(),
    })
end

function Core:broadcastState()
    if not self:isLeader() then return end
    self:noteActivity()
    for _, link in ipairs(self:getReadyLinks()) do
        self:sendStateTo(link)
    end
    self:changed()
end

function Core:sendDocumentTo(link)
    if not self.reader then return end
    local document = self.reader.getDocument()
    if not document or not document.file then return end
    -- Noted on the link itself, so it goes away when the link does.
    link.doc_pending = {
        file = document.file,
        sent_at = Util.now(),
        attempts = 1,
    }
    link:send(Protocol.DOC, {
        file = document.file,
        title = document.title or "",
        digest = document.digest or "",
        pages = self.reader.getPageCount() or 0,
        typo = self:typographySignature(),
    })
end

function Core:broadcastDocument()
    if not self:isLeader() then return end
    for _, link in ipairs(self:getReadyLinks()) do
        self:sendDocumentTo(link)
    end
end

--------------------------------------------------------------------------
-- Page turns
--------------------------------------------------------------------------

--[[--
Handles a relative page turn the user made on this device.

On the leader this moves the whole spread: one turn advances by as many
pages as there are devices. On a connected follower the turn is forwarded to
the leader instead of being applied locally, so the two screens can never
drift apart — the leader remains the only thing that decides what is shown.

@number diff pages to turn, normally 1 or -1
@treturn boolean true when Duo handled it and the reader should not
--]]--
function Core:handleRelativeTurn(diff)
    if not self:isActive() or not self:isConnected() then return false end
    if self:isLeader() then
        self:applyRelativeTurn(diff)
        return true
    end
    if not self:get("follower_can_turn") then
        -- Reading on the follower should not move the pair: ignore the tap
        -- rather than letting this screen drift out of the spread.
        return true
    end
    local link = self:getReadyLinks()[1]
    if not link then return false end
    link:send(Protocol.TURN, { dir = diff })
    return true
end

--[[--
Moves the leader by `diff` spreads.

The page change is broadcast by whatever the reader reports afterwards, via
onPageChanged.

A turn that would push the far end of the spread past the end of the book
is refused rather than clamped. Clamping is what the reader does on its
own, and on a short book it did the wrong thing twice over: the leader's
page was pulled back to the last one, the follower's was pulled back to the
*same* last one, and a pair that had been showing two different pages ended
up showing one page twice — from a tap that should have done nothing.

@treturn boolean true when the pair moved
--]]--
function Core:applyRelativeTurn(diff)
    if not self.reader then return false end
    local step = self:getStep()
    local options = self:getSpreadOptions()
    local page = self.reader.getPage()
    local ceiling = Spread.leaderCeiling(options.page_count, self:followerCount(), options)
    if page and ceiling then
        local floor = Spread.leaderFloor(options.page_count, self:followerCount(), options)
        floor = math.max(floor, 1)
        ceiling = math.max(ceiling, 1)
        if (diff > 0 and page >= ceiling) or (diff < 0 and page <= floor) then
            self:log("not turning: the spread already reaches the end of the book")
            return false
        end
        local wanted = page + diff * step
        if wanted > ceiling or wanted < floor then
            -- Part of a step still fits, so the last turn of a book lands
            -- on the last whole spread rather than being refused.
            self.reader.turnRelative(Util.clamp(wanted, floor, ceiling) - page)
            return true
        end
    end
    self.reader.turnRelative(diff * step)
    return true
end

--- Called by the plugin whenever this device's page changed, for any reason.
function Core:onPageChanged(page)
    if not self:isActive() then return end
    if self.applying_remote then return end
    if self:isLeader() then
        self:broadcastState()
    else
        self:reportJump(page)
        self:changed()
    end
end

--[[--
Tells the leader this device was moved somewhere it was not sent.

A page turn on a follower is forwarded before it happens and never moves
this screen on its own, so any page this device lands on that is not the
one it was told to show is a jump the user made -- a tapped link, an entry
in the table of contents, a bookmark, the slider. All of those used to go
nowhere: this device moved, the leader stayed where it was, and the next
page turn dragged this one back to where the link had been tapped.

The page this device wants to be showing is what is sent, not the page the
leader should hold. Where the leader has to sit for this device to show a
given page depends on the shape of the spread, and that is the leader's
business to work out.
--]]--
function Core:reportJump(page)
    if not page or not self:isConnected() then return end
    if not self.reader then return end
    -- The same permission as turning a page: a follower kept as a display
    -- should not move the pair by being tapped.
    if not self:get("follower_can_turn") then return end

    --[[
    A relayout renumbers every page in the book without anybody going
    anywhere. Change the font size and crengine keeps the reader where they
    were and calls it a different number -- which looks exactly like a jump
    from here, and reporting it would drag the whole pair somewhere nobody
    asked to be.

    Watching for the page count to move is not enough on its own, and two
    real readers showed why: crengine does not relayout in one step. It
    reports a new length, moves the reader to match, and then goes on
    settling -- so the page moves again a few seconds later with the count
    already steady, which looks like a jump by every test available at that
    instant. Reported, it moved the leader; the leader relaid out in turn
    and told this device to move; and the pair walked itself from halfway
    through the book to the far end in three rounds of that.

    So a relayout starts a quiet spell rather than skipping one event. Any
    page this device lands on while the book is still settling is taken as
    the settling and not as somebody's tap.

    Hung on the length changing rather than on settings being applied. Two
    devices swap their settings the moment they meet, and most of the time
    nothing about the book moves as a result -- gagging every tap for
    several seconds after a connection would be paying for a relayout that
    never happened.
    ]]
    if self.applying_typography then
        self.relayout_at = Util.now()
        return
    end
    local pages = self.reader.getPageCount()
    -- Only a page count that has *moved* says a relayout happened. The
    -- first one seen says nothing at all, and treating it as a change
    -- opened a quiet spell over the first tap of every session.
    if pages and self.last_seen_pages and pages ~= self.last_seen_pages then
        self.relayout_at = Util.now()
    end
    self.last_seen_pages = pages
    if self.relayout_at and Util.now() - self.relayout_at < PAGINATION_SETTLE then
        self.assigned_page = page
        self.assigned_pages = pages
        return
    end

    if self.assigned_page and page == self.assigned_page then return end
    local link = self:getReadyLinks()[1]
    if not link then return end
    -- Remembered before the answer comes back, so a jump is asked for once.
    self.assigned_page = page
    self.assigned_pages = pages
    self:log("jumped to", page, "- asking the leader to follow")
    link:send(Protocol.GOTO, { page = page })
end

--[[--
Puts the whole spread where a follower asked to be.

The follower names the page it wants to be showing. This device works out
where it has to sit for that to be true, which is the inverse of the sum it
does every time it sends that follower a page, and then moves -- taking
everyone else along with it, because the leader moving is what a spread is.

Clamped to the same floor and ceiling a page turn respects: a link near the
end of a book must not put the leader somewhere the last device cannot
follow, which would show the same page on two screens.
--]]--
function Core:applyRemoteJump(link, wanted)
    if not wanted or not self.reader then return end
    local options = self:getSpreadOptions()
    local page = Spread.leaderPageForSlot(wanted, link.slot, options)
    local count = self.reader.getPageCount()
    local followers = self:followerCount()
    local floor = Spread.leaderFloor(count, followers, options) or 1
    local ceiling = Spread.leaderCeiling(count, followers, options)
    page = Util.clamp(page, math.max(floor, 1), ceiling or math.huge)
    self.applying_remote = true
    local ok, err = pcall(self.reader.gotoPage, page)
    self.applying_remote = false
    if not ok then
        self:log("could not follow a jump to page", page, err)
    end
    self:broadcastState()
end

--[[--
Whether this device lays the book out the way the leader does.

Two page numbers are the same page only when the same layout produced them.
Change the font size and a book of 300 pages becomes one of 450: page 150
was the middle and is now the first third, and nothing about the number
itself says so. The leader stamps every page it sends with the layout that
counted it, and that stamp is what makes the number safe to use.

Returns nil when there is nothing to compare -- an old peer, or a document
type with no typography at all -- in which case the number is taken at face
value, which is what it always was.
--]]--
function Core:layoutMatches(leader_typo)
    if not leader_typo or leader_typo == "" then return nil end
    local own = self:typographySignature()
    if not own or own == "" then return nil end
    return own == leader_typo
end

--[[--
The page this device should show for a page the leader counted.

While the two devices disagree about the layout, one of them is mid-relayout
and the number cannot be used: the answer is nil and the caller waits. Once
the wait has gone on longer than a relayout takes, the disagreement is real
-- different screens, a missing font -- and the position is carried across
by proportion instead, which is the best a page number can do when the two
books are genuinely different lengths.
--]]--
function Core:pageUnderOwnLayout(page, leader_pages, leader_typo)
    local matches = self:layoutMatches(leader_typo)
    if matches ~= false then
        -- Agreed, or nothing to compare: the number means what it says.
        self.layout_differed_at = nil
        return page
    end

    local since = self.layout_differed_at
    if not since then
        self.layout_differed_at = Util.now()
        return nil
    end
    if Util.now() - since < PAGINATION_SETTLE then return nil end

    local own_pages = self.reader and self.reader.getPageCount()
    if not own_pages or own_pages <= 0 or not leader_pages or leader_pages <= 0 then
        return page
    end
    if own_pages == leader_pages then return page end

    local scaled = Util.clamp(Util.round(page * own_pages / leader_pages), 1, own_pages)
    --[[
    Proportion only wins when it would actually put this device somewhere
    else. Two books a page or two apart in length -- which is what a
    cosmetic setting the two devices spell differently comes to -- scale to
    a page next door, and taking that page instead of the one the leader
    named is how a follower ends up permanently one page ahead of the
    spread its leader is describing. It is stable, too, which is the worst
    part: this device believes it is exactly where it was sent, so nothing
    ever puts it right.

    The leader's own number is the pair's shared language, and near enough
    is near enough. What proportion is for is the case it was added for: two
    books of genuinely different lengths, where the raw number is not a page
    next door but a different part of the book.
    ]]
    local step = Spread.stepFor(self:get("mode"), self:followerCount())
    if math.abs(scaled - page) <= math.max(step, 1) then
        return Util.clamp(page, 1, own_pages)
    end
    return scaled
end

--[[--
Applies a page the leader told us to show.

Held back rather than applied while the two devices are laying the book out
differently. Sending a device to a page counted under a layout it is not
using any more is what threw the reader a long way from where they were --
the leader repaginates the instant the font size changes, and its next
broadcast used to arrive while this device was still on the old pagination.
--]]--
function Core:applyRemotePage(page, leader_pages, leader_typo)
    if not self.reader or not page then return end
    local wanted = self:pageUnderOwnLayout(page, leader_pages, leader_typo)
    if not wanted then
        -- Kept, because the leader only broadcasts when something changes
        -- and this device must not be left behind on the one that mattered.
        self.pending_page = { page = page, pages = leader_pages, typo = leader_typo }
        return
    end
    self.pending_page = nil
    -- Recorded whether or not this device has to move for it: this is the
    -- page it has been *sent*, and it is what tells a jump made here from
    -- the leader's own idea of where this screen belongs.
    self.assigned_page = wanted
    self.assigned_pages = self.reader.getPageCount()
    if self.reader.getPage() == wanted then return end
    self.applying_remote = true
    local ok, err = pcall(self.reader.gotoPage, wanted)
    self.applying_remote = false
    if not ok then
        self:log("could not go to page", wanted, err)
    end
    self:changed()
end

--- Retries a page that arrived while the layouts still disagreed.
function Core:applyPendingPage()
    local held = self.pending_page
    if not held or not self.reader then return end
    self:applyRemotePage(held.page, held.pages, held.typo)
end

--------------------------------------------------------------------------
-- The book list
--------------------------------------------------------------------------

--[[--
Attaches the file browser, when this device is showing one.

KOReader's file manager and its reader are separate worlds and only one
exists at a time, so this comes and goes exactly as the reader binding
does. The engine outlives both.
--]]--
function Core:attachBrowser(binding)
    self:log("browser attached")
    self.browser = binding
    self.browser_state = nil
    self.warned_listing = false
    self:changed()
    if self:isActive() and self:isFollower() then
        --[[
        Ask, rather than wait to be told.

        Only the leader pushed the listing, and only at the moments it
        happened to think of: a link coming up, a swipe, a folder change. A
        follower that reached the file manager at any other moment — the
        common one being a leader already sitting in its list long before
        this device connected — sat there with an unshared list and no way
        to say so. The book list looked broken until somebody swiped on the
        other device, which is exactly what a push-only design feels like
        from the receiving end.

        The leader answers SYNC with the listing among everything else, so
        one line here closes the gap for good.
        ]]
        local link = self:getReadyLinks()[1]
        if link then link:send(Protocol.SYNC, {}) end
        --[[
        And say that this device has come out of the book.

        The file manager appearing here is the same event it is on the
        leader, and it used to go nowhere. The leader stayed in its book,
        answered the SYNC above with the document it was still reading, and
        the follower was pulled straight back into it -- so the shelf could
        not be reached from this end at all.
        ]]
        self:requestHome()
    end
    if self:isActive() and self:isLeader() then
        --[[
        The file manager appearing on the leader is the moment the book was
        closed, and a better signal than the reader going away: switching
        straight from one book to another tears a reader down too, and a
        follower told to go home then would close the book it is about to be
        told to open.
        ]]
        if self:get("follow_document") then
            for _, link in ipairs(self:getReadyLinks()) do
                link:send(Protocol.HOME, {})
            end
        end
        self:broadcastBrowser()
    end
end

function Core:detachBrowser(binding)
    if binding and self.browser and self.browser ~= binding then return end
    self.browser = nil
    self.browser_state = nil
    self:changed()
end

function Core:browsingTogether()
    return self:get("share_browser") and self.browser ~= nil and self:isConnected()
end

--[[--
The file browser's state, as it is this instant.

Only ever about what is on the screen: which page of which listing the two
devices are showing each other. What may be copied is a different question
with a different answer -- see `sharedFolder` -- and the two were tangled
together for far too long.
--]]--
function Core:browserState()
    if not self.browser then return nil end
    return self.browser.getState()
end

--- Sends one device the page of the listing it should be showing.
function Core:sendBrowserTo(link)
    if not self:isLeader() or not self.browser then return end
    if not self:get("share_browser") then return end
    local state = self:browserState()
    if not state then return end
    self.browser_state = state

    local page = Spread.pageForSlot(state.page, link.slot, {
        mode = self:get("mode"),
        reverse = self:get("reverse"),
        page_count = state.pages,
    })
    self:log(("listing: %s, page %d of %d, %d per screen, %d items; slot %d gets page %d")
        :format(state.path, state.page, state.pages, state.perpage, state.count,
                link.slot, page))
    link:send(Protocol.BROWSE, {
        path = state.path,
        -- What list this is, not merely where it is. A folder is named by
        -- its path as it always was; the library's own views -- History,
        -- Favourites, a collection -- are named by what they are, because
        -- page 2 of Favourites and page 2 of a folder have nothing to do
        -- with each other.
        view = state.view or "",
        page = page,
        leader_page = state.page,
        pages = state.pages,
        perpage = state.perpage,
        -- Only set when this device is showing a grid of covers, so the
        -- other one can take the same shape rather than a bare total.
        cols = state.cols,
        rows = state.rows,
        count = state.count,
        sig = state.signature or "",
    })
end

--- Sends every device the page of the listing it should be showing.
function Core:broadcastBrowser()
    if self:isLeader() then self:noteActivity() end
    for _, link in ipairs(self:getReadyLinks()) do
        self:sendBrowserTo(link)
    end
    self:changed()
end

--- Shows the part of the listing the leader allotted to this device.
function Core:applyBrowser(msg)
    if not self.browser or not self:get("share_browser") then return end
    if self:isLeader() then return end

    self.applying_remote = true
    -- Same list first: a page number means nothing until the two devices
    -- are looking at the same one.
    local path = msg.path
    if path and path ~= "" then
        if not self.browser.changeDir(path) then
            self.applying_remote = false
            self:refuseListing(("The other device is browsing a folder this one does not have:\n\n%s"):format(path), msg.view)
            return
        end
    elseif not self:sameBrowserView(msg.view) then
        --[[
        One of the library's own views -- History, Favourites, a collection
        -- rather than a folder. Duo will page along with one when both
        devices are already in it, and will not put anybody there: a view is
        something the reader chose, and swapping the screen out from under
        that choice is worse than not following it.
        ]]
        self.applying_remote = false
        self:refuseListing(("The other device is looking at a list this one is not in (%s).\n\nOpen the same one here and the two will page together."):format(
            self:describeBrowserView(msg.view)), msg.view)
        return
    end
    if self:get("match_typography") then
        -- Items per page decides where one screenful ends and the next
        -- begins, so it belongs with the rest of the layout matching.
        self.browser.setPerPage(Protocol.num(msg, "perpage"),
            Protocol.num(msg, "cols"), Protocol.num(msg, "rows"))
    end
    self.browser.goToPage(Protocol.num(msg, "page", 1))
    self.applying_remote = false

    self:checkListing(msg)
    self:changed()
end

--- Whether this device is showing the same list the other one named.
function Core:sameBrowserView(view)
    if not view or view == "" then return true end -- an older peer: as before
    local state = self:browserState()
    if not state then return false end
    return (state.view or "") == view
end

--- "History", "Favourites", "a folder" -- for saying which list is meant.
function Core:describeBrowserView(view)
    view = tostring(view or "")
    if view == "history" then return "History" end
    local collection = view:match("^collection:(.*)$")
    if collection then
        return collection ~= "" and collection or "a collection"
    end
    local folder = view:match("^folder:(.*)$")
    if folder then return folder ~= "" and folder or "a folder" end
    return view ~= "" and view or "another list"
end

--[[--
Says why the two listings are not being lined up, once per listing.

Once, because a device that cannot follow the other's list says so on every
message otherwise, which is every swipe. Per listing, because moving to a
different one is a different situation: a reader told about Favourites,
who then goes and opens History somewhere else, is owed the same courtesy
again rather than silence.
--]]--
function Core:refuseListing(text, view)
    view = tostring(view or "")
    if self.warned_listing and self.warned_view == view then return end
    self.warned_listing = true
    self.warned_view = view
    self:alert(text)
end

--[[--
The folder Duo copies books to and from, with any trailing slash trimmed.

Not the folder on screen. Everything about copying books hangs off this one
answer, so that a transfer means the same thing whether the reader is in the
file browser, in a library view, or halfway through a novel.
--]]--
function Core:sharedFolder()
    local path = tostring(self:get("shared_folder") or "")
    path = path:gsub("/+$", "")
    if path == "" then return nil end
    return path
end

--[[--
The books sitting in `path`, read from the disk rather than from a listing.

A browser's listing is a view: it has a filter on it, it is sorted, it may
be a library view that is not a folder at all, and it does not exist while a
book is open. The folder is none of those things -- it is just what is
there, which is the only sound basis for deciding what has to be copied.

@treturn table array of { name =, size = }
--]]--
function Core:folderFiles(path)
    if not path or not self.hooks or not self.hooks.listFolder then return {} end
    local ok, entries = pcall(self.hooks.listFolder, path)
    if not ok or type(entries) ~= "table" then
        self:log("could not read the shared folder", path, "-", tostring(entries))
        return {}
    end
    local BookTransfer = require("duo/booktransfer")
    local books = {}
    for _, entry in ipairs(entries) do
        if entry.name and BookTransfer.isBookName(entry.name) then
            books[#books+1] = { name = entry.name, size = entry.size or 0 }
        end
    end
    return books
end

--[[--
Asks for the shared folder's index once the pair is connected.

Driven by the link rather than by browsing. It used to hang off whatever the
file browser was showing: a folder somebody happened to open, compared with
the leader's view of the same, which made what got copied depend on where
each reader had wandered to -- and left a device with a book open, and so no
browser at all, unable to take part.
--]]--
function Core:checkLibrary()
    if not self:get("sync_library") or self:isLeader() then return end
    if not self:isConnected() then
        self.library_asked = false
        self.library_settled = false
        return
    end
    if self.library or self.book_receiver then
        return -- a pass is running; it has not had its say yet
    end
    if self.library_asked then
        -- Asked, and nothing left running: the pass is over, whatever it
        -- found. Anything still not lining up after that is worth saying.
        self.library_settled = true
        return
    end
    self.library_asked = true
    self:requestLibrary()
end

--[[--
Whether the shared folder may yet fix itself.

A folder that does not match is only worth complaining about once the
copying has finished and left it that way. Between connecting and that
moment, a difference is a difference about to be repaired, and saying so is
alarming somebody about the thing that is already being handled.
--]]--
function Core:librarySettling()
    if not self:get("sync_library") or self:isLeader() then return false end
    if not self:isConnected() then return false end
    return not self.library_settled
end

--[[--
Says once that the book is too short to spread across the pair.

A one-page book has no second page for the second device, so both show the
same one. That is the only thing it *can* do, but it looks exactly like the
spread being broken — the complaint being that two devices show one page —
and silence invites that reading. The leader already says when a follower's
page had to be pulled back inside the book; this turns that flag into
words, once, and only for a book too short to fill the row rather than for
the ordinary last page of a long one.
--]]--
function Core:noteShortBook(beyond, pages)
    if not beyond or self.warned_short_book then return end
    -- The last spread of any book clamps too. Only a book that cannot fill
    -- the row even from its first page is worth mentioning, which is
    -- exactly a ceiling that has fallen below the first page.
    local slots = self:followerCount()
    if not pages or pages <= 0 or slots < 1 then return end
    local options = self:getSpreadOptions()
    options.page_count = pages
    local ceiling = Spread.leaderCeiling(pages, slots, options)
    if not ceiling or ceiling >= 1 then return end
    self.warned_short_book = true
    self:alert(("This book is only %d page%s long, so there is not enough of it to fill both screens. Both devices show the same page."):format(
        pages, pages == 1 and "" or "s"))
end

--[[--
Warns once when the two devices are not looking at the same list.

Nothing is said while books are on their way over: the mismatch is exactly
what the library sync is busy repairing, and the next listing after it
finishes will either match or be worth complaining about.
--]]--
function Core:checkListing(msg)
    if self.warned_listing or not self.browser then return end
    if self:isSyncingLibrary() or self:librarySettling() then return end
    local state = self:browserState()
    if not state then return end

    local their_count = Protocol.num(msg, "count")
    local their_signature = msg.sig
    if their_count and their_count ~= state.count then
        self.warned_listing = true
        self:alert(("This folder holds %d items here and %d on the other device, so the halves will not line up.\n\nThe same books have to be on both."):format(
            state.count, their_count))
        return
    end
    if their_signature and their_signature ~= "" and state.signature
            and their_signature ~= state.signature then
        self.warned_listing = true
        self:alert("Both devices show the same number of books, but not the same ones, so the halves will not line up.")
        return
    end
    -- The same books, but cut into different sized screenfuls. Duo evens
    -- this out by itself wherever KOReader lets it, so reaching here means
    -- it could not: one device is showing a grid of covers and the other a
    -- list, and a total gives no way to know what shape the grid should be.
    local their_perpage = Protocol.num(msg, "perpage")
    if their_perpage and their_perpage > 0 and (state.perpage or 0) > 0
            and their_perpage ~= state.perpage then
        self.warned_listing = true
        self:alert(("This device fits %d books on a screen and the other %d, so the halves will not line up.\n\nThey are drawing the list differently. Put both on the same display mode and Duo can even them up itself."):format(
            state.perpage, their_perpage))
    end
end

--[[--
The reader is about to go idle, or has just come back.

Only the leader is asked: it is the one with a person holding it, and it is
the one KOReader tells. A follower asleep on its own is a bug; a follower
asleep because the leader is, is the whole point.
--]]--
function Core:setDeviceIdle(idle)
    self.device_idle = idle and true or false
    if not self:isActive() then return end

    if self:isLeader() then
        for _, link in ipairs(self:getReadyLinks()) do
            link:send(Protocol.NAP, { sleep = idle and 1 or 0 })
        end
        return
    end
    -- A follower that has just woken has missed whatever happened while it
    -- was out, and the cheapest way to find out is to ask.
    if not idle and self:isConnected() then
        local link = self:getReadyLinks()[1]
        if link then link:send(Protocol.SYNC, {}) end
    end
end

--- The other device says it is dozing off, or waking up.
function Core:handleNap(msg)
    if self:isLeader() then return end
    self.peer_napping = Protocol.bool(msg, "sleep")
    self:log(self.peer_napping and "the other device is dozing off"
        or "the other device is back")
    self:updateAwake()
    self:changed()
end

--[[--
Handles a swipe through the listing.

The leader steps by as many screenfuls as there are devices; a follower asks
the leader to do it, exactly as with a page turn in a book.

@treturn boolean true when Duo handled it and the browser should not
--]]--
function Core:handleBrowserTurn(diff)
    if not self:browsingTogether() then return false end
    if self:isLeader() then
        self:applyBrowserTurn(diff)
        return true
    end
    if not self:get("follower_can_turn") then return true end
    local link = self:getReadyLinks()[1]
    if not link then return false end
    link:send(Protocol.BTURN, { dir = diff })
    return true
end

function Core:applyBrowserTurn(diff)
    if not self.browser then return end
    local state = self:browserState()
    if not state then return end
    local step = Spread.stepFor(self:get("mode"), self:followerCount())
    -- Clamped rather than wrapped: cycling round to the first page would
    -- put the devices on unrelated parts of the list.
    local target = Util.clamp(state.page + diff * step, 1, state.pages)
    self.browser.goToPage(target)
    self:broadcastBrowser()
end

--- Notices the leader moving through the listing by any other route.
function Core:checkBrowser()
    if not self:isLeader() or not self.browser then return end
    if not self:get("share_browser") or not self:isConnected() then return end
    if self.applying_remote then return end
    local state = self:browserState()
    if not state then return end
    local previous = self.browser_state
    if previous and previous.page == state.page and previous.path == state.path
            and previous.count == state.count then
        return
    end
    self:broadcastBrowser()
end

--------------------------------------------------------------------------
-- Keeping the whole library in step
--------------------------------------------------------------------------

-- A folder with more entries than this is not something to copy over a
-- Wi-Fi link one file at a time without being asked.
local MAX_LIBRARY_ENTRIES = 2000

--[[--
Asks the other device what it has in the shared folder.

Only worth doing when the two listings already disagree — which is exactly
what makes the two halves of a shared book list fail to line up.
--]]--
function Core:requestLibrary()
    if not self:get("sync_library") then return false end
    if self:isLeader() then return false end
    if self.library or self.book_receiver then return false end
    local link = self:getReadyLinks()[1]
    if not link then return false end
    local folder = self:sharedFolder()
    if not folder then return false end

    self.library = { path = folder, index = {}, collecting = true, done = 0 }
    link:send(Protocol.LIB_REQ, { path = folder })
    self:log("asked for the library index of", folder)
    return true
end

--- The leader lists the folder it is sharing.
function Core:handleLibraryRequest(link, msg)
    if not self:isLeader() then return end
    if not self:get("sync_library") then
        link:send(Protocol.LIB_END, { count = 0, reason = "not sharing the library" })
        return
    end
    local folder = self:sharedFolder()
    if not folder then
        link:send(Protocol.LIB_END, { count = 0, reason = "no shared folder is set" })
        return
    end
    -- One folder, named in the settings, and no other: a peer does not get
    -- to enumerate the filesystem by asking for a path of its own choosing.
    if msg.path and msg.path ~= "" and msg.path ~= folder then
        link:send(Protocol.LIB_END, { count = 0, reason = "that is not the folder being shared" })
        return
    end

    -- Read from the folder rather than from a browser's listing of it. The
    -- listing has a filter on it, may be a library view that is not a folder
    -- at all, and does not exist at all while a book is open -- which is
    -- exactly when the other device asks, having followed this one into it.
    local entries = self:folderFiles(folder)
    if #entries > MAX_LIBRARY_ENTRIES then
        link:send(Protocol.LIB_END, { count = 0, reason = "that folder holds too many files to copy" })
        return
    end
    for _, entry in ipairs(entries) do
        link:send(Protocol.LIB_ITEM, { name = entry.name, size = entry.size })
    end
    link:send(Protocol.LIB_END, { count = #entries })
end

function Core:handleLibraryItem(msg)
    if not self.library or not self.library.collecting then return end
    -- Checked at this end too. The other device filters, but what arrives
    -- over a socket is not something to take on trust, and this is the
    -- device that would be writing the file.
    local BookTransfer = require("duo/booktransfer")
    if not BookTransfer.isBookName(msg.name) then
        self:log("not a book, skipping:", tostring(msg.name))
        return
    end
    self.library.index[#self.library.index+1] = {
        name = msg.name,
        size = Protocol.num(msg, "size", 0),
    }
end

--- Works out what is missing here and starts fetching it.
function Core:handleLibraryEnd(msg)
    if not self.library or not self.library.collecting then return end
    self.library.collecting = false

    if msg.reason and msg.reason ~= "" then
        self:log("library sync refused:", msg.reason)
        self.library = nil
        self:changed()
        return
    end

    -- What is in the shared folder, off the disk. Not what a browser is
    -- listing: this has to be answerable with a book open and no browser
    -- anywhere, which is the common case.
    local here = {}
    for _, entry in ipairs(self:folderFiles(self.library.path)) do
        here[entry.name] = entry.size or 0
    end

    local wanted, bytes = {}, 0
    for _, entry in ipairs(self.library.index) do
        -- Same name and same size counts as the same book; anything else is
        -- fetched rather than guessed at. A stand-in is the exception: the
        -- size is meant to differ, and it is the shelf being right that was
        -- asked for, not the bytes.
        local mine = here[entry.name]
        local satisfied = mine ~= nil and mine == entry.size
        if not satisfied and mine ~= nil and self:wantsStubs() then
            satisfied = self:isStub(self.library.path .. "/" .. entry.name)
        end
        --[[
        And a book that already refused to come is not asked for again.

        A failure leaves the folder still not matching, so the next look at
        it wants the same book, asks for it, fails the same way and finishes
        still not matching -- a device fetching nothing, over and over, for
        as long as it is left alone. Remembered for this session only: a
        reconnect, or Duo being restarted, is a fair reason to try again.
        ]]
        if not satisfied and not (self.library_failed or {})[entry.name] then
            wanted[#wanted+1] = entry
            bytes = bytes + (entry.size or 0)
        end
    end

    if #wanted == 0 then
        self.library = nil
        self:changed()
        return
    end

    --[[
    Said out loud when it is a lot, rather than refused.

    There used to be a ceiling here, and it was the wrong shape of help. A
    device that has the books and a link to send them over should send them;
    what it owes the reader is a warning that this will take a while and a
    way to stop, not a refusal with a number in it. The number was also a
    setting somebody had to find and raise before the feature would work at
    all, which is a poor way to spend a person's evening.
    ]]
    if bytes > BIG_TRANSFER then
        self:alert(("That folder holds %d book%s this device lacks — %.0f MB.\n\nOver a link like this one that will take a long time. Copying them onto both devices yourself will be far quicker if you can; otherwise leave it running, and stop it whenever you like from the Duo menu."):format(
            #wanted, #wanted == 1 and "" or "s", bytes / 1048576))
    end

    self.library.wanted = wanted
    self.library.total = #wanted
    self.library.bytes = bytes
    self:notify(("Duo: fetching %d book%s (%.1f MB)"):format(
        #wanted, #wanted == 1 and "" or "s", bytes / 1048576))
    self:changed()
    self:pumpLibrary()
end

--- Remembers a book that would not come, so the folder stops asking for it.
function Core:noteLibraryFailure(request, reason)
    local name = request and request.title
    if not name or name == "" then return end
    self.library_failed = self.library_failed or {}
    self.library_failed[name] = reason or "it would not come"
    if self.library then
        self.library.failed = (self.library.failed or 0) + 1
    end
end

--- Asks for the next book on the list, one at a time.
function Core:pumpLibrary()
    local library = self.library
    if not library or library.collecting then return end
    if self.book_receiver or self.book_request then return end

    local next_entry = table.remove(library.wanted, 1)
    if not next_entry then
        local total = library.total or 0
        self.library = nil
        local failed = library.failed or 0
        if total > 0 and failed > 0 then
            -- Not left to be discovered by finding a gap on the shelf later.
            self:alert(("Duo copied %d of %d book%s; %d would not come.\n\nThe rest are on the shelf. Copy the missing one%s across yourself, or reconnect to have another go."):format(
                total - failed, total, total == 1 and "" or "s",
                failed, failed == 1 and "" or "s"))
            if self.browser then self.browser.refresh() end
        elseif total > 0 then
            self:notify(("Duo: the library is in step (%d book%s)"):format(
                total, total == 1 and "" or "s"))
            if self.browser then self.browser.refresh() end
            -- The list is a different length than it was a moment ago, so
            -- the half of it this device was given no longer means the same
            -- thing. Ask the leader where in the new one it belongs.
            local ready = self:getReadyLinks()[1]
            if ready then ready:send(Protocol.SYNC, {}) end
        end
        self:changed()
        return
    end

    local link = self:getReadyLinks()[1]
    if not link then
        self.library = nil
        return
    end
    library.current = next_entry
    local stub = self:wantsStubs() and next_entry.name:lower():match("%.epub$") ~= nil
    self.book_request = {
        file = library.path .. "/" .. next_entry.name,
        title = next_entry.name,
        library = true,
        stub = stub,
        started = Util.now(),
    }
    link:send(Protocol.BOOK_REQ, {
        file = self.book_request.file,
        digest = "",
        lib = 1,
        stub = stub and 1 or nil,
    })
end

--[[--
Whether the library should fill up with stand-ins rather than books.

A stand-in is a real EPUB holding the cover and the title and nothing else,
so the shelf and the shared list are right immediately and the bytes wait
until somebody opens something. Only EPUBs can have one: a stand-in has to
carry the name of the book it stands in for, so it has to be the same
format too, and anything else is copied whole.
--]]--
function Core:wantsStubs()
    return self:get("sync_library") and self:get("covers_first")
end

--[[--
Whether a file here is one of Duo's stand-ins rather than a book.

Asked of the file itself — the marker is written into it — so it survives
restarts, backups and anything else that would lose a list kept alongside.
--]]--
function Core:isStub(path)
    -- What this device was told when the file arrived, which beats reading
    -- it back: the marker lives inside the EPUB, and getting at it needs an
    -- archive library that a stripped build may not have. When that read
    -- failed the stand-in passed for a book and a tap opened the empty
    -- thing, which is the one outcome the whole arrangement exists to avoid.
    local known = self.settings and self.settings.stubs
    if known and known[path] ~= nil then return known[path] == true end

    local loaded, EpubStub = pcall(require, "duo/epubstub")
    if not loaded then return false end
    local read, answer = pcall(EpubStub.isPlaceholder, path)
    if not read then
        self:log("could not read", path, "-", tostring(answer))
        return false
    end
    return answer == true
end

--[[--
Notes down whether the file that just landed is a stand-in or a book.

Kept per device rather than shared: it describes what is on this disk. A
real book arriving where a stand-in was clears the note rather than
rewriting it, so the register only ever holds what is still standing in.
--]]--
function Core:rememberStub(path, is_stub)
    if type(path) ~= "string" or path == "" then return end
    self.settings.stubs = self.settings.stubs or {}
    self.settings.stubs[path] = is_stub and true or nil
    self:save()
end

--[[--
Fetches the book a stand-in is standing in for, and opens it.

This is the moment the bytes were being saved for: the user has picked the
book, so the wait is theirs to spend, and it is spent once.

@string path  the stand-in, which the book will replace
@treturn boolean true when the asking started
--]]--
function Core:fetchBookFor(path, title)
    if not self:isConnected() or self:isLeader() then return false end
    if self.book_receiver or self.book_request then return false end
    local link = self:getReadyLinks()[1]
    if not link then return false end

    self.book_request = {
        file = path,
        title = title or path:gsub("^.*/", ""),
        library = true,     -- it lives in the shared folder, not the Duo one
        replacing = path,   -- and lands exactly where the stand-in was
        open_when_done = true,
        started = Util.now(),
    }
    link:send(Protocol.BOOK_REQ, { file = path, digest = "", lib = 1 })
    self:notify(("Duo: fetching %s"):format(self.book_request.title))
    self:changed()
    return true
end

function Core:stopLibrarySync(reason)
    if not self.library then return false end
    self.library = nil
    if self.book_receiver then
        self.book_receiver:abort()
        self.book_receiver = nil
    end
    self.book_request = nil
    self:notify(("Duo: stopped fetching books%s"):format(reason and (" (" .. reason .. ")") or ""))
    self:changed()
    return true
end

function Core:isSyncingLibrary()
    return self.library ~= nil
end

--------------------------------------------------------------------------
-- Sending the book itself
--------------------------------------------------------------------------

--[[--
Asks the leader for a book this device does not have.

Called when the leader announces a document that is nowhere on this device.
Following someone else's reading is not much use if you cannot open what
they are reading.
--]]--
function Core:requestBook(msg)
    if not self:get("sync_books") then return false end
    if self:isLeader() then return false end
    local link = self:getReadyLinks()[1]
    if not link then return false end
    if self.book_receiver or self.book_request then return false end

    self.book_request = {
        file = msg.file,
        digest = msg.digest,
        title = msg.title,
        started = Util.now(),
    }
    link:send(Protocol.BOOK_REQ, { file = msg.file, digest = msg.digest or "" })
    self:notify(("Duo: asking for %s"):format(msg.title ~= "" and msg.title or "the book"))
    return true
end

--[[--
Turns a request for a library book into a path, or refuses.

The only thing taken from the request is a bare file name, which must
appear in the listing of the folder this device is currently sharing. The
path is then built here. A name with a directory in it, or one that is not
in that listing, gets nothing.

@treturn string a readable path, or nil
--]]--
--- Whether a path names a file we can actually open and send.
local function fileExists(path)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok and lfs then
        return lfs.attributes(path, "mode") == "file"
    end
    local handle = io.open(path, "rb")
    if not handle then return false end
    handle:close()
    return true
end

function Core:resolveSharedFile(requested)
    -- Deliberately not conditional on a file browser being attached. What is
    -- shared is a folder named in the settings, and a folder is still there
    -- when no widget is listing it.
    if not self:get("sync_library") then return nil end
    local BookTransfer = require("duo/booktransfer")
    local name = BookTransfer.safeName(requested)
    if not name then return nil end
    -- The gate that actually matters: this is the one that opens a file and
    -- puts its bytes on the wire, so a name that is not a book stops here
    -- no matter how it came to be asked for.
    if not BookTransfer.isBookName(name) then return nil end

    -- The folder named in the settings, whatever this device is looking at.
    -- What may be handed over does not depend on where somebody wandered to,
    -- and is answerable with a book open and no browser anywhere -- which is
    -- exactly when the other device asks, having followed this one into it.
    local folder = self:sharedFolder()
    if not folder then return nil end

    -- Judged against the folder itself rather than against the browser's
    -- listing of it, which is a view that goes away when the reader covers
    -- it. `safeName` has already refused anything carrying a directory, so
    -- this can only name a file sitting directly in the shared folder.
    local path = folder .. "/" .. name
    if not fileExists(path) then return nil end
    return path
end

--- The leader starts sending a book a follower asked for.
function Core:handleBookRequest(link, msg)
    if not self:isLeader() then return end
    local BookTransfer = require("duo/booktransfer")

    if not self:get("sync_books") then
        link:send(Protocol.BOOK_ERR, { reason = "the other device is not set up to send books" })
        return
    end
    -- A peer never gets to name a path and be handed whatever is at it.
    -- Two things may be asked for: the book this device has open, or a book
    -- in the folder it is actively sharing — and in the second case the
    -- path is rebuilt here from the shared folder plus a bare file name,
    -- so nothing outside that folder is reachable however it is spelled.
    local path
    if Protocol.bool(msg, "lib") then
        path = self:resolveSharedFile(msg.file)
        if not path then
            link:send(Protocol.BOOK_ERR, { reason = "that book is not in the shared folder" })
            return
        end
    else
        local document = self.reader and self.reader.getDocument() or nil
        if not document or not document.file or document.file ~= msg.file then
            link:send(Protocol.BOOK_ERR, { reason = "that is not the book this device has open" })
            return
        end
        path = document.file
    end

    -- A stand-in is built here and sent in the book's place, under the
    -- book's own name: the other device needs the listing to match, and it
    -- is this device that has the file to take a cover out of.
    local sending_stub = false
    if Protocol.bool(msg, "stub") then
        local stub_path, stub_err = self:buildStub(path)
        if stub_path then
            path = stub_path
            sending_stub = true
        else
            --[[
            Falling back to the whole book is right — a book that arrives
            slowly beats one that never arrives — but doing it in silence
            is not. Somebody who asked for covers first asked precisely to
            avoid sending a library over a link like this, and needs to
            know they are getting the opposite. Once per run: this is per
            book, and a shelf of them would be a wall of messages.
            ]]
            self:log("no stand-in for", path, "-", tostring(stub_err), "- sending the book")
            if not self.warned_no_stub then
                self.warned_no_stub = true
                self:alert(("The other device cannot build cover-only stand-ins (%s), so whole books are being sent instead. That works, but it is much slower."):format(
                    tostring(stub_err)))
            end
        end
    end

    local sender, err = BookTransfer.newSender(path)
    if not sender then
        link:send(Protocol.BOOK_ERR, { reason = tostring(err) })
        return
    end
    self.book_sender = {
        sender = sender,
        link = link,
        name = (sending_stub and msg.file or path):gsub("^.*/", ""),
        -- Built for this transfer alone, and no use to anyone afterwards.
        temporary = sending_stub and path or nil,
    }
    link:send(Protocol.BOOK_HEAD, {
        name = self.book_sender.name,
        size = sender.size,
        digest = "",
        -- Said out loud, rather than left to be discovered. The receiving
        -- device used to have to read the marker back out of the file to
        -- learn a stand-in was a stand-in, which needs an archive library
        -- it may not have — and when that reading failed the stand-in
        -- passed for a book, so a tap opened the empty thing instead of
        -- fetching what it stood for.
        stub = sending_stub and 1 or nil,
        title = (not Protocol.bool(msg, "lib") and self.reader and self.reader.getDocument()
            and self.reader.getDocument().title) or "",
    })
    self:notify(("Duo: sending %s (%.1f MB)"):format(self.book_sender.name, sender.size / 1048576))
    self:changed()
end

--[[--
Makes a stand-in for a book, and returns where it was put.

Built fresh each time rather than kept: it is a few hundred kilobytes per
book, the cover only changes when the book does, and a device that is
asking for stand-ins is usually asking once.

@treturn string a path, or nil plus a reason
--]]--
function Core:buildStub(source)
    if not source:lower():match("%.epub$") then
        return nil, "only an EPUB can stand in for itself"
    end
    local ok, EpubStub = pcall(require, "duo/epubstub")
    if not ok then return nil, "no stand-in builder" end

    if not self.hooks or not self.hooks.getTempDir then
        return nil, "nowhere to build it"
    end
    local found, directory = pcall(self.hooks.getTempDir)
    if not found or not directory then
        return nil, "nowhere to build it: " .. tostring(directory)
    end
    local out = ("%s/duo-stub-%s.epub"):format(directory, Util.randomHex(6))
    local made, built, err = pcall(EpubStub.make, source, out)
    if not made then return nil, tostring(built) end
    if not built then return nil, err end
    return out
end

--- Removes a stand-in built for a transfer that is over.
function Core:clearTemporary(transfer)
    if transfer and transfer.temporary then
        os.remove(transfer.temporary)
    end
end

--- Pushes as much of the book as the link will take right now.
function Core:pumpBookSender()
    local transfer = self.book_sender
    if not transfer then return end
    if transfer.link:isClosed() then
        transfer.sender:close()
        self:clearTemporary(transfer)
        self.book_sender = nil
        return
    end

    local BookTransfer = require("duo/booktransfer")
    local sent = 0
    while sent < BookTransfer.CHUNKS_PER_POLL
            and transfer.link:pending() < BookTransfer.HIGH_WATER do
        sent = sent + 1
        local chunk = transfer.sender:next()
        if not chunk then
            transfer.link:send(Protocol.BOOK_DONE, { size = transfer.sender.size })
            transfer.sender:close()
            self:clearTemporary(transfer)
            self.book_sender = nil
            self:notify("Duo: the book has been sent")
            self:changed()
            return
        end
        local ok, err = transfer.link:send(Protocol.BOOK_DATA, { b = chunk })
        if not ok then
            -- Dropping this quietly would leave the other device holding a
            -- half-written file and waiting for a chunk that is never
            -- coming, which is worse than any transfer failing.
            self:abortBookSend(err or "the chunk could not be sent")
            return
        end
    end
    self:changed()
end

--- Gives up on the book being sent, and says so at both ends.
function Core:abortBookSend(reason)
    local transfer = self.book_sender
    if not transfer then return end
    self.book_sender = nil
    transfer.sender:close()
    self:clearTemporary(transfer)
    if not transfer.link:isClosed() then
        transfer.link:send(Protocol.BOOK_ERR, { reason = reason })
    end
    self:log("sending", transfer.name, "failed:", reason)
    self:notify(("Duo: could not send %s"):format(transfer.name or "the book"))
    self:changed()
end

function Core:handleBookHead(msg)
    local BookTransfer = require("duo/booktransfer")
    -- Unsolicited books are refused: something has to have asked.
    if not self.book_request then
        return
    end
    if self.book_receiver then
        self.book_receiver:abort()
        self.book_receiver = nil
    end

    -- A book being fetched to make the shared folder match has to land in
    -- that folder; anything else goes to the Duo folder.
    local directory
    if self.book_request.replacing then
        directory = self.book_request.replacing:match("^(.*)/[^/]*$") or "."
    elseif self.book_request.library and self.library then
        directory = self.library.path
    else
        directory = self.hooks and self.hooks.getBookDir and self.hooks.getBookDir() or "."
    end
    local receiver, err = BookTransfer.newReceiver{
        directory = directory,
        name = msg.name,
        size = Protocol.num(msg, "size", 0),
    }
    if not receiver then
        self.book_request = nil
        self:alert(("Duo could not take the book: %s"):format(tostring(err)))
        return
    end
    self.book_receiver = receiver
    self.book_title = msg.title ~= "" and msg.title or msg.name
    self.progress_reported = nil
    -- One book can be the long wait all by itself, and the reader who
    -- tapped it is sitting there watching nothing happen.
    local incoming = Protocol.num(msg, "size", 0)
    if incoming > BIG_TRANSFER and not (self.book_request and self.book_request.library) then
        self:alert(("%s is %.0f MB.\n\nOver a link like this one that will take a while. You can stop it from the Duo menu, and copying the file across yourself will be quicker if you can."):format(
            self.book_title or "That book", incoming / 1048576))
    end
    self.book_request.arriving_stub = Protocol.bool(msg, "stub")
    if self.book_request then self.book_request.progress_at = Util.now() end
    self:changed()
end

function Core:handleBookData(msg)
    if not self.book_receiver then return end
    -- Still coming, so the silence timer starts again from here.
    if self.book_request then self.book_request.progress_at = Util.now() end
    local ok, err = self.book_receiver:write(msg.b or "")
    if not ok then
        self.book_receiver:abort()
        self.book_receiver = nil
        self.book_request = nil
        self:alert(("Duo could not save the book: %s"):format(tostring(err)))
    end
end

function Core:handleBookDone()
    if not self.book_receiver then return end
    local path, err = self.book_receiver:finish()
    self.book_receiver = nil
    local request = self.book_request
    self.book_request = nil
    self:changed()

    if not path then
        self:alert(("Duo could not save the book: %s"):format(tostring(err)))
        return
    end
    self:rememberStub(path, request and request.arriving_stub)
    if request and request.open_when_done then
        -- The user asked for this one by opening it, so it opens.
        self:notify(("Duo: %s is here"):format(request.title or "the book"))
        if self.browser then self.browser.refresh() end
        if self.hooks and self.hooks.openDocument then
            self.opening_file = nil
            self.hooks.openDocument(path, { title = request.title or "", digest = "", arrived = true })
        end
        return
    end
    if request and request.library then
        -- One of many: keep the folder in step rather than opening it.
        if self.library then
            self.library.done = (self.library.done or 0) + 1
            if self.browser then self.browser.refresh() end
        end
        self:pumpLibrary()
        return
    end

    self:notify(("Duo: received %s"):format(self.book_title or "the book"))
    -- Straight into it, which is the whole point of having asked.
    if self.hooks and self.hooks.openDocument and request then
        self.opening_file = nil
        self.hooks.openDocument(path, { title = self.book_title or "", digest = request.digest or "", arrived = true })
    end
end

function Core:handleBookError(msg)
    --[[
    This message travels both ways, and so does giving up. A device that
    stopped a copy told the other end so, and the other end went on sending
    -- for a thirty megabyte book, minutes of pushing at somebody who had
    stopped listening, costing both of them battery and the link its room.
    Stopping means stopping at both ends, which is what the menu entry says
    it does.
    ]]
    if self.book_sender then
        local transfer = self.book_sender
        self.book_sender = nil
        transfer.sender:close()
        self:clearTemporary(transfer)
        self.progress_reported = nil
        self:log("the other device stopped the transfer:", tostring(msg.reason))
    end
    if self.book_receiver then
        self.book_receiver:abort()
        self.book_receiver = nil
    end
    local request = self.book_request
    local was_library = request and request.library and not request.open_when_done
    self.book_request = nil
    self:changed()
    if request and request.open_when_done then
        self:alert(("Duo could not fetch %s: %s"):format(
            request.title or "the book", msg.reason or "the other device refused"))
        return
    end
    if was_library then
        -- One book failing is not a reason to abandon the rest, but it is a
        -- reason not to ask for that one again, and to say so at the end
        -- rather than leave a folder quietly short of a book.
        self:log("library book refused:", msg.reason)
        self:noteLibraryFailure(request, msg.reason)
        self:pumpLibrary()
        return
    end
    self:alert(("Duo could not fetch the book: %s"):format(msg.reason or "the other device refused"))
end

--[[--
Says how far along a transfer is, now and then.

A big book over a link like this one takes minutes, and a device that says
"fetching" once and then goes quiet for six of them is indistinguishable
from a device that has died. The status line has carried the figure all
along, but only for as long as somebody held the menu open to read it.

Every tenth of the book rather than every chunk: this ends up on an e-ink
screen, where each notice costs a flash.
--]]--
function Core:reportTransferProgress()
    local direction, fraction = self:getTransferProgress()
    if not direction then
        self.progress_reported = nil
        return
    end
    fraction = fraction or 0
    local last = self.progress_reported
    if last and fraction < last + PROGRESS_STEP then return end
    -- Nothing said at the very start: the notice that the book is coming has
    -- just been shown, and "0%" underneath it says nothing new.
    if not last and fraction < PROGRESS_STEP then
        self.progress_reported = 0
        return
    end
    self.progress_reported = fraction
    self:notify(("Duo: %s %s · %d%%"):format(
        direction == "sending" and "sending" or "fetching",
        self.book_title or "the book", math.floor(fraction * 100)))
end

--[[--
Stops whatever is being copied, at either end.

The reader's way out. A transfer that turns out to be a bad idea -- the
wrong folder, a book far bigger than it looked, a link too slow to be worth
it -- was previously something to sit through or to disconnect over, and
the whole-library sync had a stop button while a single book had none.

Tells the other device, so the half-written file at its end goes away
rather than waiting out the silence.
--]]--
function Core:cancelTransfer(reason)
    local stopped = false
    local told_peer = false

    --[[
    Said once, and said whenever this device stops taking something in.

    Giving up quietly is not giving up. A device fetching a whole library
    aborted its own half and told the other end nothing, so the other end
    went on sending -- minutes of pushing a large book at somebody who had
    stopped listening. Only two of the four ways to stop ever spoke up, and
    the one a reader actually reaches was not among them.
    ]]
    local function tellPeer()
        if told_peer then return end
        told_peer = true
        local link = self:getReadyLinks()[1]
        if not link then return end
        pcall(function()
            link:send(Protocol.BOOK_ERR, { reason = reason or "stopped on the other device" })
        end)
    end

    if self.library then
        self:stopLibrarySync(reason or "stopped by hand")
        tellPeer()
        stopped = true
    end
    if self.book_sender then
        local transfer = self.book_sender
        pcall(function()
            transfer.link:send(Protocol.BOOK_ERR, { reason = reason or "stopped on the other device" })
        end)
        told_peer = true
        transfer.sender:close()
        self:clearTemporary(transfer)
        self.book_sender = nil
        stopped = true
    end
    if self.book_receiver then
        self.book_receiver:abort()
        self.book_receiver = nil
        tellPeer()
        stopped = true
    end
    if self.book_request then
        tellPeer()
        self.book_request = nil
        stopped = true
    end
    if stopped then
        self.progress_reported = nil
        self:notify(("Duo: %s"):format(reason or "transfer stopped"))
        self:changed()
    end
    return stopped
end

--- Whether there is a transfer to stop.
function Core:isTransferring()
    return self.book_sender ~= nil or self.book_receiver ~= nil
        or self.book_request ~= nil or self.library ~= nil
end

--- "sending 42%" / "receiving 42%", for the status line.
function Core:getTransferProgress()
    if self.book_sender then
        return "sending", self.book_sender.sender:progress()
    end
    if self.book_receiver then
        return "receiving", self.book_receiver:progress()
    end
    return nil
end

--------------------------------------------------------------------------
-- Typography
--------------------------------------------------------------------------

-- How often to look for a typography change the user made here. This is a
-- throttle and nothing more -- it keeps the plugin off the CPU between
-- checks -- so the test suite turns it down to keep its waits short. Nothing
-- but the delay changes: the check itself is the same check.
local TYPOGRAPHY_POLL = tonumber(os.getenv("DUO_TYPOGRAPHY_POLL") or "") or 1.5

function Core:typographyEnabled()
    return self:get("match_typography") and self.reader ~= nil
        and self.reader.getTypography ~= nil
end

--- Sends this device's layout settings to everyone who should have them.
function Core:pushTypography(reason)
    if not self:typographyEnabled() then return end
    local settings = self.reader.getTypography()
    if not settings or not next(settings) then return end
    self.typography_snapshot = settings
    for _, link in ipairs(self:getReadyLinks()) do
        link:send(Protocol.TYPO, settings)
    end
    self:log("pushed typography:", reason)
    -- The book is a different length than it was a moment ago, so the page
    -- everyone should be on has moved too.
    if self:isLeader() then self:broadcastState() end
end

function Core:sendTypographyTo(link)
    if not self:typographyEnabled() then return end
    local settings = self.reader.getTypography()
    if settings and next(settings) then
        self.typography_snapshot = settings
        link:send(Protocol.TYPO, settings)
    end
end

--[[--
Applies the layout settings from the other device.

Whoever sent this is, for the moment, right: on connect that is the leader,
and afterwards it is whichever device the user just changed something on.
The result is that both screens keep breaking lines in the same places.
--]]--
function Core:applyTypography(msg, from_link)
    if not self:typographyEnabled() then return end

    local settings = {}
    for key, value in pairs(msg) do
        if key ~= "type" then settings[key] = value end
    end

    local Typography = require("duo/typography")
    local before = self.reader.getTypography()
    self.applying_typography = true
    local applied = self.reader.applyTypography(settings)
    self.applying_typography = false
    self.typography_snapshot = self.reader.getTypography()

    -- Did everything actually take? If the two devices now agree on every
    -- setting and still paginate differently, the difference is in the
    -- hardware, and that is worth saying; until then it is not.
    self.typography_in_sync = #Typography.differences(self.typography_snapshot, settings) == 0
    self.typography_applied_at = Util.now()

    -- Remember what this device had, but only once and only when something
    -- was really changed. Recording it on every message would capture the
    -- state at the first connection — when nothing had been touched yet —
    -- and would offer an "undo" for a change that never happened.
    if applied and #applied > 0 and not self.typography_backup then
        self.typography_backup = before
    end

    if applied and #applied > 0 then
        self:notify(("Duo: matched %s"):format(Typography.describe(applied)))
        -- Relaying out moves every page number, so the spread has to be
        -- recomputed from wherever the leader ended up.
        self.warned_pagination = false
        if self:isLeader() then
            self:broadcastState()
        elseif from_link then
            -- Every page number in this book just changed. Waiting for the
            -- leader's next broadcast means sitting on the wrong page until
            -- somebody turns one; asking costs a single line.
            from_link:send(Protocol.SYNC, {})
        end
    end
    if applied and applied.missing_font then
        self:alert(("The other device uses a typeface this one does not have (%s), so the pages will not line up.\n\nInstall it here, or pick a font both have."):format(
            tostring(applied.missing_font)))
    end

    -- A change made on a follower has to reach the other followers too, and the
    -- leader is the only device that talks to all of them.
    if self:isLeader() then
        for _, link in ipairs(self:getReadyLinks()) do
            if link ~= from_link then
                link:send(Protocol.TYPO, settings)
            end
        end
    end
end

--- Notices a typography change made on this device and shares it.
function Core:checkTypography()
    if not self:typographyEnabled() or not self:isConnected() then return end
    if self.applying_typography then return end
    local now = Util.now()
    if self.typography_checked_at and now - self.typography_checked_at < TYPOGRAPHY_POLL then
        return
    end
    self.typography_checked_at = now

    local current = self.reader.getTypography()
    if not current or not next(current) then return end
    if not self.typography_snapshot then
        self.typography_snapshot = current
        return
    end

    local Typography = require("duo/typography")
    local changed = Typography.differences(self.typography_snapshot, current)
    if #changed == 0 then return end

    self.typography_snapshot = current
    self:log("typography changed here:", table.concat(changed, ", "))
    if self:isLeader() then
        self:pushTypography("changed on the leader")
        self:broadcastState()
    else
        -- Hand it to the leader, which applies it and passes it on.
        local link = self:getReadyLinks()[1]
        if link then link:send(Protocol.TYPO, current) end
    end
end

--------------------------------------------------------------------------
-- The frontlight
--------------------------------------------------------------------------

function Core:frontlightEnabled()
    return self:get("sync_frontlight")
        and self.hooks ~= nil and self.hooks.getFrontlight ~= nil
end

--- What this device's light is set to, as proportions of its own range.
function Core:frontlightSnapshot()
    if not self:frontlightEnabled() then return nil end
    local ok, snapshot = pcall(self.hooks.getFrontlight)
    if not ok then return nil end
    return snapshot
end

function Core:sendFrontlightTo(link)
    local snapshot = self:frontlightSnapshot()
    if not snapshot then return end
    self.frontlight_snapshot = snapshot
    link:send(Protocol.LIGHT, {
        intensity = snapshot.intensity,
        warmth = snapshot.warmth,
        -- Sent only when this device knows the answer, so a reader whose
        -- driver cannot say does not tell the other one to go dark.
        on = snapshot.on ~= nil and (snapshot.on and 1 or 0) or nil,
    })
end

function Core:pushFrontlight(reason)
    if not self:isConnected() then return end
    local snapshot = self:frontlightSnapshot()
    if not snapshot then return end
    self.frontlight_snapshot = snapshot
    self:log("sharing the frontlight:", reason)
    for _, link in ipairs(self:getReadyLinks()) do
        self:sendFrontlightTo(link)
    end
end

--[[--
Matches the other device's light.

Percentages rather than levels, so a reader with 24 steps and one with 100
mean the same thing by "half". Applying is followed by taking a fresh
snapshot, so the change this device just made to itself is not read back a
moment later as a change somebody made by hand.
--]]--
function Core:applyFrontlight(msg, from_link)
    if not self:frontlightEnabled() then return end
    if not self.hooks.applyFrontlight then return end

    local wanted = {
        intensity = Protocol.num(msg, "intensity"),
        warmth = Protocol.num(msg, "warmth"),
    }
    -- Spelt out rather than folded into the table: `a and false or nil` is
    -- nil, so the one value that matters here would go missing.
    if msg.on ~= nil then
        wanted.on = Protocol.bool(msg, "on")
    end
    self.applying_frontlight = true
    local ok, applied = pcall(self.hooks.applyFrontlight, wanted)
    self.applying_frontlight = false
    self.frontlight_snapshot = self:frontlightSnapshot()

    if ok and applied then
        local Frontlight = require("duo/frontlight")
        self:notify(("Duo: matched %s"):format(Frontlight.describe(applied)))
    end

    -- A change made on a follower has to reach the other followers too.
    if self:isLeader() then
        for _, link in ipairs(self:getReadyLinks()) do
            if link ~= from_link then self:sendFrontlightTo(link) end
        end
    end
end

--[[--
Notices the light being changed on this device and shares it.

Polled rather than hooked: the frontlight is moved by a gesture, a slider,
a profile, the system's own auto-brightness and half a dozen other things,
none of which pass through Duo.
--]]--
function Core:checkFrontlight()
    if not self:frontlightEnabled() or not self:isConnected() then return end
    if self.applying_frontlight then return end
    local now = Util.now()
    if self.frontlight_checked_at and now - self.frontlight_checked_at < TYPOGRAPHY_POLL then
        return
    end
    self.frontlight_checked_at = now

    local current = self:frontlightSnapshot()
    if not current then return end
    local previous = self.frontlight_snapshot
    if not previous then
        self.frontlight_snapshot = current
        return
    end

    local Frontlight = require("duo/frontlight")
    if previous.on == current.on
            and Frontlight.same(previous.intensity, current.intensity)
            and Frontlight.same(previous.warmth, current.warmth) then
        return
    end
    self.frontlight_snapshot = current
    if self:isLeader() then
        self:pushFrontlight("changed on the leader")
    else
        local link = self:getReadyLinks()[1]
        if link then self:sendFrontlightTo(link) end
    end
end

--- Puts back the settings this device had before it ever matched another.
function Core:restoreTypography()
    if not self.typography_backup or not self.reader or not self.reader.applyTypography then
        return false
    end
    self.applying_typography = true
    self.reader.applyTypography(self.typography_backup)
    self.applying_typography = false
    self.typography_snapshot = self.reader.getTypography()
    self.typography_backup = nil
    return true
end

function Core:hasTypographyBackup()
    return self.typography_backup ~= nil
end

--------------------------------------------------------------------------
-- Incoming messages
--------------------------------------------------------------------------

function Core:handleMessage(link, msg)
    if msg.type == Protocol.STATE then
        if self:isLeader() then return end -- only the leader decides
        self.leader_page = Protocol.num(msg, "leader_page")
        self:checkPagination(Protocol.num(msg, "pages"), msg.typo)
        self:applyRemotePage(Protocol.num(msg, "page"),
            Protocol.num(msg, "pages"), msg.typo)
        self:noteShortBook(Protocol.bool(msg, "beyond"), Protocol.num(msg, "pages"))
    elseif msg.type == Protocol.TURN then
        if not self:isLeader() then return end
        if not self:get("follower_can_turn") then return end
        self:applyRelativeTurn(Protocol.num(msg, "dir", 1))
    elseif msg.type == Protocol.GOTO then
        if not self:isLeader() then return end
        if not self:get("follower_can_turn") then return end
        self:applyRemoteJump(link, Protocol.num(msg, "page"))
    elseif msg.type == Protocol.NAP then
        self:handleNap(msg)
    elseif msg.type == Protocol.SYNC then
        if not self:isLeader() then return end
        self:sendDocumentTo(link)
        --[[
        Typography before the page, and never left out.

        A follower asks for this the moment it finishes opening a book, which
        is the one time it is certain to need it: the layout settings sent
        when the link came up arrived while this device was still in the
        file list with no book to apply them to, and were dropped. Leaving
        them out here is what let two devices sit at different font sizes
        until somebody changed one by hand.
        ]]
        self:sendTypographyTo(link)
        self:sendFrontlightTo(link)
        self:sendStateTo(link)
        self:sendBrowserTo(link)
    elseif msg.type == Protocol.TYPO then
        self:applyTypography(msg, link)
    elseif msg.type == Protocol.CONF then
        self:applySettings(msg, link)
    elseif msg.type == Protocol.LIGHT then
        self:applyFrontlight(msg, link)
    elseif msg.type == Protocol.BROWSE then
        self:applyBrowser(msg)
    elseif msg.type == Protocol.BTURN then
        if self:isLeader() and self:get("follower_can_turn") then
            self:applyBrowserTurn(Protocol.num(msg, "dir", 1))
        end
    elseif msg.type == Protocol.LIB_REQ then
        self:handleLibraryRequest(link, msg)
    elseif msg.type == Protocol.LIB_ITEM then
        self:handleLibraryItem(msg)
    elseif msg.type == Protocol.LIB_END then
        self:handleLibraryEnd(msg)
    elseif msg.type == Protocol.BOOK_REQ then
        self:handleBookRequest(link, msg)
    elseif msg.type == Protocol.BOOK_HEAD then
        self:handleBookHead(msg)
    elseif msg.type == Protocol.BOOK_DATA then
        self:handleBookData(msg)
    elseif msg.type == Protocol.BOOK_DONE then
        self:handleBookDone()
    elseif msg.type == Protocol.BOOK_ERR then
        self:handleBookError(msg)
    elseif msg.type == Protocol.DOC then
        if self:isLeader() then return end
        self:handleRemoteDocument(msg)
    elseif msg.type == Protocol.DOCACK then
        if not self:isLeader() then return end
        self:handleDocumentAck(link, msg)
    elseif msg.type == Protocol.HOME then
        if self:isLeader() then return end
        self:handleRemoteHome()
    elseif msg.type == Protocol.OPEN then
        if not self:isLeader() then return end
        self:handleRemoteOpen(msg)
    elseif msg.type == Protocol.GOHOME then
        if not self:isLeader() then return end
        self:handleRemoteHomeRequest()
    elseif msg.type == Protocol.SLEEP then
        self:handleRemoteSleep()
    elseif msg.type == Protocol.NOTE then
        self:notify(msg.text or "")
    end
end

--- Opens the book the leader is reading, when we are not already in it.
--- How long a follower's request to come out of a book is given to land.
local HOME_REQUEST_GRACE = 10

--[[--
Tells the leader what became of the book it named.

Three answers, and the difference matters. "Open" and "no" are both final --
the leader stops asking, and in the second case has something to tell the
reader. "Opening" is neither: it pushes the leader's wait back rather than
ending it, because opening a book on an e-reader takes long enough that a
device working away at one would otherwise be asked again mid-way.
--]]--
function Core:sendDocumentAck(state, file, reason)
    local link = self:getReadyLinks()[1]
    if not link then return end
    link:send(Protocol.DOCACK, {
        state = state,
        file = file or "",
        reason = reason or "",
    })
end

function Core:handleRemoteDocument(msg)
    local file = msg.file
    if not self:get("follow_document") then
        -- Silence would have the leader ask again twice more for something
        -- this device has been told not to do.
        self:sendDocumentAck("no", file, "not following the other device")
        return
    end
    if not file or file == "" then return end
    -- Asked to come out a moment ago, and this is the leader describing the
    -- book it has not closed yet. Following it now would undo the request.
    if self.asked_home_at and Util.now() - self.asked_home_at < HOME_REQUEST_GRACE then
        return
    end
    local document = self.reader and self.reader.getDocument() or nil
    if document then
        local same = (document.file == file)
            or (msg.digest ~= "" and document.digest == msg.digest)
        if same then
            self:checkPagination(Protocol.num(msg, "pages"), msg.typo)
            self:sendDocumentAck("open", file)
            return
        end
    end
    if not self.hooks or not self.hooks.openDocument then
        self:sendDocumentAck("no", file, "this device cannot open books")
        return
    end
    -- Opening a book is slow and very visible, so never start the same one
    -- twice because two messages arrived close together.
    if self.opening_file == file and Util.now() - (self.opening_since or 0) < 15 then
        -- Already working on exactly this. Saying so is what stops the
        -- leader asking again while the book is still coming up.
        self:sendDocumentAck("opening", file)
        return
    end
    self.opening_file = file
    self.opening_since = Util.now()
    self:sendDocumentAck("opening", file)
    self:notify(("Duo: opening %s"):format(msg.title ~= "" and msg.title or file))
    self.hooks.openDocument(file, msg)
end

--[[--
Takes a device's answer about the book it was told to open.

"Opening" pushes the wait back without spending an attempt: a device that is
working on a book should be left to finish, not asked again half way up.
Anything final ends the matter, and a device that cannot open the book says
so plainly rather than leaving the pair to work it out from silence.
--]]--
function Core:handleDocumentAck(link, msg)
    local pending = link.doc_pending
    if not pending then return end
    local state = msg.state or ""
    if state == "opening" then
        pending.sent_at = Util.now()
        return
    end
    link.doc_pending = nil
    if state == "no" then
        local why = msg.reason ~= "" and msg.reason or "it does not have the book"
        self:log("the other device will not open", pending.file, "-", why)
        self:notify(("Duo: the other device is not following into this book (%s)"):format(why))
    end
end

--[[--
Asks again when a device never said what became of the book.

Opening a book used to be announced once and hoped for. A message that
landed while the other device was between documents, or rebuilding its
plugin, or otherwise in no state to act, was simply lost -- and the pair sat
in two different books with nothing to put it right short of turning a page.
--]]--
function Core:checkDocumentAcks()
    if not self:isLeader() or not self.reader then return end
    local now = Util.now()
    for _, link in ipairs(self:getReadyLinks()) do
        local pending = link.doc_pending
        if pending and now - pending.sent_at >= DOC_ACK_WAIT then
            if pending.attempts >= DOC_ACK_TRIES then
                link.doc_pending = nil
                self:log("gave up telling the other device about", pending.file)
                self:notify("Duo: the other device never opened the book")
            else
                --[[
                Sent again rather than merely counted. The whole point is
                that the first one may never have been acted on, and the
                receiving side is built to recognise a book it is already in
                or already opening -- so asking twice costs nothing when the
                first did arrive.
                ]]
                pending.attempts = pending.attempts + 1
                pending.sent_at = now
                self:log("asking again about", pending.file,
                    ("(attempt %d)"):format(pending.attempts))
                self:sendDocumentTo(link)
                -- sendDocumentTo starts a fresh note; keep the count going.
                if link.doc_pending then
                    link.doc_pending.attempts = pending.attempts
                end
            end
        end
    end
end

--[[--
Follows the leader out of a book and back to the list.

The spread is a pair of screens showing one thing, and that has to hold for
the book list as much as for the book: a leader that has closed its book
and a follower still sitting in one is not a spread, it is two devices doing
different things. Going in was already followed; this is coming back out.
--]]--
function Core:handleRemoteHome()
    self.asked_home_at = nil
    if not self:get("follow_document") then return end
    if not self.reader then return end        -- already out of the book
    if not self.hooks or not self.hooks.closeDocument then return end
    self.opening_file = nil
    self:notify("Duo: back to the book list")
    self.hooks.closeDocument()
end

--[[--
Opens, for the whole pair, a book the user tapped on a follower.

The follower may turn pages, so it would be strange if it could not start one.
It cannot simply open the book itself, though: the leader owns the page
number, and a follower that went off and opened something on its own would
leave the two devices in different books. So the tap is forwarded, the
leader opens it, and the leader's own DOC brings the follower along — the same
path as if the leader had been tapped.
--]]--
--[[--
Asks the leader to take the pair back to the book list.

The counterpart of a follower opening a book. It cannot simply close its
own: the leader owns what the pair is reading, and a follower that walked
out on its own would be told to come back the moment the leader mentioned
its document again. So it asks, the leader closes, and the leader's own
HOME brings this device out -- the same path as if the leader had been the
one to close the book.
--]]--
function Core:requestHome()
    if not self:isActive() or self:isLeader() then return false end
    if not self:get("follow_document") then return false end
    local link = self:getReadyLinks()[1]
    if not link then return false end
    -- Remembered so the leader's answer to the SYNC sent a moment ago --
    -- which still describes the book it has not closed yet -- cannot drag
    -- this device back in before the leader has caught up.
    self.asked_home_at = Util.now()
    link:send(Protocol.GOHOME, {})
    return true
end

--- Closes the leader's book because a follower left the list.
function Core:handleRemoteHomeRequest()
    if not self:isLeader() or not self:get("follow_document") then return end
    if not self.reader then return end        -- already out of the book
    if not self.hooks or not self.hooks.closeDocument then return end
    self.opening_file = nil
    self:notify("Duo: back to the book list")
    self.hooks.closeDocument()
end

function Core:requestOpen(file, title)
    if not self:isActive() or self:isLeader() then return false end
    -- Going back into a book is the opposite of asking to come out of one.
    self.asked_home_at = nil
    if not self:get("follow_document") then return false end
    if not self:get("follower_can_turn") then return false end
    local link = self:getReadyLinks()[1]
    if not link then return false end
    link:send(Protocol.OPEN, { file = file, title = title or "" })
    self:log("asked the leader to open", file)
    return true
end

function Core:handleRemoteOpen(msg)
    if not self:get("follower_can_turn") then return end
    local file = msg.file
    if not file or file == "" then return end
    -- Already reading it: the follower is only catching up, so say so rather
    -- than reopening the book underneath the person holding it.
    local document = self.reader and self.reader.getDocument() or nil
    if document and document.file == file then
        self:broadcastDocument()
        self:broadcastState()
        return
    end
    if not self.hooks or not self.hooks.openDocument then return end
    self:notify(("Duo: opening %s"):format(msg.title ~= "" and msg.title or file))
    self.hooks.openDocument(file, msg)
end

--[[--
Puts this device to sleep because the other one is going.

Two readers held side by side are one thing to their owner: locking the one
in your right hand and finding the left still lit, still burning battery
and still holding a page nobody is reading, is not what "a spread" should
mean. Whichever device is locked, both go.
--]]--
function Core:announceSleep()
    if not self:isActive() then return end
    self.sleep_announced_at = Util.now()
    for _, link in ipairs(self:getReadyLinks()) do
        link:send(Protocol.SLEEP, {})
    end
end

--[[--
Follows the other device to sleep, when there is anything to follow.

Sleeping a Kindle is not "go to sleep" — KOReader asks its power daemon to
*press the power button*, and a press is a toggle. Press it on a device
already asleep and it wakes up. So this has to be certain the device is
awake and not on its way out before touching anything, which is three
separate refusals rather than one:

  * one already following an order does not need a second;
  * one that just announced its own sleep is not being told anything it
    did not already know — that is two people reaching for two power
    buttons at the same moment, and relaying it would wake the device that
    got there first;
  * and one already asleep must never be prodded, since the prod is
    exactly what wakes it.
--]]--
function Core:handleRemoteSleep()
    if not self:get("sleep_together") then return end
    if self.sleeping_for_peer then return end
    if self.sleep_announced_at and Util.now() - self.sleep_announced_at < SLEEP_RACE then
        self:log("we were going to sleep anyway; not passing that on")
        return
    end
    if not self.hooks or not self.hooks.sleepDevice then return end
    -- Marked before asking, so that suspending does not bounce a SLEEP
    -- straight back at the device that sent one.
    self.sleeping_for_peer = true
    self:log("following the other device to sleep")
    pcall(self.hooks.sleepDevice)
end

--[[--
Warns once when the two devices do not paginate the book identically.

Only when there is something to be done about it. With typography matching
on, a mismatch at the moment of connecting is expected and about to be
fixed, so saying anything would be noise; the warning is held back until
the settings are known to agree and the relayout has settled. If the pages
still do not line up then, the difference is in the screens themselves,
which no setting can fix — and that is worth saying.
--]]--
--- This device's layout as a short string, for comparing with the other's.
function Core:typographySignature()
    if not self.reader or not self.reader.getTypography then return nil end
    local ok, snapshot = pcall(self.reader.getTypography)
    if not ok or not snapshot then return nil end
    return require("duo/typography").signature(snapshot)
end

--[[--
Warns when the two devices paginate the same book differently.

@int leader_pages  how many pages the leader says the book has
@string[opt] leader_typo  the leader's layout fingerprint, when it sent one
--]]--
function Core:checkPagination(leader_pages, leader_typo)
    if self.warned_pagination or not leader_pages or leader_pages == 0 then return end
    if not self.reader then return end
    local own_pages = self.reader.getPageCount()
    if not own_pages or own_pages == leader_pages then return end

    if self:get("match_typography") then
        -- Nothing to say until matching has actually happened.
        if not self.typography_in_sync then return end
        --[[
        The page counts are being compared against settings that may not be
        the ones that produced them. Change the font size on the leader and
        it repaginates at once, but Duo only notices a moment later, so the
        new page count arrives here while both devices still hold the old
        settings — and complaining then means complaining about a difference
        that is about to fix itself.

        The fingerprint settles it: the leader stamps each page count with
        the layout that produced it, so "we disagree because the settings
        differ" and "we disagree even though they match" stop looking alike.
        Only the second is worth saying, and only it gets said.
        ]]
        local own_typo = self:typographySignature()
        if leader_typo and leader_typo ~= "" and own_typo and own_typo ~= ""
                and leader_typo ~= own_typo then
            return
        end
        if self.typography_applied_at
                and Util.now() - self.typography_applied_at < PAGINATION_SETTLE then
            return
        end
        --[[
        And the count itself has to have stopped moving. Relaying out a
        real book is not instant: crengine keeps handing back the old
        length for a while afterwards, so a page count read too early says
        the devices disagree when all it means is that this one has not
        finished. Every change to our own length restarts the clock.
        ]]
        if own_pages ~= self.last_own_pages then
            self.last_own_pages = own_pages
            self.own_pages_changed_at = Util.now()
            return
        end
        if Util.now() - (self.own_pages_changed_at or 0) < PAGINATION_SETTLE then
            return
        end
        self.warned_pagination = true
        self:alert(("Both devices lay this book out with the same settings, yet it comes to %d pages here and %d on the leader.\n\nThat is usually the screens themselves, which cannot be matched, so the spread will drift apart."):format(
            own_pages, leader_pages))
    else
        self.warned_pagination = true
        self:alert(("This device paginates the book differently (%d pages here, %d on the leader), so the spread will not line up.\n\nTurn on \"Match typography\", or set the same font, size, spacing and margins on both."):format(
            own_pages, leader_pages))
    end
end

--------------------------------------------------------------------------
-- Status, for the menu
--------------------------------------------------------------------------

function Core:getStatusText()
    if not self:isActive() then
        return "Off"
    end
    local direction, progress = self:getTransferProgress()
    if self.library and self.library.total then
        -- How far into this book as well as which book. Without the
        -- percentage a long copy says the same words for minutes together,
        -- which reads as a device that has stopped rather than one working.
        local into = progress and (" · %d%%"):format(math.floor(progress * 100)) or ""
        return ("Fetching books · %d of %d%s"):format(
            (self.library.done or 0) + 1, self.library.total, into)
    end
    if direction then
        return ("%s %s · %d%%"):format(
            direction == "sending" and "Sending" or "Receiving",
            self.book_title or "a book", math.floor((progress or 0) * 100))
    end
    if self:isLeader() then
        local ready = self:getReadyLinks()
        if #ready == 0 then
            if self:usesSerial() then
                return ("Leader · waiting on %s"):format(self:get("serial_device"))
            end
            local address = NetUtil.getLocalIP()
            return ("Leader · waiting on %s:%d"):format(address or "this device", self:get("port"))
        end
        local names = {}
        for _, link in ipairs(ready) do
            names[#names+1] = link.peer_name or "follower"
        end
        local pages = ""
        if self.reader then
            pages = " · pages " .. Spread.describeLayout(self.reader.getPage(), #ready, self:getSpreadOptions())
        end
        return ("Leader · %s%s"):format(table.concat(names, ", "), pages)
    end
    local link = self:getReadyLinks()[1]
    if link then
        local page = self.reader and self.reader.getPage()
        return ("Follower · following %s%s"):format(
            link.peer_name or "leader",
            page and (" · page " .. page) or "")
    end
    if self.reconnect_at then
        local seconds = math.max(0, math.ceil(self.reconnect_at - Util.now()))
        return ("Follower · retrying in %ds%s"):format(seconds,
            self.last_error and (" (" .. self.last_error .. ")") or "")
    end
    if self:usesSerial() then
        return ("Follower · listening on %s…"):format(self:get("serial_device"))
    end
    return ("Follower · connecting to %s…"):format(self:get("peer_host"))
end

--------------------------------------------------------------------------
-- Sleep
--------------------------------------------------------------------------

--- Called when the device is about to suspend. The sockets will not survive
-- it, so they are shut down deliberately instead of timing out noisily on
-- the other device; the role is remembered for the wake-up.
function Core:suspend()
    if not self:isActive() then return end
    local role = self.role
    -- Before the sockets go: the other device should be locking too, and
    -- there is no way to tell it once the link is gone. Not when this
    -- device is only doing as it was told, or the two would take turns
    -- waking each other to say goodnight.
    if self:get("sleep_together") and not self.sleeping_for_peer then
        self:announceSleep()
    end
    self:stop("the other device went to sleep")
    self.paused_role = role
    self.settings.autostart_role = role
    self:save()
end

--[[--
Called on wake-up, and whenever the network comes back.

Waking up is not the same as being ready. A device that has been asleep for
a while comes back with its Wi-Fi still down: the interface has no address,
a link-local cell has not re-formed, and binding a socket to any of that
fails. This used to be a single attempt whose failure was permanent — the
role was cleared, the leader's listen failed, an alert went up and nothing
ever tried again, which is why a long sleep needed a disconnect and
reconnect by hand while a short one did not.

So the role is kept until a start actually succeeds, and the attempt is
repeated from the poll loop. Quietly: this is the expected state of things
for the first few seconds after waking, not something to interrupt reading
with.
--]]--
function Core:resume()
    self.sleeping_for_peer = false
    self.sleep_announced_at = nil
    -- Checked whatever happens next, and that is the point: see checkLink.
    -- Not conditional on the setting: whether this is a link Duo has to
    -- look after is the plugin's question, and it can answer it without a
    -- setting having been recorded.
    self.link_check_at = Util.now() + LINK_CHECK_DELAY
    if not self.paused_role then return end
    self.resume_attempts = 0
    self.resume_at = 0      -- try immediately; the poll loop takes it from there
    self:checkResume()
end

--[[--
Keeps trying to come back up after a sleep.

Runs while Duo is off, which is the whole point: nothing else in the poll
loop does.
--]]--
function Core:checkResume()
    local role = self.paused_role
    if not role then return end
    if self.role ~= Core.ROLE_OFF then
        -- Started some other way in the meantime; nothing left to resume.
        self.paused_role = nil
        return
    end
    local now = Util.now()
    if self.resume_at and now < self.resume_at then return end

    self.resume_attempts = (self.resume_attempts or 0) + 1
    -- Cleared before trying rather than after: start() stops first, and
    -- stopping cancels a pending resume. Put back when the attempt fails.
    self.paused_role = nil
    if self:start(role, { quiet = true }) then
        self:log("came back after", self.resume_attempts, "attempt(s)")
        return
    end
    self.paused_role = role

    if self.resume_attempts >= RESUME_MAX_ATTEMPTS then
        self.paused_role = nil
        self:alert(("Duo could not start again after waking up.\n\n%s\n\nReconnect the two devices when the network is back."):format(
            tostring(self.last_error or "the network did not come back")))
        return
    end
    self.resume_at = now + RESUME_RETRY
end

--[[--
Rebuilds a link Duo made itself, when a sleep has taken it away.

Separate from the resume retry, and deliberately so. A link with no router
behind it does not survive a deep sleep — the reader's own Wi-Fi daemon
takes the interface back and puts it in managed mode — and this used to be
attempted only after starting Duo had failed several times. On a follower
that worked. On a leader it never ran at all: starting a leader means
binding a listening socket, `socket.bind` binds every interface, and binding
every interface succeeds perfectly well when there are no interfaces worth
having. So the leader came up believing itself fine, sat there with its
radio back in managed mode and no address, and the follower reconnected into
silence for as long as anyone cared to wait.

So it is checked on both, on the way back from every sleep, whether or not
anything failed.
--]]--
function Core:checkLink()
    if not self.link_check_at then return end
    if Util.now() < self.link_check_at then return end
    self.link_check_at = nil
    if not self.hooks or not self.hooks.reviveDirectLink then return end
    self:log("checking the direct link survived the sleep")
    local ok, outcome = pcall(self.hooks.reviveDirectLink, true)
    if ok and outcome == "rebuilt" then self:dialNow() end
end

--[[--
Notices a link that has quietly gone, whether or not anything said so.

The counterpart to checkLink, and the one that does not depend on being
told. A device that has been disconnected for a while, on a link it built
itself, has one of two problems: the other reader is away, or the network
underneath them both is gone. The first needs no action and the second will
never fix itself, and telling them apart costs a single status call — so it
is worth making, over and over, rather than waiting for an event that may
not arrive on every firmware.

This is what a design like PagePair's gets for nothing by opening a fresh
connection per page turn: there is no link to lose. Duo needs a stream —
for the heartbeat, the typography, a book on its way across — so instead it
keeps checking that the stream still has somewhere to be.
--]]--
function Core:checkLinkHealth()
    if not self:isActive() then return end
    if self:isConnected() then
        self.disconnected_since = nil
        self.has_connected = true
        return
    end
    local now = Util.now()
    self.disconnected_since = self.disconnected_since or now
    -- A link that has worked and stopped is broken now; one that has never
    -- worked is probably still being set up by somebody.
    local patience = self.has_connected and LINK_HEAL_AFTER or LINK_HEAL_FIRST
    if now - self.disconnected_since < patience then return end
    if self.link_healed_at and now - self.link_healed_at < LINK_HEAL_EVERY then return end
    self.link_healed_at = now
    if not self.hooks or not self.hooks.reviveDirectLink then return end
    --[[
    Forced, not checked. Running the setup script by hand fixes this every
    time, and the only difference between that and what happens here is
    that the script does not first ask itself whether the work is needed.
    Once the two have been unable to reach each other for this long, a link
    that still looks well plainly is not, and asking can only talk us out
    of the one thing that works. Rebuilding a link nobody is using costs a
    few seconds; not rebuilding it costs the feature.
    ]]
    self:log("apart for a while; rebuilding the link rather than asking after it")
    local ok, outcome = pcall(self.hooks.reviveDirectLink, true, true)
    if ok and outcome == "rebuilt" then self:dialNow() end
end

--[[--
Tries the other device again straight away.

The network was just put back, so whatever the backoff had grown to is
about a link that no longer exists. Waiting it out after fixing the very
thing it was backing off from is how several seconds got added to every
recovery.
--]]--
function Core:dialNow()
    self.reconnect_delay = RECONNECT_MIN
    if self:isFollower() and not self.connector then
        self.reconnect_at = 0
    end
end

--- Object handed to UIManager so the sockets get polled by the UI loop.
function Core:getPoller()
    if not self.poller then
        local core = self
        self.poller = {
            -- UIManager iterates waitEvent() until it returns nil; we do our
            -- work and return nil so the loop moves on immediately.
            waitEvent = function()
                local ok, err = pcall(function() core:poll() end)
                if not ok then
                    core:log("poll error:", err)
                end
                return nil
            end,
            stop = function() end,
        }
    end
    return self.poller
end

return Core
