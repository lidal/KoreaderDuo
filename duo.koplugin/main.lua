--[[--
KOReader Duo — turn two devices into one two-page spread.

One device is the master: it owns the page number and tells the other what
to show. The other is the slave: it displays whatever it is told and can
forward page turns back. Put them side by side and you get a book with a
left page and a right page.

This file is the KOReader half of the plugin: menus, dialogs, events, and
the interception of page turns. Everything about connecting, pairing and
staying in sync lives in `duo/core.lua`.

@module koplugin.duo
--]]--

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local Core = require("duo/core")
local NetUtil = require("duo/netutil")
local Spread = require("duo/spread")
local Util = require("duo/util")

-- Settings live outside the plugin instance: KOReader rebuilds that instance
-- every time a document is opened, and so would rebuild these.
local settings_store = LuaSettings:open(DataStorage:getSettingsDir() .. "/duo.lua")

local Duo = WidgetContainer:extend{
    name = "duo",
    is_doc_only = false,
}

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

function Duo:init()
    Core:configure{
        settings = settings_store:readSetting("duo", {}),
        hooks = {
            log = function(...) logger.dbg("Duo:", ...) end,
            save = function(settings)
                settings_store:saveSetting("duo", settings)
                settings_store:flush()
            end,
            notify = function(text)
                Notification:notify(text, Notification.SOURCE_ALWAYS_SHOW)
            end,
            alert = function(text)
                UIManager:show(InfoMessage:new{ text = text })
            end,
            -- Deliberately not redrawing the menu here: this fires on every
            -- page turn, and by then the touch menu that handed us its
            -- instance is usually long gone. Menu callbacks refresh
            -- themselves, and text_func picks up the new state on reopening.
            onChanged = function() end,
            openDocument = function(file, msg) self:openRemoteDocument(file, msg) end,
            defaultDeviceName = function() return Duo:getDefaultDeviceName() end,
            openFirewall = function(port)
                if Device:isKindle() then NetUtil.openFirewall(port) end
            end,
            closeFirewall = function(port)
                if Device:isKindle() then NetUtil.closeFirewall(port) end
            end,
        },
    }

    self:ensurePolling()
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    if self.ui and self.ui.document then
        self:bindDocument()
    end

    -- Only on a real KOReader start, not on every document switch.
    if not Duo.autostart_done then
        Duo.autostart_done = true
        local role = Core:get("autostart_role")
        if Core:get("autostart") and role and role ~= Core.ROLE_OFF then
            UIManager:nextTick(function() Core:start(role) end)
        end
    end
end

--- Makes sure Duo's sockets are pumped by the UI loop.
-- UIManager polls every registered "ZMQ" at least every 50ms, which is the
-- cheapest way for a plugin to get a timer without keeping the CPU awake.
function Duo:ensurePolling()
    local poller = Core:getPoller()
    for _, registered in ipairs(UIManager._zeromqs or {}) do
        if registered == poller then return end
    end
    UIManager:insertZMQ(poller)
end

function Duo:getDefaultDeviceName()
    local model = Device.model or "KOReader"
    return tostring(model)
end

function Duo:onDispatcherRegisterActions()
    Dispatcher:registerAction("duo_toggle", {
        category = "none", event = "DuoToggle", title = _("Duo: start/stop"), general = true,
    })
    Dispatcher:registerAction("duo_resync", {
        category = "none", event = "DuoResync", title = _("Duo: resync now"), general = true,
    })
end

function Duo:onCloseWidget()
    self:unwrapPageTurns()
    Core:detachReader(self.reader_binding)
end

function Duo:onCloseDocument()
    self:unwrapPageTurns()
    Core:detachReader(self.reader_binding)
end

--------------------------------------------------------------------------
-- Document binding
--------------------------------------------------------------------------

--- The reader module that owns page turns for this document type.
function Duo:getPagingModule()
    if not self.ui or not self.ui.document then return nil end
    if self.ui.document.info and self.ui.document.info.has_pages then
        return self.ui.paging
    end
    return self.ui.rolling
end

function Duo:getCurrentPage()
    local module = self:getPagingModule()
    if module and module.current_page then return module.current_page end
    if self.ui and self.ui.view and self.ui.view.state then return self.ui.view.state.page end
    return nil
end

function Duo:getPageCount()
    if self.ui and self.ui.document and self.ui.document.getPageCount then
        return self.ui.document:getPageCount()
    end
    return nil
end

