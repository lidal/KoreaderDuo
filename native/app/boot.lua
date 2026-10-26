--[[--
The entry point KUAL's script runs.

    luajit app/boot.lua [--headless]

Kept apart from `main.lua` so that the app is a library and this is the
only thing that exits the process, which is what makes the app testable:
the suite builds an `App` and drives it, and nothing in that path can call
`os.exit` or take the framebuffer.

@module duonative.boot
--]]--

package.path = "./?.lua;" .. package.path

local Platform = require("app/platform")
local App = require("app/main")

local headless = false
for _, argument in ipairs(arg or {}) do
    if argument == "--headless" then headless = true end
end

local device, engine, why = Platform.open{ headless = headless }
if not device then
    -- To stderr and to the log, because on a device there is no terminal
    -- to read and the screen belongs to whatever was there before.
    io.stderr:write("Duo cannot start: " .. tostring(why) .. "\n")
    local log = io.open("/mnt/us/duo/boot.log", "a")
    if log then
        log:write(("%s cannot start: %s\n"):format(os.date(), tostring(why)))
        log:close()
    end
    os.exit(1)
end

local app = App.new{
    device = device,
    engine = engine,
    book_dir = Platform.bookDir(),
    store = Platform.settingsPath(),
}

--[[
The wire starts itself.

Duo's own note: a character device costs nothing to hold open, so there is
no autostart setting to respect on a wire -- the link is simply there
whenever both devices have power. The role is whatever this device was
last set to.
]]
app.duo:start()

local ok, err = pcall(function() app:run() end)
if not ok then
    device:close()
    io.stderr:write("Duo stopped: " .. tostring(err) .. "\n")
    os.exit(1)
end
os.exit(0)
