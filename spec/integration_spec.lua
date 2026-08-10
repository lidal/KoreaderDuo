--[[--
Two devices, two processes, one book.

This is the test that matters: a master and a slave, each a separate OS
process running the real plugin, connected over a real TCP socket, driven
through the same code paths a finger on the screen would take.

The controller (this file) speaks to each device over a small control
channel and asks questions like "what page are you on?" — it never reaches
into their state directly, because it cannot: they are different processes.
--]]--

local T = require("spec/testrunner")
local socket = require("socket")
local Controller = require("spec/harness/controller")

local LOG_DIR = os.getenv("DUO_LOG_DIR") or "/tmp"

--------------------------------------------------------------------------
-- Fixture
--------------------------------------------------------------------------

local controller = Controller.new()
local master = controller:spawn("master")
local slave = controller:spawn("slave")
local slave2 = controller:spawn("slave2")

local DUO_PORT = 19970

local function callMaster(code) return controller:call(master, code) end
local function callSlave(code) return controller:call(slave, code) end

--- Puts both devices back to a known state: master running, slave attached,
-- both in spread mode on page 10/11.
local function connectPair(options)
    options = options or {}
    callMaster("Core:stop('test reset')")
    callSlave("Core:stop('test reset')")
    controller:call(slave2, "Core:stop('test reset')")

    callMaster(("Core.settings.port = %d"):format(DUO_PORT))
    callMaster(("Core.settings.token = %q"):format(options.master_token or "K7F2QX"))
    callMaster(("Core.settings.mode = %q"):format(options.mode or "spread"))
    callMaster(("Core.settings.reverse = %s"):format(tostring(options.reverse or false)))
    callMaster(("Core.settings.slave_can_turn = %s"):format(tostring(options.slave_can_turn ~= false)))
    callMaster("Core.settings.discovery_port = 19971")

    callSlave(("Core.settings.token = %q"):format(options.slave_token or "K7F2QX"))
    callSlave(("Core.settings.peer_port = %d"):format(DUO_PORT))
    callSlave("Core.settings.discovery_port = 19971")

    callMaster("Core:start('master')")
    callSlave(("Core:start('slave', { host = '127.0.0.1', port = %d })"):format(DUO_PORT))

    if options.expect_failure then return end
    controller:assertEventually(master, "Core:isConnected()", true, "master never saw the slave")
    controller:assertEventually(slave, "Core:isConnected()", true, "slave never connected")
end

--- Sets the master's page and waits for the spread to settle.
local function setMasterPage(page)
    callMaster(("D:jumpToPage(%d)"):format(page))
    controller:assertEventually(master, "D:getPage()", page, "master did not move")
end

--------------------------------------------------------------------------
-- Tests
--------------------------------------------------------------------------

T.describe("two devices, connecting", function()
    T.it("pairs over the network", function()
        connectPair()
        T.assertEquals(callMaster("Core.role"), "master")
        T.assertEquals(callSlave("Core.role"), "slave")
        T.assertMatch(callMaster("Core:getStatusText()"), "Master")
        T.assertMatch(callSlave("Core:getStatusText()"), "following")
    end)

    T.it("learns the other device's name", function()
        connectPair()
        T.assertEquals(callSlave("Core:getReadyLinks()[1].peer_name"), "master")
        T.assertEquals(callMaster("Core:getReadyLinks()[1].peer_name"), "slave")
    end)

    T.it("turns away a device with the wrong pairing code", function()
        connectPair{ slave_token = "NOPE99", expect_failure = true }
        -- The slave must not end up connected, however long we wait.
        local connected = controller:waitFor(slave, "Core:isConnected()", true, 3)
        T.assertTrue(not connected, "a device with the wrong code got in")
        T.assertTrue(not (controller:waitFor(master, "Core:isConnected()", true, 1)),
            "the master accepted a device with the wrong code")
    end)

    T.it("finds the master over UDP without being told its address", function()
        connectPair()
        callSlave("Core:startScan(function(r) Core.scan_results = r end)")
        controller:assertEventually(slave, "Core.scan_results ~= nil", true, "the scan never finished")
        T.assertEquals(controller:call(slave, "#Core.scan_results"), "1")
        T.assertEquals(controller:call(slave, "Core.scan_results[1].name"), "master")
        T.assertEquals(controller:call(slave, "Core.scan_results[1].port"), tostring(DUO_PORT))
    end)
end)

