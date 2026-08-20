--[[--
A stand-in for the parts of KOReader that the plugin talks to.

KOReader itself cannot be built here (it needs a compiled C core), so this
module provides the frontend API surface `main.lua` uses: the same module
names, the same call signatures, the same event dispatch rules. The plugin
file is then loaded *unmodified*, which is the point — the glue code is the
part most likely to be wrong, so stubbing the plugin instead of its
surroundings would test nothing.

Where behaviour matters (event propagation, the UI loop's polling of
registered sockets, settings persistence) these stubs mirror KOReader's real
semantics, which are noted at each one. Where it does not (drawing), widgets
simply record that they were shown so tests can assert on them.

@module spec.harness.env
--]]--

local Env = {}

local function shallowCopy(source)
    local copy = {}
    for key, value in pairs(source or {}) do copy[key] = value end
    return copy
end

--------------------------------------------------------------------------
-- ui/event + the EventListener/WidgetContainer class chain
--------------------------------------------------------------------------

-- KOReader: an Event carries a name and its arguments; a listener handles it
-- by having a method called "on"..name.
local function makeEvent()
    local Event = {}
    function Event:new(name, ...)
        local args = { ... }
        args.n = select("#", ...)
        local event = { handler = "on" .. name, args = args, name = name }
        setmetatable(event, self)
        self.__index = self
        return event
    end
    return Event
end

-- KOReader: EventListener dispatches to self["on"..Name]; WidgetContainer
-- first offers the event to its children, and a child returning true stops
-- propagation. Plugins are the *last* children, which is why the plugin
-- wraps the paging module instead of trying to intercept its events.
local function makeWidgetContainer()
    local EventListener = {}
    function EventListener:extend(subclass_prototype)
        local class = subclass_prototype or {}
        setmetatable(class, self)
        self.__index = self
        return class
    end
    function EventListener:new(instance)
        instance = self:extend(instance)
        if instance.init then instance:init() end
        return instance
    end
    function EventListener:handleEvent(event)
        if self[event.handler] then
            return self[event.handler](self, unpack(event.args, 1, event.args.n))
        end
    end
    function EventListener:propagateEvent(event)
        for _, child in ipairs(self) do
            if child:handleEvent(event) then return true end
        end
        return false
    end
    return EventListener
end

--------------------------------------------------------------------------
-- ui/uimanager
--------------------------------------------------------------------------

local function makeUIManager(clock)
    local UIManager = {
        _zeromqs = {},
        _tasks = {},
        shown = {},      -- widgets currently on screen
        shown_log = {},  -- everything ever shown, for assertions
    }

    --[[--
    KOReader's standby counter, asserts and all.

    A reader that drops into standby stops running the UI loop, which is
    what polls Duo's sockets, so the plugin holds it off while it is
    connected. The real one refuses an unbalanced release, and so does
    this: an off-by-one here is a crash on a device.
    ]]
    UIManager._prevent_standby_count = 0

    function UIManager:preventStandby()
        self._prevent_standby_count = self._prevent_standby_count + 1
    end

    function UIManager:allowStandby()
        assert(self._prevent_standby_count > 0,
            "allowing standby that isn't prevented; you have an allow/prevent mismatch somewhere")
        self._prevent_standby_count = self._prevent_standby_count - 1
    end

    function UIManager:insertZMQ(zeromq)
        table.insert(self._zeromqs, zeromq)
        return zeromq
    end

    function UIManager:removeZMQ(zeromq)
        for index = #self._zeromqs, 1, -1 do
            if self._zeromqs[index] == zeromq then table.remove(self._zeromqs, index) end
        end
    end

    function UIManager:scheduleIn(seconds, task)
        table.insert(self._tasks, { at = clock() + seconds, task = task })
    end

    function UIManager:nextTick(task)
        table.insert(self._tasks, { at = 0, task = task })
    end

    function UIManager:unschedule(task)
        for index = #self._tasks, 1, -1 do
            if self._tasks[index].task == task then table.remove(self._tasks, index) end
        end
    end

    function UIManager:show(widget)
        self.shown[widget] = true
        --[[
        A dialog is its title *and* its buttons. Recording only the title
        let a test assert that a screen asked the right question while
        saying nothing about the answers it offered, which is most of what
        a button dialog is.
        ]]
        local text = widget.text or widget.title or ""
        for _, row in ipairs(widget.buttons or {}) do
            for _, button in ipairs(row) do
                if button.text then text = text .. "\n" .. button.text end
            end
        end
        table.insert(self.shown_log, {
            class = widget.class_name or "Widget",
            text = text,
        })
        if widget.timeout then
            self:scheduleIn(widget.timeout, function() self:close(widget) end)
        end
        return widget
    end

    function UIManager:close(widget)
        self.shown[widget] = nil
    end

    function UIManager:forceRePaint() end

    --[[--
    Locking the device, the way the power button does.

    Recorded rather than simulated: what a test needs to know is whether
    Duo asked for it, and — because both devices suspend each other — that
    asking does not become an argument neither side can end.
    ]]
    UIManager._suspends = 0

    function UIManager:suspend()
        self._suspends = self._suspends + 1
        table.insert(self.shown_log, { class = "Suspend", text = "" })
    end
    function UIManager:broadcastEvent() end
    function UIManager:setDirty() end

    --- One turn of KOReader's UI loop: run what is due, then poll sockets.
    -- The real loop polls every registered ZMQ at least every 50ms.
    function UIManager:pump()
        local now = clock()
        local due = {}
        for index = #self._tasks, 1, -1 do
            if self._tasks[index].at <= now then
                table.insert(due, table.remove(self._tasks, index).task)
            end
        end
        for _, task in ipairs(due) do task() end
        for _, zeromq in ipairs(self._zeromqs) do
            for _ in zeromq.waitEvent, zeromq do end -- drains, exactly as UIManager does
        end
    end

    --- Everything shown since the last call, as plain text.
    function UIManager:drainShownLog()
        local log = self.shown_log
        self.shown_log = {}
        return log
    end

    return UIManager
