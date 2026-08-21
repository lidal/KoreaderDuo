--[[--
KOReader Duo — turn two devices into one two-page spread.

One device is the leader: it owns the page number and tells the other what
to show. The other is the follower: it displays whatever it is told and can
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
local Browser = require("duo/browser")
local Spread = require("duo/spread")
local Typography = require("duo/typography")
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
            log = function(...)
                logger.dbg("Duo:", ...)
                Duo:writeLog(...)
            end,
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
            onChanged = function() Duo:onCoreChanged() end,
            openDocument = function(file, msg) self:openRemoteDocument(file, msg) end,
            -- `self`, not `Duo`: this one needs the live instance's `ui`,
            -- and the module table has none.
            closeDocument = function() self:closeRemoteDocument() end,
            sleepDevice = function() Duo:sleepForPeer() end,
            reviveDirectLink = function(quiet, force) return Duo:reviveDirectLink(quiet, force) end,
            defaultDeviceName = function() return Duo:getDefaultDeviceName() end,
            getBookDir = function() return Duo:getBookDir() end,
            getTempDir = function() return Duo:getTempDir() end,
            setAwake = function(awake) Duo:setAwake(awake) end,
            getFrontlight = function() return Duo:getFrontlight() end,
            -- `self`, not `Duo`: the events go to the live UI, which is
            -- where KOReader registers the DeviceListener that answers them.
            applyFrontlight = function(wanted) return self:applyFrontlight(wanted) end,
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
    elseif Browser.isAvailable(self.ui) then
        self:bindBrowser()
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

--------------------------------------------------------------------------
-- The log file
--------------------------------------------------------------------------

--[[--
Where Duo's log lives.

Beside KOReader's own `crash.log`, in the data folder, because that is the
folder somebody already knows how to find over a USB cable -- and because a
log nobody can lay hands on is not a log, it is a habit.
--]]--
function Duo:getLogPath()
    return DataStorage:getDataDir() .. "/duo.log"
end

--[[--
The open log, if there is meant to be one.

Held on the module rather than the instance: KOReader rebuilds the plugin
every time a document opens or closes, and a log that started again from
nothing at each of those would lose the moment worth reading about.
--]]--
function Duo:getLogWriter()
    if not Core:get("debug_log") then
        if Duo.log_writer then
            Duo.log_writer:close()
            Duo.log_writer = nil
        end
        return nil
    end
    if Duo.log_writer then return Duo.log_writer end
    local Log = require("duo/log")
    -- The data folder is always there on a reader; making it anyway costs
    -- one failed syscall and means a log is never lost to a missing folder.
    local lfs = require("libs/libkoreader-lfs")
    pcall(lfs.mkdir, DataStorage:getDataDir())
    local writer, err = Log.open(self:getLogPath())
    if not writer then
        logger.warn("Duo: could not open the log:", tostring(err))
        -- Switched off rather than retried on every line: a card with no
        -- room on it will not have any by the next page turn either.
        Core:set("debug_log", false)
        return nil
    end
    Duo.log_writer = writer
    writer:write(("-- Duo log opened %s"):format(os.date("%Y-%m-%d %H:%M:%S")))
    writer:write(self:describeEnvironment())
    return writer
end

--- KOReader's version, asked for rather than required: this file has no
--- other use for it, and a build that has moved it must not stop the log.
function Duo:getReaderVersion()
    local ok, Version = pcall(require, "version")
    if not ok or not Version then return "?" end
    local read, revision = pcall(function() return Version:getCurrentRevision() end)
    return read and tostring(revision) or "?"
end

--- One line saying what this device is, which every report needs and
--- nobody remembers to include.
function Duo:describeEnvironment()
    local parts = {
        ("device=%s"):format(tostring(Device and Device.model or "?")),
        ("koreader=%s"):format(Duo:getReaderVersion()),
        ("role=%s"):format(tostring(Core.role)),
        ("transport=%s"):format(tostring(Core:get("transport"))),
        ("mode=%s"):format(tostring(Core:get("mode"))),
    }
    return "-- " .. table.concat(parts, " ")
end

--[[--
Says where the log is and offers to start a fresh one.

Starting fresh matters more than it looks. The useful log is the one that
holds the thing that went wrong and not much else, so the way to use this
is: clear it, do the thing, copy the file off.
--]]--
function Duo:showLogDialog()
    local lfs = require("libs/libkoreader-lfs")
    local path = self:getLogPath()
    local attributes = lfs.attributes(path)
    local size = attributes and attributes.size or 0
    local lines = {
        T(_("Duo writes its log to:\n%1"), path),
        T(_("Size: %1 KB"), math.floor(size / 1024 + 0.5)),
        _("Connect the device over USB and copy that file off it. If a second file sits beside it ending in .1, it holds what came before; both are worth having."),
    }
    local dialog
    dialog = ConfirmBox:new{
        text = table.concat(lines, "\n\n"),
        ok_text = _("Start a fresh log"),
        ok_callback = function()
            if Duo.log_writer then
                Duo.log_writer:close()
                Duo.log_writer = nil
            end
            os.remove(path .. ".1")
            os.remove(path)
            Core:log("log started fresh by hand")
            UIManager:show(InfoMessage:new{
                text = _("The log has been cleared. Do the thing that goes wrong, then copy the file off."),
                timeout = 4,
            })
        end,
        cancel_text = _("Close"),
    }
    UIManager:show(dialog)
end

function Duo:writeLog(...)
    local writer = self:getLogWriter()
    if not writer then return end
    local Log = require("duo/log")
    writer:write(Log.format(Core.role, ...))
end

--[[--
Where a book sent by the other device is put.

Books, with the books — not in a folder of Duo's own. A `Duo` subfolder was
tidy from the plugin's point of view and wrong from the reader's: books
arrived somewhere nobody browses, so they had to be found before they could
be read.

The shelf is looked for in the order a reader would expect to find it: what
the user set here, then a `books` folder beside KOReader's own directory —
`/mnt/us/books` on a Kindle, which is where books live on one — then
KOReader's configured home, and only failing all of that a folder of our
own making.
--]]--
function Duo:getBookDir()
    local lfs = require("libs/libkoreader-lfs")
    local function usable(path)
        if not path or path == "" then return nil end
        if lfs.attributes(path, "mode") == "directory" then return path end
        return nil
    end

    local chosen = Core:get("book_dir")
    if chosen and chosen ~= "" then
        if not usable(chosen) then lfs.mkdir(chosen) end
        if usable(chosen) then return chosen end
    end

    -- KOReader sits next to the shelf rather than inside it: /mnt/us/koreader
    -- and /mnt/us/books on a Kindle, and the same shape elsewhere.
    local data = DataStorage:getDataDir()
    local beside = (data:match("^(.*)/[^/]+$") or data) .. "/books"
    if usable(beside) then return beside end

    local home = usable(G_reader_settings and G_reader_settings:readSetting("home_dir"))
    if home then return home end

    -- Nothing to join: make the shelf rather than hide the books away.
    lfs.mkdir(beside)
    return usable(beside) or data
end

--- Lets the user say where books should land, starting from where they do.
function Duo:chooseBookDir()
    local ok, PathChooser = pcall(require, "ui/widget/pathchooser")
    if not ok or not PathChooser then
        UIManager:show(InfoMessage:new{
            text = _("This build of KOReader has no folder chooser."),
        })
        return
    end
    UIManager:show(PathChooser:new{
        select_directory = true,
        select_file = false,
        path = self:getBookDir(),
        onConfirm = function(path)
            Core:set("book_dir", path or "")
            self:refreshMenu()
            UIManager:show(InfoMessage:new{
                text = T(_("Books from the other device will arrive in %1."), self:getBookDir()),
                timeout = 3,
            })
        end,
    })
end

--- Somewhere to build a stand-in before sending it, out of the way of the
--- library so it never turns up in a listing.
function Duo:getTempDir()
    local directory = DataStorage:getDataDir() .. "/cache/duo"
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(directory, "mode") ~= "directory" then
        lfs.mkdir(DataStorage:getDataDir() .. "/cache")
        lfs.mkdir(directory)
    end
    return directory
end

--[[--
Keeps the UI loop ticking while Duo is running, or lets it stop.

The count lives on the class rather than the instance: KOReader rebuilds
the instance on every document switch, and a hold taken by one instance has
to be released by whichever one is alive when Duo stops. UIManager asserts
on an unbalanced release, so the flag matters.
--]]--
function Duo:setAwake(awake)
    if awake and not Duo.standby_held then
        Duo.standby_held = true
        UIManager:preventStandby()
    elseif not awake and Duo.standby_held then
        Duo.standby_held = false
        UIManager:allowStandby()
    end
end

--- KOReader is about to let the device doze, or has just stopped.
-- Only ever reaches the plugin when nothing is holding standby off, which
-- is exactly the state a leader sits in and a follower does not.
function Duo:onAllowStandby()
    Core:setDeviceIdle(true)
end

function Duo:onPreventStandby()
    Core:setDeviceIdle(false)
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
    self:unwrapBrowserTurns()
    self:unwrapFileOpening()
    Core:detachReader(self.reader_binding)
    Core:detachBrowser(self.browser_binding)
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
        getTypography = function()
            return Typography.snapshot(ui)
        end,
        applyTypography = function(settings)
            return Typography.apply(ui, settings, Event)
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
-- The book list
--------------------------------------------------------------------------

--[[--
Hands the file browser to the engine, so the listing can be spread too.

Only exists in the file manager; KOReader replaces the whole thing with a
ReaderUI when a book is opened, which is why this is attached and detached
just like the reader binding.
--]]--
function Duo:bindBrowser()
    local ui = self.ui
    if not Browser.isAvailable(ui) then return end
    -- Already bound to this very browser: nothing to redo.
    if self.browser_binding and self.wrapped_chooser == ui.file_chooser then return end
    self:wrapBrowserTurns()
    self:wrapFileOpening()

    self.browser_binding = {
        getState = function()
            local state = Browser.snapshot(ui)
            if state then
                state.signature = Browser.signature(ui)
            end
            return state
        end,
        goToPage = function(page) return Browser.goToPage(ui, page) end,
        getFiles = function() return Browser.fileEntries(ui) end,
        refresh = function() return Browser.refresh(ui) end,
        changeDir = function(path) return Browser.changeDir(ui, path) end,
        setPerPage = function(perpage, cols, rows)
            return Browser.setPerPage(ui, perpage, cols, rows)
        end,
    }
    Core:attachBrowser(self.browser_binding)
end

--[[--
Wraps the browser's page turns, the same trick as in the reader.

`onNextPage` and `onPrevPage` are where every swipe and button press in the
file list ends up, so wrapping them catches the lot. They are left alone
when Duo is not sharing the listing.
--]]--
function Duo:wrapBrowserTurns()
    local chooser = self.ui and self.ui.file_chooser
    if not chooser or chooser.duo_wrapped then return end

    local original_next = chooser.onNextPage
    local original_prev = chooser.onPrevPage
    if not original_next or not original_prev then return end
    self.wrapped_chooser = chooser
    self.original_browser_turns = { next = original_next, prev = original_prev }
    chooser.duo_wrapped = true

    chooser.onNextPage = function(menu, ...)
        if Core:handleBrowserTurn(1) then return true end
        return original_next(menu, ...)
    end
    chooser.onPrevPage = function(menu, ...)
        if Core:handleBrowserTurn(-1) then return true end
        return original_prev(menu, ...)
    end
end

function Duo:unwrapBrowserTurns()
    local chooser = self.wrapped_chooser
    if chooser then
        chooser.onNextPage = nil -- unshadow the class methods
        chooser.onPrevPage = nil
        chooser.duo_wrapped = nil
    end
    self.wrapped_chooser = nil
    self.original_browser_turns = nil
end

--[[--
The file manager announces its folder, and the spread follows.

This is also where the browser first gets bound. KOReader builds the file
chooser in `setupLayout()`, which runs *after* the plugins are created, so
there is nothing to bind to at init time — but `PathChanged` is dispatched
immediately afterwards, and again on every folder change, which makes it
exactly the right moment.
--]]--
function Duo:onPathChanged()
    self:bindBrowser()
    if Core:isLeader() then
        Core:broadcastBrowser()
    end
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

--- Whether this device is asleep or on its way, on the class rather than
--- the instance: KOReader rebuilds the instance and the answer must not
--- go with it.
function Duo:onSuspend()
    Duo.suspending = true
    Core:suspend()
end

function Duo:onResume()
    Duo.suspending = false
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
    if Core:isLeader() then
        Core:broadcastDocument()
        Core:broadcastState()
        Core:notify(_("Duo: resent the current page"))
    else
        local link = Core:getReadyLinks()[1]
        if link then
            link:send(require("duo/protocol").SYNC, {})
            Core:notify(_("Duo: asked the leader where we are"))
        end
    end
end

--[[--
Catches a tap on a book that is not really here yet.

The file manager funnels every way of opening a book — a tap, the history,
a search result — through `openFile`, so wrapping it catches the lot. A
stand-in is sent to Duo to be filled in first; everything else is opened
exactly as it would have been.
--]]--
function Duo:wrapFileOpening()
    local ui = self.ui
    if not ui or type(ui.openFile) ~= "function" then return end
    if self.wrapped_open == ui then return end
    self.wrapped_open = ui

    local original = ui.openFile
    self.original_open_file = original
    ui.openFile = function(manager, file, ...)
        if Duo:fetchBeforeOpening(file) then return true end
        return original(manager, file, ...)
    end
end

function Duo:unwrapFileOpening()
    if self.wrapped_open and self.original_open_file then
        self.wrapped_open.openFile = self.original_open_file
    end
    self.wrapped_open = nil
    self.original_open_file = nil
end

--[[--
Decides what a tap on a book in the list means on this device.

On the leader it means what it always did. On a follower there are two other
possibilities: the file is a stand-in, and the real book has to be fetched
before there is anything to open; or it is a real book, and the pair should
open it together rather than this device wandering off into it alone.

@treturn boolean true when Duo took the tap and the file manager should not
--]]--
function Duo:fetchBeforeOpening(file)
    if type(file) ~= "string" then return false end
    if not Core:isConnected() or Core:isLeader() then return false end

    if not file:lower():match("%.epub$") or not Core:isStub(file) then
        -- A book both devices can open: let the leader lead the way in, so
        -- it stays the one deciding what page everybody is on.
        local name = select(2, util.splitFilePathName(file))
        if not Core:requestOpen(file, name) then return false end
        -- The book opens when the leader's answer comes back, a moment
        -- later. Saying so means the tap is never silent in between.
        UIManager:show(InfoMessage:new{
            text = T(_("Opening %1 on both devices…"), name),
            timeout = 2,
        })
        return true
    end

    local name = file:gsub("^.*/", "")
    if not Core:fetchBookFor(file, name) then
        UIManager:show(InfoMessage:new{
            text = T(_("Duo is already fetching a book. %1 will have to wait its turn."), name),
        })
        return true
    end
    UIManager:show(InfoMessage:new{
        text = T(_("Fetching %1 from the other device — it will open when it arrives."), name),
        timeout = 3,
    })
    return true
end

--------------------------------------------------------------------------
-- Following the leader's book
--------------------------------------------------------------------------

--- Opens the book the leader just opened.
-- Two Kindles usually store the same book at the same path, but when they
-- do not, the reading history is a good second guess before giving up.
function Duo:openRemoteDocument(file, msg)
    local lfs = require("libs/libkoreader-lfs")
    --[[
    A book that has this moment landed is the book, whatever stood at that
    path before it. Asking again whether it is a stand-in would find the one
    it just landed on top of — for ever, on a device that cannot read the
    marker back out — and the answer would send it off to fetch the same
    book again instead of opening the copy already here.
    ]]
    local arrived = msg and msg.arrived
    local function here(path)
        --[[
        A stand-in is a file, so every "is it here?" test said yes to one.
        The pair then went into a book on the leader and into a few hundred
        bytes of cover and title on the follower — the dummy, opened
        instead of fetched, which is the exact opposite of what a stand-in
        is for. It stands in until somebody wants the book; this is
        somebody wanting the book.
        ]]
        return path and lfs.attributes(path, "mode") == "file"
            and (arrived or not Core:isStub(path))
    end
    local target = file
    local standing_in = not arrived
        and lfs.attributes(file, "mode") == "file" and Core:isStub(file)
    if not here(target) then
        target = self:findLocalCopy(file, msg)
        if not here(target) then target = nil end
    end
    if not target then
        -- A stand-in on the shelf is asked for by name, so the book lands
        -- on top of it and the shelf keeps one entry rather than growing a
        -- second copy somewhere else.
        if standing_in and Core:fetchBookFor(file, file:gsub("^.*/", "")) then
            UIManager:show(InfoMessage:new{
                text = T(_("Fetching %1 from the other device — it will open when it arrives."),
                         file:gsub("^.*/", "")),
                timeout = 3,
            })
            return
        end
        -- Not here, and not anywhere else on this device: ask for it.
        if msg and Core:requestBook(msg) then
            return
        end
        UIManager:show(InfoMessage:new{
            text = T(_("Duo: the other device is reading a book this one does not have:\n%1"),
                     msg and msg.title ~= "" and msg.title or file),
        })
        return
    end
    local ReaderUI = require("apps/reader/readerui")
    UIManager:nextTick(function()
        ReaderUI:showReader(target)
    end)
end

--[[--
Closes the book, because the other device closed its own.

KOReader's own "back to the file list" is the Home event: the reader tears
itself down and the file manager comes up in its place, which is exactly
what the leader just did. Doing it on the next tick because this arrives
from inside the poll loop, and closing the widget that is polling from
underneath itself does not end well.
--]]--
function Duo:closeRemoteDocument()
    if not self.ui or not self.ui.document then return end
    UIManager:nextTick(function()
        local ui = self.ui
        if ui and ui.document and ui.handleEvent then
            ui:handleEvent(Event:new("Home"))
        end
    end)
end

--[[--
This device's frontlight, as proportions of its own range.

Proportions rather than levels because the ranges differ: KOReader drives a
Kindle's light from 0 to 24 and a Kobo's from 0 to 100, so a number that
means "bright" on one is nearly off on the other.
--]]--
function Duo:getFrontlight()
    if not Device.hasFrontlight or not Device:hasFrontlight() then return nil end
    local powerd = Device:getPowerDevice()
    if not powerd then return nil end
    return require("duo/frontlight").snapshot(powerd, Device)
end

--[[--
Sets the light to match the other device.

Through KOReader's own events rather than powerd directly, so whatever else
is watching the light — the status bar, a profile, the frontlight dialog —
finds out about the change the same way it would from a gesture.

@treturn ?table what was actually changed, in device levels
--]]--
function Duo:applyFrontlight(wanted)
    if not Device.hasFrontlight or not Device:hasFrontlight() then return nil end
    local powerd = Device:getPowerDevice()
    if not powerd then return nil end

    local changes = require("duo/frontlight").differences(wanted, powerd, Device)
    if not changes then return nil end

    local target = self.ui or (UIManager.getTopWidget and UIManager:getTopWidget())
    local function fire(name, value)
        if target and target.handleEvent then
            target:handleEvent(Event:new(name, value))
        else
            UIManager:broadcastEvent(Event:new(name, value))
        end
    end
    if changes.intensity then fire("SetFlIntensity", changes.intensity) end
    if changes.warmth then fire("SetFlWarmth", changes.warmth) end
    --[[
    The switch last, and only if it is still wrong.

    Setting a brightness on a reader whose light is off turns it on by
    itself on some devices, so the state has to be read back rather than
    assumed. There is no event for "be on": KOReader has a toggle, which is
    the right thing to send precisely because the two are known to differ.
    ]]
    if changes.on ~= nil then
        local still_wrong = true
        if powerd.isFrontlightOn then
            local ok, on = pcall(powerd.isFrontlightOn, powerd)
            if ok and on ~= nil then still_wrong = (on and true or false) ~= changes.on end
        end
        if still_wrong then
            fire("ToggleFrontlight")
        else
            changes.on = nil
        end
    end
    return changes
end

--[[--
Locks this device, because the other one is being locked.

Refuses outright if this device is already asleep or on its way there.
KOReader suspends a Kindle by asking its power daemon to press the power
button, and a press is a toggle: on a sleeping device it does not sleep it
harder, it wakes it up. Both readers being put down within a moment of each
other is the ordinary case rather than a rare one, so without this the pair
took turns waking each other.
--]]--
function Duo:sleepForPeer()
    if Duo.suspending then
        logger.dbg("Duo: already asleep or on the way; not pressing the button again")
        return
    end
    Duo.suspending = true
    UIManager:nextTick(function()
        UIManager:suspend()
    end)
end

--[[--
Rebuilds a Wi-Fi link this device set up itself.

Only for a link Duo made: an ordinary network is the system's business and
taking it over uninvited would be a rude way to recover from a nap. The
script checks what the interface is doing before changing anything, so a
link that survived the sleep costs a status call and nothing more.
--]]--
--[[--
Which side of a direct link this device is, or nil for an ordinary network.

Three answers, not two. "host" and "join" are recorded when the link comes
up from the menu; **"off"** is recorded when somebody hands Wi-Fi back, and
means *do not go looking* — without it, nothing meant "ask again", and the
answer was worked out afresh from an address that handing Wi-Fi back did
not clear. The link then rebuilt itself moments after being dismantled,
which from outside looks like the plugin refusing to let go.

Only when nothing has been recorded at all is it worked out from the
addresses, which are fixed and used by nothing else. That is for a link set
up by hand over SSH, which leaves nothing else behind saying so.
--]]--
function Duo:directLinkRole()
    local stored = Core:get("direct_link")
    if stored == "host" or stored == "join" then return stored end
    if stored == "off" then return nil end

    local DirectLink = require("duo/directlink")
    local role
    if Core:get("peer_host") == DirectLink.HOST_ADDRESS then
        role = "join"
    elseif NetUtil.getLocalIP() == DirectLink.HOST_ADDRESS then
        role = "host"
    end
    if role then
        logger.dbg("Duo: this looks like a direct link set up by hand:", role)
        Core:set("direct_link", role)
    end
    return role
end

--[[--
Records that this pairing is over an ordinary network.

Asked for by choosing that on the first screen, which is as plain a
statement of intent as there is — so nothing should be quietly rebuilding a
router-free link underneath it. The one exception is somebody who built
such a link by hand and is now pairing across it by address: that is still
a direct link whatever route they took to it, and the address says so.
--]]--
function Duo:notOnADirectLink()
    local DirectLink = require("duo/directlink")
    if Core:get("peer_host") == DirectLink.HOST_ADDRESS
        or NetUtil.getLocalIP() == DirectLink.HOST_ADDRESS then
        return
    end
    Core:set("direct_link", "off")
end

--[[--
Puts a link Duo built back up, and says out loud what it found.

Deliberately noisy. Everything here happens while nobody is looking — a
device wakes, checks its own network, and either finds it or does not — and
a silent failure is indistinguishable from a plugin that does not work. One
line when it rebuilds, one when it succeeds, and the script's own words
when it does not.

`force` skips asking whether the link looks well and simply rebuilds it,
which is what running the script by hand does and what actually works. The
check is worth having when the pair is merely waking; it is worth nothing
once they have been unable to reach each other for a while, because by
then a link that looks up plainly is not, and the only thing the check can
do is talk you out of the fix.

@tparam[opt] boolean quiet  do not say anything about a link that is fine
@tparam[opt] boolean force  rebuild without asking whether it is needed
@treturn string  "up", "rebuilt", "failed", or "not-ours"
--]]--
function Duo:reviveDirectLink(quiet, force)
    local role = self:directLinkRole()
    if not role then return "not-ours" end

    local DirectLink = require("duo/directlink")
    if not force then
        local status = DirectLink.run("status") or ""
        if DirectLink.isUp(status, role) then
            logger.dbg("Duo: the direct link is still up")
            if not quiet then Core:notify(_("Duo: the direct link is up")) end
            return "up"
        end
    end

    logger.dbg("Duo: rebuilding the direct link, role", role, "forced", tostring(force))
    Core:notify(_("Duo: rebuilding the direct link…"))
    local output = (role == "host" and DirectLink.host() or DirectLink.join()) or ""
    local failure = output:match("\nerror: ([^\n]*)") or output:match("^error: ([^\n]*)")
    if failure then
        logger.dbg("Duo: rebuilding the direct link failed:", failure)
        Core:alert(T(_("Duo could not rebuild the direct link.\n\n%1"), failure))
        return "failed"
    end
    Core:notify(_("Duo: the direct link is back"))
    return "rebuilt"
end

--- Looks for the same book somewhere else on this device.
--[[--
How far down a shelf a book is looked for, and how many folders that search
may open.

A shelf is a handful of folders deep in practice. The search can afford to
be generous, because what it saves is sending a whole book over a link that
may be a serial cable -- but not unbounded, because a card full of files
should not stall a tap.
--]]--
local SEARCH_DEPTH = 4
local SEARCH_FOLDERS = 400

--- Every folder worth looking in for a book this device may already have.
function Duo:getSearchRoots()
    local roots, seen = {}, {}
    local function add(path)
        if type(path) ~= "string" or path == "" or seen[path] then return end
        seen[path] = true
        roots[#roots+1] = path
    end
    add(self:getBookDir())
    add(G_reader_settings and G_reader_settings:readSetting("home_dir"))
    -- The folder the pair was last browsing together, which is where a book
    -- copied across by hand is most likely to have been put.
    add(Core.shared_folder)
    return roots
end

--- Every file called `name` under `roots`, breadth first and bounded.
function Duo:findByName(roots, name)
    local lfs = require("libs/libkoreader-lfs")
    if not lfs.dir then return {} end
    local found, seen = {}, {}
    local queue, head = {}, 1
    for _, root in ipairs(roots) do queue[#queue+1] = { path = root, depth = 0 } end
    local budget = SEARCH_FOLDERS
    while head <= #queue and budget > 0 do
        local entry = queue[head]
        head = head + 1
        if not seen[entry.path] then
            seen[entry.path] = true
            budget = budget - 1
            local ok, iterator = pcall(lfs.dir, entry.path)
            if ok and iterator then
                for item in iterator do
                    -- Hidden folders are KOReader's own bookkeeping, and
                    -- `.` and `..` are a way to walk for ever.
                    if item:sub(1, 1) ~= "." then
                        local path = entry.path .. "/" .. item
                        local mode = lfs.attributes(path, "mode")
                        if mode == "file" then
                            if item == name then found[#found+1] = path end
                        elseif mode == "directory" and entry.depth < SEARCH_DEPTH then
                            queue[#queue+1] = { path = path, depth = entry.depth + 1 }
                        end
                    end
                end
            end
        end
    end
    return found
end

--- KOReader's own cheap fingerprint for a file, when it can be had.
function Duo:partialDigest(path)
    if not util.partialMd5 then return nil end
    local ok, digest = pcall(util.partialMd5, path)
    if ok and digest and digest ~= "" then return digest end
    return nil
end

--[[--
A copy of `file` already on this device, wherever it happens to live.

The other device names a book by its own absolute path, which says nothing
about where the same book sits here: two readers rarely agree on where the
shelf is, and never on what a Kindle calls it versus a Kobo.

The read history alone was not enough, and the gap was the common case. A
book copied onto both devices by hand has never been opened on either, so
it is in no history, and the device concluded it did not have the book and
asked for it to be sent -- a long transfer of a file already sitting on the
disk. So the shelf itself is searched too.

The digest decides between several files of the same name when there are
several and the other device said which it meant. It is a preference and
not a requirement: matching a name is the answer that avoids sending a
whole book across, and that is what this is for.

@string file  the path the other device used
@tparam[opt] table msg  the message describing the book, for its digest
--]]--
function Duo:findLocalCopy(file, msg)
    local lfs = require("libs/libkoreader-lfs")
    -- Note: `_` is gettext in this file, so the path half is discarded with
    -- select() rather than by naming it.
    local name = select(2, util.splitFilePathName(file))
    if not name or name == "" then return nil end

    local candidates, seen = {}, {}
    local function consider(path)
        if type(path) ~= "string" or path == "" or seen[path] then return end
        seen[path] = true
        if lfs.attributes(path, "mode") ~= "file" then return end
        -- A stand-in has the book's name and none of the book.
        if Core:isStub(path) then return end
        candidates[#candidates+1] = path
    end

    local ok, ReadHistory = pcall(require, "readhistory")
    if ok and ReadHistory and ReadHistory.hist then
        for _, item in ipairs(ReadHistory.hist) do
            if item.file and select(2, util.splitFilePathName(item.file)) == name then
                consider(item.file)
            end
        end
    end
    for _, path in ipairs(self:findByName(self:getSearchRoots(), name)) do
        consider(path)
    end

    if #candidates == 0 then return nil end
    local wanted = msg and msg.digest
    if wanted and wanted ~= "" then
        for _, path in ipairs(candidates) do
            if self:partialDigest(path) == wanted then return path end
        end
    end
    return candidates[1]
end

--------------------------------------------------------------------------
-- Connecting
--------------------------------------------------------------------------

--- The entry point for pairing: pick a role.
--[[--
Step one of pairing: how the two devices should reach each other.

Split in two because the old single screen asked two questions at once and
in the wrong order — two roles, plus a third button that was really a
different kind of link and then asked for the role again. Which page a
device holds has nothing to do with whether there is a router in the room,
so the link is settled first and the role second, the same two taps
whichever way you go.
--]]--
function Duo:showConnectDialog()
    local dialog
    local buttons = {
        {{
            text = _("Over a Wi-Fi network"),
            callback = function()
                UIManager:close(dialog)
                self:showRoleDialog("network")
            end,
        }},
        {{
            text = _("Directly, with no router"),
            callback = function()
                UIManager:close(dialog)
                self:showDirectRoleDialog()
            end,
        }},
    }
    -- Only worth offering once there is something to undo.
    if Core:get("direct_link") then
        buttons[#buttons+1] = {{
            text = _("Restore normal Wi-Fi"),
            callback = function()
                UIManager:close(dialog)
                self:restoreWifi()
            end,
        }}
    end
    buttons[#buttons+1] = {{
        text = _("Cancel"),
        callback = function() UIManager:close(dialog) end,
    }}

    dialog = ButtonDialog:new{
        title = _("Duo — two devices, one book\n\nHow should the two reach each other?"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

--[[--
Step two: which of the two devices this one is.

@string over  "network" for an ordinary network, "direct" for a link Duo
              makes itself
@tparam[opt] string preamble  what to say above the question
--]]--
function Duo:showRoleDialog(over, preamble)
    local dialog
    local title = preamble
        or _("Both devices on the same network.\n\nWhich one is this?")
    dialog = ButtonDialog:new{
        title = title,
        buttons = {
            {{
                text = _("This device leads (left page)"),
                callback = function()
                    UIManager:close(dialog)
                    if over == "direct" then
                        self:runDirectLink("host")
                    else
                        self:notOnADirectLink()
                        self:startLeader()
                    end
                end,
            }},
            {{
                text = _("This device follows (right page)"),
                callback = function()
                    UIManager:close(dialog)
                    if over == "direct" then
                        self:runDirectLink("join")
                    else
                        self:notOnADirectLink()
                        self:searchForLeader()
                    end
                end,
            }},
            {{
                text = _("Back"),
                callback = function()
                    UIManager:close(dialog)
                    self:showConnectDialog()
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

--[[--
The role question for a link Duo makes itself.

Asks the device what it can do before offering anything, so a reader whose
Wi-Fi cannot host a link says so here rather than after the choice is made.
--]]--
function Duo:showDirectRoleDialog()
    local DirectLink = require("duo/directlink")
    local report = DirectLink.probe()

    if not DirectLink.isPossible(report) then
        UIManager:show(InfoMessage:new{
            text = T(_([[
This device cannot make a Wi-Fi link of its own.

%1

Any network will do instead — a home router, or a phone hotspot with no internet on it.]]),
                DirectLink.describe(report)),
        })
        return
    end

    self:showRoleDialog("direct", T(_([[
A link with no router: one device makes the network, the other joins it.

%1

Which one is this? Takes over Wi-Fi while it runs.]]), DirectLink.describe(report)))
end

--[[--
Hands Wi-Fi back to the system and forgets the link Duo built.

The script puts the interface right and flicks the device's own Wi-Fi
switch; this then tells KOReader to reconnect, so its idea of the network
matches the one the device now actually has. Without that last step the
reader sits believing itself offline until something else asks it to look
again — which is why handing back used to mean restarting KOReader.
--]]--
function Duo:restoreWifi()
    local DirectLink = require("duo/directlink")
    Core:stop("restoring Wi-Fi")
    DirectLink.restore()
    -- "off", not nothing: nothing means "work it out", and what it would
    -- work it out from is the address cleared just below.
    Core:set("direct_link", "off")
    if Core:get("peer_host") == DirectLink.HOST_ADDRESS then
        -- The other device is not there any more, and leaving its address
        -- behind is what let the link put itself back up.
        Core:set("peer_host", "")
    end
    UIManager:show(InfoMessage:new{
        text = _("Wi-Fi handed back to the system.\n\nRejoining your usual network may take a few seconds. Do this on the other device too, or it will sit waiting on a link that is no longer there."),
        timeout = 5,
    })
    if NetworkMgr.restoreWifiAsync then
        UIManager:nextTick(function() pcall(function() NetworkMgr:restoreWifiAsync() end) end)
    end
end

function Duo:startLeader()
    local function go()
        if Core:start(Core.ROLE_LEADER) then
            self:showPairingSheet()
        end
    end
    -- A leader with no network is a leader nobody can reach.
    if NetworkMgr:isConnected() then
        go()
    else
        NetworkMgr:promptWifiOn(go)
    end
end

--- The screen you read out to the other device.
--[[--
What to do on the other device, now that this one is listening.

The direct-link case needs more than the ordinary one. On a network both
devices are already on, the other device only has to search. On a link this
device is *hosting*, the other device has to get onto that network first —
and only another reader running Duo can do that by itself, from the same
menu. Anything else has to be told the name and the passphrase, so those
are on the sheet rather than buried in a script.

@tparam[opt] table options  direct=true when this device is hosting the link
--]]--
function Duo:showPairingSheet(options)
    options = options or {}
    local address = NetUtil.getLocalIP() or _("unknown — check Wi-Fi")
    local text

    if options.direct then
        local DirectLink = require("duo/directlink")
        local report = options.report or DirectLink.probe() or {}
        local others = _([[Anything else: join this Wi-Fi network, then tap "Connect to a leader".]])
        if options.mode == "ibss" then
            others = _([[This is an ad-hoc cell, not an access point. Another reader still joins it as above, but most phones and laptops will not list it at all.]])
        end
        text = T(_([[
Duo leader is running, on a link this device is hosting.

Another reader: open Duo, tap "Directly, with no router", then "This device follows". Nothing to type.

%1

Network:    %2
Passphrase: %3
Address:    %4:%5
Code:       %6]]),
            others, report.ssid or "KOReaderDuo", report.passphrase or "koreaderduo",
            address, Core:get("port"), Core:ensureToken())
    else
        text = T(_([[
Duo leader is running.

On the other device, open Duo and tap "Connect to a leader". It should find this one by itself.

Name:    %1
Address: %2:%3
Code:    %4]]),
            Core:getDeviceName(), address, Core:get("port"), Core:ensureToken())
    end
    UIManager:show(InfoMessage:new{ text = text, timeout = 60 })
end

--- Searches the network, then offers whatever it found.
function Duo:searchForLeader()
    local function begin()
        local searching = InfoMessage:new{
            text = _("Looking for a leader on this network…"),
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
            self:searchForLeader()
        end,
    }}
    buttons[#buttons+1] = {{
        text = _("Cancel"),
        callback = function() UIManager:close(self.search_dialog) end,
    }}

    self.search_dialog = ButtonDialog:new{
        title = #results > 0
            and _("Found these devices:")
            or _("No leader answered.\n\nCheck that Duo is running as leader on the other device, and that both are on the same network."),
        buttons = buttons,
    }
    UIManager:show(self.search_dialog)
end

--- Connects, asking for the pairing code when the leader wants one.
function Duo:connectTo(host, port, locked)
    local function go()
        Core:start(Core.ROLE_FOLLOWER, { host = host, port = port })
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
        description = _("Type the code shown on the leader."),
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
        title = _("Leader address"),
        description = _("The address shown on the leader device, for example 192.168.1.24"),
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
    -- Remembered so it can be rebuilt after a sleep, which is the one thing
    -- a link nobody else is maintaining does not survive.
    Core:set("direct_link", role)
    if role == "host" then
        if Core:start(Core.ROLE_LEADER) then
            self:showPairingSheet{ direct = true, mode = DirectLink.modeOf(output) }
        end
    else
        -- The host is always at the same address, so there is nothing to
        -- search for and nothing to type.
        Core:set("peer_host", DirectLink.HOST_ADDRESS)
        Core:start(Core.ROLE_FOLLOWER, {
            host = DirectLink.HOST_ADDRESS,
            port = Core:get("peer_port"),
        })
    end
end

--------------------------------------------------------------------------
-- Menu
--------------------------------------------------------------------------

--[[--
Redraws the menu when the engine's idea of things has moved.

This is how a setting adopted from the other device reaches the screen. The
hook did nothing at all before, so the value crossed the link, was stored,
was used -- and the menu went on showing what it had been showing when it
was opened, which reads exactly like a setting that did not sync.

Throttled, because this also fires for every chunk of a book being copied
and the menu is on an e-ink screen.
--]]--
local MENU_REFRESH_INTERVAL = 1

function Duo:onCoreChanged()
    if not self.menu_container then return end
    local now = require("duo/util").now()
    if self.menu_refreshed_at and now - self.menu_refreshed_at < MENU_REFRESH_INTERVAL then
        return
    end
    self.menu_refreshed_at = now
    self:refreshMenu()
end

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
                    help_text = _("Leader shows page N, the other shows N+1. A turn moves the pair by two."),
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
                    help_text = _("Talk over TCP/IP. Bluetooth PAN counts: KOReader sees an ordinary network."),
                    checked_func = function() return not Core:usesSerial() end,
                    callback = function() self:setTransport(Core.TRANSPORT_TCP) end,
                },
                {
                    text = _("Check the direct link now"),
                    help_text = _("Ask whether the link Duo built is still there, and rebuild it if not. The same check that runs by itself when the two have been apart for a while — this one just says what it found straight away."),
                    enabled_func = function() return Duo:directLinkRole() ~= nil end,
                    keep_menu_open = true,
                    callback = function()
                        local found = self:reviveDirectLink()
                        if found == "up" then
                            UIManager:show(InfoMessage:new{
                                text = _("The direct link is still up.\n\nIf the two are not talking, the trouble is above the network."),
                            })
                        end
                    end,
                },
                {
                    text = _("Set up a direct link (no router)…"),
                    help_text = _("A Wi-Fi link between the two devices alone, for reading where there is no network."),
                    keep_menu_open = true,
                    callback = function() self:showDirectRoleDialog() end,
                },
                {
                    text = _("Serial line (RFCOMM or UART)"),
                    help_text = _("Talk over a character device rather than a network: a bound RFCOMM channel or a serial line. Set it up outside KOReader first — for Bluetooth, 'rfcomm bind /dev/rfcomm0 <address> 1'; for a wire, the port's name, with nothing else using it."),
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
            text = _("Match typography"),
            help_text = _([[Keep both devices laying the book out alike, so the pages line up.

Font, size, weight, spacing, margins, columns and zoom are matched; brightness, rotation and night mode are not.

On connecting, the leader's settings win. After that a change on either device moves the rest.]]),
            checked_func = function() return Core:get("match_typography") end,
            callback = function()
                Core:set("match_typography", not Core:get("match_typography"))
                if Core:get("match_typography") and Core:isLeader() then
                    Core:pushTypography("switched on")
                end
            end,
        },
        {
            text = _("Use this device's typography everywhere"),
            enabled_func = function() return Core:isConnected() and Core:get("match_typography") end,
            keep_menu_open = true,
            callback = function()
                Core:pushTypography("sent by hand")
                Core:notify(_("Duo: sent this device's typography"))
            end,
        },
        {
            text = _("Undo: restore my own typography"),
            enabled_func = function() return Core:hasTypographyBackup() end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self.menu_container = touchmenu_instance
                if Core:restoreTypography() then
                    Core:notify(_("Duo: put your own typography back"))
                end
                self:refreshMenu()
            end,
            separator = true,
        },
        {
            text = _("Page turns from the other device"),
            help_text = _("Let a tap on the follower turn the pair. Switch this off to make the follower a display only."),
            checked_func = function() return Core:get("follower_can_turn") end,
            callback = function() Core:set("follower_can_turn", not Core:get("follower_can_turn")) end,
        },
        {
            text = _("Follow the leader's book"),
            help_text = _("When the leader opens a book, open the same one here."),
            checked_func = function() return Core:get("follow_document") end,
            callback = function() Core:set("follow_document", not Core:get("follow_document")) end,
        },
        {
            text = _("Share the book list too"),
            help_text = _("Spread the file browser too: the first screenful of books here, the next one there. The halves only line up if both devices hold the same books."),
            checked_func = function() return Core:get("share_browser") end,
            callback = function()
                Core:set("share_browser", not Core:get("share_browser"))
                if Core:get("share_browser") then Core:broadcastBrowser() end
            end,
        },
        {
            text = _("Match the frontlight"),
            help_text = _("Keep both devices at the same brightness, and the same warmth where they have it. Sent as a proportion, so readers with different ranges still agree about what half means."),
            enabled_func = function() return Device:hasFrontlight() end,
            checked_func = function() return Core:get("sync_frontlight") end,
            callback = function()
                Core:set("sync_frontlight", not Core:get("sync_frontlight"))
                if Core:get("sync_frontlight") then Core:pushFrontlight("switched on") end
            end,
        },
        {
            text = _("Lock one, lock both"),
            help_text = _("Sleeping either device sleeps the other, rather than leaving one lit on a page nobody is reading."),
            checked_func = function() return Core:get("sleep_together") end,
            callback = function() Core:set("sleep_together", not Core:get("sleep_together")) end,
        },
        {
            text = _("Keep the whole library in step"),
            help_text = _("Fetch whatever books the shared folder is missing here. This is what makes a shared book list line up."),
            checked_func = function() return Core:get("sync_library") end,
            callback = function() Core:set("sync_library", not Core:get("sync_library")) end,
        },
        {
            text = _("Stop copying now"),
            help_text = _("Stops whatever is being copied, at both ends. A transfer over a link like this one can take a long time, and changing your mind halfway through is allowed."),
            enabled_func = function() return Core:isTransferring() end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self.menu_container = touchmenu_instance
                Core:cancelTransfer(_("transfer stopped"))
                self:refreshMenu()
            end,
        },
        {
            text_func = function()
                return T(_("Books arrive in: %1"), Duo:getBookDir())
            end,
            help_text = _("Where a book sent from the other device is saved, when it is not one of the shared folder's own. Books copied to line up a shared book list land in that folder instead, since that is the point of them."),
            keep_menu_open = true,
            callback = function() Duo:chooseBookDir() end,
        },
        {
            text = _("Covers now, books when you open them"),
            help_text = _("Fill the shelf with stand-ins carrying the cover and title, and fetch each book when you first open it. Far less to copy, and the list lines up at once. EPUB only; anything else is copied whole.\n\nOff by default, and not settled: it puts a transfer between the tap and the page, which needs the link up and the other device still holding the file. It may be removed."),
            enabled_func = function() return Core:get("sync_library") end,
            checked_func = function() return Core:get("covers_first") end,
            callback = function() Core:set("covers_first", not Core:get("covers_first")) end,
        },
        {
            text_func = function()
                if Core:isSyncingLibrary() then return _("Stop fetching books") end
                return _("Fetch any missing books now")
            end,
            help_text = _("Compare this folder with the leader's and pull over what is missing. Only the other device has anything to fetch."),
            -- The leader is where the books come from; it has nothing to fetch.
            enabled_func = function() return Core:isConnected() and not Core:isLeader() end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self.menu_container = touchmenu_instance
                if Core:isSyncingLibrary() then
                    Core:stopLibrarySync("stopped by hand")
                elseif Core.browser then
                    local state = Core.browser.getState()
                    if state and not Core:requestLibrary(state.path) then
                        Core:notify(_("Duo: nothing to fetch"))
                    end
                end
                self:refreshMenu()
            end,
            separator = true,
        },
        {
            text = _("Send the book if the other device lacks it"),
            help_text = _("When the leader opens a book this device lacks, fetch it over the same link. Only the book it actually has open can be sent."),
            checked_func = function() return Core:get("sync_books") end,
            callback = function() Core:set("sync_books", not Core:get("sync_books")) end,
        },
        {
            text = _("Start Duo when KOReader starts"),
            checked_func = function() return Core:get("autostart") end,
            callback = function() Core:set("autostart", not Core:get("autostart")) end,
            separator = true,
        },
        {
            text = _("Write a log file"),
            help_text = _("Keep a record of what Duo does, in a file you can copy off the device over USB. Off by default. Worth switching on before reproducing something that went wrong, and worth switching off again afterwards.\n\nThe log holds book and folder names, device names and addresses. It does not hold your pairing code or anything you have read."),
            checked_func = function() return Core:get("debug_log") end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self.menu_container = touchmenu_instance
                local wanted = not Core:get("debug_log")
                Core:set("debug_log", wanted)
                if wanted then
                    -- Opened now rather than on the next thing that happens,
                    -- so the menu can say where it is and be right.
                    Duo:getLogWriter()
                    Core:log("log switched on by hand")
                else
                    Core:log("log switched off by hand")
                    if Duo.log_writer then
                        Duo.log_writer:close()
                        Duo.log_writer = nil
                    end
                end
                self:refreshMenu()
            end,
        },
        {
            text_func = function()
                if not Core:get("debug_log") then return _("The log is off") end
                return T(_("Log: %1"), Duo:getLogPath())
            end,
            help_text = _("Where the log is written. Connect the device over USB and copy this file off it; there may be a second one beside it, ending .1, holding what came before."),
            enabled_func = function() return Core:get("debug_log") end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self.menu_container = touchmenu_instance
                Duo:showLogDialog()
            end,
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
            text = _("This build of KOReader cannot open a serial device, so Duo will stay on the network."),
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
        description = _("The device file for the Bluetooth channel. Bind the two to each other first."),
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
        description = _("Both devices must use the same port. Change it only if something else has it."),
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
