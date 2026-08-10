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
local Protocol = require("duo/protocol")
local SerialTransport = require("duo/transport_serial")

local LOG_DIR = os.getenv("DUO_LOG_DIR") or "/tmp"
local interpreter = arg and arg[-1] or "luajit"
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
-- Device processes, driven exactly as in integration_spec
--------------------------------------------------------------------------

local Controller = {}
Controller.__index = Controller

function Controller.new()
    local server, port
    for candidate = 18950, 19000 do
        server = socket.bind("127.0.0.1", candidate)
        if server then port = candidate break end
    end
    assert(server, "no free control port")
    server:settimeout(0)
    return setmetatable({ server = server, port = port, devices = {}, next_id = 1 }, Controller)
end

function Controller:spawn(name)
    local log = ("%s/duo-serial-%s.log"):format(LOG_DIR, name)
    os.execute(("LUA_PATH=%q %s spec/harness/instance_main.lua %s %d 300 >%s 2>&1 &"):format(
        "./?.lua;./duo.koplugin/?.lua;;", interpreter, name, self.port, log))
    local deadline = socket.gettime() + 20
    while socket.gettime() < deadline do
        local client = self.server:accept()
        if client then
            client:settimeout(0)
            local device = { name = name, socket = client, reader = Protocol.newReader(), log = log }
            assert(self:awaitMessage(device, "READY", 10), "no check-in from " .. name)
            self.devices[name] = device
            return device
        end
        socket.sleep(0.01)
    end
    error("device " .. name .. " did not start; see " .. log)
end

function Controller:awaitMessage(device, msg_type, timeout)
    local deadline = socket.gettime() + (timeout or 10)
    while socket.gettime() < deadline do
        local data, err, partial = device.socket:receive(4096)
        local received = data or partial
        if received and #received > 0 then
            device.reader:feed(received)
        elseif err == "closed" then
            error("device " .. device.name .. " died; see " .. device.log)
        end
        while true do
            local msg = device.reader:next()
            if not msg then break end
            if msg.type == msg_type then return msg end
        end
        socket.sleep(0.005)
    end
    return nil
end

function Controller:call(device, code, timeout)
    local id = tostring(self.next_id)
    self.next_id = self.next_id + 1
    device.socket:send(Protocol.encode("CMD", { id = id, code = code }))
    local msg = self:awaitMessage(device, "RESULT", timeout or 10)
    if not msg then error(("%s did not answer %s"):format(device.name, code)) end
    if msg.ok ~= "1" then
        error(("%s failed to run %s: %s"):format(device.name, code, msg.value))
    end
    return msg.value
end

function Controller:assertEventually(device, code, expected, what)
    local deadline = socket.gettime() + 15
    local last
    while socket.gettime() < deadline do
        last = self:call(device, code)
        if last == tostring(expected) then return end
        socket.sleep(0.05)
    end
    error(("%s: %s was %s, expected %s (%s)"):format(
        device.name, code, tostring(last), tostring(expected), what or ""), 2)
end

function Controller:shutdown()
    for _, device in pairs(self.devices) do
        pcall(function()
            device.socket:send(Protocol.encode("QUIT", {}))
            device.socket:close()
        end)
    end
    self.server:close()
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

local controller = Controller.new()
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
return exit_code