end

--------------------------------------------------------------------------
-- Everything else
--------------------------------------------------------------------------

local function makeWidget(class_name)
    local Widget = { class_name = class_name }
    function Widget:new(instance)
        instance = shallowCopy(instance)
        instance.class_name = class_name
        instance.onShowKeyboard = function() end
        instance.getInputText = function(self_) return self_.input end
        instance.setInputText = function(self_, text) self_.input = text end
        return instance
    end
    return Widget
end

local function makeLuaSettings()
    local LuaSettings = {}
    function LuaSettings:open(path)
        return setmetatable({ path = path, data = {} }, {
            __index = {
                readSetting = function(self_, key, default)
                    if self_.data[key] == nil and default ~= nil then
                        self_.data[key] = default
                    end
                    return self_.data[key]
                end,
                saveSetting = function(self_, key, value)
                    self_.data[key] = value
                    return self_
                end,
                delSetting = function(self_, key) self_.data[key] = nil end,
                isTrue = function(self_, key) return self_.data[key] == true end,
                flush = function(self_) self_.flushes = (self_.flushes or 0) + 1 end,
            },
        })
    end
    return LuaSettings
end

--- KOReader's T(): "%1" style placeholders, so translators can reorder.
local function template(text, ...)
    local values = { ... }
    return (tostring(text):gsub("%%(%d+)", function(index)
        return tostring(values[tonumber(index)])
    end))
end

