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

    local events = { leader = {}, follower = {} }
    local leader = Link.new{
        stream = leader_stream,
        is_leader = true,
        token = leader_token,
        name = "Kindle-L",
        slot = 1,
        on_message = function(_, msg) events.leader[#events.leader+1] = msg end,
        on_close = function(_, reason) events.leader.closed = reason end,
        on_ready = function() events.leader.ready = true end,
    }
    local follower = Link.new{
        stream = follower_stream,
        is_leader = false,
        token = follower_token,
        name = "Kindle-F",
        on_message = function(_, msg) events.follower[#events.follower+1] = msg end,
        on_close = function(_, reason) events.follower.closed = reason end,
        on_ready = function() events.follower.ready = true end,
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

os.exit(T.run())