--- Builds the reader binding the engine talks to, and hands it over.
function Duo:bindDocument()
    local ui = self.ui
    if not ui or not ui.document then return end
    self:wrapPageTurns()

    self.reader_binding = {
        getPage = function() return self:getCurrentPage() end,
        getPageCount = function() return self:getPageCount() end,
        getPagesPerView = function()
            local document = ui.document
            if document and document.getVisiblePageNumberCount then
                local ok, count = pcall(document.getVisiblePageNumberCount, document)
                if ok and count and count > 0 then return count end
            end
            return 1
        end,
        gotoPage = function(page)
            ui:handleEvent(Event:new("GotoPage", page))
        end,
        turnRelative = function(diff)
            local module = self:getPagingModule()
            if not module then return end
            -- Deliberately the *unwrapped* method: this is the real turn,
            -- already multiplied by the number of devices in the spread.
            local original = self.original_goto_view_rel
            if original then
                original(module, diff)
            else
                ui:handleEvent(Event:new("GotoViewRel", diff))
            end
        end,
        getDocument = function()
            return {
                file = ui.document.file,
                title = ui.doc_props and (ui.doc_props.display_title or ui.doc_props.title) or nil,
                digest = ui.doc_settings and ui.doc_settings:readSetting("partial_md5_checksum") or nil,
            }
        end,
    }
    Core:attachReader(self.reader_binding)
end

function Duo:onReaderReady()
    self:bindDocument()
end

--------------------------------------------------------------------------
-- Page turns
--------------------------------------------------------------------------

--[[--
Wraps the reader's relative page turn.

Every ordinary way of turning a page — tap, swipe, hardware button, a
gesture — ends up in `onGotoViewRel`, so this one wrapper covers them all.
Absolute jumps (table of contents, the go-to dialog, links) are left alone:
they change the page, the resulting PageUpdate is broadcast, and the spread
follows along by itself.
--]]--
function Duo:wrapPageTurns()
    local module = self:getPagingModule()
    if not module or module.duo_wrapped then return end

    local original = module.onGotoViewRel
    if not original then return end
    self.original_goto_view_rel = original
    self.wrapped_module = module
    module.duo_wrapped = true

    module.onGotoViewRel = function(paging_module, diff, no_page_turn, ...)
        -- `no_page_turn` is ReaderSearch peeking at the next page; a key
        -- event passes the key object in that slot. Only a plain turn of a
        -- single screen is ours to reinterpret.
        if no_page_turn ~= true and (diff == 1 or diff == -1) then
            if Core:handleRelativeTurn(diff) then
                return true
            end
        end
        return original(paging_module, diff, no_page_turn, ...)
    end
end

function Duo:unwrapPageTurns()
    local module = self.wrapped_module
    if module then
        module.onGotoViewRel = nil -- unshadow the class method
        module.duo_wrapped = nil
    end
    self.wrapped_module = nil
    self.original_goto_view_rel = nil
end

function Duo:onPageUpdate(page)
    Core:onPageChanged(page)
end

function Duo:onPosUpdate(pos, page) -- luacheck: ignore pos
    -- Scroll mode moves without changing pages; the page number is what the
    -- other device needs, so only a real change is worth sending.
    if page and page ~= self.last_reported_page then
        self.last_reported_page = page
        Core:onPageChanged(page)
    end
end

--------------------------------------------------------------------------
-- Power and network
--------------------------------------------------------------------------

function Duo:onSuspend()
    Core:suspend()
end

function Duo:onResume()
    Core:resume()
end

function Duo:onNetworkConnected()
    Core:resume()
end

function Duo:onNetworkDisconnecting()
    Core:suspend()
end

function Duo:onDuoToggle()
    if Core:isActive() then
        Core:stop("stopped")
        Core:notify(_("Duo: stopped"))
    else
        self:showConnectDialog()
    end
    return true
end

function Duo:onDuoResync()
    self:resync()
    return true
end

function Duo:resync()
    if not Core:isActive() then return end
    if Core:isMaster() then
        Core:broadcastDocument()
        Core:broadcastState()
        Core:notify(_("Duo: resent the current page"))
    else
        local link = Core:getReadyLinks()[1]
        if link then
            link:send(require("duo/protocol").SYNC, {})
            Core:notify(_("Duo: asked the master where we are"))
        end
    end
end

--------------------------------------------------------------------------
-- Following the master's book
--------------------------------------------------------------------------

