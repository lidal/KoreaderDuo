--[[--
Two devices with the same folder and different books in it.

This needs a setup the other suites cannot provide. Both readers keep their
library at the same path — that is the whole premise of a shared book list —
but here they share a filesystem, so "the same path" would be the same
folder and there would be nothing to copy.

The follower is therefore run inside its own mount namespace with its own
folder mounted over that path. Same path on both, different books in it,
which is exactly the situation on two Kindles.

Needs root and `unshare`; skips itself otherwise.
--]]--

local T = require("spec/testrunner")
local socket = require("socket")
local Controller = require("spec/harness/controller")

local LOG_DIR = os.getenv("DUO_LOG_DIR") or "/tmp"
local SHARED = LOG_DIR .. "/duo-library"        -- the path both devices use
local FOLLOWER_SRC = LOG_DIR .. "/duo-library-follower" -- what the follower starts with
local DUO_PORT = 19975

local function shell(command)
    local pipe = io.popen(command .. " 2>&1; echo EXIT=$?")
    local output = pipe:read("*a")
    pipe:close()
    return output:match("EXIT=(%d+)") == "0", output
end

local function canIsolate()
    if not shell("id -u | grep -q '^0$'") then return false, "not root" end
    if not shell("command -v unshare") then return false, "unshare missing" end
    if not shell("unshare -m sh -c 'mount -t tmpfs none /mnt'") then
        return false, "mount namespaces unavailable"
    end
    return true
end

local function makeBook(directory, name, seed)
    os.execute(("mkdir -p %q"):format(directory))
    local file = assert(io.open(directory .. "/" .. name, "wb"))
    local parts = {}
    for index = 1, 2000 + seed * 500 do
        parts[index] = string.char((index * (seed + 3)) % 256)
    end
    file:write(table.concat(parts))
    file:close()
end

local possible, why = canIsolate()
if not possible then
    print("# " .. why .. " — skipping the library tests")
    return 0
end

-- Six books at the shared path (what the leader has), two of them also in
-- the folder the follower will mount over it.
os.execute(("rm -rf %q %q"):format(SHARED, FOLLOWER_SRC))
for index = 1, 6 do
    makeBook(SHARED, ("book%02d.epub"):format(index), index)
end
os.execute(("mkdir -p %q"):format(FOLLOWER_SRC))
for _, index in ipairs({ 1, 2 }) do
    makeBook(FOLLOWER_SRC, ("book%02d.epub"):format(index), index)
end

local controller = Controller.new{ first_port = 18300 }
local leader = controller:spawn("lib-leader")
-- The follower sees its own two books at the shared path and nothing else.
local follower = controller:spawn("lib-follower", {
    prefix = ("unshare -m sh -c 'mount -t tmpfs none %q && cp -a %q/. %q/ && exec \"$0\" \"$@\"' ")
        :format(SHARED, FOLLOWER_SRC, SHARED),
})

local function callLeader(code) return controller:call(leader, code) end
local function callFollower(code) return controller:call(follower, code) end

--- Both devices browsing the same path, connected, with syncing on.
local function browseTogether(options)
    options = options or {}
    callLeader("Core:stop('reset')")
    callFollower("Core:stop('reset')")
    for _, device in ipairs({ leader, follower }) do
        controller:call(device, ("D:openFileManager{ path = %q, perpage = 3, real_folder = true }"):format(SHARED))
        controller:call(device, "Core.settings.token = 'L1BR41'")
        controller:call(device, ("Core.settings.port = %d"):format(DUO_PORT))
        controller:call(device, ("Core.settings.peer_port = %d"):format(DUO_PORT))
        controller:call(device, "Core.settings.discovery_port = 19976")
        controller:call(device, "Core.settings.share_browser = true")
        controller:call(device, ("Core.settings.sync_library = %s"):format(
            tostring(options.sync ~= false)))
    end
    -- A clean slate, so what a scenario shows the user is its own doing.
    callFollower("UIManager.shown_log = {}")
    callLeader("Core:start('leader')")
    callFollower(("Core:start('follower', { host = '127.0.0.1', port = %d })"):format(DUO_PORT))
    controller:assertEventually(leader, "Core:isConnected()", true, "never connected")
    controller:assertEventually(follower, "Core:isConnected()", true, "never connected")
    callLeader("Core:broadcastBrowser()")
