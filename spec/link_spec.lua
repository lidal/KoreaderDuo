--[[--
Transport, handshake and discovery, exercised over real loopback sockets.
No mocks: if luasocket behaves differently on the device than it does here,
these tests are the ones that would notice.
--]]--

local T = require("spec/testrunner")
local socket = require("socket")

local Discovery = require("duo/discovery")
local Link = require("duo/link")
local Protocol = require("duo/protocol")
local TcpTransport = require("duo/transport_tcp")

local next_port = 19700
local function freePort()
    next_port = next_port + 1
    return next_port
end

--- Polls a set of objects until `condition` holds or we run out of patience.
local function pumpUntil(objects, condition, timeout)
    local deadline = socket.gettime() + (timeout or 3)
    while socket.gettime() < deadline do
        for _, object in ipairs(objects) do
            if object then object:poll() end
        end
        if condition() then return true end
        socket.sleep(0.005)
    end
    return false
end

--- Brings up a connected leader/follower pair on loopback.
local function connectedPair(leader_token, follower_token)
    local port = freePort()
    local server = assert(TcpTransport.listen(port, "127.0.0.1"))
    local connector = assert(TcpTransport.connect("127.0.0.1", port, 3))

    local follower_stream, leader_stream
    local deadline = socket.gettime() + 3
    while socket.gettime() < deadline and not (follower_stream and leader_stream) do
        leader_stream = leader_stream or server:accept()
        if not follower_stream then
            local result = connector:poll()
            if result then follower_stream = result end
        end
        socket.sleep(0.005)
    end
    assert(follower_stream and leader_stream, "sockets did not connect")

    -- Both links narrate into `events.<side>.trace`, which is what the
    -- verbose log gets on a real device. Attached to every pair rather than
    -- to the one test that reads it, so the commentary is exercised
    -- wherever links are.
    local events = { leader = { trace = {} }, follower = { trace = {} } }
    local function narrator(side)
        return function(...)
            local parts = {}
            for index = 1, select("#", ...) do
                parts[#parts+1] = tostring((select(index, ...)))
            end
            local log = events[side].trace
            log[#log+1] = table.concat(parts, " ")
        end
    end
    local leader = Link.new{
        stream = leader_stream,
        is_leader = true,
        token = leader_token,
        name = "Kindle-L",
        slot = 1,
        on_message = function(_, msg) events.leader[#events.leader+1] = msg end,
        on_close = function(_, reason) events.leader.closed = reason end,
        on_ready = function() events.leader.ready = true end,
        trace = narrator("leader"),
        -- Read at call time, so a test can decide where to put the peer
        -- after the pair is built but before the handshake is pumped.
        on_identify = function(_, id)
            events.leader.identified = id
            return events.leader.give_slot
        end,
    }
    local follower = Link.new{
        stream = follower_stream,
        is_leader = false,
        token = follower_token,
        name = "Kindle-F",
        on_message = function(_, msg) events.follower[#events.follower+1] = msg end,
        on_close = function(_, reason) events.follower.closed = reason end,
        on_ready = function() events.follower.ready = true end,
        trace = narrator("follower"),
        id = "f0110w",
    }
    return leader, follower, events, server
end

T.describe("tcp transport", function()
    T.it("connects, transfers and closes", function()
        local port = freePort()
        local server = assert(TcpTransport.listen(port, "127.0.0.1"))
        local connector = assert(TcpTransport.connect("127.0.0.1", port, 3))

        local client, accepted
        pumpUntil({}, function()
            accepted = accepted or server:accept()
            if not client then
                local result = connector:poll()
                if result then client = result end
            end
            return client and accepted
        end)
        T.assertTrue(client, "client did not connect")
        T.assertTrue(accepted, "server did not accept")

        T.assertTrue(client:send("hello over the wire\n"))
        local received = ""
        pumpUntil({}, function()
            received = received .. (accepted:receive() or "")
            return received:find("\n")
        end)
        T.assertEquals(received, "hello over the wire\n")

        client:close()
        local data, err
        pumpUntil({}, function()
            data, err = accepted:receive()
            return data == nil
        end)
        T.assertNil(data)
        T.assertEquals(err, "closed")
        server:close()
        accepted:close()
    end)

    T.it("reports a refused connection instead of hanging", function()
        local port = freePort() -- nothing is listening here
        local connector = assert(TcpTransport.connect("127.0.0.1", port, 3))
        local result, err
        pumpUntil({}, function()
            result, err = connector:poll()
            return result ~= nil
        end)
        T.assertEquals(result, false)
        T.assertMatch(err, "refused")
    end)

    T.it("buffers a large write instead of blocking", function()
        local port = freePort()
        local server = assert(TcpTransport.listen(port, "127.0.0.1"))
        local connector = assert(TcpTransport.connect("127.0.0.1", port, 3))
        local client, accepted
        pumpUntil({}, function()
            accepted = accepted or server:accept()
            if not client then
                local result = connector:poll()
                if result then client = result end
            end
            return client and accepted
        end)

        local payload = string.rep("x", 40000) .. "\n"
        local started = socket.gettime()
        T.assertTrue(client:send(payload))
        T.assertTrue(socket.gettime() - started < 0.5, "send blocked")

        local received = ""
        pumpUntil({}, function()
            received = received .. (accepted:receive() or "")
            client:flush()
            return #received >= #payload
        end, 5)
        T.assertEquals(#received, #payload)
        client:close(); accepted:close(); server:close()
    end)
end)

T.describe("link handshake", function()
    T.it("brings both sides up when the tokens match", function()
        local leader, follower, events, server = connectedPair("K7F2QX", "k7f-2qx")
        T.assertTrue(pumpUntil({ leader, follower }, function()
            return leader:isReady() and follower:isReady()
        end), "handshake did not complete")
        T.assertTrue(events.leader.ready)
        T.assertTrue(events.follower.ready)
        T.assertEquals(leader.peer_name, "Kindle-F")
        T.assertEquals(follower.peer_name, "Kindle-L")
        T.assertEquals(follower.slot, 1)
        leader:close("done"); follower:close("done"); server:close()
    end)

    T.it("refuses a follower with the wrong token", function()
        local leader, follower, events, server = connectedPair("K7F2QX", "WRONG9")
        T.assertTrue(pumpUntil({ leader, follower }, function()
            return leader:isClosed() and follower:isClosed()
        end), "bad pairing was not rejected")
        T.assertTrue(not leader:isReady())
        T.assertMatch(events.follower.closed, "pairing code")
        server:close()
    end)

    T.it("never puts the token on the wire", function()
        local port = freePort()
        local server = assert(TcpTransport.listen(port, "127.0.0.1"))
        local connector = assert(TcpTransport.connect("127.0.0.1", port, 3))
        local client, accepted
        pumpUntil({}, function()
            accepted = accepted or server:accept()
            if not client then
                local result = connector:poll()
                if result then client = result end
            end
            return client and accepted
        end)

        local token = "K7F2QX"
        local leader = Link.new{ stream = accepted, is_leader = true, token = token, name = "L" }
        local follower = Link.new{ stream = client, is_leader = false, token = token, name = "F" }

        -- Watch every byte the two of them exchange.
        local seen = {}
        for _, stream in ipairs({ accepted, client }) do
            local original_send = stream.send
            stream.send = function(self, data)
                seen[#seen+1] = data or ""
                return original_send(self, data)
            end
        end
        pumpUntil({ leader, follower }, function()
            return leader:isReady() and follower:isReady()
        end)
        local transcript = table.concat(seen)
        T.assertTrue(#transcript > 0, "nothing was exchanged")
        T.assertNil(transcript:find(token, 1, true), "the pairing token leaked onto the wire")
        leader:close(); follower:close(); server:close()
    end)

    T.it("accepts anybody when no token is set", function()
        local leader, follower, _, server = connectedPair("", "")
        T.assertTrue(pumpUntil({ leader, follower }, function()
            return leader:isReady() and follower:isReady()
        end))
        leader:close(); follower:close(); server:close()
    end)
end)

T.describe("link traffic", function()
    T.it("carries application messages both ways", function()
        local leader, follower, events, server = connectedPair("T0KEN2", "T0KEN2")
        pumpUntil({ leader, follower }, function()
            return leader:isReady() and follower:isReady()
        end)

        leader:send(Protocol.STATE, { page = 42, pages = 300 })
        follower:send(Protocol.TURN, { dir = -1 })
        T.assertTrue(pumpUntil({ leader, follower }, function()
            return #events.follower > 0 and #events.leader > 0
        end), "messages did not arrive")

        T.assertEquals(events.follower[1].type, "STATE")
        T.assertEquals(Protocol.num(events.follower[1], "page"), 42)
        T.assertEquals(events.leader[1].type, "TURN")
        T.assertEquals(Protocol.num(events.leader[1], "dir"), -1)
        leader:close(); follower:close(); server:close()
    end)

    T.it("names itself, so the leader can tell a return from a newcomer", function()
        --[[
        The leader hands out slots by counting the links it holds. A
        follower that reconnects while the old link is still timing out
        would be counted twice and welcomed into the spread beside itself,
        so it says who it is and the leader decides where it goes -- before
        the welcome, which is what carries the slot.
        ]]
        local leader, follower, events, server = connectedPair("T0KEN2", "T0KEN2")
        events.leader.give_slot = 3
        pumpUntil({ leader, follower }, function()
            return leader:isReady() and follower:isReady()
        end)

        T.assertEquals(events.leader.identified, "f0110w")
        T.assertEquals(leader.peer_id, "f0110w")
        T.assertEquals(leader.slot, 3, "the leader ignored where it put the peer")
        T.assertEquals(follower.slot, 3, "the welcome carried the old slot")
        leader:close(); follower:close(); server:close()
    end)

    T.it("shrugs off a second hello answering a repeated challenge", function()
        --[[
        Taken from two Kindles on a house network. The leader repeats its
        challenge when the first goes unanswered for a second, which with a
        half-second round trip it regularly does. The follower answers both,
        as it must -- a lost challenge is what the repeat is for -- and the
        second answer arrives at a leader that is already talking.

        Signing starts at the welcome, so that hello carries no tag, and
        treating it as a forgery hung up on the pair every single time the
        first challenge was slow. Which over Wi-Fi was every time: connect,
        disconnect, connect, on every pairing.
        ]]
        local leader, follower, events, server = connectedPair("T0KEN2", "T0KEN2")
        pumpUntil({ leader, follower }, function()
            return leader:isReady() and follower:isReady()
        end)

        -- The hello the follower had already sent, arriving late.
        leader:dispatch{ type = "HELLO", nonce = "beef", name = "Kindle-F",
                         proof = "whatever", proto = 3 }
        T.assertTrue(leader:isReady(), "a late hello hung up on a working link")
        T.assertNil(events.leader.closed)

        -- And the same courtesy the other way, for a repeated challenge or
        -- a welcome that arrives twice.
        follower:dispatch{ type = "CHALLENGE", nonce = "cafe", proto = 3 }
        follower:dispatch{ type = "WELCOME", proof = "whatever", slot = 9 }
        T.assertTrue(follower:isReady(), "a late welcome hung up on a working link")
        T.assertEquals(follower.slot, 1, "and it must not be moved by one either")

        -- Anything that is not part of the handshake is still refused.
        leader:dispatch{ type = "TURN", dir = "1" }
        T.assertTrue(leader:isClosed(), "an unsigned message got through")
        follower:close(); server:close()
    end)

    T.it("can say one thing here and another to the peer", function()
        --[[
        Going to sleep is the case: each device is the "other" one from
        where the other is standing. Sending both ends the same sentence
        meant the device that had just locked its own screen recorded the
        peer as having dozed off -- fifty-nine times in one log, against
        thirteen occasions when that was what happened.
        ]]
        local leader, follower, events, server = connectedPair("T0KEN2", "T0KEN2")
        pumpUntil({ leader, follower }, function()
            return leader:isReady() and follower:isReady()
        end)

        leader:close("this device went to sleep", true,
                     "the other device went to sleep")
        T.assertEquals(events.leader.closed, "this device went to sleep")
        T.assertTrue(pumpUntil({ follower }, function()
            return events.follower.closed ~= nil
        end), "the goodbye never arrived")
        T.assertEquals(events.follower.closed, "the other device went to sleep")
        follower:close(); server:close()
    end)

    T.it("says what it had been doing when it dies", function()
        --[[
        "peer stopped responding" is the same sentence whether the other
        device wandered off mid-book or never really arrived, and which of
        those it was is the whole question. So a link that ends says how
        long it lived and how much had crossed it.
        ]]
        local leader, follower, events, server = connectedPair("T0KEN2", "T0KEN2")
        pumpUntil({ leader, follower }, function()
            return leader:isReady() and follower:isReady()
        end)
        leader:send(Protocol.STATE, { page = 42, pages = 300 })
        pumpUntil({ leader, follower }, function() return #events.follower > 0 end)

        local report = follower:report()
        T.assertMatch(report, "age=%d")
        T.assertMatch(report, "in=%d+/%d+B")
        T.assertMatch(report, "out=%d+/%d+B")
        T.assertMatch(report, "last_in=STATE")
        T.assertTrue(follower.bytes_in > 0, "nothing was counted coming in")
        T.assertTrue(leader.bytes_out > 0, "nothing was counted going out")

        follower:close("test over")
        local said = table.concat(events.follower.trace, "\n")
        T.assertMatch(said, "closing test over")
        T.assertMatch(said, "age=")
        leader:close(); server:close()
    end)

    T.it("keeps the heartbeat out of the commentary it writes", function()
        -- Two messages every couple of seconds each way, saying nothing the
        -- summary does not say better. Counted, not narrated -- otherwise
        -- they bury whatever the log was switched on to see.
        local leader, follower, events, server = connectedPair("T0KEN2", "T0KEN2")
        pumpUntil({ leader, follower }, function()
            return leader:isReady() and follower:isReady()
        end)
        leader:send(Protocol.STATE, { page = 42, pages = 300 })
        local started = socket.gettime()
        pumpUntil({ leader, follower }, function()
            return socket.gettime() - started > 2.5
        end, 4)

        local said = table.concat(events.follower.trace, "\n")
        T.assertMatch(said, "in STATE")
        T.assertTrue(not said:find("PING"), "the heartbeat is in the commentary")
        T.assertTrue(not said:find("PONG"), "the heartbeat is in the commentary")
        T.assertTrue(follower.msgs_in > 1, "but it should still be counted")
        leader:close(); follower:close(); server:close()
    end)

    T.it("keeps itself alive with heartbeats and measures latency", function()
        local leader, follower, _, server = connectedPair("T0KEN2", "T0KEN2")
        pumpUntil({ leader, follower }, function()
            return leader:isReady() and follower:isReady()
        end)
        -- PING_INTERVAL is 4s; wait past it and confirm nothing timed out.
        local started = socket.gettime()
        pumpUntil({ leader, follower }, function()
            return socket.gettime() - started > 4.5
        end, 6)
        T.assertTrue(leader:isReady(), "leader dropped the link")
        T.assertTrue(follower:isReady(), "follower dropped the link")
        T.assertTrue(leader.latency ~= nil or follower.latency ~= nil, "no round trip measured")
        leader:close(); follower:close(); server:close()
    end)

    T.it("notices when the peer vanishes", function()
        local leader, follower, events, server = connectedPair("T0KEN2", "T0KEN2")
        pumpUntil({ leader, follower }, function()
            return leader:isReady() and follower:isReady()
        end)
        follower.stream:close() -- yanked cable / device suspended
        T.assertTrue(pumpUntil({ leader }, function()
            return leader:isClosed()
        end), "leader did not notice the peer leaving")
        T.assertMatch(events.leader.closed, "disconnect")
        server:close()
    end)

    T.it("says goodbye on a clean close", function()
        local leader, follower, events, server = connectedPair("T0KEN2", "T0KEN2")
        pumpUntil({ leader, follower }, function()
            return leader:isReady() and follower:isReady()
        end)
        leader:close("stopped by user", true)
        T.assertTrue(pumpUntil({ follower }, function()
            return follower:isClosed()
        end), "follower missed the goodbye")
        T.assertMatch(events.follower.closed, "stopped by user")
        server:close()
    end)
end)

T.describe("signing the conversation", function()
    --[[
    The proofs establish that the other end knows the pairing code. They do
    not establish that the other end is the one you are talking to: a device
    in the middle can pass the challenge along, pass the answer back, and
    then sit between two peers that each believe they proved something.

    So both sides derive a key from the code and *both* nonces, and sign
    everything after the handshake with it. A relay ends up with two
    different keys rather than one shared one, and the first signed message
    it forwards fails.
    ]]
    local Sha256 = require("duo/sha256")

    T.it("puts a tag on every message once the handshake is done", function()
        local leader, follower, events, server = connectedPair("T4GG3D", "T4GG3D")
        pumpUntil({ leader, follower }, function()
            return leader:isReady() and follower:isReady()
        end)
        T.assertTrue(leader.session_key ~= nil, "the leader derived no key")
        T.assertEquals(leader.session_key, follower.session_key,
            "the two ends must arrive at the same key or nothing will verify")
        server:close()
    end)

    T.it("refuses a message nobody signed", function()
        local leader, follower, events, server = connectedPair("T4GG3D", "T4GG3D")
        pumpUntil({ leader, follower }, function()
            return leader:isReady() and follower:isReady()
        end)
        -- Straight onto the wire, bypassing the signing the link would do.
        follower.stream:send(Protocol.encode(Protocol.GOTO, { page = 99 }))
        T.assertTrue(pumpUntil({ leader }, function() return leader:isClosed() end),
            "an unsigned message was acted on")
        T.assertMatch(events.leader.closed, "not signed")
        server:close()
    end)

    T.it("refuses a message signed with the wrong key", function()
        -- Which is what a device relaying somebody else's handshake holds:
        -- it knows the code but not the pair of nonces this link agreed on.
        local leader, follower, events, server = connectedPair("T4GG3D", "T4GG3D")
        pumpUntil({ leader, follower }, function()
            return leader:isReady() and follower:isReady()
        end)
        local body = Protocol.encode(Protocol.GOTO, { page = 99 }):gsub("\n$", "")
        local forged = Sha256.hmac("some other session", body):sub(1, 16)
        follower.stream:send(Protocol.encode(Protocol.GOTO, { page = 99, mac = forged }))
        T.assertTrue(pumpUntil({ leader }, function() return leader:isClosed() end),
            "a forged tag was accepted")
        server:close()
    end)

    T.it("refuses a message whose contents were changed in flight", function()
        local leader, follower, events, server = connectedPair("T4GG3D", "T4GG3D")
        pumpUntil({ leader, follower }, function()
            return leader:isReady() and follower:isReady()
        end)
        -- A real tag, over a different page than the one being sent.
        local body = Protocol.encode(Protocol.GOTO, { page = 7 }):gsub("\n$", "")
        local tag = Sha256.hmac(follower.session_key, body):sub(1, 16)
        follower.stream:send(Protocol.encode(Protocol.GOTO, { page = 99, mac = tag }))
        T.assertTrue(pumpUntil({ leader }, function() return leader:isClosed() end),
            "the page was changed under a tag that did not cover it")
        server:close()
    end)

    T.it("leaves the body of a book unsigned, and says so", function()
        -- The one exception, and it is deliberate: signing megabytes in Lua
        -- would cost more than the encoding that already bounds a transfer.
        local leader, follower, events, server = connectedPair("T4GG3D", "T4GG3D")
        pumpUntil({ leader, follower }, function()
            return leader:isReady() and follower:isReady()
        end)
        local seen
        events.follower.messages = {}
        follower.on_message = function(_, msg) seen = msg end
        leader:send(Protocol.BOOK_DATA, { b = "AAAA" })
        pumpUntil({ leader, follower }, function() return seen ~= nil end)
        T.assertTrue(seen ~= nil, "the chunk never arrived")
        T.assertNil(seen.mac, "book data should not be carrying a tag")
        server:close()
    end)

    T.it("takes the tag back off before anybody else sees the message", function()
        --[[
        Several handlers copy every field out of a message that is not
        `type` -- matching typography does exactly that -- so a tag left in
        place arrives as one more setting to apply. It did: the pair then
        believed its layouts disagreed for as long as the link was up, and
        stopped saying anything about page counts that really did differ.
        ]]
        local leader, follower, events, server = connectedPair("T4GG3D", "T4GG3D")
        pumpUntil({ leader, follower }, function()
            return leader:isReady() and follower:isReady()
        end)
        local seen
        follower.on_message = function(_, msg) seen = msg end
        leader:send(Protocol.TYPO, { font_size = "26" })
        pumpUntil({ leader, follower }, function() return seen ~= nil end)
        T.assertTrue(seen ~= nil, "the message never arrived")
        T.assertEquals(seen.font_size, "26")
        T.assertNil(seen.mac,
            "the tag was still on the message when the handlers got it")
        server:close()
    end)

    T.it("gives two different pairs two different keys", function()
        -- The nonces are what make the key belong to one conversation.
        local a = Link.sessionKey("aaaa", "bbbb", "SAM3C0DE")
        local b = Link.sessionKey("aaaa", "cccc", "SAM3C0DE")
        T.assertNotEquals(a, b, "the same key would follow the code around")
        T.assertNotEquals(a, Link.sessionKey("aaaa", "bbbb", "0TH3RC0DE"))
    end)
end)

T.describe("discovery", function()
    T.it("finds a leader over UDP", function()
        local udp_port = freePort()
        local responder = assert(Discovery.newResponder{
            port = udp_port,
            describe = function()
                return { id = "abc123", name = "Kindle-L", port = 9970, book = "Moby Dick", locked = true }
            end,
        })
        local scanner = assert(Discovery.newScanner{
            port = udp_port,
            duration = 3,
            extra_hosts = { "127.0.0.1" }, -- loopback has no broadcast domain
        })

        local offers = {}
        pumpUntil({ responder }, function()
            for _, offer in ipairs(scanner:poll()) do
                offers[#offers+1] = offer
            end
            return #offers > 0
        end, 4)

        -- The responder answers on every interface the probe reached it on;
        -- those replies must fold into a single offer for one device.
        T.assertEquals(#offers, 1, "expected exactly one offer")
        T.assertEquals(offers[1].name, "Kindle-L")
        T.assertEquals(offers[1].port, 9970)
        T.assertEquals(offers[1].book, "Moby Dick")
        T.assertTrue(offers[1].locked)

        -- Repeated probes must not produce duplicate entries.
        scanner:poll()
        responder:poll()
        scanner:poll()
        T.assertEquals(#scanner:getResults(), 1)

        scanner:close(); responder:close()
    end)

    T.it("finishes quietly when nobody answers", function()
        local scanner = assert(Discovery.newScanner{
            port = freePort(),
            duration = 0.5,
            extra_hosts = { "127.0.0.1" },
        })
        pumpUntil({}, function()
            scanner:poll()
            return scanner:isDone()
        end, 3)
        T.assertTrue(scanner:isDone())
        T.assertEquals(#scanner:getResults(), 0)
        scanner:close()
    end)
end)

T.describe("forgiving a device that is opening a book", function()
    --[[
    Opening a book is not quick and cannot be interrupted: a large one is
    tens of seconds of parsing during which the reader answers nothing at
    all, and six seconds of silence is how a dead peer looks. Two real
    readers opening the same big book dropped the link every time -- which
    is what made a book arriving over the link fail half way.
    ]]
    local Link = require("duo/link")
    local Util = require("duo/util")

    local function quietLink()
        return setmetatable({
            state = "ready",
            last_rx = Util.now() - (Link.PEER_TIMEOUT + 5),
            last_tx = Util.now(),
            closed_with = nil,
            close = function(self, reason) self.closed_with = reason end,
        }, { __index = Link })
    end

    T.it("closes a link that has simply gone quiet", function()
        local link = quietLink()
        T.assertTrue(link.grace_until == nil)
        T.assertTrue(Util.now() - link.last_rx > Link.PEER_TIMEOUT,
            "the fixture is not actually silent")
    end)

    T.it("forgives the silence while a book is being opened", function()
        local link = quietLink()
        link:allowSilence()
        T.assertTrue(link.grace_until > Util.now(),
            "the silence should be forgiven for a while")
        T.assertTrue(link.grace_until - Util.now() <= Link.OPEN_GRACE + 1,
            "and only for a while: a peer that has really gone must still be noticed")
    end)

    T.it("stops forgiving it the moment the peer speaks", function()
        -- Given up as soon as the opening is over rather than left to run
        -- its length, so a link that dies just afterwards is still noticed
        -- in the usual few seconds.
        local link = quietLink()
        link:allowSilence()
        link:expectAnswers()
        T.assertNil(link.grace_until, "it went on forgiving a peer that had answered")
    end)
end)

T.describe("forgiving a device that was not running", function()
    --[[
    A suspended reader takes its whole process with it, and every deadline
    here is wall-clock. From a log, and it cost the pair more than a minute:

        22:32:02 [follower] dialled through in 0.08s
        ... the loop stops for 55.5 seconds ...
        22:32:57 [leader]   accepted a connection from 169.254.13.2:43313
        22:32:57 [leader]   link L out CHALLENGE 60      (and nine more)
        22:32:58 [follower] link F closing handshake timed out age=55.6s in=0/0B

    The connection was fine. The other device woke a second earlier,
    accepted it and called ten times. This one woke, measured a handshake
    against a clock that had run while it was not, threw the connection
    away and rebuilt the radio underneath the challenges arriving on it.

    None of that time was the peer's, so none of it is charged to them.
    ]]
    local Link = require("duo/link")
    local Util = require("duo/util")

    local function sleptThrough(seconds)
        local now = Util.now()
        return setmetatable({
            state = "handshake",
            -- Made a moment before the freeze, and nothing has crossed it.
            created_at = now - seconds - 0.5,
            last_rx = now - seconds - 0.5,
            last_tx = 0,
            is_leader = false,
            closed_with = nil,
            close = function(self, reason) self.closed_with = reason end,
        }, { __index = Link })
    end

    T.it("would otherwise time out a handshake that never had its chance", function()
        local link = sleptThrough(55)
        link:checkTimers()
        T.assertEquals(link.closed_with, "handshake timed out",
            "the fixture is not actually past the deadline")
    end)

    T.it("gives the handshake its full allowance from when the device woke", function()
        local link = sleptThrough(55)
        link:forgive(55)
        link:checkTimers()
        T.assertNil(link.closed_with,
            "a connection was thrown away for time the device spent asleep")
    end)

    T.it("does not forgive a peer that went quiet while the loop was turning", function()
        -- The whole point is which of the two was not running. A peer that
        -- stopped answering a device that was awake throughout is still a
        -- peer that has gone.
        local link = sleptThrough(55)
        link:forgive(0)
        link:checkTimers()
        T.assertEquals(link.closed_with, "handshake timed out")
    end)

    T.it("leaves a link made after the freeze exactly where it is", function()
        --[[
        A connection the kernel took while the process was down is handed
        over the moment it comes back, so it is made during the stopped
        poll and lived through none of it. Moving its clocks puts them in
        the future:

            23:09:01 link L closing peer disconnected age=-103.4s state=handshake

        A link a hundred seconds old before it was made, on a device that
        then had nothing to do for a minute and a half.
        ]]
        local now = Util.now()
        local link = sleptThrough(55)
        -- Made now, which is after the loop was last known to be turning.
        link.created_at = now
        link.last_rx = now
        link:forgive(55, now - 55)
        T.assertEquals(link.created_at, now, "a link was aged before it existed")
        T.assertEquals(link.last_rx, now)
        link:checkTimers()
        T.assertNil(link.closed_with)
    end)

    T.it("leaves nothing-sent-yet alone rather than moving it", function()
        -- Zero is not a time. A leader repeats its challenge once a second
        -- from last_tx, and a last_tx pushed into the future is a challenge
        -- that never goes out again.
        local link = sleptThrough(55)
        link:forgive(55)
        T.assertEquals(link.last_tx, 0)
    end)
end)

os.exit(T.run())
