--[[--
Two native apps, one wire, one book shown across both screens.

This is the file the whole exercise is for. Everything else can be argued
about; this either works or it does not. Two separate processes, each
running the native frontend with its own headless device, joined by a
pseudo-terminal, driven by the *unmodified* `duo/core.lua` out of the
plugin. If the spread comes up here, then the claim in `FEASIBILITY.md` --
that the engine is host-agnostic and the frontend is the only thing that
has to be written -- is true rather than hopeful.

What a pty proves is the framing, the handshake and the state machine.
What it cannot prove is anything electrical. The README of the plugin is
right about that and nothing here changes it.
--]]--

local t = require("spec/testrunner")
local socket = require("socket")
local Controller = require("spec/harness/controller")
local SerialTransport = require("duo/transport_serial")
local Fixture = require("spec/fixture")

local LOG_DIR = os.getenv("DUO_LOG_DIR") or "/tmp"
local RUN = tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
local PTY_A = LOG_DIR .. "/duonative-pty-a-" .. RUN
local PTY_B = LOG_DIR .. "/duonative-pty-b-" .. RUN
local BOOK = Fixture.book("spread", 120, 60)

--------------------------------------------------------------------------
-- The wire, such as it is
--------------------------------------------------------------------------

local function carriesAByte()
    local a = SerialTransport.open(PTY_A, { skip_stty = true })
    if not a then return false end
    local b = SerialTransport.open(PTY_B, { skip_stty = true })
    if not b then a:close() return false end
    a:send("\n")
    a:flush()
    local carried = false
    local deadline = socket.gettime() + 1
    while socket.gettime() < deadline do
        if (b:receive() or "") ~= "" then carried = true break end
        socket.sleep(0.02)
    end
    a:close()
    b:close()
    return carried
end

local function startPtyPair()
    os.remove(PTY_A)
    os.remove(PTY_B)
    os.execute(("socat -d -d pty,raw,echo=0,link=%s pty,raw,echo=0,link=%s >%s/duonative-socat.log 2>&1 &")
        :format(PTY_A, PTY_B, LOG_DIR))
    -- Waited for by carrying a byte rather than by sleeping, for the
    -- reason the plugin's own serial suite gives: the symlinks appear
    -- before socat has finished wiring the ends together.
    local deadline = socket.gettime() + 10
    while socket.gettime() < deadline do
        if SerialTransport.exists(PTY_A) and SerialTransport.exists(PTY_B) then
            if carriesAByte() then return true end
        end
        socket.sleep(0.05)
    end
    return false
end

local function stopPtyPair()
    os.execute(("pkill -f 'link=%s' 2>/dev/null"):format(PTY_A))
    os.remove(PTY_A)
    os.remove(PTY_B)
end

--[[
A skip that says nothing is a pass that means nothing.

Taken straight from the plugin's serial suite, and for the same reason: a
file that quietly returns 0 when its prerequisite is missing reads in the
summary exactly like a file whose tests all passed, and that is how
something comes to be believed tested when it never ran.
]]
if not SerialTransport.isAvailable() then
    print("")
    print("!! SPREAD TESTS DID NOT RUN: this interpreter has no LuaJIT ffi.")
    return 1
end

if not startPtyPair() then
    stopPtyPair()
    print("")
    print("!! SPREAD TESTS DID NOT RUN: socat is not installed.")
    print("!! The two-device spread is UNTESTED in this run. Install socat.")
    return 1
end

--------------------------------------------------------------------------
-- Two apps
--------------------------------------------------------------------------

local controller = Controller.new{
    first_port = 19400,
    launcher = function(name, port, log, options)
        return ("LUA_PATH=%q luajit spec/instance_main.lua %s %d %s %s %q >%s 2>&1 &")
            :format("./?.lua;../?.lua;../duo.koplugin/?.lua;;",
                name, port, options.pty, options.role, BOOK, log)
    end,
}

local leader = controller:spawn("leader", { pty = PTY_A, role = "leader", book = BOOK })
local follower = controller:spawn("follower", { pty = PTY_B, role = "follower", book = BOOK })

local function connected(device)
    return controller:call(device, "Core:isConnected() and 1 or 0") == "1"
end

local function page(device)
    return tonumber(controller:call(device, "Doc and Doc:page() or -1"))
end

local function awaitConnected(timeout)
    local deadline = socket.gettime() + (timeout or 25)
    while socket.gettime() < deadline do
        if connected(leader) and connected(follower) then return true end
        socket.sleep(0.05)
    end
    return false
end

local function awaitPage(device, wanted, timeout)
    local deadline = socket.gettime() + (timeout or 12)
    local last
    while socket.gettime() < deadline do
        last = page(device)
        if last == wanted then return true end
        socket.sleep(0.05)
    end
    return false, last
end

