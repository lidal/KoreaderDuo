--[[--
The real device, through koreader-base.

**Not yet run on a Paperwhite.** Everything else in this app is exercised
by the suite against `device/fake.lua`; this file is the seam where the
suite stops and the hardware starts, and it cannot be tested here. Treat
every symbol name below as needing confirmation against the koreader-base
revision actually built -- which is why `open()` probes for each one and
says which is missing rather than failing somewhere deeper with a nil.

What it needs from koreader-base:

* `ffi/blitbuffer`  -- the drawing target. A 4bpp grey buffer matching the
  panel, which is what the display list is replayed into.
* a framebuffer module -- `ffi/framebuffer_mxcfb` on an i.MX6 Kindle.
  Provides `refreshPartialImp` / `refreshFullImp`, the two e-ink update
  modes that matter.
* `ffi/input` -- raw touch and key events off `/dev/input/*`.
* `ffi/freetype` -- glyph rasterising, for the app's own chrome. The
  *book's* text is drawn by CREngine itself and does not come through
  here; this is for labels, the shelf and the typography panel.

The display list is replayed rather than drawn directly for the reason
`device/api.lua` gives: it is what lets every view be tested without a
framebuffer. The cost is one extra pass over a few hundred operations,
which is nothing beside an e-ink refresh.

@module duonative.device.kobase
--]]--

local Api = require("app/device/api")

local Kobase = {}

--[[--
The modules this backend stands on, and what it wants from each.

Probed by name so that a missing or renamed one produces "koreader-base
has no ffi/framebuffer_mxcfb" on the first run rather than an arithmetic
error on a nil three calls later. The names are the thing most likely to
be wrong, and this is the cheapest way to find out which.
--]]--
Kobase.NEEDS = {
    { module = "ffi/blitbuffer", wants = { "new" } },
    { module = "ffi/input", wants = { "open" } },
}