T.describe("two devices, one spread", function()
    T.it("puts the slave on the page after the master's", function()
        connectPair()
        setMasterPage(10)
        controller:assertEventually(slave, "D:getPage()", 11, "the slave is not showing the next page")
    end)

    T.it("moves both devices by two when the master turns a page", function()
        connectPair()
        setMasterPage(10)
        controller:assertEventually(slave, "D:getPage()", 11)

        callMaster("D:tapForward()")
        controller:assertEventually(master, "D:getPage()", 12, "the master must skip the page the slave showed")
        controller:assertEventually(slave, "D:getPage()", 13)

        callMaster("D:tapForward()")
        controller:assertEventually(master, "D:getPage()", 14)
        controller:assertEventually(slave, "D:getPage()", 15)

        callMaster("D:tapBack()")
        controller:assertEventually(master, "D:getPage()", 12)
        controller:assertEventually(slave, "D:getPage()", 13)
    end)

    T.it("lets a tap on the slave turn the pair", function()
        connectPair()
        setMasterPage(20)
        controller:assertEventually(slave, "D:getPage()", 21)

        callSlave("D:tapForward()")
        controller:assertEventually(master, "D:getPage()", 22, "the slave's tap did not reach the master")
        controller:assertEventually(slave, "D:getPage()", 23)

        callSlave("D:tapBack()")
        controller:assertEventually(master, "D:getPage()", 20)
        controller:assertEventually(slave, "D:getPage()", 21)
    end)

    T.it("ignores taps on the slave when that is switched off", function()
        connectPair{ slave_can_turn = false }
        setMasterPage(30)
        controller:assertEventually(slave, "D:getPage()", 31)

        callSlave("Core.settings.slave_can_turn = false")
        callSlave("D:tapForward()")
        socket.sleep(0.5)
        T.assertEquals(controller:number(master, "D:getPage()"), 30, "the master moved anyway")
        T.assertEquals(controller:number(slave, "D:getPage()"), 31, "the slave drifted out of the spread")
    end)

    T.it("follows a jump from the table of contents", function()
        connectPair()
        setMasterPage(10)
        controller:assertEventually(slave, "D:getPage()", 11)
        setMasterPage(157)
        controller:assertEventually(slave, "D:getPage()", 158, "the slave did not follow an absolute jump")
    end)

    T.it("mirrors both devices onto the same page", function()
        connectPair{ mode = "mirror" }
        setMasterPage(42)
        controller:assertEventually(slave, "D:getPage()", 42)
        callMaster("D:tapForward()")
        controller:assertEventually(master, "D:getPage()", 43, "mirror mode must move one page at a time")
        controller:assertEventually(slave, "D:getPage()", 43)
    end)

    T.it("can put the slave on the left", function()
        connectPair{ reverse = true }
        setMasterPage(50)
        controller:assertEventually(slave, "D:getPage()", 49)
        callMaster("D:tapForward()")
        controller:assertEventually(master, "D:getPage()", 52)
        controller:assertEventually(slave, "D:getPage()", 51)
    end)

    T.it("stops at the end of the book instead of running past it", function()
        connectPair()
        setMasterPage(300)
        controller:assertEventually(slave, "D:getPage()", 300, "the slave should stay on the last page")
    end)

    T.it("switches layout while connected", function()
        connectPair()
        setMasterPage(10)
        controller:assertEventually(slave, "D:getPage()", 11)
        callMaster("Core.settings.mode = 'mirror'; Core:broadcastState()")
        controller:assertEventually(slave, "D:getPage()", 10, "the slave did not follow the layout change")
        callMaster("Core.settings.mode = 'spread'; Core:broadcastState()")
        controller:assertEventually(slave, "D:getPage()", 11)
    end)
end)

