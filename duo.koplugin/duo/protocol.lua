--[[--
Wire protocol for KOReader Duo.

The link between the two devices carries one message per line:

    <TYPE> key=value key=value ... \n

`TYPE` is uppercase ASCII, keys are lowercase ASCII, and values are
percent-encoded so that a value may contain spaces, `=` or newlines
(file names and book titles do). The format is deliberately trivial:
it needs no JSON library, survives a partial read, is cheap to parse on
a slow e-ink device, and is readable in a `tcpdump` when something goes
wrong.

@module duo.protocol
--]]--

local Protocol = {}

--- Bumped when the message grammar changes incompatibly.
--- 2: the roles became leader and follower, and `master_page` with them.
--- A pair mid-upgrade is refused at the handshake, which beats one device
--- reading a field the other never sends and quietly showing page nil.
Protocol.VERSION = 2

--- A single message may not exceed this (a book path plus a title fits easily).
Protocol.MAX_LINE = 4096

-- Message types.
Protocol.CHALLENGE = "CHALLENGE" -- leader -> peer, on accept: nonce for the token proof
Protocol.HELLO     = "HELLO"     -- peer -> leader: identity + proof of the shared token
Protocol.WELCOME   = "WELCOME"   -- leader -> peer: accepted, here is my own proof + your slot
Protocol.DENY      = "DENY"      -- leader -> peer: rejected (bad token, wrong version, full)
Protocol.PING      = "PING"
Protocol.PONG      = "PONG"
Protocol.STATE     = "STATE"     -- leader -> peer: the page this peer must display
Protocol.TURN      = "TURN"      -- peer -> leader: user turned the page on the follower
Protocol.GOTO      = "GOTO"      -- peer -> leader: user jumped to an absolute page
Protocol.DOC       = "DOC"       -- leader -> peer: open this document
Protocol.DOCACK    = "DOCACK"    -- peer -> leader: what became of the book you named
Protocol.HOME      = "HOME"      -- leader -> peer: I closed the book; come back to the list
Protocol.OPEN      = "OPEN"      -- peer -> leader: open this book for the pair
Protocol.GOHOME    = "GOHOME"    -- peer -> leader: I left the book; take us both out
Protocol.TYPO      = "TYPO"      -- either way: lay the book out like this
Protocol.CONF      = "CONF"      -- either way: these are the shared settings
Protocol.LIGHT     = "LIGHT"     -- either way: set the frontlight to this
Protocol.BROWSE    = "BROWSE"    -- leader -> peer: show this part of the book list
Protocol.BTURN     = "BTURN"     -- peer -> leader: user swiped the book list
Protocol.SHELF     = "SHELF"     -- peer -> leader: the two shelves differ / match
Protocol.LIB_REQ   = "LIB_REQ"   -- peer -> leader: what is in the shared folder?
Protocol.LIB_ITEM  = "LIB_ITEM"  -- leader -> peer: one book in it
Protocol.LIB_END   = "LIB_END"   -- leader -> peer: that is the whole folder
Protocol.BOOK_REQ  = "BOOK_REQ"  -- peer -> leader: I do not have that book
Protocol.BOOK_HEAD = "BOOK_HEAD" -- leader -> peer: here it comes
Protocol.BOOK_DATA = "BOOK_DATA" -- leader -> peer: a chunk of it
Protocol.BOOK_DONE = "BOOK_DONE" -- leader -> peer: that was all of it
Protocol.BOOK_ERR  = "BOOK_ERR"  -- either way: the transfer failed
Protocol.NAP       = "NAP"       -- leader -> peer: I am dozing off / I am back
Protocol.SLEEP     = "SLEEP"     -- either way: I am going to sleep, do the same
Protocol.NOTE      = "NOTE"      -- either way: show this text to the user
Protocol.SYNC      = "SYNC"      -- peer -> leader: (re)send me the current state
Protocol.BYE       = "BYE"       -- either way: closing on purpose

local SAFE = {}
for c in ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"):gmatch(".") do
    SAFE[c] = true
end

--[[--
Percent-encodes anything outside the safe set.

The fast path is not a micro-optimisation, it is the point. Nearly every
value that crosses this link is already safe from end to end -- a page
number, a slot, a digest, and above all a chunk of a book, which travels
under the URL-safe base64 alphabet precisely so that nothing in it ever
needs escaping. Rewriting those a character at a time, with a Lua call per
byte, was costing more than the base64 that produced them: a megabyte of
book is a million calls that all hand back the character they were given.
Looking once, in C, and handing the string straight back is what a value
with nothing to escape in it deserves.
--]]--
local UNSAFE_PATTERN = "[^A-Za-z0-9._%-]"

local function escape(value)
    value = tostring(value)
    if not value:find(UNSAFE_PATTERN) then return value end
    return (value:gsub(".", function(c)
        if SAFE[c] then return c end
        return string.format("%%%02X", string.byte(c))
    end))
