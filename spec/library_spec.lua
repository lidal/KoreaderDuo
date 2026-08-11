--[[--
Two devices with the same folder and different books in it.

This needs a setup the other suites cannot provide. Both readers keep their
library at the same path — that is the whole premise of a shared book list —
but here they share a filesystem, so "the same path" would be the same
folder and there would be nothing to copy.

The slave is therefore run inside its own mount namespace with its own
folder mounted over that path. Same path on both, different books in it,
which is exactly the situation on two Kindles.

Needs root and `unshare`; skips itself otherwise.
--]]--

local T = require("spec/testrunner")
local socket = require("socket")
local Controller = require("spec/harness/controller")

local LOG_DIR = os.getenv("DUO_LOG_DIR") or "/tmp"
local SHARED = LOG_DIR .. "/duo-library"        -- the path both devices use
local SLAVE_SRC = LOG_DIR .. "/duo-library-slave" -- what the slave starts with
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

-- Six books at the shared path (what the master has), two of them also in
-- the folder the slave will mount over it.
os.execute(("rm -rf %q %q"):format(SHARED, SLAVE_SRC))
for index = 1, 6 do
    makeBook(SHARED, ("book%02d.epub"):format(index), index)
end
os.execute(("mkdir -p %q"):format(SLAVE_SRC))
for _, index in ipairs({ 1, 2 }) do
    makeBook(SLAVE_SRC, ("book%02d.epub"):format(index), index)
end

local controller = Controller.new{ first_port = 18300 }
local master = controller:spawn("lib-master")
-- The slave sees its own two books at the shared path and nothing else.
local slave = controller:spawn("lib-slave", {
    prefix = ("unshare -m sh -c 'mount -t tmpfs none %q && cp -a %q/. %q/ && exec \"$0\" \"$@\"' ")
        :format(SHARED, SLAVE_SRC, SHARED),
})

local function callMaster(code) return controller:call(master, code) end
local function callSlave(code) return controller:call(slave, code) end

--- Both devices browsing the same path, connected, with syncing on.
local function browseTogether(options)
    options = options or {}
    callMaster("Core:stop('reset')")
    callSlave("Core:stop('reset')")
    for _, device in ipairs({ master, slave }) do
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
    callSlave("UIManager.shown_log = {}")
    callMaster("Core:start('master')")
    callSlave(("Core:start('slave', { host = '127.0.0.1', port = %d })"):format(DUO_PORT))
    controller:assertEventually(master, "Core:isConnected()", true, "never connected")
    controller:assertEventually(slave, "Core:isConnected()", true, "never connected")
    callMaster("Core:broadcastBrowser()")
end

--- Whether the device has told its user the two halves will not line up.
local WARNED = "(function() for _, m in ipairs(UIManager.shown_log) do if tostring(m.text):find('not line up') then return true end end return false end)()"

--- The books a device can see, asked of the device itself: the slave's
--- folder is inside its own mount namespace and invisible from here.
local function booksOn(device)
    return controller:call(device,
        "(function() local n = {} for _, e in ipairs(Core.browser.getFiles()) do n[#n+1] = e.name end table.sort(n) return table.concat(n, ',') end)()")
end

T.describe("the two devices start with different books", function()
    T.it("really is a different folder at the same path", function()
        browseTogether{ sync = false }
        T.assertEquals(booksOn(master),
            "book01.epub,book02.epub,book03.epub,book04.epub,book05.epub,book06.epub")
        T.assertEquals(booksOn(slave), "book01.epub,book02.epub")
        T.assertEquals(callMaster("Core.browser.getState().path"),
            callSlave("Core.browser.getState().path"),
            "the premise is that both call the folder the same thing")
    end)

    T.it("fetches nothing while the option is off", function()
        socket.sleep(2)
        T.assertEquals(booksOn(slave), "book01.epub,book02.epub")
        T.assertEquals(callSlave("Core:isSyncingLibrary()"), "false")
    end)

    T.it("says so, since nothing is going to come along and fix it", function()
        T.assertEquals(callSlave(WARNED), "true",
            "the halves cannot line up and no sync is on its way to help")
    end)
end)

