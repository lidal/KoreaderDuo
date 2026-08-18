--[[--
Matching the light on two readers.

The awkward part is that brightness is not a number two devices can agree
on: KOReader drives a Kindle's light from 0 to 24 and a Kobo's from 0 to
100. So proportions travel, not levels, and the arithmetic that converts
them is what is checked here.
--]]--

package.path = "./duo.koplugin/?.lua;" .. package.path

local T = require("spec/testrunner")
local Frontlight = require("duo/frontlight")

local KINDLE = { fl_min = 0, fl_max = 24, fl_warmth_min = 0, fl_warmth_max = 24 }
local KOBO = { fl_min = 0, fl_max = 100, fl_warmth_min = 0, fl_warmth_max = 100 }

local function reader(powerd, options)
    options = options or {}
    return {
        hasFrontlight = function() return options.no_light ~= true end,
        hasNaturalLight = function() return options.warm == true end,
        canTurnFrontlightOff = function() return options.cannot_turn_off ~= true end,
    }, powerd
end

T.describe("proportions rather than levels", function()
    T.it("reads a level as a share of the device's own range", function()
        T.assertEquals(Frontlight.toPercent(24, 0, 24), 100)
        T.assertEquals(Frontlight.toPercent(12, 0, 24), 50)
        T.assertEquals(Frontlight.toPercent(0, 0, 24), 0)
        T.assertEquals(Frontlight.toPercent(50, 0, 100), 50)
    end)

    T.it("puts it back on whatever range this device has", function()
        -- The whole point: half on a Kindle and half on a Kobo are the same
        -- brightness and completely different numbers.
        T.assertEquals(Frontlight.fromPercent(50, 0, 24), 12)
        T.assertEquals(Frontlight.fromPercent(50, 0, 100), 50)
        T.assertEquals(Frontlight.fromPercent(100, 0, 24), 24)
    end)

    T.it("rounds rather than truncates, so a coarse light does not drift", function()
        -- On 24 steps, truncating loses most of a step each way, and two
        -- devices correcting each other would walk the light down to zero.
        for level = 0, 24 do
            local back = Frontlight.fromPercent(Frontlight.toPercent(level, 0, 24), 0, 24)
            T.assertEquals(back, level, "level " .. level .. " did not survive the round trip")
        end
    end)

    T.it("refuses a range that is not one", function()
        T.assertNil(Frontlight.toPercent(5, 10, 10))
        T.assertNil(Frontlight.toPercent(nil, 0, 24))
        T.assertNil(Frontlight.fromPercent(50, 0, 0))
    end)

    T.it("treats a step either way as the same setting", function()
        -- Without this the two devices take turns correcting each other,
        -- because a percentage rounded onto 24 steps rarely lands exactly.
        T.assertTrue(Frontlight.same(50, 51))
        T.assertTrue(not Frontlight.same(50, 60))
        T.assertTrue(Frontlight.same(nil, nil))
        T.assertTrue(not Frontlight.same(50, nil))
    end)
end)

T.describe("reading the light off a device", function()
    T.it("reports brightness as a percentage", function()
        local device, powerd = reader(KINDLE)
        powerd.fl_intensity = 18
        local snapshot = Frontlight.snapshot(powerd, device)
        T.assertEquals(snapshot.intensity, 75)
        T.assertNil(snapshot.warmth, "a device with no warm light must not claim one")
    end)

    T.it("includes warmth only where the device has it", function()
        local device, powerd = reader(KINDLE, { warm = true })
        powerd.fl_intensity = 12
        powerd.fl_warmth = 6
        local snapshot = Frontlight.snapshot(powerd, device)
        T.assertEquals(snapshot.warmth, 25)
    end)

    T.it("says nothing at all on a device with no light", function()
        local device, powerd = reader(KINDLE, { no_light = true })
        powerd.fl_intensity = 12
        T.assertNil(Frontlight.snapshot(powerd, device))
    end)
end)