T.describe("matching typography", function()
    -- The point of all this: page numbers only mean the same thing on two
    -- devices if both break the lines in the same places.
    local function fontSize(device) return controller:number(device, "UI.document.configurable.font_size") end
    local function pageCount(device) return controller:number(device, "UI.document:getPageCount()") end

    T.it("brings a mismatched slave into line on connect", function()
        callMaster("Core:stop('reset')")
        callSlave("Core:stop('reset')")
        -- The slave is reading at a bigger size, so it has more pages than
        -- the master and the spread would be nonsense.
        callSlave("UI.document.configurable.font_size = 30; UI.document:repaginate()")
        T.assertNotEquals(pageCount(slave), pageCount(master), "the fixture is not actually mismatched")

        connectPair()
        controller:assertEventually(slave, "UI.document.configurable.font_size", 22,
            "the slave kept its own font size")
        T.assertEquals(pageCount(slave), pageCount(master),
            "the two devices still disagree about how long the book is")
    end)

    T.it("follows a change made on the master", function()
        connectPair()
        callMaster("UI:handleEvent(D.Event:new('SetFontSize', 26))")
        controller:assertEventually(slave, "UI.document.configurable.font_size", 26,
            "the slave did not follow the master")
        T.assertEquals(pageCount(slave), pageCount(master))
    end)

    T.it("follows a change made on the slave", function()
        connectPair()
        callSlave("UI:handleEvent(D.Event:new('SetFontSize', 18))")
        -- A slave cannot decide anything by itself: it tells the master,
        -- which applies it and passes it on.
        controller:assertEventually(master, "UI.document.configurable.font_size", 18,
            "the master did not follow the slave")
        T.assertEquals(fontSize(slave), 18)
        T.assertEquals(pageCount(slave), pageCount(master))
    end)

    T.it("matches margins, which are a pair rather than a number", function()
        connectPair()
        callMaster("UI:handleEvent(D.Event:new('SetPageHorizMargins', {25, 25}))")
        controller:assertEventually(slave, "UI.document.configurable.h_page_margins[1]", 25,
            "the slave did not follow the margins")
        T.assertEquals(controller:number(slave, "UI.document.configurable.h_page_margins[2]"), 25)
        T.assertEquals(pageCount(slave), pageCount(master))
    end)

    T.it("keeps the spread correct after a relayout", function()
        connectPair()
        setMasterPage(40)
        controller:assertEventually(slave, "D:getPage()", 41)

        callMaster("UI:handleEvent(D.Event:new('SetFontSize', 24))")
        controller:assertEventually(slave, "UI.document.configurable.font_size", 24)
        -- Whatever page the master ended up on, the slave must be on the next.
        local master_page = controller:number(master, "D:getPage()")
        controller:assertEventually(slave, "D:getPage()", master_page + 1,
            "the spread broke when the book was laid out again")
    end)

    T.it("leaves the devices alone when switched off", function()
        connectPair()
        callSlave("Core.settings.match_typography = false")
        callMaster("Core.settings.match_typography = false")
        callSlave("UI.document.configurable.font_size = 30; UI.document:repaginate()")
        callMaster("UI:handleEvent(D.Event:new('SetFontSize', 20))")
        socket.sleep(2.5)
        T.assertEquals(fontSize(slave), 30, "the slave was changed with matching switched off")
    end)

    T.it("can put the slave's own settings back", function()
        callSlave("Core:stop('reset')")
        callMaster("Core:stop('reset')")
        callSlave("Core.settings.match_typography = true")
        callMaster("Core.settings.match_typography = true")
        -- On a device this is fresh per document; these are all one session.
        callSlave("Core.typography_backup = nil")
        -- Both sizes set here rather than assumed: the previous test leaves
        -- the master somewhere of its own choosing.
        callMaster("UI:handleEvent(D.Event:new('SetFontSize', 22))")
        callSlave("UI:handleEvent(D.Event:new('SetFontSize', 30))")
        connectPair()
        controller:assertEventually(slave, "UI.document.configurable.font_size", 22,
            "the slave did not take the master's size")

        T.assertEquals(callSlave("Core:hasTypographyBackup()"), "true")
        T.assertEquals(callSlave("Core:restoreTypography()"), "true")
        T.assertEquals(fontSize(slave), 30, "the slave's own size did not come back")
        T.assertEquals(callSlave("Core:hasTypographyBackup()"), "false")
    end)
end)

