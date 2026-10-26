--[[--
One native Duo app, as its own operating-system process.

    luajit spec/instance_main.lua <name> <control-port> <pty> <role> <book>

Boots the app with a headless device and the stub engine, points Duo's
serial transport at one end of a pseudo-terminal, and then does two things
for the rest of its life: turn the app's loop, and run whatever snippets
the controller sends.

Two processes is the whole point, and it is not a convenience. `duo/core`
is a module singleton -- the plugin's "the connection outlives the plugin"
-- so two apps in one interpreter would share one engine and prove nothing
at all. Here they share no Lua state, no module cache and no clock. The
only thing between them is the pty, which is standing in for the wire.

What the pty does and does not prove is worth being exact about, and the
plugin's README says it best: the framing, the handshake and the state
machine, yes; baud rates, framing errors, a full FIFO and whether flow
control does what it says on a real driver, no.

@module duonative.spec.instance_main
--]]--

local name = arg[1] or "device"
local control_port = tonumber(arg[2]) or error("no control port given")
local pty = arg[3] or error("no pty given")
local role = arg[4] or "leader"
local book = arg[5]

local socket = require("socket")
local Protocol = require("duo/protocol")
local App = require("app/main")
local FakeDevice = require("app/device/fake")
local Stub = require("app/engine/stub")

local app = App.new{
    device = FakeDevice.open{},
    engine = Stub,
    book_dir = book and (book:match("^(.*)/[^/]+$") or ".") or ".",
    store = ("%s/duonative-%s-settings.lua")
        :format(os.getenv("TMPDIR") or "/tmp", name),
}

local Core = app.duo.Core
Core:set("transport", Core.TRANSPORT_SERIAL)
Core.settings.serial_device = pty
Core.settings.device_name = name
-- No pairing code is needed on a wire -- the engine says so itself -- but
-- setting one proves the pair ignores it rather than that it happened to
-- be empty on both.
Core.settings.pairing_code = ""

if book then app:openBook(book) end

local sandbox = setmetatable({
    App = app,
    Core = Core,
    Protocol = Protocol,
    --- The open document, resolved on each lookup: a relayout replaces it.
    name = name,
}, {
    __index = function(_, key)
        if key == "Doc" then
            return app.reader and app.reader:document() or nil
        end
        if key == "Reader" then return app.reader end
        if key == "Library" then return app.library end
        return _G[key]
    end,
})

local control = assert(socket.connect("127.0.0.1", control_port))
control:settimeout(0)
local reader = Protocol.newReader()

local function reply(fields)
    control:send(Protocol.encode("RESULT", fields))
end

local function run(code)
    local chunk, compile_error = loadstring("return " .. code)
    if not chunk then chunk, compile_error = loadstring(code) end
    if not chunk then return false, compile_error end
    setfenv(chunk, sandbox)
    local ok, result = pcall(chunk)
    return ok, result
end

control:send(Protocol.encode("READY", { name = name }))
io.stderr:write(("[%s] up as %s on %s\n"):format(name, role, pty))

app.duo:start(role)

while true do
    -- The app's own turn of the loop, which is what pumps Duo.
    app:tick(0)

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
