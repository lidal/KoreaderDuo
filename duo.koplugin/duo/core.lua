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
    role = "off",              -- "off" | "master" | "slave"
    links = {},                -- master: one per slave. slave: at most one.
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
Core.ROLE_MASTER = "master"
Core.ROLE_SLAVE = "slave"

--- Reconnection backoff, in seconds.
local RECONNECT_MIN = 1
local RECONNECT_MAX = 15

--- How long a book may go without a byte before it is written off, in
--- seconds. Generous: a slow link is not the same as a dead one.
local BOOK_SILENCE = 30

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
--- Attempts before a link this device built itself is presumed lost.
local RESUME_REVIVE_AFTER = 3

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
    slave_can_turn = true,
    follow_document = true,
    match_typography = true,
    share_browser = true,
    sleep_together = true,
    sync_frontlight = true,
    sync_books = true,
    sync_library = true,
    covers_first = true,
    max_book_mb = 64,
    max_library_mb = 512,
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
function Core:configure(options)
    self.hooks = options.hooks or self.hooks or {}
    if not self.settings then
        self.settings = options.settings or {}
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
turn on the slave counts, whether the book list is shared, how big a
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
    "slave_can_turn",
    "follow_document",
    "match_typography",
    "share_browser",
    "sleep_together",
    "sync_books",
    "sync_library",
    "covers_first",
    "sync_frontlight",
    "max_book_mb",
    "max_library_mb",
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

The master tells everyone. A slave can only ask: it hands the change to the
master, which applies it and passes it on, so there is one account of what
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

On connect this arrives from the master and the master wins, which is what
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
        if self:isMaster() then
            -- A change made on a slave has to reach the other slaves, and
            -- the master is the only device that talks to all of them.
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
    self.opening_file = nil -- whatever we were opening has now arrived
    -- A different document has its own typography; nothing carries over.
    self.typography_snapshot = nil
    self.typography_checked_at = nil
    self.typography_backup = nil
    self:changed()
    if not self:isActive() then return end
    if self:isMaster() then
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

function Core:isMaster()
    return self.role == Core.ROLE_MASTER
end

function Core:isSlave()
    return self.role == Core.ROLE_SLAVE
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
    if self:isMaster() then
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

function Core:slaveCount()
    if self:isMaster() then return #self:getReadyLinks() end
    return self:isConnected() and 1 or 0
end

--- How many pages one turn should move the master.
function Core:getStep()
    if not self:isActive() or not self:isConnected() then return 1 end
    return Spread.stepFor(self:get("mode"), self:slaveCount())
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

@string role Core.ROLE_MASTER or Core.ROLE_SLAVE
@tparam[opt] table options host and port for a slave
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
and the master starts talking. Whoever gets there first waits for the other.
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
    self:adoptStream(stream, self:isMaster())
    self:changed()
    return true
end

function Core:start(role, options)
    options = options or {}
    self:stop("restarting")

    self:ensureToken()
    self.last_error = nil
    self.reconnect_delay = RECONNECT_MIN
    -- Starting is something an awake device does, so whatever this was
    -- following the other one into is over.
    self.sleeping_for_peer = false

    if self:usesSerial() then
        if role ~= Core.ROLE_MASTER and role ~= Core.ROLE_SLAVE then return false end
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

    if role == Core.ROLE_MASTER then
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
        self.role = Core.ROLE_MASTER
        self:log("started as master on port", port)
    elseif role == Core.ROLE_SLAVE then
        local host = tostring(options.host or self:get("peer_host") or ""):gsub("%s", "")
        local port = options.port or self:get("peer_port")
        if host == "" then
            if not options.quiet then
                self:alert("No master address yet. Search for one, or type its address.")
            end
            return false
        end
        -- Refuse an address we cannot reach *before* saving it, so a typo
        -- does not become a reconnect loop against a host that never existed.
        local resolved = NetUtil.resolve(host)
        if not resolved then
            self.last_error = ("no device answers to %s"):format(host)
            if not options.quiet then
                self:alert(("No device answers to \"%s\".\n\nCheck the address shown on the master."):format(host))
            end
            return false
        end
        host = resolved
        self.settings.peer_host = host
        self.settings.peer_port = port
        self:save()
        self.role = Core.ROLE_SLAVE
        self:beginConnect()
        self:log("started as slave, dialing", host, port)
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
Starts looking for a master on the network.

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
    if self.role == Core.ROLE_OFF then return end

    if self.responder then self.responder:poll() end

    if self:usesSerial() then
        -- One line, one link: reopen it when it has gone away.
        if #self.links == 0 and self.reconnect_at and Util.now() >= self.reconnect_at then
            self:openSerialLink()
        end
    else
        if self:isMaster() and self.server then
            while true do
                local stream = self.server:accept()
                if not stream then break end
                self:adoptStream(stream, true)
            end
        end

        if self:isSlave() then
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
    self:checkBrowser()
    self:pumpBookSender()
    self:checkBookRequest()
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
        self:pumpLibrary()
        return
    end
    self:alert(("Duo could not fetch %s: the other device stopped sending."):format(
        request.title ~= "" and request.title or "the book"))