T.describe("three devices", function()
    -- Nothing in the design caps this at two: each device gets a slot and
    -- shows the master's page plus its slot number, and a turn moves the
    -- whole row. Three e-readers on a desk is a wide spread, but the
    -- arithmetic is the same one the pair relies on, so it is worth proving.
    T.it("lays three pages out in a row and turns them together", function()
        connectPair()
        controller:call(slave2, ("Core.settings.token = %q"):format("K7F2QX"))
        controller:call(slave2, ("Core.settings.peer_port = %d"):format(DUO_PORT))
        controller:call(slave2, ("Core:start('slave', { host = '127.0.0.1', port = %d })"):format(DUO_PORT))
        controller:assertEventually(slave2, "Core:isConnected()", true, "the third device never joined")

        setMasterPage(10)
        controller:assertEventually(slave, "D:getPage()", 11)
        controller:assertEventually(slave2, "D:getPage()", 12)
        T.assertEquals(controller:number(master, "Core:getStep()"), 3)

        callMaster("D:tapForward()")
        controller:assertEventually(master, "D:getPage()", 13)
        controller:assertEventually(slave, "D:getPage()", 14)
        controller:assertEventually(slave2, "D:getPage()", 15)

        T.assertEquals(callMaster("Core:getStatusText()"):match("pages ([%d–]+)"), "13–14–15")

        controller:call(slave2, "Core:stop('done')")
        controller:assertEventually(master, "Core:slaveCount()", 1, "the master did not shrink the spread")
    end)
end)

