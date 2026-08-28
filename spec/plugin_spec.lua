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
    device:clearScreen()
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

    --[[
    A wake, and then the moment Duo leaves the reader to redraw in. The
    repair blocks the event loop for five seconds and must not do it while
    the screensaver is still on screen, so nothing rebuilds for PAINT_FIRST
    after waking -- which in a test is time that has to be said to pass
    rather than waited for.
    ]]
    local function wokeAMomentAgo()
        Core:resume()
        if Core.resumed_at then
            Core.resumed_at = Core.resumed_at - Core.PAINT_FIRST - 0.1
        end
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
        wokeAMomentAgo()
        T.assertEquals(checked, 0, "not the instant the screen lights up")

        Core.link_check_at = 0
        Core:poll()
        T.assertEquals(checked, 1, "the link was never checked")

        Core:poll()
        T.assertEquals(checked, 1, "and checking it is a one-off, not a loop")

        Core.hooks.reviveDirectLink = nil
        Core.settings.direct_link = nil
    end)

    T.it("says the link came back after a sleep, and says nothing while it waits", function()
        --[[
        Reported as a regression: "resuming the direct link after sleep was
        not working anymore -- before it resumed the link in about 6
        seconds". What had actually stopped was the sentence saying so.

        Two different callers rebuild this link, and they had been given one
        flag between them. The check a couple of seconds after waking runs
        once and needs to say when it rebuilt something -- that line is how
        anyone knows the pair is back. The healer that runs every twenty
        seconds while the two are apart must say nothing, because narrating
        every pass is what read as the link going up over and over.

        Silencing both at once made a recovery that still worked look like
        one that had stopped, which is a worse bug than the noise it was
        meant to fix: noise is annoying, and a missing signal is a feature
        nobody can tell is working.
        ]]
        reset()
        Core.settings.direct_link = "host"

        local said = {}
        local was_notify = Core.hooks.notify
        Core.hooks.notify = function(text) said[#said+1] = tostring(text) end
        local passed
        Core.hooks.reviveDirectLink = function(quiet, force, silent)
            passed = { quiet = quiet, force = force, silent = silent }
            return "rebuilt"
        end

        -- The check on the way back from a sleep.
        Core.paused_role = nil
        wokeAMomentAgo()
        Core.link_check_at = 0
        Core:poll()
        T.assertTrue(passed ~= nil, "the link was never checked after the sleep")
        T.assertTrue(not passed.silent,
            "the check after a sleep was told to keep the rebuild to itself")
        -- The hook is stubbed here, so what the plugin would have said is
        -- checked against the real one separately; what matters at this
        -- level is that it was not told to hold its tongue.

        -- And the healer that runs on and on while the two are apart.
        passed = nil
        Core.role = Core.ROLE_FOLLOWER          -- active, and not connected
        Core.has_connected = true               -- so it heals over and over
        Core.disconnected_since = 0             -- apart for a good while
        Core.link_healed_at = nil
        Core:poll()
        T.assertTrue(passed ~= nil, "the link was never healed")
        T.assertTrue(passed.silent,
            "the healer announces itself every twenty seconds all over again")

        Core.hooks.notify = was_notify
        Core.hooks.reviveDirectLink = nil
        Core.settings.direct_link = nil
        Core.role = Core.ROLE_OFF
        Core.has_connected = nil
        Core.disconnected_since = nil
        Core.link_healed_at = nil
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
        --[[
        Somebody reading a code off one screen and typing it into the other
        does not need the network pulled out from under them every twenty
        seconds -- which is what rebuilding the cell at the rate a broken
        link deserves amounts to, when the link is not broken at all and the
        other device simply has not arrived yet.

        Rarely, though, and not never. "Once and then leave it alone" was
        the first attempt, and it strands a pair whose one rebuild landed
        before the other device was ready: nothing would ever try again.
        ]]
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

        -- The rate a pair that has worked and come apart gets. Not this one.
        Core.link_healed_at = Util.now() - 25
        Core:poll()
        T.assertEquals(rebuilt, 1,
            "the cell was pulled out from under somebody still typing a code")

        -- But it does come back to it, rather than giving up for good.
        Core.link_healed_at = Util.now() - 600
        Core:poll()
        T.assertEquals(rebuilt, 2,
            "a pair whose one rebuild came too early would be stranded for ever")

        Core.hooks.reviveDirectLink = nil
        Core.settings.direct_link = nil
        Core.role = Core.ROLE_OFF
        Core.disconnected_since, Core.link_healed_at = nil, nil
    end)

    T.it("says nothing about a drop the pair recovers from", function()
        --[[
        Every drop used to be announced the instant it happened, so a reader
        that lost its partner for five seconds and got it straight back said
        "disconnected" and then "connected" -- which reads as the pair
        breaking rather than as the pair coping. Five of eleven drops in one
        log healed within a few seconds.
        ]]
        reset()
        Core.role = Core.ROLE_FOLLOWER
        Core.links = {}
        Core:onLinkClosed({}, "peer disconnected")
        T.assertEquals(table.concat(device:drainMessages(), "\n"), "",
            "it announced a drop before knowing whether it mattered")

        -- Back before the notice was due: nothing was ever worth saying.
        Core.links = { { isReady = function() return true end,
                         isClosed = function() return false end,
                         close = function() end } }
        Core:checkDropNotice()
        T.assertNil(Core.announce_drop_at)
        T.assertEquals(table.concat(device:drainMessages(), "\n"), "")

        -- And one that lasts does get said.
        Core.links = {}
        Core:onLinkClosed({}, "peer stopped responding")
        Core.announce_drop_at = Util.now() - 1
        Core:checkDropNotice()
        T.assertMatch(table.concat(device:drainMessages(), "\n"), "peer stopped responding")

        Core.role = Core.ROLE_OFF
        reset()
    end)

    T.it("still says so at once when the link was put down on purpose", function()
        -- Somebody just asked for this, and an answer six seconds late is
        -- worse than no answer.
        reset()
        Core.role = Core.ROLE_LEADER
        Core.links = {}
        Core:stop("stopped by user")
        T.assertMatch(table.concat(device:drainMessages(), "\n") .. " ", " ")
        T.assertNil(Core.announce_drop_at, "a deliberate stop left a notice pending")
        reset()
    end)

    T.it("works out that it slept when nothing told it so", function()
        --[[
        Because a reader does not always say. On a Kindle the system can
        suspend underneath KOReader without KOReader's own suspend path
        running, and then the first Duo knows of it is that its next poll is
        a minute after its last. In one log every single wake was like that
        -- gaps of 23s, 55s, 232s, 877s and 57 minutes, on both devices
        within a second of each other, and not one of them announced.
        Everything that should follow a sleep was therefore skipped on
        exactly the sleeps that needed it most.

        The gap is the evidence, and Duo is the one holding it.
        ]]
        reset()
        Core.role = Core.ROLE_LEADER
        local woke = 0
        local real_resume = Core.resume
        Core.resume = function(_self) woke = woke + 1 end

        local now = 1000
        Core.last_poll_at = nil
        Core.resumed_at = nil
        Core:noticeFrozenLoop(now)
        T.assertEquals(woke, 0, "the first poll of all was taken for a wake")

        Core:noticeFrozenLoop(now + 0.05)
        T.assertEquals(woke, 0, "an ordinary pass was taken for a night")

        Core:noticeFrozenLoop(now + 0.05 + Core.SLEPT_THROUGH + 1)
        T.assertEquals(woke, 1, "a minute of not running went unnoticed")

        Core.resume = real_resume
        Core.last_poll_at = nil
        Core.resumed_at = nil
        Core.role = Core.ROLE_OFF
        reset()
    end)

    T.it("does not take a slow pass for a sleep, but still forgives it", function()
        --[[
        Two different judgements. Forgiving the time is right whatever
        stopped the loop -- the direct-link script blocks it for four or
        five seconds, and a handshake in flight should no more be charged
        for those than for a night. Calling it a sleep is the bigger claim
        and wants the bigger gap.
        ]]
        reset()
        Core.role = Core.ROLE_LEADER
        local woke = 0
        local real_resume = Core.resume
        Core.resume = function(_self) woke = woke + 1 end

        local forgiven = 0
        Core.links = { {
            isClosed = function() return false end,
            forgive = function(_self, seconds) forgiven = forgiven + seconds end,
        } }

        local now = 2000
        Core.last_poll_at = now
        Core.resumed_at = nil
        local gap = (Core.FROZEN_LOOP + Core.SLEPT_THROUGH) / 2
        Core:noticeFrozenLoop(now + gap)

        T.assertEquals(woke, 0, "five seconds of a shell script is not a night")
        T.assertEquals(forgiven, gap,
            "the link was charged for time the loop spent not running")

        Core.resume = real_resume
        Core.links = {}
        Core.last_poll_at = nil
        Core.role = Core.ROLE_OFF
        reset()
    end)

    T.it("hands a sleeping device's link straight back rather than holding it", function()
        --[[
        The difference is the radio. A loop stopped by Duo's own setup
        script leaves the peer talking all along, so counting that silence
        against it drops a link that never went anywhere. A loop stopped by
        a suspend took the radio with it, and the connection is over.

        Reported the day the forgiveness shipped: Wi-Fi reconnects went
        from instant to about eight seconds. A ready link whose silence has
        been forgiven looks healthy, so Duo held a dead connection for the
        whole of PEER_TIMEOUT before noticing, then redialled, then
        connected -- six seconds and change of doing nothing.
        ]]
        reset()
        Core.role = Core.ROLE_FOLLOWER
        local forgiven = 0
        Core.links = { {
            isClosed = function() return false end,
            forgive = function(_self, seconds) forgiven = forgiven + seconds end,
        } }

        local now = 6000
        Core.last_poll_at = now
        Core.resumed_at = nil
        local real_resume = Core.resume
        Core.resume = function() end

        Core:noticeFrozenLoop(now + Core.SLEPT_THROUGH + 40)
        T.assertEquals(forgiven, 0,
            "a link that slept through the radio going off was kept alive")

        -- And the freeze it was written for is still forgiven.
        Core.last_poll_at = now
        Core.resumed_at = nil
        local shorter = (Core.FROZEN_LOOP + Core.SLEPT_THROUGH) / 2
        Core:noticeFrozenLoop(now + shorter)
        T.assertEquals(forgiven, shorter,
            "a peer was dropped for the seconds Duo spent in its own script")

        Core.resume = real_resume
        Core.links = {}
        Core.last_poll_at = nil
        Core.role = Core.ROLE_OFF
        reset()
    end)

    T.it("puts the other clocks forward by exactly what it lost", function()
        -- A dial, a backoff and a deferred notice are all measured against
        -- a clock that went on running while nothing else did.
        reset()
        Core.role = Core.ROLE_LEADER
        local real_resume = Core.resume
        Core.resume = function() end

        local now = 3000
        Core.last_poll_at = now
        Core.resumed_at = nil
        Core.dialled_at = now - 1
        Core.disconnected_since = now - 2
        Core.link_healed_at = now - 3
        local gap = Core.SLEPT_THROUGH + 8

        Core:noticeFrozenLoop(now + gap)
        T.assertEquals(Core.dialled_at, now - 1 + gap)
        T.assertEquals(Core.disconnected_since, now - 2 + gap)
        T.assertEquals(Core.link_healed_at, now - 3 + gap)

        Core.resume = real_resume
        Core.dialled_at, Core.disconnected_since, Core.link_healed_at = nil, nil, nil
        Core.last_poll_at = nil
        Core.role = Core.ROLE_OFF
        reset()
    end)

    T.it("comes back once per wake, whoever says so", function()
        --[[
        Two things report a wake and they do not agree on when: the poll gap
        at the first turn of the loop, and the reader's own resume event
        whenever KOReader gets to it -- five to eight seconds later in one
        log, which was long enough for the repair to have rebuilt in
        between. Coming back a second time cleared the repair's bookkeeping,
        so it rebuilt again at once, and the second rebuild tore down the
        cell the first had just made:

            23:03:30 apart for a while; rebuilding the link rather than asking
            23:03:35 rebuilt the link the two had been apart on
            23:03:36 dialling 169.254.13.1:9970
            23:03:38 apart for a while; rebuilding the link rather than asking
        ]]
        reset()
        Core.role = Core.ROLE_LEADER

        Core:resume()
        local first = Core.resumed_at
        T.assertTrue(first ~= nil, "the first wake did nothing at all")

        -- The repair runs, as it did in the log.
        Core.link_healed_at = Util.now()
        Core.heal_backoff = 4

        -- And now the reader mentions the sleep it never announced.
        Core:resume()
        T.assertEquals(Core.resumed_at, first, "the same wake was taken twice")
        T.assertTrue(Core.link_healed_at ~= nil,
            "the second wake wiped the repair's bookkeeping, so it rebuilt again")
        T.assertEquals(Core.heal_backoff, 4)

        -- A stop between the two says they are different wakes.
        Core:stop("test done")
        Core.role = Core.ROLE_LEADER
        Core:resume()
        T.assertTrue(Core.resumed_at ~= first, "a wake after a stop was refused")

        Core.role = Core.ROLE_OFF
        reset()
    end)

    T.it("does not move a clock stamped after the loop started again", function()
        --[[
        The poll that froze goes on to finish, and everything it does is
        stamped after the freeze: a connection accepted, a dial completed, a
        disconnection noticed. Moving those forward puts them in the future,
        and a device whose clocks are ahead of the present has nothing to do
        until the present catches up -- which in one log was a minute and a
        half of the leader sitting still while the follower dialled it every
        four seconds.
        ]]
        reset()
        Core.role = Core.ROLE_LEADER
        local real_resume = Core.resume
        Core.resume = function() end

        local now = 5000
        Core.last_poll_at = now
        Core.resumed_at = nil
        local gap = Core.SLEPT_THROUGH + 100
        -- One from before the freeze, one written by the poll that froze.
        Core.link_healed_at = now - 3
        Core.disconnected_since = now + gap - 0.2

        Core:noticeFrozenLoop(now + gap)
        T.assertEquals(Core.link_healed_at, now - 3 + gap,
            "the clock that really did stop was not put right")
        T.assertEquals(Core.disconnected_since, now + gap - 0.2,
            "a clock stamped after the freeze was pushed into the future")

        Core.resume = real_resume
        Core.link_healed_at, Core.disconnected_since = nil, nil
        Core.last_poll_at = nil
        Core.role = Core.ROLE_OFF
        reset()
    end)

    T.it("lets the reader draw before it stops the reader dead", function()
        --[[
        Rebuilding the link runs a shell script synchronously, and
        KOReader's event loop is what waits for it -- so for its whole run
        nothing is drawn and no tap is answered. From a log, the leader's
        first twelve seconds awake:

            23:03:29 the loop stopped for 296s - taking that as a sleep nobody announced
            23:03:29 apart for a while; rebuilding the link rather than asking
            23:03:34 loop: ... work avg 35.8ms max 5282.9ms
            23:03:35 apart for a while; rebuilding the link rather than asking
            23:03:45 loop: ... work avg 73.4ms max 5042.9ms

        Eleven of twelve seconds blocked inside Duo, on a device whose
        wallpaper stayed up because nothing could replace it. Reported as
        the reader looking like it had not woken at all.
        ]]
        reset()
        Core.role = Core.ROLE_LEADER
        Core.has_connected = true
        Core.settings.direct_link = "host"
        local healed = 0
        Core.hooks.reviveDirectLink = function() healed = healed + 1 return "rebuilt" end

        Core.resumed_at = Util.now()
        Core.disconnected_since = Util.now() - 60
        Core.link_healed_at = nil
        Core.heal_backoff = nil
        Core:checkLinkHealth()
        T.assertEquals(healed, 0, "it froze the reader in the act of waking")

        -- The check after a sleep waits with it, and keeps its one shot.
        Core.link_check_at = 0
        Core:checkLink()
        T.assertTrue(Core.link_check_at ~= nil, "and it lost the check waiting")

        -- A moment later there is nothing left to draw over.
        Core.resumed_at = Util.now() - Core.PAINT_FIRST - 0.1
        Core:checkLinkHealth()
        T.assertEquals(healed, 1, "it never got round to the repair at all")

        Core.hooks.reviveDirectLink = nil
        Core.settings.direct_link = nil
        Core.resumed_at, Core.disconnected_since = nil, nil
        Core.link_healed_at, Core.link_check_at = nil, nil
        Core.has_connected = nil
        Core.role = Core.ROLE_OFF
        reset()
    end)

    T.it("starts the clock on being apart when the two come apart", function()
        --[[
        `disconnected_since` used to be cleared below a guard that returns
        whenever a link exists -- which is whenever the pair is connected,
        so it was never cleared at all. It held the time the two were first
        ever apart, and every patience measured against it had been passed
        hours before. From a log, the moment a healthy link dropped:

            09:02:20 [follower] link closed: peer disconnected age=67.8s
            09:02:20 [follower] apart for a while; rebuilding the link
            09:02:23 [leader]   link closed: peer disconnected age=67.7s
            09:02:23 [leader]   apart for a while; rebuilding the link

        Both rebuilding within three seconds, the joiner's lead stepped
        over, two cells of the same name, and the follower dialling into
        nothing.
        ]]
        reset()
        Core.role = Core.ROLE_LEADER
        Core.disconnected_since = Util.now() - 3600   -- apart, an hour ago
        Core.has_connected = nil
        Core.heal_backoff = 8

        local link = { isReady = function() return true end,
                       isClosed = function() return false end }
        Core.links = { link }
        Core:checkLinkHealth()

        T.assertNil(Core.disconnected_since,
            "a connected pair went on counting how long it had been apart")
        T.assertTrue(Core.has_connected,
            "a pair that has met was treated as one that never had")
        T.assertNil(Core.heal_backoff, "the backoff earned while apart outlived it")

        -- And the count starts again from now, not from an hour ago.
        Core.links = {}
        local rebuilt = 0
        Core.hooks.reviveDirectLink = function() rebuilt = rebuilt + 1 return "rebuilt" end
        Core.settings.direct_link = "host"
        Core:checkLinkHealth()
        T.assertEquals(rebuilt, 0, "it rebuilt the instant the link dropped")
        T.assertTrue(Core.disconnected_since ~= nil)

        Core.hooks.reviveDirectLink = nil
        Core.settings.direct_link = nil
        Core.disconnected_since, Core.has_connected = nil, nil
        Core.role = Core.ROLE_OFF
        reset()
    end)

    T.it("stops the host throwing out a joiner that has just arrived", function()
        --[[
        The host makes the cell and the joiner joins it, so a host that
        keeps re-making it keeps throwing out whoever came. From a log:

            09:49:24 [leader]   apart for a while; rebuilding   (after its wake)
            09:49:33 [follower] rebuilt the link ... role: join (joined it)
            09:50:04 [leader]   apart for a while; rebuilding   (and threw it away)

        after which the follower dialled an address with nothing on it
        until somebody stopped Duo by hand.
        ]]
        reset()
        Core.role = Core.ROLE_LEADER
        Core.has_connected = true
        Core.settings.direct_link = "host"
        local forced = {}
        Core.hooks.reviveDirectLink = function(_quiet, force)
            forced[#forced+1] = force and true or false
            return "rebuilt"
        end

        local function repairNow()
            Core.link_healed_at = nil
            Core.heal_backoff = nil
            Core.disconnected_since = Util.now() - 60
            Core:checkLinkHealth()
        end

        -- Nothing has rebuilt since the wake, so the sleep is still suspect.
        -- Woken a moment ago rather than this instant, so the repair is not
        -- held off letting the reader redraw. See PAINT_FIRST.
        Core.resumed_at = Util.now() - Core.PAINT_FIRST - 0.1
        Core.link_rebuilt_at = nil
        repairNow()
        T.assertEquals(forced[1], true, "the first repair after a wake must force")

        -- And now one has, so the cell is asked after rather than remade.
        repairNow()
        T.assertEquals(forced[2], false, "the host tore down its own working cell")

        -- The joiner has nothing to throw away, and keeps forcing.
        Core.settings.direct_link = "join"
        repairNow()
        T.assertEquals(forced[3], true, "the joiner stopped looking for a cell to join")

        Core.hooks.reviveDirectLink = nil
        Core.settings.direct_link = nil
        Core.resumed_at, Core.link_rebuilt_at = nil, nil
        Core.disconnected_since, Core.has_connected = nil, nil
        Core.role = Core.ROLE_OFF
        reset()
    end)

    T.it("keeps the joiner off the air until the host has made the cell", function()
        --[[
        The repair, not just the check after a sleep. Both devices woke
        together, both repaired together, and both rebuilt in the same
        second:

            23:09:06 [leader]   rebuilt as ibss ... role: host
            23:09:06 [follower] rebuilt as ibss ... role: join

        after which the follower dialled the host every four seconds for a
        minute and a half without an answer -- two cells, same name, made at
        the same moment, which never became one. Scoping the stagger to the
        wake assumed clocks that drift apart, and a pair that sleeps and
        wakes on magnets does not have those.
        ]]
        reset()
        Core.role = Core.ROLE_LEADER
        Core.has_connected = true
        local healed = 0
        Core.hooks.reviveDirectLink = function() healed = healed + 1 return "rebuilt" end

        local function repairAfter(apart, role)
            Core.settings.direct_link = role
            Core.link_healed_at = nil
            Core.heal_backoff = nil
            Core.disconnected_since = Util.now() - apart
            Core:checkLinkHealth()
        end

        local before = healed
        repairAfter(3, "join")
        T.assertEquals(healed, before, "the joiner went looking for a cell nobody had made")

        repairAfter(3, "host")
        T.assertEquals(healed, before + 1, "the host waited for a cell only it can make")

        -- And the joiner does get there, once the host has had its run.
        repairAfter(3 + Core.JOINER_LEAD, "join")
        T.assertEquals(healed, before + 2, "the joiner never rebuilt at all")

        Core.hooks.reviveDirectLink = nil
        Core.settings.direct_link = nil
        Core.disconnected_since, Core.link_healed_at = nil, nil
        Core.has_connected = nil
        Core.role = Core.ROLE_OFF
        reset()
    end)

    T.it("does not rebuild the link twice over, four seconds each", function()
        --[[
        The repair and the check after a sleep both rebuild, and in one log
        they ran back to back:

            22:33:07 apart for a while; rebuilding the link rather than asking
            22:33:11 rebuilt the link the two had been apart on
            22:33:11 checking the direct link survived the sleep
            22:33:15 the direct link is back

        Eight seconds before it would say the link was up, and the second
        rebuild tore down the cell the first had just made -- while the
        other device was dialling into it.
        ]]
        reset()
        Core.settings.direct_link = "host"
        Core.role = Core.ROLE_FOLLOWER
        local rebuilt = 0
        Core.hooks.reviveDirectLink = function() rebuilt = rebuilt + 1 return "rebuilt" end

        -- The repair got there first, as it did in the log.
        Core.resumed_at = 100
        Core.link_rebuilt_at = 101
        Core.link_check_at = 0
        Core:checkLink()
        T.assertEquals(rebuilt, 0, "it rebuilt a link that had just been rebuilt")
        T.assertNil(Core.link_check_at, "and left the check hanging about after")

        -- A rebuild from before the sleep answers for nothing.
        Core.link_rebuilt_at = 99
        Core.link_check_at = 0
        Core:checkLink()
        T.assertEquals(rebuilt, 1, "a rebuild from before the sleep was counted")

        Core.hooks.reviveDirectLink = nil
        Core.settings.direct_link = nil
        Core.resumed_at, Core.link_rebuilt_at = nil, nil
        Core.role = Core.ROLE_OFF
        reset()
    end)

    T.it("does not make the joiner wait on the path every wake takes", function()
        --[[
        Settled by the benchmark, over twelve direct-link trials on the
        readers themselves. The reconnect came in at about four seconds plus
        exactly whatever the joiner had been told to wait:

            lead  0s ->  4.1s,  5.9s     lead  6s -> 10.1s, 10.1s
            lead  2s -> 11.0s, 11.1s     lead  8s -> 13.2s, 12.2s
            lead  4s ->  8.1s,  8.2s     lead 12s -> 16.0s

        A second for a second, and nothing bought: the trials at no lead
        were the quickest and not one of them failed. What the lead was for
        is answered at the host's end now, where a host that has already
        rebuilt since waking leaves its own cell alone -- so the tax was
        being paid on every wake against something that had stopped
        happening. It stays on the repeating repair, which only runs when
        the pair is stuck already.
        ]]
        reset()
        Core.settings.direct_link = "join"
        local rebuilt = 0
        Core.hooks.reviveDirectLink = function() rebuilt = rebuilt + 1 return "rebuilt" end
        Core.role = Core.ROLE_FOLLOWER
        Core.resumed_at = Util.now() - Core.PAINT_FIRST - 0.1
        Core.link_rebuilt_at = nil
        Core.link_check_at = 0

        Core:checkLink()
        T.assertEquals(rebuilt, 1, "the joiner sat out a wait it gains nothing from")
        T.assertNil(Core.link_check_at, "and it kept the check hanging about after")

        Core.hooks.reviveDirectLink = nil
        Core.settings.direct_link = nil
        Core.resumed_at, Core.link_rebuilt_at = nil, nil
        Core.role = Core.ROLE_OFF
        reset()
    end)

    T.it("makes the first repair after waking a prompt one", function()
        --[[
        The backoff exists to stop a device hammering a partner switched off
        for the night. It has nothing to say about a device that has just
        woken, where the link is almost certainly gone. In one log a leader
        woke, waited out thirty-five seconds of backoff earned an hour
        earlier, and by the time it rebuilt the cell its partner had given
        up and switched to Wi-Fi.
        ]]
        reset()
        Core.heal_backoff = 8
        Core.link_healed_at = Util.now()
        Core.paused_role = nil
        Core:resume()
        T.assertNil(Core.heal_backoff, "it woke up still holding a grudge")
        T.assertNil(Core.link_healed_at)
        reset()
    end)

    T.it("stops hammering a link the other device is not on", function()
        --[[
        Twenty seconds is right for the case the healer is for: the two went
        out of range, or one woke first, and a rebuild in the next few
        seconds puts them back together. It is wrong for the case that
        actually happens most -- the other reader is off for the night --
        where it means reconfiguring the radio every twenty seconds until
        morning. One log had 1,720 of them, and the shell script that does
        it blocks the event loop while it runs.
        ]]
        reset()
        Core.settings.direct_link = "join"
        local rebuilt = 0
        Core.hooks.reviveDirectLink = function() rebuilt = rebuilt + 1 return "rebuilt" end
        Core.role = Core.ROLE_FOLLOWER
        Core.has_connected = true
        Core.heal_backoff = nil
        Core.disconnected_since = 0
        Core.link_healed_at = nil

        -- The first one is as prompt as it ever was.
        Core:checkLinkHealth()
        T.assertEquals(rebuilt, 1)

        -- The second waits twice as long, and the third twice as long again.
        Core.link_healed_at = Util.now() - 25
        Core:checkLinkHealth()
        T.assertEquals(rebuilt, 1, "it went again at the old twenty seconds")
        Core.link_healed_at = Util.now() - 45
        Core:checkLinkHealth()
        T.assertEquals(rebuilt, 2)
        Core.link_healed_at = Util.now() - 45
        Core:checkLinkHealth()
        T.assertEquals(rebuilt, 2, "the interval stopped growing")

        -- And when they find each other again, it is prompt once more.
        local real_connected = Core.isConnected
        Core.isConnected = function() return true end
        Core:checkLinkHealth()
        Core.isConnected = real_connected
        T.assertNil(Core.heal_backoff, "it stayed slow after the pair came back")

        Core.hooks.reviveDirectLink = nil
        Core.settings.direct_link = nil
        Core.role = Core.ROLE_OFF
        Core.disconnected_since, Core.link_healed_at = nil, nil
        Core.has_connected, Core.heal_backoff = nil, nil
        reset()
    end)

    T.it("leaves a connection that is still being made alone", function()
        --[[
        From a direct-link log, and it is the whole reason that session
        cycled. The follower dialled and got through in 0.03s; the handshake
        had not finished, so nothing thought it was connected; the healer
        fired, ran the setup script -- four and a half seconds of blocked
        event loop -- and reconfigured the radio underneath the handshake it
        was busy not polling. Then, told the link had been "rebuilt", it
        dialled a second time. The leader kept the newer connection and
        dropped the older, the follower saw that as a disconnection, and
        round it went: eleven connections in fourteen seconds.

        Half-made is not disconnected. Nothing here touches the radio, or
        dials, while anything is in flight.
        ]]
        reset()
        Core.settings.direct_link = "join"
        local rebuilt = 0
        Core.hooks.reviveDirectLink = function() rebuilt = rebuilt + 1 return "rebuilt" end
        Core.role = Core.ROLE_FOLLOWER
        Core.has_connected = true
        Core.disconnected_since = 0
        Core.link_healed_at, Core.heal_backoff = nil, nil

        -- A link in the middle of its handshake: not ready, not closed.
        local handshaking = { isReady = function() return false end,
                              isClosed = function() return false end }
        Core.links = { handshaking }
        Core:checkLinkHealth()
        T.assertEquals(rebuilt, 0, "it rebuilt the network under a live handshake")

        Core.reconnect_at = nil
        Core:dialNow()
        T.assertNil(Core.reconnect_at, "it dialled over a link already being made")

        --[[
        A dial in flight is a different matter. dialNow is only called by the
        repair that has just rebuilt the network underneath that attempt, so
        it is crossing something that no longer exists; leaving it to run
        means waiting out its timeout and a backoff before trying the network
        that now works.
        ]]
        Core.links = {}
        local cancelled = false
        Core.connector = { poll = function() end,
                           cancel = function() cancelled = true end }
        Core.reconnect_at = nil
        Core:dialNow()
        T.assertTrue(cancelled, "it left a dial running over a network that had gone")
        T.assertEquals(Core.reconnect_at, 0)
        T.assertNil(Core.connector)

        --[[
        A dial still in flight does not count, and treating it as though it
        did cost more than the bug it fixed. A follower whose peer has gone
        spends most of its time with an attempt outstanding, so the healer --
        the one thing that puts the link back up -- almost never got a turn:
        one log took twenty-seven minutes to reconnect, and thirteen
        recoveries out of fifty-four ran past half a minute. A dial into a
        network that is not there protects nothing.
        ]]
        Core.links = {}
        Core.connector = { poll = function() end, cancel = function() end }
        Core.dialled_at = Util.now() - 30      -- long since given up on
        Core:checkLinkHealth()
        T.assertEquals(rebuilt, 1, "a dial into the void held the healer off")

        --[[
        A dial that has only just gone out is a different matter: healing
        reconfigures the radio, so firing it a moment after a dial destroys
        the connection that dial was making. In one log the follower killed
        its own attempt and the leader recorded an accepted connection that
        never said a word.
        ]]
        Core.link_healed_at, Core.heal_backoff = nil, nil
        -- The heal above cancelled the dial it interrupted, which is what
        -- dialNow is for; this is the next one, freshly out.
        Core.connector = { poll = function() end, cancel = function() end }
        Core.dialled_at = Util.now()
        Core:checkLinkHealth()
        T.assertEquals(rebuilt, 1, "it pulled the radio out from under a fresh dial")

        Core.connector, Core.dialled_at = nil, nil

        Core.hooks.reviveDirectLink = nil
        Core.settings.direct_link = nil
        Core.role = Core.ROLE_OFF
        Core.disconnected_since, Core.link_healed_at = nil, nil
        Core.has_connected, Core.heal_backoff = nil, nil
        reset()
    end)

    T.it("asks the reader for its Wi-Fi back rather than dialling into nothing", function()
        --[[
        From a log: "Network is unreachable" every four seconds for
        twenty-seven minutes. A reader switches its radio off to sleep and
        on again when something wants the network -- and Duo wanting it was
        not, until now, something that said so. Dialling into a dead
        interface changes nothing; asking for it back does.
        ]]
        reset()
        local woken = 0
        Core.hooks.wakeNetwork = function() woken = woken + 1 end
        Core.network_woken_at = nil

        Core:noteDialFailure("Network is unreachable")
        T.assertEquals(woken, 1)

        -- Not on every attempt: it is the reader's connection manager doing
        -- the work, and asking it twice a second helps nobody.
        Core:noteDialFailure("Network is unreachable")
        T.assertEquals(woken, 1, "it nagged the connection manager")

        -- And never for a peer that is simply away, which is a thing to
        -- wait for rather than a thing to do something about.
        Core.network_woken_at = nil
        Core:noteDialFailure("connection refused")
        T.assertEquals(woken, 1, "it rearranged the Wi-Fi over a sleeping peer")
        T.assertEquals(Core.last_error, "connection refused")

        Core.hooks.wakeNetwork = nil
        Core.network_woken_at = nil
        reset()
    end)

    T.it("puts the sleep check off rather than losing it", function()
        --[[
        One check is all a sleep gets. Dropping it because a handshake
        happened to be in flight at the second it came due lost it for good,
        and on a follower -- which starts dialling the moment it wakes --
        that was most of the time.
        ]]
        reset()
        -- Hosting, so the joiner's head start is not what is under test here.
        Core.settings.direct_link = "host"
        local checked = 0
        Core.hooks.reviveDirectLink = function() checked = checked + 1 return "up" end
        Core.role = Core.ROLE_FOLLOWER

        local handshaking = { isReady = function() return false end,
                              isClosed = function() return false end,
                              close = function() end }
        Core.links = { handshaking }
        Core.link_check_at = 0
        Core:checkLink()
        T.assertEquals(checked, 0, "it looked at the network under a live handshake")
        T.assertTrue(Core.link_check_at ~= nil, "and it threw the check away")

        -- The handshake failed; now the check it was holding gets its turn.
        Core.links = {}
        Core.link_check_at = 0
        Core:checkLink()
        T.assertEquals(checked, 1, "the check never came back")

        -- A pair that is talking has no sleep left to recover from.
        Core.links = { { isReady = function() return true end,
                         isClosed = function() return false end,
                         close = function() end } }
        Core.link_check_at = 0
        Core:checkLink()
        T.assertEquals(checked, 1)
        T.assertNil(Core.link_check_at, "it went on asking about a link that is up")

        Core.links = {}
        Core.hooks.reviveDirectLink = nil
        Core.settings.direct_link = nil
        Core.role = Core.ROLE_OFF
        reset()
    end)

    T.it("counts resume attempts per sleep, not per lifetime", function()
        --[[
        The counter only reset in resume, which hangs off a wake-up event
        that does not arrive on every reader. Where it does not, the count
        was a lifetime total -- fifty-eight, in one log -- so a limit meant
        to stop thirty fruitless attempts instead made the first failure
        after the thirtieth ever the last one Duo would try.
        ]]
        reset()
        Core.role = Core.ROLE_LEADER
        Core.resume_attempts = 58
        Core:suspend()
        T.assertEquals(Core.resume_attempts, 0,
            "a device that has woken often would give up on the first try")
        T.assertEquals(Core.paused_role, Core.ROLE_LEADER)
        Core.paused_role = nil
        reset()
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

    T.it("says a rebuild out loud, unless it is the one that repeats", function()
        --[[
        The other half of the same regression, at the level a reader sees.
        The check after a sleep must produce the two lines that tell you the
        pair is coming back; the healer that runs every twenty seconds while
        they are apart must produce none.

        The script is stood in for: rebuilding a link for real reconfigures
        the machine's network, which the suite is not entitled to do to
        whoever is running it.
        ]]
        reset()
        Core.settings.direct_link = "host"

        local DirectLink = require("duo/directlink")
        local ran_script, hosted = DirectLink.run, DirectLink.host
        -- A link that is not up, so every call has something to rebuild.
        DirectLink.run = function() return "mode=managed" end
        DirectLink.host = function() return "" end

        device:drainMessages()
        T.assertEquals(device.plugin:reviveDirectLink(true), "rebuilt")
        local said = table.concat(device:drainMessages(), " | ")
        T.assertMatch(said, "rebuilding the direct link",
            "nothing said while the link was being rebuilt after a sleep")
        T.assertMatch(said, "the direct link is back",
            "the one line that says the pair is back never appeared")

        device:drainMessages()
        T.assertEquals(device.plugin:reviveDirectLink(true, true, true), "rebuilt")
        T.assertEquals(table.concat(device:drainMessages(), " | "), "",
            "the healer narrated itself, which is what it does every twenty seconds")

        DirectLink.run, DirectLink.host = ran_script, hosted
        Core.settings.direct_link = nil
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
        --[[
        Connected, as far as this half of the pair can tell. Put back at the
        end of the test, which it was not: the engine is a singleton, so a
        replacement left in place makes every test after this one believe it
        is connected for the rest of the run. That went unnoticed for as
        long as nothing later depended on the answer.
        ]]
        local was_connected = unit.Core.isConnected
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
        unit.Core.isConnected = was_connected
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

T.describe("one device, one link", function()
    --[[
    Enough of a stream for a link to be built on: the handshake writes a
    challenge into it and reads nothing back. What these tests are about is
    decided the moment the peer names itself, before a page is ever sent.
    ]]
    local function fakeStream(peer)
        return {
            getPeerName = function() return peer end,
            send = function() return true end,
            receive = function() return "" end,
            flush = function() return true end,
            close = function() end,
            pending = function() return 0 end,
        }
    end

    --- A link the way the leader makes one, and the peer naming itself.
    local function arrive(peer, id)
        local link = Core:adoptStream(fakeStream(peer), true)
        link.peer_id = id
        link.slot = Core:placeLink(link, id)
        return link
    end

    T.it("gives a returning follower its old slot back, not a new one", function()
        --[[
        A follower reconnects in a second or two; the leader only notices the
        link it left behind six seconds later, when the heartbeat gives up.
        In between it holds two links to one reader, and since slots are
        handed out by counting links, the returning device is welcomed into
        slot 2 -- shown the page meant for a third reader that does not
        exist. Then the stale link times out and announces a disconnection
        for a device sitting there connected.

        Which is exactly what connect, disconnect, connect looks like.
        ]]
        reset()
        Core.role = Core.ROLE_LEADER
        Core.links = {}

        local first = arrive("192.168.1.9:41000", "aa11bb")
        T.assertEquals(first.slot, 1)

        local second = arrive("192.168.1.9:41001", "aa11bb")
        T.assertEquals(second.slot, 1,
            "the returning device was pushed to the end of the spread")
        T.assertTrue(first:isClosed(), "the leader kept two links to one device")

        Core.links = {}
        reset()
    end)

    T.it("leaves a second, different reader alone", function()
        --[[
        The rule is one link per device, not one link. Two readers can share
        an address -- behind a router, or on one machine, which is how the
        three-device tests run -- so what tells them apart is the identifier
        each one sends, not where it connected from.
        ]]
        reset()
        Core.role = Core.ROLE_LEADER
        Core.links = {}

        local one = arrive("127.0.0.1:41000", "aa11bb")
        local two = arrive("127.0.0.1:41001", "cc22dd")
        T.assertEquals(two.slot, 2)
        T.assertTrue(not one:isClosed(), "it hung up on a device that was fine")

        Core.links = {}
        reset()
    end)

    T.it("does not announce a disconnection it caused itself", function()
        -- The device is connected right now, on the link that replaced the
        -- one being closed. Saying "disconnected" here is the middle of the
        -- three notifications somebody reported seeing.
        reset()
        Core.role = Core.ROLE_LEADER
        Core.links = {}
        arrive("192.168.1.9:41000", "aa11bb")
        device:drainMessages()

        arrive("192.168.1.9:41001", "aa11bb")
        local said = table.concat(device:drainMessages(), "\n")
        T.assertTrue(not said:find("replaced by a new connection"),
            "it told the reader about its own housekeeping")

        Core.links = {}
        reset()
    end)

    T.it("does not redial while it still has somewhere to talk", function()
        --[[
        The other half of the same story, on the follower. It can hold two
        links for a moment -- it dialled again, the leader kept the new one
        and dropped the old -- and the old one closing must not send it
        dialling a third time. That is a pair taking turns hanging up on
        each other for as long as anybody watches.
        ]]
        reset()
        Core.role = Core.ROLE_FOLLOWER
        Core.links = {}
        Core.reconnect_at = nil

        local good = { isReady = function() return true end,
                       isClosed = function() return false end }
        Core.links = { good }
        Core:onLinkClosed({}, "replaced by a new connection from the same device")
        T.assertNil(Core.reconnect_at, "it redialled over a link that was working")

        -- And over one that is merely half-made, which is the case that
        -- actually happened: the replacement had not finished its handshake
        -- when the link it replaced was closed.
        Core.links = { { isReady = function() return false end,
                         isClosed = function() return false end } }
        Core:onLinkClosed({}, "replaced by a new connection from the same device")
        T.assertNil(Core.reconnect_at, "it redialled over a handshake in progress")

        -- And when there really is nothing left, it does redial.
        Core.links = {}
        Core:onLinkClosed({}, "peer disconnected")
        T.assertTrue(Core.reconnect_at ~= nil, "it gave up instead of redialling")

        Core.links = {}
        reset()
    end)

    T.it("cannot be talked into dropping a link by an anonymous peer", function()
        -- A peer that sends no identifier is not "the same device" as
        -- another that sent none; it is simply unknown, and unknown is no
        -- reason to hang up on somebody who is connected.
        reset()
        Core.role = Core.ROLE_LEADER
        Core.links = {}

        local one = arrive("192.168.1.9:41000", "")
        local two = arrive("192.168.1.10:41000", "")
        T.assertTrue(not one:isClosed(), "an unnamed peer evicted a connected one")
        T.assertEquals(two.slot, 2)

        Core.links = {}
        reset()
    end)
end)

T.describe("leaving a direct link to pair over a network", function()
    local DirectLink = require("duo/directlink")
    local NetUtil = require("duo/netutil")

    --- Runs `body` with the device reporting `ip` as its own address, and
    --- with the setup script stubbed out so no radio is touched.
    local function withAddress(ip, body)
        local real_ip, real_restore = NetUtil.getLocalIP, DirectLink.restore
        local restores = 0
        NetUtil.getLocalIP = function() return ip end
        DirectLink.restore = function() restores = restores + 1 return "" end
        local ok, err = pcall(body, function(now) ip = now end,
            function() return restores end)
        NetUtil.getLocalIP, DirectLink.restore = real_ip, real_restore
        if not ok then error(err, 0) end
    end

    T.it("hands the Wi-Fi back before going looking over one", function()
        --[[
        Choosing "Over a Wi-Fi network" while the radio is still holding up
        a cell Duo made is a contradiction, and it used to be resolved the
        wrong way: the setting changed and the radio did not, so the pair
        went looking for each other over the ad-hoc link they were supposed
        to be leaving.
        ]]
        reset()
        device.plugin.RESTORE_POLL = 0
        Core.settings.direct_link = "host"
        Core.settings.peer_host = DirectLink.HOST_ADDRESS

        withAddress(DirectLink.HOST_ADDRESS, function(setAddress, restores)
            local went_on = false
            device.plugin:leaveDirectLink(function() went_on = true end)
            T.assertEquals(restores(), 1, "it left the radio where it was")
            T.assertTrue(not went_on, "it went looking before the network was back")

            -- The system takes a moment to rejoin; then it carries on.
            setAddress("192.168.1.55")
            device.UIManager:pump()
            T.assertTrue(went_on, "it never got on with what it was asked to do")
        end)

        T.assertEquals(Core:get("direct_link"), "off")
        T.assertEquals(Core:get("peer_host"), "",
            "the old host address is what lets the link put itself back up")
        device.plugin.RESTORE_POLL = nil
        reset()
    end)

    T.it("takes the other device with it", function()
        --[[
        Switching has always meant doing the same thing twice, on two
        devices, in the right order, and getting it wrong strands one reader
        on a cell nobody else is on. They are talking to each other at the
        moment the question is asked, so it gets settled between them.
        ]]
        reset()
        Core.settings.autostart_role = Core.ROLE_LEADER
        local asked, switched = nil, false
        local real_ask = Core.askPeerToSwitch
        Core.askPeerToSwitch = function(_, to) asked = to return true end
        device.plugin.performSwitch = function() switched = true end

        device.plugin:switchTransportWith("direct")
        T.assertEquals(asked, "direct", "it switched without a word to the other device")
        T.assertTrue(not switched, "it moved before the other device had heard")

        -- The answer comes back; now both move.
        device.plugin:onPeerSwitch("direct", true)
        T.assertTrue(switched)

        Core.askPeerToSwitch = real_ask
        device.plugin.performSwitch = nil
        device.plugin:closeSwitchNotice()
        reset()
    end)

    T.it("goes alone rather than not at all", function()
        -- A device with nobody to ask, or whose partner is on an older
        -- version and has no idea what it was asked, still switches. Doing
        -- nothing is the one outcome that would be worse than doing it
        -- twice by hand.
        reset()
        Core.settings.autostart_role = Core.ROLE_LEADER
        local switched = 0
        device.plugin.performSwitch = function() switched = switched + 1 end

        local real_ask = Core.askPeerToSwitch
        Core.askPeerToSwitch = function() return false end
        device.plugin:switchTransportWith("wifi")
        T.assertEquals(switched, 1, "with nobody to ask it should just go")

        -- And with somebody who never answers.
        Core.askPeerToSwitch = function() return true end
        device.plugin.SWITCH_ACK_WAIT = 0
        device.plugin:switchTransportWith("wifi")
        T.assertEquals(switched, 1, "it did not wait to be answered")
        device:drainMessages()
        device.UIManager:pump()
        T.assertEquals(switched, 2, "it gave up on the switch entirely")
        T.assertMatch(table.concat(device:drainMessages(), "\n"), "did not answer")

        device.plugin.SWITCH_ACK_WAIT = nil
        Core.askPeerToSwitch = real_ask
        device.plugin.performSwitch = nil
        device.plugin:closeSwitchNotice()
        device:clearScreen()
        reset()
    end)

    T.it("answers a request from the other device, then moves", function()
        --[[
        The reply goes out before this device touches its own radio, because
        touching it is what ends the conversation the reply has to cross.
        ]]
        reset()
        local sent, moved = nil, nil
        local link = { send = function(_, kind, fields) sent = { kind, fields } end }
        Core.hooks.switchTransport = function(to, ours) moved = { to, ours } end

        Core:handleSwitch(link, { type = "SWITCH", to = "direct" })
        T.assertEquals(sent[1], "SWITCH")
        T.assertEquals(sent[2].to, "direct")
        T.assertEquals(sent[2].ack, 1, "the other device was never told we heard")
        T.assertEquals(moved[1], "direct")
        T.assertTrue(not moved[2], "an ack is not a request of our own")

        -- Nonsense is ignored rather than acted on.
        sent, moved = nil, nil
        Core:handleSwitch(link, { type = "SWITCH", to = "sideways" })
        T.assertNil(sent)
        T.assertNil(moved)

        Core.hooks.switchTransport = nil
        reset()
    end)

    T.it("lets the host make the cell before the joiner looks for it", function()
        --[[
        From a log, one second apart:

            18:47:21 [follower] rebuilt the link the two had been apart on
            18:47:22 [leader]   rebuilt the link the two had been apart on

        Both then said the link was up, and the follower dialled the host's
        address every seven seconds for a minute and a half without an
        answer: two ad-hoc cells, same name, formed at the same moment,
        which never became one.
        ]]
        reset()
        Core.settings.autostart_role = Core.ROLE_FOLLOWER
        local built = 0
        device.plugin.switchToDirectLink = function() built = built + 1 end
        device.plugin.JOINER_HOLD = 0

        device.plugin:performSwitch("direct")
        T.assertEquals(built, 0, "the joiner went looking before there was a cell")
        device.UIManager:pump()
        T.assertEquals(built, 1)

        -- The host has nothing to wait for.
        Core.settings.autostart_role = Core.ROLE_LEADER
        device.plugin:performSwitch("direct")
        T.assertEquals(built, 2, "the host held back for no reason")

        device.plugin.JOINER_HOLD = nil
        device.plugin.switchToDirectLink = nil
        reset()
    end)

    T.it("is what both network buttons do first", function()
        -- The wiring, not the mechanism: it is no use knowing how to hand
        -- the Wi-Fi back if the screen that needs it does not ask.
        for _, button in ipairs{ "This device leads (left page)",
                                 "This device follows (right page)" } do
            reset()
            local asked = false
            device.plugin.leaveDirectLink = function() asked = true end
            device.plugin:showRoleDialog("network")
            T.assertTrue(device:pressButton(button), "no such button: " .. button)
            device.plugin.leaveDirectLink = nil
            T.assertTrue(asked, button .. " went straight on to the network")
        end
        reset()
    end)

    T.it("does not touch a device that is already on an ordinary network", function()
        -- Nothing to hand back, and handing it back anyway costs five
        -- seconds of frozen reader for no reason at all.
        reset()
        Core.settings.direct_link = "off"
        withAddress("192.168.1.55", function(_, restores)
            local went_on = false
            device.plugin:leaveDirectLink(function() went_on = true end)
            T.assertTrue(went_on, "it should have gone straight on")
            T.assertEquals(restores(), 0, "it bounced a network that was fine")
        end)
        reset()
    end)

    T.it("knows a stale role from a link that is really up", function()
        --[[
        The two disagree in both directions. A role can be left over from a
        session that ended days ago -- that device is on the house Wi-Fi and
        must be left alone -- while a link set up by hand over SSH leaves no
        role at all and is still plainly a direct link.
        ]]
        reset()
        Core.settings.direct_link = "join"
        withAddress("192.168.1.55", function()
            T.assertTrue(not device.plugin:onADirectLink(),
                "a routed address means this pair is not on a link Duo built")
        end)

        Core.settings.direct_link = "off"
        withAddress(DirectLink.JOIN_ADDRESS, function()
            T.assertTrue(device.plugin:onADirectLink(),
                "holding the joining address is proof, role or no role")
        end)

        -- A link whose address a sleep flushed: the radio is still in the
        -- wrong mode with nothing to show for it, and only the role says so.
        Core.settings.direct_link = "host"
        withAddress("", function()
            T.assertTrue(device.plugin:onADirectLink())
        end)
        reset()
    end)
end)

T.describe("switching how the two reach each other", function()
    local DirectLink = require("duo/directlink")
    local NetUtil = require("duo/netutil")

    T.it("keeps the sides the pair already has", function()
        -- Switching how the two are connected is not a change of roles, and
        -- being walked through both screens to say so again is what makes a
        -- shortcut not worth taking.
        reset()
        Core.settings.autostart_role = Core.ROLE_LEADER
        local role
        device.plugin.runDirectLink = function(_, which) role = which end
        device.plugin:switchToDirectLink()
        T.assertEquals(role, "host")

        Core.settings.autostart_role = Core.ROLE_FOLLOWER
        device.plugin:switchToDirectLink()
        T.assertEquals(role, "join")

        device.plugin.runDirectLink = nil
        reset()
    end)

    T.it("asks which device this is when it has never paired", function()
        -- Nothing to keep, so there is a question to ask after all.
        reset()
        Core.settings.autostart_role = "off"
        Core.settings.token_source = ""
        local asked = false
        device.plugin.showDirectRoleDialog = function() asked = true end
        device.plugin:switchToDirectLink()
        T.assertTrue(asked)
        device.plugin.showDirectRoleDialog = nil
        reset()
    end)

    T.it("does the whole job when switching back to Wi-Fi", function()
        --[[
        Handing the radio back and stopping there would leave two readers on
        a network with nothing running, which is not what anybody means by
        switching to Wi-Fi. It hands it back, waits for the usual network,
        and starts again over it.
        ]]
        reset()
        Core.settings.autostart_role = Core.ROLE_LEADER
        local handed_back, started = false, false
        device.plugin.leaveDirectLink = function(_, on_done)
            handed_back = true
            on_done()
        end
        device.plugin.startLeader = function() started = true end
        device.plugin:switchToWifi()
        device.plugin.leaveDirectLink, device.plugin.startLeader = nil, nil

        T.assertTrue(handed_back, "it left the radio on the link it was leaving")
        T.assertTrue(started, "it handed the Wi-Fi back and then did nothing with it")
        reset()
    end)

    T.it("offers the two a link of their own when it wakes with no network", function()
        --[[
        The moment this is for: the pair leaves the house, a reader wakes on
        a train, and Duo sits retrying a leader that will never answer.
        Everything needed is already on both devices; the only thing missing
        is somebody to say so.
        ]]
        reset()
        Core.settings.autostart_role = Core.ROLE_FOLLOWER
        Core.settings.direct_link = "off"
        local was = device.plugin.STRANDED_AFTER
        device.plugin.STRANDED_AFTER = 0

        local real_ip = NetUtil.getLocalIP
        NetUtil.getLocalIP = function() return "" end
        device.plugin:offerDirectLinkWhenStranded()
        device.UIManager:pump()
        NetUtil.getLocalIP = real_ip

        local said = table.concat(device:drainMessages(), "\n")
        T.assertMatch(said, "no Wi%-Fi here")
        T.assertMatch(said, "Direct link")
        T.assertMatch(said, "Not now", "it has to be refusable")

        device.plugin.STRANDED_AFTER = was
        device:clearScreen()
        reset()
    end)

    T.it("says nothing when the network came back while it was looking", function()
        -- Six seconds is long enough for all of it to have changed, so the
        -- question is asked again on the way out rather than only on the way
        -- in. A device back on its own Wi-Fi must not be offered a link.
        reset()
        Core.settings.autostart_role = Core.ROLE_FOLLOWER
        Core.settings.direct_link = "off"
        local was = device.plugin.STRANDED_AFTER
        device.plugin.STRANDED_AFTER = 0

        local real_ip = NetUtil.getLocalIP
        NetUtil.getLocalIP = function() return "192.168.1.55" end
        device.plugin:offerDirectLinkWhenStranded()
        device.UIManager:pump()
        NetUtil.getLocalIP = real_ip

        T.assertEquals(table.concat(device:drainMessages(), "\n"), "")
        device.plugin.STRANDED_AFTER = was
        reset()
    end)

    T.it("leaves a pair that was stopped on purpose alone", function()
        -- No standing role means somebody switched Duo off. Offering to
        -- rearrange their Wi-Fi at that point is not helpfulness.
        reset()
        Core.settings.autostart_role = "off"
        local was = device.plugin.STRANDED_AFTER
        device.plugin.STRANDED_AFTER = 0

        local real_ip = NetUtil.getLocalIP
        NetUtil.getLocalIP = function() return "" end
        device.plugin:offerDirectLinkWhenStranded()
        device.UIManager:pump()
        NetUtil.getLocalIP = real_ip

        T.assertEquals(table.concat(device:drainMessages(), "\n"), "")
        device.plugin.STRANDED_AFTER = was
        reset()
    end)
end)

T.describe("knowing whether this is a direct link at all", function()
    local DirectLink = require("duo/directlink")

    T.it("forgets a stored role the addresses contradict", function()
        --[[
        Taken from a log: a pair that had once used a direct link and had
        since gone back to the house Wi-Fi. Nothing clears the stored role
        but the menu, and neither autostart nor waking from sleep goes
        through the menu -- so the healer went on tearing down a working
        network to rebuild a link nobody was on, every twenty seconds, for
        a day and a half.
        ]]
        reset()
        Core.settings.direct_link = "join"
        Core.settings.peer_host = "192.168.1.227"
        T.assertNil(device.plugin:directLinkRole(),
            "it would have rebuilt a direct link on a routed network")
        T.assertEquals(Core:get("direct_link"), "off",
            "and it should stop asking the same question every twenty seconds")

        -- The leader sees it from the other side: where its follower came
        -- from, which is the only evidence it has.
        reset()
        Core.settings.direct_link = "host"
        Core.settings.last_peer_host = "192.168.1.67"
        T.assertNil(device.plugin:directLinkRole())
        T.assertEquals(Core:get("direct_link"), "off")
        reset()
    end)

    T.it("keeps a real one, including when the network has gone", function()
        --[[
        Silence is not evidence. A device with no address has merely lost
        its network, which is exactly the moment a direct link needs
        rebuilding -- and a Kindle that wakes and rejoins the house Wi-Fi on
        its own must not talk Duo out of putting the link back.
        ]]
        reset()
        Core.settings.direct_link = "join"
        Core.settings.peer_host = DirectLink.HOST_ADDRESS
        T.assertEquals(device.plugin:directLinkRole(), "join")

        reset()
        Core.settings.direct_link = "host"
        Core.settings.last_peer_host = DirectLink.JOIN_ADDRESS
        T.assertEquals(device.plugin:directLinkRole(), "host")

        -- Nothing known either way: the stored role stands.
        reset()
        Core.settings.direct_link = "host"
        Core.settings.last_peer_host = ""
        T.assertEquals(device.plugin:directLinkRole(), "host")
        reset()
    end)
end)

T.describe("the verbose log", function()
    --[[
    Everything Duo said while `run` ran. The hook rather than the file: what
    matters is what was handed to the log, and going through a real file
    would make these tests about the writer instead.
    ]]
    local function capture(run)
        local lines = {}
        local real = Core.hooks.log
        Core.hooks.log = function(...)
            local parts = {}
            for index = 1, select("#", ...) do
                parts[#parts+1] = tostring((select(index, ...)))
            end
            lines[#lines+1] = table.concat(parts, " ")
        end
        local ok, err = pcall(run)
        Core.hooks.log = real
        if not ok then error(err, 0) end
        return table.concat(lines, "\n")
    end

    local function verbose(on)
        Core.settings.debug_log = on and true or false
        Core.settings.verbose_log = on and true or false
    end

    T.it("stays quiet until it is asked for", function()
        -- Two switches, because the commentary is far too much to leave on
        -- and the ordinary log is not. Either one off means silence.
        reset()
        Core.settings.debug_log = true
        Core.settings.verbose_log = false
        T.assertEquals(capture(function() Core:trace("running commentary") end), "")

        Core.settings.verbose_log = true
        T.assertMatch(capture(function() Core:trace("running commentary") end),
            "running commentary")

        Core.settings.debug_log = false
        T.assertEquals(capture(function() Core:trace("running commentary") end), "",
            "the commentary escaped a log that is switched off")
        verbose(false)
    end)

    T.it("reports how often the event loop really ran", function()
        --[[
        The measurement that separates the two ways a pair feels slow. A long
        round trip with 50ms gaps is a slow network; hundred-millisecond gaps
        are a Duo that is not being run often enough to answer quickly
        however fast the network is. From the outside the two are identical.
        ]]
        reset()
        verbose(true)
        local every = Core.POLL_SUMMARY_EVERY
        Core.POLL_SUMMARY_EVERY = 0
        Core.poll_stats, Core.polled_at = nil, nil

        local said = capture(function() Core:poll() Core:poll() end)

        Core.POLL_SUMMARY_EVERY = every
        verbose(false)
        T.assertMatch(said, "loop:")
        T.assertMatch(said, "gap avg %d+ms max %d+ms")
        T.assertMatch(said, "work avg")
    end)

    T.it("does not time the loop when nobody is reading about it", function()
        reset()
        verbose(false)
        Core.poll_stats, Core.polled_at = nil, nil
        Core:poll()
        T.assertNil(Core.poll_stats, "it kept books nobody asked for")
    end)

    T.it("times a turn from the tap to the page coming back", function()
        --[[
        Not the same number the heartbeat measures. A ping is answered by the
        link the instant it lands; a turn has to reach the leader, move a
        real reader and come back as a page for this screen. Somebody saying
        the follower is slow means this number.
        ]]
        reset()
        verbose(true)
        Core:noteTurnSent("turn")
        local said = capture(function() Core:noteTurnAnswered() end)
        T.assertMatch(said, "turn answered in %d+ms")

        -- And it is one measurement, not one per page that arrives after it.
        T.assertEquals(capture(function() Core:noteTurnAnswered() end), "")
        verbose(false)
    end)

    T.it("says what a link had been doing when it closes, log or no log", function()
        -- In the ordinary log, not the commentary: a pair that connects,
        -- drops and connects again is the first thing worth knowing, and
        -- nobody has verbose switched on when it happens the first time.
        reset()
        verbose(false)
        Core.settings.debug_log = true
        Core.role = Core.ROLE_FOLLOWER
        local said = capture(function()
            Core:onLinkClosed({ report = function() return "age=2.0s in=7/900B" end },
                "peer stopped responding")
        end)
        Core.settings.debug_log = false
        T.assertMatch(said, "peer stopped responding")
        T.assertMatch(said, "age=2.0s")
        reset()
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
            report = { ssid = "KOReaderDuo" },
        }
        local shown = table.concat(device:drainMessages(), "\n")
        T.assertMatch(shown, "KOReaderDuo", "the network has to be named")
        T.assertMatch(shown, "This device follows", "another reader does it from the menu")
        T.assertMatch(shown, "DIRECT1")

        --[[
        And the passphrase, which is derived from the pairing code rather
        than fixed. It used to be one string shipped with the plugin and
        printed in the README, which is not a secret; the sheet has to show
        whatever this pair's key actually is, because that is what somebody
        types into a laptop.
        ]]
        local DirectLink = require("duo/directlink")
        T.assertMatch(shown, DirectLink.passphraseFor("DIRECT1"),
            "the sheet must show the key the network was really built with")
        T.assertTrue(shown:find("koreaderduo") == nil,
            "the published passphrase should be nowhere near it")

        -- The ordinary sheet says none of that, because it does not apply.
        device.plugin:showPairingSheet()
        local plain = table.concat(device:drainMessages(), "\n")
        T.assertTrue(not plain:find("Passphrase"),
            "on a network both devices are already on there is nothing to join")
        Core.settings.port = 9970
    end)

    T.it("says plainly that an ad-hoc cell carries no encryption", function()
        -- The drivers this runs on cannot do WPA on an ad-hoc cell, so the
        -- fallback is an open network. Showing a passphrase for it, or
        -- saying nothing, would both be lies.
        reset()
        Core.settings.token = "DIRECT1"
        device.plugin:showPairingSheet{
            direct = true, mode = "ibss", report = { ssid = "KOReaderDuo" },
        }
        local shown = table.concat(device:drainMessages(), "\n")
        T.assertMatch(shown, "unencrypted", "an open network has to be called one")
        T.assertTrue(shown:find(require("duo/directlink").passphraseFor("DIRECT1")) == nil,
            "it showed a key for a cell that has none")
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

    T.it("asks the joining device for the code once, and then never again", function()
        --[[
        The direct link's Wi-Fi key is derived from the pairing code, which
        means a joining device that has not been told the code cannot even
        associate -- it does not get as far as being refused, it just fails
        to find a network that is right there. So it has to ask.

        Once. The whole appeal of the direct link is a tap on each device,
        and a keyboard every time you sit down would be worse than the
        published passphrase this replaced.
        ]]
        reset()
        Core.settings.token = ""
        Core.settings.token_source = ""
        -- Counted rather than run: the real one reconfigures the Wi-Fi
        -- interface, which is the script's job and directlink_spec's.
        local built = 0
        device.plugin.buildDirectLink = function() built = built + 1 end

        device.plugin:runDirectLink("join")
        T.assertEquals(built, 0, "it must not touch the radio with a code it made up")
        local asked = table.concat(device:drainMessages(), "\n")
        T.assertMatch(asked, "Pairing code")
        T.assertMatch(asked, "Only once")
        T.assertTrue(device:answerDialog("K7F2QX", "OK"), "no code dialog to answer")
        T.assertEquals(built, 1, "answering has to get on with it")
        T.assertEquals(Core:get("token"), "K7F2QX")

        -- And the second time, and every time after it.
        device:drainMessages()
        device.plugin:runDirectLink("join")
        T.assertEquals(built, 2)
        T.assertNil(device:currentDialog("InputDialog"),
            "it asked for a code it already had")

        device.plugin.buildDirectLink = nil -- back to the module's own
    end)

    T.it("never asks the hosting device for a code", function()
        -- The host is where the code comes *from*. Asking there would be
        -- asking somebody to type in what is about to be shown to them.
        reset()
        Core.settings.token = ""
        Core.settings.token_source = ""
        -- Counted rather than run: the real one reconfigures the Wi-Fi
        -- interface, which is the script's job and directlink_spec's.
        local built = 0
        device.plugin.buildDirectLink = function() built = built + 1 end
        device.plugin:runDirectLink("host")
        T.assertEquals(built, 1)
        T.assertNil(device:currentDialog("InputDialog"))
        device.plugin.buildDirectLink = nil -- back to the module's own
    end)

    T.it("will not build a direct link with no code, and says why", function()
        --[[
        "No code, let anybody connect" is a real answer on an ordinary
        network. It is no answer at all to WPA2, which wants eight
        characters to encrypt with -- and the script rightly refuses to
        build an open network instead. Refusing here, with a sentence,
        beats handing that refusal on as a shell error.
        ]]
        reset()
        Core.settings.token = ""
        Core.settings.token_source = ""
        -- Counted rather than run: the real one reconfigures the Wi-Fi
        -- interface, which is the script's job and directlink_spec's.
        local built = 0
        device.plugin.buildDirectLink = function() built = built + 1 end

        device.plugin:runDirectLink("join")
        device:drainMessages()
        T.assertTrue(device:answerDialog("", "OK"), "no code dialog to answer")
        T.assertEquals(built, 0, "it went ahead with no key at all")
        local said = table.concat(device:drainMessages(), "\n")
        T.assertMatch(said, "needs a pairing code")

        device.plugin.buildDirectLink = nil -- back to the module's own
    end)

    T.it("takes 'no code' as an answer on an ordinary network", function()
        -- A leader with no code set accepts anybody, which is a setting
        -- somebody chose. Asking a follower for it again every time it
        -- connects would be nagging about a decision already made.
        reset()
        Core.settings.token = ""
        Core.settings.token_source = ""
        Core:adoptToken("")
        T.assertTrue(Core:knowsPeerToken())

        local started = false
        local real_start = Core.start
        Core.start = function() started = true return true end
        device.plugin:connectTo("169.254.13.1", 9970, true)
        Core.start = real_start
        T.assertTrue(started, "it should have connected without asking")
        T.assertNil(device:currentDialog("InputDialog"))
    end)

    T.it("asks a device that invented its own code, not just an empty one", function()
        --[[
        Opening Duo's menu mints a pairing code, because a leader needs one
        to show. A device that did that and then went to follow was holding
        six characters no leader had ever heard of -- and because the box
        was not empty, nothing asked. It connected with them, was refused,
        and retried with the same wrong code until somebody gave up.
        ]]
        reset()
        Core.settings.token = ""
        Core.settings.token_source = ""
        local mine = Core:ensureToken()
        T.assertEquals(#mine, 6)
        T.assertTrue(not Core:knowsPeerToken(),
            "a code this device invented is not the other device's code")

        local started = false
        local real_start = Core.start
        Core.start = function() started = true return true end
        device.plugin:connectTo("169.254.13.1", 9970, true)
        T.assertTrue(not started, "it connected with a code of its own invention")
        T.assertTrue(device:answerDialog("PEER01", "OK"))
        T.assertTrue(started)
        T.assertTrue(Core:knowsPeerToken())
        Core.start = real_start
    end)

    T.it("does not offer a code of its own as the answer", function()
        -- The box used to be prefilled with whatever this device had, which
        -- on a device that minted its own is six plausible-looking
        -- characters that are certainly wrong -- an invitation to press OK
        -- and be turned away.
        reset()
        Core.settings.token = ""
        Core.settings.token_source = ""
        local mine = Core:ensureToken()
        device.plugin:promptForToken()
        local dialog = device:currentDialog("InputDialog")
        T.assertTrue(dialog ~= nil, "nothing asked")
        T.assertEquals(dialog.input, "", "it offered a code the leader never issued")
        T.assertTrue(mine ~= "", "sanity: this device had one of its own")
        device:clearScreen()
    end)

    T.it("keeps a code that has already worked, across an update", function()
        --[[
        Where a code came from was not recorded before this, and a pair that
        has been working for months should not be handed a keyboard because
        a new version started keeping notes. A stored leader address is the
        tell: nothing but following one ever writes it.
        ]]
        local migrated = require("duo/core").migrateSettings{
            token = "OLD123", peer_host = "169.254.13.1",
        }
        T.assertEquals(migrated.token_source, "peer")

        -- A device that has only ever led has no address to go on, and
        -- guessing "peer" there would skip an ask that is needed.
        local leader = require("duo/core").migrateSettings{ token = "OLD123" }
        T.assertEquals(leader.token_source, nil)
    end)

    T.it("asks again when the leader refuses the code, instead of retrying it", function()
        --[[
        Every other reason a link ends is worth another go a second later.
        A code the leader will not take is not: retrying is a loop that
        cannot terminate, and the device sits saying "retrying in 32s" while
        the fix -- six characters off the other screen -- is never asked
        for.
        ]]
        reset()
        Core.settings.token = "WRONG1"
        Core.settings.token_source = "peer"
        Core.settings.peer_host = "169.254.13.1"
        Core.role = Core.ROLE_FOLLOWER
        Core.reconnect_at = nil

        local asked = false
        local real_hook = Core.hooks.askForToken
        Core.hooks.askForToken = function() asked = true end
        Core:onLinkClosed({}, require("duo/link").BAD_TOKEN)
        Core.hooks.askForToken = real_hook

        T.assertNil(Core.reconnect_at, "a refused code must not be retried")
        T.assertTrue(not Core:isActive(), "and it must not be left running either")
        T.assertEquals(Core:get("token"), "", "a refused code is not worth keeping")
        T.assertTrue(asked, "nothing asked for the code that would have fixed it")
        reset()
    end)

    T.it("reconnects with whatever is typed after a refusal", function()
        -- One dialog, not a dead end: the point of asking is to get back on
        -- the link, and making somebody find the menu again afterwards is
        -- most of the annoyance of being refused in the first place.
        reset()
        Core.settings.token = ""
        Core.settings.token_source = ""
        Core.settings.peer_host = "169.254.13.1"

        device.plugin:askForTokenAgain()
        local asked = table.concat(device:drainMessages(), "\n")
        T.assertMatch(asked, "refused that code")

        local started
        local real_start = Core.start
        Core.start = function(_, role) started = role return true end
        T.assertTrue(device:answerDialog("RIGHT1", "OK"))
        Core.start = real_start
        T.assertEquals(started, Core.ROLE_FOLLOWER, "answering should reconnect")
        T.assertEquals(Core:get("token"), "RIGHT1")
        T.assertTrue(Core:knowsPeerToken(), "and it should not be asked for again")
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

    T.it("says which Duo wrote it, which no report ever includes either", function()
        --[[
        Learnt from a bug report that came with two days of logs and the
        sentence "these issues are not tested with the new version". Half of
        what was in the file was about a fault that had already been fixed,
        and nothing in the file said so.
        ]]
        local line = device.plugin:describeEnvironment()
        T.assertMatch(line, "duo=%d+%.%d+%.%d+")
    end)

    T.it("takes its version from the one place it is written down", function()
        --[[
        _meta.lua, because that is the copy KOReader loads and the copy a
        plugin store reads to work out whether what is installed is older
        than what is published. A second copy anywhere else is one that
        disagrees with itself by the second release.

        Read rather than required: _meta.lua wants gettext, and a version
        number is not worth dragging KOReader's translations in for.
        ]]
        local handle = assert(io.open("duo.koplugin/_meta.lua", "r"))
        local meta = handle:read("*a")
        handle:close()
        local written = meta:match('version%s*=%s*"([^"]+)"')
        T.assertTrue(written ~= nil,
            "_meta.lua has no version, so nothing can tell an update from an install")
        T.assertEquals(device.plugin:getVersion(), written)
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

T.describe("opening a book on both devices at once", function()
    T.it("does not report the page a book opens on as a jump", function()
        --[[
        Seen in a real reader's log: "jumped to 1 - asking the leader to
        follow", moments after a book was opened. A device that has not been
        told where to stand has not jumped anywhere -- it has just opened a
        book and landed where it left off -- and reporting that dragged the
        pair to page one of a book neither had finished opening.
        ]]
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
        Core.reader = {
            getPage = function() return 1 end,
            getPageCount = function() return 300 end,
            gotoPage = function() end,
        }
        Core.assigned_page = nil
        Core.assigned_pages = nil

        Core:reportJump(1)
        T.assertEquals(#sent, 0, "opening a book was reported as a jump")

        -- Once it has been told where to stand, a real jump still counts.
        Core.assigned_page = 10
        Core.assigned_pages = 300
        Core.last_seen_pages = 300
        Core:reportJump(120)
        T.assertEquals(#sent, 1, "a jump made by hand should still be reported")

        Core.links = {}
        Core.role = Core.ROLE_OFF
        Core.reader = nil
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
        --[[
        More chunks than one turn of the loop may send, on any machine. The
        turn stops at a deadline now, so how much it gets through depends on
        how fast the machine is -- but never past the ceiling that sits over
        the deadline, so sizing the book past that holds everywhere.
        ]]
        handle:write(string.rep("x", BookTransfer.CHUNK * (BookTransfer.CHUNKS_PER_POLL + 16)))
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

        local chunks_in_book = math.ceil(sender.size / BookTransfer.CHUNK)
        Core:pumpBookSender()
        local first = countData(link)
        T.assertTrue(first > 0, "the poll sent nothing at all")
        T.assertTrue(first < chunks_in_book,
            "one turn of the poll loop sent the whole book and froze the reader")
        T.assertTrue(Core.book_sender ~= nil, "the transfer should still be going")

        Core:pumpBookSender()
        T.assertTrue(countData(link) > first,
            "the next turn did not carry on where the last one stopped")

        Core:cancelTransfer("stopped by hand")
        T.assertNil(Core.book_sender, "the transfer would not stop")
    end)

    T.it("keeps one turn inside the slice of the poll it was given", function()
        --[[
        What the count used to stand in for, asked directly. KOReader polls
        every fifty milliseconds, and a plugin that spends all of that is a
        plugin nobody can tap through. The measurement is generous -- a
        shared build machine is not a quiet one -- but it is measuring the
        right thing, which the old ceiling of forty-eight chunks was not:
        that number was minutes of work on a Kindle and a rounding error on
        anything else.
        ]]
        reset()
        local sender = assert(BookTransfer.newSender(bigBook()))
        local link = eagerLink()
        Core.book_sender = { sender = sender, link = link, name = "big.epub" }

        local Util = require("duo/util")
        local started = Util.now()
        Core:pumpBookSender()
        local spent = Util.now() - started
        T.assertTrue(spent < BookTransfer.POLL_BUDGET * 5,
            ("one turn held the reader for %.0f ms, against a budget of %.0f ms")
                :format(spent * 1000, BookTransfer.POLL_BUDGET * 1000))
        Core:cancelTransfer("stopped by hand")
    end)

    T.it("still sends something when there is no time at all to send it in", function()
        -- A budget that has already run out must not mean a transfer that
        -- never moves. The deadline is checked after a chunk, not before.
        reset()
        local was = BookTransfer.POLL_BUDGET
        BookTransfer.POLL_BUDGET = -1
        local sender = assert(BookTransfer.newSender(bigBook()))
        local link = eagerLink()
        Core.book_sender = { sender = sender, link = link, name = "big.epub" }

        Core:pumpBookSender()
        BookTransfer.POLL_BUDGET = was
        T.assertEquals(countData(link), 1,
            "a poll with no time in it should still move the transfer along by one")
        Core:cancelTransfer("stopped by hand")
    end)

    T.it("gets the whole book across, a poll at a time", function()
        -- The budget bounds one turn; it must not bound the transfer.
        reset()
        local sender = assert(BookTransfer.newSender(bigBook()))
        local link = eagerLink()
        Core.book_sender = { sender = sender, link = link, name = "big.epub" }

        local total = sender.size
        for _ = 1, 5000 do
            if not Core.book_sender then break end
            Core:pumpBookSender()
        end
        T.assertNil(Core.book_sender, "the transfer never finished")
        T.assertEquals(countData(link), math.ceil(total / BookTransfer.CHUNK),
            "the book did not go across in one piece")
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

T.describe("keeping the radio awake while the pair is connected", function()
    --[[
    Confirmed on the reader's own hardware before it was built: with
    `iw dev wlan0 set power_save off` on both Kindles, page turns over an
    ordinary Wi-Fi network stopped lagging. A reader associated to a router
    sleeps its radio between beacons and the router holds small packets
    until the next one, which a page turn pays for and a book transfer --
    whose traffic never lets the radio sleep -- does not.
    ]]
    --- A link that answers everything asked of it and remembers nothing.
    local function fakeLink()
        return {
            state = "ready",
            slot = 1,
            peer_name = "other",
            isReady = function() return true end,
            isClosed = function() return false end,
            allowSilence = function() end,
            send = function() return true end,
        }
    end

    local function device_with(hook)
        local instance = Instance.new{ name = "Kindle-W", page_count = 300 }
        instance.Core.hooks.setRadioAwake = hook
        -- The engine is a singleton and remembers what it last asked for,
        -- deliberately, so that it asks once rather than on every poll.
        -- Each test here starts from not having asked.
        instance.Core.radio_awake = nil
        return instance, instance.Core
    end

    T.it("asks for it while Duo runs, and hands it back when Duo stops", function()
        --[[
        While running, not while connected. Scoping it to the connection
        looked tighter and was really much noisier: every connection and
        every disconnection poked the driver, so a flapping pair ran `iw`
        four times in ten seconds -- on hardware that may answer a
        power-save change by re-associating, which is to say by causing the
        next disconnection. And it saved nothing, because a disconnected Duo
        is dialling every few seconds and wants the radio just as much.
        ]]
        local asked = {}
        local instance, core = device_with(function(awake) asked[#asked+1] = awake end)
        core.settings.keep_radio_awake = true

        core.role = core.ROLE_LEADER
        core.links = { fakeLink() }
        core:onLinkReady(core.links[1])
        T.assertEquals(asked[#asked], true, "the radio was left to doze while running")

        -- Losing the peer is not losing the reason: it is about to dial again.
        core.links = {}
        core:onLinkClosed(nil, "peer disconnected")
        T.assertEquals(#asked, 1, "it handed the radio back between two dials")

        core:stop("test done")
        T.assertEquals(asked[#asked], false,
            "the radio was kept awake after Duo stopped, which is battery for nothing")
        core.role = core.ROLE_OFF
    end)

    T.it("does not ask at all when the reader would rather have the battery", function()
        local asked = 0
        local instance, core = device_with(function() asked = asked + 1 end)
        core.settings.keep_radio_awake = false
        core.role = core.ROLE_LEADER
        core.links = { fakeLink() }
        core:onLinkReady(core.links[1])
        T.assertEquals(asked, 0, "a setting that is off should ask for nothing")
        core.links = {}
        core.role = core.ROLE_OFF
    end)

    T.it("asks again after a sleep, because the reader puts it back", function()
        -- A reader's own connection manager restores its wireless settings
        -- when it brings the network up, so what Duo asked for before the
        -- sleep is not still true afterwards.
        local asked = {}
        local instance, core = device_with(function(awake) asked[#asked+1] = awake end)
        core.settings.keep_radio_awake = true
        core.role = core.ROLE_LEADER
        core.links = { fakeLink() }
        core:onLinkReady(core.links[1])
        local before = #asked

        core:resume()
        T.assertTrue(#asked > before,
            "Duo took its own word for it and never asked again after waking")
        core.links = {}
        core.role = core.ROLE_OFF
    end)

    --[[
    And asking again is not the same as it having worked.

    Reported from the pair as page turns that lag after every sleep, and
    never come right until Duo is stopped and started. Asking on the way
    back was there already; what was missing is that the answer does not
    hold. A driver puts its own defaults back when the interface
    re-associates, which is what a reader does on every wake -- and `resume`
    asks while the Wi-Fi is still down, so the request lands on a card that
    is about to overwrite it. Nothing announces that, and the flag saying
    Duo had asked was taken as the radio being awake, so it never asked
    twice.

    So the flag is what Duo wants, and the card is asked what is true.
    ]]
    local function watching(state)
        local looked = 0
        local asked = {}
        local instance, core = device_with(function(awake) asked[#asked+1] = awake end)
        core.hooks.radioIsAwake = function()
            looked = looked + 1
            return state
        end
        core.settings.keep_radio_awake = true
        core.role = core.ROLE_LEADER
        core.links = { fakeLink() }
        core:onLinkReady(core.links[1])
        core.radio_checked_at = nil
        core.radio_retries = 0
        -- A device that has not just woken, so that a test which wakes it
        -- is not refused as the same wake as the test before.
        core.resumed_at = nil
        return core, asked, function() return looked end
    end

    local function put_away(core)
        core.hooks.radioIsAwake = nil
        core.links = {}
        core.role = core.ROLE_OFF
        core.radio_checked_at = nil
        core.radio_retries = nil
    end

    T.it("notices power saving came back on, and says so again", function()
        local core, asked = watching(false)
        local before = #asked

        core:checkRadioSetting()
        T.assertEquals(#asked, before + 1,
            "the card said it was dozing and Duo let it")
        T.assertEquals(asked[#asked], true, "and asked for the wrong thing")

        -- Not on every poll, though: this runs an external command.
        core:checkRadioSetting()
        T.assertEquals(#asked, before + 1, "it asked twice in the same second")
        put_away(core)
    end)

    T.it("says nothing more when the card is doing what was asked", function()
        local core, asked, looked = watching(true)
        local before = #asked
        core:checkRadioSetting()
        T.assertEquals(looked(), 1, "it did not look")
        T.assertEquals(#asked, before, "a radio already awake was poked anyway")
        put_away(core)
    end)

    T.it("leaves a card alone that will not answer", function()
        -- nil is a driver saying it does not know, which is not a reason to
        -- poke it every thirty seconds for the whole of a book.
        local core, asked = watching(nil)
        local before = #asked
        core:checkRadioSetting()
        T.assertEquals(#asked, before, "it argued with a card that said nothing")
        put_away(core)
    end)

    T.it("takes no for an answer after a few tries", function()
        --[[
        A driver that will not turn power saving off is entitled to that,
        and changing power save may be answered by re-associating -- so a
        device that asks every thirty seconds forever is spending battery to
        be told no, and dropping the link to hear it.
        ]]
        local core, asked = watching(false)
        local before = #asked
        for _ = 1, core.RADIO_RETRIES + 3 do
            core.radio_checked_at = nil
            core:checkRadioSetting()
        end
        T.assertEquals(#asked - before, core.RADIO_RETRIES,
            "it kept poking a driver that had made itself clear")

        -- Until the next sleep, which brings the interface up again and is
        -- a different proposition. Waking asks once by itself, which is the
        -- behaviour above; what is under test is that it asks again after.
        core:resume()
        core.role = core.ROLE_LEADER
        core.radio_awake = true
        core.radio_checked_at = nil
        local woken = #asked
        core:checkRadioSetting()
        T.assertEquals(#asked, woken + 1,
            "a device that gave up once gave up for good")
        put_away(core)
    end)

    T.it("leaves a link alone until it is old enough to survive the asking", function()
        --[[
        Changing power save can drop the link, and on a link a second old it
        reliably does. Sorted by how old the link was when Duo re-applied
        the setting, from a log of one morning:

            link 0s old   -> the link died 1, 1, 4, 5, 6, 7, 7 and 8s later
            link 90s+ old -> the next death was 48, 78, 108, 121, 211s later

        Duo's own doing: the check was arranged to run the moment a link
        came up, because a link is proof the card just associated and
        association is what puts the driver's default back. True, and the
        wrong moment to act on it. The reader saw "connected",
        "disconnected", "connected", twice in two minutes.
        ]]
        local core, asked = watching(false)
        local before = #asked
        local now = Util.now()
        core.links = { {
            created_at = now,
            isClosed = function() return false end,
        } }

        core.radio_checked_at = nil
        core:checkRadioSetting()
        T.assertEquals(#asked, before, "it poked the driver under a fresh link")

        -- And not put off for ever: as soon as the link is old enough.
        core.links[1].created_at = now - Core.RADIO_SETTLE - 1
        core.radio_checked_at = nil
        core:checkRadioSetting()
        T.assertEquals(#asked, before + 1,
            "a settled link never got its power saving turned off again")

        put_away(core)
    end)

    T.it("does not chase a radio it has handed back", function()
        -- Duo stopping is Duo having no opinion: the reader turning power
        -- saving back on afterwards is the reader's business.
        local core, asked = watching(false)
        core.links = {}
        core:stop("test done")
        local before = #asked
        core.radio_checked_at = nil
        core:checkRadioSetting()
        T.assertEquals(#asked, before, "it went on managing a radio it gave up")
        put_away(core)
    end)
end)

T.describe("a follower's own page turn", function()
    --[[
    Reported from a pair of Kindles, and it is the best description of the
    problem there is: "when doing the follower, it takes a while for the host
    to turn, and after that the follower finally turns, even though this is
    where I started the turn."

    A follower's tap was forwarded and swallowed. The leader received it,
    moved, repainted, and only then said where everybody stood -- so the
    device under the reader's thumb was the last thing in the room to
    respond.
    ]]
    local Protocol = require("duo/protocol")

    local function follower(page)
        local unit = Instance.new{ name = "Kindle-T", page_count = 300 }
        local core = unit.Core
        core.settings.mode = "spread"
        core.settings.follower_can_turn = true
        core.role = core.ROLE_FOLLOWER
        local sent = {}
        core.links = { {
            state = "ready", slot = 1, peer_name = "leader",
            isReady = function() return true end,
            isClosed = function() return false end,
            allowSilence = function() end,
            close = function() end,
            send = function(_, kind, fields) sent[#sent+1] = { kind, fields } return true end,
        } }
        unit:openDocument{ page_count = 300 }
        core.reader.gotoPage(page)
        -- What the leader last told it: where the leader stands, which half
        -- of the spread this is, and what one turn moves the pair by.
        core.leader_page = page - 1
        core.my_slot = 1
        core.spread_step = 2
        core.assigned_page = page
        return unit, core, sent
    end

    --- How many of a kind were sent, whatever else went with them.
    local function count(sent, kind)
        local total = 0
        for _, message in ipairs(sent) do
            if message[1] == kind then total = total + 1 end
        end
        return total
    end

    T.it("moves this device at once rather than waiting to be told", function()
        local unit, core, sent = follower(11)
        T.assertTrue(core:handleRelativeTurn(1))
        T.assertEquals(core.reader.getPage(), 13,
            "the device the reader tapped did not move")
        T.assertEquals(count(sent, Protocol.TURN), 1, "the leader was not asked to follow")
        core.role = core.ROLE_OFF
    end)

    T.it("does not then report that move back to the leader as a jump", function()
        -- The page came from the leader's own arithmetic. Describing it to
        -- the leader as somewhere the reader went is a loop.
        local unit, core, sent = follower(11)
        core:handleRelativeTurn(1)
        core:onPageChanged(core.reader.getPage())
        for _, message in ipairs(sent) do
            T.assertTrue(message[1] ~= Protocol.GOTO,
                "the guess was reported back as a jump, which moves the pair twice")
        end
        core.role = core.ROLE_OFF
    end)

    T.it("keeps still near the end of the book, where the leader would refuse", function()
        -- A guess that has to be taken back is worse than one not made.
        local unit, core, sent = follower(300)
        core.leader_page = 299
        core:handleRelativeTurn(1)
        T.assertEquals(core.reader.getPage(), 300,
            "it guessed past the end of the book and would be pulled back")
        core.role = core.ROLE_OFF
    end)

    T.it("keeps still until the leader has told it where it stands", function()
        local unit, core, sent = follower(11)
        core.leader_page, core.my_slot, core.spread_step = nil, nil, nil
        core:handleRelativeTurn(1)
        T.assertEquals(core.reader.getPage(), 11,
            "it guessed from numbers it did not have")
        T.assertEquals(count(sent, Protocol.TURN), 1, "and it should still ask")
        core.role = core.ROLE_OFF
    end)

    T.it("does not move at all when a follower is kept as a display", function()
        local unit, core, sent = follower(11)
        core.settings.follower_can_turn = false
        core:handleRelativeTurn(1)
        T.assertEquals(core.reader.getPage(), 11)
        T.assertEquals(count(sent, Protocol.TURN), 0,
            "a follower kept as a display should not move the pair")
        core.settings.follower_can_turn = true
        core.role = core.ROLE_OFF
    end)
end)

T.describe("a book asked for over a link that goes", function()
    --[[
    Straight out of a reader's log. Asked for a book at 18:42:22; "link
    closed: peer stopped responding" at 18:42:28, six seconds later, which is
    the heartbeat timeout to the second; back together at 18:42:33; and then
    at 18:42:52 an alert about the other device having stopped sending -- a
    device that had been sitting there reconnected for nineteen seconds.

    Two faults in one sequence. The leader goes quiet while it finds a book
    and opens it, and was being written off for it. And the request outlived
    the link it was made on, so it blocked the next one and then blamed the
    wrong thing.
    ]]
    T.it("forgives the other device for going quiet while it finds the book", function()
        reset()
        local granted = 0
        local link = {
            state = "ready", slot = 1, peer_name = "leader",
            isReady = function() return true end,
            isClosed = function() return false end,
            close = function() end,
            allowSilence = function() granted = granted + 1 end,
            send = function() return true end,
        }
        Core.role = Core.ROLE_FOLLOWER
        Core.settings.sync_books = true
        Core.links = { link }
        Core.book_request, Core.book_receiver = nil, nil
        T.assertTrue(Core:requestBook{ file = "/books/big.epub", digest = "", title = "Big" })
        T.assertTrue(granted > 0,
            "a device told to go and find a book was given no time to do it")
        Core.role = Core.ROLE_OFF
        Core.links = {}
        Core.book_request = nil
    end)

    T.it("gives up on the book when the link goes, rather than blaming it later", function()
        reset()
        Core.book_request = { file = "/books/big.epub", title = "Big", started = Util.now() }
        Core:onLinkClosed(nil, "peer stopped responding")
        T.assertNil(Core.book_request,
            "the request outlived its link and would block the next one")
    end)

    T.it("names the book it gave up on", function()
        -- The log read "gave up on  after 30 seconds": `title` is often the
        -- empty string rather than absent, and `or` does not step over that.
        reset()
        local lines = {}
        local was_log = Core.hooks.log
        Core.hooks.log = function(...)
            local parts = {}
            for index = 1, select("#", ...) do parts[#parts+1] = tostring((select(index, ...))) end
            lines[#lines+1] = table.concat(parts, " ")
        end
        Core.book_request = { file = "/books/big.epub", title = "", started = 0 }
        Core:checkBookRequest()
        Core.hooks.log = was_log
        T.assertMatch(table.concat(lines, " | "), "gave up on /books/big%.epub")
    end)
end)

os.exit(T.run())
