--[[--
Duo's own log file.

KOReader's `logger.dbg` goes nowhere unless the whole reader was started in
debug mode, which is not something to ask of somebody who just wants to
report that their two devices disagreed about a page. So Duo keeps a log of
its own, off by default, written where a USB cable can reach it.

Bounded on purpose. A reader has a card, not a disk, and a log that grows
without end is a bug of its own -- so the file is capped and rolled over
once, which leaves at most two files and always keeps the most recent
history.

Kept free of any KOReader dependency, so the awkward parts -- rolling over
at the boundary, surviving a full card -- can be tested without one.

@module duo.log
--]]--

local Log = {}

--- How large the log may grow before it is rolled over, and how much
--- history that leaves: this many bytes twice, worst case.
Log.MAX_BYTES = 512 * 1024

local Writer = {}
Writer.__index = Writer

--[[--
Opens `path` for appending, rolling over an oversized log first.

@string path where to write
@treturn table|nil the writer, or nil plus a reason
--]]--
function Log.open(path)
    if type(path) ~= "string" or path == "" then return nil, "no path" end
    local writer = setmetatable({ path = path, size = 0 }, Writer)
    local ok, err = writer:reopen()
    if not ok then return nil, err end
    return writer
end

--- Bytes already in the file, so an append picks up where it left off.
local function sizeOf(path)
    local handle = io.open(path, "rb")
    if not handle then return 0 end
    local size = handle:seek("end") or 0
    handle:close()
    return size
end

function Writer:reopen()
    if self.handle then return true end
    local handle, err = io.open(self.path, "a")
    if not handle then return false, err or "could not open the log" end
    self.handle = handle
    self.size = sizeOf(self.path)
    return true
end

--[[--
Moves the log aside and starts a new one.

One generation kept, deliberately. Two files is enough to hold what
happened just before somebody noticed something was wrong, and a reader
with a full card is worse off than one with a short log.
--]]--
function Writer:rollOver()
    if self.handle then
        self.handle:close()
        self.handle = nil
    end
    os.remove(self.path .. ".1")
    os.rename(self.path, self.path .. ".1")
    self.size = 0
    return self:reopen()
end

--[[--
Writes one line, rolling over first when this one would not fit.

Failures are swallowed rather than raised: a log that cannot be written is
a nuisance, and a log that takes the reader down with it when the card
fills up is a good deal worse than no log at all.
--]]--
function Writer:write(line)
    if not self.handle and not self:reopen() then return false end
    line = tostring(line)
    if self.size + #line + 1 > Log.MAX_BYTES then
        if not self:rollOver() then return false end
    end
    local ok = pcall(function()
        self.handle:write(line, "\n")
        self.handle:flush()
    end)
    if not ok then
        -- The card may have filled, or the file gone out from under us.
        self.handle = nil
        return false
    end
    self.size = self.size + #line + 1
    return true
end

function Writer:close()
    if not self.handle then return end
    pcall(function() self.handle:close() end)
    self.handle = nil
end

--- Everything the log holds, newest file last. For handing to somebody.
function Writer:getPaths()
    local paths = {}
    local previous = io.open(self.path .. ".1", "rb")
    if previous then
        previous:close()
        paths[#paths+1] = self.path .. ".1"
    end
    paths[#paths+1] = self.path
    return paths
end

--[[--
One line, stamped and tidied.

The timestamp is wall clock, because the question a log answers is "what
happened when I pressed the thing", and that is a question about the clock
on the wall. Newlines inside a message are folded so one event stays one
line: a log that has to be read by eye is read a line at a time.

@string role  what this device was being at the time
@param ...    the parts of the message, as they came from the caller
--]]--
function Log.format(role, ...)
    local parts = {}
    for index = 1, select("#", ...) do
        local value = select(index, ...)
        parts[#parts+1] = tostring(value)
    end
    local text = table.concat(parts, " "):gsub("[\r\n]+", " | ")
    return ("%s [%s] %s"):format(os.date("%Y-%m-%d %H:%M:%S"), role or "off", text)
end

return Log
