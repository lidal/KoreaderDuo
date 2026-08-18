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
local PTY_A = LOG_DIR .. "/duo-pty-a"
local PTY_B = LOG_DIR .. "/duo-pty-b"

--------------------------------------------------------------------------
-- A stand-in for a bound RFCOMM channel
--------------------------------------------------------------------------

local function startPtyPair()
    os.remove(PTY_A)
    os.remove(PTY_B)
    os.execute(("socat -d -d pty,raw,echo=0,link=%s pty,raw,echo=0,link=%s >%s/duo-socat.log 2>&1 &")
        :format(PTY_A, PTY_B, LOG_DIR))
    local deadline = socket.gettime() + 10
    while socket.gettime() < deadline do
        if SerialTransport.exists(PTY_A) and SerialTransport.exists(PTY_B) then
            socket.sleep(0.2) -- let socat finish wiring the two ends together
            return true
        end
        socket.sleep(0.05)
    end
    return false
end

local function stopPtyPair()
    os.execute("pkill -f 'socat -d -d pty' 2>/dev/null")
    os.remove(PTY_A)
    os.remove(PTY_B)
end

--------------------------------------------------------------------------
-- Tests
--------------------------------------------------------------------------

if not SerialTransport.isAvailable() then
    print("# serial transport unavailable on this interpreter (needs LuaJIT ffi) — skipping")
    return 0
end

if not startPtyPair() then
    stopPtyPair()
    print("# socat not available — skipping the serial tests")
    return 0
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
    controller:assertEventually(leader, "Core:isConnected()", true, "no follower on the serial line")
    controller:assertEventually(follower, "Core:isConnected()", true, "did not reach the leader")
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

    T.it("runs the spread over Bluetooth just as over Wi-Fi", function()
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