end

--- The other half of the same bargain: a value with no `%` in it is
--- already the value, and copying it to prove that is work for nothing.
local function unescape(value)
    if not value:find("%", 1, true) then return value end
    return (value:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

--- Serializes a message into a single `\n` terminated line.
-- Keys are emitted in sorted order so that the wire form is reproducible
-- (which makes both tests and packet dumps a lot easier to read).
-- @string msg_type one of the Protocol.* constants
-- @tparam[opt] table fields map of string keys to string/number/boolean values
-- @treturn string the encoded line, or nil plus an error message
function Protocol.encode(msg_type, fields)
    if type(msg_type) ~= "string" or not msg_type:match("^[A-Z][A-Z0-9_]*$") then
        return nil, "invalid message type"
    end
    local parts = { msg_type }
    if fields then
        local keys = {}
        for key in pairs(fields) do
            if type(key) ~= "string" or not key:match("^[a-z][a-z0-9_]*$") then
                return nil, "invalid field name: " .. tostring(key)
            end
            keys[#keys+1] = key
        end
        table.sort(keys)
        for _, key in ipairs(keys) do
            local value = fields[key]
            if type(value) == "boolean" then
                value = value and "1" or "0"
            end
            parts[#parts+1] = key .. "=" .. escape(value)
        end
    end
    local line = table.concat(parts, " ")
    if #line + 1 > Protocol.MAX_LINE then
        return nil, "message too long"
    end
    return line .. "\n"
end

--- Parses one line (without its trailing newline) into a message table.
-- The returned table has a `type` field plus one string entry per key.
-- @string line
-- @treturn table the message, or nil plus an error message
function Protocol.decode(line)
    if type(line) ~= "string" then return nil, "not a string" end
    line = line:gsub("\r$", "")
    local msg_type, rest = line:match("^([A-Z][A-Z0-9_]*)(.*)$")
    if not msg_type then
        return nil, "malformed message"
    end
    local msg = { type = msg_type }
    for token in rest:gmatch("%S+") do
        local key, value = token:match("^([a-z][a-z0-9_]*)=(.*)$")
        if not key then
            return nil, "malformed field: " .. token
        end
        msg[key] = unescape(value)
    end
    return msg
end

--- Reads a numeric field, returning `default` when absent or not a number.
function Protocol.num(msg, key, default)
    local value = tonumber(msg and msg[key])
    if value == nil then return default end
    return value
end

--- Reads a boolean field ("1" is true, everything else false).
function Protocol.bool(msg, key)
    return msg and msg[key] == "1"
end

local Reader = {}
Reader.__index = Reader

--- Creates a stream reader that turns arbitrary byte chunks into messages.
-- TCP gives us no message boundaries, so everything received is appended
-- here and pulled out again one complete line at a time.
function Protocol.newReader()
    return setmetatable({ buffer = "", at = 1 }, Reader)
end

--- Appends received bytes to the reader.
function Reader:feed(data)
    if not data or #data == 0 then return end
    if self.at > 1 then
        -- Drop what has already been read before growing the buffer, so a
        -- long-lived reader does not carry a transferred book around in it.
        self.buffer = self.buffer:sub(self.at)
        self.at = 1
    end
    self.buffer = self.buffer .. data
end

--- Pops the next complete message.
-- @treturn table message, or nil when no complete line is buffered.
-- On a protocol violation it returns nil plus an error message; the caller
-- should drop the connection, as the stream can no longer be trusted.
--[[--
Read with a cursor rather than by cutting the front off the buffer.

One turn of the poll loop takes a couple of hundred kilobytes off the
socket, which during a transfer is fifty messages. Slicing the buffer after
each of them copied everything still unread -- fifty times, over a buffer
shrinking from the top -- so the reader was moving several megabytes to
deliver a couple of hundred kilobytes. The cursor moves instead, and `feed`
throws away what is behind it when there is more to add.
--]]--
function Reader:next()
    local buffer, at = self.buffer, self.at
    while true do
        local newline = buffer:find("\n", at, true)
        if not newline then
            if #buffer - at + 1 >= Protocol.MAX_LINE then
                self.buffer, self.at = "", 1
                return nil, "message too long"
            end
            self.at = at
            return nil
        end
        local stop = newline - 1
        if stop >= at and buffer:byte(stop) == 13 then stop = stop - 1 end -- a trailing \r
        local line = buffer:sub(at, stop)
        at = newline + 1
        if #line > 0 then
            self.at = at
            return Protocol.decode(line)
        end
        -- Skip blank lines; keepalive newlines are cheap and harmless.
    end
end

--- How many bytes are buffered but not yet turned into messages.
--- The link uses this to stop taking more off the socket while it is still
--- working through what it already has.
function Reader:backlog()
    return #self.buffer - self.at + 1
end

return Protocol
