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

function Core:set(key, value)
    self.settings[key] = value
    self:save()
    self:changed()
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
    self:changed()
    if not self:isActive() then return end
    if self:isMaster() then
        self:broadcastDocument()
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
        self:changed()
        return true
    end

    if role == Core.ROLE_MASTER then
        local port = self:get("port")
        local server, err = TcpTransport.listen(port)
        if not server then
            self.last_error = err
            self:alert(("Could not listen on port %d.\n%s"):format(port, tostring(err)))
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
            self:alert("No master address yet. Search for the master, or type its address.")
            return false
        end
        -- Refuse an address we cannot reach *before* saving it, so a typo
        -- does not become a reconnect loop against a host that never existed.
        local resolved = NetUtil.resolve(host)
        if not resolved then
            self:alert(("No device answers to \"%s\".\n\nCheck the address shown on the master."):format(host))
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
    if self.role ~= Core.ROLE_OFF then
        self.role = Core.ROLE_OFF
        self.settings.autostart_role = Core.ROLE_OFF
        self:save()
        self:changed()
    end
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
        self:sendDocumentTo(link)
        self:sendStateTo(link)
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
    })
end

function Core:broadcastState()
    if not self:isMaster() then return end
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
-- Incoming messages
--------------------------------------------------------------------------

function Core:handleMessage(link, msg)
    if msg.type == Protocol.STATE then
        if self:isMaster() then return end -- only the master decides
        self.master_page = Protocol.num(msg, "master_page")
        self:checkPagination(Protocol.num(msg, "pages"))
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
    elseif msg.type == Protocol.SYNC then
        if not self:isMaster() then return end
        self:sendDocumentTo(link)
        self:sendStateTo(link)
    elseif msg.type == Protocol.DOC then
        if self:isMaster() then return end
        self:handleRemoteDocument(msg)
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
            self:checkPagination(Protocol.num(msg, "pages"))
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

--- Warns once when the two devices do not paginate the book identically,
-- which is what happens when their font size or margins differ.
function Core:checkPagination(master_pages)
    if self.warned_pagination or not master_pages or master_pages == 0 then return end
    if not self.reader then return end
    local own_pages = self.reader.getPageCount()
    if own_pages and own_pages ~= master_pages then
        self.warned_pagination = true
        self:alert(("This device paginates the book differently (%d pages here, %d on the master), so the spread will not line up.\n\nMatch the font size, line spacing and margins on both devices."):format(own_pages, master_pages))
    end
end

--------------------------------------------------------------------------
-- Status, for the menu
--------------------------------------------------------------------------

function Core:getStatusText()
    if not self:isActive() then
        return "Off"
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
    self:stop("the other device went to sleep")
    self.paused_role = role
    self.settings.autostart_role = role
    self:save()
end

--- Called on wake-up, and whenever the network comes back.
function Core:resume()
    local role = self.paused_role
    if not role then return end
    self.paused_role = nil
    self:start(role)
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
