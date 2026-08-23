--[[--
Two real KOReaders, on one machine, with Duo between them.

Everything else in `spec/` runs against a KOReader that this repository
wrote itself. That harness is fast and can force states a real reader will
not reach on demand, and it has earned its place -- but it is a model, and
a model is wrong in ways nobody notices until a bug hides in the gap.
Several have: a relayout that kept the page number steady, a file system
where every folder was a file, a document torn down through the wrong hook.
Each of those made a real bug invisible to a test that looked like it
covered it.

So this file runs the real thing. Two KOReader processes, each with its own
settings folder, each with Duo and a small control plugin installed, talking
to each other over a real socket and to the test over another. What is under
test here is precisely what the model cannot promise: that KOReader behaves
the way the model says it does.

Slow, and it needs a KOReader to point at, so it is not part of `make test`:

    make real KOREADER=/path/to/koreader

@module spec.real_spec
--]]--

local T = require("spec/testrunner")
local socket = require("socket")
local Controller = require("spec/harness/controller")

local KOREADER = os.getenv("KOREADER_DIR")
local WORK = (os.getenv("DUO_LOG_DIR") or "/tmp") .. "/duo-real"
local BOOKS = WORK .. "/books"
local DUO_PORT = 19990

if not KOREADER or KOREADER == "" then
    print("# KOREADER_DIR is not set — skipping the real-KOReader tests")
    return 0
end
if not io.open(KOREADER .. "/reader.lua", "r") then
    print("# no KOReader at " .. KOREADER .. " — skipping the real-KOReader tests")
    return 0
end

--[[--
Refuses to run against a KOReader that already has a Duo inside it.

KOReader scans its own `plugins` folder before the one `KO_HOME` points at,
so a copy left in the installation wins over the copy under test -- and the
tests then quietly measure whatever was there before. That cost a long
while once: a crash was reproduced, diagnosed, fixed, and went on
reproducing, because the fix was being read from a file nobody was running.

Said rather than deleted. Reaching into somebody's KOReader and removing
things from it is not a test runner's business.
--]]--
local stale = KOREADER .. "/plugins/duo.koplugin"
if io.open(stale .. "/main.lua", "r") then
    print("# there is already a Duo inside " .. KOREADER)
    print("# remove " .. stale .. " — it would be loaded instead of the one under test")
    return 1
end

--------------------------------------------------------------------------
-- Two installations, side by side
--------------------------------------------------------------------------

local function shell(command)
    return os.execute(command) == 0 or os.execute(command) == true
end

--- A book with enough words in it to paginate into something worth turning.
local function writeBook(path)
    local file = assert(io.open(path, "wb"))
    local paragraph = {}
    for index = 1, 40 do
        paragraph[index] = ("This is sentence %d of a book that exists only to be paginated."):format(index)
    end
    local text = table.concat(paragraph, " ")
    for _ = 1, 60 do
        file:write(text, "\n\n")
    end
    file:close()
end

os.execute(("rm -rf %q"):format(WORK))
os.execute(("mkdir -p %q"):format(BOOKS))
writeBook(BOOKS .. "/spread.txt")

--- Everything one device needs on disk: its own settings, its own plugins.
local function install(name)
    local home = ("%s/%s"):format(WORK, name)
    os.execute(("mkdir -p %q"):format(home .. "/plugins"))
    -- Copied rather than linked: KOReader walks the plugin folder, and a
    -- link into the working tree would have both devices sharing one.
    os.execute(("cp -r %q %q"):format("duo.koplugin", home .. "/plugins/"))
    os.execute(("cp -r %q %q"):format("spec/real/duocontrol.koplugin", home .. "/plugins/"))
    return home
end

--[[--
The command that starts one KOReader.

`KO_HOME` is what keeps the two apart: settings, history and plugins all
hang off it, so two instances on one machine do not tread on each other.
Xvfb because the emulator wants a display and there is not one; the reader
is drawing to a screen nobody looks at, which is fine, because what is being
watched is what it does rather than what it shows.
--]]--
local function launcher(name, control_port, log)
    local home = install(name)
    return ("KO_HOME=%q DUO_CONTROL_PORT=%d DUO_DEVICE_NAME=%q DUO_PLUGIN_DIR=%q " ..
        "xvfb-run -a %q/koreader.sh %q >%q 2>&1 &"):format(
        home, control_port, name, home .. "/plugins/duo.koplugin",
        KOREADER, BOOKS, log)
end

local controller = Controller.new{ first_port = 18500, launcher = launcher }
local leader = controller:spawn("real-leader")
local follower = controller:spawn("real-follower")

local function callLeader(code) return controller:call(leader, code) end
local function callFollower(code) return controller:call(follower, code) end

