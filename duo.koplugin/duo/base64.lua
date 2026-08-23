--[[--
Base64, so a book can travel down a link that carries text.

The Duo protocol is one line of printable characters per message, which is
what makes it easy to debug and equally happy on a socket or a serial line.
A book is not printable, so it goes across encoded — a third larger, which
is a much better trade than percent-encoding's threefold.

Written for speed, which is not usually worth doing in Lua and is here. A
book is the one thing Duo moves that is measured in megabytes rather than
bytes, and every one of them passes through this file twice: once on the
device sending it and once on the device receiving it. On a reader's
processor the arithmetic below was costing more than the Wi-Fi it was
feeding, so a transfer that should have been limited by the radio was
limited by this instead. Everything that can be worked out once is worked
out once, at load, into lookup tables; the loops that remain do table
lookups and nothing else.

@module duo.base64
--]]--

local Base64 = {}

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

--[[--
The URL-safe alphabet from the same standard (RFC 4648 §5), which differs
only in its last two characters.

This is the one a book actually travels under. The protocol keeps its lines
to a safe character set and percent-encodes the rest, and `+` and `/` are
not in it — so with the ordinary alphabet roughly one character in thirty
triples in length on the wire. Text barely notices; a real book is
compressed, its bytes look random, and the line grows past the protocol's
limit often enough to break the transfer. Swapping two characters removes
the problem at the source: nothing here ever needs escaping.
--]]--
local URL_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

local floor = math.floor
local char = string.char
local concat = table.concat

--------------------------------------------------------------------------
-- The tables everything below runs on
--------------------------------------------------------------------------

--[[--
Every twelve-bit value as the two characters that stand for it.

Four thousand and ninety-six short strings, built once. A triple of bytes
is twenty-four bits, so encoding one becomes two lookups and a join rather
than four searches through the alphabet and three joins.
--]]--
local function pairsFor(alphabet)
    local single = {}
    for index = 1, 64 do
        single[index - 1] = alphabet:sub(index, index)
    end
    local pairs_of = {}
    for high = 0, 63 do
        local prefix = single[high]
        local base = high * 64
        for low = 0, 63 do
            pairs_of[base + low] = prefix .. single[low]
        end
    end
    return pairs_of
end

--- Splitting a byte across two output characters, precomputed.
local HIGH_NIBBLE, LOW_NIBBLE = {}, {}
for byte = 0, 255 do
    HIGH_NIBBLE[byte] = floor(byte / 16)
    LOW_NIBBLE[byte] = (byte % 16) * 256
end

--- And putting one back together again, the same way round.
local SIX_TO_HIGH, SIX_TO_MID_HIGH, SIX_TO_MID_LOW = {}, {}, {}
local SIX_TO_LOW_HIGH, SIX_TO_LOW = {}, {}
for value = 0, 63 do
    SIX_TO_HIGH[value] = value * 4
    SIX_TO_MID_HIGH[value] = floor(value / 16)
    SIX_TO_MID_LOW[value] = (value % 16) * 16
    SIX_TO_LOW_HIGH[value] = floor(value / 4)
    SIX_TO_LOW[value] = (value % 4) * 64
end

--[[--
Which six-bit value a character stands for, looked up by its byte.

By the byte rather than by the character, deliberately: it means the decoder
can pull four characters out of the string with one call and never cut a
one-character string out of it, which is where the old decoder spent most of
its time.
--]]--
local function decoderFor(alphabet)
    local map = {}
    for index = 1, 64 do
        map[alphabet:byte(index)] = index - 1
    end
    return map
end

local ENCODE_PAIRS = pairsFor(ALPHABET)
local ENCODE_PAIRS_URL = pairsFor(URL_ALPHABET)
local DECODE_MAP = decoderFor(ALPHABET)
local DECODE_MAP_URL = decoderFor(URL_ALPHABET)

--------------------------------------------------------------------------
-- Encoding
--------------------------------------------------------------------------

--[[--
How much is joined before the result is put aside.

`table.concat` over a list has to walk the whole list, and a megabyte of
book is a lot of entries. Joining a few dozen at a time keeps that list
short without building the long string one piece at a time, which is the
other way to be slow.
--]]--
local BATCH = 64