end

--- Wraps a freshly opened stream in an authenticated link.
-- @tparam table stream anything with send / receive / close
-- @bool is_master true when this device drives the handshake
function Core:adoptStream(stream, is_master)
    local link
    link = Link.new{
        stream = stream,
        is_master = is_master,
        token = self:get("token"),
        name = self:getDeviceName(),
        slot = is_master and self:nextFreeSlot() or 1,
        on_message = function(_, msg) self:handleMessage(link, msg) end,
        on_ready = function() self:onLinkReady(link) end,
        on_close = function(_, reason) self:onLinkClosed(link, reason) end,
    }
    self.links[#self.links+1] = link
    return link
end

--- Lowest slave index not currently taken, so a reconnecting device lands
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
    if self:isMaster() then
        -- The master pushes; the slave does not need to ask. Asking as well
        -- would have it told twice, and a second DOC can mean opening the
        -- same book twice.
        -- Settings first of all: they decide whether the rest of this is
        -- wanted at all, and the master is the tiebreaker when the two
        -- devices were configured differently.
        self:sendSettingsTo(link)
        self:sendDocumentTo(link)
        -- Typography before the page: the layout decides what page numbers
        -- even mean, so sending the page first would only move it twice.
        self:sendTypographyTo(link)
        self:sendFrontlightTo(link)
        self:sendStateTo(link)
        self:broadcastBrowser()
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
    if self:isActive() and (self:isSlave() or self:usesSerial()) then
        self:scheduleReconnect()
    end
    self:changed()
end

--------------------------------------------------------------------------
-- Talking about pages
--------------------------------------------------------------------------

function Core:sendStateTo(link)
    if not self.reader then return end
    local master_page = self.reader.getPage()
    if not master_page then return end
    local options = self:getSpreadOptions()
    local page, clamped = Spread.pageForSlot(master_page, link.slot, options)
    link:send(Protocol.STATE, {
        page = page,
        master_page = master_page,
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
    if not self:isMaster() then return end
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
    link:send(Protocol.DOC, {
        file = document.file,
        title = document.title or "",
        digest = document.digest or "",
        pages = self.reader.getPageCount() or 0,
        typo = self:typographySignature(),
    })
end

function Core:broadcastDocument()
    if not self:isMaster() then return end
    for _, link in ipairs(self:getReadyLinks()) do
        self:sendDocumentTo(link)
    end
end

--------------------------------------------------------------------------
-- Page turns
--------------------------------------------------------------------------

--[[--
Handles a relative page turn the user made on this device.

On the master this moves the whole spread: one turn advances by as many
pages as there are devices. On a connected slave the turn is forwarded to
the master instead of being applied locally, so the two screens can never
drift apart — the master remains the only thing that decides what is shown.

@number diff pages to turn, normally 1 or -1
@treturn boolean true when Duo handled it and the reader should not
--]]--
function Core:handleRelativeTurn(diff)
    if not self:isActive() or not self:isConnected() then return false end
    if self:isMaster() then
        self:applyRelativeTurn(diff)
        return true
    end
    if not self:get("slave_can_turn") then
        -- Reading on the slave should not move the pair: ignore the tap
        -- rather than letting this screen drift out of the spread.
        return true
    end
    local link = self:getReadyLinks()[1]
    if not link then return false end
    link:send(Protocol.TURN, { dir = diff })
    return true
end

--- Moves the master by `diff` spreads. The page change is broadcast by
-- whatever the reader reports afterwards, via onPageChanged.
function Core:applyRelativeTurn(diff)
    if not self.reader then return end
    local step = self:getStep()
    self.reader.turnRelative(diff * step)
end

--- Called by the plugin whenever this device's page changed, for any reason.
function Core:onPageChanged(page)
    if not self:isActive() then return end
    if self.applying_remote then return end
    if self:isMaster() then
        self:broadcastState()
    else
        self:changed()
    end
end

--- Applies a page the master told us to show.
function Core:applyRemotePage(page)
    if not self.reader or not page then return end
    if self.reader.getPage() == page then return end
    self.applying_remote = true
    local ok, err = pcall(self.reader.gotoPage, page)
    self.applying_remote = false
    if not ok then
        self:log("could not go to page", page, err)
    end
    self:changed()
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
    if self:isActive() and self:isMaster() then
        --[[
        The file manager appearing on the master is the moment the book was
        closed, and a better signal than the reader going away: switching
        straight from one book to another tears a reader down too, and a
        slave told to go home then would close the book it is about to be
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

--- Sends one device the page of the listing it should be showing.
function Core:sendBrowserTo(link)
    if not self:isMaster() or not self.browser then return end
    if not self:get("share_browser") then return end
    local state = self.browser.getState()
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
        page = page,
        master_page = state.page,
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
    if self:isMaster() then self:noteActivity() end
    for _, link in ipairs(self:getReadyLinks()) do
        self:sendBrowserTo(link)
    end
    self:changed()
end

--- Shows the part of the listing the master allotted to this device.
function Core:applyBrowser(msg)
    if not self.browser or not self:get("share_browser") then return end
    if self:isMaster() then return end

    self.applying_remote = true
    -- Same folder first: a page number means nothing until the two devices
    -- are looking at the same list.
    local path = msg.path
    if path and path ~= "" and not self.browser.changeDir(path) then
        self.applying_remote = false
        if not self.warned_listing then
            self.warned_listing = true
            self:alert(("The other device is browsing a folder this one does not have:\n\n%s"):format(path))
        end
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

    self:reconcileLibrary(msg)
    self:checkListing(msg)
    self:changed()
end

--- Fetches whatever is missing when the two folders do not match.
function Core:reconcileLibrary(msg)
    if not self:get("sync_library") or self:isMaster() then return end
    if self.library or not self.browser then return end
    local state = self.browser.getState()
    if not state then return end
    local their_count = Protocol.num(msg, "count")
    local their_signature = msg.sig
    local differs = (their_count and their_count ~= state.count)
        or (their_signature and their_signature ~= "" and state.signature
            and their_signature ~= state.signature)
    if differs then
        self:requestLibrary(state.path)
    end
end

--[[--
Warns once when the two devices are not looking at the same list.

Nothing is said while books are on their way over: the mismatch is exactly
what the library sync is busy repairing, and the next listing after it
finishes will either match or be worth complaining about.
--]]--
function Core:checkListing(msg)
    if self.warned_listing or not self.browser then return end
    if self:isSyncingLibrary() then return end
    local state = self.browser.getState()
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

    if self:isMaster() then
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
    if self:isMaster() then return end
    self.peer_napping = Protocol.bool(msg, "sleep")
    self:log(self.peer_napping and "the other device is dozing off"
        or "the other device is back")
    self:updateAwake()
    self:changed()
end

--[[--
Handles a swipe through the listing.

The master steps by as many screenfuls as there are devices; a slave asks
the master to do it, exactly as with a page turn in a book.

@treturn boolean true when Duo handled it and the browser should not
--]]--
function Core:handleBrowserTurn(diff)
    if not self:browsingTogether() then return false end
    if self:isMaster() then
        self:applyBrowserTurn(diff)
        return true
    end
    if not self:get("slave_can_turn") then return true end
    local link = self:getReadyLinks()[1]
    if not link then return false end
    link:send(Protocol.BTURN, { dir = diff })
    return true
end

function Core:applyBrowserTurn(diff)
    if not self.browser then return end
    local state = self.browser.getState()
    if not state then return end
    local step = Spread.stepFor(self:get("mode"), self:slaveCount())
    -- Clamped rather than wrapped: cycling round to the first page would
    -- put the devices on unrelated parts of the list.
    local target = Util.clamp(state.page + diff * step, 1, state.pages)
    self.browser.goToPage(target)
    self:broadcastBrowser()
end

--- Notices the master moving through the listing by any other route.
function Core:checkBrowser()
    if not self:isMaster() or not self.browser then return end
    if not self:get("share_browser") or not self:isConnected() then return end
    if self.applying_remote then return end
    local state = self.browser.getState()
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
function Core:requestLibrary(path)
    if not self:get("sync_library") then return false end
    if self:isMaster() or not self.browser then return false end
    if self.library or self.book_receiver then return false end
    local link = self:getReadyLinks()[1]
    if not link then return false end

    self.library = { path = path, index = {}, collecting = true, done = 0 }
    link:send(Protocol.LIB_REQ, { path = path })
    self:log("asked for the library index of", path)
    return true
end

--- The master lists the folder it is sharing.
function Core:handleLibraryRequest(link, msg)
    if not self:isMaster() or not self.browser then return end
    if not self:get("sync_library") then
        link:send(Protocol.LIB_END, { count = 0, reason = "not sharing the library" })
        return
    end
    local state = self.browser.getState()
    -- Only the folder actually on show: a peer does not get to enumerate
    -- the filesystem.
    if not state or state.path ~= msg.path then
        link:send(Protocol.LIB_END, { count = 0, reason = "that is not the folder being shared" })
        return
    end

    -- Books only, whatever else is sitting in the folder. The listing the
    -- file browser shows is not a promise: "show unsupported files" is a
    -- setting, and the shared folder is only ever whichever one this device
    -- happens to be looking at.
    local BookTransfer = require("duo/booktransfer")
    local entries = {}
    for _, entry in ipairs(self.browser.getFiles()) do
        if BookTransfer.isBookName(entry.name) then
            entries[#entries+1] = entry
        end
    end
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

    local here = {}
    for _, entry in ipairs(self.browser and self.browser.getFiles() or {}) do
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
        if not satisfied then
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
    A ceiling on one sync, because the folder being copied is whichever one
    the master is looking at and a wrong turn is easy to make. Nothing here
    is destructive, but a mistake would otherwise mean a device quietly
    pulling gigabytes over a link that has no router on it, at a few hundred
    kilobytes a second, with a battery to pay for it. Refusing and saying
    the number is kinder than starting and hoping somebody notices.
    ]]
    local ceiling = self:get("max_library_mb") * 1024 * 1024
    if ceiling > 0 and bytes > ceiling then
        self.library = nil
        self:changed()
        self:alert(("That folder holds %d book%s this device lacks — %.0f MB, over Duo's %d MB limit for one sync.\n\nRaise the limit if that really is the shelf you meant; otherwise open the folder you want copied."):format(
            #wanted, #wanted == 1 and "" or "s", bytes / 1048576, self:get("max_library_mb")))
        return
    end

    self.library.wanted = wanted
    self.library.total = #wanted
    self.library.bytes = bytes
    self:notify(("Duo: fetching %d book%s (%.1f MB)"):format(
        #wanted, #wanted == 1 and "" or "s", bytes / 1048576))
    self:changed()
    self:pumpLibrary()
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
        if total > 0 then
            self:notify(("Duo: the library is in step (%d book%s)"):format(
                total, total == 1 and "" or "s"))
            if self.browser then self.browser.refresh() end
            -- The list is a different length than it was a moment ago, so
            -- the half of it this device was given no longer means the same
            -- thing. Ask the master where in the new one it belongs.
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
Fetches the book a stand-in is standing in for, and opens it.

This is the moment the bytes were being saved for: the user has picked the
book, so the wait is theirs to spend, and it is spent once.

@string path  the stand-in, which the book will replace
@treturn boolean true when the asking started
--]]--
function Core:fetchBookFor(path, title)
    if not self:isConnected() or self:isMaster() then return false end
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
Asks the master for a book this device does not have.

Called when the master announces a document that is nowhere on this device.
Following someone else's reading is not much use if you cannot open what
they are reading.
--]]--
function Core:requestBook(msg)
    if not self:get("sync_books") then return false end
    if self:isMaster() then return false end
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
function Core:resolveSharedFile(requested)
    if not self.browser or not self:get("sync_library") then return nil end
    local BookTransfer = require("duo/booktransfer")
    local name = BookTransfer.safeName(requested)
    if not name then return nil end
    -- The gate that actually matters: this is the one that opens a file and
    -- puts its bytes on the wire, so a name that is not a book stops here
    -- no matter how it came to be asked for.
    if not BookTransfer.isBookName(name) then return nil end

    local state = self.browser.getState()
    if not state or not state.path then return nil end
    for _, entry in ipairs(self.browser.getFiles()) do
        if entry.name == name then
            return state.path .. "/" .. name
        end
    end
    return nil
end

--- The master starts sending a book a slave asked for.
function Core:handleBookRequest(link, msg)
    if not self:isMaster() then return end
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
    local limit = self:get("max_book_mb") * 1024 * 1024
    if sender.size > limit then
        sender:close()
        link:send(Protocol.BOOK_ERR, {
            reason = ("the book is %.1f MB, over this device's %d MB limit"):format(
                sender.size / 1048576, self:get("max_book_mb")),
        })
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
    while transfer.link:pending() < BookTransfer.HIGH_WATER do
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
        max_bytes = self:get("max_book_mb") * 1024 * 1024,
    }
    if not receiver then
        self.book_request = nil
        self:alert(("Duo could not take the book: %s"):format(tostring(err)))
        return
    end
    self.book_receiver = receiver
    self.book_title = msg.title ~= "" and msg.title or msg.name
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
    if request and request.open_when_done then
        -- The user asked for this one by opening it, so it opens.
        self:notify(("Duo: %s is here"):format(request.title or "the book"))
        if self.browser then self.browser.refresh() end
        if self.hooks and self.hooks.openDocument then
            self.opening_file = nil
            self.hooks.openDocument(path, { title = request.title or "", digest = "" })
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
        self.hooks.openDocument(path, { title = self.book_title or "", digest = request.digest or "" })
    end
end

function Core:handleBookError(msg)
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
        -- One book failing is not a reason to abandon the rest.
        self:log("library book refused:", msg.reason)
        self:pumpLibrary()
        return
    end
    self:alert(("Duo could not fetch the book: %s"):format(msg.reason or "the other device refused"))
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

-- How often to look for a typography change the user made here.
local TYPOGRAPHY_POLL = 1.5

-- How long to let a relayout settle before believing a page count. Real
-- rendering engines finish repaginating a little after the event returns.
--- How long the two devices are given to agree on a book's length after a
--- layout change, before a difference is treated as real. Generous,
--- because relaying out a long book is not quick.
local PAGINATION_SETTLE = 8

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
    if self:isMaster() then self:broadcastState() end
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

Whoever sent this is, for the moment, right: on connect that is the master,
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
        -- recomputed from wherever the master ended up.
        self.warned_pagination = false
        if self:isMaster() then
            self:broadcastState()
        elseif from_link then
            -- Every page number in this book just changed. Waiting for the
            -- master's next broadcast means sitting on the wrong page until
            -- somebody turns one; asking costs a single line.
            from_link:send(Protocol.SYNC, {})
        end
    end
    if applied and applied.missing_font then
        self:alert(("The other device uses a typeface this one does not have (%s), so the pages will not line up.\n\nInstall it here, or pick a font both have."):format(
            tostring(applied.missing_font)))
    end

    -- A change made on a slave has to reach the other slaves too, and the
    -- master is the only device that talks to all of them.
    if self:isMaster() then
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
    if self:isMaster() then
        self:pushTypography("changed on the master")
        self:broadcastState()
    else
        -- Hand it to the master, which applies it and passes it on.
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
    self.applying_frontlight = true
    local ok, applied = pcall(self.hooks.applyFrontlight, wanted)
    self.applying_frontlight = false
    self.frontlight_snapshot = self:frontlightSnapshot()

    if ok and applied then
        local Frontlight = require("duo/frontlight")
        self:notify(("Duo: matched %s"):format(Frontlight.describe(applied)))
    end

    -- A change made on a slave has to reach the other slaves too.
    if self:isMaster() then
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
    if Frontlight.same(previous.intensity, current.intensity)
            and Frontlight.same(previous.warmth, current.warmth) then
        return
    end
    self.frontlight_snapshot = current
    if self:isMaster() then
        self:pushFrontlight("changed on the master")
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
        if self:isMaster() then return end -- only the master decides
        self.master_page = Protocol.num(msg, "master_page")
        self:checkPagination(Protocol.num(msg, "pages"), msg.typo)
        self:applyRemotePage(Protocol.num(msg, "page"))
    elseif msg.type == Protocol.TURN then
        if not self:isMaster() then return end
        if not self:get("slave_can_turn") then return end
        self:applyRelativeTurn(Protocol.num(msg, "dir", 1))
    elseif msg.type == Protocol.GOTO then
        if not self:isMaster() or not self.reader then return end
        local page = Protocol.num(msg, "page")
        if page then
            self.applying_remote = true
            pcall(self.reader.gotoPage, page)
            self.applying_remote = false
            self:broadcastState()
        end
    elseif msg.type == Protocol.NAP then
        self:handleNap(msg)
    elseif msg.type == Protocol.SYNC then
        if not self:isMaster() then return end
        self:sendDocumentTo(link)
        --[[
        Typography before the page, and never left out.

        A slave asks for this the moment it finishes opening a book, which
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
        if self:isMaster() and self:get("slave_can_turn") then
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
        if self:isMaster() then return end
        self:handleRemoteDocument(msg)
    elseif msg.type == Protocol.HOME then
        if self:isMaster() then return end
        self:handleRemoteHome()
    elseif msg.type == Protocol.OPEN then
        if not self:isMaster() then return end
        self:handleRemoteOpen(msg)
    elseif msg.type == Protocol.SLEEP then
        self:handleRemoteSleep()
    elseif msg.type == Protocol.NOTE then
        self:notify(msg.text or "")
    end
end

--- Opens the book the master is reading, when we are not already in it.
function Core:handleRemoteDocument(msg)
    if not self:get("follow_document") then return end
    local file = msg.file
    if not file or file == "" then return end
    local document = self.reader and self.reader.getDocument() or nil
    if document then
        local same = (document.file == file)
            or (msg.digest ~= "" and document.digest == msg.digest)
        if same then
            self:checkPagination(Protocol.num(msg, "pages"), msg.typo)
            return
        end
    end
    if not self.hooks or not self.hooks.openDocument then return end
    -- Opening a book is slow and very visible, so never start the same one
    -- twice because two messages arrived close together.
    if self.opening_file == file and Util.now() - (self.opening_since or 0) < 15 then
        return
    end
    self.opening_file = file
    self.opening_since = Util.now()
    self:notify(("Duo: opening %s"):format(msg.title ~= "" and msg.title or file))
    self.hooks.openDocument(file, msg)
end

--[[--
Follows the master out of a book and back to the list.

The spread is a pair of screens showing one thing, and that has to hold for
the book list as much as for the book: a master that has closed its book
and a slave still sitting in one is not a spread, it is two devices doing
different things. Going in was already followed; this is coming back out.
--]]--
function Core:handleRemoteHome()
    if not self:get("follow_document") then return end
    if not self.reader then return end        -- already out of the book
    if not self.hooks or not self.hooks.closeDocument then return end
    self.opening_file = nil
    self:notify("Duo: back to the book list")
    self.hooks.closeDocument()
end

--[[--
Opens, for the whole pair, a book the user tapped on a slave.

The slave may turn pages, so it would be strange if it could not start one.
It cannot simply open the book itself, though: the master owns the page
number, and a slave that went off and opened something on its own would
leave the two devices in different books. So the tap is forwarded, the
master opens it, and the master's own DOC brings the slave along — the same
path as if the master had been tapped.
--]]--
function Core:requestOpen(file, title)
    if not self:isActive() or self:isMaster() then return false end
    if not self:get("follow_document") then return false end
    if not self:get("slave_can_turn") then return false end
    local link = self:getReadyLinks()[1]
    if not link then return false end
    link:send(Protocol.OPEN, { file = file, title = title or "" })
    self:log("asked the master to open", file)
    return true
end

function Core:handleRemoteOpen(msg)
    if not self:get("slave_can_turn") then return end
    local file = msg.file
    if not file or file == "" then return end
    -- Already reading it: the slave is only catching up, so say so rather
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
    for _, link in ipairs(self:getReadyLinks()) do
        link:send(Protocol.SLEEP, {})
    end
end

function Core:handleRemoteSleep()
    if not self:get("sleep_together") then return end
    if self.sleeping_for_peer then return end
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

@int master_pages  how many pages the master says the book has
@string[opt] master_typo  the master's layout fingerprint, when it sent one
--]]--
function Core:checkPagination(master_pages, master_typo)
    if self.warned_pagination or not master_pages or master_pages == 0 then return end
    if not self.reader then return end
    local own_pages = self.reader.getPageCount()
    if not own_pages or own_pages == master_pages then return end

    if self:get("match_typography") then
        -- Nothing to say until matching has actually happened.
        if not self.typography_in_sync then return end
        --[[
        The page counts are being compared against settings that may not be
        the ones that produced them. Change the font size on the master and
        it repaginates at once, but Duo only notices a moment later, so the
        new page count arrives here while both devices still hold the old
        settings — and complaining then means complaining about a difference
        that is about to fix itself.

        The fingerprint settles it: the master stamps each page count with
        the layout that produced it, so "we disagree because the settings
        differ" and "we disagree even though they match" stop looking alike.
        Only the second is worth saying, and only it gets said.
        ]]
        local own_typo = self:typographySignature()
        if master_typo and master_typo ~= "" and own_typo and own_typo ~= ""
                and master_typo ~= own_typo then
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
        self:alert(("Both devices lay this book out with the same settings, yet it comes to %d pages here and %d on the master.\n\nThat is usually the screens themselves, which cannot be matched, so the spread will drift apart."):format(
            own_pages, master_pages))
    else
        self.warned_pagination = true
        self:alert(("This device paginates the book differently (%d pages here, %d on the master), so the spread will not line up.\n\nTurn on \"Match typography\", or set the same font, size, spacing and margins on both."):format(
            own_pages, master_pages))
    end
end

--------------------------------------------------------------------------
-- Status, for the menu
--------------------------------------------------------------------------

function Core:getStatusText()
    if not self:isActive() then
        return "Off"
    end
    if self.library and self.library.total then
        return ("Fetching books · %d of %d"):format(
            (self.library.done or 0) + 1, self.library.total)
    end
    local direction, progress = self:getTransferProgress()
    if direction then
        return ("%s %s · %d%%"):format(
            direction == "sending" and "Sending" or "Receiving",
            self.book_title or "a book", math.floor((progress or 0) * 100))
    end
    if self:isMaster() then
        local ready = self:getReadyLinks()
        if #ready == 0 then
            if self:usesSerial() then
                return ("Master · waiting on %s"):format(self:get("serial_device"))
            end
            local address = NetUtil.getLocalIP()
            return ("Master · waiting on %s:%d"):format(address or "this device", self:get("port"))
        end
        local names = {}
        for _, link in ipairs(ready) do
            names[#names+1] = link.peer_name or "slave"
        end
        local pages = ""
        if self.reader then
            pages = " · pages " .. Spread.describeLayout(self.reader.getPage(), #ready, self:getSpreadOptions())
        end
        return ("Master · %s%s"):format(table.concat(names, ", "), pages)
    end
    local link = self:getReadyLinks()[1]
    if link then
        local page = self.reader and self.reader.getPage()
        return ("Slave · following %s%s"):format(
            link.peer_name or "master",
            page and (" · page " .. page) or "")
    end
    if self.reconnect_at then
        local seconds = math.max(0, math.ceil(self.reconnect_at - Util.now()))
        return ("Slave · retrying in %ds%s"):format(seconds,
            self.last_error and (" (" .. self.last_error .. ")") or "")
    end
    if self:usesSerial() then
        return ("Slave · listening on %s…"):format(self:get("serial_device"))
    end
    return ("Slave · connecting to %s…"):format(self:get("peer_host"))
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
role was cleared, the master's listen failed, an alert went up and nothing
ever tried again, which is why a long sleep needed a disconnect and
reconnect by hand while a short one did not.

So the role is kept until a start actually succeeds, and the attempt is
repeated from the poll loop. Quietly: this is the expected state of things
for the first few seconds after waking, not something to interrupt reading
with.
--]]--
function Core:resume()
    self.sleeping_for_peer = false
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

    --[[
    A link this device brought up itself does not survive a deep sleep:
    the Kindle's own Wi-Fi daemon takes the interface back and puts it in
    managed mode, so there is no network to bind to and there never will
    be until somebody rebuilds it. Left to itself that looks exactly like
    a peer that is still asleep, and waits for ever.

    Not on the first failure, though — the ordinary case is a radio that
    is a second or two behind the rest of the device, and rebuilding the
    link would be a heavy answer to a problem that fixes itself.
    ]]
    if self.resume_attempts == RESUME_REVIVE_AFTER
        and self.hooks and self.hooks.reviveDirectLink then
        self:log("still no network; rebuilding the direct link")
        pcall(self.hooks.reviveDirectLink)
    end

    if self.resume_attempts >= RESUME_MAX_ATTEMPTS then
        self.paused_role = nil
        self:alert(("Duo could not start again after waking up.\n\n%s\n\nReconnect the two devices when the network is back."):format(
            tostring(self.last_error or "the network did not come back")))
        return
    end
    self.resume_at = now + RESUME_RETRY
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
