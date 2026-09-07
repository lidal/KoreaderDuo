--[[--
A running checksum, for the one thing on this link that is not signed.

Every message Duo sends after the handshake carries a truncated HMAC, which
is a stronger integrity check than anything here -- but a book does not.
Signing each chunk of one would mean a SHA-256 over every kilobyte of a
several-megabyte file, on a reader whose processor is already the slow part
of a transfer, and that is why book chunks were left unsigned.

Left unsigned is not the same as left unchecked. The receiver already
counts the bytes, so a chunk the line ate is caught; what it cannot catch
is a chunk that arrived the right length and wrong, which on a wire with no
parity is exactly what a flipped bit looks like. A CRC catches that, costs
one table lookup per byte, and was designed for precisely this.

CRC-32, the ordinary one -- the polynomial used by zip, gzip and PNG --
so a digest Duo computes can be checked against any other tool that speaks
it.

@module duo.checksum
--]]--

local Checksum = {}

local has_bit, bit = pcall(require, "bit")

--[[--
The table, built once.

Two hundred and fifty-six entries, each the remainder of one byte's worth
of division. Building it costs eight shifts per entry and is done at load;
using it costs a lookup and an exclusive-or per byte, which is the whole
reason to have a table at all.
--]]--
local TABLE
local function buildTable()
    if TABLE then return TABLE end
    TABLE = {}
    for index = 0, 255 do
        local value = index
        for _ = 1, 8 do
            if value % 2 == 1 then
                value = bit.bxor(bit.rshift(value, 1), 0xEDB88320)
            else
                value = bit.rshift(value, 1)
            end
        end
        TABLE[index] = bit.band(value, 0xFFFFFFFF)
    end
    return TABLE
end

--- True when this build can compute one at all.
function Checksum.isAvailable()
    return has_bit and bit ~= nil
end

--[[--
Starts a running checksum.

@treturn table something with `add` and `value`, or nil where there is no
    bit library to do it with -- in which case the caller carries on without
    one rather than refusing to send a book.
--]]--
function Checksum.new()
    if not Checksum.isAvailable() then return nil end
    local crc = { state = 0xFFFFFFFF }
    local lookup = buildTable()

    --[[
    Fed a string at a time, in the sizes the transfer already uses. The loop
    is per byte because a CRC is per byte; what keeps it cheap is that
    everything inside it is a table index and an exclusive-or, and that the
    strings arriving are the chunks the sender was reading anyway.
    ]]
    function crc:add(data)
        if not data or #data == 0 then return self end
        local state = self.state
        local byte = string.byte
        local bxor, band, rshift = bit.bxor, bit.band, bit.rshift
        for index = 1, #data do
            state = bxor(rshift(state, 8),
                lookup[band(bxor(state, byte(data, index)), 0xFF)])
        end
        self.state = state
        return self
    end

    --[[--
    The checksum so far, as eight lowercase hex characters.

    Through tohex where there is one, because band hands back a *signed*
    thirty-two bit number and formatting a negative one prints sixteen
    characters of sign extension -- "ffffffffcbf43926" where the answer is
    "cbf43926". Right value, wrong string, and it would have been compared
    against the other device's right string for ever.
    --]]--
    function crc:value()
        local final = bit.bxor(self.state, 0xFFFFFFFF)
        if bit.tohex then return bit.tohex(final) end
        return ("%08x"):format(final % 4294967296)
    end

    return crc
end

--- The checksum of one string, for tests and for anything short.
function Checksum.of(data)
    local crc = Checksum.new()
    if not crc then return nil end
    return crc:add(data):value()
end

return Checksum
