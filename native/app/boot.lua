--[[--
The entry point KUAL's script runs.

    luajit app/boot.lua [--headless]

Kept apart from `main.lua` so that the app is a library and this is the
only thing that exits the process, which is what makes the app testable:
the suite builds an `App` and drives it, and nothing in that path can call
`os.exit` or take the framebuffer.

@module duonative.boot
--]]--

--[[
Where Lua looks, on a device.

The extension directory is the working directory -- KUAL guarantees that,
and run.sh cds there anyway -- and the installed layout puts everything
beside the app:

    /mnt/us/extensions/duo/
      app/            this frontend
      ffi/            koreader-base's Lua modules
      libs/           koreader-base's .so modules
      luajit          the interpreter
      fonts/          the faces the app ships

So `?.lua` finds both `app/main` and `ffi/blitbuffer`, and `?.so` finds
`libs/libkoreader-input` -- which is required by that path, slash and all,
exactly as KOReader requires it. Both come *first*: a host that happens to
have a different koreader-base on its own path must not win.
]]
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;./libs/?.so;" .. package.cpath

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
app.duo:start(os.getenv("DUO_ROLE"))

local ok, err = pcall(function() app:run() end)
if not ok then
    device:close()
    io.stderr:write("Duo stopped: " .. tostring(err) .. "\n")
    os.exit(1)
end
os.exit(0)
