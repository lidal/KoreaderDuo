--[[--
The plugin file itself, loaded the way KOReader loads it, driven through a
stub frontend. One simulated device only — the two-device behaviour is in
integration_spec.lua, which runs two real processes.
--]]--

local T = require("spec/testrunner")
local Instance = require("spec/harness/instance")

local device = Instance.new{ name = "Kindle-A", page_count = 300 }
local Core = device.Core

local function reset()
    Core:stop("test reset")
    Core.settings.mode = "spread"
    Core.settings.reverse = false
    Core.settings.slave_can_turn = true
    device:drainMessages()
end

T.describe("plugin loading", function()
    T.it("loads and registers itself with the menu", function()
        T.assertEquals(device.Duo.name, "duo")
        T.assertEquals(#device.ui.registered_menus, 1)
        T.assertEquals(device.ui.registered_menus[1], device.plugin)
    end)

    T.it("registers a poller with the UI loop exactly once", function()
        local count = 0
        for _, zeromq in ipairs(device.UIManager._zeromqs) do
            if zeromq == Core:getPoller() then count = count + 1 end
        end
        T.assertEquals(count, 1)
        -- Reopening a document rebuilds the plugin; it must not pile up.
        device:openDocument{ page_count = 300 }
        count = 0
        for _, zeromq in ipairs(device.UIManager._zeromqs) do
            if zeromq == Core:getPoller() then count = count + 1 end
        end
        T.assertEquals(count, 1)
    end)

    T.it("builds its menu without errors", function()
        local menu = device.plugin:getMenuTable()
        T.assertTrue(#menu > 5, "menu looks empty")
        for _, item in ipairs(menu) do
            local label = item.text or (item.text_func and item.text_func())
            T.assertTrue(label and #label > 0, "menu item without a label")
            if item.checked_func then item.checked_func() end
            if item.enabled_func then item.enabled_func() end
        end
    end)

    T.it("generates a pairing code on demand and keeps it", function()
        Core.settings.token = ""
        local token = Core:ensureToken()
        T.assertEquals(#token, 6)
        T.assertEquals(Core:ensureToken(), token, "the code must not change on every read")
    end)
end)

T.describe("reading with Duo switched off", function()
    T.it("turns pages normally", function()
        reset()
        device.ui.paging.current_page = 10
        device:tapForward()
        T.assertEquals(device:getPage(), 11, "a tap must move exactly one page")
        device:tapBack()
        T.assertEquals(device:getPage(), 10)
    end)

    T.it("leaves the reader's own methods untouched afterwards", function()
        reset()
        device.plugin:unwrapPageTurns()
        device.ui.paging.current_page = 5
        device:tapForward()
        T.assertEquals(device:getPage(), 6)
        device.plugin:wrapPageTurns() -- put it back for the other tests
    end)

    T.it("reports itself as off", function()
        reset()
        T.assertEquals(Core:getStatusText(), "Off")
        T.assertTrue(not Core:isActive())
        T.assertEquals(Core:getStep(), 1)
    end)
end)

T.describe("reader binding", function()
    T.it("reads the page, page count and document details", function()
        reset()
        device.ui.paging.current_page = 42
        T.assertEquals(Core.reader.getPage(), 42)
        T.assertEquals(Core.reader.getPageCount(), 300)
        local document = Core.reader.getDocument()
        T.assertMatch(document.file, "%.epub$")
        T.assertEquals(document.title, "Moby Dick")
        T.assertEquals(document.digest, "digest-moby")
    end)

    T.it("jumps to an absolute page when told to", function()
        reset()
        Core:applyRemotePage(120)
        T.assertEquals(device:getPage(), 120)
    end)

    T.it("survives a document switch", function()
        reset()
        device:openDocument{ page_count = 120, title = "Другая книга" }
        T.assertEquals(Core.reader.getPageCount(), 120)
        T.assertEquals(Core.reader.getDocument().title, "Другая книга")
        device:openDocument{ page_count = 300, title = "Moby Dick" }
    end)
end)

T.describe("master page stepping", function()
    -- The engine is driven directly here: a real slave arrives in the
    -- integration test. What matters is that a turn moves by as many pages
    -- as there are devices.
    local function pretendConnected(slave_count)
        Core.role = Core.ROLE_MASTER
        Core.getReadyLinks = function()
            local links = {}
            for slot = 1, slave_count do
                links[slot] = { slot = slot, send = function() end, isReady = function() return true end }
            end
            return links
        end
    end

    local real_getReadyLinks = Core.getReadyLinks

    T.it("moves two pages per turn with one slave", function()
        reset()
        pretendConnected(1)
        device.ui.paging.current_page = 10
        device:tapForward()
        T.assertEquals(device:getPage(), 12)
        device:tapBack()
        T.assertEquals(device:getPage(), 10)
        Core.getReadyLinks = real_getReadyLinks
        Core.role = Core.ROLE_OFF
    end)

    T.it("moves three pages per turn with two slaves", function()
        reset()
        pretendConnected(2)
        device.ui.paging.current_page = 10
        T.assertEquals(Core:getStep(), 3)
        device:tapForward()
        T.assertEquals(device:getPage(), 13)
        Core.getReadyLinks = real_getReadyLinks
        Core.role = Core.ROLE_OFF
    end)

    T.it("moves one page per turn in mirror mode", function()
        reset()
        pretendConnected(1)
        Core.settings.mode = "mirror"
        device.ui.paging.current_page = 10
        device:tapForward()
        T.assertEquals(device:getPage(), 11)
        Core.settings.mode = "spread"
        Core.getReadyLinks = real_getReadyLinks
        Core.role = Core.ROLE_OFF
    end)

    T.it("does not touch a search peeking at the next page", function()
        reset()
        pretendConnected(1)
        device.ui.paging.current_page = 10
        -- ReaderSearch calls with no_page_turn = true and expects no move.
        device.ui.paging:onGotoViewRel(1, true)
        T.assertEquals(device:getPage(), 10)
        Core.getReadyLinks = real_getReadyLinks
        Core.role = Core.ROLE_OFF
    end)
end)

T.describe("keeping the reader awake", function()
    --[[
    Duo is polled by the UI loop and has no timer of its own, so a device
    in standby stops following. Holding standby off costs battery, so it is
    held where it buys something and not otherwise — and whatever the
    answer, it has to balance, because KOReader asserts on a stray release.
    ]]
    local function reader(name)
        local made = Instance.new{ name = name, page_count = 100 }
        made.Core.settings.token = "AWAKE1"
        return made
    end

    T.it("keeps a leader up while somebody is reading, then lets it doze", function()
        --[[
        The leader holds standby off while the book is being read and lets
        go when it is not. Letting go is what tells KOReader the reader has
        gone idle, and that is the signal the followers wait for — so this
        is not only about battery on this device.
        ]]
        local unit = reader("Kindle-Lead")
        unit.Core.settings.port = 19801
        T.assertTrue(unit.Core:start("master"))
        T.assertEquals(unit.UIManager._prevent_standby_count, 1,
            "a leader just started is being used")

        -- Long enough since the last page turn that the book is down.
        unit.Core.last_activity = 0
        unit.Core:updateAwake()
        T.assertEquals(unit.UIManager._prevent_standby_count, 0,
            "nothing has happened for a while; let the reader sleep")

        -- And a page turn brings it back up.
        unit.Core:noteActivity()
        T.assertEquals(unit.UIManager._prevent_standby_count, 1)
        unit.Core:stop("done")
    end)

    T.it("keeps a follower awake while the leader is", function()
        local unit = reader("Kindle-Follow")
        unit.Core.role = unit.Core.ROLE_SLAVE
        unit.Core.peer_napping = false
        -- Connected, as far as this half of the pair can tell.
        unit.Core.isConnected = function() return true end
        unit.Core:updateAwake()
        T.assertEquals(unit.UIManager._prevent_standby_count, 1)

        -- And goes to sleep with it.
        unit.Core:handleNap{ sleep = "1" }
        T.assertEquals(unit.UIManager._prevent_standby_count, 0,
            "a follower should doze when the leader does")

        unit.Core:handleNap{ sleep = "0" }
        T.assertEquals(unit.UIManager._prevent_standby_count, 1,
            "and wake up with it")
        unit.Core:stop("done")
        T.assertEquals(unit.UIManager._prevent_standby_count, 0)
    end)

    T.it("stays awake for a book, whichever end of it this is", function()
        local unit = reader("Kindle-Busy")
        unit.Core.settings.port = 19802
        T.assertTrue(unit.Core:start("master"))
        -- Idle long enough that only the transfer can be holding it.
        unit.Core.last_activity = 0
        unit.Core:updateAwake()
        T.assertEquals(unit.UIManager._prevent_standby_count, 0)

        unit.Core.book_sender = { sender = { close = function() end }, link = {} }
        unit.Core:updateAwake()
        T.assertEquals(unit.UIManager._prevent_standby_count, 1,
            "a book half sent is worth a minute of battery")

        unit.Core.book_sender = nil
        unit.Core.last_activity = 0
        unit.Core:updateAwake()
        T.assertEquals(unit.UIManager._prevent_standby_count, 0)
        unit.Core:stop("done")
    end)

    T.it("never releases a hold it does not have", function()
        local unit = reader("Kindle-Balance")
        unit.Core.settings.port = 19803
        T.assertTrue(unit.Core:start("master"))
        unit.Core:stop("done")
        unit.Core:stop("done again")
        unit.Core:updateAwake()
        T.assertEquals(unit.UIManager._prevent_standby_count, 0)
    end)
end)

T.describe("pairing dialogs", function()
    T.it("offers both roles", function()
        reset()
        device.plugin:showConnectDialog()
        local messages = device:drainMessages()
        T.assertEquals(#messages, 1)
        T.assertMatch(messages[1], "master")
    end)

    T.it("shows the code and address after starting as master", function()
        reset()
        Core.settings.token = "K7F2QX"
        -- Not the default port: a real KOReader running Duo on this machine
        -- would already hold 9970, and this test would fail for a reason
        -- that has nothing to do with the pairing sheet.
        Core.settings.port = 19899
        device.plugin:startMaster()
        local shown = table.concat(device:drainMessages(), "\n")
        T.assertMatch(shown, "K7F2QX")
        T.assertMatch(shown, "19899")
        T.assertTrue(Core:isMaster())
        Core:stop("test done")
        Core.settings.port = 9970
    end)

    T.it("refuses an address that is not one", function()
        reset()
        local before = Core:get("peer_host")
        device.plugin:connectTo("not-an-address", 9970, false)
        T.assertEquals(Core:get("peer_host"), before, "a bad address must not be stored")
        T.assertTrue(not Core:isActive())
    end)
end)

T.describe("spread arithmetic", function()
    local Spread = require("duo/spread")

    T.it("puts the slave on the next page", function()
        T.assertEquals(Spread.pageForSlot(10, 1, { mode = "spread", page_count = 300 }), 11)
        T.assertEquals(Spread.pageForSlot(10, 2, { mode = "spread", page_count = 300 }), 12)
    end)

    T.it("puts the slave on the previous page when reversed", function()
        T.assertEquals(Spread.pageForSlot(10, 1, { mode = "spread", reverse = true, page_count = 300 }), 9)
    end)

    T.it("mirrors", function()
        T.assertEquals(Spread.pageForSlot(10, 1, { mode = "mirror" }), 10)
        T.assertEquals(Spread.stepFor("mirror", 3), 1)
    end)

    T.it("does not run off the end of the book", function()
        local page, clamped = Spread.pageForSlot(300, 1, { mode = "spread", page_count = 300 })
        T.assertEquals(page, 300)
        T.assertTrue(clamped, "the last page must be reported as clamped")
        local first = Spread.pageForSlot(1, 1, { mode = "spread", reverse = true, page_count = 300 })
        T.assertEquals(first, 1)
    end)

    T.it("accounts for devices showing two pages at once", function()
        T.assertEquals(Spread.pageForSlot(10, 1, { mode = "spread", pages_per_view = 2, page_count = 300 }), 12)
    end)

    T.it("describes the layout for the status line", function()
        T.assertEquals(Spread.describeLayout(10, 1, { mode = "spread", page_count = 300 }), "10–11")
        T.assertEquals(Spread.describeLayout(10, 2, { mode = "spread", page_count = 300 }), "10–11–12")
        T.assertEquals(Spread.describeLayout(10, 1, { mode = "spread", reverse = true, page_count = 300 }), "9–10")
    end)
end)

os.exit(T.run())
