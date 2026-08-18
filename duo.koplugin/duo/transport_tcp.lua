--[[--
TCP transport for KOReader Duo.

Everything here is non-blocking. The plugin is polled from inside KOReader's
UI loop (roughly every 50ms), so a call that blocks is a call that freezes
the reader: connects are started and then polled for completion, reads take
whatever is available, and writes keep a small outgoing buffer for the bytes
the kernel would not take yet.

The transport does not care what runs on top of it. Anything that can
produce a `Stream` (send / receive / close) can carry the Duo protocol,
which is how the same code works over Wi-Fi and over a Bluetooth PAN link.

@module duo.transport_tcp
--]]--

local socket = require("socket")

local TcpTransport = {}

-- How much we are willing to queue for a peer that has stopped reading
-- before we consider the link broken (a stalled e-ink device, typically).
local MAX_OUT_BUFFER = 64 * 1024

--------------------------------------------------------------------------
-- Stream: a connected socket.
--------------------------------------------------------------------------

local Stream = {}
Stream.__index = Stream

function TcpTransport.wrap(sock)
    sock:settimeout(0)
    if sock.setoption then
        pcall(sock.setoption, sock, "tcp-nodelay", true) -- page turns are tiny and latency matters
        pcall(sock.setoption, sock, "keepalive", true)
    end
    return setmetatable({
        sock = sock,
        out_buffer = "",
        closed = false,
    }, Stream)
end

--- Queues `data` and pushes out as much as the socket will take.
-- @treturn boolean true on success, or false plus an error message
function Stream:send(data)
    if self.closed then return false, "closed" end
    if data and #data > 0 then
        if #self.out_buffer + #data > MAX_OUT_BUFFER then
            return false, "peer is not reading"
        end
        self.out_buffer = self.out_buffer .. data
    end
    return self:flush()
end

--- Pushes buffered bytes towards the peer without blocking.
function Stream:flush()
    if self.closed then return false, "closed" end
    if #self.out_buffer == 0 then return true end
    local sent, err, sent_partial = self.sock:send(self.out_buffer)
    local written = sent or sent_partial
    if written and written > 0 then
        self.out_buffer = self.out_buffer:sub(written + 1)
    end
    if sent then
        return true -- the whole buffer was handed to the kernel
    end
    if err == "timeout" or err == "wantwrite" then
        return true -- the rest goes out on a later poll
    end
    return false, err or "send failed"
end

--- Reads whatever has arrived.
-- @treturn string received bytes (possibly empty), or nil plus an error
function Stream:receive()
    if self.closed then return nil, "closed" end
    local data, err, partial = self.sock:receive(8192)
    local received = data or partial
    if received and #received > 0 then
        return received
    end
    if err == "timeout" or err == "wantread" or err == nil then
        return ""
    end
    return nil, err -- "closed" when the peer went away
end

function Stream:close()
    if self.closed then return end
    self.closed = true
    pcall(function() self.sock:close() end)
end

function Stream:isClosed()
    return self.closed
end

--- Bytes still waiting to go out, so a bulk sender knows when to pause.
function Stream:pending()
    return #self.out_buffer
end

--- "1.2.3.4:9970", for the connection status screen.
function Stream:getPeerName()
    local ok, ip, port = pcall(function()
        return self.sock:getpeername()
    end)
    if ok and ip then
        return tostring(ip) .. ":" .. tostring(port)
    end
    return "?"
end

--------------------------------------------------------------------------
-- Server: accepts follower connections.
--------------------------------------------------------------------------

local Server = {}
Server.__index = Server

--- Starts listening on `port`.
-- @treturn table server, or nil plus an error message
function TcpTransport.listen(port, host)
    local sock, err = socket.bind(host or "*", port)
    if not sock then
        return nil, err or "could not bind"
    end
    sock:settimeout(0)
    return setmetatable({ sock = sock, port = port }, Server)
end

--- Accepts one pending connection, if any.
-- @treturn table a Stream, or nil when nobody is knocking
function Server:accept()
    local client = self.sock:accept()
    if not client then return nil end
    return TcpTransport.wrap(client)
end

function Server:close()
    pcall(function() self.sock:close() end)
end

function Server:getPort()
    local _, port = self.sock:getsockname()
    return tonumber(port) or self.port
end

--------------------------------------------------------------------------
-- Connector: a connect attempt in progress.
--------------------------------------------------------------------------

local Connector = {}
Connector.__index = Connector

--- Begins connecting to `host`:`port` without blocking the UI.
-- Poll the returned object until it reports success or failure.
function TcpTransport.connect(host, port, timeout)
    local sock, err = socket.tcp()
    if not sock then return nil, err or "no socket" end
    sock:settimeout(0)
    -- With a zero timeout this returns immediately; the handshake continues
    -- in the kernel and we find out how it went by selecting for writability.
    local ok, connect_err = sock:connect(host, port)
    if not ok and connect_err and connect_err ~= "timeout"
            and not connect_err:match("in progress") then
        pcall(function() sock:close() end)
        return nil, connect_err
    end
    return setmetatable({
        sock = sock,
        host = host,
        port = port,
        deadline = socket.gettime() + (timeout or 10),
        connected = ok and true or false,
    }, Connector)
end

--- Checks on the attempt.
-- @treturn table|boolean|nil a Stream once connected, false plus an error
-- message on failure, or nil while it is still in progress
function Connector:poll()
    if self.connected then
        return TcpTransport.wrap(self.sock)
    end
    local _, writable = socket.select(nil, { self.sock }, 0)
    if writable and writable[1] then
        -- Writable means the handshake finished, successfully or not; a
        -- socket with no peer is a refused connection.
        local peer = self.sock:getpeername()
        if peer then
            self.connected = true
            return TcpTransport.wrap(self.sock)
        end
        self:cancel()
        return false, "connection refused"
    end
    if socket.gettime() > self.deadline then
        self:cancel()
        return false, "connection timed out"
    end
    return nil
end

function Connector:cancel()
    pcall(function() self.sock:close() end)
end

return TcpTransport