--[[--
Twelve bytes at a time, which is four groups of three.

`string.byte` is a C call, and asking it for three bytes means one call for
every four characters produced -- for a book, hundreds of thousands of them,
and the call was costing more than the work it was fetching for. Twelve
bytes is four times the payload for the same call, and the eight lookups
that follow join in one go, which the interpreter does as a single
operation over a run of registers rather than seven separate joins.

Twelve rather than more because `string.byte` returns its bytes on the
stack, and a longer run starts to cost what it saves.
--]]--
local BULK = 12

--- Encodes a byte string with the given pair table.
local function encodeWith(data, pairs_of)
    if not data or #data == 0 then return "" end
    local length = #data
    local out, count = {}, 0
    local batch, held = {}, 0
    local position = 1

    local last_bulk = length - BULK + 1
    while position <= last_bulk do
        local b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12 =
            data:byte(position, position + 11)
        held = held + 1
        batch[held] =
            pairs_of[b1 * 16 + HIGH_NIBBLE[b2]] .. pairs_of[LOW_NIBBLE[b2] + b3] ..
            pairs_of[b4 * 16 + HIGH_NIBBLE[b5]] .. pairs_of[LOW_NIBBLE[b5] + b6] ..
            pairs_of[b7 * 16 + HIGH_NIBBLE[b8]] .. pairs_of[LOW_NIBBLE[b8] + b9] ..
            pairs_of[b10 * 16 + HIGH_NIBBLE[b11]] .. pairs_of[LOW_NIBBLE[b11] + b12]
        if held == BATCH then
            count = count + 1
            out[count] = concat(batch)
            held = 0
        end
        position = position + BULK
    end

    -- Whatever whole triples are left over after the bulk of it.
    while position + 2 <= length do
        local a, b, c = data:byte(position, position + 2)
        held = held + 1
        batch[held] = pairs_of[a * 16 + HIGH_NIBBLE[b]] .. pairs_of[LOW_NIBBLE[b] + c]
        position = position + 3
    end

    -- And the last one or two bytes, padded out to a full group.
    local remaining = length - position + 1
    if remaining == 1 then
        local a = data:byte(position)
        held = held + 1
        -- The byte's eight bits fill the first two characters exactly, so
        -- the pair for it with a zero byte after is the pair wanted.
        batch[held] = pairs_of[a * 16] .. "=="
    elseif remaining == 2 then
        local a, b = data:byte(position, position + 1)
        held = held + 1
        batch[held] = pairs_of[a * 16 + HIGH_NIBBLE[b]] .. pairs_of[LOW_NIBBLE[b]]:sub(1, 1) .. "="
    end

    if held > 0 then
        count = count + 1
        out[count] = concat(batch, "", 1, held)
    end
    return concat(out, "", 1, count)
end

--------------------------------------------------------------------------
-- Decoding
--------------------------------------------------------------------------

--- One group of four characters, as the bytes they stand for.
--- Returns nil when any of the four is not in the alphabet.
local function group(map, c1, c2, c3, c4)
    local v1, v2, v3, v4 = map[c1], map[c2], map[c3], map[c4]
    if v1 == nil or v2 == nil or v3 == nil or v4 == nil then return nil end
    return char(SIX_TO_HIGH[v1] + SIX_TO_MID_HIGH[v2],
                SIX_TO_MID_LOW[v2] + SIX_TO_LOW_HIGH[v3],
                SIX_TO_LOW[v3] + v4)
end

