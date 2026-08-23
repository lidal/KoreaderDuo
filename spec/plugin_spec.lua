--[[--
The plugin file itself, loaded the way KOReader loads it, driven through a
stub frontend. One simulated device only — the two-device behaviour is in
integration_spec.lua, which runs two real processes.
--]]--

local T = require("spec/testrunner")
local Instance = require("spec/harness/instance")
local Util = require("duo/util")

local device = Instance.new{ name = "Kindle-A", page_count = 300 }
local Core = device.Core

local function reset()
    Core:stop("test reset")
    Core.settings.mode = "spread"
    Core.settings.reverse = false
    Core.settings.follower_can_turn = true
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

T.describe("leader page stepping", function()
    -- The engine is driven directly here: a real follower arrives in the
    -- integration test. What matters is that a turn moves by as many pages
    -- as there are devices.
    local function pretendConnected(follower_count)
        Core.role = Core.ROLE_LEADER
        Core.getReadyLinks = function()
            local links = {}
            for slot = 1, follower_count do
                links[slot] = { slot = slot, send = function() end, isReady = function() return true end }
            end
            return links
        end
    end

    local real_getReadyLinks = Core.getReadyLinks

    T.it("moves two pages per turn with one follower", function()
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

    T.it("moves three pages per turn with two followers", function()
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

T.describe("saying how a transfer is going, and stopping it", function()
    --[[
    A big book over a link between two readers takes minutes. A device that
    says "fetching" once and then goes quiet for six of them is
    indistinguishable from one that has died, and the only way out used to
    be to disconnect: the whole-library sync had a stop button and a single
    book had none.
    ]]

    local real_getReadyLinks = Core.getReadyLinks

    --- A receiver that is `fraction` of the way through and notices an abort.
    local function pretendReceiving(fraction)
        reset()
        local receiver = {
            aborted = false,
            progress = function() return fraction end,
            abort = function(self_) self_.aborted = true end,
        }
        Core.book_receiver = receiver
        Core.book_title = "Middlemarch"
        Core.progress_reported = nil
        device:drainMessages()
        return receiver
    end

    T.it("says how far along a book is", function()
        local receiver = pretendReceiving(0.4)
        Core:reportTransferProgress()
        local said = table.concat(device:drainMessages(), "\n")
        T.assertMatch(said, "Middlemarch")
        T.assertMatch(said, "40%%")
        Core.book_receiver = nil
        receiver.progress = nil
    end)

    T.it("keeps quiet between one tenth and the next", function()
        -- This runs on every pass of the UI loop, twenty times a second,
        -- and every notice costs an e-ink flash.
        pretendReceiving(0.4)
        Core:reportTransferProgress()
        device:drainMessages()
        Core.book_receiver.progress = function() return 0.44 end
        Core:reportTransferProgress()
        T.assertEquals(#device:drainMessages(), 0, "it spoke up again too soon")

        Core.book_receiver.progress = function() return 0.55 end
        Core:reportTransferProgress()
        T.assertMatch(table.concat(device:drainMessages(), "\n"), "55%%")
        Core.book_receiver = nil
    end)

    T.it("says nothing at all at the very start", function()
        -- The notice that the book is coming has just been shown; "0%"
        -- underneath it says nothing new.
        pretendReceiving(0)
        Core:reportTransferProgress()
        T.assertEquals(#device:drainMessages(), 0)
        Core.book_receiver = nil
    end)

    T.it("stops a book being fetched, and tells the other device", function()
        local receiver = pretendReceiving(0.4)
        local sent = {}
        Core.getReadyLinks = function()
            return { { send = function(_, kind) sent[#sent+1] = kind end,
                       isReady = function() return true end } }
        end
        Core.book_request = { title = "Middlemarch", started = 0 }

        T.assertTrue(Core:cancelTransfer("stopped by hand"), "nothing was stopped")
        T.assertTrue(receiver.aborted, "the part-file was left behind")
        T.assertNil(Core.book_receiver)
        T.assertNil(Core.book_request)
        T.assertTrue(sent[1] ~= nil, "the other device was never told")
        T.assertTrue(not Core:isTransferring(), "it still thinks something is going on")
        Core.getReadyLinks = real_getReadyLinks
    end)

    T.it("stops a whole library sync too", function()
        reset()
        Core.library = { wanted = {}, total = 3, done = 1, path = "/books" }
        T.assertTrue(Core:isTransferring())
        T.assertTrue(Core:cancelTransfer("stopped by hand"))
        T.assertNil(Core.library)
    end)

    T.it("has nothing to stop when nothing is moving", function()
        reset()
        T.assertTrue(not Core:isTransferring())
        T.assertTrue(not Core:cancelTransfer("stopped by hand"))
    end)
end)

T.describe("what a library sync will and will not copy", function()
    local function pretendBrowsing(path)
        reset()
        Core.browser = {
            getFiles = function() return {} end,
            getState = function() return { path = path, page = 1, pages = 1, count = 0 } end,
            refresh = function() return true end,
        }
        Core.library = { collecting = true, index = {}, path = path }
        device:drainMessages()
    end

    T.it("asks before copying anything, and says how much there is", function()
        --[[
        Copying used to start here, on its own, while somebody read -- and a
        book crossing the link takes the same poll loop that turns pages, so
        every turn queued behind it. Between two real readers that was fifty
        milliseconds a turn when the link was quiet and over a second while a
        book was copying.

        So the difference is now something to be told about rather than
        something to start doing.
        ]]
        pretendBrowsing("/downloads")
        local asked_about
        Core.hooks.shelvesDiffer = function(count, bytes)
            asked_about = { count = count, bytes = bytes }
        end
        Core:handleLibraryItem{ name = "enormous.epub", size = 400 * 1024 * 1024 }
        Core:handleLibraryEnd{}

        T.assertTrue(asked_about ~= nil, "it started copying without asking")
        T.assertEquals(asked_about.count, 1)
        T.assertTrue(asked_about.bytes > 300 * 1024 * 1024)
        T.assertNil(Core.library, "nothing should be copying until somebody says so")
        T.assertTrue(Core:isShelfGated(), "the pair should be waiting on an answer")

        -- And when they say yes, it goes ahead.
        T.assertTrue(Core:startShelfSync())
        T.assertMatch(table.concat(device:drainMessages(), "\n"), "fetching 1 book")

        Core.hooks.shelvesDiffer = nil
        Core:setShelfGate(nil)
        Core.library = nil
        Core.browser = nil
    end)

    T.it("lets the reader take the books across themselves instead", function()
        -- Carrying a big shelf over by USB is often the better idea, and
        -- always the quicker one. Saying so disconnects rather than nags.
        pretendBrowsing("/downloads")
        Core.hooks.shelvesDiffer = function() end
        Core:handleLibraryItem{ name = "enormous.epub", size = 400 * 1024 * 1024 }
        Core:handleLibraryEnd{}
        T.assertTrue(Core:isShelfGated())

        T.assertTrue(Core:abandonShelfSync())
        T.assertNil(Core.library, "it copied anyway")
        T.assertTrue(not Core:isShelfGated(), "the pair should not still be waiting")
        T.assertTrue(not Core:isActive(), "saying no should disconnect")

        Core.hooks.shelvesDiffer = nil
        Core.browser = nil
    end)

    T.it("holds page turns while the shelves are being settled", function()
        -- A pair still working out which books it has is not a pair that
        -- should be reading, and one screen wandering off while the other
        -- waits is how they end up in different places.
        reset()
        local sent = {}
        Core.links = { {
            slot = 1,
            isReady = function() return true end,
            isClosed = function() return false end,
            poll = function() end,
            send = function(_self, msg_type) sent[#sent+1] = msg_type return true end,
        } }
        Core.role = Core.ROLE_FOLLOWER

        Core.shelf_gate = "waiting"
        T.assertTrue(Core:handleRelativeTurn(1),
            "a turn should be swallowed rather than passed on while waiting")
        T.assertEquals(#sent, 0, "the turn was forwarded while the pair was still waiting")

        -- And once the shelves are settled it goes through as before.
        Core.shelf_gate = nil
        T.assertTrue(Core:handleRelativeTurn(1))
        T.assertEquals(#sent, 1, "a turn should be forwarded once there is nothing in the way")

        Core.links = {}
        Core.role = Core.ROLE_OFF
    end)

    T.it("says nothing about the size when there is little to copy", function()
        pretendBrowsing("/books")
        Core:handleLibraryItem{ name = "small.epub", size = 200 * 1024 }
        Core:handleLibraryEnd{}
        T.assertTrue(not table.concat(device:drainMessages(), "\n"):find("take a long time"),
            "a small shelf should not come with a warning about a long wait")
        Core.library = nil
        Core.browser = nil
    end)

    T.it("stops asking for a book that would not come", function()
        --[[
        A failure leaves the folder still not matching, so the next look
        wants the same book, asks for it, fails the same way and finishes
        still not matching -- a device fetching nothing, over and over.
        ]]
        pretendBrowsing("/books")
        -- The reader is asked first now; this scenario is about what happens
        -- after they have said yes.
        Core.hooks.shelvesDiffer = function() Core:startShelfSync() end
        Core:handleLibraryItem{ name = "broken.epub", size = 1024 }
        Core:handleLibraryEnd{}
        T.assertMatch(table.concat(device:drainMessages(), "\n"), "fetching 1 book")

        -- The book is asked for and refused, which is where the loop used
        -- to start: the folder still does not match, so the next look wants
        -- the same book again.
        Core.book_request = { title = "broken.epub", library = true, started = 0 }
        Core:handleBookError{ reason = "no" }
        T.assertTrue(Core.library_failed ~= nil and Core.library_failed["broken.epub"] ~= nil,
            "the failure should be remembered")

        -- The same folder looked at again, without a restart in between:
        -- this is the loop, and it is where it used to go round.
        Core.library = { collecting = true, index = {}, path = "/books" }
        Core:handleLibraryItem{ name = "broken.epub", size = 1024 }
        Core:handleLibraryEnd{}
        T.assertTrue(not table.concat(device:drainMessages(), "\n"):find("fetching 1 book"),
            "it asked for the same book all over again")

        -- Stopping is a fair reason to try again, though: this is a note
        -- about one session, not a verdict on the book.
        Core:stop("test")
        T.assertNil(Core.library_failed, "a fresh start should forget it")

        Core.library = nil
        Core.browser = nil
    end)

    T.it("drops anything that is not a book out of the other device's list", function()
        -- Filtered at the sending end too, but what arrives over a socket
        -- is not something to take on trust.
        pretendBrowsing("/books")
        Core:handleLibraryItem{ name = "update.bin", size = 100 }
        Core:handleLibraryItem{ name = "photo.jpg", size = 100 }
        Core:handleLibraryItem{ name = "real.epub", size = 100 }
        T.assertEquals(#Core.library.index, 1, "only the book belongs on the list")
        T.assertEquals(Core.library.index[1].name, "real.epub")
        Core.library = nil
        Core.browser = nil
    end)
end)

T.describe("coming back after a sleep", function()
    --[[
    A device wakes before its network does. This used to be one attempt
    whose failure was final — the leader's listen failed on an interface
    with no address yet, an alert went up, and Duo stayed off until
    somebody reconnected both devices by hand. A short lock worked because
    the network never went away; a long one did not.
    ]]
    local real_start = Core.start

    local function failingStart(fail_times)
        local attempts = 0
        Core.start = function(_self, _role, _options)
            attempts = attempts + 1
            return attempts > fail_times
        end
        return function() return attempts end
    end

    local function sleepAsLeader()
        reset()
        Core.role = Core.ROLE_LEADER
        Core:suspend()
        T.assertEquals(Core.paused_role, "leader", "the role has to survive the sleep")
    end

    T.it("keeps trying until the network is really back", function()
        sleepAsLeader()
        local attempts = failingStart(2)

        Core:resume()
        T.assertEquals(attempts(), 1)
        T.assertEquals(Core.paused_role, "leader", "one failure must not be the end of it")

        Core.resume_at = 0
        Core:poll()
        T.assertEquals(attempts(), 2)

        Core.resume_at = 0
        Core:poll()
        T.assertEquals(attempts(), 3, "it should have tried again")
        T.assertNil(Core.paused_role, "and stopped trying once it worked")
        Core.start = real_start
    end)

    T.it("checks a link it made itself on both devices, not only where a start failed", function()
        --[[
        The bug this exists for. A link with no router behind it does not
        survive a deep sleep, and the rebuild used to hang off a failed
        start — which happens on a follower and never on a leader, because
        starting a leader binds a listening socket and binding every
        interface succeeds fine when there is no network on any of them. So
        the leader came up believing itself well, and the follower
        reconnected into silence.
        ]]
        reset()
        Core.settings.direct_link = "host"
        local checked = 0
        Core.hooks.reviveDirectLink = function() checked = checked + 1 end

        -- Nothing paused, nothing failed: exactly the leader's situation.
        Core.paused_role = nil
        Core:resume()
        T.assertEquals(checked, 0, "not the instant the screen lights up")

        Core.link_check_at = 0
        Core:poll()
        T.assertEquals(checked, 1, "the link was never checked")

        Core:poll()
        T.assertEquals(checked, 1, "and checking it is a one-off, not a loop")

        Core.hooks.reviveDirectLink = nil
        Core.settings.direct_link = nil
    end)

    T.it("dials again the moment the network is back, not after the backoff", function()
        --[[
        The backoff had grown while the link was broken, and it was about a
        network that no longer exists. Waiting it out after fixing the very
        thing it was backing off from added several seconds to every
        recovery, on top of the wait to notice and the wait to rebuild.
        ]]
        reset()
        Core.settings.direct_link = "join"
        Core.settings.peer_host = "169.254.13.1"
        Core.hooks.reviveDirectLink = function() return "rebuilt" end
        Core.role = Core.ROLE_FOLLOWER
        Core.reconnect_delay = 4
        Core.reconnect_at = Util.now() + 4

        Core.disconnected_since = 0
        Core.has_connected = true
        Core:poll()

        T.assertEquals(Core.reconnect_delay, 1, "the backoff was about the old network")
        T.assertTrue(Core.reconnect_at <= Util.now(), "and there is no reason to wait")

        Core.hooks.reviveDirectLink = nil
        Core.settings.direct_link = nil
        Core.settings.peer_host = ""
        Core.role = Core.ROLE_OFF
        Core.disconnected_since, Core.link_healed_at, Core.has_connected = nil, nil, nil
    end)

    T.it("is patient with a pair that has never managed to connect", function()
        -- Somebody reading a code off one screen and typing it into the
        -- other does not need the network pulled out from under them.
        reset()
        Core.settings.direct_link = "join"
        local rebuilt = 0
        Core.hooks.reviveDirectLink = function() rebuilt = rebuilt + 1 return "rebuilt" end
        Core.role = Core.ROLE_FOLLOWER
        Core.has_connected = nil
        Core.disconnected_since = Util.now() - 5   -- broken, but never worked
        Core:poll()
        T.assertEquals(rebuilt, 0, "five seconds into a first pairing is not a fault")

        Core.disconnected_since = 0                -- now it really has been a while
        Core:poll()
        T.assertEquals(rebuilt, 1)

        Core.hooks.reviveDirectLink = nil
        Core.settings.direct_link = nil
        Core.role = Core.ROLE_OFF
        Core.disconnected_since, Core.link_healed_at = nil, nil
    end)

    T.it("checks the link again simply because the pair has been apart", function()
        --[[
        The check that does not wait to be told. A wake-up notification
        travels through the reader's power daemon, its screensaver handling
        and an event broadcast, and if any of that does not fire on a
        particular firmware then nothing ever looks at the network again.
        Being disconnected for a while is its own reason to look.
        ]]
        reset()
        Core.settings.direct_link = "join"
        local checked = 0
        Core.hooks.reviveDirectLink = function() checked = checked + 1 end
        Core.role = Core.ROLE_FOLLOWER          -- active, and not connected

        Core:poll()
        T.assertEquals(checked, 0, "not the instant the link drops")

        Core.disconnected_since = 0             -- apart for a good while
        Core:poll()
        T.assertEquals(checked, 1, "the link was never looked at")

        Core:poll()
        T.assertEquals(checked, 1, "and not on every turn of the loop after that")

        Core.hooks.reviveDirectLink = nil
        Core.settings.direct_link = nil
        Core.role = Core.ROLE_OFF
        Core.disconnected_since = nil
        Core.link_healed_at = nil
    end)

    T.it("lets go when Wi-Fi is handed back, and stays let go", function()
        --[[
        The link rebuilding itself moments after being dismantled. Nothing
        recorded did not mean "there is no direct link", it meant "work it
        out" — and what it worked it out from was the peer address, which
        handing Wi-Fi back left behind. So the answer came back "join", the
        healing rebuilt the cell, and the Wi-Fi that had just been restored
        was taken away again.
        ]]
        reset()
        Core.settings.direct_link = "join"
        Core.settings.peer_host = "169.254.13.1"

        -- Handing Wi-Fi back reconfigures the machine's network for real,
        -- and the suite is not entitled to do that to whoever is running
        -- it. What is under test is what Duo forgets afterwards, so the
        -- script is stood in for.
        local DirectLink = require("duo/directlink")
        local ran_script = DirectLink.run
        DirectLink.run = function() return "" end
        device.plugin:restoreWifi()
        DirectLink.run = ran_script

        T.assertEquals(Core:get("direct_link"), "off", "silence is not an answer")
        T.assertNil(device.plugin:directLinkRole(),
            "it must not work the link out again from what it just dismantled")
        T.assertEquals(Core:get("peer_host"), "",
            "the other device is not at that address any more")
    end)

    T.it("stays let go when the pair is told to use an ordinary network", function()
        reset()
        Core.settings.direct_link = "host"
        Core.settings.peer_host = ""
        device.plugin:notOnADirectLink()
        T.assertNil(device.plugin:directLinkRole(),
            "choosing a Wi-Fi network is as plain a statement of intent as there is")
    end)

    T.it("but keeps a hand-built link that is being paired across by address", function()
        -- Still a direct link, whatever route was taken to it.
        reset()
        Core.settings.direct_link = nil
        Core.settings.peer_host = "169.254.13.1"
        device.plugin:notOnADirectLink()
        T.assertEquals(device.plugin:directLinkRole(), "join")
        Core.settings.peer_host = ""
    end)

    T.it("works out which side of a link built by hand this device is", function()
        --[[
        The script is meant to be run over SSH, and a link built that way
        left nothing behind saying so — so every automatic check decided
        the link was none of its business and did nothing at all, which is
        exactly what "it never reconnects" looked like. The addresses give
        it away; nothing else uses them.
        ]]
        reset()
        Core.settings.direct_link = nil
        Core.settings.peer_host = "169.254.13.1"
        T.assertEquals(device.plugin:directLinkRole(), "join")
        T.assertEquals(Core:get("direct_link"), "join", "and it is remembered")

        -- An ordinary network is somebody else's business.
        reset()
        Core.settings.direct_link = nil
        Core.settings.peer_host = "192.168.1.44"
        T.assertNil(device.plugin:directLinkRole(),
            "taking over a network Duo did not build would be rude")
        Core.settings.peer_host = ""
    end)

    T.it("gives up in the end, and says so", function()
        sleepAsLeader()
        failingStart(99)
        Core:resume()
        for _ = 1, 40 do
            Core.resume_at = 0
            Core:poll()
        end
        T.assertNil(Core.paused_role, "retrying into a flat battery helps nobody")
        T.assertMatch(table.concat(device:drainMessages(), "\n"), "could not start again")
        Core.start = real_start
    end)

    T.it("does not come back after being switched off on purpose", function()
        sleepAsLeader()
        Core:stop("switched off by hand")
        T.assertNil(Core.paused_role)
        local attempts = failingStart(0)
        Core.resume_at = 0
        Core:poll()
        T.assertEquals(attempts(), 0, "a deliberate stop outranks an unfinished sleep")
        Core.start = real_start
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
        T.assertTrue(unit.Core:start("leader"))
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
        unit.Core.role = unit.Core.ROLE_FOLLOWER
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
        T.assertTrue(unit.Core:start("leader"))
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
        T.assertTrue(unit.Core:start("leader"))
        unit.Core:stop("done")
        unit.Core:stop("done again")
        unit.Core:updateAwake()
        T.assertEquals(unit.UIManager._prevent_standby_count, 0)
    end)
end)

T.describe("pairing dialogs", function()
    T.it("asks how the two should reach each other, before who is who", function()
        --[[
        Two questions, in that order. The screen used to ask both at once
        and in the wrong one: two roles plus a third button that was really
        a different kind of link and then asked for the role again. Which
        page a device holds has nothing to do with whether there is a router
        in the room.
        ]]
        reset()
        device.plugin:showConnectDialog()
        local shown = table.concat(device:drainMessages(), "\n")
        T.assertMatch(shown, "reach each other")
        T.assertTrue(not shown:find("left page"),
            "the role question does not belong on the first screen")
    end)

    T.it("then asks which device this is, the same way for either link", function()
        reset()
        device.plugin:showRoleDialog("network")
        local shown = table.concat(device:drainMessages(), "\n")
        T.assertMatch(shown, "Which one is this")
        T.assertMatch(shown, "leads")
        T.assertMatch(shown, "follows")
        T.assertMatch(shown, "Back", "a two-step choice has to be reversible")
    end)

    T.it("shows the code and address after starting as leader", function()
        reset()
        Core.settings.token = "K7F2QX"
        -- Not the default port: a real KOReader running Duo on this machine
        -- would already hold 9970, and this test would fail for a reason
        -- that has nothing to do with the pairing sheet.
        Core.settings.port = 19899
        device.plugin:startLeader()
        local shown = table.concat(device:drainMessages(), "\n")
        T.assertMatch(shown, "K7F2QX")
        T.assertMatch(shown, "19899")
        T.assertTrue(Core:isLeader())
        Core:stop("test done")
        Core.settings.port = 9970
    end)

    T.it("names the network to join when it is hosting the link itself", function()
        --[[
        The ordinary sheet says "tap Connect to a leader" and that is
        enough, because both devices are already on the same network. When
        this device *is* the network, anything that is not another reader
        running Duo has to be told what to join — and being told to search a
        network you are not on is no help at all.
        ]]
        reset()
        Core.settings.token = "DIRECT1"
        Core.settings.port = 19898
        device.plugin:showPairingSheet{
            direct = true,
            report = { ssid = "KOReaderDuo", passphrase = "koreaderduo" },
        }
        local shown = table.concat(device:drainMessages(), "\n")
        T.assertMatch(shown, "KOReaderDuo", "the network has to be named")
        T.assertMatch(shown, "koreaderduo", "and so does the passphrase")
        T.assertMatch(shown, "This device follows", "another reader does it from the menu")
        T.assertMatch(shown, "DIRECT1")

        -- The ordinary sheet says none of that, because it does not apply.
        device.plugin:showPairingSheet()
        local plain = table.concat(device:drainMessages(), "\n")
        T.assertTrue(not plain:find("Passphrase"),
            "on a network both devices are already on there is nothing to join")
        Core.settings.port = 9970
    end)

    T.it("does not send people scanning for an ad-hoc cell they cannot see", function()
        --[[
        A reader whose driver will not do access point mode falls back to an
        ad-hoc cell. Two readers still pair over it, but no phone will show
        it in a list of networks. Telling somebody to "join this Wi-Fi
        network" then is worse than saying nothing: they go looking for a
        name that is never going to appear and conclude the link is broken.
        ]]
        reset()
        Core.settings.token = "ADHOC1"
        device.plugin:showPairingSheet{
            direct = true,
            mode = "ibss",
            report = { ssid = "KOReaderDuo", passphrase = "koreaderduo" },
        }
        local shown = table.concat(device:drainMessages(), "\n")
        T.assertMatch(shown, "ad%-hoc cell")
        T.assertMatch(shown, "will not list it at all")
        T.assertMatch(shown, "This device follows", "another reader can still join it")
        T.assertTrue(not shown:find("join this Wi%-Fi network"),
            "nobody should be sent looking for a network their device will not show")
    end)

    T.it("reads back which kind of link came up", function()
        local DirectLink = require("duo/directlink")
        T.assertEquals(DirectLink.modeOf("verified: wlan0 is AP\nmode=AP\nhosting"), "ap")
        T.assertEquals(DirectLink.modeOf("mode=IBSS\n"), "ibss")
        T.assertEquals(DirectLink.modeOf("mode=Ad-Hoc\n"), "ibss")
        T.assertNil(DirectLink.modeOf("nothing to say here"))
        T.assertNil(DirectLink.modeOf(nil))
    end)

    T.it("refuses an address that is not one", function()
        reset()
        local before = Core:get("peer_host")
        device.plugin:connectTo("not-an-address", 9970, false)
        T.assertEquals(Core:get("peer_host"), before, "a bad address must not be stored")
        T.assertTrue(not Core:isActive())
    end)
end)

T.describe("the status screen", function()
    --[[
    The report: tapping the status entry crashed KOReader.

    This screen is where somebody goes when something is already wrong, and
    that is exactly the state in which the things it asks about answer
    strangely -- a peer half gone away, an address that cannot be read, an
    error that is not a string. Whatever the line was, a screen that can
    take the reader down with it is worse than no screen.
    ]]
    local function shown()
        local log = device.UIManager.shown_log
        return tostring(log[#log] and log[#log].text or "")
    end

    T.it("says what Duo is doing", function()
        reset()
        device.plugin:showStatus()
        T.assertMatch(shown(), "Off")
    end)

    T.it("survives a peer that answers strangely", function()
        reset()
        Core.settings.port = 19891
        T.assertTrue(Core:start("leader"))
        -- A link that has come apart in the middle of being asked about.
        Core.links[#Core.links+1] = {
            isReady = function() return true end,
            isClosed = function() return false end,
            latency = "not a number",
            describe = function() error("the peer went away mid-sentence") end,
            poll = function() end,
            slot = 1,
        }
        local ok = pcall(function() device.plugin:showStatus() end)
        T.assertTrue(ok, "the status screen took the reader down with it")
        T.assertMatch(shown(), "could not be read")
        Core.links = {}
        Core:stop("done")
    end)

    T.it("survives an error that is not a string", function()
        reset()
        Core.last_error = { it = "was a table" }
        local ok = pcall(function() device.plugin:showStatus() end)
        T.assertTrue(ok, "a last error that was not text crashed the screen")
        Core.last_error = nil
    end)

    T.it("still shows the lines it could build", function()
        -- One bad line must not cost the reader the rest of the screen.
        reset()
        Core.last_error = setmetatable({}, { __tostring = function()
            error("even saying what this is fails")
        end })
        local ok = pcall(function() device.plugin:showStatus() end)
        T.assertTrue(ok)
        T.assertMatch(shown(), "Off", "the good lines went missing with the bad one")
        Core.last_error = nil
    end)

    T.it("points at the log when there is one", function()
        reset()
        Core:set("debug_log", true)
        device.plugin:showStatus()
        T.assertMatch(shown(), "duo%.log")
        Core:set("debug_log", false)
    end)
end)

T.describe("the log the reader can send on", function()
    --[[
    Everything Duo had to say went to KOReader's debug logger, which writes
    nothing unless the whole reader was started in debug mode. So a reader
    who wanted to report that their two devices had disagreed about
    something had nothing to send.

    Driven through the plugin's own writer rather than through `Core:log`.
    Core is a single engine and its hooks belong to whichever plugin last
    started up, and this file builds more than one device -- so going in by
    the front door here would be testing which of them answered, not what
    was written. The one line in between is `Core:configure`'s log hook; the
    file it writes to is what the rest of this checks.
    ]]
    local function logPath() return device.plugin:getLogPath() end

    local function sizeNow()
        local handle = io.open(logPath(), "rb")
        if not handle then return 0 end
        local size = handle:seek("end") or 0
        handle:close()
        return size
    end

    local function since(mark)
        local handle = io.open(logPath(), "rb")
        if not handle then return "" end
        handle:seek("set", mark)
        local text = handle:read("*a") or ""
        handle:close()
        return text
    end

    T.it("writes nothing at all until it is asked to", function()
        reset()
        Core:set("debug_log", false)
        local mark = sizeNow()
        device.plugin:writeLog("something worth knowing")
        T.assertEquals(since(mark), "",
            "a log was written by a device nobody asked")
    end)

    T.it("records what Duo does once it is switched on", function()
        reset()
        Core:set("debug_log", true)
        local mark = sizeNow()
        device.plugin:writeLog("the link came up")
        T.assertMatch(since(mark), "the link came up")
        Core:set("debug_log", false)
    end)

    T.it("stamps every line with the time and what this device was being", function()
        reset()
        Core:set("debug_log", true)
        local mark = sizeNow()
        device.plugin:writeLog("the link came up")
        T.assertMatch(since(mark), "%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d %[")
        Core:set("debug_log", false)
    end)

    T.it("opens with what device this is, which no report ever includes", function()
        -- The first question anybody asks about a log is what wrote it.
        local line = device.plugin:describeEnvironment()
        T.assertMatch(line, "device=")
        T.assertMatch(line, "koreader=")
        T.assertMatch(line, "role=")
    end)

    T.it("stops writing when it is switched off again", function()
        reset()
        Core:set("debug_log", true)
        device.plugin:writeLog("while it was on")
        Core:set("debug_log", false)
        local mark = sizeNow()
        device.plugin:writeLog("after it was switched off")
        T.assertEquals(since(mark), "",
            "the log went on being written after it was switched off")
    end)

    T.it("goes where a USB cable can reach it", function()
        -- Beside KOReader's own crash.log, in the data folder, which is
        -- where somebody already knows to look. Checked by shape rather
        -- than against `datastorage` itself: this file builds more than one
        -- device and they do not share a data folder.
        T.assertMatch(logPath(), "^/.+/duo%.log$")
        T.assertTrue(not logPath():find("/cache/"),
            "a log in the cache is a log that gets swept away")
    end)

    T.it("is this device's business and not the pair's", function()
        -- Switching a log on here must not quietly switch one on over there:
        -- a log is about one device, and the other device's card is not this
        -- one's to start filling.
        reset()
        local sent = {}
        Core.links = { {
            slot = 1,
            isReady = function() return true end,
            isClosed = function() return false end,
            poll = function() end,
            send = function(_self, msg_type, fields)
                sent[#sent+1] = { type = msg_type, fields = fields or {} }
                return true
            end,
        } }
        Core:set("debug_log", true)
        for _, message in ipairs(sent) do
            T.assertNil(message.fields.debug_log,
                "switching on a log here offered to switch one on over there")
        end
        Core:set("debug_log", false)
        Core.links = {}
    end)
end)

T.describe("stopping a copy stops it at both ends", function()
    --[[
    Found by watching two real readers: a device fetching a whole library
    aborted its own half and told the other end nothing, so the other end
    went on sending. For a thirty megabyte book that is minutes of pushing
    at somebody who has stopped listening.

    Only two of the four ways to stop ever spoke up, and the one a reader
    actually reaches -- stopping while books are being fetched -- was not
    among them.
    ]]
    local Protocol = require("duo/protocol")

    --- A link that writes down what it was asked to send.
    local function recordingLink(sent)
        return {
            slot = 1,
            isReady = function() return true end,
            isClosed = function() return false end,
            poll = function() end,
            send = function(_self, msg_type)
                sent[#sent+1] = msg_type
                return true
            end,
        }
    end

    local function countOf(sent, wanted)
        local count = 0
        for _, msg_type in ipairs(sent) do
            if msg_type == wanted then count = count + 1 end
        end
        return count
    end

    T.it("tells the other device when a fetch is stopped", function()
        reset()
        local sent = {}
        Core.links = { recordingLink(sent) }
        Core.book_receiver = { abort = function() end }
        Core.library = { path = "/books", index = {}, total = 1, done = 0 }

        T.assertTrue(Core:cancelTransfer("stopped by hand"))
        T.assertEquals(countOf(sent, Protocol.BOOK_ERR), 1,
            "the other device was left sending a book nobody was taking")
        Core.links = {}
    end)

    T.it("says it once, however many things it stopped", function()
        reset()
        local sent = {}
        Core.links = { recordingLink(sent) }
        Core.book_receiver = { abort = function() end }
        Core.book_request = { name = "book.epub" }
        Core.library = { path = "/books", index = {}, total = 1, done = 0 }

        Core:cancelTransfer("stopped by hand")
        T.assertEquals(countOf(sent, Protocol.BOOK_ERR), 1,
            "the other device was told more than once")
        Core.links = {}
    end)

    T.it("stops sending when the other device gives up", function()
        -- The other half of the same conversation: this message travels both
        -- ways, and so does giving up.
        reset()
        local closed = false
        Core.book_sender = {
            sender = { close = function() closed = true end, size = 10 },
            link = { send = function() return true end, isClosed = function() return false end },
            name = "book.epub",
        }
        Core:handleBookError({ type = Protocol.BOOK_ERR, reason = "stopped on the other device" })
        T.assertNil(Core.book_sender, "it went on sending at somebody who had stopped listening")
        T.assertTrue(closed, "the file was left open")
    end)
end)

T.describe("sending a book without freezing the reader", function()
    --[[
    The report: a device locked up while a big book was copying, and the way
    out of the transfer could not be reached.

    The pump sent chunks until the link was backed up. The high-water mark it
    watched counts bytes still waiting for the socket, and on a link that
    keeps up that is nearly always zero -- so the loop ran until the book ran
    out, inside one turn of the poll loop, with no repaint and no chance to
    touch anything. The bigger the book, the longer the freeze, which is
    exactly when somebody reaches for the stop button.
    ]]
    local BookTransfer = require("duo/booktransfer")
    local BIG = "/tmp/duo-pump-spec.epub"

    local function bigBook()
        local handle = assert(io.open(BIG, "wb"))
        -- Comfortably more chunks than one turn of the loop may send.
        handle:write(string.rep("x", BookTransfer.CHUNK * BookTransfer.CHUNKS_PER_POLL * 4))
        handle:close()
        return BIG
    end

    --- A link that always keeps up, which is the case that used to run away.
    local function eagerLink()
        return {
            sent = {},
            isClosed = function() return false end,
            pending = function() return 0 end,
            send = function(self_, msg_type, fields)
                self_.sent[#self_.sent+1] = { type = msg_type, fields = fields }
                return true
            end,
        }
    end

    local function countData(link)
        local Protocol = require("duo/protocol")
        local count = 0
        for _, message in ipairs(link.sent) do
            if message.type == Protocol.BOOK_DATA then count = count + 1 end
        end
        return count
    end

    T.it("gives the reader its turn back instead of sending the whole book", function()
        reset()
        local sender = assert(BookTransfer.newSender(bigBook()))
        local link = eagerLink()
        Core.book_sender = { sender = sender, link = link, name = "big.epub" }

        Core:pumpBookSender()
        T.assertEquals(countData(link), BookTransfer.CHUNKS_PER_POLL,
            "one turn of the poll loop sent more of the book than it may")
        T.assertTrue(Core.book_sender ~= nil, "the transfer should still be going")

        Core:pumpBookSender()
        T.assertEquals(countData(link), BookTransfer.CHUNKS_PER_POLL * 2,
            "the next turn should carry on where the last one stopped")

        Core:cancelTransfer("stopped by hand")
        T.assertNil(Core.book_sender, "the transfer would not stop")
    end)

    T.it("still stops early when the link is the thing holding it up", function()
        -- The ceiling is a floor for responsiveness, not a replacement for
        -- flow control: a backed-up link still stops the pump at once.
        reset()
        local sender = assert(BookTransfer.newSender(bigBook()))
        local link = eagerLink()
        link.pending = function() return BookTransfer.HIGH_WATER + 1 end
        Core.book_sender = { sender = sender, link = link, name = "big.epub" }

        Core:pumpBookSender()
        T.assertEquals(countData(link), 0, "a backed-up link was written to anyway")
        Core:cancelTransfer("stopped by hand")
    end)

    T.it("finishes a book that fits inside one turn", function()
        reset()
        local small = "/tmp/duo-pump-small.epub"
        local handle = assert(io.open(small, "wb"))
        handle:write(string.rep("y", BookTransfer.CHUNK * 2))
        handle:close()
        local sender = assert(BookTransfer.newSender(small))
        local link = eagerLink()
        Core.book_sender = { sender = sender, link = link, name = "small.epub" }

        Core:pumpBookSender()
        T.assertNil(Core.book_sender, "a short book should be done in one turn")
        local Protocol = require("duo/protocol")
        T.assertEquals(link.sent[#link.sent].type, Protocol.BOOK_DONE)
        os.remove(small)
    end)
end)

T.describe("finding a book this device already has", function()
    --[[
    The report: a big book copied onto both Kindles by hand was not
    recognised, so opening it on the follower set off a transfer of a file
    that was already sitting on the disk.

    Only the read history was searched, and a book copied across by hand has
    never been opened, so it is in no history. The shelf itself is searched
    now.
    ]]
    local SHELF = "/tmp/duo-shelf-spec"

    local function put(path, contents)
        os.execute(("mkdir -p %q"):format(path:gsub("/[^/]*$", "")))
        local handle = assert(io.open(path, "w"))
        handle:write(contents or "a book")
        handle:close()
        return path
    end

    local function shelf()
        reset()
        os.execute(("rm -rf %q"):format(SHELF))
        os.execute(("mkdir -p %q"):format(SHELF))
        Core.settings.book_dir = SHELF
    end

    T.it("finds a book sitting on the shelf under another name for the folder", function()
        shelf()
        local here = put(SHELF .. "/Fiction/big.epub")
        T.assertEquals(device.plugin:findLocalCopy("/mnt/us/documents/big.epub"), here,
            "a book already on the shelf was going to be sent across again")
    end)

    T.it("says so when the book really is not here", function()
        shelf()
        put(SHELF .. "/Fiction/something-else.epub")
        T.assertNil(device.plugin:findLocalCopy("/mnt/us/documents/big.epub"))
    end)

    T.it("does not offer a stand-in as the book", function()
        shelf()
        local stub = put(SHELF .. "/big.epub")
        Core:rememberStub(stub, true)
        T.assertNil(device.plugin:findLocalCopy("/mnt/us/documents/big.epub"),
            "a stand-in was offered as the book it stands in for")
        Core:rememberStub(stub, false)
    end)

    T.it("picks the copy the other device meant when there are several", function()
        shelf()
        put(SHELF .. "/Fiction/big.epub", "one edition")
        local wanted = put(SHELF .. "/Reference/big.epub", "quite another")
        local digest = device.plugin:partialDigest(wanted)
        T.assertEquals(device.plugin:findLocalCopy("/mnt/us/documents/big.epub",
            { digest = digest }), wanted)
    end)

    T.it("still answers when the digest matches nothing here", function()
        -- A name is the answer that avoids sending a whole book across, and
        -- that is what this is for. The digest breaks ties; it is not a bar.
        shelf()
        local here = put(SHELF .. "/big.epub")
        T.assertEquals(device.plugin:findLocalCopy("/mnt/us/documents/big.epub",
            { digest = "not a digest of anything here" }), here)
    end)

    T.it("does not walk the whole card looking", function()
        -- Deep enough for a shelf, bounded enough that a tap never stalls.
        shelf()
        local deep = SHELF .. "/a/b/c/d/e/f/g"
        put(deep .. "/big.epub")
        T.assertNil(device.plugin:findLocalCopy("/mnt/us/documents/big.epub"))
    end)
end)

T.describe("a page number and the layout that counted it", function()
    --[[
    The report: changing the font size threw the reader a long way into the
    book.

    The leader repaginates the instant the size changes and broadcasts the
    new page straight away. Real engines finish repaginating a little after
    the event returns, so that number lands on a device still holding the
    old pagination -- where it means somewhere else entirely. Page 200 of
    400 is half way through; page 200 of 300 is two thirds.
    ]]
    local function withLayout(own_signature, own_pages)
        reset()
        Core.reader = {
            getPageCount = function() return own_pages end,
            getPage = function() return 1 end,
            gotoPage = function() end,
        }
        Core.typographySignature = function() return own_signature end
        Core.layout_differed_at = nil
    end

    T.it("takes the number at face value when both lay the book out alike", function()
        withLayout("A", 300)
        T.assertEquals(Core:pageUnderOwnLayout(150, 300, "A"), 150)
    end)

    T.it("holds a page counted under a layout this device is not using", function()
        withLayout("B", 300)
        T.assertNil(Core:pageUnderOwnLayout(200, 400, "A"),
            "a page from someone else's pagination was applied as it stood")
    end)

    T.it("does not drift a page ahead when the two books are nearly the same length", function()
        --[[
        The report: the follower sat permanently two pages ahead of the
        spread the leader was describing -- the leader said 219-220 and the
        follower showed 221 -- and turning a page kept the gap. A reset was
        the only way out.

        Two books a page apart in length, which is what a cosmetic setting
        the devices spell differently comes to, scaled page 220 to 221. The
        follower went there and recorded 221 as the page it had been sent,
        so nothing ever put it right: the drift was not only wrong, it was
        stable.
        ]]
        withLayout("B", 301)
        Core.layout_differed_at = Util.now() - 60
        T.assertEquals(Core:pageUnderOwnLayout(220, 300, "A"), 220,
            "a book one page longer moved the follower off the spread")
    end)

    T.it("keeps the pair adjacent rather than each device merely near", function()
        -- The leader turns a page and the gap must not grow with it.
        withLayout("B", 301)
        Core.layout_differed_at = Util.now() - 60
        for _, page in ipairs({ 100, 220, 221, 222, 300 }) do
            T.assertEquals(Core:pageUnderOwnLayout(page, 300, "A"), math.min(page, 301),
                ("page %d was moved off the spread"):format(page))
        end
    end)

    T.it("carries the position across by proportion once the difference is real", function()
        -- Held only while it might still be a relayout in flight. Two devices
        -- that go on disagreeing are two different screens, and proportion is
        -- the best a page number can do.
        withLayout("B", 400)
        T.assertNil(Core:pageUnderOwnLayout(150, 300, "A"))
        Core.layout_differed_at = Util.now() - 60
        T.assertEquals(Core:pageUnderOwnLayout(150, 300, "A"), 200,
            "half way through a 300-page book is half way through a 400-page one")
        -- Which is the whole point of the rule: 200 is a different part of
        -- the book from 150, where 221 was next door to 220.
    end)

    T.it("stays inside the book", function()
        withLayout("B", 100)
        Core.layout_differed_at = Util.now() - 60
        T.assertEquals(Core:pageUnderOwnLayout(300, 300, "A"), 100)
    end)

    T.it("says nothing about layouts it cannot compare", function()
        -- An older peer, or a document type with no typography at all: the
        -- number is all there is, and it is used as it always was.
        withLayout("A", 300)
        T.assertEquals(Core:pageUnderOwnLayout(150, 400, nil), 150)
        withLayout(nil, 300)
        T.assertEquals(Core:pageUnderOwnLayout(150, 400, "A"), 150)
    end)
end)

T.describe("spread arithmetic", function()
    local Spread = require("duo/spread")

    T.it("puts the follower on the next page", function()
        T.assertEquals(Spread.pageForSlot(10, 1, { mode = "spread", page_count = 300 }), 11)
        T.assertEquals(Spread.pageForSlot(10, 2, { mode = "spread", page_count = 300 }), 12)
    end)

    T.it("puts the follower on the previous page when reversed", function()
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

    T.it("works out where the leader must sit for a follower to show a page", function()
        --[[
        A follower can be moved by something that is not a page turn -- a
        tapped link, the table of contents, a bookmark -- and it lands
        somewhere the leader knows nothing about. It says the page it wants
        to be showing; this is the sum that turns that into the leader's.
        ]]
        local options = { mode = "spread", page_count = 300 }
        T.assertEquals(Spread.leaderPageForSlot(11, 1, options), 10)
        T.assertEquals(Spread.leaderPageForSlot(12, 2, options), 10)
    end)

    T.it("undoes exactly what it does, whatever the shape of the spread", function()
        -- The one property that matters: the two sums are inverses, or a
        -- device asking to be somewhere ends up somewhere else.
        local shapes = {
            { mode = "spread", page_count = 300 },
            { mode = "spread", page_count = 300, reverse = true },
            { mode = "spread", page_count = 300, pages_per_view = 2 },
            { mode = "spread", page_count = 300, reverse = true, pages_per_view = 2 },
            { mode = "mirror", page_count = 300 },
        }
        for _, options in ipairs(shapes) do
            for slot = 1, 3 do
                local shown = Spread.pageForSlot(150, slot, options)
                T.assertEquals(Spread.leaderPageForSlot(shown, slot, options), 150,
                    ("slot %d did not come back to the leader's page"):format(slot))
            end
        end
    end)

    T.it("mirrors a jump rather than offsetting it", function()
        T.assertEquals(Spread.leaderPageForSlot(42, 1, { mode = "mirror" }), 42)
    end)

    T.it("describes the layout for the status line", function()
        T.assertEquals(Spread.describeLayout(10, 1, { mode = "spread", page_count = 300 }), "10–11")
        T.assertEquals(Spread.describeLayout(10, 2, { mode = "spread", page_count = 300 }), "10–11–12")
        T.assertEquals(Spread.describeLayout(10, 1, { mode = "spread", reverse = true, page_count = 300 }), "9–10")
    end)
end)

os.exit(T.run())