--- Framebuffer modules to try, best first. i.MX6 Kindles are mxcfb.
Kobase.FRAMEBUFFERS = {
    "ffi/framebuffer_mxcfb",
    "ffi/framebuffer_linux",
    "ffi/framebuffer",
}

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
            found.framebuffer = module
            found.framebuffer_name = name
            break
        end
    end
    if not found.framebuffer then
        missing[#missing+1] = "a framebuffer module (tried "
            .. table.concat(Kobase.FRAMEBUFFERS, ", ") .. ")"
    end
    return found, missing
end

--------------------------------------------------------------------------
-- The surface
--------------------------------------------------------------------------

local Surface = {}
Surface.__index = Surface

--[[--
Records like the fake, then replays into a BlitBuffer on `commit`.

Identical recording behaviour to `device/fake.lua` on purpose: the suite
asserts on the display list, so if this one recorded differently the suite
would be testing something the device does not do.
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
Replays the display list into the blit buffer.

Grey runs 0 (black) to 15 (white) in this app's vocabulary, and
BlitBuffer's 4bpp colour constructors take the same range -- but the sense
of it is worth checking on the device before trusting it, since getting it
inverted produces a readable screen in photographic negative rather than
an error.
--]]--
function Surface:commit()
    local buffer = self.buffer
    for _, op in ipairs(self.recorded) do
        if op.op == "fill" then
            buffer:paintRect(op.rect.x, op.rect.y, op.rect.w, op.rect.h,
                self:grey(op.grey))
        elseif op.op == "rect" then
            buffer:paintBorder(op.rect.x, op.rect.y, op.rect.w, op.rect.h,
                op.width, self:grey(op.grey))
        elseif op.op == "text" and self.rasteriser then
            self.rasteriser(buffer, op)
        elseif op.op == "image" and op.handle and op.handle.blitbuffer then
            buffer:blitFrom(op.handle.blitbuffer, op.rect.x, op.rect.y)
        end
    end
    return #self.recorded
end

function Surface:grey(level)
    -- One place, so an inverted panel is one edit rather than a hunt.
    return self.colour_for and self.colour_for(level) or level
end

--------------------------------------------------------------------------
-- The device
--------------------------------------------------------------------------

local Device = {}
Device.__index = Device

--[[--
Opens the panel and the input devices.

@tparam[opt] table options
    rasteriser  function(blitbuffer, text_op) -- draws one string.
                Supplied by the platform so this file need not decide how
                fonts are found; see `platform.lua`.
    light_path  sysfs node for the frontlight
@treturn table device, or nil plus a reason naming what was missing
--]]--
function Kobase.open(options)
    options = options or {}
    local found, missing = probe()
    if #missing > 0 then
        return nil, "koreader-base is missing: " .. table.concat(missing, ", ")
    end

    local fb = found.framebuffer.open and found.framebuffer:open() or found.framebuffer
    if not fb then return nil, "the framebuffer would not open" end

    local buffer = fb.bb or fb.full_bb
    if not buffer then return nil, "the framebuffer has no blit buffer" end
    local width = buffer:getWidth()
    local height = buffer:getHeight()

    local input = found["ffi/input"]
    local ok_input = pcall(function() input.open() end)

    return setmetatable({
        fb = fb,
        input = ok_input and input or nil,
        surface = newSurface(buffer, width, height, options.rasteriser),
        w = width, h = height,
        light_path = options.light_path,
        suspend_handlers = {},
        resume_handlers = {},
    }, Device)
end

function Device:screen() return self.surface end
function Device:size() return self.w, self.h end

--[[--
Draws and updates the panel.

Partial by default. A full refresh clears the ghosting a long run of
partial updates leaves behind, and costs a visible black flash -- so it is
asked for at the points a reader expects a flash anyway: opening a book,
coming back from sleep, leaving a dialogue.
--]]--
function Device:refresh(rect, how)
    self.surface:commit()
    self.surface:reset()
    local fb = self.fb
    if how == Api.FULL then
        if fb.refreshFull then fb:refreshFull(rect.x, rect.y, rect.w, rect.h) end
    elseif how == Api.FAST then
        if fb.refreshFast then fb:refreshFast(rect.x, rect.y, rect.w, rect.h)
        elseif fb.refreshPartial then fb:refreshPartial(rect.x, rect.y, rect.w, rect.h) end
    else
        if fb.refreshPartial then fb:refreshPartial(rect.x, rect.y, rect.w, rect.h) end
    end
    return true
end

--[[--
One input event, or nil.

koreader-base's input returns its own event shapes; this maps them onto the
four this app knows about. The mapping is the second most likely thing in
this file to be wrong, after the module names -- `EV_ABS` slots and key
codes differ between Kindle generations, and a PW3's touch controller is
not the same as a PW4's.
--]]--
function Device:poll(timeout_ms)
    if not self.input then return nil end
    local ok, event = pcall(self.input.waitForEvent, (timeout_ms or 50) * 1000)
    if not ok or not event then return nil end
    return self:translate(event)
end

--- Where a raw event becomes one of this app's four kinds.
function Device:translate(event)
    if type(event) ~= "table" then return nil end
    if event.x and event.y then
        return { kind = "tap", x = event.x, y = event.y }
    end
    local KEYS = {
        [105] = "left", [106] = "right", [103] = "up", [108] = "down",
        [139] = "menu", [158] = "back", [116] = "power",
    }
    if event.code and KEYS[event.code] then
        return { kind = "key", key = KEYS[event.code] }
    end
    return nil
end

--------------------------------------------------------------------------
-- The light
--------------------------------------------------------------------------

--[[--
Reads the frontlight out of sysfs.

Not through koreader-base's PowerD, which is part of KOReader's frontend
rather than the base. A Kindle's light is a single integer in a sysfs file
and reading it directly is both simpler and one fewer thing to port. The
node differs by model, so the path is configuration rather than a constant.
--]]--
function Device:frontlight()
    if not self.light_path then return nil end
    local handle = io.open(self.light_path, "r")
    if not handle then return nil end
    local value = tonumber(handle:read("*l"))
    handle:close()
    -- No warmth on a Paperwhite 3; later devices would report one here.
    return value, nil
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
    local handle = io.open("/sys/class/power_supply/bd7181x_bat/capacity", "r")
    if not handle then return nil, false end
    local percent = tonumber(handle:read("*l"))
    handle:close()
    return percent, false
end

function Device:onSuspend(fn) self.suspend_handlers[#self.suspend_handlers+1] = fn end
function Device:onResume(fn) self.resume_handlers[#self.resume_handlers+1] = fn end

--[[--
Gives the framebuffer back.

Not optional on a Kindle. The app took the panel from whatever was drawing
on it, and a process that exits without closing it leaves a reader showing
a half-drawn screen that nothing will repaint -- which looks exactly like
the device having died.
--]]--
function Device:close()
    if self.input and self.input.close then pcall(self.input.close) end
    if self.fb and self.fb.close then pcall(function() self.fb:close() end) end
    self.closed = true
    return true
end

return Kobase
