--[[--
Serial transport — two readers joined by a wire.

Written for Bluetooth, which was a mistake about the hardware: the readers
this runs on have no Bluetooth radio at all. What it is for now is a cable —
the debug UART on each device, TX to RX and a common ground, which on a
matched pair needs no level shifting because both sides are the same.

It talks to any character device, so a bound RFCOMM channel or a USB gadget
serial port would work equally well on hardware that has them. A
pseudo-terminal is how the suite exercises it, and it is worth being plain
about what that does and does not prove: the framing, the handshake and the
state machine, yes; baud rates, framing errors, a full FIFO or anything
electrical, no. Those wait for a wire.

The reason to want it is that there is nothing here to reconnect. Every
fault this plugin has chased — associating, power saving, cells that have to
be rebuilt, links that die at eight seconds — is a radio fault. A line is
simply there whenever both devices have power.

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
local ENOENT     = 2
local EIO        = 5
local EBUSY      = 16
local EACCES     = 13

local READ_SIZE = 4096
local MAX_OUT_BUFFER = 64 * 1024

--- True when this device can use the serial transport at all.
function SerialTransport.isAvailable()
    return has_ffi and has_bit and ffi ~= nil and bit ~= nil
end

--[[--
What an errno means on this line, rather than what number it was.

"errno 5" on a reader's screen is a number to go and search for; what it
means here is one of three or four specific things somebody can act on. EIO
is the one this line produces most, and it does not mean the hardware has
failed -- it means the tty was hung up, which is what happens when a login
prompt on the same device is stopped or restarted underneath an open
descriptor.
--]]--
function SerialTransport.why(errno)
    if errno == ENOENT then return "there is no such device" end
    if errno == EIO then
        return "errno 5: the line was hung up, which usually means a login prompt on this device was stopped or restarted underneath it"
    end
    if errno == EBUSY then return "errno 16: something else has the line open" end
    if errno == EACCES then return "errno 13: not allowed to open it" end
    return ("errno %d"):format(errno)
end

--[[--
True when `path` exists and can be opened.

Never with `io.open`, which is a *blocking* open, and a blocking open on a
serial line is a way to stop the reader dead. A tty whose CLOCAL flag is
clear makes open() wait for carrier -- and three soldered wires carry TX, RX
and ground, so there is no carrier and it waits for ever. What that looks
like is not an error: it is a reader that never finishes starting, and a
diagnostic screen that never appears, which is precisely how it turned up.

O_NONBLOCK is the whole of the fix. It makes open() return whatever state
the line is in, which is all this ever needed to know.
--]]--
function SerialTransport.exists(path)
    if not path or path == "" then return false end
    if not SerialTransport.isAvailable() then return false end
    local fd = ffi.C.open(path, bit.bor(O_RDWR, O_NOCTTY, O_NONBLOCK))
    if fd < 0 then
        -- Present but write-only, or held exclusively, still counts as
        -- present. Only "no such file" says it is not there.
        return ffi.errno() ~= ENOENT
    end
    ffi.C.close(fd)
    return true
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

    --[[
    A tty in its default mode echoes what it receives and rewrites
    newlines, which would corrupt the protocol and feed every message
    straight back to its sender. Raw mode is not optional.

    `clocal` and `-crtscts` are what make three wires work. Both describe
    signals that are not connected: CLOCAL clear means the line waits for
    carrier, which on TX, RX and ground never comes -- so a blocking open
    hangs for ever and a hangup can arrive out of nowhere. CRTSCTS means the
    kernel will not transmit until CTS is asserted, which on those same
    three wires it never is, so bytes queue and never leave. Neither can be
    left to whatever the console happened to set.

    Software flow control is deliberately *not* on by default. It is the
    right answer for a line of one's own and the wrong one for this line: on
    these readers the wire is also the system console, so a single stray
    XOFF -- one 0x13 out of a framing error at the wrong speed, which is
    exactly what setting a wire up produces -- stops the port until an XON
    that may never come. Everything that writes to the console then blocks,
    the reader included. That is not a transfer running slowly, it is two
    devices wedged, and it is what happened. See wire_flow_control.
    ]]
    if not options.skip_stty then
        local flow = options.flow_control and "ixon ixoff" or "-ixon -ixoff"
        os.execute(("stty -F %s raw -echo clocal -crtscts %s %s 2>/dev/null")
            :format(path, flow, tostring(options.baud or 115200)))
    end

    local fd = ffi.C.open(path, bit.bor(O_RDWR, O_NOCTTY, O_NONBLOCK))
    if fd < 0 then
        return nil, ("could not open %s: %s"):format(path, SerialTransport.why(ffi.errno()))
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
    return false, ("write failed: " .. SerialTransport.why(ffi.errno()))
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
    return nil, ("read failed: " .. SerialTransport.why(ffi.errno()))
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