--- Puts both devices in the book, paired, and waits for the link.
local function connectPair()
    callLeader("Core:stop('reset')")
    callFollower("Core:stop('reset')")

    for _, device in ipairs({ leader, follower }) do
        controller:call(device, ("Core.settings.token = %q"):format("R3AL01"))
        controller:call(device, ("Core.settings.port = %d"):format(DUO_PORT))
        controller:call(device, ("Core.settings.peer_port = %d"):format(DUO_PORT))
        controller:call(device, "Core.settings.mode = 'spread'")
        controller:call(device, "Core.settings.follower_can_turn = true")
        controller:call(device, "Core.settings.match_typography = true")
        controller:call(device, ("D:openDocument(%q)"):format(BOOKS .. "/spread.txt"))
    end

    -- Opening a book in a real reader is not instant.
    for _, device in ipairs({ leader, follower }) do
        controller:assertEventually(device, "tostring(D:getPage() ~= nil)", "true",
            "the book never opened", 30)
    end

    callLeader("Core:start('leader')")
    callFollower(("Core:start('follower', { host = '127.0.0.1', port = %d })"):format(DUO_PORT))
    controller:assertEventually(leader, "Core:isConnected()", true, "the leader never saw the follower", 30)
    controller:assertEventually(follower, "Core:isConnected()", true, "the follower never connected", 30)
end

--------------------------------------------------------------------------
-- Tests
--------------------------------------------------------------------------

