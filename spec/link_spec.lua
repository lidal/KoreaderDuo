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

--- Brings up a connected master/slave pair on loopback.
local function connectedPair(master_token, slave_token)
    local port = freePort()
    local server = assert(TcpTransport.listen(port, "127.0.0.1"))
    local connector = assert(TcpTransport.connect("127.0.0.1", port, 3))

    local slave_stream, master_stream
    local deadline = socket.gettime() + 3
    while socket.gettime() < deadline and not (slave_stream and master_stream) do
        master_stream = master_stream or server:accept()
        if not slave_stream then
            local result = connector:poll()
            if result then slave_stream = result end
        end
        socket.sleep(0.005)
    end
    assert(slave_stream and master_stream, "sockets did not connect")

    local events = { master = {}, slave = {} }
    local master = Link.new{
        stream = master_stream,
        is_master = true,
        token = master_token,
        name = "Kindle-L",
        slot = 1,
        on_message = function(_, msg) events.master[#events.master+1] = msg end,
        on_close = function(_, reason) events.master.closed = reason end,
        on_ready = function() events.master.ready = true end,
    }
    local slave = Link.new{
        stream = slave_stream,
        is_master = false,
        token = slave_token,
        name = "Kindle-F",
        on_message = function(_, msg) events.slave[#events.slave+1] = msg end,
        on_close = function(_, reason) events.slave.closed = reason end,
        on_ready = function() events.slave.ready = true end,
    }
    return master, slave, events, server
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
        local master, slave, events, server = connectedPair("K7F2QX", "k7f-2qx")
        T.assertTrue(pumpUntil({ master, slave }, function()
            return master:isReady() and slave:isReady()
        end), "handshake did not complete")
        T.assertTrue(events.master.ready)
        T.assertTrue(events.slave.ready)
        T.assertEquals(master.peer_name, "Kindle-F")
        T.assertEquals(slave.peer_name, "Kindle-L")
        T.assertEquals(slave.slot, 1)
        master:close("done"); slave:close("done"); server:close()
    end)

    T.it("refuses a slave with the wrong token", function()
        local master, slave, events, server = connectedPair("K7F2QX", "WRONG9")
        T.assertTrue(pumpUntil({ master, slave }, function()
            return master:isClosed() and slave:isClosed()
        end), "bad pairing was not rejected")
        T.assertTrue(not master:isReady())
        T.assertMatch(events.slave.closed, "pairing code")
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
        local master = Link.new{ stream = accepted, is_master = true, token = token, name = "L" }
        local slave = Link.new{ stream = client, is_master = false, token = token, name = "F" }

        -- Watch every byte the two of them exchange.
        local seen = {}
        for _, stream in ipairs({ accepted, client }) do
            local original_send = stream.send
            stream.send = function(self, data)
                seen[#seen+1] = data or ""
                return original_send(self, data)
            end
        end
        pumpUntil({ master, slave }, function()
            return master:isReady() and slave:isReady()
        end)
        local transcript = table.concat(seen)
        T.assertTrue(#transcript > 0, "nothing was exchanged")
        T.assertNil(transcript:find(token, 1, true), "the pairing token leaked onto the wire")
        master:close(); slave:close(); server:close()
    end)

    T.it("accepts anybody when no token is set", function()
        local master, slave, _, server = connectedPair("", "")
        T.assertTrue(pumpUntil({ master, slave }, function()
            return master:isReady() and slave:isReady()
        end))
        master:close(); slave:close(); server:close()
    end)
end)

T.describe("link traffic", function()
    T.it("carries application messages both ways", function()
        local master, slave, events, server = connectedPair("T0KEN2", "T0KEN2")
        pumpUntil({ master, slave }, function()
            return master:isReady() and slave:isReady()
        end)

        master:send(Protocol.STATE, { page = 42, pages = 300 })
        slave:send(Protocol.TURN, { dir = -1 })
        T.assertTrue(pumpUntil({ master, slave }, function()
            return #events.slave > 0 and #events.master > 0
        end), "messages did not arrive")

        T.assertEquals(events.slave[1].type, "STATE")
        T.assertEquals(Protocol.num(events.slave[1], "page"), 42)
        T.assertEquals(events.master[1].type, "TURN")
        T.assertEquals(Protocol.num(events.master[1], "dir"), -1)
        master:close(); slave:close(); server:close()
    end)

    T.it("keeps itself alive with heartbeats and measures latency", function()
        local master, slave, _, server = connectedPair("T0KEN2", "T0KEN2")
        pumpUntil({ master, slave }, function()
            return master:isReady() and slave:isReady()
        end)
        -- PING_INTERVAL is 4s; wait past it and confirm nothing timed out.
        local started = socket.gettime()
        pumpUntil({ master, slave }, function()
            return socket.gettime() - started > 4.5
        end, 6)
        T.assertTrue(master:isReady(), "master dropped the link")
        T.assertTrue(slave:isReady(), "slave dropped the link")
        T.assertTrue(master.latency ~= nil or slave.latency ~= nil, "no round trip measured")
        master:close(); slave:close(); server:close()
    end)

    T.it("notices when the peer vanishes", function()
        local master, slave, events, server = connectedPair("T0KEN2", "T0KEN2")
        pumpUntil({ master, slave }, function()
            return master:isReady() and slave:isReady()
        end)
        slave.stream:close() -- yanked cable / device suspended
        T.assertTrue(pumpUntil({ master }, function()
            return master:isClosed()
        end), "master did not notice the peer leaving")
        T.assertMatch(events.master.closed, "disconnect")
        server:close()
    end)

    T.it("says goodbye on a clean close", function()
        local master, slave, events, server = connectedPair("T0KEN2", "T0KEN2")
        pumpUntil({ master, slave }, function()
            return master:isReady() and slave:isReady()
        end)
        master:close("stopped by user", true)
        T.assertTrue(pumpUntil({ slave }, function()
            return slave:isClosed()
        end), "slave missed the goodbye")
        T.assertMatch(events.slave.closed, "stopped by user")
        server:close()
    end)
end)

T.describe("discovery", function()
    T.it("finds a master over UDP", function()
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

return T.run()
