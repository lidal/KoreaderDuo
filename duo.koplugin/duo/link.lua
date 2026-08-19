--[[--
One authenticated connection to the other device.

A Link owns a stream, runs the pairing handshake over it, keeps it alive with
heartbeats, and hands finished messages to its owner. It knows nothing about
pages or books: `duo/core` decides what to say, the Link makes sure it is
said to the right device and notices when that device goes away.

Handshake (the leader listens, the follower dials in):

    leader   -> follower : CHALLENGE nonce=<a> proto=1
    follower -> leader   : HELLO nonce=<b> proof=H(<a>:token) name=... proto=1
    leader   -> follower : WELCOME proof=H(<b>:token) name=... slot=1
                    or   : DENY reason=...

Both sides prove they know the pairing token, and neither side ever sends
the token itself. The nonces make a proof captured off the air useless the
next time around.

@module duo.link
--]]--

local Protocol = require("duo/protocol")
local Sha256 = require("duo/sha256")
local Util = require("duo/util")

local Link = {}
Link.__index = Link

--[[--
Seconds between heartbeats, and seconds of silence before giving up.

Tuned for how long it takes to *notice* a link has died rather than for
politeness. A sleeping device's socket is not closed, it is simply
abandoned — no reset comes back, because the network it would come back
over is what went away — so nothing here learns the link is dead except by
waiting for silence. That wait used to be fifteen seconds, and it was the
largest part of the twenty a pair took to find each other again after a
sleep.

Three missed beats, on a link where a round trip is milliseconds. The cost
of being wrong is a reconnect that takes well under a second; the cost of
being slow is the pair sitting there not working.
--]]--
Link.PING_INTERVAL = 2
Link.PEER_TIMEOUT = 6

--[[--
How many messages one poll may hand over before going back for air.

A library sync arrives as hundreds of chunks, and the socket hands them all
over at once. Decoding and writing each one is work, and doing the lot
inside a single poll meant minutes could pass with no heartbeat going out —
so the *other* device, hearing nothing, decided this one had died and
dropped a link that was in the middle of working perfectly. Hence the
connected/disconnected churn that showed up only while books were moving.

Bounded, the poll returns after a mouthful, sends its ping, and picks the
rest up on the next tick fifty milliseconds later. Nothing is lost: what is
left sits in the reader's buffer. Throughput is unaffected at any rate a
Wi-Fi link can manage.
--]]--
Link.MAX_DISPATCH_PER_POLL = 16
--- Seconds allowed for the handshake.
Link.HANDSHAKE_TIMEOUT = 10
--- Seconds between repeated challenges on a link with no connect step.
Link.CHALLENGE_INTERVAL = 1

--- Computes the proof of knowing `token` for a given nonce.
function Link.proof(nonce, token)
    return Sha256.hex(tostring(nonce) .. ":" .. Util.normalizeToken(token))
end

--[[--
Creates a link around an already connected stream.

@tparam table options
    stream      the transport stream to talk over
    is_leader   true on the device that listens and decides
    token       shared pairing token ("" accepts anybody)
    name        this device's display name
    slot        follower index handed out by the leader (leader side only)
    on_message  function(link, msg) for application messages
    on_ready    function(link) once the handshake succeeded
    on_close    function(link, reason) exactly once, when the link dies
--]]--
function Link.new(options)
    local link = setmetatable({
        stream = options.stream,
        is_leader = options.is_leader and true or false,
        token = options.token or "",
        name = options.name or "KOReader",
        slot = options.slot or 1,
        on_message = options.on_message,
        on_ready = options.on_ready,
        on_close = options.on_close,
        reader = Protocol.newReader(),
        state = "handshake",
        created_at = Util.now(),
        last_rx = Util.now(),
        last_tx = 0,
        peer_name = nil,
        latency = nil,
    }, Link)

    if link.is_leader then
        link.nonce = Util.randomHex(8)
        link:sendChallenge()
    end
    return link
end

function Link:sendChallenge()
    self:sendMessage(Protocol.CHALLENGE, {
        nonce = self.nonce,
        proto = Protocol.VERSION,
        name = self.name,
    })
end

--- True once both sides have proved themselves and traffic may flow.
function Link:isReady()
    return self.state == "ready"
end

function Link:isClosed()
    return self.state == "closed"
end

--- Sends a protocol message. Safe to call before the link is ready only
-- from inside the handshake itself.
function Link:sendMessage(msg_type, fields)
    if self.state == "closed" then return false, "closed" end
    local line, err = Protocol.encode(msg_type, fields)
    if not line then
        return false, err
    end
    local ok, send_err = self.stream:send(line)
    if not ok then
        self:close(send_err or "send failed")
        return false, send_err
    end
    self.last_tx = Util.now()
    return true
end

--- Sends an application message; ignored until the handshake is done.
function Link:send(msg_type, fields)
    if not self:isReady() then return false, "not ready" end
    return self:sendMessage(msg_type, fields)
end

--- Closes the link, telling the peer why when we still can.
function Link:close(reason, polite)
    if self.state == "closed" then return end
    if polite and self.state == "ready" then
        -- Best effort: if this cannot go out, the peer's timeout catches it.
        pcall(function()
            self.stream:send(Protocol.encode(Protocol.BYE, { reason = reason or "bye" }))
        end)
    end
    self.state = "closed"
    self.stream:close()
    if self.on_close then
        self.on_close(self, reason or "closed")
    end