end

--- Whether the device has told its user the two halves will not line up.
local WARNED = "(function() for _, m in ipairs(UIManager.shown_log) do if tostring(m.text):find('not line up') then return true end end return false end)()"

--- The books a device can see, asked of the device itself: the follower's
--- folder is inside its own mount namespace and invisible from here.
local function booksOn(device)
    return controller:call(device,
        "(function() local n = {} for _, e in ipairs(Core.browser.getFiles()) do n[#n+1] = e.name end table.sort(n) return table.concat(n, ',') end)()")
end

T.describe("the two devices start with different books", function()
    T.it("really is a different folder at the same path", function()
        browseTogether{ sync = false }
        T.assertEquals(booksOn(leader),
            "book01.epub,book02.epub,book03.epub,book04.epub,book05.epub,book06.epub")
        T.assertEquals(booksOn(follower), "book01.epub,book02.epub")
        T.assertEquals(callLeader("Core.browser.getState().path"),
            callFollower("Core.browser.getState().path"),
            "the premise is that both call the folder the same thing")
    end)

    T.it("fetches nothing while the option is off", function()
        socket.sleep(2)
        T.assertEquals(booksOn(follower), "book01.epub,book02.epub")
        T.assertEquals(callFollower("Core:isSyncingLibrary()"), "false")
    end)

    T.it("says so, since nothing is going to come along and fix it", function()
        T.assertEquals(callFollower(WARNED), "true",
            "the halves cannot line up and no sync is on its way to help")
    end)
end)

