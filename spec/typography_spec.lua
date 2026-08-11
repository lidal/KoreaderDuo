--[[--
Matching the two devices' layout settings.
--]]--

local T = require("spec/testrunner")
local Typography = require("duo/typography")
local Instance = require("spec/harness/instance")

T.describe("values on the wire", function()
    T.it("carries numbers, strings and margin pairs", function()
        T.assertEquals(Typography.encodeValue(22), "22")
        T.assertEquals(Typography.encodeValue("Noto Serif"), "Noto Serif")
        T.assertEquals(Typography.encodeValue({ 10, 10 }), "10,10")
        T.assertEquals(Typography.encodeValue(true), "1")
    end)

    T.it("decodes back into the shape the setting already has", function()
        -- KOReader is particular: a margin has to come back a pair, not the
        -- string "10,10", or it is quietly wrong rather than loudly wrong.
        local margins = Typography.decodeValue("15,15", { 10, 10 })
        T.assertEquals(type(margins), "table")
        T.assertEquals(margins[1], 15)
        T.assertEquals(margins[2], 15)

        T.assertEquals(Typography.decodeValue("24", 22), 24)
        T.assertEquals(type(Typography.decodeValue("24", 22)), "number")
        T.assertEquals(Typography.decodeValue("Literata", "Noto Serif"), "Literata")
    end)

    T.it("round-trips every key it claims to match", function()
        local values = { 22, "Noto Serif", { 10, 10 }, 0, 100 }
        for _, value in ipairs(values) do
            local encoded = Typography.encodeValue(value)
            local decoded = Typography.decodeValue(encoded, value)
            T.assertEquals(Typography.encodeValue(decoded), encoded)
        end
    end)

    T.it("knows the event that applies each setting", function()
        local events = Typography.getEventMap()
        T.assertEquals(events.font_size, "SetFontSize")
        T.assertEquals(events.line_spacing, "SetLineSpace")
        T.assertEquals(events.h_page_margins, "SetPageHorizMargins")
        T.assertEquals(events.view_mode, "SetViewMode")
        for _, key in ipairs(Typography.KEYS) do
            T.assertTrue(events[key], "no event known for " .. key)
        end
    end)

    T.it("lists what changed", function()
        local mine = { font_size = "22", line_spacing = "100" }
        local theirs = { font_size = "26", line_spacing = "100" }
        T.assertTableEquals(Typography.differences(mine, theirs), { "font_size" })
        T.assertEquals(#Typography.differences(mine, mine), 0)
    end)

    T.it("describes a change in words", function()
        T.assertEquals(Typography.describe({ "font_size" }), "font size")
        T.assertEquals(Typography.describe({ "font_size", "h_page_margins" }), "font size, margins")
        T.assertMatch(Typography.describe({ "font_size", "h_page_margins", "line_spacing", "view_mode", "t_page_margin" }),
            "and 2 more")
        T.assertEquals(Typography.describe({}), "nothing")
    end)
end)

T.describe("reading and applying on a device", function()
    local device = Instance.new{ name = "Kindle-A", page_count = 300 }

    T.it("reads the settings that move the lines", function()
        local snapshot = Typography.snapshot(device.ui)
        T.assertEquals(snapshot.font_size, "22")
        T.assertEquals(snapshot.h_page_margins, "10,10")
        T.assertEquals(snapshot.font_face, "Noto Serif")
        -- And nothing that is properly personal to one device.
        T.assertNil(snapshot.rotation_mode)
        T.assertNil(snapshot.nightmode_images)
    end)

    T.it("applies a setting through the reader's own event", function()
        local applied = Typography.apply(device.ui, { font_size = "26" }, device.Event)
        T.assertTableEquals(applied, { "font_size" })
        T.assertEquals(device.ui.document.configurable.font_size, 26)
        -- And the document really was laid out again.
        T.assertNotEquals(device.ui.document:getPageCount(), 300)
    end)

    T.it("changes nothing when the settings already match", function()
        local snapshot = Typography.snapshot(device.ui)
        local applied = Typography.apply(device.ui, snapshot, device.Event)
        T.assertEquals(#applied, 0, "applied a change that was not needed")
    end)

    T.it("restores a margin pair as a pair", function()
        Typography.apply(device.ui, { h_page_margins = "25,25" }, device.Event)
        local margins = device.ui.document.configurable.h_page_margins
        T.assertEquals(type(margins), "table")
        T.assertEquals(margins[1], 25)
    end)

    T.it("says so when the other device's typeface is missing here", function()
        local applied = Typography.apply(device.ui, { font_face = "Some Font Nobody Has" }, device.Event)
        T.assertEquals(applied.missing_font, "Some Font Nobody Has")
        T.assertEquals(device.ui.font.font_face, "Noto Serif", "the typeface must not have changed")
    end)

    T.it("leaves paged documents alone", function()
        -- A PDF has the pages the file says it has; there is nothing to match.
        local paged = Instance.new{ name = "Kindle-P", page_count = 120 }
        paged.ui.document.info.has_pages = true
        T.assertEquals(next(Typography.snapshot(paged.ui)), nil)
        local applied = Typography.apply(paged.ui, { font_size = "40" }, paged.Event)
        T.assertEquals(#applied, 0)
    end)
end)

os.exit(T.run())
