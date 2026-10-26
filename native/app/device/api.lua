--[[--
What the app needs from a reader, and nothing more.

This file is a contract, not an implementation. It exists because the app
has to be built and tested on a machine that is not a Kindle, and the only
way that works is if everything touching the hardware goes through one
narrow door that can be answered twice: `device/kobase.lua` on the reader,
`device/fake.lua` in the suite.

The surface is deliberately small. Every method added here is a method that
has to be faked convincingly, and a fake that drifts from the real thing is
worse than no fake at all -- it makes the suite pass while the device
fails. So: a screen to draw on, taps and keys coming in, a light, a
battery, and being told the device is going to sleep. That is the whole of
what a reader is, from up here.

**Drawing is a display list, not pixels.** `screen()` hands back a surface
that records operations rather than one that rasterises them. On the device
the recording is replayed into koreader-base's blitbuffer; in the suite it
is read back and asserted on. That is what makes a library grid testable
without a framebuffer, and it is the reason the UI layer never sees a
pixel.

@module duonative.device.api
--]]--

local DeviceApi = {}

--[[--
The methods an implementation must provide.

    open(options)            -> device, or nil plus a reason
    device:screen()          -> surface (see below)
    device:size()            -> width, height in pixels
    device:refresh(rect, how) push the surface to the panel
                              how: "full" | "partial" | "fast"
    device:poll(timeout_ms)   -> event or nil
    device:frontlight()       -> level, warmth   (nil when there is no light)
    device:setFrontlight(level, warmth)
    device:battery()          -> percent, charging
    device:onSuspend(fn)      called when the device is about to sleep
    device:onResume(fn)
    device:close()            give the framebuffer back

An event is one of:

    { kind = "tap",   x = n, y = n }
    { kind = "swipe", dir = "left"|"right"|"up"|"down" }
    { kind = "key",   key = "left"|"right"|"menu"|"back"|"power" }
    { kind = "quit" }

A surface provides:

    surface:size()                     -> w, h
    surface:fill(rect, grey)           grey 0 (black) .. 15 (white)
    surface:rect(rect, grey, width)    outline
    surface:text(x, y, str, style)     style = { size=, face=, grey=, bold= }
    surface:image(rect, handle)        a cover or a rendered page
    surface:clip(rect, fn)             draw fn's output clipped to rect
    surface:ops()                      the display list, for the suite

`rect` is always `{ x =, y =, w =, h = }`.
--]]--
DeviceApi.CONTRACT = {
    device = {
        "screen", "size", "refresh", "poll",
        "frontlight", "setFrontlight", "battery",
        "onSuspend", "onResume", "close",
    },
    surface = {
        "size", "fill", "rect", "text", "image", "clip", "ops",
    },
}

--- Refresh modes, named so a caller never passes a typo.
DeviceApi.FULL = "full"
DeviceApi.PARTIAL = "partial"
DeviceApi.FAST = "fast"

--[[--
Checks an implementation against the contract.

Called by the suite against both backends, so that the fake cannot quietly
grow a method the real device lacks -- which is the failure this whole
arrangement exists to prevent.
--]]--
function DeviceApi.check(device)
    local missing = {}
    for _, name in ipairs(DeviceApi.CONTRACT.device) do
        if type(device[name]) ~= "function" then missing[#missing+1] = name end
    end
    local surface = device.screen and device:screen()
    if surface then
        for _, name in ipairs(DeviceApi.CONTRACT.surface) do
            if type(surface[name]) ~= "function" then
                missing[#missing+1] = "surface." .. name
            end
        end
    else
        missing[#missing+1] = "screen() returned nothing"
    end
    if #missing == 0 then return true end
    return false, table.concat(missing, ", ")
end

return DeviceApi
