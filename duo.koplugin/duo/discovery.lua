--[[--
Finding the other device without typing an IP address.

The master answers UDP probes with an offer describing itself; the slave
broadcasts a probe and collects the answers. Typing a `192.168.x.y` on an
e-ink keyboard is miserable, so this is the path the pairing screen uses,
with manual entry kept as the fallback for networks that filter broadcasts.

@module duo.discovery
--]]--

local socket = require("socket")

local NetUtil = require("duo/netutil")
local Protocol = require("duo/protocol")
local Util = require("duo/util")

local Discovery = {}

--- Default UDP port for probes and offers (the Duo TCP port plus one).
Discovery.PORT = 9971

local PROBE = "PROBE"
local OFFER = "OFFER"

--------------------------------------------------------------------------
-- Responder: runs on the master.
--------------------------------------------------------------------------

local Responder = {}
Responder.__index = Responder

--[[--
Starts answering probes.

@tparam table options
    port      UDP port to listen on (default Discovery.PORT)
    describe  function returning { name=, port=, book=, token_hint= }
--]]--
function Discovery.newResponder(options)
    local udp, err = socket.udp()
    if not udp then return nil, err or "no socket" end
    udp:settimeout(0)
    local ok, bind_err = udp:setsockname("*", options.port or Discovery.PORT)
    if not ok then
        udp:close()
        return nil, bind_err or "could not bind"
    end
    return setmetatable({
        udp = udp,
        describe = options.describe,
    }, Responder)
end

--- Answers whatever probes have arrived. Never blocks.
function Responder:poll()
    for _ = 1, 8 do -- bounded so a probe flood cannot stall the UI
        local data, ip, port = self.udp:receivefrom()
        if not data then return end
        local msg = Protocol.decode((data:gsub("\n$", "")))
        if msg and msg.type == PROBE and Protocol.num(msg, "proto", 0) == Protocol.VERSION then
            local info = self.describe and self.describe() or {}
            local reply = Protocol.encode(OFFER, {
                proto = Protocol.VERSION,
                id = info.id or "",
                name = info.name or "KOReader",
                port = info.port or 9970,
                book = info.book or "",
                locked = info.locked and 1 or 0,
            })
            if reply then
                self.udp:sendto(reply, ip, port)
            end
        end
    end
end

function Responder:close()
    pcall(function() self.udp:close() end)
end

--------------------------------------------------------------------------
-- Scanner: runs on the slave.
--------------------------------------------------------------------------

local Scanner = {}
Scanner.__index = Scanner

--[[--
Starts looking for masters.

@tparam table options
    port        UDP port to probe (default Discovery.PORT)
    duration    how long to keep looking, in seconds (default 4)
    extra_hosts additional unicast probe targets
--]]--
function Discovery.newScanner(options)
    options = options or {}
    local udp, err = socket.udp()
    if not udp then return nil, err or "no socket" end
    udp:settimeout(0)
    udp:setsockname("*", 0)
    pcall(function() udp:setoption("broadcast", true) end)

    local targets = { "255.255.255.255" }
    for _, address in ipairs(NetUtil.getBroadcastAddresses(NetUtil.getLocalIP())) do
        targets[#targets+1] = address
    end
    for _, host in ipairs(options.extra_hosts or {}) do
        targets[#targets+1] = host
    end

    return setmetatable({
        udp = udp,
        port = options.port or Discovery.PORT,
        targets = targets,
        deadline = Util.now() + (options.duration or 4),
        next_probe = 0,
        found = {},
        errors = {},
    }, Scanner)
end

--- Sends probes when due and collects offers.
-- @treturn table offers discovered since the last call:
--   { name=, host=, port=, book=, locked= }
function Scanner:poll()
    local now = Util.now()
    if now >= self.next_probe and now < self.deadline then
        self.next_probe = now + 0.75
        local probe = Protocol.encode(PROBE, { proto = Protocol.VERSION })
        for _, target in ipairs(self.targets) do
            local ok, send_err = self.udp:sendto(probe, target, self.port)
            if not ok and send_err then
                self.errors[target] = send_err
            end
        end
    end

    local new_offers = {}
    for _ = 1, 16 do
        local data, ip = self.udp:receivefrom()
        if not data then break end
        local msg = Protocol.decode((data:gsub("\n$", "")))
        if msg and msg.type == OFFER and Protocol.num(msg, "proto", 0) == Protocol.VERSION then
            -- One master can answer the same scan on several interfaces.
            -- Fold those together by its instance id so the user is offered
            -- one device, not one row per address it happens to own.
            local key = (msg.id and msg.id ~= "" and msg.id) or (ip .. ":" .. (msg.port or "?"))
            local known = self.found[key]
            if not known then
                local offer = {
                    name = msg.name or "KOReader",
                    host = ip,
                    port = Protocol.num(msg, "port", 9970),
                    book = msg.book ~= "" and msg.book or nil,
                    locked = Protocol.bool(msg, "locked"),
                }
                self.found[key] = offer
                new_offers[#new_offers+1] = offer
            elseif known.host:match("^127%.") and not ip:match("^127%.") then
                known.host = ip -- prefer the address the peer can actually route to
            end
        end
    end
    return new_offers
end

--- True once the scan window has elapsed.
function Scanner:isDone()
    return Util.now() >= self.deadline
end

--- Everything found so far, as an array.
function Scanner:getResults()
    local results = {}
    for _, offer in pairs(self.found) do
        results[#results+1] = offer
    end
    table.sort(results, function(a, b) return a.host < b.host end)
    return results
end

function Scanner:close()
    pcall(function() self.udp:close() end)
end

return Discovery
