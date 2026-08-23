--[[--
A way in, for the tests, to a KOReader that is really running.

The simulated devices in `spec/harness` speak a small control protocol: the
controller sends a snippet, the device runs it and sends back what it came
to. This is the same protocol spoken from inside a real KOReader, so the
same controller, the same `call`, and the same `assertEventually` drive
either -- and a test can be moved from one to the other without being
rewritten.

There is no loop here. A plugin does not own the process: KOReader's own
`UIManager` does, and it polls whatever is registered with it roughly every
fifty milliseconds. That is exactly how Duo drives its sockets, and this
borrows the same doorway.

Only loaded when DUO_CONTROL_PORT is set, so it does nothing at all on a
device somebody is reading on.
--]]--

local Device = require("device")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local socket = require("socket")

local port = tonumber(os.getenv("DUO_CONTROL_PORT") or "")

local DuoControl = WidgetContainer:extend{
    name = "duocontrol",
    is_doc_only = false,
}

--- Duo's own line protocol, borrowed from the plugin under test.
local function loadProtocol()
    local duo_dir = os.getenv("DUO_PLUGIN_DIR")
    if duo_dir then
        package.path = duo_dir .. "/?.lua;" .. package.path
    end
    local ok, Protocol = pcall(require, "duo/protocol")
    if ok then return Protocol end
    return nil
end

function DuoControl:init()
    if not port then return end
    self.Protocol = loadProtocol()
    if not self.Protocol then
        logger.warn("duocontrol: could not load Duo's protocol")
        return
    end

    local host = os.getenv("DUO_CONTROL_HOST") or "127.0.0.1"
    local control, err = socket.connect(host, port)
    if not control then
        logger.warn("duocontrol: could not reach the controller:", tostring(err))
        return
    end
    control:settimeout(0)
    self.control = control
    self.reader = self.Protocol.newReader()
    self.name = os.getenv("DUO_DEVICE_NAME") or "device"

    --[[
    The sandbox the controller's snippets run in. `UI` is resolved on every
    lookup rather than captured, because KOReader really does replace it:
    opening a book tears the file manager down and builds a reader, and a
    captured reference would quietly go stale -- which is the very thing
    that made the simulated devices lie about the browser.
    ]]
    self.sandbox = setmetatable({
        UIManager = UIManager,
        Device = Device,
        Protocol = self.Protocol,
        D = self,
    }, {
        __index = function(_, key)
            if key == "UI" then return DuoControl.currentUI() end
            if key == "Core" then return package.loaded["duo/core"] end
            if key == "Duo" then return DuoControl.duoPlugin() end
            return _G[key]
        end,
    })

    control:send(self.Protocol.encode("READY", { name = self.name }))
    UIManager:insertZMQ(self)
    logger.info("duocontrol: attached to the controller on", port)
end

--- Whatever is on screen: a reader if one is open, the file manager if not.
function DuoControl.currentUI()
    local ReaderUI = package.loaded["apps/reader/readerui"]
    if ReaderUI and ReaderUI.instance then return ReaderUI.instance end
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    if FileManager and FileManager.instance then return FileManager.instance end
    return nil
end

--- Duo itself, as the live plugin instance rather than the module.
-- KOReader registers a plugin on the UI under its own name, which is the
-- answer; the sweep behind it is for a build that has moved on.
function DuoControl.duoPlugin()
    local ui = DuoControl.currentUI()
    if not ui then return nil end
    if type(ui.duo) == "table" then return ui.duo end
    for _, module in pairs(ui) do
        if type(module) == "table" and rawget(module, "name") == "duo" then
            return module
        end
    end
    return nil
end

--------------------------------------------------------------------------
-- The controller's doorway. UIManager calls this; nothing here blocks.
--------------------------------------------------------------------------

function DuoControl:waitEvent()
    if not self.control then return end

    local data, err, partial = self.control:receive(4096)
    local received = data or partial
    if received and #received > 0 then
        self.reader:feed(received)
    elseif err == "closed" then
        self.control = nil
        return
    end

    while true do
        local msg = self.reader:next()
        if not msg then break end
        if msg.type == "CMD" then
            local ok, result = self:run(msg.code or "")
            self.control:send(self.Protocol.encode("RESULT", {
                id = msg.id,
                ok = ok and 1 or 0,
                value = tostring(result),
            }))
        elseif msg.type == "QUIT" then
            os.exit(0)
        end
    end
end

function DuoControl:run(code)
    local chunk, compile_error = loadstring("return " .. code)
    if not chunk then
        chunk, compile_error = loadstring(code)
    end
    if not chunk then return false, compile_error end
    setfenv(chunk, self.sandbox)
    return pcall(chunk)
end

--------------------------------------------------------------------------
-- The handful of things a test asks a device to do, spelled the way the
-- simulated devices spell them, so a test reads the same against either.
--------------------------------------------------------------------------

function DuoControl:getPage()
    local ui = DuoControl.currentUI()
    if not ui or not ui.document then return nil end
    local module = ui.document.info and ui.document.info.has_pages and ui.paging or ui.rolling
    if module and module.current_page then return module.current_page end
    if ui.view and ui.view.state then return ui.view.state.page end
    return nil
end

function DuoControl:getPageCount()
    local ui = DuoControl.currentUI()
    if not ui or not ui.document then return nil end
    return ui.document:getPageCount()
end

function DuoControl:jumpToPage(page)
    local ui = DuoControl.currentUI()
    if not ui then return false end
    local Event = require("ui/event")
    ui:handleEvent(Event:new("GotoPage", page))
    return true
end

--- A page turn as the reader makes one: through the method every tap,
--- swipe and button ends up in, which is the one Duo wraps.
function DuoControl:turn(diff)
    local ui = DuoControl.currentUI()
    if not ui or not ui.document then return false end
    local module = ui.document.info and ui.document.info.has_pages and ui.paging or ui.rolling
    if not module or not module.onGotoViewRel then return false end
    module:onGotoViewRel(diff)
    return true
end

function DuoControl:tapForward() return self:turn(1) end
function DuoControl:tapBack() return self:turn(-1) end

function DuoControl:openDocument(path)
    local ReaderUI = require("apps/reader/readerui")
    UIManager:nextTick(function() ReaderUI:showReader(path) end)
    return true
end

--- The font size, set the way the reader's own settings screen sets it.
function DuoControl:setFontSize(size)
    local ui = DuoControl.currentUI()
    if not ui then return false end
    local Event = require("ui/event")
    ui:handleEvent(Event:new("SetFontSize", size))
    return true
end

return DuoControl
