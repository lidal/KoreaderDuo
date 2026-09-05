--[[--
The Bluetooth path, over a real character device.

A bound RFCOMM channel appears as `/dev/rfcomm0`: a character device with
no connect step, where both ends simply open the same line. A pseudo-terminal
pair behaves the same way, so `socat` gives us the two ends of a Bluetooth
link to test against without any Bluetooth hardware.

Two device processes again — the same processes and the same plugin as the
Wi-Fi tests, with the transport swapped underneath.
--]]--

local T = require("spec/testrunner")
local socket = require("socket")
local Controller = require("spec/harness/controller")
local SerialTransport = require("duo/transport_serial")

local LOG_DIR = os.getenv("DUO_LOG_DIR") or "/tmp"
--- Named for this run, so two of them cannot fight over one pair of ends.
local RUN = tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
local PTY_A = LOG_DIR .. "/duo-pty-a-" .. RUN
local PTY_B = LOG_DIR .. "/duo-pty-b-" .. RUN

--------------------------------------------------------------------------
-- A stand-in for a bound RFCOMM channel
--------------------------------------------------------------------------

--- True once something written on one end can be read from the other.
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
    os.execute(("socat -d -d pty,raw,echo=0,link=%s pty,raw,echo=0,link=%s >%s/duo-socat.log 2>&1 &")
        :format(PTY_A, PTY_B, LOG_DIR))
    --[[
    Waited for by carrying a byte, not by sleeping.

    The symlinks appear before socat has finished wiring the two ends
    together, so this used to sleep two tenths of a second and hope. Under
    the full suite that was sometimes not enough and this file failed on its
    first test while passing every time it was run alone -- which is the
    least useful kind of failure there is.

    A pair that has moved a byte is a pair that is ready. Nothing else
    proves it, and the check costs less than the sleep it replaces.
    ]]
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
    -- By this run's own ends, so a suite running beside this one keeps its.
    os.execute(("pkill -f 'link=%s' 2>/dev/null"):format(PTY_A))
    os.remove(PTY_A)
    os.remove(PTY_B)
end

--------------------------------------------------------------------------
-- Tests
--------------------------------------------------------------------------

--[[
A skip that says nothing is a pass that means nothing.

This file used to print a line and `return 0` when socat was missing, which
reads in the suite exactly like a file whose tests all passed. Nobody
looking at "All suites passed" would know the serial transport had not been
exercised at all -- and that is a fair description of how it came to be
believed tested when it was not.

So a skip is loud now, and it is counted as a failure of the suite rather
than a silence in it. Install socat, or know that this is untested.
]]
if not SerialTransport.isAvailable() then
    print("")
    print("!! SERIAL TESTS DID NOT RUN: this interpreter has no LuaJIT ffi.")
    print("!! The serial transport is UNTESTED in this run.")
    return 1
end

if not startPtyPair() then
    stopPtyPair()
    print("")
    print("!! SERIAL TESTS DID NOT RUN: socat is not installed.")
    print("!! The serial transport is UNTESTED in this run. Install socat.")
    return 1
end

local controller = Controller.new{ first_port = 18950 }
local leader = controller:spawn("ser-leader")
local follower = controller:spawn("ser-follower")

local function connectOverSerial()
    controller:call(leader, "Core:stop('reset')")
    controller:call(follower, "Core:stop('reset')")
    for _, device in ipairs({ leader, follower }) do
        controller:call(device, "Core.settings.transport = 'serial'")
        controller:call(device, "Core.settings.token = 'S3R14L'")
    end
    controller:call(leader, ("Core.settings.serial_device = %q"):format(PTY_A))
    controller:call(follower, ("Core.settings.serial_device = %q"):format(PTY_B))
    controller:call(leader, "Core:start('leader')")
    controller:call(follower, "Core:start('follower')")
    --[[
    The ordinary window, deliberately. This used to fail here and be widened
    on the theory that a shared machine was just being slow; it was not, and
    the waiting only delayed the report. What was actually happening is in
    the restart test below.
    ]]
    controller:assertEventually(leader, "Core:isConnected()", true,
        "no follower on the serial line")
    controller:assertEventually(follower, "Core:isConnected()", true,
        "did not reach the leader")
end