T.describe("two real KOReaders", function()
    T.it("loads Duo and reaches its engine", function()
        T.assertEquals(callLeader("tostring(Core ~= nil)"), "true",
            "Duo's engine is not loaded in a real KOReader")
        T.assertEquals(callLeader("tostring(Duo ~= nil)"), "true",
            "the Duo plugin did not attach to the reader")
    end)

    T.it("pairs one to the other over a real socket", function()
        connectPair()
        T.assertEquals(callLeader("Core.role"), "leader")
        T.assertEquals(callFollower("Core.role"), "follower")
    end)

    T.it("puts the follower on the page after the leader's", function()
        connectPair()
        callLeader("D:jumpToPage(10)")
        controller:assertEventually(leader, "D:getPage()", 10, "the leader did not move", 20)
        controller:assertEventually(follower, "D:getPage()", 11,
            "the follower is not showing the next page", 20)
    end)

    T.it("moves both devices by two when the leader turns a page", function()
        connectPair()
        callLeader("D:jumpToPage(10)")
        controller:assertEventually(follower, "D:getPage()", 11, nil, 20)

        callLeader("D:tapForward()")
        controller:assertEventually(leader, "D:getPage()", 12,
            "the leader must skip the page the follower showed", 20)
        controller:assertEventually(follower, "D:getPage()", 13, nil, 20)
    end)

    T.it("brings the leader along when the follower follows a link", function()
        -- The bug this exists for was invisible to the simulated devices for
        -- a long time, because they moved a page the way the model said a
        -- page moves rather than the way crengine moves one.
        connectPair()
        callLeader("D:jumpToPage(10)")
        controller:assertEventually(follower, "D:getPage()", 11, nil, 20)

        callFollower("D:jumpToPage(40)")
        controller:assertEventually(leader, "D:getPage()", 39,
            "the leader stayed behind when the follower jumped", 20)
        controller:assertEventually(follower, "D:getPage()", 40, nil, 20)
    end)

    T.it("keeps the reader where they were when the font size changes", function()
        --[[
        The one the model could not test at all. It kept the page number
        steady across a relayout, which is the one thing a relayout never
        does, so the test passed whether the bug was there or not. A real
        crengine holds an xpointer and works the page out again, which is
        what makes this worth asking of the real thing.
        ]]
        connectPair()
        callLeader("D:jumpToPage(20)")
        controller:assertEventually(follower, "D:getPage()", 21, nil, 20)
        local before = controller:number(leader, "D:getPageCount()")

        callLeader("D:setFontSize(26)")
        controller:assertEventually(follower, "UI.document.configurable.font_size", 26,
            "the follower never took the new size", 30)

        -- Both devices agreeing on the book's length is what makes the page
        -- numbers below mean anything at all.
        controller:assertEventually(follower, "D:getPageCount()",
            controller:number(leader, "D:getPageCount()"),
            "the two readers disagree about how long the book is", 30)

        local after = controller:number(leader, "D:getPageCount()")
        T.assertNotEquals(after, before, "the font size change did not relayout the book")

        local expected = math.floor(20 * after / before + 0.5)
        local landed = controller:number(leader, "D:getPage()")
        T.assertTrue(math.abs(landed - expected) <= 3,
            ("the reader was thrown from about %d to %d"):format(expected, landed))

        controller:assertEventually(follower, "D:getPage()", landed + 1,
            "the follower did not settle next to the leader after the relayout", 20)
    end)

    T.it("asks the styles question on one device and answers it for both", function()
        --[[
        Reported from a pair of Kindles: changing embedded styles meant
        answering a "reload the document?" box on both devices and then
        waiting for both to settle.

        KOReader asks when a style change has left crengine unable to render
        the book correctly without building it again. Duo makes the change on
        both, so KOReader wants to ask on both -- and the two answers need
        not agree, which is worse than tiresome: a book built one way here
        and another way there paginates differently, and that is the one
        thing a spread cannot survive.

        Asked here at the point KOReader hands over, rather than by hoping a
        fixture provokes it: whether a given change leaves the DOM stale is
        crengine's business and a plain book often does not. What is under
        test is Duo's half.
        ]]
        connectPair()
        callLeader("D:jumpToPage(20)")
        controller:assertEventually(follower, "D:getPage()", 21, nil, 20)

        callLeader("D:setFontSize(26)")
        controller:assertEventually(follower, "UI.document.configurable.font_size", 26,
            "the follower never took the new size", 30)
        controller:assertEventually(follower, "Core:isFollowingTypography()", true,
            "the follower does not know the change came from the other device", 20)
        T.assertEquals(callLeader("tostring(Core:isFollowingTypography())"), "false",
            "the device the reader is holding thinks it is following the other one")

        local leader_was = callLeader("tostring(UI)")
        local follower_was = callFollower("tostring(UI)")

        -- What KOReader does when it finds the DOM stale -- on both, because
        -- the change was made on both.
        callLeader("UI.rolling:showSuggestReloadConfirmBox()")
        callFollower("UI.rolling:showSuggestReloadConfirmBox()")
        controller:assertEventually(leader, "D:isAskingToReload()", true,
            "the device the reader is holding never asked", 10)
        T.assertEquals(callFollower("tostring(D:isAskingToReload())"), "false",
            "the reader was asked the same question on both devices")

        -- Answered once, on the device being held.
        T.assertEquals(callLeader("tostring(D:answerReload(true))"), "true")

        -- Rebuilding a book makes a new reader, so the object is a new one.
        controller:assertEventually(leader,
            ("tostring(tostring(UI) ~= %q)"):format(leader_was), "true",
            "the device that was answered did not rebuild the book", 40)
        controller:assertEventually(follower,
            ("tostring(tostring(UI) ~= %q)"):format(follower_was), "true",
            "the other device was not brought along", 40)

        -- And the two must still agree about the book, which is the reason
        -- for carrying the answer across in the first place.
        controller:assertEventually(follower, "D:getPageCount()",
            controller:number(leader, "D:getPageCount()"),
            "the two readers disagree about the book after rebuilding it", 40)
    end)

    T.it("shows its status without taking the reader down", function()
        -- Reported from a real device and never reproduced against the
        -- model, which is reason enough to ask the real thing.
        connectPair()
        local outcome = callLeader(
            "(function() local ok, err = xpcall(function() Duo:showStatus() end, " ..
            "function(m) return tostring(m) .. ' | ' .. debug.traceback('', 2):gsub('\\n', ' / ') end) " ..
            "return ok and 'ok' or tostring(err) end)()")
        T.assertEquals(outcome, "ok",
            "the status screen crashed a real KOReader: " .. outcome)

        --[[
        And every line has to be readable, not merely survivable. Each line
        is built behind a pcall, so a line that throws is replaced rather
        than fatal -- which means a screen quietly full of apologies would
        pass a test that only asked whether it crashed. The peer line is the
        one that used to throw, so it is the one worth insisting on.
        ]]
        local text = callLeader(
            "(function() local shown = UIManager._window_stack[#UIManager._window_stack] " ..
            "local widget = shown and shown.widget " ..
            "return tostring(widget and (widget.text or (widget.movable and 'shown')) or 'nothing') end)()")
        T.assertTrue(not text:find("could not be read"),
            "a line of the status screen could not be built: " .. text)
        -- The peer line by its shape, not by the name in it: what a device
        -- calls itself is the emulator's business, and on this one both
        -- readers honestly report the same model.
        T.assertMatch(text, "Peer: .+%(.+%)",
            "the status screen does not describe the device it is connected to: " .. text)
    end)
end)

local exit_code = T.run()
controller:shutdown()
socket.sleep(1)
os.execute("pkill -f 'DUO_CONTROL_PORT' >/dev/null 2>&1")
os.exit(exit_code)
