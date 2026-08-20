--[[--
Keeping the two readers lit the same way.

Two devices held side by side as one book look wrong when one is brighter
than the other — more obviously wrong, in fact, than a font size that does
not match, because the eye compares the two halves directly.

The complication is that brightness is not a number two devices can agree
on. KOReader's Kindle driver runs the light from 0 to 24; a Kobo runs 0 to
100; a desktop has no light at all. So nothing here sends a level. It sends
a *proportion* of each device's own range, and each end scales it back to
whatever hardware it has — which makes a Kindle and a Kobo agree about
"half" without either knowing what the other's numbers mean.

Warmth is carried the same way, and simply skipped on the devices that have
no warm light, which is most of them.

@module duo.frontlight
--]]--

local Frontlight = {}

--- Percentages either side of this are treated as the same setting.
-- Rounding a proportion back onto a coarse scale — a Kindle's 24 steps —
-- can land a step either way, and without a tolerance the two devices would
-- take turns correcting each other for ever.
Frontlight.TOLERANCE = 3

local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

--[[--
Turns a device level into a percentage of that device's own range.
@treturn number 0-100, or nil when the range is meaningless
--]]--
function Frontlight.toPercent(level, min, max)
    level, min, max = tonumber(level), tonumber(min), tonumber(max)
    if not level or not min or not max or max <= min then return nil end
    return clamp((level - min) / (max - min) * 100, 0, 100)
end

--- Turns a percentage back into a level on this device's range.
function Frontlight.fromPercent(percent, min, max)
    percent, min, max = tonumber(percent), tonumber(min), tonumber(max)
    if not percent or not min or not max or max <= min then return nil end
    local level = min + (clamp(percent, 0, 100) / 100) * (max - min)
    -- Rounded rather than truncated: on a 24-step light, truncating loses
    -- most of a step every time and the two devices drift apart.
    return clamp(math.floor(level + 0.5), min, max)
end

--- True when two percentages are close enough to leave alone.
function Frontlight.same(one, other)
    if one == nil or other == nil then return one == other end
    return math.abs(one - other) <= Frontlight.TOLERANCE
end

--[[--
Reads the frontlight as proportions, from a KOReader powerd.

@tparam table powerd  Device:getPowerDevice()
@tparam table device  the Device table, for its capability flags
@treturn ?table { intensity = 0-100, warmth = 0-100 }
--]]--
function Frontlight.snapshot(powerd, device)
    if not powerd or not device then return nil end
    if not device.hasFrontlight or not device:hasFrontlight() then return nil end

    local snapshot = {}
    snapshot.intensity = Frontlight.toPercent(
        powerd.fl_intensity, powerd.fl_min, powerd.fl_max)
    --[[
    Whether the light is on at all, which is a different question from how
    bright it is. KOReader remembers the brightness across a switch-off, so
    a reader with its light off still reports the level it will go back to
    -- which is why turning the light off used to cross the link as no
    change whatsoever while every nudge of the slider crossed it fine.
    ]]
    if powerd.isFrontlightOn then
        local ok, on = pcall(powerd.isFrontlightOn, powerd)
        if ok and on ~= nil then snapshot.on = on and true or false end
    elseif powerd.is_fl_on ~= nil then
        snapshot.on = powerd.is_fl_on and true or false
    end
    if device.hasNaturalLight and device:hasNaturalLight() then
        snapshot.warmth = Frontlight.toPercent(
            powerd.fl_warmth, powerd.fl_warmth_min, powerd.fl_warmth_max)
    end
    if snapshot.intensity == nil and snapshot.warmth == nil
            and snapshot.on == nil then
        return nil
    end
    return snapshot
end

--[[--
What has to change here for this device to match the other one.

Returns the device-scale values to apply, leaving out anything already
close enough and anything this device cannot do. Nothing is applied for a
warm light on a device that has none, rather than the request being
refused: a pair of different readers should still match on brightness.

@treturn ?table { intensity = level, warmth = level }
--]]--
function Frontlight.differences(wanted, powerd, device)
    if not wanted then return nil end
    local current = Frontlight.snapshot(powerd, device)
    if not current then return nil end

    local changes = nil
    if wanted.intensity ~= nil and current.intensity ~= nil
            and not Frontlight.same(wanted.intensity, current.intensity) then
        local level = Frontlight.fromPercent(
            wanted.intensity, powerd.fl_min, powerd.fl_max)
        -- Some readers cannot turn the light off at all, and asking them to
        -- is asking for the lowest step they have rather than darkness.
        if level == powerd.fl_min and device.canTurnFrontlightOff
                and not device:canTurnFrontlightOff() then
            level = powerd.fl_min + 1
        end
        if level then changes = { intensity = level } end
    end
    -- The switch before the levels. A reader told to go dark does not need
    -- to be walked down to its lowest step on the way.
    if wanted.on ~= nil and current.on ~= nil and wanted.on ~= current.on then
        changes = changes or {}
        changes.on = wanted.on
    end
    if wanted.warmth ~= nil and current.warmth ~= nil
            and not Frontlight.same(wanted.warmth, current.warmth) then
        local level = Frontlight.fromPercent(
            wanted.warmth, powerd.fl_warmth_min, powerd.fl_warmth_max)
        if level then
            changes = changes or {}
            changes.warmth = level
        end
    end
    return changes
end

--- A short line for the notification, in the units people actually see.
function Frontlight.describe(changes)
    local parts = {}
    if changes.on ~= nil then
        parts[#parts+1] = changes.on and "the light on" or "the light off"
    end
    if changes.intensity then
        parts[#parts+1] = ("brightness %d"):format(changes.intensity)
    end
    if changes.warmth then
        parts[#parts+1] = ("warmth %d"):format(changes.warmth)
    end
    return table.concat(parts, ", ")
end

return Frontlight
