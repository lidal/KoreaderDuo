--[[--
Small helpers shared by the Duo modules.

@module duo.util
--]]--

local Util = {}

local has_socket, socket = pcall(require, "socket")

--- Seconds since some fixed point, with sub-second resolution when available.
-- Only ever used for differences (timeouts, heartbeats), never as a date.
function Util.now()
    if has_socket and socket and socket.gettime then
        return socket.gettime()
    end
    return os.time()
end

local seeded = false
local function seed()
    if seeded then return end
    seeded = true
    local entropy = os.time() + math.floor((os.clock() * 1000000) % 1000000)
    if has_socket and socket and socket.gettime then
        entropy = entropy + math.floor((socket.gettime() * 1000) % 1000000)
    end
    -- The address of a fresh table differs between two devices booted alike.
    local address = tostring({}):match("0x(%x+)")
    if address then
        entropy = entropy + (tonumber(address:sub(-6), 16) or 0)
    end
    math.randomseed(entropy)
    for _ = 1, 5 do math.random() end
end

--- Returns `count` random bytes as a lowercase hex string.
-- Good enough to keep two nearby pairings from colliding and to stop a
-- replayed proof from working; it is not a cryptographic RNG.
function Util.randomHex(count)
    seed()
    local out = {}
    for i = 1, (count or 8) do
        out[i] = string.format("%02x", math.random(0, 255))
    end
    return table.concat(out)
end

-- Digits and letters that survive being read off one e-ink screen and typed
-- into another: no 0/O, 1/I/L, 5/S, 8/B.
local TOKEN_ALPHABET = "234679ACDEFGHJKMNPQRTUVWXYZ"

--- Returns a short pairing token that is easy to read aloud and to type.
function Util.newPairingToken(length)
    seed()
    local out = {}
    for i = 1, (length or 6) do
        local index = math.random(1, #TOKEN_ALPHABET)
        out[i] = TOKEN_ALPHABET:sub(index, index)
    end
    return table.concat(out)
end

--- Normalizes a token the user typed (case and stray spaces do not matter).
function Util.normalizeToken(token)
    if not token then return "" end
    return (tostring(token):upper():gsub("[^%w]", ""))
end

--- Nearest whole number, halves going up.
function Util.round(value)
    return math.floor(value + 0.5)
end

function Util.clamp(value, min_value, max_value)
    if value < min_value then return min_value end
    if value > max_value then return max_value end
    return value
end

--- Truncates a string for display, appending an ellipsis when cut.
function Util.ellipsize(text, max_length)
    text = tostring(text or "")
    if #text <= max_length then return text end
    return text:sub(1, max_length - 1) .. "…"
end

return Util
