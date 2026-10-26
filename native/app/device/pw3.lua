--[[--
What a Paperwhite 3 is, as koreader-base needs to be told.

This file is the answer to the question the study called the project's
biggest unknown: whether koreader-base can be driven without KOReader's
frontend. It can, and this is the whole of what was in the way.

`ffi/framebuffer_mxcfb` does not want KOReader. It wants an object it can
ask about twenty-odd predicates -- is this a Kindle, is it REAGL, is it
Zelda, does it have a colour screen -- plus `model`, `display_dpi` and
`screen`. Every one of those is a constant for a given device, so the
coupling is a table, not a framework.

The values are read off KOReader's own `frontend/device/kindle/device.lua`,
which is authoritative for what a PW3 is, rather than guessed:

* `model = "KindlePaperWhite3"`, `display_dpi = 300`
* `isREAGL` -- inherited `yes` from the Kindle base. The devices that set
  it `no` are the Kindle 2, DXG, Kindle 3, Kindle 4, Touch and PW1; a PW3
  is not among them.
* `isZelda`, `isRex`, `isMTK` -- all `no`; those are later drivers.
* `canHWInvert`, `canModifyFBInfo` -- `yes` on mxcfb Kindles.
* `canHWDither` -- `no`. The comment in KOReader is emphatic that it does
  not work on any of them.
* `canTurnFrontlightOff` -- **`no`**, and a PW3 specifically overrides the
  Kindle default to say so. It matters: `duo/frontlight` has a branch for
  exactly this, and asks for the lowest step rather than darkness.
* `touch_dev = "/dev/input/event1"`.
* Frontlight range 0-24, from KOReader's Kindle `powerd`.

`hasEclipseWfm` and `hasReliableMxcWaitFor` are Kobo properties and are
nil on a Kindle in KOReader itself. They are answered here anyway, because
a nil is a crash if the framebuffer ever asks unguarded and `no` is the
safe answer either way.

**Still unverified on hardware.** Every value here is right according to
KOReader's source; whether this app assembles them into a working
framebuffer is what the first run on a device will say.

@module duonative.device.pw3
--]]--

local Pw3 = {}

local function yes() return true end
local function no() return false end

--[[--
The descriptor to hand to a koreader-base framebuffer.

`screen` is left nil and filled in by the caller once the framebuffer
exists, because the two refer to each other -- KOReader does the same
thing, in the same order.
--]]--
function Pw3.descriptor()
    return {
        model = "KindlePaperWhite3",
        display_dpi = 300,
        screen = nil,

        isKindle = yes,
        isKobo = no,
        isCervantes = no,
        isPocketBook = no,
        isRemarkable = no,
        isBookeen = no,
        isAndroid = no,

        -- Waveform and driver generation.
        isREAGL = yes,
        isZelda = no,
        isRex = no,
        isMTK = no,
        isMk = no,
        isNightModeChallenged = no,

        -- Framebuffer capabilities.
        canHWInvert = yes,
        canModifyFBInfo = yes,
        canHWDither = no,
        hasColorScreen = no,
        hasBGRFrameBuffer = no,

        -- Kobo-only in KOReader, answered here so an unguarded ask cannot
        -- crash on a nil.
        hasEclipseWfm = no,
        hasReliableMxcWaitFor = no,

        hasFrontlight = yes,
        -- The one that is easy to get wrong and changes behaviour: a PW3
        -- cannot take its light to zero.
        canTurnFrontlightOff = no,
    }
end

--[[--
Where the panel, the touchscreen, the light and the battery live.

All four read off KOReader's `KindlePaperWhite3:init`, which is the only
place these are written down correctly. The battery node in particular is
a `wario_*` path -- the first guess here was a Kobo node, which would have
reported no battery at all and looked like a missing feature rather than a
wrong path.
--]]--
Pw3.TOUCH_DEV = "/dev/input/event1"
Pw3.LIGHT_PATH = "/sys/class/backlight/max77696-bl/brightness"
Pw3.BATTERY_PATH =
    "/sys/devices/system/wario_battery/wario_battery0/battery_capacity"
Pw3.CHARGING_PATH =
    "/sys/devices/system/wario_charger/wario_charger0/charging"
Pw3.FRONTLIGHT_MIN = 0
Pw3.FRONTLIGHT_MAX = 24

--- 1072 x 1448 at 300dpi. Read off the framebuffer in practice; here for tests.
Pw3.WIDTH = 1072
Pw3.HEIGHT = 1448

return Pw3