--- Decodes a base64 string against the given byte-indexed map.
-- @treturn string the bytes, or nil plus an error message
local function decodeWith(text, map)
    if not text or text == "" then return "" end
    -- Looking is cheaper than rewriting, and what comes off the wire never
    -- has whitespace in it.
    if text:find("%s") then text = (text:gsub("%s", "")) end
    local length = #text
    if length % 4 ~= 0 then
        return nil, "truncated base64"
    end

    local out, count = {}, 0
    local batch, held = {}, 0

    --[[
    Everything up to the last group, which is the only one that may carry
    padding and so the only one worth testing for it. Sixteen characters a
    turn for the same reason the encoder takes twelve bytes: one call
    instead of four.
    ]]
    local final = length - 3          -- where the last group starts
    local position = 1
    local last_bulk = final - 16
    while position <= last_bulk do
        local c1, c2, c3, c4, c5, c6, c7, c8,
              c9, c10, c11, c12, c13, c14, c15, c16 = text:byte(position, position + 15)
        --[[
        Written out rather than calling `group` four times. Four calls a
        turn, each handing back a string, cost more than the bulk read
        saved: measured, the tidy version decoded at less than half the
        speed of this one. This is the one loop in Duo where that trade is
        worth making, because it is the one a whole book goes through.
        ]]
        local v1, v2, v3, v4 = map[c1], map[c2], map[c3], map[c4]
        local v5, v6, v7, v8 = map[c5], map[c6], map[c7], map[c8]
        local v9, v10, v11, v12 = map[c9], map[c10], map[c11], map[c12]
        local v13, v14, v15, v16 = map[c13], map[c14], map[c15], map[c16]
        if v1 == nil or v2 == nil or v3 == nil or v4 == nil
            or v5 == nil or v6 == nil or v7 == nil or v8 == nil
            or v9 == nil or v10 == nil or v11 == nil or v12 == nil
            or v13 == nil or v14 == nil or v15 == nil or v16 == nil then
            return nil, "invalid base64 character"
        end
        held = held + 1
        batch[held] = char(
            SIX_TO_HIGH[v1] + SIX_TO_MID_HIGH[v2],
            SIX_TO_MID_LOW[v2] + SIX_TO_LOW_HIGH[v3],
            SIX_TO_LOW[v3] + v4,
            SIX_TO_HIGH[v5] + SIX_TO_MID_HIGH[v6],
            SIX_TO_MID_LOW[v6] + SIX_TO_LOW_HIGH[v7],
            SIX_TO_LOW[v7] + v8,
            SIX_TO_HIGH[v9] + SIX_TO_MID_HIGH[v10],
            SIX_TO_MID_LOW[v10] + SIX_TO_LOW_HIGH[v11],
            SIX_TO_LOW[v11] + v12,
            SIX_TO_HIGH[v13] + SIX_TO_MID_HIGH[v14],
            SIX_TO_MID_LOW[v14] + SIX_TO_LOW_HIGH[v15],
            SIX_TO_LOW[v15] + v16)
        if held == BATCH then
            count = count + 1
            out[count] = concat(batch)
            held = 0
        end
        position = position + 16
    end

    while position < final do
        local decoded = group(map, text:byte(position, position + 3))
        if not decoded then return nil, "invalid base64 character" end
        held = held + 1
        batch[held] = decoded
        position = position + 4
    end

    -- The last group, where the padding lives.
    local c1, c2, c3, c4 = text:byte(final, length)
    local v1, v2 = map[c1], map[c2]
    if v1 == nil or v2 == nil then
        return nil, "invalid base64 character"
    end
    local tail
    if c3 == 61 then -- "="
        if c4 ~= 61 then return nil, "invalid base64 character" end
        tail = char(SIX_TO_HIGH[v1] + SIX_TO_MID_HIGH[v2])
    elseif c4 == 61 then
        local v3 = map[c3]
        if v3 == nil then return nil, "invalid base64 character" end
        tail = char(SIX_TO_HIGH[v1] + SIX_TO_MID_HIGH[v2],
                    SIX_TO_MID_LOW[v2] + SIX_TO_LOW_HIGH[v3])
    else
        tail = group(map, c1, c2, c3, c4)
        if not tail then return nil, "invalid base64 character" end
    end
    held = held + 1
    batch[held] = tail

    count = count + 1
    out[count] = concat(batch, "", 1, held)
    return concat(out, "", 1, count)
end

--------------------------------------------------------------------------
-- What the rest of Duo calls
--------------------------------------------------------------------------

--- Encodes a byte string, standard alphabet.
function Base64.encode(data)
    return encodeWith(data, ENCODE_PAIRS)
end

--- Decodes a standard base64 string.
-- @treturn string the bytes, or nil plus an error message
function Base64.decode(text)
    return decodeWith(text, DECODE_MAP)
end

--- Encodes a byte string with the URL-safe alphabet, which is what the
--- protocol carries: every character it produces passes through unescaped.
function Base64.encodeUrl(data)
    return encodeWith(data, ENCODE_PAIRS_URL)
end

--- Decodes a URL-safe base64 string.
-- @treturn string the bytes, or nil plus an error message
function Base64.decodeUrl(text)
    return decodeWith(text, DECODE_MAP_URL)
end

return Base64