--- Opens the book the master just opened.
-- Two Kindles usually store the same book at the same path, but when they
-- do not, the reading history is a good second guess before giving up.
function Duo:openRemoteDocument(file, msg)
    local lfs = require("libs/libkoreader-lfs")
    local target = file
    if lfs.attributes(target, "mode") ~= "file" then
        target = self:findLocalCopy(file)
    end
    if not target then
        UIManager:show(InfoMessage:new{
            text = T(_("Duo: the master is reading a book this device does not have:\n%1"),
                     msg and msg.title ~= "" and msg.title or file),
        })
        return
    end
    local ReaderUI = require("apps/reader/readerui")
    UIManager:nextTick(function()
        ReaderUI:showReader(target)
    end)
end

--- Looks for the same book somewhere else on this device.
function Duo:findLocalCopy(file)
    -- Note: `_` is gettext in this file, so the path half is discarded with
    -- select() rather than by naming it.
    local name = select(2, util.splitFilePathName(file))
    local ok, ReadHistory = pcall(require, "readhistory")
    if not ok or not ReadHistory or not ReadHistory.hist then return nil end
    for _, item in ipairs(ReadHistory.hist) do
        if item.file then
            local candidate = select(2, util.splitFilePathName(item.file))
            if candidate == name then
                local lfs = require("libs/libkoreader-lfs")
                if lfs.attributes(item.file, "mode") == "file" then
                    return item.file
                end
            end
        end
    end
    return nil
end

--------------------------------------------------------------------------
-- Connecting
--------------------------------------------------------------------------

--- The entry point for pairing: pick a role.
function Duo:showConnectDialog()
    local dialog
    dialog = ButtonDialog:new{
        title = _("Duo — two devices, one book\n\nStart one device as the master, then connect the other one to it."),
        buttons = {
            {{
                text = _("This is the master (left page)"),
                callback = function()
                    UIManager:close(dialog)
                    self:startMaster()
                end,
            }},
            {{
                text = _("Connect to a master (right page)"),
                callback = function()
                    UIManager:close(dialog)
                    self:searchForMaster()
                end,
            }},
            {{
                text = _("No Wi-Fi network? Link the two directly…"),
                callback = function()
                    UIManager:close(dialog)
                    self:showDirectLinkDialog()
                end,
            }},
            {{
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            }},
        },
    }
    UIManager:show(dialog)
end

function Duo:startMaster()
    local function go()
        if Core:start(Core.ROLE_MASTER) then
            self:showPairingSheet()
        end
    end
    -- A master with no network is a master nobody can reach.
    if NetworkMgr:isConnected() then
        go()
    else
        NetworkMgr:promptWifiOn(go)
    end
end

--- The screen you read out to the other device.
function Duo:showPairingSheet()
    local address = NetUtil.getLocalIP() or _("unknown — check Wi-Fi")
    local text = T(_([[
Duo master is running.

On the other device, open Duo and tap "Connect to a master". It should find this device by itself.

Name:    %1
Address: %2:%3
Code:    %4]]),
        Core:getDeviceName(), address, Core:get("port"), Core:ensureToken())
    UIManager:show(InfoMessage:new{ text = text, timeout = 30 })
end

--- Searches the network, then offers whatever it found.
function Duo:searchForMaster()
    local function begin()
        local searching = InfoMessage:new{
            text = _("Looking for a master on this network…"),
            timeout = 10,
        }
        UIManager:show(searching)
        Core:startScan(function(results)
            UIManager:close(searching)
            self:showSearchResults(results)
        end)
    end
    if NetworkMgr:isConnected() then
        begin()
    else
        NetworkMgr:promptWifiOn(begin)
    end
end

function Duo:showSearchResults(results)
    local buttons = {}
    for _, offer in ipairs(results) do
        local label = offer.name
        if offer.book then
            label = label .. " — " .. Util.ellipsize(offer.book, 30)
        end
        buttons[#buttons+1] = {{
            text = label .. "  (" .. offer.host .. ")",
            callback = function()
                UIManager:close(self.search_dialog)
                self:connectTo(offer.host, offer.port, offer.locked)
            end,
        }}
    end
    buttons[#buttons+1] = {{
        text = _("Type the address by hand"),
        callback = function()
            UIManager:close(self.search_dialog)
            self:promptForAddress()
        end,
    }}
    buttons[#buttons+1] = {{
        text = _("Search again"),
        callback = function()
            UIManager:close(self.search_dialog)
            self:searchForMaster()
        end,
    }}
    buttons[#buttons+1] = {{
        text = _("Cancel"),
        callback = function() UIManager:close(self.search_dialog) end,
    }}

    self.search_dialog = ButtonDialog:new{
        title = #results > 0
            and _("Found these devices:")
            or _("No master answered.\n\nMake sure Duo is running as master on the other device and that both are on the same Wi-Fi network."),
        buttons = buttons,
    }
    UIManager:show(self.search_dialog)
