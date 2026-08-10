--[[--
A small, self-contained SHA-256.

Used only to prove knowledge of the shared pairing token without putting it
on the wire. KOReader ships LuaJIT, so the fast `bit` library is used when
present; the arithmetic fallback keeps this module usable from a plain
Lua 5.1 interpreter (which is how the unit tests run it).

@module duo.sha256
--]]--

local Sha256 = {}

local band, bxor, bnot, rshift, lshift

local has_bit, bit = pcall(require, "bit")
if has_bit and bit then
    local function u32(x) return x % 4294967296 end
    band   = function(a, b) return u32(bit.band(a, b)) end
    bxor   = function(a, b) return u32(bit.bxor(a, b)) end
    bnot   = function(a) return u32(bit.bnot(a)) end
    rshift = function(a, n) return u32(bit.rshift(a, n)) end
    lshift = function(a, n) return u32(bit.lshift(a, n)) end
else
    local function bitwise(a, b, op)
        local result, value = 0, 1
        for _ = 1, 32 do
            local abit, bbit = a % 2, b % 2
            if op(abit, bbit) then result = result + value end
            a = (a - abit) / 2
            b = (b - bbit) / 2
            value = value * 2
        end
        return result
    end
    band   = function(a, b) return bitwise(a, b, function(x, y) return x + y == 2 end) end
    bxor   = function(a, b) return bitwise(a, b, function(x, y) return x + y == 1 end) end
    bnot   = function(a) return 4294967295 - a end
    rshift = function(a, n) return math.floor(a / 2^n) end
    lshift = function(a, n) return (a * 2^n) % 4294967296 end
end

local function rrotate(x, n)
    return band(rshift(x, n) + lshift(x, 32 - n), 4294967295)
end

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function pad(message)
    local length = #message
    local bit_length = length * 8
    local padding = "\128" .. string.rep("\0", (55 - length) % 64)
    local tail = ""
    -- 64 bit big-endian bit count
    local remaining = bit_length
    for _ = 1, 8 do
        tail = string.char(remaining % 256) .. tail
        remaining = math.floor(remaining / 256)
    end
    return message .. padding .. tail
end

--- Returns the SHA-256 of `message` as a lowercase hex string.
function Sha256.hex(message)
    local h = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
    local padded = pad(message or "")
    local w = {}
    for block = 1, #padded, 64 do
        for i = 0, 15 do
            local o = block + i * 4
            w[i+1] = padded:byte(o) * 16777216 + padded:byte(o+1) * 65536
                   + padded:byte(o+2) * 256 + padded:byte(o+3)
        end
        for i = 17, 64 do
            local s0 = bxor(bxor(rrotate(w[i-15], 7), rrotate(w[i-15], 18)), rshift(w[i-15], 3))
            local s1 = bxor(bxor(rrotate(w[i-2], 17), rrotate(w[i-2], 19)), rshift(w[i-2], 10))
            w[i] = (w[i-16] + s0 + w[i-7] + s1) % 4294967296
        end
        local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
        for i = 1, 64 do
            local s1 = bxor(bxor(rrotate(e, 6), rrotate(e, 11)), rrotate(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local temp1 = (hh + s1 + ch + K[i] + w[i]) % 4294967296
            local s0 = bxor(bxor(rrotate(a, 2), rrotate(a, 13)), rrotate(a, 22))
            local maj = bxor(bxor(band(a, b), band(a, c)), band(b, c))
            local temp2 = (s0 + maj) % 4294967296
            hh, g, f, e = g, f, e, (d + temp1) % 4294967296
            d, c, b, a = c, b, a, (temp1 + temp2) % 4294967296
        end
        h[1] = (h[1] + a) % 4294967296
        h[2] = (h[2] + b) % 4294967296
        h[3] = (h[3] + c) % 4294967296
        h[4] = (h[4] + d) % 4294967296
        h[5] = (h[5] + e) % 4294967296
        h[6] = (h[6] + f) % 4294967296
        h[7] = (h[7] + g) % 4294967296
        h[8] = (h[8] + hh) % 4294967296
    end
    local out = {}
    for i = 1, 8 do
        out[i] = string.format("%08x", h[i])
    end
    return table.concat(out)
end

return Sha256