T.describe("serial transport", function()
    T.it("opens a device and moves bytes both ways", function()
        local a = assert(SerialTransport.open(PTY_A, { skip_stty = true }))
        local b = assert(SerialTransport.open(PTY_B, { skip_stty = true }))

        T.assertTrue(a:send("hello down the line\n"))
        local received = ""
        local deadline = socket.gettime() + 3
        while socket.gettime() < deadline and not received:find("\n") do
            received = received .. (b:receive() or "")
            socket.sleep(0.01)
        end
        T.assertEquals(received, "hello down the line\n")

        -- And back, because a serial line is symmetric.
        T.assertTrue(b:send("and back\n"))
        received = ""
        deadline = socket.gettime() + 3
        while socket.gettime() < deadline and not received:find("\n") do
            received = received .. (a:receive() or "")
            socket.sleep(0.01)
        end
        T.assertEquals(received, "and back\n")

        a:close(); b:close()
    end)

    T.it("reports a device that is not there", function()
        local stream, err = SerialTransport.open("/dev/definitely-not-here")
        T.assertNil(stream)
        T.assertMatch(err, "could not open")
    end)

    T.it("does not block when there is nothing to read", function()
        local a = assert(SerialTransport.open(PTY_A, { skip_stty = true }))
        local started = socket.gettime()
        for _ = 1, 50 do a:receive() end
        T.assertTrue(socket.gettime() - started < 0.5, "reads are blocking")
        a:close()
    end)
end)

T.describe("two devices over a serial link", function()
    T.it("pairs with no network at all", function()
        connectOverSerial()
        T.assertEquals(controller:call(leader, "Core.role"), "leader")
        T.assertEquals(controller:call(follower, "Core:getReadyLinks()[1].peer_name"), "ser-leader")
        T.assertMatch(controller:call(leader, "Core:getStatusText()"), "Leader")
    end)

    T.it("waits for a leader that starts later", function()
        controller:call(leader, "Core:stop('reset')")
        controller:call(follower, "Core:stop('reset')")
        for _, device in ipairs({ leader, follower }) do
            controller:call(device, "Core.settings.transport = 'serial'")
            controller:call(device, "Core.settings.token = 'S3R14L'")
        end
        controller:call(leader, ("Core.settings.serial_device = %q"):format(PTY_A))
        controller:call(follower, ("Core.settings.serial_device = %q"):format(PTY_B))

        -- The follower opens the line first and hears nothing for a while.
        controller:call(follower, "Core:start('follower')")
        socket.sleep(1.5)
        T.assertEquals(controller:call(follower, "Core:isConnected()"), "false")

        controller:call(leader, "Core:start('leader')")
        controller:assertEventually(follower, "Core:isConnected()", true,
            "the repeated challenge never got through")
    end)

    T.it("comes back after being stopped and started again", function()
        --[[
        A serial line is not a connection: there is nothing to hang up, so
        the bytes the last session wrote are still in the device's buffer
        when the next one opens it, and the next one reads them as though
        they had just arrived. The leader restarted, sent a fresh challenge,
        and the follower answered the one from before the restart -- a proof
        against a nonce nobody was holding any more. Each side then reported
        the other as having the wrong pairing code, for ever: one message out
        of step, and every retry read more of the backlog rather than less.

        It showed up here as a test that failed every few runs, which is
        what a race looks like when you do not look at it. It is not a race.
        Restart the pair twice and it never came back at all.
        ]]
        connectOverSerial()
        for _ = 1, 3 do
            connectOverSerial()
        end
        T.assertEquals(controller:call(leader, "Core:isConnected()"), "true",
            "the pair would not go back together over the same line")
    end)

    T.it("runs the spread over a wire just as over Wi-Fi", function()
        connectOverSerial()
        controller:call(leader, "D:jumpToPage(10)")
        controller:assertEventually(follower, "D:getPage()", 11, "the follower is not on the next page")

        controller:call(leader, "D:tapForward()")
        controller:assertEventually(leader, "D:getPage()", 12)
        controller:assertEventually(follower, "D:getPage()", 13)

        controller:call(follower, "D:tapForward()")
        controller:assertEventually(leader, "D:getPage()", 14, "the follower's tap did not reach the leader")
        controller:assertEventually(follower, "D:getPage()", 15)
    end)

    T.it("turns away a device with the wrong pairing code", function()
        controller:call(leader, "Core:stop('reset')")
        controller:call(follower, "Core:stop('reset')")
        for _, device in ipairs({ leader, follower }) do
            controller:call(device, "Core.settings.transport = 'serial'")
        end
        controller:call(leader, "Core.settings.token = 'S3R14L'")
        controller:call(follower, "Core.settings.token = 'WR0NG2'")
        controller:call(leader, ("Core.settings.serial_device = %q"):format(PTY_A))
        controller:call(follower, ("Core.settings.serial_device = %q"):format(PTY_B))
        controller:call(leader, "Core:start('leader')")
        controller:call(follower, "Core:start('follower')")

        socket.sleep(2)
        T.assertEquals(controller:call(leader, "Core:isConnected()"), "false",
            "a device with the wrong code got in over serial")
        controller:call(leader, "Core:stop('done')")
        controller:call(follower, "Core:stop('done')")
    end)
end)

local exit_code = T.run()
controller:shutdown()
stopPtyPair()
os.exit(exit_code)
