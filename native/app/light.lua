--[[--
The frontlight, in the shape `duo/frontlight` expects.

The engine matches brightness across devices with different ranges -- a
Kindle's light is 0-24 and a Kobo's 0-100 -- by carrying a percentage and
converting at each end. All of that is already written, in
`duo/frontlight.lua`, and it reads its two arguments as KOReader's
`powerd` and `Device`. So this adapts one device from `device/api.lua`
into those two shapes and then uses the plugin's module unchanged.

Writing the conversion again here was the alternative, and it is the wrong
one twice over: the arithmetic has already been got right once, and two
copies of it would be two copies to keep in step with a wire format they
both have to agree with.

A Paperwhite 3 has a frontlight and no natural light -- warmth arrived
with later devices -- so `hasNaturalLight` answers for what the device
actually reports rather than for what the model usually has.

@module duonative.light
--]]--

local Frontlight = require("duo/frontlight")

local Light = {}

--[[--
Builds the `powerd` and `Device` pair from one device.

@tparam table device a `device/api.lua` implementation
@tparam[opt] table options max (default 24, a Kindle's range)
@treturn table powerd, or nil when there is no light
@treturn table device shim
--]]--
function Light.shim(device, options)
    options = options or {}
    local level, warmth = device:frontlight()
    if level == nil then return nil end

    local powerd = {
        fl_min = 0,
        fl_max = options.max or 24,
        fl_intensity = level,
        -- A reader remembers its brightness across a switch-off, so "off"
        -- is a separate fact from "zero". Reported as off only at zero,
        -- which is the honest answer for a device that has no separate
        -- switch to read.
        is_fl_on = level > 0,
    }
    if warmth ~= nil then
        powerd.fl_warmth_min = 0
        powerd.fl_warmth_max = options.warmth_max or 24
        powerd.fl_warmth = warmth
    end

    local shim = {
        hasFrontlight = function() return true end,
        hasNaturalLight = function() return warmth ~= nil end,
        -- Kindles can take their light to zero, so this is true. A device
        -- that cannot would make the engine ask for the lowest step
        -- instead of darkness, which is handled inside the module.
        canTurnFrontlightOff = function() return true end,
    }
    return powerd, shim
end

--- What this device's light is doing, as the engine wants to hear it.
function Light.snapshot(device, options)
    local powerd, shim = Light.shim(device, options)
    if not powerd then return nil end
    return Frontlight.snapshot(powerd, shim)
end

--[[--
Moves the light to match the other device.

@treturn table the changes actually made, or nil when nothing needed doing.
    The engine reads this to say what it matched, and `Frontlight.describe`
    will index it -- so nil and not false, which is what a boolean return
    from here used to crash on.
--]]--
function Light.apply(device, wanted, options)
    local powerd, shim = Light.shim(device, options)
    if not powerd then return nil end

    local changes = Frontlight.differences(wanted, powerd, shim)
    if not changes then return nil end

    local level = changes.intensity
    if changes.on == false then
        level = 0
    elseif changes.on == true and (level == nil or level == 0) then
        -- Told to come on with no brightness named: back to something
        -- visible rather than on at zero, which looks like a light that
        -- did not come on.
        level = math.max(powerd.fl_intensity, 1)
    end
    device:setFrontlight(level or powerd.fl_intensity, changes.warmth)
    return changes
end

return Light
