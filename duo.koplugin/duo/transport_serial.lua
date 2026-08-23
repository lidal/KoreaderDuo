--[[--
Serial transport — the Bluetooth path.

KOReader has no Bluetooth stack of its own, and neither does it need one:
once two devices have an RFCOMM channel bound, the link shows up as an
ordinary character device (`/dev/rfcomm0`) that behaves like a serial port.
This transport talks to any such device, which also makes it work over a
real serial cable, a USB gadget serial port, or a pseudo-terminal — the
last of which is how the test suite exercises it.

The difference from TCP is that there is nothing to connect to: the line is
simply there, symmetric, with no accept step. Whoever is configured as the
leader starts the handshake and repeats it until the other end answers.

Non-blocking I/O needs the raw system calls, so this module uses LuaJIT's
ffi. KOReader ships LuaJIT, so that is a safe dependency; `isAvailable()`
reports the truth for anything else.

@module duo.transport_serial
--]]--

local SerialTransport = {}

local has_ffi, ffi = pcall(require, "ffi")
local has_bit, bit = pcall(require, "bit")

if has_ffi then
    -- Declared once per process; a second identical cdef would throw.
    pcall(ffi.cdef, [[
        int open(const char *pathname, int flags, ...);
        long read(int fd, void *buf, unsigned long count);
        long write(int fd, const void *buf, unsigned long count);
        int close(int fd);
    ]])
end

-- Linux values; this transport only exists on Linux-based readers.
local O_RDWR     = 0x0002
local O_NOCTTY   = 0x0100
local O_NONBLOCK = 0x0800
local EAGAIN     = 11

local READ_SIZE = 4096
local MAX_OUT_BUFFER = 64 * 1024

--- True when this device can use the serial transport at all.
function SerialTransport.isAvailable()
    return has_ffi and has_bit and ffi ~= nil and bit ~= nil
end

--- True when `path` exists and can be opened.
function SerialTransport.exists(path)
    if not path or path == "" then return false end
    local handle = io.open(path, "r")
    if handle then
        handle:close()
        return true
    end
    -- Write-only or exclusive devices still count as present.
    return io.open(path, "a") ~= nil
end

local Stream = {}
Stream.__index = Stream

--[[--
Opens a serial device.

@string path e.g. "/dev/rfcomm0"
@tparam[opt] table options
    baud       line speed for real UARTs (ignored by RFCOMM)
    skip_stty  do not touch the line settings
@treturn table a Stream, or nil plus an error message
--]]--
function SerialTransport.open(path, options)
    options = options or {}
    if not SerialTransport.isAvailable() then
        return nil, "this build has no ffi, so no serial support"
    end
    if not path or path == "" then
        return nil, "no serial device configured"
    end

    -- A tty in its default mode echoes what it receives and rewrites
    -- newlines, which would corrupt the protocol and feed every message
    -- straight back to its sender. Raw mode is not optional.
    if not options.skip_stty then
        os.execute(("stty -F %s raw -echo %s 2>/dev/null")
            :format(path, tostring(options.baud or 115200)))
    end

    local fd = ffi.C.open(path, bit.bor(O_RDWR, O_NOCTTY, O_NONBLOCK))
    if fd < 0 then
        return nil, ("could not open %s (errno %d)"):format(path, ffi.errno())
    end

    local stream = setmetatable({
        fd = fd,
        path = path,
        out_buffer = "",
        closed = false,
        read_buffer = ffi.new("char[?]", READ_SIZE),
    }, Stream)
    stream:discardStaleTraffic()
    return stream
end

--[[--
Throws away whatever was already on the line.

A serial line is not a connection. There is nothing to hang up, so bytes the
last session wrote are still sitting in the device's buffer when the next
one opens it -- and the next one reads them as though they had just been
sent. That is not a small mess: the leader restarts, sends a fresh
challenge, and the follower answers the challenge from *before* the restart,
so the proof is against a nonce nobody is holding any more. Each side then
reports the other as having the wrong pairing code, for ever, one message
out of step and getting no closer.

Reading the line dry before saying a word is what a connection gets for
free. Bounded, because a device that hands back bytes indefinitely is a
device to give up on rather than to keep reading.
--]]--
function Stream:discardStaleTraffic()
    local dropped = 0
    for _ = 1, 64 do
        local count = tonumber(ffi.C.read(self.fd, self.read_buffer, READ_SIZE))
        if count <= 0 then break end
        dropped = dropped + count
        if count < READ_SIZE then break end
    end
    return dropped
end

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

function Stream:flush()
    if self.closed then return false, "closed" end
    if #self.out_buffer == 0 then return true end
    local written = ffi.C.write(self.fd, self.out_buffer, #self.out_buffer)
    if written >= 0 then
        self.out_buffer = self.out_buffer:sub(tonumber(written) + 1)
        return true
    end
    if ffi.errno() == EAGAIN then
        return true -- the line is busy; the rest goes out on a later poll
    end
    return false, ("write failed (errno %d)"):format(ffi.errno())
end

function Stream:receive()
    if self.closed then return nil, "closed" end
    local count = ffi.C.read(self.fd, self.read_buffer, READ_SIZE)
    if count > 0 then
        return ffi.string(self.read_buffer, count)
    end
    if count == 0 then
        -- End of file on a tty means the other end let go of the line.
        return nil, "closed"
    end
    if ffi.errno() == EAGAIN then
        return "" -- nothing to read right now, which is the normal case
    end
    return nil, ("read failed (errno %d)"):format(ffi.errno())
end

function Stream:close()
    if self.closed then return end
    self.closed = true
    ffi.C.close(self.fd)
end

function Stream:isClosed()
    return self.closed
end

--- Bytes still waiting to go out, so a bulk sender knows when to pause.
function Stream:pending()
    return #self.out_buffer
end

function Stream:getPeerName()
    return self.path
end

return SerialTransport
