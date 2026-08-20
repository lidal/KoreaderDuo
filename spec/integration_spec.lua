--[[--
Two devices, two processes, one book.

This is the test that matters: a leader and a follower, each a separate OS
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
local leader = controller:spawn("leader")
local follower = controller:spawn("follower")
local follower2 = controller:spawn("follower2")

local DUO_PORT = 19970

local function callLeader(code) return controller:call(leader, code) end
local function callFollower(code) return controller:call(follower, code) end

--- Puts both devices back to a known state: leader running, follower attached,
-- both in spread mode on page 10/11.
local function connectPair(options)
    options = options or {}
    callLeader("Core:stop('test reset')")
    callFollower("Core:stop('test reset')")
    controller:call(follower2, "Core:stop('test reset')")

    callLeader(("Core.settings.port = %d"):format(DUO_PORT))
    callLeader(("Core.settings.token = %q"):format(options.leader_token or "K7F2QX"))
    callLeader(("Core.settings.mode = %q"):format(options.mode or "spread"))
    callLeader(("Core.settings.reverse = %s"):format(tostring(options.reverse or false)))
    callLeader(("Core.settings.follower_can_turn = %s"):format(tostring(options.follower_can_turn ~= false)))
    callLeader("Core.settings.discovery_port = 19971")

    callFollower(("Core.settings.token = %q"):format(options.follower_token or "K7F2QX"))
    callFollower(("Core.settings.peer_port = %d"):format(DUO_PORT))
    callFollower("Core.settings.discovery_port = 19971")
    -- Set on both sides: the follower consults its own copy when deciding
    -- whether to forward a turn, and a test that switched it off would
    -- otherwise leak into every test after it.
    callFollower(("Core.settings.follower_can_turn = %s"):format(tostring(options.follower_can_turn ~= false)))

    callLeader("Core:start('leader')")
    callFollower(("Core:start('follower', { host = '127.0.0.1', port = %d })"):format(DUO_PORT))

    if options.expect_failure then return end
    controller:assertEventually(leader, "Core:isConnected()", true, "leader never saw the follower")
    controller:assertEventually(follower, "Core:isConnected()", true, "follower never connected")
end

--- Sets the leader's page and waits for the spread to settle.
local function setLeaderPage(page)
    callLeader(("D:jumpToPage(%d)"):format(page))
    controller:assertEventually(leader, "D:getPage()", page, "leader did not move")
end

--------------------------------------------------------------------------
-- Tests
--------------------------------------------------------------------------

T.describe("two devices, connecting", function()
    T.it("pairs over the network", function()
        connectPair()
        T.assertEquals(callLeader("Core.role"), "leader")
        T.assertEquals(callFollower("Core.role"), "follower")
        T.assertMatch(callLeader("Core:getStatusText()"), "Leader")
        T.assertMatch(callFollower("Core:getStatusText()"), "following")
    end)

    T.it("learns the other device's name", function()
        connectPair()
        T.assertEquals(callFollower("Core:getReadyLinks()[1].peer_name"), "leader")
        T.assertEquals(callLeader("Core:getReadyLinks()[1].peer_name"), "follower")
    end)

    T.it("turns away a device with the wrong pairing code", function()
        connectPair{ follower_token = "NOPE99", expect_failure = true }
        -- The follower must not end up connected, however long we wait.
        local connected = controller:waitFor(follower, "Core:isConnected()", true, 3)
        T.assertTrue(not connected, "a device with the wrong code got in")
        T.assertTrue(not (controller:waitFor(leader, "Core:isConnected()", true, 1)),
            "the leader accepted a device with the wrong code")
    end)

    T.it("finds the leader over UDP without being told its address", function()
        connectPair()
        callFollower("Core:startScan(function(r) Core.scan_results = r end)")
        controller:assertEventually(follower, "Core.scan_results ~= nil", true, "the scan never finished")
        T.assertEquals(controller:call(follower, "#Core.scan_results"), "1")
        T.assertEquals(controller:call(follower, "Core.scan_results[1].name"), "leader")
        T.assertEquals(controller:call(follower, "Core.scan_results[1].port"), tostring(DUO_PORT))
    end)
end)

T.describe("two devices, one spread", function()
    T.it("puts the follower on the page after the leader's", function()
        connectPair()
        setLeaderPage(10)
        controller:assertEventually(follower, "D:getPage()", 11, "the follower is not showing the next page")
    end)

    T.it("moves both devices by two when the leader turns a page", function()
        connectPair()
        setLeaderPage(10)
        controller:assertEventually(follower, "D:getPage()", 11)

        callLeader("D:tapForward()")
        controller:assertEventually(leader, "D:getPage()", 12, "the leader must skip the page the follower showed")
        controller:assertEventually(follower, "D:getPage()", 13)

        callLeader("D:tapForward()")
        controller:assertEventually(leader, "D:getPage()", 14)
        controller:assertEventually(follower, "D:getPage()", 15)

        callLeader("D:tapBack()")
        controller:assertEventually(leader, "D:getPage()", 12)
        controller:assertEventually(follower, "D:getPage()", 13)
    end)

    T.it("lets a tap on the follower turn the pair", function()
        connectPair()
        setLeaderPage(20)
        controller:assertEventually(follower, "D:getPage()", 21)

        callFollower("D:tapForward()")
        controller:assertEventually(leader, "D:getPage()", 22, "the follower's tap did not reach the leader")
        controller:assertEventually(follower, "D:getPage()", 23)

        callFollower("D:tapBack()")
        controller:assertEventually(leader, "D:getPage()", 20)
        controller:assertEventually(follower, "D:getPage()", 21)
    end)

    T.it("ignores taps on the follower when that is switched off", function()
        connectPair{ follower_can_turn = false }
        setLeaderPage(30)
        controller:assertEventually(follower, "D:getPage()", 31)

        callFollower("Core.settings.follower_can_turn = false")
        callFollower("D:tapForward()")
        socket.sleep(0.5)
        T.assertEquals(controller:number(leader, "D:getPage()"), 30, "the leader moved anyway")
        T.assertEquals(controller:number(follower, "D:getPage()"), 31, "the follower drifted out of the spread")
    end)

    T.it("follows a jump from the table of contents", function()
        connectPair()
        setLeaderPage(10)
        controller:assertEventually(follower, "D:getPage()", 11)
        setLeaderPage(157)
        controller:assertEventually(follower, "D:getPage()", 158, "the follower did not follow an absolute jump")
    end)

    T.it("mirrors both devices onto the same page", function()
        connectPair{ mode = "mirror" }
        setLeaderPage(42)
        controller:assertEventually(follower, "D:getPage()", 42)
        callLeader("D:tapForward()")
        controller:assertEventually(leader, "D:getPage()", 43, "mirror mode must move one page at a time")
        controller:assertEventually(follower, "D:getPage()", 43)
    end)

    T.it("can put the follower on the left", function()
        connectPair{ reverse = true }
        setLeaderPage(50)
        controller:assertEventually(follower, "D:getPage()", 49)
        callLeader("D:tapForward()")
        controller:assertEventually(leader, "D:getPage()", 52)
        controller:assertEventually(follower, "D:getPage()", 51)
    end)

    T.it("stops at the end of the book instead of running past it", function()
        connectPair()
        setLeaderPage(300)
        controller:assertEventually(follower, "D:getPage()", 300, "the follower should stay on the last page")
    end)

    T.it("switches layout while connected", function()
        connectPair()
        setLeaderPage(10)
        controller:assertEventually(follower, "D:getPage()", 11)
        callLeader("Core.settings.mode = 'mirror'; Core:broadcastState()")
        controller:assertEventually(follower, "D:getPage()", 10, "the follower did not follow the layout change")
        callLeader("Core.settings.mode = 'spread'; Core:broadcastState()")
        controller:assertEventually(follower, "D:getPage()", 11)
    end)
end)

T.describe("matching typography", function()
    -- The point of all this: page numbers only mean the same thing on two
    -- devices if both break the lines in the same places.
    local function fontSize(device) return controller:number(device, "UI.document.configurable.font_size") end
    local function pageCount(device) return controller:number(device, "UI.document:getPageCount()") end

    T.it("brings a mismatched follower into line on connect", function()
        callLeader("Core:stop('reset')")
        callFollower("Core:stop('reset')")
        -- The follower is reading at a bigger size, so it has more pages than
        -- the leader and the spread would be nonsense.
        callFollower("UI.document.configurable.font_size = 30; UI.document:repaginate()")
        T.assertNotEquals(pageCount(follower), pageCount(leader), "the fixture is not actually mismatched")

        connectPair()
        controller:assertEventually(follower, "UI.document.configurable.font_size", 22,
            "the follower kept its own font size")
        T.assertEquals(pageCount(follower), pageCount(leader),
            "the two devices still disagree about how long the book is")
    end)

    T.it("matches a book opened after the link came up", function()
        --[[
        The layout settings sent when the link comes up arrive while a
        follower is still in the file list, with no book to apply them to, and
        are dropped. If nothing sends them again, the two devices sit at
        different font sizes until somebody changes one by hand — which is
        exactly what it looked like on real hardware. A follower asks for its
        place the moment it finishes opening a book; the answer has to
        carry the typography as well as the page.
        ]]
        connectPair()
        callLeader("UI:handleEvent(D.Event:new('SetFontSize', 26))")
        controller:assertEventually(follower, "UI.document.configurable.font_size", 26)

        -- A fresh book on the follower, opened at a size of its own. All one
        -- snippet: the device only touches its sockets between commands, so
        -- there is no window for the answer to arrive early and make this
        -- pass without ever having been mismatched.
        callFollower("D:openDocument{ page_count = 300 }" ..
            "; UI.document.configurable.font_size = 30; UI.document:repaginate()")

        controller:assertEventually(follower, "UI.document.configurable.font_size", 26,
            "a book opened on the follower kept its own font size")
        T.assertEquals(pageCount(follower), pageCount(leader),
            "the two devices still disagree about how long the book is")
    end)

    T.it("follows a change made on the leader", function()
        connectPair()
        callLeader("UI:handleEvent(D.Event:new('SetFontSize', 26))")
        controller:assertEventually(follower, "UI.document.configurable.font_size", 26,
            "the follower did not follow the leader")
        T.assertEquals(pageCount(follower), pageCount(leader))
    end)

    T.it("follows a change made on the follower", function()
        connectPair()
        callFollower("UI:handleEvent(D.Event:new('SetFontSize', 18))")
        -- A follower cannot decide anything by itself: it tells the leader,
        -- which applies it and passes it on.
        controller:assertEventually(leader, "UI.document.configurable.font_size", 18,
            "the leader did not follow the follower")
        T.assertEquals(fontSize(follower), 18)
        T.assertEquals(pageCount(follower), pageCount(leader))
    end)

    T.it("matches margins, which are a pair rather than a number", function()
        connectPair()
        callLeader("UI:handleEvent(D.Event:new('SetPageHorizMargins', {25, 25}))")
        controller:assertEventually(follower, "UI.document.configurable.h_page_margins[1]", 25,
            "the follower did not follow the margins")
        T.assertEquals(controller:number(follower, "UI.document.configurable.h_page_margins[2]"), 25)
        T.assertEquals(pageCount(follower), pageCount(leader))
    end)

    T.it("keeps the spread correct after a relayout", function()
        connectPair()
        setLeaderPage(40)
        controller:assertEventually(follower, "D:getPage()", 41)

        callLeader("UI:handleEvent(D.Event:new('SetFontSize', 24))")
        controller:assertEventually(follower, "UI.document.configurable.font_size", 24)
        -- Whatever page the leader ended up on, the follower must be on the next.
        local leader_page = controller:number(leader, "D:getPage()")
        controller:assertEventually(follower, "D:getPage()", leader_page + 1,
            "the spread broke when the book was laid out again")
    end)

    T.it("leaves the devices alone when switched off", function()
        connectPair()
        callFollower("Core.settings.match_typography = false")
        callLeader("Core.settings.match_typography = false")
        callFollower("UI.document.configurable.font_size = 30; UI.document:repaginate()")
        callLeader("UI:handleEvent(D.Event:new('SetFontSize', 20))")
        socket.sleep(2.5)
        T.assertEquals(fontSize(follower), 30, "the follower was changed with matching switched off")
    end)

    T.it("does not let a follower overrule the leader when the link returns", function()
        --[[
        A follower remembers the layout it last saw so a change made on it
        can be told from the state it has been sitting in. Kept across a
        disconnection that memory lies: anything that drifted while the two
        were apart reads as a change somebody just made, and goes to the
        leader the instant the link is ready -- ahead of the leader's own
        settings, whose whole job is to be the tiebreaker.

        Which one won came down to which message arrived first, so this was
        a coin toss rather than a rule.
        ]]
        callFollower("Core:stop('reset')")
        callLeader("Core:stop('reset')")
        callFollower("Core.settings.match_typography = true")
        callLeader("Core.settings.match_typography = true")
        callLeader("UI:handleEvent(D.Event:new('SetFontSize', 22))")
        callFollower("UI:handleEvent(D.Event:new('SetFontSize', 30))")
        T.assertEquals(callFollower("tostring(Core.typography_snapshot)"), "nil",
            "a stopped device should not still be holding last session's layout")

        connectPair()
        controller:assertEventually(follower, "UI.document.configurable.font_size", 22,
            "the follower kept the size it drifted to while disconnected")
        -- The half that actually catches the race: the leader must not have
        -- been talked into the follower's size on the way.
        socket.sleep(2)
        T.assertEquals(fontSize(leader), 22, "the follower overruled the leader")
        T.assertEquals(fontSize(follower), 22)
    end)

    T.it("can put the follower's own settings back", function()
        callFollower("Core:stop('reset')")
        callLeader("Core:stop('reset')")
        callFollower("Core.settings.match_typography = true")
        callLeader("Core.settings.match_typography = true")
        -- On a device this is fresh per document; these are all one session.
        callFollower("Core.typography_backup = nil")
        -- Both sizes set here rather than assumed: the previous test leaves
        -- the leader somewhere of its own choosing.
        callLeader("UI:handleEvent(D.Event:new('SetFontSize', 22))")
        callFollower("UI:handleEvent(D.Event:new('SetFontSize', 30))")
        connectPair()
        controller:assertEventually(follower, "UI.document.configurable.font_size", 22,
            "the follower did not take the leader's size")

        T.assertEquals(callFollower("Core:hasTypographyBackup()"), "true")
        T.assertEquals(callFollower("Core:restoreTypography()"), "true")
        T.assertEquals(fontSize(follower), 30, "the follower's own size did not come back")
        T.assertEquals(callFollower("Core:hasTypographyBackup()"), "false")
    end)
end)

T.describe("agreeing on the settings", function()
    --[[
    Nothing about the configuration used to cross the link, and several
    features are checked on both devices — page turns from the follower, for
    one. Switching such a thing off on one device silently disabled it, and
    which device you had to look at differed from feature to feature.
    ]]
    T.it("takes the leader's settings on connect, whatever the follower had", function()
        callLeader("Core:stop('reset')")
        callFollower("Core:stop('reset')")
        -- Configured differently, and deliberately in both directions so a
        -- test that simply set everything true could not pass.
        callFollower("Core.settings.share_browser = false")
        callFollower("Core.settings.covers_first = false")
        callFollower("Core.settings.mode = 'solo'")
        callLeader("Core.settings.share_browser = true")
        callLeader("Core.settings.covers_first = true")
        callLeader("Core.settings.mode = 'spread'")

        connectPair()
        controller:assertEventually(follower, "Core:get('share_browser')", true,
            "the follower kept its own setting")
        T.assertEquals(callFollower("Core:get('covers_first')"), "true")
        T.assertEquals(callFollower("Core:get('mode')"), "spread",
            "a setting that is a word has to survive the trip as one")
    end)

    T.it("follows a change made on either device afterwards", function()
        connectPair()
        callLeader("Core:set('follower_can_turn', false)")
        controller:assertEventually(follower, "Core:get('follower_can_turn')", false,
            "the follower did not follow the leader")

        -- And back the other way: a follower asks, the leader decides, and the
        -- answer comes back round.
        callFollower("Core:set('follower_can_turn', true)")
        controller:assertEventually(leader, "Core:get('follower_can_turn')", true,
            "a change on the follower never reached the leader")
        controller:assertEventually(follower, "Core:get('follower_can_turn')", true)
    end)

    T.it("never levels the things that make the two devices different", function()
        --[[
        Ports, codes, addresses and names are what let these two find each
        other at all. Pushing them across would be a fine way for a pair to
        talk itself into silence.
        ]]
        connectPair()
        local before = callFollower("Core:get('peer_port') .. ',' .. Core:get('device_name')")
        callLeader("Core:pushSettings('test')")
        socket.sleep(0.5)
        T.assertEquals(callFollower("Core:get('peer_port') .. ',' .. Core:get('device_name')"),
            before, "the follower adopted something that identifies the other device")
        T.assertEquals(callFollower("Core.role"), "follower", "and it is still the follower")
    end)
end)

T.describe("matching the frontlight", function()
    local function light(device) return controller:number(device, "Device.getPowerDevice().fl_intensity") end

    T.it("brings a mismatched follower to the leader's brightness on connect", function()
        callLeader("Core:stop('reset')")
        callFollower("Core:stop('reset')")
        callLeader("Device.getPowerDevice().fl_intensity = 18")
        callFollower("Device.getPowerDevice().fl_intensity = 3")
        T.assertNotEquals(light(follower), light(leader), "the fixture is not actually mismatched")

        connectPair()
        controller:assertEventually(follower, "Device.getPowerDevice().fl_intensity", 18,
            "the follower stayed at its own brightness")
    end)

    T.it("follows a change made on the leader", function()
        connectPair()
        callLeader("Device.getPowerDevice().fl_intensity = 6")
        controller:assertEventually(follower, "Device.getPowerDevice().fl_intensity", 6,
            "the follower did not follow", 15)
    end)

    T.it("follows a change made on the follower", function()
        connectPair()
        callFollower("Device.getPowerDevice().fl_intensity = 21")
        controller:assertEventually(leader, "Device.getPowerDevice().fl_intensity", 21,
            "a change on the follower never reached the leader", 15)
    end)

    T.it("follows the light being switched off, not only dimmed", function()
        --[[
        The report: brightness adjustments synced and the on/off toggle did
        not. KOReader remembers the level a light will come back to while it
        is off, so switching off changes no number a snapshot of levels
        would notice -- and Duo was only sending numbers.
        ]]
        connectPair()
        controller:assertEventually(follower, "Device.getPowerDevice().is_fl_on", true,
            "the fixture should start with both lights on")

        callLeader("Device.getPowerDevice().is_fl_on = false")
        controller:assertEventually(follower, "Device.getPowerDevice().is_fl_on", false,
            "the follower's light stayed on", 15)
        -- The brightness it will come back to must survive being switched off.
        T.assertEquals(light(follower), light(leader),
            "switching off should not have moved the level either")

        callLeader("Device.getPowerDevice().is_fl_on = true")
        controller:assertEventually(follower, "Device.getPowerDevice().is_fl_on", true,
            "the follower did not come back on", 15)
    end)

    T.it("follows the switch from the follower too", function()
        connectPair()
        callFollower("Device.getPowerDevice().is_fl_on = false")
        controller:assertEventually(leader, "Device.getPowerDevice().is_fl_on", false,
            "the switch never reached the leader", 15)
        callFollower("Device.getPowerDevice().is_fl_on = true")
        controller:assertEventually(leader, "Device.getPowerDevice().is_fl_on", true, nil, 15)
    end)

    T.it("settles rather than correcting each other for ever", function()
        -- Both devices watch their own light and share what they find, so a
        -- value that rounds a step either way could have them chasing it up
        -- and down between them without ever stopping.
        connectPair()
        callLeader("Device.getPowerDevice().fl_intensity = 13")
        controller:assertEventually(follower, "Device.getPowerDevice().fl_intensity", 13, nil, 15)
        socket.sleep(3)
        T.assertEquals(light(leader), 13, "the leader's light moved on its own")
        T.assertEquals(light(follower), 13, "the two never settled")
    end)

    T.it("leaves the light alone when the option is off", function()
        connectPair()
        callLeader("Core:set('sync_frontlight', false)")
        controller:assertEventually(follower, "Core:get('sync_frontlight')", false)
        callFollower("Device.getPowerDevice().fl_intensity = 2")
        callLeader("Device.getPowerDevice().fl_intensity = 20")
        socket.sleep(2.5)
        T.assertEquals(light(follower), 2, "the light was matched with matching switched off")
        callLeader("Core:set('sync_frontlight', true)")
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

        callLeader("Core:stop('reset')")
        callFollower("Core:stop('reset')")
        callLeader(setup)
        callFollower(options.follower_setup or setup)
        connectPair()
        callLeader("Core.settings.share_browser = true")
        callFollower("Core.settings.share_browser = true")
        callLeader("Core:broadcastBrowser()")
    end

    local function visible(device)
        return controller:call(device, "table.concat(D:visibleBooks(), ',')")
    end

    T.it("shows the next screenful of books on the second device", function()
        browseTogether{ count = 20, perpage = 6 }
        controller:assertEventually(follower, "UI.file_chooser.page", 2,
            "the follower is not on the second screenful")
        T.assertEquals(visible(leader), "book01.epub,book02.epub,book03.epub,book04.epub,book05.epub,book06.epub")
        T.assertEquals(visible(follower), "book07.epub,book08.epub,book09.epub,book10.epub,book11.epub,book12.epub")
    end)

    T.it("moves the whole row by two screenfuls at a time", function()
        browseTogether{ count = 40, perpage = 6 }
        controller:assertEventually(follower, "UI.file_chooser.page", 2)

        -- A swipe on the leader: it takes screen 3, the follower takes screen 4.
        callLeader("UI.file_chooser:onNextPage()")
        controller:assertEventually(leader, "UI.file_chooser.page", 3,
            "the leader must skip the screenful the follower was showing")
        controller:assertEventually(follower, "UI.file_chooser.page", 4)
        T.assertEquals(visible(leader), "book13.epub,book14.epub,book15.epub,book16.epub,book17.epub,book18.epub")
        T.assertEquals(visible(follower), "book19.epub,book20.epub,book21.epub,book22.epub,book23.epub,book24.epub")

        callLeader("UI.file_chooser:onPrevPage()")
        controller:assertEventually(leader, "UI.file_chooser.page", 1)
        controller:assertEventually(follower, "UI.file_chooser.page", 2)
    end)

    T.it("lets a swipe on the follower move the row", function()
        browseTogether{ count = 40, perpage = 6 }
        controller:assertEventually(follower, "UI.file_chooser.page", 2)
        callFollower("UI.file_chooser:onNextPage()")
        controller:assertEventually(leader, "UI.file_chooser.page", 3,
            "the follower's swipe did not reach the leader")
        controller:assertEventually(follower, "UI.file_chooser.page", 4)
    end)

    T.it("stops at the end of the list instead of wrapping round", function()
        -- KOReader's own paging cycles back to the first page at the end,
        -- which would put the two devices on unrelated parts of the list.
        browseTogether{ count = 20, perpage = 6 } -- four screenfuls
        callLeader("UI.file_chooser:onNextPage()")
        controller:assertEventually(leader, "UI.file_chooser.page", 3)
        callLeader("UI.file_chooser:onNextPage()")
        socket.sleep(0.6)
        T.assertEquals(controller:number(leader, "UI.file_chooser.page"), 4,
            "the leader should stop at the last screenful")
        T.assertEquals(controller:number(follower, "UI.file_chooser.page"), 4)
    end)

    T.it("makes both devices fit the same number of books on a screen", function()
        browseTogether{ count = 24, perpage = 6, follower_setup =
            "D:openFileManager{ path = '/books', perpage = 4, items = " ..
            "{'book01.epub','book02.epub','book03.epub','book04.epub','book05.epub','book06.epub'," ..
            "'book07.epub','book08.epub','book09.epub','book10.epub','book11.epub','book12.epub'," ..
            "'book13.epub','book14.epub','book15.epub','book16.epub','book17.epub','book18.epub'," ..
            "'book19.epub','book20.epub','book21.epub','book22.epub','book23.epub','book24.epub'} }" }
        controller:assertEventually(follower, "UI.file_chooser.perpage", 6,
            "the follower kept its own screenful size, so the halves cannot line up")
        controller:assertEventually(follower, "UI.file_chooser.page", 2)
        T.assertEquals(visible(follower), "book07.epub,book08.epub,book09.epub,book10.epub,book11.epub,book12.epub")
    end)

    T.it("spreads a grid of covers across the two screens", function()
        -- KOReader's cover browser can draw the list as a grid, where a
        -- screenful is its columns times its rows. Two grids can be evened
        -- up exactly, because the shape travels with the page.
        browseTogether{ count = 24, perpage = 6 }
        callLeader("UI.file_chooser:asCoverBrowser('mosaic', { cols = 3, rows = 2 })")
        callFollower("UI.file_chooser:asCoverBrowser('mosaic', { cols = 2, rows = 2 })")
        callFollower("UIManager.shown_log = {}")
        callFollower("Core.warned_listing = false")
        callLeader("Core:broadcastBrowser()")

        controller:assertEventually(follower, "UI.file_chooser.perpage", 6,
            "the follower kept its own grid, so the halves cannot line up")
        T.assertEquals(controller:number(follower, "UI.file_chooser.nb_cols"), 3,
            "the shape should have come over, not just the total")
        T.assertEquals(controller:number(follower, "UI.file_chooser.nb_rows"), 2)
        controller:assertEventually(follower, "UI.file_chooser.page", 2)
        T.assertEquals(visible(leader), "book01.epub,book02.epub,book03.epub,book04.epub,book05.epub,book06.epub")
        T.assertEquals(visible(follower), "book07.epub,book08.epub,book09.epub,book10.epub,book11.epub,book12.epub")
        T.assertEquals(callFollower(
            "(function() for _, m in ipairs(UIManager.shown_log) do if tostring(m.text):find('on a screen') then return true end end return false end)()"),
            "false", "it warned about a difference it had just evened out")
    end)

    T.it("moves a grid on by two screenfuls too, and stops at the end", function()
        -- The same rule as a book: with one follower, a turn skips the
        -- screenful the follower is already showing. Worth its own test in
        -- mosaic mode, where the cover browser replaces how a page is
        -- measured but not how it is turned.
        browseTogether{ count = 30, perpage = 6 }
        callLeader("UI.file_chooser:asCoverBrowser('mosaic', { cols = 2, rows = 3 })")
        callFollower("UI.file_chooser:asCoverBrowser('mosaic', { cols = 2, rows = 3 })")
        callLeader("Core:broadcastBrowser()")
        controller:assertEventually(leader, "UI.file_chooser.page_num", 5,
            "thirty books at six a screen is five screenfuls")
        controller:assertEventually(follower, "UI.file_chooser.page", 2)

        callLeader("UI.file_chooser:onNextPage()")
        controller:assertEventually(leader, "UI.file_chooser.page", 3,
            "the leader must skip the screenful the follower was showing")
        controller:assertEventually(follower, "UI.file_chooser.page", 4)
        T.assertEquals(visible(leader), "book13.epub,book14.epub,book15.epub,book16.epub,book17.epub,book18.epub")
        T.assertEquals(visible(follower), "book19.epub,book20.epub,book21.epub,book22.epub,book23.epub,book24.epub")

        -- A turn on the follower moves the row just the same.
        callFollower("UI.file_chooser:onPrevPage()")
        controller:assertEventually(leader, "UI.file_chooser.page", 1,
            "a swipe on the grid of the second device did not reach the first")
        controller:assertEventually(follower, "UI.file_chooser.page", 2)

        -- And the end of the list is a wall, not a loop.
        callLeader("UI.file_chooser:onNextPage()")
        controller:assertEventually(follower, "UI.file_chooser.page", 4)
        callLeader("UI.file_chooser:onNextPage()")
        socket.sleep(0.8)
        T.assertEquals(controller:number(leader, "UI.file_chooser.page"), 5,
            "the leader should stop at the last screenful rather than wrap")
        T.assertEquals(controller:number(follower, "UI.file_chooser.page"), 5,
            "with nothing after it, the follower shows the last screenful too")
    end)

    T.it("says so when one device is a grid and the other a list", function()
        -- Here the shape cannot be worked out: told only that the other
        -- device fits eight, a grid has no way to know whether that is two
        -- by four or one by eight, and guessing would rearrange the screen.
        browseTogether{ count = 24, perpage = 8 }
        callFollower("UIManager.shown_log = {}")
        callFollower("Core.warned_listing = false")
        callFollower("UI.file_chooser:asCoverBrowser('mosaic', { cols = 3, rows = 3 })")
        callLeader("Core:broadcastBrowser()")
        controller:assertEventually(follower,
            "(function() for _, m in ipairs(UIManager.shown_log) do if tostring(m.text):find('on a screen') then return true end end return false end)()",
            true, "no warning when the two screenfuls are different sizes")
        T.assertEquals(controller:number(follower, "UI.file_chooser.perpage"), 9,
            "the grid should have been left as it is")
    end)

    T.it("asks where it belongs when it is reopened on the list", function()
        -- A follower that has just been rebuilt — a document closed, a folder
        -- reopened — knows nothing about which screenful is its own.
        browseTogether{ count = 40, perpage = 6 }
        callLeader("UI.file_chooser:onNextPage()")
        controller:assertEventually(follower, "UI.file_chooser.page", 4)

        callFollower("UI.file_chooser:onGotoPage(1)")
        callFollower("Core:getReadyLinks()[1]:send('SYNC', {})")
        controller:assertEventually(follower, "UI.file_chooser.page", 4,
            "asking for the current state did not bring back the book list")
    end)

    T.it("says so when the two devices hold different books", function()
        browseTogether{ count = 20, perpage = 6, follower_setup =
            "D:openFileManager{ path = '/books', perpage = 6, items = {'other01.epub','other02.epub'} }" }
        controller:assertEventually(follower,
            "(function() for _, m in ipairs(UIManager.shown_log) do if tostring(m.text):find('not line up') then return true end end return false end)()",
            true, "no warning about the two libraries differing")
    end)

    T.it("leaves the browser alone when switched off", function()
        browseTogether{ count = 20, perpage = 6 }
        callFollower("Core.settings.share_browser = false")
        callFollower("UI.file_chooser:onGotoPage(1)")
        callLeader("UI.file_chooser:onNextPage()")
        socket.sleep(1)
        T.assertEquals(controller:number(follower, "UI.file_chooser.page"), 1,
            "the follower moved with sharing switched off")
        callFollower("Core.settings.share_browser = true")
    end)

    T.it("keeps the link when a book is opened from the list", function()
        browseTogether{ count = 20, perpage = 6 }
        controller:assertEventually(follower, "UI.file_chooser.page", 2)

        -- KOReader throws the whole file manager away and builds a ReaderUI,
        -- which is the moment a connection owned by the UI would die.
        callLeader("D:openDocument{ page_count = 300 }")
        callFollower("D:openDocument{ page_count = 300 }")

        T.assertEquals(callLeader("Core:isConnected()"), "true",
            "the link died on the way from the list into a book")
        setLeaderPage(12)
        controller:assertEventually(follower, "D:getPage()", 13,
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

    T.it("sends a book the follower does not have, and opens it there", function()
        local path = makeBook("sent-book.epub", 40000)
        connectPair()
        callFollower("Core.settings.sync_books = true")
        callLeader("Core.settings.sync_books = true")
        callFollower("UIManager.shown_log = {}")
        -- Both processes share a disk, so without this the follower would open
        -- the leader's copy and the book would never go over the wire.
        callFollower(("D:doesNotHave(%q)"):format(path))

        -- The leader opens a book that exists only on its side.
        callLeader(("UI.document.file = %q"):format(path))
        callLeader("UI.digest = 'digest-sent-book'")
        callLeader("Core:broadcastDocument()")

        -- The follower asks for it, receives it, and opens what arrived.
        controller:assertEventually(follower,
            "(function() for _, m in ipairs(UIManager.shown_log) do if m.class == 'ShowReader' then return true end end return false end)()",
            true, "the follower never opened the book it was sent", 25)

        local landed = controller:call(follower,
            "(function() for _, m in ipairs(UIManager.shown_log) do if m.class == 'ShowReader' then return m.text end end return '' end)()")
        T.assertMatch(landed, "sent%-book%.epub")
        T.assertTrue(landed ~= path,
            "the follower opened the leader's own copy, so nothing was sent")
        T.assertEquals(readFile(landed), readFile(path),
            "the book that arrived is not the book that was sent")
        os.remove(landed)
    end)

    T.it("tells the other device when a send fails part way", function()
        -- The failure that matters is the quiet one: give up mid-book
        -- without a word and the other device sits on a half-written file
        -- waiting for a chunk that is never coming.
        local path = makeBook("broken-book.epub", 200000)
        callFollower("Core:stop('reset')")
        connectPair()
        callFollower("Core.settings.sync_books = true")
        callLeader("Core.settings.sync_books = true")
        callFollower("UIManager.shown_log = {}")
        callFollower(("D:doesNotHave(%q)"):format(path))

        -- Armed before the follower asks, so the book cannot slip across
        -- whole in the gap between two calls from here. Only the chunks
        -- fail, the way an unsendable message does: the link itself is
        -- fine, which is what makes staying silent inexcusable.
        callLeader([[(function()
            local link = Core:getReadyLinks()[1]
            local real = link.send
            link.send = function(self, msg_type, fields)
                if msg_type == 'BOOK_DATA' then return false, 'the chunk would not fit' end
                return real(self, msg_type, fields)
            end
        end)()]])

        callLeader(("UI.document.file = %q"):format(path))
        callLeader("UI.digest = 'digest-broken-book'")
        callLeader("Core:broadcastDocument()")

        controller:assertEventually(follower,
            "(function() for _, m in ipairs(UIManager.shown_log) do if tostring(m.text):find('could not fetch') then return true end end return false end)()",
            true, "the follower was never told the transfer had failed", 20)
        T.assertEquals(callLeader("tostring(Core.book_sender)"), "nil",
            "the leader should have given up on the book")
        T.assertEquals(callFollower("tostring(Core.book_receiver)"), "nil",
            "the follower was left holding a half-written book")
    end)

    T.it("will not hand over a book it does not have open", function()
        connectPair()
        callFollower("Core.settings.sync_books = true")
        callFollower("UIManager.shown_log = {}")
        -- A peer asking for an arbitrary path gets nothing.
        callFollower("Core.book_request = { file = '/etc/passwd' }")
        callFollower("Core:getReadyLinks()[1]:send('BOOK_REQ', { file = '/etc/passwd' })")
        controller:assertEventually(follower,
            "(function() for _, m in ipairs(UIManager.shown_log) do if tostring(m.text):find('not the book') then return true end end return false end)()",
            true, "the leader should refuse a book it does not have open")
        callFollower("Core.book_request = nil")
    end)

    T.it("says nothing and sends nothing when switched off", function()
        local path = makeBook("unsent-book.epub", 4000)
        callFollower("Core:stop('reset')")
        connectPair()
        callFollower("Core.settings.sync_books = false")
        callFollower("UIManager.shown_log = {}")
        callLeader(("UI.document.file = %q"):format(path))
        callLeader("UI.digest = 'digest-unsent'")
        callLeader("Core:broadcastDocument()")
        socket.sleep(2)
        T.assertEquals(callFollower("tostring(Core.book_receiver)"), "nil",
            "a book was fetched with sending switched off")
        callFollower("Core.settings.sync_books = true")
        os.execute("rm -rf " .. BOOK_DIR)
    end)
end)

T.describe("three devices", function()
    -- Nothing in the design caps this at two: each device gets a slot and
    -- shows the leader's page plus its slot number, and a turn moves the
    -- whole row. Three e-readers on a desk is a wide spread, but the
    -- arithmetic is the same one the pair relies on, so it is worth proving.
    T.it("lays three pages out in a row and turns them together", function()
        connectPair()
        controller:call(follower2, ("Core.settings.token = %q"):format("K7F2QX"))
        controller:call(follower2, ("Core.settings.peer_port = %d"):format(DUO_PORT))
        controller:call(follower2, ("Core:start('follower', { host = '127.0.0.1', port = %d })"):format(DUO_PORT))
        controller:assertEventually(follower2, "Core:isConnected()", true, "the third device never joined")

        setLeaderPage(10)
        controller:assertEventually(follower, "D:getPage()", 11)
        controller:assertEventually(follower2, "D:getPage()", 12)
        T.assertEquals(controller:number(leader, "Core:getStep()"), 3)

        callLeader("D:tapForward()")
        controller:assertEventually(leader, "D:getPage()", 13)
        controller:assertEventually(follower, "D:getPage()", 14)
        controller:assertEventually(follower2, "D:getPage()", 15)

        T.assertEquals(callLeader("Core:getStatusText()"):match("pages ([%d–]+)"), "13–14–15")

        controller:call(follower2, "Core:stop('done')")
        controller:assertEventually(leader, "Core:followerCount()", 1, "the leader did not shrink the spread")
    end)
end)

T.describe("two devices, when things go wrong", function()
    T.it("puts the follower back on the right page after a reconnect", function()
        connectPair()
        setLeaderPage(60)
        controller:assertEventually(follower, "D:getPage()", 61)

        -- Yank the connection the way a sleeping device or a dropped
        -- Wi-Fi link would, without telling either side.
        callFollower("Core.links[1].stream:close()")
        controller:assertEventually(follower, "Core:isConnected()", false, "the follower did not notice")

        -- While it is away, the leader reads on alone.
        setLeaderPage(120)

        controller:assertEventually(follower, "Core:isConnected()", true, "the follower never came back")
        controller:assertEventually(follower, "D:getPage()", 121, "the follower came back on the wrong page")
    end)

    T.it("goes back to one page per turn while alone", function()
        connectPair()
        setLeaderPage(70)
        T.assertEquals(controller:number(leader, "Core:getStep()"), 2)

        callFollower("Core:stop('follower left')")
        controller:assertEventually(leader, "Core:isConnected()", false, "the leader did not notice")
        T.assertEquals(controller:number(leader, "Core:getStep()"), 1,
            "with nobody following, a turn should move one page again")

        callLeader("D:tapForward()")
        controller:assertEventually(leader, "D:getPage()", 71)
    end)

    local WARNED = "(function() for _, m in ipairs(UIManager.shown_log) do if tostring(m.text):find('pages here') or tostring(m.text):find('paginates') then return true end end return false end)()"

    T.it("says nothing about a mismatch it is about to fix itself", function()
        -- The follower arrives with a bigger font and so a longer book. With
        -- matching on, that is not worth a word: it is fixed a moment later.
        callFollower("Core:stop('reset')")
        callFollower("Core.settings.match_typography = true")
        callLeader("Core.settings.match_typography = true")
        callFollower("UI:handleEvent(D.Event:new('SetFontSize', 30))")
        callFollower("UIManager.shown_log = {}")
        callFollower("Core.warned_pagination = false")

        connectPair()
        setLeaderPage(60)
        socket.sleep(6) -- well past the settle window
        setLeaderPage(62)
        socket.sleep(1)

        T.assertEquals(callFollower(WARNED), "false", "warned about a mismatch it had already fixed")
        T.assertEquals(controller:number(follower, "UI.document:getPageCount()"),
            controller:number(leader, "UI.document:getPageCount()"),
            "the two devices should agree by now")
    end)

    T.it("stays quiet while a font change is still on its way over", function()
        --[[
        The race a real font change runs into. The leader repaginates the
        instant the size changes, and its new page count reaches the follower
        before Duo has even noticed the change to push it — so for a moment
        the follower holds the old settings and a page count from the new ones.
        It used to complain about that, and then fix it a second later.
        ]]
        callFollower("Core:stop('reset')")
        callFollower("Core.settings.match_typography = true")
        callLeader("Core.settings.match_typography = true")
        connectPair()
        setLeaderPage(40)
        callFollower("UIManager.shown_log = {}")
        callFollower("Core.warned_pagination = false")
        callFollower("Core.typography_applied_at = 0")

        -- The leader's layout changes, and only its page count arrives.
        callLeader("UI:handleEvent(D.Event:new('SetFontSize', 28))")
        callLeader("Core:broadcastState()")
        socket.sleep(1)
        T.assertEquals(callFollower(WARNED), "false",
            "it complained about a difference the font change was about to explain")

        -- And once the change lands, the two agree and still say nothing.
        controller:assertEventually(follower, "UI.document:getPageCount()",
            controller:number(leader, "UI.document:getPageCount()"),
            "the follower never caught up with the new font size", 20)
        T.assertEquals(callFollower(WARNED), "false")
    end)

    T.it("puts itself back on the right page as soon as the layout changes", function()
        -- A font change moves every page number in the book. Until the
        -- leader next broadcasts, a device that only applied the settings
        -- is on the page that number used to mean — so it asks.
        callFollower("Core:stop('reset')")
        callFollower("Core.settings.match_typography = true")
        callLeader("Core.settings.match_typography = true")
        connectPair()
        setLeaderPage(50)
        controller:assertEventually(follower, "D:getPage()", 51)

        callLeader("UI:handleEvent(D.Event:new('SetFontSize', 26))")
        -- No page turn from anyone: only the layout changed.
        controller:assertEventually(follower, "UI.document:getPageCount()",
            controller:number(leader, "UI.document:getPageCount()"),
            "the follower never took the new font size", 20)
        controller:assertEventually(follower, "D:getPage()",
            controller:number(leader, "D:getPage()") + 1,
            "the follower stayed on the page that number used to mean", 20)
    end)

    T.it("warns when matching cannot fix it, because the screens differ", function()
        connectPair()
        -- Same settings on both, but this device still lays the book out
        -- differently: a smaller screen, which no setting can match.
        callFollower("UIManager.shown_log = {}")
        callFollower("Core.warned_pagination = false")
        callFollower("Core.typography_applied_at = 0")
        callFollower("UI.document.page_count = 412")
        -- A length that has been sitting still for a while, which is what
        -- tells a real difference apart from a book still being relaid out.
        callFollower("Core.last_own_pages = 412")
        callFollower("Core.own_pages_changed_at = 0")
        setLeaderPage(80)
        controller:assertEventually(follower, WARNED, true,
            "no warning when the pages genuinely cannot line up", 20)
        T.assertEquals(callFollower(
            "(function() for _, m in ipairs(UIManager.shown_log) do if tostring(m.text):find('the screens themselves') then return true end end return false end)()"),
            "true", "the warning should name the real cause")
        callFollower("UI.document:repaginate()")
    end)

    T.it("still tells you to match them when matching is switched off", function()
        callFollower("Core:stop('reset')")
        callFollower("Core.settings.match_typography = false")
        callLeader("Core.settings.match_typography = false")
        connectPair()
        callFollower("UIManager.shown_log = {}")
        callFollower("Core.warned_pagination = false")
        callFollower("UI.document.page_count = 412")
        setLeaderPage(84)
        controller:assertEventually(follower,
            "(function() for _, m in ipairs(UIManager.shown_log) do if tostring(m.text):find('Match typography') then return true end end return false end)()",
            true, "no warning with matching switched off")
        callFollower("UI.document:repaginate()")
        callFollower("Core.settings.match_typography = true")
        callLeader("Core.settings.match_typography = true")
    end)

    T.it("tells the follower which book to open", function()
        -- A file that really exists, so the follower gets as far as opening it.
        local book = LOG_DIR .. "/duo-test-book.epub"
        local handle = assert(io.open(book, "w"))
        handle:write("not really an epub")
        handle:close()

        connectPair()
        callFollower("Core.settings.follow_document = true")
        callLeader(("UI.document.file = %q"):format(book))
        callLeader("UI.digest = 'digest-other-book'")
        callLeader("Core:broadcastDocument()")

        controller:assertEventually(follower,
            ("(function() for _, m in ipairs(UIManager.shown_log) do if m.class == 'ShowReader' and m.text == %q then return true end end return false end)()"):format(book),
            true, "the follower never opened the leader's book")
        os.remove(book)
    end)

    T.it("opens the leader's book once, not once per message", function()
        local book = LOG_DIR .. "/duo-test-book2.epub"
        local handle = assert(io.open(book, "w"))
        handle:write("not really an epub")
        handle:close()

        connectPair()
        callFollower("Core.settings.follow_document = true")
        callFollower("UIManager.shown_log = {}")
        callLeader(("UI.document.file = %q"):format(book))
        callLeader("UI.digest = 'digest-book-two'")
        -- Two announcements in quick succession, as a reconnect would produce.
        callLeader("Core:broadcastDocument()")
        callLeader("Core:broadcastDocument()")
        socket.sleep(0.6)

        T.assertEquals(controller:call(follower,
            "(function() local n = 0 for _, m in ipairs(UIManager.shown_log) do if m.class == 'ShowReader' then n = n + 1 end end return n end)()"),
            "1", "the follower opened the same book more than once")
        os.remove(book)
    end)

    T.it("stays put when the leader is in the same book by a different path", function()
        connectPair()
        callFollower("Core.settings.follow_document = true")
        callFollower("UIManager.shown_log = {}")
        -- Same content digest, different path: a copy of the same book.
        callLeader("UI.document.file = '/elsewhere/moby-dick.epub'")
        callLeader("Core:broadcastDocument()")
        socket.sleep(0.5)
        T.assertEquals(controller:call(follower,
            "(function() for _, m in ipairs(UIManager.shown_log) do if m.class == 'ShowReader' then return true end end return false end)()"),
            "false", "the follower reopened a book it was already reading")
    end)

    T.it("brings the follower back out to the list when the leader leaves the book", function()
        --[[
        Going into a book was followed; coming back out was not, which left
        the leader in the file list and the follower still sitting in a book —
        two devices doing different things, which is the one thing a spread
        is not. Signalled from the file manager coming up rather than the
        reader going down: switching straight from one book to another
        tears a reader down too, and a follower sent home then would close the
        book it is about to be told to open.
        ]]
        connectPair()
        callFollower("Core.settings.follow_document = true")
        T.assertEquals(callFollower("UI.document ~= nil"), "true", "the follower should start in a book")

        callLeader("D:openFileManager{ path = '/books' }")
        controller:assertEventually(follower, "UI.went_home == true", true,
            "the follower stayed in the book after the leader closed its own")
        callLeader("D:openDocument{ page_count = 300 }")
    end)

    T.it("takes the pair out of the book when the follower reaches the shelf", function()
        --[[
        The report: opening the bookshelf on the follower did not open it on
        the leader, and the follower was forced straight back into the book.

        Coming out was only ever signalled one way. The follower asked the
        leader to resend the current state -- which it needs, to know where
        it belongs in the book list -- and the leader, still sitting in its
        book, answered with the document. So the follower was pulled back
        in by the very message it had asked for, and the shelf could not be
        reached from that end at all.
        ]]
        connectPair()
        callLeader("Core.settings.follow_document = true")
        callFollower("Core.settings.follow_document = true")
        callLeader("UI.went_home = false")

        callFollower("D:openFileManager{ path = '/books' }")
        controller:assertEventually(leader, "UI.went_home == true", true,
            "the leader stayed in the book when the follower left it")
        -- And it has to stay out: being dragged back is the other half of
        -- the complaint, and the leader's state is still in flight.
        socket.sleep(2)
        T.assertEquals(callFollower("UI.document ~= nil"), "false",
            "the follower was forced back into the book")

        callLeader("D:openDocument{ page_count = 300 }")
        callFollower("D:openDocument{ page_count = 300 }")
    end)

    T.it("opens a book for the pair when the tap lands on the follower", function()
        --[[
        A follower may turn pages, so it would be strange if it could not
        start one. It must not simply open the book by itself, though: the
        leader owns the page number, and a follower that wandered off into a
        book on its own would leave the two devices reading different
        things. The tap is forwarded, and the leader's answer brings the
        follower along the same way a tap on the leader would.
        ]]
        local book = LOG_DIR .. "/duo-follower-opened.epub"
        local handle = assert(io.open(book, "w"))
        handle:write("not really an epub")
        handle:close()

        connectPair()
        callLeader("Core.settings.follow_document = true")
        callFollower("Core.settings.follow_document = true")
        callFollower("D:openFileManager{ path = '/books' }")
        callLeader("UIManager.shown_log = {}")

        callFollower(("D:openFile(%q)"):format(book))
        controller:assertEventually(leader,
            ("(function() for _, m in ipairs(UIManager.shown_log) do if m.class == 'ShowReader' and m.text == %q then return true end end return false end)()"):format(book),
            true, "the leader never opened the book the follower was tapped on")
        os.remove(book)
        callFollower("D:openDocument{ page_count = 300 }")
    end)

    T.it("locks the other device when either one is locked", function()
        --[[
        Two readers held side by side are one thing to their owner. Locking
        the one in your right hand and finding the left still lit, still
        burning battery on a page nobody is reading, is not what a spread
        should mean.
        ]]
        connectPair()
        callFollower("UIManager._suspends = 0")
        callLeader("D.plugin:onSuspend()")
        controller:assertEventually(follower, "UIManager._suspends", 1,
            "the follower stayed awake when the leader was locked")

        -- And the other way round, since either device can be the one put
        -- down first. Waking first, as a real device would.
        callLeader("D.plugin:onResume()")
        callFollower("D.plugin:onResume()")
        connectPair()
        callLeader("UIManager._suspends = 0")
        callFollower("D.plugin:onSuspend()")
        controller:assertEventually(leader, "UIManager._suspends", 1,
            "the leader stayed awake when the follower was locked")
    end)

    T.it("does not wake a device that was already going to sleep", function()
        --[[
        The bug two people putting two readers down at once will find
        every time. KOReader sleeps a Kindle by asking its power daemon to
        press the power button, and a press is a toggle: on a device
        already asleep it wakes it up. Both devices announce their own
        sleep, so without a rule the two take turns waking each other.
        ]]
        connectPair()
        callLeader("UIManager._suspends = 0")
        callFollower("UIManager._suspends = 0")

        -- Two thumbs, near enough the same moment.
        callLeader("D.plugin:onSuspend()")
        callFollower("D.plugin:onSuspend()")
        socket.sleep(1)

        T.assertEquals(controller:number(leader, "UIManager._suspends"), 0,
            "the leader was prodded after deciding to sleep on its own")
        T.assertEquals(controller:number(follower, "UIManager._suspends"), 0,
            "the follower was prodded after deciding to sleep on its own")
    end)

    T.it("never presses the button on a device already asleep", function()
        connectPair()
        callFollower("UIManager._suspends = 0")
        -- Asleep, and then told about somebody else's sleep.
        callFollower("D.plugin:onSuspend()")
        callFollower("Core.sleep_announced_at = nil")   -- long enough ago
        callFollower("Core:handleRemoteSleep()")
        socket.sleep(0.3)
        T.assertEquals(controller:number(follower, "UIManager._suspends"), 0,
            "pressing the button on a sleeping device wakes it")
        callFollower("D.plugin:onResume()")
    end)

    T.it("does not send a device that is only obeying back to bed", function()
        -- Both sides suspend each other, so the one following an order must
        -- not pass it on, or the two would take turns saying goodnight.
        connectPair()
        callFollower("UIManager._suspends = 0")
        callLeader("D.plugin:onSuspend()")
        controller:assertEventually(follower, "UIManager._suspends", 1)
        socket.sleep(0.4)
        T.assertEquals(controller:number(follower, "UIManager._suspends"), 1,
            "the follower suspended more than once for one lock")
    end)

    T.it("keeps the connection across a document switch on the follower", function()
        connectPair()
        setLeaderPage(90)
        controller:assertEventually(follower, "D:getPage()", 91)

        -- KOReader destroys and rebuilds the plugin instance here; the
        -- engine, and so the connection, has to outlive it.
        callFollower("D:openDocument{ page_count = 300 }")
        T.assertEquals(callFollower("Core:isConnected()"), "true",
            "the link died when the document changed")

        setLeaderPage(140)
        controller:assertEventually(follower, "D:getPage()", 141,
            "the rebuilt plugin instance is not following any more")
    end)

    T.it("takes the follower to sleep with the leader, and back", function()
        -- The leader is the one somebody is holding, so it is the one
        -- allowed to doze; the follower has nobody to wake it and would
        -- simply stop following.
        connectPair()
        setLeaderPage(30)
        controller:assertEventually(follower, "UIManager._prevent_standby_count", 1,
            "a follower should stay awake while the leader is")
        T.assertEquals(controller:number(leader, "UIManager._prevent_standby_count"), 1,
            "the leader holds while the book is being read")

        -- Nothing happens for long enough that the book is down. The
        -- leader lets go, which is what tells KOReader — and through it
        -- this plugin — that the reader has gone idle.
        callLeader("Core.last_activity = 0")
        controller:assertEventually(leader, "UIManager._prevent_standby_count", 0,
            "the leader should stop holding once nobody is reading", 15)
        callLeader("D.plugin:onAllowStandby()")
        controller:assertEventually(follower, "UIManager._prevent_standby_count", 0,
            "the follower stayed awake after the leader dozed off")

        callLeader("D.plugin:onPreventStandby()")
        controller:assertEventually(follower, "UIManager._prevent_standby_count", 1,
            "the follower did not wake with the leader")
    end)

    T.it("catches up by itself when it wakes", function()
        connectPair()
        setLeaderPage(30)
        controller:assertEventually(follower, "D:getPage()", 31)

        -- Asleep, and missing everything.
        callLeader("Core.last_activity = 0")
        callLeader("D.plugin:onAllowStandby()")
        controller:assertEventually(follower, "UIManager._prevent_standby_count", 0)
        callFollower("UI.paging.current_page = 1")

        -- Waking is the follower's cue to ask where it belongs, since it
        -- has no idea what happened while it was out.
        callFollower("D.plugin:onPreventStandby()")
        controller:assertEventually(follower, "D:getPage()", 31,
            "a woken follower should ask for its place rather than wait")
    end)

    T.it("survives the leader restarting", function()
        connectPair()
        setLeaderPage(100)
        controller:assertEventually(follower, "D:getPage()", 101)

        callLeader("Core:stop('leader restarting')")
        controller:assertEventually(follower, "Core:isConnected()", false)
        callLeader("Core:start('leader')")
        controller:assertEventually(follower, "Core:isConnected()", true, "the follower did not find the leader again")

        setLeaderPage(200)
        controller:assertEventually(follower, "D:getPage()", 201)
    end)
end)

local exit_code = T.run()
controller:shutdown()
os.exit(exit_code)