--[[--
Installs the stub modules.

@tparam table options
    device_name  what Device.model reports
    clock        function returning the current time in seconds
    debug        print logger output to stderr
--]]--
function Env.install(options)
    options = options or {}

    -- The file browser asks whether a path is a directory, so the stub has
    -- to be able to say yes. `directories` is the set this fake device has;
    -- everything else falls back to looking on the real disk.
    -- `missing` is how a fake device says it genuinely does not hold a
    -- book. The two devices in a test share one filesystem, so without it
    -- the follower can simply open the leader's copy off the disk and no
    -- book ever travels — which makes a transfer test prove nothing.
    local lfs_stub = { directories = {}, missing = {} }
    function lfs_stub.mkdir(path)
        return os.execute(("mkdir -p %q"):format(path)) == 0
    end
    function lfs_stub.attributes(path, what)
        if lfs_stub.missing[path] then return nil end
        if lfs_stub.directories[path] then
            if what == "mode" then return "directory" end
            return { mode = "directory" }
        end
        local handle = io.open(path, "r")
        if not handle then return nil end
        handle:close()
        if what == "mode" then return "file" end
        return { mode = "file" }
    end
    local clock = options.clock or require("socket").gettime

    local UIManager = makeUIManager(clock)
    local Event = makeEvent()
    local WidgetContainer = makeWidgetContainer()

    local modules = {
        ["ui/uimanager"] = UIManager,
        ["ui/event"] = Event,
        ["ui/widget/container/widgetcontainer"] = WidgetContainer,
        ["ui/widget/eventlistener"] = WidgetContainer,
        ["ui/widget/infomessage"] = makeWidget("InfoMessage"),
        ["ui/widget/notification"] = (function()
            local Notification = makeWidget("Notification")
            Notification.SOURCE_ALWAYS_SHOW = 0x8000
            Notification.notify = function(_self, text)
                UIManager:show({ class_name = "Notification", text = text })
                return true
            end
            return Notification
        end)(),
        ["ui/widget/inputdialog"] = makeWidget("InputDialog"),
        ["ui/widget/buttondialog"] = makeWidget("ButtonDialog"),
        ["ui/widget/confirmbox"] = makeWidget("ConfirmBox"),
        ["luasettings"] = makeLuaSettings(),
        ["datastorage"] = {
            getSettingsDir = function() return "/tmp" end,
            -- Per-device, so two simulated readers do not write over each
            -- other when a book is sent from one to the other.
            getDataDir = function()
                return options.data_dir or ("/tmp/duo-data-" .. (options.device_name or "device"))
            end,
        },
        ["device"] = (function()
            --[[--
            A reader with a frontlight, on a deliberately awkward scale.

            KOReader drives a Kindle's light from 0 to 24 and a Kobo's from
            0 to 100, so a test on a 0-100 device would let a plain level
            through unnoticed and never catch a proportion being sent as a
            number. Warmth is off by default, as it is on most hardware.
            ]]
            local powerd = {
                fl_min = 0, fl_max = 24, fl_intensity = 12,
                fl_warmth_min = 0, fl_warmth_max = 24, fl_warmth = 0,
                -- Modelled because KOReader models it: the switch is not
                -- the level, and a light switched off still remembers what
                -- it was set to.
                is_fl_on = true,
            }
            powerd.isFrontlightOn = function(self_) return self_.is_fl_on end
            return {
                model = options.device_name or "TestReader",
                isKindle = function() return false end,
                hasWifiToggle = function() return true end,
                hasKeys = function() return false end,
                hasFrontlight = function() return options.no_frontlight ~= true end,
                hasNaturalLight = function() return options.warm_light == true end,
                canTurnFrontlightOff = function() return true end,
                getPowerDevice = function() return powerd end,
                powerd = powerd,
            }
        end)(),
        ["dispatcher"] = { registerAction = function() end },
        ["ui/network/manager"] = {
            isConnected = function() return true end,
            isOnline = function() return true end,
            promptWifiOn = function(_self, callback) if callback then callback() end end,
        },
        ["logger"] = (function()
            local function emit(level)
                return function(...)
                    if not options.debug then return end
                    local parts = {}
                    for index = 1, select("#", ...) do
                        parts[#parts+1] = tostring((select(index, ...)))
                    end
                    io.stderr:write(("[%s] %s\n"):format(level, table.concat(parts, " ")))
                end
            end
            return { dbg = emit("dbg"), info = emit("info"), warn = emit("warn"), err = emit("err") }
        end)(),
        ["gettext"] = setmetatable({}, { __call = function(_self, text) return text end }),
        ["ffi/util"] = { template = template },
        ["util"] = {
            splitFilePathName = function(path)
                local directory, name = tostring(path):match("^(.*/)([^/]*)$")
                if not directory then return "", tostring(path) end
                return directory, name
            end,
        },
        ["libs/libkoreader-lfs"] = lfs_stub,
        ["readhistory"] = { hist = {} },
        ["apps/reader/readerui"] = {
            showReader = function(_self, file)
                UIManager:show({ class_name = "ShowReader", text = file })
            end,
        },
    }

    for name, module in pairs(modules) do
        package.loaded[name] = module
    end

    -- KOReader hangs its global settings off _G, and plugins are entitled to
    -- expect it: the file browser's items-per-page lives there.
    G_reader_settings = modules["luasettings"]:open("/tmp/duo-global-settings.lua")

    return {
        UIManager = UIManager,
        Event = Event,
        WidgetContainer = WidgetContainer,
        modules = modules,
        lfs = lfs_stub,
    }
end

return Env