T.describe("deciding what to change", function()
    T.it("converts the other device's share to a level here", function()
        local device, powerd = reader(KINDLE)
        powerd.fl_intensity = 4
        local changes = Frontlight.differences({ intensity = 100 }, powerd, device)
        T.assertEquals(changes.intensity, 24)
    end)

    T.it("leaves a light that is already close enough alone", function()
        local device, powerd = reader(KINDLE)
        powerd.fl_intensity = 12                       -- 50%
        T.assertNil(Frontlight.differences({ intensity = 51 }, powerd, device))
    end)

    T.it("ignores warmth it was sent but cannot do", function()
        -- A Kindle and a Kobo should still agree about brightness rather
        -- than the whole message being refused over a light one lacks.
        local device, powerd = reader(KINDLE)
        powerd.fl_intensity = 0
        local changes = Frontlight.differences({ intensity = 50, warmth = 80 }, powerd, device)
        T.assertEquals(changes.intensity, 12)
        T.assertNil(changes.warmth)
    end)

    T.it("does not ask a reader that cannot go dark to go dark", function()
        -- KOReader marks these devices; asking for the minimum means asking
        -- for the lowest step they actually have.
        local device, powerd = reader(KINDLE, { cannot_turn_off = true })
        powerd.fl_intensity = 24
        local changes = Frontlight.differences({ intensity = 0 }, powerd, device)
        T.assertEquals(changes.intensity, 1)
    end)

    T.it("crosses between two different ranges without changing the brightness", function()
        local kindle, kindle_powerd = reader(KINDLE)
        kindle_powerd.fl_intensity = 18
        local kobo, kobo_powerd = reader(KOBO)
        kobo_powerd.fl_intensity = 0

        local sent = Frontlight.snapshot(kindle_powerd, kindle)
        local changes = Frontlight.differences(sent, kobo_powerd, kobo)
        T.assertEquals(changes.intensity, 75, "three quarters is three quarters on either")
    end)
end)

T.describe("deciding whether a direct link survived a sleep", function()
    local DirectLink = require("duo/directlink")

    local function status(mode, address)
        return ("interface: wlan0\naddress:  %s\nmode=%s\nduo link: configured\n")
            :format(address or "169.254.13.1", mode)
    end

    T.it("takes both the mode and the address as proof", function()
        -- Either half can go on its own: a radio put back into managed mode
        -- keeps its address for a moment, and an interface still in the
        -- right mode can have its address flushed.
        T.assertTrue(DirectLink.isUp(status("IBSS", "169.254.13.1"), "host"))
        T.assertTrue(not DirectLink.isUp(status("managed", "169.254.13.1"), "host"))
        T.assertTrue(not DirectLink.isUp(status("IBSS", "192.168.1.44"), "host"))
    end)

    T.it("knows which address each role should be holding", function()
        T.assertTrue(DirectLink.isUp(status("IBSS", "169.254.13.2"), "join"))
        T.assertTrue(not DirectLink.isUp(status("IBSS", "169.254.13.2"), "host"))
    end)

    T.it("reads the mode line the script actually prints", function()
        --[[
        The bug this is here for: the check looked for wording `status`
        never used, so it could not tell a live link from a dead one and
        answered "gone" every time.
        ]]
        T.assertEquals(DirectLink.modeOf("interface: wlan0\nmode=Ad-Hoc\n"), "ibss")
        T.assertEquals(DirectLink.modeOf("interface: wlan0\nmode=Master\n"), "ap")
        T.assertTrue(not DirectLink.isUp("interface: wlan0\nmode:     Ad-Hoc\n", "host"),
            "the old spelling must not be mistaken for the new one")
    end)

    T.it("says no when it was handed nothing at all", function()
        T.assertTrue(not DirectLink.isUp(nil, "host"))
        T.assertTrue(not DirectLink.isUp(status("IBSS"), "over-wifi"))
    end)
end)

os.exit(T.run())
