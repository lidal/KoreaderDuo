--[[--
A reader that is not there, for the suite and the desktop.

Records every draw instead of rasterising it, queues input instead of
waiting for a finger, and counts refreshes. That makes three things
testable that otherwise need a Paperwhite on the desk: what the library
grid actually drew, that a page turn refreshed once rather than four
times, and that the two halves of a spread agree.

Screen defaults to a Paperwhite 3's 1072x1448, because a UI that is only
ever tested at some convenient size is a UI that will be wrong on the
device.

@module duonative.device.fake
--]]--

local Api = require("app/device/api")

local Fake = {}

local Surface = {}
Surface.__index = Surface

local function newSurface(width, height)
    return setmetatable({ w = width, h = height, recorded = {}, depth = 0 }, Surface)
end

function Surface:size() return self.w, self.h end

--[[--
Every draw lands here.

The clip stack is recorded with each op rather than applied to it: the
suite wants to know what the UI asked for, and a widget that drew outside
its own box is a bug worth seeing rather than one silently trimmed.
--]]--
function Surface:record(op)
    op.clip = self.clip_rect
    self.recorded[#self.recorded+1] = op
    return op
end

function Surface:fill(rect, grey)
    return self:record{ op = "fill", rect = rect, grey = grey or 15 }
end

function Surface:rect(rect, grey, width)
    return self:record{ op = "rect", rect = rect, grey = grey or 0, width = width or 1 }
end

function Surface:text(x, y, str, style)
    style = style or {}
    return self:record{
        op = "text", x = x, y = y, text = tostring(str),
        size = style.size or 20, face = style.face, grey = style.grey or 0,
        bold = style.bold or false,
    }
end

function Surface:image(rect, handle)
    return self:record{ op = "image", rect = rect, handle = handle }
end

function Surface:clip(rect, fn)
    local previous = self.clip_rect
    self.clip_rect = rect
    local ok, err = pcall(fn)
    self.clip_rect = previous
    if not ok then error(err, 0) end
end

function Surface:ops() return self.recorded end

--- Throws the display list away, which is what a repaint starts with.
function Surface:reset() self.recorded = {} end

--[[--
The ops of one kind, in order -- the query the suite actually wants.

`surface:find("text")` reads better in a test than a loop over `ops()`,
and a test that reads well is one somebody will keep up to date.
--]]--
function Surface:find(kind)
    local out = {}
    for _, op in ipairs(self.recorded) do
        if op.op == kind then out[#out+1] = op end
    end
    return out
end

--- Every string drawn, concatenated -- for "does the page mention this?".
function Surface:allText()
    local parts = {}
    for _, op in ipairs(self:find("text")) do parts[#parts+1] = op.text end
    return table.concat(parts, "\n")
end

local Device = {}
Device.__index = Device

--[[--
Opens a device that is not there.

@tparam[opt] table options width, height, light (false for no frontlight)
--]]--
function Fake.open(options)
    options = options or {}
    local width = options.width or 1072
    local height = options.height or 1448
    return setmetatable({
        surface = newSurface(width, height),
        w = width, h = height,
        queued = {},
        refreshes = {},
        light_level = options.light == false and nil or 10,
        light_warmth = options.light == false and nil or 0,
        battery_percent = options.battery or 80,
        suspend_handlers = {},
        resume_handlers = {},
        closed = false,
    }, Device)
end

function Device:screen() return self.surface end
function Device:size() return self.w, self.h end

function Device:refresh(rect, how)
    self.refreshes[#self.refreshes+1] = { rect = rect, how = how or Api.PARTIAL }
end

--- Queues input the next poll will return. The suite's only way in.
function Device:feed(event)
    self.queued[#self.queued+1] = event
end

function Device:poll()
    return table.remove(self.queued, 1)
end

function Device:frontlight() return self.light_level, self.light_warmth end

function Device:setFrontlight(level, warmth)
    if self.light_level == nil then return false end
    self.light_level = level
    if warmth ~= nil then self.light_warmth = warmth end
    return true
end

function Device:battery() return self.battery_percent, false end

function Device:onSuspend(fn) self.suspend_handlers[#self.suspend_handlers+1] = fn end
function Device:onResume(fn) self.resume_handlers[#self.resume_handlers+1] = fn end

--- Pretends to sleep, so the suite can exercise what wakes up wrong.
function Device:sleep()
    for _, fn in ipairs(self.suspend_handlers) do fn() end
end

function Device:wake()
    for _, fn in ipairs(self.resume_handlers) do fn() end
end

function Device:close() self.closed = true end

return Fake
