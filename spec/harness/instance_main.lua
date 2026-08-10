--[[--
A simulated device, as its own operating-system process.

    <interpreter> spec/harness/instance_main.lua <name> <control-port> [pages] [control-host]

It boots one KOReader-plus-Duo instance, dials back to the test controller
on the given port, and then spends its life doing two things: pumping the UI
loop (which is what drives Duo's sockets) and running whatever snippets the
controller sends it.

Running the two devices as separate processes is the point. They share no
Lua state, no module cache and no clock — the only thing between them is a
TCP connection, exactly as with two Kindles on a Wi-Fi network.

@module spec.harness.instance_main
--]]--

local name = arg[1] or "device"
local control_port = tonumber(arg[2]) or error("no control port given")

local socket = require("socket")
local Protocol = require("duo/protocol")
local Instance = require("spec/harness/instance")

local device = Instance.new{
    name = name,
    page_count = tonumber(arg[3]) or 300,
    debug = os.getenv("DUO_DEBUG") == "1",
}

-- The snippets from the controller run with the device in scope. `UI` is
-- resolved on every lookup rather than captured: opening a book or going
-- back to the file browser replaces it, exactly as in KOReader, and a
-- captured reference would quietly go stale.
local sandbox = setmetatable({
    D = device,
    Core = device.Core,
    UIManager = device.UIManager,
    Protocol = Protocol,
}, {
    __index = function(_, key)
        if key == "UI" then return device.ui end
        return _G[key]
    end,
})

-- The controller may be on the other side of a network namespace boundary
-- when the direct-link tests are running.
local control = assert(socket.connect(arg[4] or "127.0.0.1", control_port))
control:settimeout(0)
local reader = Protocol.newReader()

local function reply(fields)
    control:send(Protocol.encode("RESULT", fields))
end

control:send(Protocol.encode("READY", { name = name }))

local function run(code)
    local chunk, compile_error = loadstring("return " .. code)
    if not chunk then
        chunk, compile_error = loadstring(code)
    end
    if not chunk then
        return false, compile_error
    end
    setfenv(chunk, sandbox)
    local ok, result = pcall(chunk)
    return ok, result
end

io.stderr:write(("[%s] up, controller on %d\n"):format(name, control_port))

while true do
    device.UIManager:pump()

    local data, err, partial = control:receive(4096)
    local received = data or partial
    if received and #received > 0 then
        reader:feed(received)
    elseif err == "closed" then
        break
    end

    while true do
        local msg = reader:next()
        if not msg then break end
        if msg.type == "CMD" then
            local ok, result = run(msg.code or "")
            reply{ id = msg.id, ok = ok and 1 or 0, value = tostring(result) }
        elseif msg.type == "QUIT" then
            os.exit(0)
        end
    end

    socket.sleep(0.004)
end
