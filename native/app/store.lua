--[[--
Settings that survive a restart.

A Lua table written out as Lua source and read back with `loadstring`,
which is what KOReader does and for the same reasons: there is no JSON
library to depend on, the file is legible when something has gone wrong,
and the parser is the interpreter that is already running.

Written to a temporary file and renamed over the real one. A reader loses
power without warning -- that is the premise of the whole device -- and a
settings file half-written is a reader that comes back with no settings at
all. Rename is atomic on the card's filesystem; write-in-place is not.

Values are restricted to strings, numbers, booleans and tables of the
same. Not a limitation in practice, and it means the serialiser cannot be
handed a function and produce a file that will not load.

@module duonative.store
--]]--

local Store = {}
Store.__index = Store

local function quote(text)
    return ("%q"):format(text):gsub("\\\n", "\\n")
end

--[[--
Serialises a value, sorting table keys.

Sorted because two devices comparing their settings is a thing this app
does, and because a settings file whose lines move about between saves is
one nobody can diff.
--]]--
local function dump(value, indent)
    indent = indent or ""
    local kind = type(value)
    if kind == "string" then return quote(value) end
    if kind == "number" or kind == "boolean" then return tostring(value) end
    if kind ~= "table" then return "nil" end

    local keys = {}
    for key in pairs(value) do
        if type(key) == "string" or type(key) == "number" then keys[#keys+1] = key end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

    local inner = indent .. "  "
    local parts = {}
    for _, key in ipairs(keys) do
        local name = type(key) == "string" and ("[%s]"):format(quote(key))
            or ("[%d]"):format(key)
        parts[#parts+1] = ("%s%s = %s"):format(inner, name, dump(value[key], inner))
    end
    if #parts == 0 then return "{}" end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

Store.dump = dump

function Store.open(path)
    local self = setmetatable({ path = path, data = {} }, Store)
    self:load()
    return self
end

function Store:load()
    local handle = io.open(self.path, "r")
    if not handle then return false end
    local source = handle:read("*a")
    handle:close()
    local chunk = loadstring("return " .. source)
    if not chunk then return false end
    local ok, value = pcall(chunk)
    -- A corrupt file is ignored rather than fatal. Losing settings is a
    -- nuisance; refusing to start because of them is a brick.
    if ok and type(value) == "table" then self.data = value end
    return ok
end

function Store:flush()
    local temporary = self.path .. ".new"
    local handle, err = io.open(temporary, "w")
    if not handle then return false, err end
    handle:write(dump(self.data), "\n")
    handle:close()
    os.remove(self.path)
    return os.rename(temporary, self.path) and true or false
end

function Store:get(key, fallback)
    local value = self.data[key]
    if value == nil then return fallback end
    return value
end

function Store:set(key, value)
    self.data[key] = value
    return value
end

function Store:all() return self.data end

return Store