end

--- Connects, asking for the pairing code when the master wants one.
function Duo:connectTo(host, port, locked)
    local function go()
        Core:start(Core.ROLE_SLAVE, { host = host, port = port })
    end
    if locked and Util.normalizeToken(Core:get("token")) == "" then
        self:promptForToken(go)
    else
        go()
    end
end

function Duo:promptForToken(on_done)
    local dialog
    dialog = InputDialog:new{
        title = _("Pairing code"),
        description = _("Type the code shown on the master."),
        input = Core:get("token"),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("OK"),
                is_enter_default = true,
                callback = function()
                    Core:set("token", Util.normalizeToken(dialog:getInputText()))
                    UIManager:close(dialog)
                    if on_done then on_done() end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Duo:promptForAddress()
    local dialog
    dialog = InputDialog:new{
        title = _("Master address"),
        description = _("The address shown on the master device, for example 192.168.1.24"),
        input = Core:get("peer_host"),
        input_hint = "192.168.1.24",
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Connect"),
                is_enter_default = true,
                callback = function()
                    local host = (dialog:getInputText() or ""):gsub("%s", "")
                    UIManager:close(dialog)
                    if not NetUtil.isValidIP(host) then
                        UIManager:show(InfoMessage:new{
                            text = T(_("That does not look like an address: %1"), host),
                        })
                        return
                    end
                    self:connectTo(host, Core:get("peer_port"), true)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--------------------------------------------------------------------------
-- A link with no router on it
--------------------------------------------------------------------------

--[[--
The self-contained arrangement: the two devices make a Wi-Fi link between
themselves. Whether a reader can do this at all depends on its Wi-Fi
driver, so nothing is attempted until the device has been asked.
--]]--
function Duo:showDirectLinkDialog()
    local DirectLink = require("duo/directlink")
    local report = DirectLink.probe()

    if not DirectLink.isPossible(report) then
        UIManager:show(InfoMessage:new{
            text = T(_([[
This device cannot make a Wi-Fi link of its own.

%1

Any network will do instead: a home router, or a phone hotspot with no internet on it. Duo works the same over either.]]),
                DirectLink.describe(report)),
        })
        return
    end

    local dialog
    dialog = ButtonDialog:new{
        title = T(_([[
Link the two devices directly, with no router.

One device hosts the link and the other joins it. Do this on both, then they find each other by themselves.

%1

This takes over Wi-Fi while it runs. "Restore normal Wi-Fi" or a reboot puts it back.]]),
            DirectLink.describe(report)),
        buttons = {
            {{
                text = _("Host the link, and be the master"),
                callback = function()
                    UIManager:close(dialog)
                    self:runDirectLink("host")
                end,
            }},
            {{
                text = _("Join the link, and be the slave"),
                callback = function()
                    UIManager:close(dialog)
                    self:runDirectLink("join")
                end,
            }},
            {{
                text = _("Restore normal Wi-Fi"),
                callback = function()
                    UIManager:close(dialog)
                    local DirectLinkModule = require("duo/directlink")
                    Core:stop("restoring Wi-Fi")
                    DirectLinkModule.restore()
                    UIManager:show(InfoMessage:new{
                        text = _("Wi-Fi handed back to the system."),
                    })
                end,
            }},
            {{
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            }},
        },
    }
    UIManager:show(dialog)
end

--- Brings the direct link up and then starts Duo on it, so the whole thing
-- is one tap on each device.
function Duo:runDirectLink(role)
    local DirectLink = require("duo/directlink")
    local working = InfoMessage:new{
        text = _("Setting up the direct link…"),
        timeout = 30,
    }
    UIManager:show(working)
    UIManager:forceRePaint()

    local output = (role == "host") and DirectLink.host() or DirectLink.join()
    UIManager:close(working)

    if not output or output:match("^error:") or output:match("\nerror:") then
        UIManager:show(InfoMessage:new{
            text = T(_("The direct link could not be set up.\n\n%1"), tostring(output)),
        })
        return
    end

    Core:set("transport", Core.TRANSPORT_TCP)
    if role == "host" then
        if Core:start(Core.ROLE_MASTER) then
            self:showPairingSheet()
        end
    else
        -- The host is always at the same address, so there is nothing to
        -- search for and nothing to type.
        Core:set("peer_host", DirectLink.HOST_ADDRESS)
        Core:start(Core.ROLE_SLAVE, {
            host = DirectLink.HOST_ADDRESS,
            port = Core:get("peer_port"),
        })
    end
end

--------------------------------------------------------------------------
-- Menu
--------------------------------------------------------------------------

function Duo:refreshMenu()
    if self.menu_container and self.menu_container.updateItems then
        pcall(function() self.menu_container:updateItems() end)
    end
end

function Duo:addToMainMenu(menu_items)
    menu_items.duo = {
        text = _("Duo (two-device spread)"),
        sorting_hint = "network",
        sub_item_table = self:getMenuTable(),
    }
end

function Duo:getMenuTable()
    return {
        {
            text_func = function() return T(_("Status: %1"), Core:getStatusText()) end,
            keep_menu_open = true,
            callback = function() self:showStatus() end,
        },
        {
            text_func = function()
                return Core:isActive() and _("Stop Duo") or _("Connect the two devices…")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self.menu_container = touchmenu_instance
                if Core:isActive() then
                    Core:stop("stopped by user")
                    Core:notify(_("Duo: stopped"))
                else
                    self:showConnectDialog()
                end
                self:refreshMenu()
            end,
        },
        {
            text = _("Resync now"),
            enabled_func = function() return Core:isConnected() end,
            keep_menu_open = true,
            callback = function() self:resync() end,
        },
        {
            text = _("Layout"),
            separator = true,
            sub_item_table = {
                {
                    text = _("Two-page spread"),
                    help_text = _("The master shows one page, the other device shows the next one. A page turn moves the pair forward by two."),
                    checked_func = function() return Core:get("mode") == Spread.SPREAD end,
                    callback = function()
                        Core:set("mode", Spread.SPREAD)
                        Core:broadcastState()
                    end,
                },
                {
                    text = _("Mirror the same page"),
                    help_text = _("Both devices show the same page — for reading along with somebody else."),
                    checked_func = function() return Core:get("mode") == Spread.MIRROR end,
                    callback = function()
                        Core:set("mode", Spread.MIRROR)
                        Core:broadcastState()
                    end,
                    separator = true,
                },
                {
                    text = _("This device holds the right-hand page"),
                    help_text = _("Swap the sides: the other device shows the earlier page."),
                    checked_func = function() return Core:get("reverse") end,
                    callback = function()
                        Core:set("reverse", not Core:get("reverse"))
                        Core:broadcastState()
                    end,
                },
            },
        },
        {
            text = _("Link"),
            sub_item_table = {
                {
                    text = _("Wi-Fi (or any network link)"),
                    help_text = _("Talk over TCP/IP. This also covers a Bluetooth PAN connection, which looks like an ordinary network to KOReader."),
                    checked_func = function() return not Core:usesSerial() end,
                    callback = function() self:setTransport(Core.TRANSPORT_TCP) end,
                },
                {
                    text = _("Set up a direct link (no router)…"),
                    help_text = _("Make a Wi-Fi link between the two devices themselves, for reading somewhere with no network."),
                    keep_menu_open = true,
                    callback = function() self:showDirectLinkDialog() end,
                },
                {
                    text = _("Bluetooth serial (RFCOMM)"),
                    help_text = _("Talk over a bound RFCOMM channel, with no Wi-Fi at all. Bind the channel outside KOReader first, e.g. 'rfcomm bind /dev/rfcomm0 <address> 1'."),
                    checked_func = function() return Core:usesSerial() end,
                    callback = function() self:setTransport(Core.TRANSPORT_SERIAL) end,
                    separator = true,
                },
                {
                    text_func = function() return T(_("Serial device: %1"), Core:get("serial_device")) end,
                    enabled_func = function() return Core:usesSerial() end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        self.menu_container = touchmenu_instance
                        self:showSerialDeviceDialog()
                    end,
                },
            },
        },
        {
            text = _("Page turns from the other device"),
            help_text = _("Let a tap on the slave turn the pair. Switch this off to make the slave a display only."),
            checked_func = function() return Core:get("slave_can_turn") end,
            callback = function() Core:set("slave_can_turn", not Core:get("slave_can_turn")) end,
        },
        {
            text = _("Follow the master's book"),
            help_text = _("When the master opens a book, open the same one here."),
            checked_func = function() return Core:get("follow_document") end,
            callback = function() Core:set("follow_document", not Core:get("follow_document")) end,
        },
        {
            text = _("Start Duo when KOReader starts"),
            checked_func = function() return Core:get("autostart") end,
            callback = function() Core:set("autostart", not Core:get("autostart")) end,
            separator = true,
        },
        {
            text_func = function() return T(_("Pairing code: %1"), Core:ensureToken()) end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self.menu_container = touchmenu_instance
                self:showTokenDialog()
            end,
        },
        {
            text_func = function() return T(_("Device name: %1"), Core:getDeviceName()) end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self.menu_container = touchmenu_instance
                self:showNameDialog()
            end,
        },
        {
            text_func = function() return T(_("Port: %1"), Core:get("port")) end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self.menu_container = touchmenu_instance
                self:showPortDialog()
            end,
        },
    }
end

function Duo:showStatus()
    local lines = { Core:getStatusText() }
    local address = NetUtil.getLocalIP()
    if address then
        lines[#lines+1] = T(_("This device: %1 (%2)"), Core:getDeviceName(), address)
    end
    for _, link in ipairs(Core:getReadyLinks()) do
        local latency = link.latency and T(_(" · %1 ms"), math.floor(link.latency * 1000)) or ""
        lines[#lines+1] = T(_("Peer: %1%2"), link:describe(), latency)
    end
    if Core:isConnected() and Core:hasReader() then
        lines[#lines+1] = T(_("Turning a page moves %1 pages."), Core:getStep())
    end
    if Core.last_error then
        lines[#lines+1] = T(_("Last error: %1"), Core.last_error)
    end
    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
end

--- Switches between the network and the serial link, restarting if running.
function Duo:setTransport(transport)
    if Core:get("transport") == transport then return end
    local role = Core.role
    local was_active = Core:isActive()
    if was_active then
        Core:stop("switching link")
    end
    Core:set("transport", transport)
    if transport == Core.TRANSPORT_SERIAL and not require("duo/transport_serial").isAvailable() then
        UIManager:show(InfoMessage:new{
            text = _("This build of KOReader cannot open a serial device, so Duo will keep using the network."),
        })
        Core:set("transport", Core.TRANSPORT_TCP)
        return
    end
    if was_active then
        Core:start(role)
    end
    self:refreshMenu()
end

function Duo:showSerialDeviceDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Serial device"),
        description = _("The device file for the Bluetooth channel. Both devices must be bound to each other before Duo can use it."),
        input = Core:get("serial_device"),
        input_hint = "/dev/rfcomm0",
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local path = (dialog:getInputText() or ""):gsub("%s", "")
                    UIManager:close(dialog)
                    if path == "" then return end
                    Core:set("serial_device", path)
                    self:refreshMenu()
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Duo:showTokenDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Pairing code"),
        description = _("Both devices must use the same code. Leave it empty to let any device connect."),
        input = Core:get("token"),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("New code"),
                callback = function()
                    UIManager:close(dialog)
                    Core:set("token", Util.newPairingToken(6))
                    self:refreshMenu()
                end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    Core:set("token", Util.normalizeToken(dialog:getInputText()))
                    UIManager:close(dialog)
                    self:refreshMenu()
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Duo:showNameDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Device name"),
        description = _("Shown on the other device when pairing."),
        input = Core:getDeviceName(),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    Core:set("device_name", dialog:getInputText() or "")
                    UIManager:close(dialog)
                    self:refreshMenu()
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Duo:showPortDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Port"),
        description = _("Both devices must use the same port. Change this only if something else is already using it."),
        input = tostring(Core:get("port")),
        input_type = "number",
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local port = tonumber(dialog:getInputText())
                    UIManager:close(dialog)
                    if not port or port < 1024 or port > 65535 then
                        UIManager:show(InfoMessage:new{
                            text = _("Pick a port between 1024 and 65535."),
                        })
                        return
                    end
                    local was_active = Core:isActive()
                    local role = Core.role
                    Core:set("port", port)
                    Core.settings.peer_port = port
                    Core:save()
                    if was_active then
                        UIManager:show(ConfirmBox:new{
                            text = _("Restart Duo with the new port?"),
                            ok_callback = function() Core:start(role) end,
                        })
                    end
                    self:refreshMenu()
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return Duo