T.describe("keeping the whole library in step", function()
    T.it("fetches every book the other device has and this one lacks", function()
        browseTogether()
        controller:assertEventually(slave, "Core:isSyncingLibrary()", false,
            "the library sync never finished", 60)
        T.assertEquals(booksOn(slave), booksOn(master),
            "the two folders still do not hold the same books")
    end)

    T.it("does not complain about a mismatch it is busy repairing", function()
        T.assertEquals(callSlave(WARNED), "false",
            "it warned that the halves would not line up, then lined them up")
    end)

    T.it("brings them across whole, not just by name", function()
        -- Sizes are asked of each device; the bytes themselves are checked
        -- in booktransfer_spec, which can see both ends.
        local sizes = "(function() local s = {} for _, e in ipairs(Core.browser.getFiles()) do s[#s+1] = e.name .. ':' .. e.size end table.sort(s) return table.concat(s, ',') end)()"
        T.assertEquals(controller:call(slave, sizes), controller:call(master, sizes))
    end)

    T.it("lines the two halves of the list up once it has", function()
        -- No prodding from here: the list is a different length than it was
        -- when the master handed out the pages, so the slave has to ask
        -- again by itself once the books have landed.
        controller:assertEventually(slave, "UI.file_chooser.page", 2,
            "the slave should be on the second screenful", 20)
        T.assertEquals(controller:call(master, "table.concat(D:visibleBooks(), ',')"),
            "book01.epub,book02.epub,book03.epub")
        T.assertEquals(controller:call(slave, "table.concat(D:visibleBooks(), ',')"),
            "book04.epub,book05.epub,book06.epub")
    end)

    T.it("does nothing more once the folders match", function()
        callMaster("Core:broadcastBrowser()")
        socket.sleep(2)
        T.assertEquals(callSlave("Core:isSyncingLibrary()"), "false",
            "it went looking for books again with nothing missing")
    end)

    T.it("fetches a book on demand when the shelf holds only a stand-in", function()
        -- The stand-in machinery needs an archive library this harness has
        -- not got, so the file is declared a stand-in rather than built as
        -- one. What is under test is the rest: a tap turns into a request,
        -- the book lands over the top of what was there, and it opens.
        local target = SHARED .. "/book05.epub"
        callSlave("Core.isStub = function(self, path) return path == '" .. target .. "' end")
        callSlave("UIManager.shown_log = {}")
        callSlave(("D:openFile(%q)"):format(target))

        controller:assertEventually(slave,
            "(function() for _, m in ipairs(UIManager.shown_log) do if m.class == 'ShowReader' then return m.text end end return '' end)()",
            target, "the fetched book did not open", 30)
        T.assertEquals(callSlave(("tostring(D:sizeOf(%q))"):format(target)),
            callMaster(("tostring(D:sizeOf(%q))"):format(target)),
            "what landed is not the book the other device has")
        callSlave("Core.isStub = nil")
    end)

    T.it("will not hand over anything outside the shared folder", function()
        callSlave("UIManager.shown_log = {}")
        -- A traversal, and a name that is simply not in the folder.
        for _, wanted in ipairs({ "../../etc/passwd", "/etc/passwd", "not-a-book.epub" }) do
            callSlave("Core.book_request = { file = 'x', library = true }")
            callSlave(("Core:getReadyLinks()[1]:send('BOOK_REQ', { file = %q, lib = 1 })"):format(wanted))
            socket.sleep(0.4)
            T.assertEquals(callSlave("tostring(Core.book_receiver)"), "nil",
                "the master offered " .. wanted)
            callSlave("Core.book_request = nil")
        end
    end)
end)

local exit_code = T.run()
controller:shutdown()
os.execute(("rm -rf %q %q"):format(SHARED, SLAVE_SRC))
os.exit(exit_code)