T.describe("keeping the whole library in step", function()
    T.it("fetches every book the other device has and this one lacks", function()
        browseTogether()
        controller:assertEventually(follower, "Core:isSyncingLibrary()", false,
            "the library sync never finished", 60)
        T.assertEquals(booksOn(follower), booksOn(leader),
            "the two folders still do not hold the same books")
    end)

    T.it("does not complain about a mismatch it is busy repairing", function()
        T.assertEquals(callFollower(WARNED), "false",
            "it warned that the halves would not line up, then lined them up")
    end)

    T.it("brings them across whole, not just by name", function()
        -- Sizes are asked of each device; the bytes themselves are checked
        -- in booktransfer_spec, which can see both ends.
        local sizes = "(function() local s = {} for _, e in ipairs(Core.browser.getFiles()) do s[#s+1] = e.name .. ':' .. e.size end table.sort(s) return table.concat(s, ',') end)()"
        T.assertEquals(controller:call(follower, sizes), controller:call(leader, sizes))
    end)

    T.it("lines the two halves of the list up once it has", function()
        -- No prodding from here: the list is a different length than it was
        -- when the leader handed out the pages, so the follower has to ask
        -- again by itself once the books have landed.
        controller:assertEventually(follower, "UI.file_chooser.page", 2,
            "the follower should be on the second screenful", 20)
        T.assertEquals(controller:call(leader, "table.concat(D:visibleBooks(), ',')"),
            "book01.epub,book02.epub,book03.epub")
        T.assertEquals(controller:call(follower, "table.concat(D:visibleBooks(), ',')"),
            "book04.epub,book05.epub,book06.epub")
    end)

    T.it("does nothing more once the folders match", function()
        callLeader("Core:broadcastBrowser()")
        socket.sleep(2)
        T.assertEquals(callFollower("Core:isSyncingLibrary()"), "false",
            "it went looking for books again with nothing missing")
    end)

    T.it("fetches a book on demand when the shelf holds only a stand-in", function()
        -- The stand-in machinery needs an archive library this harness has
        -- not got, so the file is declared a stand-in rather than built as
        -- one. What is under test is the rest: a tap turns into a request,
        -- the book lands over the top of what was there, and it opens.
        local target = SHARED .. "/book05.epub"
        callFollower("Core.isStub = function(self, path) return path == '" .. target .. "' end")
        callFollower("UIManager.shown_log = {}")
        callFollower(("D:openFile(%q)"):format(target))

        controller:assertEventually(follower,
            "(function() for _, m in ipairs(UIManager.shown_log) do if m.class == 'ShowReader' then return m.text end end return '' end)()",
            target, "the fetched book did not open", 30)
        T.assertEquals(callFollower(("tostring(D:sizeOf(%q))"):format(target)),
            callLeader(("tostring(D:sizeOf(%q))"):format(target)),
            "what landed is not the book the other device has")
        callFollower("Core.isStub = nil")
    end)

    T.it("says so when it cannot build the cover-only stand-ins that were asked for", function()
        --[[
        Covers-first exists so a shelf of books does not have to cross a
        slow link. When the stand-in cannot be built — no archive library
        in this build, a book that is not an EPUB — the whole book is sent
        instead, which is the right fallback and the opposite of what was
        asked for. Doing that in silence looked exactly like covers simply
        not working.
        ]]
        browseTogether()
        callLeader("Core.warned_no_stub = nil")
        callLeader("UIManager.shown_log = {}")
        callFollower("Core.settings.covers_first = true")
        callFollower("Core:getReadyLinks()[1]:send(Protocol.BOOK_REQ," ..
            " { file = 'book06.epub', digest = '', lib = 1, stub = 1 })")

        controller:assertEventually(leader,
            "(function() for _, m in ipairs(UIManager.shown_log) do if tostring(m.text):find('cover%-only stand%-ins') then return true end end return false end)()",
            true, "the fallback to whole books happened without a word")
    end)

    T.it("copies books and nothing else, whatever else is in the folder", function()
        --[[
        The shared folder is only ever whichever one the leader happens to
        be looking at, so a wrong turn into a downloads folder is an easy
        mistake to make — and the file browser hides what a reader cannot
        open only until somebody turns that setting off. Copying a firmware
        image across an ad-hoc cell at a few hundred kilobytes a second is
        not a mistake worth being able to make.

        These land in the folder after the follower's namespace was built, so
        only the leader can see them: exactly the shape of the real case.
        ]]
        makeBook(SHARED, "update.bin", 7)
        makeBook(SHARED, "holiday-photo.jpg", 8)

        browseTogether()
        callLeader("Core.browser.refresh()")
        callLeader("Core:broadcastBrowser()")
        controller:assertEventually(follower, "Core:isSyncingLibrary()", false,
            "the sync never finished", 60)

        T.assertMatch(booksOn(leader), "update%.bin")
        local on_follower = booksOn(follower)
        T.assertTrue(not on_follower:find("update%.bin"),
            "a firmware image was copied to the other device")
        T.assertTrue(not on_follower:find("holiday%-photo"),
            "a photograph was copied to the other device")
        T.assertMatch(on_follower, "book06%.epub", "the books should still come across")

        os.remove(SHARED .. "/update.bin")
        os.remove(SHARED .. "/holiday-photo.jpg")
    end)

    T.it("refuses to hand one over even when asked for by name", function()
        -- The listing is a courtesy; this is the gate. Whatever a peer
        -- sends, the device that would open the file and put its bytes on
        -- the wire checks for itself.
        makeBook(SHARED, "update.bin", 7)
        browseTogether()
        callLeader("Core.browser.refresh()")
        callFollower("UIManager.shown_log = {}")
        callFollower("Core:getReadyLinks()[1]:send(Protocol.BOOK_REQ," ..
            " { file = 'update.bin', digest = '', lib = 1 })")
        socket.sleep(1)
        T.assertEquals(callFollower(("tostring(D:sizeOf(%q))"):format(SHARED .. "/update.bin")),
            "nil", "the leader handed over a file that is not a book")
        os.remove(SHARED .. "/update.bin")
    end)

    T.it("will not hand over anything outside the shared folder", function()
        callFollower("UIManager.shown_log = {}")
        -- A traversal, and a name that is simply not in the folder.
        for _, wanted in ipairs({ "../../etc/passwd", "/etc/passwd", "not-a-book.epub" }) do
            callFollower("Core.book_request = { file = 'x', library = true }")
            callFollower(("Core:getReadyLinks()[1]:send('BOOK_REQ', { file = %q, lib = 1 })"):format(wanted))
            socket.sleep(0.4)
            T.assertEquals(callFollower("tostring(Core.book_receiver)"), "nil",
                "the leader offered " .. wanted)
            callFollower("Core.book_request = nil")
        end
    end)
end)

local exit_code = T.run()
controller:shutdown()
os.execute(("rm -rf %q %q"):format(SHARED, FOLLOWER_SRC))
os.exit(exit_code)
