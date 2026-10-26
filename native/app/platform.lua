--[[--
Which backends this process should use.

One decision, in one place: a Kindle gets koreader-base and CREngine, a
development machine gets the headless device and the stub paginator. The
app itself asks for neither -- it is handed a device and an engine (see
`main.lua`) -- so this is the only file that knows where it is running,
and swapping either backend is one line here rather than a hunt.

Detection is by the device's own fingerprint rather than by a build flag.
A flag has to be set correctly, and a wrong one produces an app that
starts on a reader and draws nothing.

@module duonative.platform
--]]--

local Platform = {}

--[[--
True when this is a Kindle.

`/proc/usid` is the device serial and exists on every Kindle and nothing
else; the version file is the belt to that brace. Deliberately not a test
for the framebuffer, which also exists on a Linux desktop.
--]]--
function Platform.isKindle()
    local usid = io.open("/proc/usid", "r")
    if usid then usid:close() return true end
    local version = io.open("/etc/prettyversion.txt", "r")
    if version then version:close() return true end
    return false
end

--- Where a Kindle keeps the frontlight. Differs by model; PW3 is this one.
Platform.LIGHT_PATH =
    "/sys/class/backlight/max77696-bl/brightness"

Platform.BOOK_DIRS = {
    "/mnt/us/documents",
    "/mnt/us/books",
}

function Platform.bookDir()
    if not Platform.isKindle() then
        return os.getenv("DUO_BOOKS") or "."
    end
    for _, candidate in ipairs(Platform.BOOK_DIRS) do
        local probe = io.popen(("test -d %q && echo yes"):format(candidate))
        local there = probe and probe:read("*l") == "yes"
        if probe then probe:close() end
        if there then return candidate end
    end
    return "/mnt/us"
end

function Platform.settingsPath()
    if Platform.isKindle() then return "/mnt/us/duo/settings.lua" end
    return (os.getenv("TMPDIR") or "/tmp") .. "/duonative-settings.lua"
end

--[[--
Opens the right device and names the right engine.

@treturn table device
@treturn table engine module
@treturn string|nil the reason, when the real backends were wanted and
    could not be had. Returned rather than raised so the caller can say so
    on a screen the reader can actually see.
--]]--
function Platform.open(options)
    options = options or {}
    if options.headless or not Platform.isKindle() then
        return require("app/device/fake").open(options),
               require("app/engine/stub"), nil
    end

    local Kobase = require("app/device/kobase")
    local device, why = Kobase.open{
        light_path = Platform.LIGHT_PATH,
        rasteriser = options.rasteriser,
    }
    if not device then return nil, nil, why end

    local Cre = require("app/engine/cre")
    local _, engine_error = Cre.init{ cache_dir = "/mnt/us/duo/cache" }
    if engine_error then
        device:close()
        return nil, nil, engine_error
    end
    return device, Cre, nil
end

return Platform
