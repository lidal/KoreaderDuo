--[[--
The real device, through koreader-base.

**Not yet run on a Paperwhite.** This is the seam where the suite stops and
the hardware starts. What is different from the first draft of this file is
that its APIs are no longer guesses: they were read off koreader-base and
KOReader itself, and three of them were wrong.

* Input is **not** `ffi/input`; there is no such module. It is a C module,
  `libs/libkoreader-input`, built from `input/input.c` with `-DKINDLE`.
* It does **not** hand back `{ x, y }`. It hands back raw evdev records --
  `{ type, code, value, fd, time }` -- so the touch protocol is this
  file's job. That is what `Touch` below is for.
* `waitForEvent` takes **seconds and microseconds**, not microseconds, and
  returns `true, events` or `false, errno` (`ETIME` on a timeout).

The framebuffer is instantiated exactly as `KindlePaperWhite3:init` does
it: `require("ffi/framebuffer_mxcfb"):new{ device = ..., debug = ... }`,
where `device` is the descriptor in `device/pw3.lua`. That descriptor is
the whole of the coupling to KOReader's frontend, and it is a table of
constants -- which is the answer to the study's biggest open question.

`beforePaint` and `afterPaint` bracket every update. koreader-base's own
comment says they must, and drivers rely on it to batch.

@module duonative.device.kobase
--]]--

local Api = require("app/device/api")
local Pw3 = require("app/device/pw3")

local Kobase = {}

--- The C module that reads the input devices. Not a Lua `ffi/` module.
Kobase.INPUT_LIBRARY = "libs/libkoreader-input"

--- Framebuffer modules to try, best first. i.MX6 Kindles are mxcfb.
Kobase.FRAMEBUFFERS = {
    "ffi/framebuffer_mxcfb",
    "ffi/framebuffer_linux",
}

--[[--
What must be present, and what is wanted from it.

Probed by name so a rename upstream reads as "koreader-base has no
libs/libkoreader-input.waitForEvent" on the first run, rather than an
arithmetic-on-nil three calls later.
--]]--
Kobase.NEEDS = {
    { module = "ffi/blitbuffer", wants = { "new" } },
    { module = Kobase.INPUT_LIBRARY, wants = { "open", "waitForEvent" } },
}

--------------------------------------------------------------------------
-- Linux input, as the kernel actually reports it
--------------------------------------------------------------------------

local EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
local SYN_REPORT = 0
local ABS_X, ABS_Y = 0, 1
local ABS_MT_SLOT = 0x2f
local ABS_MT_POSITION_X, ABS_MT_POSITION_Y = 0x35, 0x36
local ABS_MT_TRACKING_ID = 0x39

--- Kindle key codes. A PW3 has only a power button; the rest are for later
--- models and cost nothing to carry.
local KEYS = {
    [105] = "left", [106] = "right", [103] = "up", [108] = "down",
    [139] = "menu", [158] = "back", [116] = "power",
}

--[[--
Turns a stream of evdev records into taps and swipes.

Protocol B is assumed -- `ABS_MT_SLOT` selecting a contact, position
events filling it in, `ABS_MT_TRACKING_ID` of -1 ending it -- with single
touch `ABS_X`/`ABS_Y` honoured as a fallback. A gesture is decided on
*release* rather than on contact, because that is the only moment the
distance travelled is known, and a reader needs to tell a tap from a swipe
before it does either.

Only the first contact is followed. This app has no use for a second
finger, and a pinch interpreted as two taps would turn an accident into
two page turns.

The thresholds are in pixels on a 300dpi panel: 40px is about 3.4mm, which
is comfortably more than a finger wobbles and comfortably less than
anything meant as a swipe.
--]]--
local Touch = {}
Touch.__index = Touch

Touch.TAP_SLOP = 40
Touch.SWIPE_MIN = 120

local function newTouch()
    return setmetatable({ slot = 0, x = nil, y = nil,
                          start_x = nil, start_y = nil, down = false }, Touch)
end

