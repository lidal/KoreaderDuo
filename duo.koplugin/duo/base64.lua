--[[--
Base64, so a book can travel down a link that carries text.

The Duo protocol is one line of printable characters per message, which is
what makes it easy to debug and equally happy on a socket or a serial line.
A book is not printable, so it goes across encoded — a third larger, which
is a much better trade than percent-encoding's threefold.

@module duo.base64
--]]--

local Base64 = {}

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local decode_map = {}
for index = 1, #ALPHABET do
    decode_map[ALPHABET:sub(index, index)] = index - 1
end

--- Encodes a byte string.
function Base64.encode(data)
    if not data or #data == 0 then return "" end
    local out = {}
    local length = #data
    local position = 1

    while position + 2 <= length do
        local a, b, c = data:byte(position, position + 2)
        local triple = a * 65536 + b * 256 + c
        out[#out+1] = ALPHABET:sub(math.floor(triple / 262144) + 1, math.floor(triple / 262144) + 1)
            .. ALPHABET:sub(math.floor(triple / 4096) % 64 + 1, math.floor(triple / 4096) % 64 + 1)
            .. ALPHABET:sub(math.floor(triple / 64) % 64 + 1, math.floor(triple / 64) % 64 + 1)
            .. ALPHABET:sub(triple % 64 + 1, triple % 64 + 1)
        position = position + 3
    end

    local remaining = length - position + 1
    if remaining == 1 then
        local a = data:byte(position)
        local triple = a * 65536
        out[#out+1] = ALPHABET:sub(math.floor(triple / 262144) + 1, math.floor(triple / 262144) + 1)
            .. ALPHABET:sub(math.floor(triple / 4096) % 64 + 1, math.floor(triple / 4096) % 64 + 1)
            .. "=="
    elseif remaining == 2 then
        local a, b = data:byte(position, position + 1)
        local triple = a * 65536 + b * 256
        out[#out+1] = ALPHABET:sub(math.floor(triple / 262144) + 1, math.floor(triple / 262144) + 1)
            .. ALPHABET:sub(math.floor(triple / 4096) % 64 + 1, math.floor(triple / 4096) % 64 + 1)
            .. ALPHABET:sub(math.floor(triple / 64) % 64 + 1, math.floor(triple / 64) % 64 + 1)
            .. "="
    end

    return table.concat(out)
end

--- Decodes a base64 string.
-- @treturn string the bytes, or nil plus an error message
function Base64.decode(text)
    if not text or text == "" then return "" end
    text = text:gsub("%s", "")
    if #text % 4 ~= 0 then
        return nil, "truncated base64"
    end

    local out = {}
    for position = 1, #text, 4 do
        local chunk = text:sub(position, position + 3)
        local padding = 0
        local values = {}
        for index = 1, 4 do
            local character = chunk:sub(index, index)
            if character == "=" then
                padding = padding + 1
                values[index] = 0
            else
                local value = decode_map[character]
                if not value then
                    return nil, "invalid base64 character"
                end
                values[index] = value
            end
        end
        local triple = values[1] * 262144 + values[2] * 4096 + values[3] * 64 + values[4]
        local a = math.floor(triple / 65536)
        local b = math.floor(triple / 256) % 256
        local c = triple % 256
        if padding == 0 then
            out[#out+1] = string.char(a, b, c)
        elseif padding == 1 then
            out[#out+1] = string.char(a, b)
        else
            out[#out+1] = string.char(a)
        end
    end

    return table.concat(out)
end

return Base64