--------------------------------------------------------------------------
-- Tests
--------------------------------------------------------------------------

t.describe("two native apps on a wire", function()
    t.it("pair, with no pairing code and nothing to connect to", function()
        t.assertTrue(awaitConnected(), "the pair never came up; see /tmp/duo-*.log")
    end)

    --[[
    `Core.role` and not `Core:get("role")`. The setting is what to come back
    as at autostart; the field is what this device is being right now, and
    they are different questions -- the setting still reads "off" on a
    device that is currently leading.
    ]]
    t.it("agree about who leads", function()
        t.assertEquals(controller:call(leader, "Core.role"), "leader")
        t.assertEquals(controller:call(follower, "Core.role"), "follower")
        t.assertEquals(controller:call(leader, "Core:isLeader() and 1 or 0"), "1")
        t.assertEquals(controller:call(follower, "Core:isFollower() and 1 or 0"), "1")
    end)

    t.it("show consecutive pages of one book", function()
        t.assertTrue(awaitConnected())
        controller:call(leader, "Reader:gotoPage(1)")
        t.assertTrue(awaitPage(leader, 1))
        local ok, got = awaitPage(follower, 2)
        t.assertTrue(ok, ("the follower should be on 2, was on %s"):format(tostring(got)))
    end)
end)

t.describe("a page turn moves both", function()
    t.it("advances the leader by the width of the spread", function()
        t.assertTrue(awaitConnected())
        controller:call(leader, "Reader:gotoPage(1)")
        t.assertTrue(awaitPage(follower, 2))

        -- A tap on the leader's right quarter: the real input path, not a
        -- call to gotoPage. This is what has to move two devices.
        controller:call(leader, "App.stack:handle{ kind = 'tap', x = 1000, y = 700 }")

        t.assertTrue(select(1, awaitPage(leader, 3)),
            "the leader should have moved by two")
        t.assertTrue(select(1, awaitPage(follower, 4)),
            "the follower should be one ahead of the leader")
    end)

    t.it("takes a tap on the follower as a request, and answers it", function()
        t.assertTrue(awaitConnected())
        controller:call(leader, "Reader:gotoPage(5)")
        t.assertTrue(awaitPage(follower, 6))

        controller:call(follower, "App.stack:handle{ kind = 'tap', x = 1000, y = 700 }")

        t.assertTrue(select(1, awaitPage(leader, 7)),
            "a follower's tap should have moved the leader")
        t.assertTrue(select(1, awaitPage(follower, 8)))
    end)

    t.it("goes backwards too", function()
        t.assertTrue(awaitConnected())
        controller:call(leader, "Reader:gotoPage(9)")
        t.assertTrue(awaitPage(follower, 10))
        controller:call(leader, "App.stack:handle{ kind = 'tap', x = 40, y = 700 }")
        t.assertTrue(select(1, awaitPage(leader, 7)))
        t.assertTrue(select(1, awaitPage(follower, 8)))
    end)
end)

t.describe("typography crosses the wire", function()
    t.it("a font size change on one device moves the other", function()
        t.assertTrue(awaitConnected())
        local before = tonumber(controller:call(follower, "Doc:getLayout().size"))
        t.assertTrue(before ~= nil, "no layout on the follower")

        controller:call(leader,
            "local l = Doc:getLayout() l.size = l.size + 6 return Reader:applyLayout(l) and 1 or 0")

        local deadline = socket.gettime() + 15
        local after
        while socket.gettime() < deadline do
            after = tonumber(controller:call(follower, "Doc:getLayout().size"))
            if after == before + 6 then break end
            socket.sleep(0.05)
        end
        t.assertEquals(after, before + 6)
    end)

    t.it("and both then paginate the book identically", function()
        t.assertTrue(awaitConnected())
        local deadline = socket.gettime() + 15
        local one, two
        while socket.gettime() < deadline do
            one = controller:call(leader, "Doc:fingerprint()")
            two = controller:call(follower, "Doc:fingerprint()")
            if one == two then break end
            socket.sleep(0.05)
        end
        -- The fingerprint says what differs, which is the point of it being
        -- legible rather than a hash.
        t.assertEquals(two, one)
    end)
end)

t.describe("the wire is a channel, not a connection", function()
    t.it("survives the leader going quiet without tearing the session down", function()
        t.assertTrue(awaitConnected())
        -- Nothing sent for a while: on a wire, silence proves nothing, and
        -- the engine is supposed to step the session back over the same
        -- stream rather than close it.
        socket.sleep(1.5)
        t.assertTrue(connected(follower), "the follower hung up on a silence")

        controller:call(leader, "Reader:gotoPage(3)")
        t.assertTrue(select(1, awaitPage(follower, 4)),
            "the pair did not recover from the silence")
    end)
end)

local code = t.run()
controller:shutdown()
stopPtyPair()
return code