--[[--
Feeds one record in. Returns an event when a gesture completed.

Nil the rest of the time, which is almost always: a single tap is a dozen
records and only the last of them means anything.
--]]--
function Touch:feed(record)
    local kind, code, value = record.type, record.code, record.value

    if kind == EV_ABS then
        if code == ABS_MT_SLOT then
            self.slot = value
            return nil
        end
        -- Contacts past the first are watched for their end and otherwise
        -- ignored, so letting go of a second finger cannot emit anything.
        if self.slot ~= 0 then return nil end
        if code == ABS_MT_POSITION_X or code == ABS_X then
            self.x = value
        elseif code == ABS_MT_POSITION_Y or code == ABS_Y then
            self.y = value
        elseif code == ABS_MT_TRACKING_ID then
            if value == -1 then
                self.ending = true
            elseif not self.down then
                --[[
                A new contact forgets where the last one was.

                Without this the second tap in a frame starts from the
                first one's position: two taps at opposite corners became
                one 800px diagonal, which is neither a tap nor a swipe and
                so was silently dropped. The suite caught it.

                Only when not already down -- within one contact the
                tracking id can be re-reported, and resetting then would
                throw away the start that is being measured from.
                ]]
                self.down = true
                self.x, self.y = nil, nil
                self.start_x, self.start_y = nil, nil
            end
        end
        return nil
    end

    if kind == EV_KEY and KEYS[code] then
        -- Down only. A key that reported both would turn every press into
        -- two page turns.
        if value == 1 then return { kind = "key", key = KEYS[code] } end
        return nil
    end

    if kind == EV_SYN and code == SYN_REPORT then
        -- A contact's first position often arrives in the same frame as
        -- its tracking id, so the start is taken here if it was not then.
        if self.down and self.start_x == nil then
            self.start_x, self.start_y = self.x, self.y
        end
        if self.ending then return self:release() end
    end
    return nil
end

function Touch:release()
    local from_x, from_y = self.start_x, self.start_y
    local to_x, to_y = self.x, self.y
    self.ending, self.down = false, false
    self.start_x, self.start_y = nil, nil
    if not (from_x and from_y and to_x and to_y) then return nil end

    local dx, dy = to_x - from_x, to_y - from_y
    local adx, ady = math.abs(dx), math.abs(dy)

    if adx < Touch.TAP_SLOP and ady < Touch.TAP_SLOP then
        return { kind = "tap", x = to_x, y = to_y }
    end
    if adx >= Touch.SWIPE_MIN and adx > ady then
        return { kind = "swipe", dir = dx < 0 and "left" or "right" }
    end
    if ady >= Touch.SWIPE_MIN and ady > adx then
        return { kind = "swipe", dir = dy < 0 and "up" or "down" }
    end
    -- Travelled too far to be a tap and not far enough to be a swipe.
    -- Deliberately nothing: a reader's thumb dragging across the page
    -- should not turn it.
    return nil
end

Kobase.Touch = Touch
Kobase.newTouch = newTouch

--------------------------------------------------------------------------
-- The surface
--------------------------------------------------------------------------

local Surface = {}
Surface.__index = Surface

--[[--
Records like the fake, then replays into the BlitBuffer on `commit`.

Identical recording behaviour to `device/fake.lua`, deliberately: the suite
asserts on the display list, so a surface that recorded differently would
make the suite test something the device does not do.
--]]--
local function newSurface(buffer, width, height, rasteriser)
    return setmetatable({
        buffer = buffer, w = width, h = height,
        recorded = {}, rasteriser = rasteriser,
    }, Surface)
end

function Surface:size() return self.w, self.h end
function Surface:ops() return self.recorded end
function Surface:reset() self.recorded = {} end

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
        size = style.size or 20, face = style.face,
        grey = style.grey or 0, bold = style.bold or false,
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

--[[--
4-bit grey, 0 black to 15 white, as this app's vocabulary.

BlitBuffer's `Color4` constructors take the same range and the same sense,
but it is worth checking on the device before trusting it: inverted, the
result is a perfectly readable screen in photographic negative rather than
anything that looks like an error. One function, so fixing it is one edit.
--]]--
function Surface:grey(level)
    local bb = self.blitbuffer_module
    if bb and bb.Color4 then return bb.Color4(level) end
    return level
