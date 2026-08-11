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
local master = controller:spawn("ser-master")
local slave = controller:spawn("ser-slave")

local function connectOverSerial()
    controller:call(master, "Core:stop('reset')")
    controller:call(slave, "Core:stop('reset')")
    for _, device in ipairs({ master, slave }) do
        controller:call(device, "Core.settings.transport = 'serial'")
        controller:call(device, "Core.settings.token = 'S3R14L'")
    end
    controller:call(master, ("Core.settings.serial_device = %q"):format(PTY_A))
    controller:call(slave, ("Core.settings.serial_device = %q"):format(PTY_B))
    controller:call(master, "Core:start('master')")
    controller:call(slave, "Core:start('slave')")
    controller:assertEventually(master, "Core:isConnected()", true, "no slave on the serial line")
    controller:assertEventually(slave, "Core:isConnected()", true, "did not reach the master")
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
        T.assertEquals(controller:call(master, "Core.role"), "master")
        T.assertEquals(controller:call(slave, "Core:getReadyLinks()[1].peer_name"), "ser-master")
        T.assertMatch(controller:call(master, "Core:getStatusText()"), "Master")
    end)

    T.it("waits for a master that starts later", function()
        controller:call(master, "Core:stop('reset')")
        controller:call(slave, "Core:stop('reset')")
        for _, device in ipairs({ master, slave }) do
            controller:call(device, "Core.settings.transport = 'serial'")
            controller:call(device, "Core.settings.token = 'S3R14L'")
        end
        controller:call(master, ("Core.settings.serial_device = %q"):format(PTY_A))
        controller:call(slave, ("Core.settings.serial_device = %q"):format(PTY_B))

        -- The slave opens the line first and hears nothing for a while.
        controller:call(slave, "Core:start('slave')")
        socket.sleep(1.5)
        T.assertEquals(controller:call(slave, "Core:isConnected()"), "false")

        controller:call(master, "Core:start('master')")
        controller:assertEventually(slave, "Core:isConnected()", true,
            "the repeated challenge never got through")
    end)

    T.it("runs the spread over Bluetooth just as over Wi-Fi", function()
        connectOverSerial()
        controller:call(master, "D:jumpToPage(10)")
        controller:assertEventually(slave, "D:getPage()", 11, "the slave is not on the next page")

        controller:call(master, "D:tapForward()")
        controller:assertEventually(master, "D:getPage()", 12)
        controller:assertEventually(slave, "D:getPage()", 13)

        controller:call(slave, "D:tapForward()")
        controller:assertEventually(master, "D:getPage()", 14, "the slave's tap did not reach the master")
        controller:assertEventually(slave, "D:getPage()", 15)
    end)

    T.it("turns away a device with the wrong pairing code", function()
        controller:call(master, "Core:stop('reset')")
        controller:call(slave, "Core:stop('reset')")
        for _, device in ipairs({ master, slave }) do
            controller:call(device, "Core.settings.transport = 'serial'")
        end
        controller:call(master, "Core.settings.token = 'S3R14L'")
        controller:call(slave, "Core.settings.token = 'WR0NG2'")
        controller:call(master, ("Core.settings.serial_device = %q"):format(PTY_A))
        controller:call(slave, ("Core.settings.serial_device = %q"):format(PTY_B))
        controller:call(master, "Core:start('master')")
        controller:call(slave, "Core:start('slave')")

        socket.sleep(2)
        T.assertEquals(controller:call(master, "Core:isConnected()"), "false",
            "a device with the wrong code got in over serial")
        controller:call(master, "Core:stop('done')")
        controller:call(slave, "Core:stop('done')")
    end)
end)

local exit_code = T.run()
controller:shutdown()
stopPtyPair()
os.exit(exit_code)
