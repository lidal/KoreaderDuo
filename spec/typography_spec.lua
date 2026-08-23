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

    T.it("turns embedded styles off rather than on", function()
        --[[
        The report: disabling embedded styles on one device made the other
        announce over and over that it had matched them, and left the
        setting exactly as it was.

        KOReader's toggle handlers do not take the value that goes into
        `configurable`; they take the argument its settings dialog sends
        alongside, which is a boolean. Duo sent the value, and in Lua 0 is
        true -- so "off" arrived as "on", the two devices disagreed, and
        each new reading of the difference was announced as a fresh match.
        ]]
        local reader = Instance.new{ name = "Kindle-E", page_count = 300 }
        T.assertEquals(reader.ui.document.configurable.embedded_css, 1)

        local applied = Typography.apply(reader.ui, { embedded_css = "0" }, reader.Event)
        T.assertTableEquals(applied, { "embedded_css" })
        T.assertEquals(reader.ui.document.configurable.embedded_css, 0,
            "asking for embedded styles off turned them on")

        -- And it settles: a second pass with the same settings is a no-op,
        -- which is what stops the announcements repeating.
        local again = Typography.apply(reader.ui, { embedded_css = "0" }, reader.Event)
        T.assertEquals(#again, 0, "the same change was applied twice")
    end)

    T.it("turns them back on again", function()
        local reader = Instance.new{ name = "Kindle-F", page_count = 300 }
        Typography.apply(reader.ui, { embedded_css = "0" }, reader.Event)
        Typography.apply(reader.ui, { embedded_css = "1" }, reader.Event)
        T.assertEquals(reader.ui.document.configurable.embedded_css, 1)
    end)

    T.it("sends the view mode as the word its handler expects", function()
        -- Same shape of bug: the value is 0 or 1, the event takes "page" or
        -- "scroll", and nothing but the argument table says so.
        local reader = Instance.new{ name = "Kindle-V", page_count = 300 }
        local applied = Typography.apply(reader.ui, { view_mode = "1" }, reader.Event)
        T.assertTableEquals(applied, { "view_mode" })
        T.assertEquals(reader.ui.document.configurable.view_mode, 1,
            "the view mode did not follow")
    end)

    T.it("passes an ordinary setting's value through untouched", function()
        -- The mapping is for the handful that need it, not a free-for-all.
        T.assertEquals(Typography.eventArgument("font_size", 26), 26)
        T.assertEquals(Typography.eventArgument("line_spacing", 120), 120)
        T.assertEquals(Typography.eventArgument("embedded_css", 0), false)
        T.assertEquals(Typography.eventArgument("embedded_css", 1), true)
        T.assertEquals(Typography.eventArgument("view_mode", 0), "page")
        T.assertEquals(Typography.eventArgument("view_mode", 1), "scroll")
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

T.describe("asking the styles question once", function()
    --[[
    Reported from a pair of Kindles: turning a book's embedded styles off
    meant answering the same "reload the document?" box on both devices, and
    then waiting for both to settle.

    KOReader asks because some style changes leave crengine unable to render
    the book correctly without building it again. Duo makes the change on
    both devices, so KOReader asks on both -- and the two answers need not
    agree, which is a good deal worse than tiresome: a book built one way
    here and another way there paginates differently, and a spread is made
    of the two paginating the same.
    ]]
    local Util = require("duo/util")
    local Protocol = require("duo/protocol")

    local function paired()
        local device = Instance.new{ name = "Kindle-R", page_count = 300 }
        local Core = device.Core
        Core.settings.match_typography = true
        local sent = {}
        Core.links = { {
            state = "ready",
            slot = 1,
            isReady = function(self_) return self_.state == "ready" end,
            isClosed = function() return false end,
            allowSilence = function() end,
            send = function(_, msg_type, fields)
                sent[#sent+1] = { type = msg_type, fields = fields }
                return true
            end,
        } }
        return device, Core, sent
    end

    local function reloads(sent)
        local count = 0
        for _, message in ipairs(sent) do
            if message.type == Protocol.RELOAD then count = count + 1 end
        end
        return count
    end

    T.it("counts as following the other device for a while after taking its layout", function()
        local device, Core = paired()
        T.assertTrue(not Core:isFollowingTypography(),
            "a device that has been told nothing is not following anything")
        Core.typography_changed_at = Util.now()
        T.assertTrue(Core:isFollowingTypography(),
            "a device that has just taken the other's layout is following it")
        -- Long enough to cover a relayout, not so long that a change made
        -- here an hour later is mistaken for one made there.
        Core.typography_changed_at = Util.now() - 3600
        T.assertTrue(not Core:isFollowingTypography(),
            "it should stop following eventually")
    end)

    T.it("passes the answer on when the reader says yes", function()
        local device, Core, sent = paired()
        Core.reload_suggested_at = Util.now()
        T.assertTrue(Core:announceReload(), "the other device was not told")
        T.assertEquals(reloads(sent), 1)
    end)

    T.it("says nothing when the reader was never asked", function()
        -- A reader reloads a book for its own reasons -- a stale cache,
        -- where page numbers come from -- and those are its own business.
        local device, Core, sent = paired()
        Core.reload_suggested_at = nil
        T.assertTrue(not Core:announceReload(),
            "a reload nobody asked about was passed on")
        T.assertEquals(reloads(sent), 0)
    end)

    T.it("says nothing about a question asked a long time ago", function()
        local device, Core, sent = paired()
        Core.reload_suggested_at = Util.now() - 3600
        T.assertTrue(not Core:announceReload())
        T.assertEquals(reloads(sent), 0)
    end)

    T.it("only says it once", function()
        -- Reloading opens the book again, and opening a book can reach the
        -- same place; the other device should not be asked to rebuild twice.
        local device, Core, sent = paired()
        Core.reload_suggested_at = Util.now()
        T.assertTrue(Core:announceReload())
        T.assertTrue(not Core:announceReload(), "it was passed on a second time")
        T.assertEquals(reloads(sent), 1)
    end)

    T.it("leaves the book alone when the two are not matching layouts", function()
        local device, Core, sent = paired()
        Core.settings.match_typography = false
        Core.reload_suggested_at = Util.now()
        T.assertTrue(not Core:announceReload())

        local rebuilt = false
        Core.hooks.reloadDocument = function() rebuilt = true end
        Core:handleRemoteReload()
        T.assertTrue(not rebuilt,
            "a device not matching layouts rebuilt its book anyway")
    end)

    T.it("rebuilds the book when the other device says it did", function()
        local device, Core = paired()
        local rebuilt = false
        Core.hooks.reloadDocument = function() rebuilt = true end
        Core.reload_suggested_at = Util.now()
        Core:handleRemoteReload()
        T.assertTrue(rebuilt, "the book was not rebuilt to match")
        -- And the offer this device was holding is answered now.
        T.assertNil(Core.reload_suggested_at,
            "it would still pass its own answer back afterwards")
    end)
end)

os.exit(T.run())
