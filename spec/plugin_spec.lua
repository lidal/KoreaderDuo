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

    T.it("stops before copying a folder far too big to be a shelf", function()
        --[[
        The shared folder is whichever one the master is looking at, so a
        wrong turn is easy. Refusing and naming the number beats starting a
        multi-gigabyte pull over a link with no router on it and hoping
        somebody notices.
        ]]
        pretendBrowsing("/downloads")
        Core.settings.max_library_mb = 1
        Core:handleLibraryItem{ name = "enormous.epub", size = 40 * 1024 * 1024 }
        Core:handleLibraryEnd{}

        T.assertMatch(table.concat(device:drainMessages(), "\n"), "over Duo's 1 MB limit")
        T.assertNil(Core.library, "it should not have started fetching")
        Core.settings.max_library_mb = 512
        Core.browser = nil
    end)

    T.it("leaves the ceiling off when it is set to no limit", function()
        pretendBrowsing("/books")
        Core.settings.max_library_mb = 0
        Core:handleLibraryItem{ name = "enormous.epub", size = 40 * 1024 * 1024 }
        Core:handleLibraryEnd{}
        -- It gets as far as asking for the book, which with nothing
        -- connected is where it stops; what matters is that the ceiling
        -- never spoke up.
        T.assertTrue(not table.concat(device:drainMessages(), "\n"):find("MB limit"),
            "no limit should mean no limit")
        Core.library = nil
        Core.settings.max_library_mb = 512
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
    whose failure was final — the master's listen failed on an interface
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

    local function sleepAsMaster()
        reset()
        Core.role = Core.ROLE_MASTER
        Core:suspend()
        T.assertEquals(Core.paused_role, "master", "the role has to survive the sleep")
    end

    T.it("keeps trying until the network is really back", function()
        sleepAsMaster()
        local attempts = failingStart(2)

        Core:resume()
        T.assertEquals(attempts(), 1)
        T.assertEquals(Core.paused_role, "master", "one failure must not be the end of it")

        Core.resume_at = 0
        Core:poll()
        T.assertEquals(attempts(), 2)

        Core.resume_at = 0
        Core:poll()
        T.assertEquals(attempts(), 3, "it should have tried again")
        T.assertNil(Core.paused_role, "and stopped trying once it worked")
        Core.start = real_start
    end)

    T.it("rebuilds a link it made itself, once the radio has had its chance", function()
        -- A link with no router behind it does not survive a deep sleep:
        -- the Kindle's own Wi-Fi daemon takes the interface back. Nothing
        -- else will notice, and waiting politely means waiting for ever.
        sleepAsMaster()
        local revived = 0
        Core.hooks.reviveDirectLink = function() revived = revived + 1 end
        failingStart(99)

        Core:resume()
        T.assertEquals(revived, 0, "not on the first failure: radios are just slow")
        for _ = 1, 4 do
            Core.resume_at = 0
            Core:poll()
        end
        T.assertEquals(revived, 1, "the link should be rebuilt exactly once")
        Core.hooks.reviveDirectLink = nil
        Core.start = real_start
        Core:stop("test done")
    end)

    T.it("gives up in the end, and says so", function()
        sleepAsMaster()
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
        sleepAsMaster()
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

    T.it("names the network to join when it is hosting the link itself", function()
        --[[
        The ordinary sheet says "tap Connect to a master" and that is
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
        T.assertMatch(shown, "Join the link", "another reader does it from the menu")
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
        T.assertMatch(shown, "Join the link", "another reader can still join it")
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