end

function Surface:commit()
    local buffer = self.buffer
    for _, op in ipairs(self.recorded) do
        if op.op == "fill" then
            buffer:paintRect(op.rect.x, op.rect.y, op.rect.w, op.rect.h, self:grey(op.grey))
        elseif op.op == "rect" then
            buffer:paintBorder(op.rect.x, op.rect.y, op.rect.w, op.rect.h,
                op.width, self:grey(op.grey))
        elseif op.op == "text" and self.rasteriser then
            self.rasteriser(buffer, op, self)
        elseif op.op == "image" and op.handle and op.handle.blitbuffer then
            buffer:blitFrom(op.handle.blitbuffer, op.rect.x, op.rect.y)
        end
    end
    return #self.recorded
end

--------------------------------------------------------------------------
-- The device
--------------------------------------------------------------------------

local Device = {}
Device.__index = Device

local function probe()
    local found, missing = {}, {}
    for _, need in ipairs(Kobase.NEEDS) do
        local ok, module = pcall(require, need.module)
        if not ok or type(module) ~= "table" then
            missing[#missing+1] = need.module
        else
            for _, want in ipairs(need.wants) do
                if module[want] == nil then
                    missing[#missing+1] = ("%s.%s"):format(need.module, want)
                end
            end
            found[need.module] = module
        end
    end
    for _, name in ipairs(Kobase.FRAMEBUFFERS) do
        local ok, module = pcall(require, name)
        if ok and type(module) == "table" then
            found.framebuffer, found.framebuffer_name = module, name
            break
        end
    end
    if not found.framebuffer then
        missing[#missing+1] = "a framebuffer module (tried "
            .. table.concat(Kobase.FRAMEBUFFERS, ", ") .. ")"
    end
    return found, missing
end

--[[--
Opens the panel and the touchscreen.

@tparam[opt] table options
    descriptor  the device descriptor (default `device/pw3`)
    rasteriser  function(blitbuffer, text_op, surface) -- draws one string
    touch_dev   input device to read (default the descriptor's)
    debug       where koreader-base's own chatter goes
@treturn table device, or nil plus a reason naming what was missing
--]]--
function Kobase.open(options)
    options = options or {}
    local found, missing = probe()
    if #missing > 0 then
        return nil, "koreader-base is missing: " .. table.concat(missing, ", ")
    end

    local descriptor = options.descriptor or Pw3.descriptor()
    --[[
    `device` in, `screen` out, in that order -- which is the order KOReader
    uses, so `descriptor.screen` is nil while `init()` runs. That is not an
    oversight to fix: koreader-base's own `init` does not read it, and the
    two genuinely refer to each other.
    ]]
    local ok, fb = pcall(function()
        return found.framebuffer:new{
            device = descriptor,
            -- Must be callable: framebuffer.lua calls self.debug(...)
            -- unconditionally in a few places.
            debug = options.debug or function() end,
        }
    end)
    if not ok or not fb then
        return nil, ("%s would not open: %s"):format(
            tostring(found.framebuffer_name), tostring(fb))
    end
    descriptor.screen = fb

    local buffer = fb.bb
    if not buffer then
        return nil, "the framebuffer came up with no blit buffer"
    end
    local width, height = buffer:getWidth(), buffer:getHeight()

    local input = found[Kobase.INPUT_LIBRARY]
    local touch_dev = options.touch_dev or Pw3.TOUCH_DEV
    local opened = pcall(function() return input.open(touch_dev) end)

    local surface = newSurface(buffer, width, height, options.rasteriser)
    surface.blitbuffer_module = found["ffi/blitbuffer"]

    return setmetatable({
        fb = fb,
        descriptor = descriptor,
        input = opened and input or nil,
        touch_dev = touch_dev,
        touch = newTouch(),
        pending = {},
        surface = surface,
        w = width, h = height,
        light_path = options.light_path or Pw3.LIGHT_PATH,
        suspend_handlers = {},
        resume_handlers = {},
    }, Device)
end

function Device:screen() return self.surface end
function Device:size() return self.w, self.h end

--[[--
Draws and updates the panel.

Partial by default; full where a reader expects a flash anyway -- opening a
book, coming back from sleep, leaving a dialogue -- because a full refresh
is what clears the ghosting a run of partial ones leaves behind.

`beforePaint` before the blits and `afterPaint` after the refresh call,
which koreader-base requires and uses to batch.
--]]--
function Device:refresh(rect, how)
    local fb = self.fb
    if fb.beforePaint then pcall(function() fb:beforePaint() end) end
    self.surface:commit()
    self.surface:reset()

    local x, y, w, h = rect.x, rect.y, rect.w, rect.h
    if how == Api.FULL then
        pcall(function() fb:refreshFull(x, y, w, h) end)
    elseif how == Api.FAST then
        pcall(function() fb:refreshFast(x, y, w, h) end)
    else
        pcall(function() fb:refreshPartial(x, y, w, h) end)
    end

    if fb.afterPaint then pcall(function() fb:afterPaint() end) end
    return true
end

--[[--
One gesture, or nil.

A single `waitForEvent` yields a whole frame of records, which may contain
no gesture or more than one, so decoded events are queued and handed out
one per call. That keeps the app's loop shape -- one event, one repaint --
and stops a frame holding two taps from losing one of them.
--]]--
function Device:poll(timeout_ms)
    local queued = table.remove(self.pending, 1)
    if queued then return queued end
    if not self.input then return nil end

    local milliseconds = timeout_ms or 50
    local ok, result, records = pcall(self.input.waitForEvent,
        math.floor(milliseconds / 1000), (milliseconds % 1000) * 1000)
    -- `false, ETIME` is the ordinary case: nothing happened in the window.
    if not ok or result ~= true or type(records) ~= "table" then return nil end

    for _, record in ipairs(records) do
        local event = self.touch:feed(record)
        if event then self.pending[#self.pending+1] = event end
    end
    return table.remove(self.pending, 1)
end

--------------------------------------------------------------------------
-- The light and the battery
--------------------------------------------------------------------------

local function readNumber(path)
    if not path then return nil end
    local handle = io.open(path, "r")
    if not handle then return nil end
    local value = tonumber(handle:read("*l"))
    handle:close()
    return value
end

--[[--
Reads the frontlight out of sysfs.

Not through KOReader's PowerD, which is part of its frontend rather than
the base. A Kindle's light is one integer in one file; reading it directly
is simpler and one fewer thing to port. No warmth on a PW3 -- that arrived
with later models -- so the second return is nil and `light.lua` takes
that as "no natural light".
--]]--
function Device:frontlight()
    return readNumber(self.light_path), nil
end

function Device:setFrontlight(level)
    if not self.light_path or not level then return false end
    local handle = io.open(self.light_path, "w")
    if not handle then return false end
    handle:write(tostring(math.floor(level)))
    handle:close()
    return true
end

function Device:battery()
    local percent = readNumber(Pw3.BATTERY_PATH)
    local charging = readNumber(Pw3.CHARGING_PATH)
    return percent, (charging or 0) ~= 0
end

function Device:onSuspend(fn) self.suspend_handlers[#self.suspend_handlers+1] = fn end
function Device:onResume(fn) self.resume_handlers[#self.resume_handlers+1] = fn end

--[[--
Gives the framebuffer and the touchscreen back.

Not optional on a Kindle. This app took the panel from whatever was
drawing on it, and a process that exits without closing it leaves a reader
showing a half-drawn screen nothing will repaint -- which looks exactly
like a device that has died.
--]]--
function Device:close()
    if self.input and self.input.closeAll then pcall(self.input.closeAll) end
    if self.fb and self.fb.close then pcall(function() self.fb:close() end) end
    self.closed = true
    return true
end

return Kobase
