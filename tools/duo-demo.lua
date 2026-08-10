--[[--
Runs a real Duo session and records what each device displayed.

    luajit tools/duo-demo.lua [device-count]

Starts one master and N-1 slaves as separate processes, connects them over
real sockets, performs a scripted sequence of taps and jumps, and after each
one asks every device what page it is showing. Prints a table, and writes
`/tmp/duo-demo-trace.lua` for anything that wants to draw it.

Nothing here is simulated except the screen: the page numbers come from the
plugin's own reader state, on the far side of a socket.
--]]--

package.path = "./?.lua;./duo.koplugin/?.lua;" .. package.path

local Controller = require("spec/harness/controller")

local DEVICE_COUNT = tonumber(arg and arg[1]) or 2
local PAGES = 300
local PORT = 19990

local controller = Controller.new{ first_port = 18700 }

local devices = {}
local names = { "master", "slave", "slave2", "slave3" }
for index = 1, DEVICE_COUNT do
    local name = names[index] or ("slave" .. (index - 1))
    devices[index] = controller:spawn(name, { pages = PAGES })
    devices[index].label = name
end

local function call(device, code) return controller:call(device, code) end

local function connect()
    for _, device in ipairs(devices) do
        call(device, "Core:stop('demo')")
        call(device, "Core.settings.token = 'DEM024'")
        call(device, ("Core.settings.port = %d"):format(PORT))
        call(device, ("Core.settings.peer_port = %d"):format(PORT))
        call(device, "Core.settings.discovery_port = 19991")
        call(device, "Core.settings.mode = 'spread'")
        call(device, "Core.settings.reverse = false")
    end
    call(devices[1], "Core:start('master')")
    for index = 2, #devices do
        call(devices[index], ("Core:start('slave', { host = '127.0.0.1', port = %d })"):format(PORT))
    end
    controller:assertEventually(devices[1], "Core:slaveCount()", #devices - 1,
        "not everybody connected", 20)
end

--- Reads every screen once the pages have stopped moving.
-- Stability rather than an expected arrangement, so this works the same in
-- spread mode, in mirror mode and at the end of the book.
local function readScreens()
    local socket = require("socket")
    local deadline = socket.gettime() + 3
    local previous, pages
    while socket.gettime() < deadline do
        pages = {}
        for index, device in ipairs(devices) do
            pages[index] = tonumber(call(device, "D:getPage()"))
        end
        if previous and table.concat(previous, ",") == table.concat(pages, ",") then
            return pages
        end
        previous = pages
        socket.sleep(0.08)
    end
    return pages
end

local trace = { devices = {}, steps = {}, device_count = DEVICE_COUNT }
for index, device in ipairs(devices) do
    trace.devices[index] = device.label
end

local function record(action, note)
    local pages = readScreens()
    local step = { action = action, pages = pages, note = note }
    trace.steps[#trace.steps+1] = step

    local cells = {}
    for index, page in ipairs(pages) do
        cells[#cells+1] = ("%-8s %3d"):format(devices[index].label, page)
    end
    print(("%-34s │ %s"):format(action, table.concat(cells, " │ ")))
end

print("")
print(("KOReader Duo — %d devices, a %d page book"):format(DEVICE_COUNT, PAGES))
print(string.rep("─", 34 + DEVICE_COUNT * 15))

connect()
trace.step_size = tonumber(call(devices[1], "Core:getStep()"))

call(devices[1], "D:jumpToPage(10)")
record("open at page 10")

for _ = 1, 3 do
    call(devices[1], "D:tapForward()")
    record("tap forward on the master")
end

call(devices[#devices], "D:tapForward()")
record("tap forward on the last slave")

call(devices[1], "D:tapBack()")
record("tap back on the master")

call(devices[1], "D:jumpToPage(100)")
record("jump to page 100 (contents)")

call(devices[1], "Core.settings.mode = 'mirror'; Core:broadcastState()")
record("switch to mirror mode")
call(devices[1], "D:tapForward()")
record("tap forward, mirrored")

call(devices[1], "Core.settings.mode = 'spread'; Core:broadcastState()")
record("back to spread")

call(devices[1], ("D:jumpToPage(%d)"):format(PAGES))
record("jump to the last page")

print(string.rep("─", 34 + DEVICE_COUNT * 15))
print(("a page turn moves the master %d pages (%d devices)"):format(trace.step_size, DEVICE_COUNT))
print(("status: %s"):format(call(devices[1], "Core:getStatusText()")))
print("")

-- A Lua literal, for whatever wants to draw this.
local out = assert(io.open("/tmp/duo-demo-trace.lua", "w"))
out:write("return {\n")
out:write(("  device_count = %d,\n  step_size = %d,\n"):format(DEVICE_COUNT, trace.step_size))
out:write("  devices = { ")
for _, name in ipairs(trace.devices) do out:write(("%q, "):format(name)) end
out:write("},\n  steps = {\n")
for _, step in ipairs(trace.steps) do
    out:write(("    { action = %q, pages = { %s } },\n"):format(
        step.action, table.concat(step.pages, ", ")))
end
out:write("  },\n}\n")
out:close()
print("trace written to /tmp/duo-demo-trace.lua")

controller:shutdown()