T.describe("two devices, when things go wrong", function()
    T.it("puts the slave back on the right page after a reconnect", function()
        connectPair()
        setMasterPage(60)
        controller:assertEventually(slave, "D:getPage()", 61)

        -- Yank the connection the way a sleeping device or a dropped
        -- Wi-Fi link would, without telling either side.
        callSlave("Core.links[1].stream:close()")
        controller:assertEventually(slave, "Core:isConnected()", false, "the slave did not notice")

        -- While it is away, the master reads on alone.
        setMasterPage(120)

        controller:assertEventually(slave, "Core:isConnected()", true, "the slave never came back")
        controller:assertEventually(slave, "D:getPage()", 121, "the slave came back on the wrong page")
    end)

    T.it("goes back to one page per turn while alone", function()
        connectPair()
        setMasterPage(70)
        T.assertEquals(controller:number(master, "Core:getStep()"), 2)

        callSlave("Core:stop('slave left')")
        controller:assertEventually(master, "Core:isConnected()", false, "the master did not notice")
        T.assertEquals(controller:number(master, "Core:getStep()"), 1,
            "with nobody following, a turn should move one page again")

        callMaster("D:tapForward()")
        controller:assertEventually(master, "D:getPage()", 71)
    end)

    local WARNED = "(function() for _, m in ipairs(UIManager.shown_log) do if tostring(m.text):find('pages here') or tostring(m.text):find('paginates') then return true end end return false end)()"

    T.it("says nothing about a mismatch it is about to fix itself", function()
        -- The slave arrives with a bigger font and so a longer book. With
        -- matching on, that is not worth a word: it is fixed a moment later.
        callSlave("Core:stop('reset')")
        callSlave("Core.settings.match_typography = true")
        callMaster("Core.settings.match_typography = true")
        callSlave("UI:handleEvent(D.Event:new('SetFontSize', 30))")
        callSlave("UIManager.shown_log = {}")
        callSlave("Core.warned_pagination = false")

        connectPair()
        setMasterPage(60)
        socket.sleep(6) -- well past the settle window
        setMasterPage(62)
        socket.sleep(1)

        T.assertEquals(callSlave(WARNED), "false", "warned about a mismatch it had already fixed")
        T.assertEquals(controller:number(slave, "UI.document:getPageCount()"),
            controller:number(master, "UI.document:getPageCount()"),
            "the two devices should agree by now")
    end)

    T.it("warns when matching cannot fix it, because the screens differ", function()
        connectPair()
        -- Same settings on both, but this device still lays the book out
        -- differently: a smaller screen, which no setting can match.
        callSlave("UIManager.shown_log = {}")
        callSlave("Core.warned_pagination = false")
        callSlave("Core.typography_applied_at = 0")
        callSlave("UI.document.page_count = 412")
        setMasterPage(80)
        controller:assertEventually(slave, WARNED, true,
            "no warning when the pages genuinely cannot line up")
        T.assertEquals(callSlave(
            "(function() for _, m in ipairs(UIManager.shown_log) do if tostring(m.text):find('between the screens') then return true end end return false end)()"),
            "true", "the warning should name the real cause")
        callSlave("UI.document:repaginate()")
    end)

    T.it("still tells you to match them when matching is switched off", function()
        callSlave("Core:stop('reset')")
        callSlave("Core.settings.match_typography = false")
        callMaster("Core.settings.match_typography = false")
        connectPair()
        callSlave("UIManager.shown_log = {}")
        callSlave("Core.warned_pagination = false")
        callSlave("UI.document.page_count = 412")
        setMasterPage(84)
        controller:assertEventually(slave,
            "(function() for _, m in ipairs(UIManager.shown_log) do if tostring(m.text):find('Match typography') then return true end end return false end)()",
            true, "no warning with matching switched off")
        callSlave("UI.document:repaginate()")
        callSlave("Core.settings.match_typography = true")
        callMaster("Core.settings.match_typography = true")
    end)

    T.it("tells the slave which book to open", function()
        -- A file that really exists, so the slave gets as far as opening it.
        local book = LOG_DIR .. "/duo-test-book.epub"
        local handle = assert(io.open(book, "w"))
        handle:write("not really an epub")
        handle:close()

        connectPair()
        callSlave("Core.settings.follow_document = true")
        callMaster(("UI.document.file = %q"):format(book))
        callMaster("UI.digest = 'digest-other-book'")
        callMaster("Core:broadcastDocument()")

        controller:assertEventually(slave,
            ("(function() for _, m in ipairs(UIManager.shown_log) do if m.class == 'ShowReader' and m.text == %q then return true end end return false end)()"):format(book),
            true, "the slave never opened the master's book")
        os.remove(book)
    end)

    T.it("opens the master's book once, not once per message", function()
        local book = LOG_DIR .. "/duo-test-book2.epub"
        local handle = assert(io.open(book, "w"))
        handle:write("not really an epub")
        handle:close()

        connectPair()
        callSlave("Core.settings.follow_document = true")
        callSlave("UIManager.shown_log = {}")
        callMaster(("UI.document.file = %q"):format(book))
        callMaster("UI.digest = 'digest-book-two'")
        -- Two announcements in quick succession, as a reconnect would produce.
        callMaster("Core:broadcastDocument()")
        callMaster("Core:broadcastDocument()")
        socket.sleep(0.6)

        T.assertEquals(controller:call(slave,
            "(function() local n = 0 for _, m in ipairs(UIManager.shown_log) do if m.class == 'ShowReader' then n = n + 1 end end return n end)()"),
            "1", "the slave opened the same book more than once")
        os.remove(book)
    end)

    T.it("stays put when the master is in the same book by a different path", function()
        connectPair()
        callSlave("Core.settings.follow_document = true")
        callSlave("UIManager.shown_log = {}")
        -- Same content digest, different path: a copy of the same book.
        callMaster("UI.document.file = '/elsewhere/moby-dick.epub'")
        callMaster("Core:broadcastDocument()")
        socket.sleep(0.5)
        T.assertEquals(controller:call(slave,
            "(function() for _, m in ipairs(UIManager.shown_log) do if m.class == 'ShowReader' then return true end end return false end)()"),
            "false", "the slave reopened a book it was already reading")
    end)

    T.it("keeps the connection across a document switch on the slave", function()
        connectPair()
        setMasterPage(90)
        controller:assertEventually(slave, "D:getPage()", 91)

        -- KOReader destroys and rebuilds the plugin instance here; the
        -- engine, and so the connection, has to outlive it.
        callSlave("D:openDocument{ page_count = 300 }")
        T.assertEquals(callSlave("Core:isConnected()"), "true",
            "the link died when the document changed")

        setMasterPage(140)
        controller:assertEventually(slave, "D:getPage()", 141,
            "the rebuilt plugin instance is not following any more")
    end)

    T.it("survives the master restarting", function()
        connectPair()
        setMasterPage(100)
        controller:assertEventually(slave, "D:getPage()", 101)

        callMaster("Core:stop('master restarting')")
        controller:assertEventually(slave, "Core:isConnected()", false)
        callMaster("Core:start('master')")
        controller:assertEventually(slave, "Core:isConnected()", true, "the slave did not find the master again")

        setMasterPage(200)
        controller:assertEventually(slave, "D:getPage()", 201)
    end)
end)

local exit_code = T.run()
controller:shutdown()
return exit_code
