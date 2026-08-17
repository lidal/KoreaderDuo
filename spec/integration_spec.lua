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
    -- Set on both sides: the slave consults its own copy when deciding
    -- whether to forward a turn, and a test that switched it off would
    -- otherwise leak into every test after it.
    callSlave(("Core.settings.slave_can_turn = %s"):format(tostring(options.slave_can_turn ~= false)))

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

    T.it("matches a book opened after the link came up", function()
        --[[
        The layout settings sent when the link comes up arrive while a
        slave is still in the file list, with no book to apply them to, and
        are dropped. If nothing sends them again, the two devices sit at
        different font sizes until somebody changes one by hand — which is
        exactly what it looked like on real hardware. A slave asks for its
        place the moment it finishes opening a book; the answer has to
        carry the typography as well as the page.
        ]]
        connectPair()
        callMaster("UI:handleEvent(D.Event:new('SetFontSize', 26))")
        controller:assertEventually(slave, "UI.document.configurable.font_size", 26)

        -- A fresh book on the slave, opened at a size of its own. All one
        -- snippet: the device only touches its sockets between commands, so
        -- there is no window for the answer to arrive early and make this
        -- pass without ever having been mismatched.
        callSlave("D:openDocument{ page_count = 300 }" ..
            "; UI.document.configurable.font_size = 30; UI.document:repaginate()")

        controller:assertEventually(slave, "UI.document.configurable.font_size", 26,
            "a book opened on the slave kept its own font size")
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

T.describe("one book list across two screens", function()
    -- The same spread idea, one level up: the first screenful of the folder
    -- here, the next screenful there.
    local function browseTogether(options)
        options = options or {}
        local items = {}
        for index = 1, (options.count or 20) do
            items[index] = ("book%02d.epub"):format(index)
        end
        local setup = ("D:openFileManager{ path = '/books', perpage = %d, items = %s }")
            :format(options.perpage or 6, "{'" .. table.concat(items, "','") .. "'}")

        callMaster("Core:stop('reset')")
        callSlave("Core:stop('reset')")
        callMaster(setup)
        callSlave(options.slave_setup or setup)
        connectPair()
        callMaster("Core.settings.share_browser = true")
        callSlave("Core.settings.share_browser = true")
        callMaster("Core:broadcastBrowser()")
    end

    local function visible(device)
        return controller:call(device, "table.concat(D:visibleBooks(), ',')")
    end

    T.it("shows the next screenful of books on the second device", function()
        browseTogether{ count = 20, perpage = 6 }
        controller:assertEventually(slave, "UI.file_chooser.page", 2,
            "the slave is not on the second screenful")
        T.assertEquals(visible(master), "book01.epub,book02.epub,book03.epub,book04.epub,book05.epub,book06.epub")
        T.assertEquals(visible(slave), "book07.epub,book08.epub,book09.epub,book10.epub,book11.epub,book12.epub")
    end)

    T.it("moves the whole row by two screenfuls at a time", function()
        browseTogether{ count = 40, perpage = 6 }
        controller:assertEventually(slave, "UI.file_chooser.page", 2)

        -- A swipe on the master: it takes screen 3, the slave takes screen 4.
        callMaster("UI.file_chooser:onNextPage()")
        controller:assertEventually(master, "UI.file_chooser.page", 3,
            "the master must skip the screenful the slave was showing")
        controller:assertEventually(slave, "UI.file_chooser.page", 4)
        T.assertEquals(visible(master), "book13.epub,book14.epub,book15.epub,book16.epub,book17.epub,book18.epub")
        T.assertEquals(visible(slave), "book19.epub,book20.epub,book21.epub,book22.epub,book23.epub,book24.epub")

        callMaster("UI.file_chooser:onPrevPage()")
        controller:assertEventually(master, "UI.file_chooser.page", 1)
        controller:assertEventually(slave, "UI.file_chooser.page", 2)
    end)

    T.it("lets a swipe on the slave move the row", function()
        browseTogether{ count = 40, perpage = 6 }
        controller:assertEventually(slave, "UI.file_chooser.page", 2)
        callSlave("UI.file_chooser:onNextPage()")
        controller:assertEventually(master, "UI.file_chooser.page", 3,
            "the slave's swipe did not reach the master")
        controller:assertEventually(slave, "UI.file_chooser.page", 4)
    end)

    T.it("stops at the end of the list instead of wrapping round", function()
        -- KOReader's own paging cycles back to the first page at the end,
        -- which would put the two devices on unrelated parts of the list.
        browseTogether{ count = 20, perpage = 6 } -- four screenfuls
        callMaster("UI.file_chooser:onNextPage()")
        controller:assertEventually(master, "UI.file_chooser.page", 3)
        callMaster("UI.file_chooser:onNextPage()")
        socket.sleep(0.6)
        T.assertEquals(controller:number(master, "UI.file_chooser.page"), 4,
            "the master should stop at the last screenful")
        T.assertEquals(controller:number(slave, "UI.file_chooser.page"), 4)
    end)

    T.it("makes both devices fit the same number of books on a screen", function()
        browseTogether{ count = 24, perpage = 6, slave_setup =
            "D:openFileManager{ path = '/books', perpage = 4, items = " ..
            "{'book01.epub','book02.epub','book03.epub','book04.epub','book05.epub','book06.epub'," ..
            "'book07.epub','book08.epub','book09.epub','book10.epub','book11.epub','book12.epub'," ..
            "'book13.epub','book14.epub','book15.epub','book16.epub','book17.epub','book18.epub'," ..
            "'book19.epub','book20.epub','book21.epub','book22.epub','book23.epub','book24.epub'} }" }
        controller:assertEventually(slave, "UI.file_chooser.perpage", 6,
            "the slave kept its own screenful size, so the halves cannot line up")
        controller:assertEventually(slave, "UI.file_chooser.page", 2)
        T.assertEquals(visible(slave), "book07.epub,book08.epub,book09.epub,book10.epub,book11.epub,book12.epub")
    end)

    T.it("spreads a grid of covers across the two screens", function()
        -- KOReader's cover browser can draw the list as a grid, where a
        -- screenful is its columns times its rows. Two grids can be evened
        -- up exactly, because the shape travels with the page.
        browseTogether{ count = 24, perpage = 6 }
        callMaster("UI.file_chooser:asCoverBrowser('mosaic', { cols = 3, rows = 2 })")
        callSlave("UI.file_chooser:asCoverBrowser('mosaic', { cols = 2, rows = 2 })")
        callSlave("UIManager.shown_log = {}")
        callSlave("Core.warned_listing = false")
        callMaster("Core:broadcastBrowser()")

        controller:assertEventually(slave, "UI.file_chooser.perpage", 6,
            "the slave kept its own grid, so the halves cannot line up")
        T.assertEquals(controller:number(slave, "UI.file_chooser.nb_cols"), 3,
            "the shape should have come over, not just the total")
        T.assertEquals(controller:number(slave, "UI.file_chooser.nb_rows"), 2)
        controller:assertEventually(slave, "UI.file_chooser.page", 2)
        T.assertEquals(visible(master), "book01.epub,book02.epub,book03.epub,book04.epub,book05.epub,book06.epub")
        T.assertEquals(visible(slave), "book07.epub,book08.epub,book09.epub,book10.epub,book11.epub,book12.epub")
        T.assertEquals(callSlave(
            "(function() for _, m in ipairs(UIManager.shown_log) do if tostring(m.text):find('on a screen') then return true end end return false end)()"),
            "false", "it warned about a difference it had just evened out")
    end)

    T.it("moves a grid on by two screenfuls too, and stops at the end", function()
        -- The same rule as a book: with one follower, a turn skips the
        -- screenful the follower is already showing. Worth its own test in
        -- mosaic mode, where the cover browser replaces how a page is
        -- measured but not how it is turned.
        browseTogether{ count = 30, perpage = 6 }
        callMaster("UI.file_chooser:asCoverBrowser('mosaic', { cols = 2, rows = 3 })")
        callSlave("UI.file_chooser:asCoverBrowser('mosaic', { cols = 2, rows = 3 })")
        callMaster("Core:broadcastBrowser()")
        controller:assertEventually(master, "UI.file_chooser.page_num", 5,
            "thirty books at six a screen is five screenfuls")
        controller:assertEventually(slave, "UI.file_chooser.page", 2)

        callMaster("UI.file_chooser:onNextPage()")
        controller:assertEventually(master, "UI.file_chooser.page", 3,
            "the master must skip the screenful the slave was showing")
        controller:assertEventually(slave, "UI.file_chooser.page", 4)
        T.assertEquals(visible(master), "book13.epub,book14.epub,book15.epub,book16.epub,book17.epub,book18.epub")
        T.assertEquals(visible(slave), "book19.epub,book20.epub,book21.epub,book22.epub,book23.epub,book24.epub")

        -- A turn on the follower moves the row just the same.
        callSlave("UI.file_chooser:onPrevPage()")
        controller:assertEventually(master, "UI.file_chooser.page", 1,
            "a swipe on the grid of the second device did not reach the first")
        controller:assertEventually(slave, "UI.file_chooser.page", 2)

        -- And the end of the list is a wall, not a loop.
        callMaster("UI.file_chooser:onNextPage()")
        controller:assertEventually(slave, "UI.file_chooser.page", 4)
        callMaster("UI.file_chooser:onNextPage()")
        socket.sleep(0.8)
        T.assertEquals(controller:number(master, "UI.file_chooser.page"), 5,
            "the master should stop at the last screenful rather than wrap")
        T.assertEquals(controller:number(slave, "UI.file_chooser.page"), 5,
            "with nothing after it, the follower shows the last screenful too")
    end)

    T.it("says so when one device is a grid and the other a list", function()
        -- Here the shape cannot be worked out: told only that the other
        -- device fits eight, a grid has no way to know whether that is two
        -- by four or one by eight, and guessing would rearrange the screen.
        browseTogether{ count = 24, perpage = 8 }
        callSlave("UIManager.shown_log = {}")
        callSlave("Core.warned_listing = false")
        callSlave("UI.file_chooser:asCoverBrowser('mosaic', { cols = 3, rows = 3 })")
        callMaster("Core:broadcastBrowser()")
        controller:assertEventually(slave,
            "(function() for _, m in ipairs(UIManager.shown_log) do if tostring(m.text):find('on a screen') then return true end end return false end)()",
            true, "no warning when the two screenfuls are different sizes")
        T.assertEquals(controller:number(slave, "UI.file_chooser.perpage"), 9,
            "the grid should have been left as it is")
    end)

    T.it("asks where it belongs when it is reopened on the list", function()
        -- A slave that has just been rebuilt — a document closed, a folder
        -- reopened — knows nothing about which screenful is its own.
        browseTogether{ count = 40, perpage = 6 }
        callMaster("UI.file_chooser:onNextPage()")
        controller:assertEventually(slave, "UI.file_chooser.page", 4)

        callSlave("UI.file_chooser:onGotoPage(1)")
        callSlave("Core:getReadyLinks()[1]:send('SYNC', {})")
        controller:assertEventually(slave, "UI.file_chooser.page", 4,
            "asking for the current state did not bring back the book list")
    end)

    T.it("says so when the two devices hold different books", function()
        browseTogether{ count = 20, perpage = 6, slave_setup =
            "D:openFileManager{ path = '/books', perpage = 6, items = {'other01.epub','other02.epub'} }" }
        controller:assertEventually(slave,
            "(function() for _, m in ipairs(UIManager.shown_log) do if tostring(m.text):find('not line up') then return true end end return false end)()",
            true, "no warning about the two libraries differing")
    end)

    T.it("leaves the browser alone when switched off", function()
        browseTogether{ count = 20, perpage = 6 }
        callSlave("Core.settings.share_browser = false")
        callSlave("UI.file_chooser:onGotoPage(1)")
        callMaster("UI.file_chooser:onNextPage()")
        socket.sleep(1)
        T.assertEquals(controller:number(slave, "UI.file_chooser.page"), 1,
            "the slave moved with sharing switched off")
        callSlave("Core.settings.share_browser = true")
    end)

    T.it("keeps the link when a book is opened from the list", function()
        browseTogether{ count = 20, perpage = 6 }
        controller:assertEventually(slave, "UI.file_chooser.page", 2)

        -- KOReader throws the whole file manager away and builds a ReaderUI,
        -- which is the moment a connection owned by the UI would die.
        callMaster("D:openDocument{ page_count = 300 }")
        callSlave("D:openDocument{ page_count = 300 }")

        T.assertEquals(callMaster("Core:isConnected()"), "true",
            "the link died on the way from the list into a book")
        setMasterPage(12)
        controller:assertEventually(slave, "D:getPage()", 13,
            "the spread did not resume in the book")
    end)
end)

T.describe("sending the book itself", function()
    -- Following someone else's reading is not much use if you cannot open
    -- what they are reading.
    local BOOK_DIR = LOG_DIR .. "/duo-book-src"

    --[[--
    Writes a book that looks like a real one on the wire.

    An EPUB is a zip, so its bytes are compressed and behave like noise —
    which matters more than it sounds. A tidy pattern encodes into tidy
    base64, and a book made of one repeated byte, or of a short arithmetic
    cycle, sails through a line-length limit that real books do not. So
    this is a pseudorandom stream, and it still covers every byte value.
    --]]--
    local function makeBook(name, size)
        os.execute("mkdir -p " .. BOOK_DIR)
        local path = ("%s/%s"):format(BOOK_DIR, name)
        local file = assert(io.open(path, "wb"))
        local parts = {}
        local seed = 20260811
        for index = 1, size do
            seed = (seed * 1103515245 + 12345) % 2147483648
            parts[index] = string.char(math.floor(seed / 65536) % 256)
        end
        file:write(table.concat(parts))
        file:close()
        return path
    end

    local function readFile(path)
        local file = io.open(path, "rb")
        if not file then return nil end
        local contents = file:read("*a")
        file:close()
        return contents
    end

    T.it("sends a book the slave does not have, and opens it there", function()
        local path = makeBook("sent-book.epub", 40000)
        connectPair()
        callSlave("Core.settings.sync_books = true")
        callMaster("Core.settings.sync_books = true")
        callSlave("UIManager.shown_log = {}")
        -- Both processes share a disk, so without this the slave would open
        -- the master's copy and the book would never go over the wire.
        callSlave(("D:doesNotHave(%q)"):format(path))

        -- The master opens a book that exists only on its side.
        callMaster(("UI.document.file = %q"):format(path))
        callMaster("UI.digest = 'digest-sent-book'")
        callMaster("Core:broadcastDocument()")

        -- The slave asks for it, receives it, and opens what arrived.
        controller:assertEventually(slave,
            "(function() for _, m in ipairs(UIManager.shown_log) do if m.class == 'ShowReader' then return true end end return false end)()",
            true, "the slave never opened the book it was sent", 25)

        local landed = controller:call(slave,
            "(function() for _, m in ipairs(UIManager.shown_log) do if m.class == 'ShowReader' then return m.text end end return '' end)()")
        T.assertMatch(landed, "sent%-book%.epub")
        T.assertTrue(landed ~= path,
            "the slave opened the master's own copy, so nothing was sent")
        T.assertEquals(readFile(landed), readFile(path),
            "the book that arrived is not the book that was sent")
        os.remove(landed)
    end)

    T.it("tells the other device when a send fails part way", function()
        -- The failure that matters is the quiet one: give up mid-book
        -- without a word and the other device sits on a half-written file
        -- waiting for a chunk that is never coming.
        local path = makeBook("broken-book.epub", 200000)
        callSlave("Core:stop('reset')")
        connectPair()
        callSlave("Core.settings.sync_books = true")
        callMaster("Core.settings.sync_books = true")
        callSlave("UIManager.shown_log = {}")
        callSlave(("D:doesNotHave(%q)"):format(path))

        -- Armed before the slave asks, so the book cannot slip across
        -- whole in the gap between two calls from here. Only the chunks
        -- fail, the way an unsendable message does: the link itself is
        -- fine, which is what makes staying silent inexcusable.
        callMaster([[(function()
            local link = Core:getReadyLinks()[1]
            local real = link.send
            link.send = function(self, msg_type, fields)
                if msg_type == 'BOOK_DATA' then return false, 'the chunk would not fit' end
                return real(self, msg_type, fields)
            end
        end)()]])

        callMaster(("UI.document.file = %q"):format(path))
        callMaster("UI.digest = 'digest-broken-book'")
        callMaster("Core:broadcastDocument()")

        controller:assertEventually(slave,
            "(function() for _, m in ipairs(UIManager.shown_log) do if tostring(m.text):find('could not fetch') then return true end end return false end)()",
            true, "the slave was never told the transfer had failed", 20)
        T.assertEquals(callMaster("tostring(Core.book_sender)"), "nil",
            "the master should have given up on the book")
        T.assertEquals(callSlave("tostring(Core.book_receiver)"), "nil",
            "the slave was left holding a half-written book")
    end)

    T.it("will not hand over a book it does not have open", function()
        connectPair()
        callSlave("Core.settings.sync_books = true")
        callSlave("UIManager.shown_log = {}")
        -- A peer asking for an arbitrary path gets nothing.
        callSlave("Core.book_request = { file = '/etc/passwd' }")
        callSlave("Core:getReadyLinks()[1]:send('BOOK_REQ', { file = '/etc/passwd' })")
        controller:assertEventually(slave,
            "(function() for _, m in ipairs(UIManager.shown_log) do if tostring(m.text):find('not the book') then return true end end return false end)()",
            true, "the master should refuse a book it does not have open")
        callSlave("Core.book_request = nil")
    end)

    T.it("says nothing and sends nothing when switched off", function()
        local path = makeBook("unsent-book.epub", 4000)
        callSlave("Core:stop('reset')")
        connectPair()
        callSlave("Core.settings.sync_books = false")
        callSlave("UIManager.shown_log = {}")
        callMaster(("UI.document.file = %q"):format(path))
        callMaster("UI.digest = 'digest-unsent'")
        callMaster("Core:broadcastDocument()")
        socket.sleep(2)
        T.assertEquals(callSlave("tostring(Core.book_receiver)"), "nil",
            "a book was fetched with sending switched off")
        callSlave("Core.settings.sync_books = true")
        os.execute("rm -rf " .. BOOK_DIR)
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

    T.it("stays quiet while a font change is still on its way over", function()
        --[[
        The race a real font change runs into. The master repaginates the
        instant the size changes, and its new page count reaches the slave
        before Duo has even noticed the change to push it — so for a moment
        the slave holds the old settings and a page count from the new ones.
        It used to complain about that, and then fix it a second later.
        ]]
        callSlave("Core:stop('reset')")
        callSlave("Core.settings.match_typography = true")
        callMaster("Core.settings.match_typography = true")
        connectPair()
        setMasterPage(40)
        callSlave("UIManager.shown_log = {}")
        callSlave("Core.warned_pagination = false")
        callSlave("Core.typography_applied_at = 0")

        -- The master's layout changes, and only its page count arrives.
        callMaster("UI:handleEvent(D.Event:new('SetFontSize', 28))")
        callMaster("Core:broadcastState()")
        socket.sleep(1)
        T.assertEquals(callSlave(WARNED), "false",
            "it complained about a difference the font change was about to explain")

        -- And once the change lands, the two agree and still say nothing.
        controller:assertEventually(slave, "UI.document:getPageCount()",
            controller:number(master, "UI.document:getPageCount()"),
            "the slave never caught up with the new font size", 20)
        T.assertEquals(callSlave(WARNED), "false")
    end)

    T.it("puts itself back on the right page as soon as the layout changes", function()
        -- A font change moves every page number in the book. Until the
        -- master next broadcasts, a device that only applied the settings
        -- is on the page that number used to mean — so it asks.
        callSlave("Core:stop('reset')")
        callSlave("Core.settings.match_typography = true")
        callMaster("Core.settings.match_typography = true")
        connectPair()
        setMasterPage(50)
        controller:assertEventually(slave, "D:getPage()", 51)

        callMaster("UI:handleEvent(D.Event:new('SetFontSize', 26))")
        -- No page turn from anyone: only the layout changed.
        controller:assertEventually(slave, "UI.document:getPageCount()",
            controller:number(master, "UI.document:getPageCount()"),
            "the slave never took the new font size", 20)
        controller:assertEventually(slave, "D:getPage()",
            controller:number(master, "D:getPage()") + 1,
            "the slave stayed on the page that number used to mean", 20)
    end)

    T.it("warns when matching cannot fix it, because the screens differ", function()
        connectPair()
        -- Same settings on both, but this device still lays the book out
        -- differently: a smaller screen, which no setting can match.
        callSlave("UIManager.shown_log = {}")
        callSlave("Core.warned_pagination = false")
        callSlave("Core.typography_applied_at = 0")
        callSlave("UI.document.page_count = 412")
        -- A length that has been sitting still for a while, which is what
        -- tells a real difference apart from a book still being relaid out.
        callSlave("Core.last_own_pages = 412")
        callSlave("Core.own_pages_changed_at = 0")
        setMasterPage(80)
        controller:assertEventually(slave, WARNED, true,
            "no warning when the pages genuinely cannot line up", 20)
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

    T.it("brings the slave back out to the list when the master leaves the book", function()
        --[[
        Going into a book was followed; coming back out was not, which left
        the master in the file list and the slave still sitting in a book —
        two devices doing different things, which is the one thing a spread
        is not. Signalled from the file manager coming up rather than the
        reader going down: switching straight from one book to another
        tears a reader down too, and a slave sent home then would close the
        book it is about to be told to open.
        ]]
        connectPair()
        callSlave("Core.settings.follow_document = true")
        T.assertEquals(callSlave("UI.document ~= nil"), "true", "the slave should start in a book")

        callMaster("D:openFileManager{ path = '/books' }")
        controller:assertEventually(slave, "UI.went_home == true", true,
            "the slave stayed in the book after the master closed its own")
        callMaster("D:openDocument{ page_count = 300 }")
    end)

    T.it("opens a book for the pair when the tap lands on the slave", function()
        --[[
        A slave may turn pages, so it would be strange if it could not
        start one. It must not simply open the book by itself, though: the
        master owns the page number, and a slave that wandered off into a
        book on its own would leave the two devices reading different
        things. The tap is forwarded, and the master's answer brings the
        slave along the same way a tap on the master would.
        ]]
        local book = LOG_DIR .. "/duo-slave-opened.epub"
        local handle = assert(io.open(book, "w"))
        handle:write("not really an epub")
        handle:close()

        connectPair()
        callMaster("Core.settings.follow_document = true")
        callSlave("Core.settings.follow_document = true")
        callSlave("D:openFileManager{ path = '/books' }")
        callMaster("UIManager.shown_log = {}")

        callSlave(("D:openFile(%q)"):format(book))
        controller:assertEventually(master,
            ("(function() for _, m in ipairs(UIManager.shown_log) do if m.class == 'ShowReader' and m.text == %q then return true end end return false end)()"):format(book),
            true, "the master never opened the book the slave was tapped on")
        os.remove(book)
        callSlave("D:openDocument{ page_count = 300 }")
    end)

    T.it("locks the other device when either one is locked", function()
        --[[
        Two readers held side by side are one thing to their owner. Locking
        the one in your right hand and finding the left still lit, still
        burning battery on a page nobody is reading, is not what a spread
        should mean.
        ]]
        connectPair()
        callSlave("UIManager._suspends = 0")
        callMaster("D.plugin:onSuspend()")
        controller:assertEventually(slave, "UIManager._suspends", 1,
            "the slave stayed awake when the master was locked")

        -- And the other way round, since either device can be the one put
        -- down first.
        connectPair()
        callMaster("UIManager._suspends = 0")
        callSlave("D.plugin:onSuspend()")
        controller:assertEventually(master, "UIManager._suspends", 1,
            "the master stayed awake when the slave was locked")
    end)

    T.it("does not send a device that is only obeying back to bed", function()
        -- Both sides suspend each other, so the one following an order must
        -- not pass it on, or the two would take turns saying goodnight.
        connectPair()
        callSlave("UIManager._suspends = 0")
        callMaster("D.plugin:onSuspend()")
        controller:assertEventually(slave, "UIManager._suspends", 1)
        socket.sleep(0.4)
        T.assertEquals(controller:number(slave, "UIManager._suspends"), 1,
            "the slave suspended more than once for one lock")
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

    T.it("takes the follower to sleep with the leader, and back", function()
        -- The leader is the one somebody is holding, so it is the one
        -- allowed to doze; the follower has nobody to wake it and would
        -- simply stop following.
        connectPair()
        setMasterPage(30)
        controller:assertEventually(slave, "UIManager._prevent_standby_count", 1,
            "a follower should stay awake while the leader is")
        T.assertEquals(controller:number(master, "UIManager._prevent_standby_count"), 1,
            "the leader holds while the book is being read")

        -- Nothing happens for long enough that the book is down. The
        -- leader lets go, which is what tells KOReader — and through it
        -- this plugin — that the reader has gone idle.
        callMaster("Core.last_activity = 0")
        controller:assertEventually(master, "UIManager._prevent_standby_count", 0,
            "the leader should stop holding once nobody is reading", 15)
        callMaster("D.plugin:onAllowStandby()")
        controller:assertEventually(slave, "UIManager._prevent_standby_count", 0,
            "the follower stayed awake after the leader dozed off")

        callMaster("D.plugin:onPreventStandby()")
        controller:assertEventually(slave, "UIManager._prevent_standby_count", 1,
            "the follower did not wake with the leader")
    end)

    T.it("catches up by itself when it wakes", function()
        connectPair()
        setMasterPage(30)
        controller:assertEventually(slave, "D:getPage()", 31)

        -- Asleep, and missing everything.
        callMaster("Core.last_activity = 0")
        callMaster("D.plugin:onAllowStandby()")
        controller:assertEventually(slave, "UIManager._prevent_standby_count", 0)
        callSlave("UI.paging.current_page = 1")

        -- Waking is the follower's cue to ask where it belongs, since it
        -- has no idea what happened while it was out.
        callSlave("D.plugin:onPreventStandby()")
        controller:assertEventually(slave, "D:getPage()", 31,
            "a woken follower should ask for its place rather than wait")
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
os.exit(exit_code)
