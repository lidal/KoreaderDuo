--[[--
Drives simulated devices that run as separate processes.

Each device connects back here over a small control channel and runs the
Lua snippets it is sent, which is the only way this side can learn anything
about it: the devices share no state with the controller or with each
other, exactly like two readers on a table.

@module spec.harness.controller
--]]--

local socket = require("socket")
local Protocol = require("duo/protocol")

local Controller = {}
Controller.__index = Controller

local LOG_DIR = os.getenv("DUO_LOG_DIR") or "/tmp"

--[[--
Starts listening for devices.

@tparam[opt] table options
    bind          address to listen on (default "127.0.0.1")
    reach_host    address the devices should dial back on
    first_port    where to start looking for a free port
--]]--
function Controller.new(options)
    options = options or {}
    local server, port
    local first = options.first_port or 18800
    for candidate = first, first + 200 do
        server = socket.bind(options.bind or "127.0.0.1", candidate)
        if server then port = candidate break end
    end
    assert(server, "no free control port")
    server:settimeout(0)
    return setmetatable({
        server = server,
        port = port,
        reach_host = options.reach_host or "127.0.0.1",
        interpreter = options.interpreter or (arg and arg[-1]) or "luajit",
        devices = {},
        order = {},
        next_id = 1,
    }, Controller)
end

--[[--
Starts a device process and waits for it to check in.

@string name          the device's name, as its peer will see it
@tparam[opt] table options
    namespace  run inside this network namespace
    pages      pages in the device's document
--]]--
function Controller:spawn(name, options)
    options = options or {}
    local log = ("%s/duo-%s.log"):format(LOG_DIR, name)
    -- `ip netns exec` runs its argument directly rather than through a
    -- shell, so the environment has to be set before it, not after.
    local prefix = options.namespace and ("ip netns exec " .. options.namespace .. " ") or ""
    os.execute(("LUA_PATH=%q %s%s spec/harness/instance_main.lua %s %d %d %s >%s 2>&1 &"):format(
        "./?.lua;./duo.koplugin/?.lua;;", prefix, self.interpreter,
        name, self.port, options.pages or 300, self.reach_host, log))

    local deadline = socket.gettime() + 20
    while socket.gettime() < deadline do
        local client = self.server:accept()
        if client then
            client:settimeout(0)
            local device = {
                name = name,
                socket = client,
                reader = Protocol.newReader(),
                log = log,
            }
            assert(self:awaitMessage(device, "READY", 10),
                "device " .. name .. " never checked in; see " .. log)
            self.devices[name] = device
            self.order[#self.order+1] = device
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

--- Runs a snippet on a device and returns its result as a string.
function Controller:call(device, code, timeout)
    local id = tostring(self.next_id)
    self.next_id = self.next_id + 1
    device.socket:send(Protocol.encode("CMD", { id = id, code = code }))
    local deadline = socket.gettime() + (timeout or 10)
    while socket.gettime() < deadline do
        local msg = self:awaitMessage(device, "RESULT", deadline - socket.gettime())
        if not msg then break end
        if msg.id == id then
            if msg.ok ~= "1" then
                error(("%s failed to run %s: %s"):format(device.name, code, msg.value))
            end
            return msg.value
        end
    end
    error(("%s did not answer %s in time"):format(device.name, code))
end

function Controller:number(device, code)
    return tonumber(self:call(device, code))
end

--- Polls a device until an expression takes the expected value.
function Controller:waitFor(device, code, expected, timeout)
    local deadline = socket.gettime() + (timeout or 8)
    local last
    while socket.gettime() < deadline do
        last = self:call(device, code)
        if last == tostring(expected) then return true, last end
        socket.sleep(0.02)
    end
    return false, last
end

function Controller:assertEventually(device, code, expected, what, timeout)
    local ok, last = self:waitFor(device, code, expected, timeout)
    if not ok then
        error(("%s: %s was %s, expected %s (%s)"):format(
            device.name, code, tostring(last), tostring(expected), what or ""), 2)
    end
end

function Controller:shutdown()
    for _, device in ipairs(self.order) do
        pcall(function()
            device.socket:send(Protocol.encode("QUIT", {}))
            device.socket:close()
        end)
    end
    self.server:close()
end

return Controller