end

--- Bytes still queued on the transport, for flow control when sending a book.
function Link:pending()
    if self.stream.pending then return self.stream:pending() end
    return 0
end

function Link:describe()
    return (self.peer_name or "peer") .. " (" .. self.stream:getPeerName() .. ")"
end

--------------------------------------------------------------------------
-- Handshake
--------------------------------------------------------------------------

function Link:handleHandshake(msg)
    if self.is_leader then
        if msg.type ~= Protocol.HELLO then
            self:close("unexpected " .. msg.type)
            return
        end
        if Protocol.num(msg, "proto", 0) ~= Protocol.VERSION then
            self:sendMessage(Protocol.DENY, { reason = "protocol version mismatch" })
            self:close("protocol version mismatch")
            return
        end
        if self.token ~= "" and msg.proof ~= Link.proof(self.nonce, self.token) then
            self:sendMessage(Protocol.DENY, { reason = "pairing code does not match" })
            self:close("wrong pairing code")
            return
        end
        self.peer_name = msg.name or "follower"
        self:sendMessage(Protocol.WELCOME, {
            proof = Link.proof(msg.nonce or "", self.token),
            name = self.name,
            slot = self.slot,
        })
        self:becomeReady()
    else
        if msg.type == Protocol.DENY then
            self:close(msg.reason or "refused by leader")
            return
        end
        if msg.type == Protocol.CHALLENGE then
            if Protocol.num(msg, "proto", 0) ~= Protocol.VERSION then
                self:close("protocol version mismatch")
                return
            end
            self.peer_name = msg.name or "leader"
            -- A serial line has no connect step, so the leader repeats its
            -- challenge until somebody answers. Answering a repeat with a
            -- *new* nonce would invalidate the reply already in flight, so
            -- the nonce is tied to the challenge that prompted it.
            if self.challenge_nonce ~= msg.nonce then
                self.challenge_nonce = msg.nonce
                self.nonce = Util.randomHex(8)
            end
            self:sendMessage(Protocol.HELLO, {
                nonce = self.nonce,
                proof = Link.proof(msg.nonce or "", self.token),
                name = self.name,
                proto = Protocol.VERSION,
            })
            return
        end
        if msg.type == Protocol.WELCOME then
            if self.token ~= "" and msg.proof ~= Link.proof(self.nonce, self.token) then
                -- Someone is listening on that port, but it is not our leader.
                self:close("pairing code does not match")
                return
            end
            self.peer_name = msg.name or self.peer_name or "leader"
            self.slot = Protocol.num(msg, "slot", 1)
            self:becomeReady()
            return
        end
        self:close("unexpected " .. msg.type)
    end
end

function Link:becomeReady()
    self.state = "ready"
    self.last_rx = Util.now()
    if self.on_ready then
        self.on_ready(self)
    end
end

--------------------------------------------------------------------------
-- Pump
--------------------------------------------------------------------------

--- Moves bytes in both directions and runs the timers.
-- Call this often; it never blocks.
function Link:poll()
    if self.state == "closed" then return end

    local data, err = self.stream:receive()
    if not data then
        self:close(err == "closed" and "peer disconnected" or (err or "read failed"))
        return
    end
    if #data > 0 then
        self.last_rx = Util.now()
        self.heard_from_peer = true
        self.reader:feed(data)
    end

    local handled = 0
    while self.state ~= "closed" and handled < Link.MAX_DISPATCH_PER_POLL do
        local msg, decode_err = self.reader:next()
        if not msg then
            if decode_err then
                self:close("bad message: " .. decode_err)
            end
            break
        end
        handled = handled + 1
        self:dispatch(msg)
    end

    if self.state == "closed" then return end

    local ok, flush_err = self.stream:flush()
    if not ok then
        self:close(flush_err or "write failed")
        return
    end

    self:checkTimers()
end

function Link:dispatch(msg)
    if self.state == "handshake" then
        self:handleHandshake(msg)
        return
    end
    if msg.type == Protocol.PING then
        self:sendMessage(Protocol.PONG, { t = msg.t })
        return
    end
    if msg.type == Protocol.PONG then
        local sent_at = tonumber(msg.t)
        if sent_at then
            self.latency = Util.now() - sent_at
        end
        return
    end
    if msg.type == Protocol.BYE then
        self:close(msg.reason or "peer left")
        return
    end
    if self.on_message then
        self.on_message(self, msg)
    end
end

function Link:checkTimers()
    local now = Util.now()
    if self.state == "handshake" then
        if now - self.created_at > Link.HANDSHAKE_TIMEOUT then
            self:close("handshake timed out")
        elseif self.is_leader and not self.heard_from_peer
                and now - self.last_tx >= Link.CHALLENGE_INTERVAL then
            -- Nobody has said anything back. On a serial line that just
            -- means the other device is not listening yet, so keep calling.
            self:sendChallenge()
        end
        return
    end
    if now - self.last_rx > Link.PEER_TIMEOUT then
        self:close("peer stopped responding")
        return
    end
    if now - self.last_tx >= Link.PING_INTERVAL then
        self:sendMessage(Protocol.PING, { t = string.format("%.3f", now) })
    end
end

return Link
