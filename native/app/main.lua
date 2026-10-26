--[[--
The application: a shelf, a book, and a wire to the other device.

Owns the device, the view stack and the Duo engine, and is the delegate
every view calls back into. Deliberately the only place that knows about
all three -- a view that could reach the engine directly is a view that can
move the page without the pair being told, and that is the one bug this
whole arrangement is arranged to prevent.

The loop is the shape e-ink wants: wait for something, do it, repaint only
if something changed, refresh once. Not a frame rate. A reader that
repaints when nothing happened is a reader whose battery goes in a day and
whose screen flashes while somebody is reading a page they have not
finished.

@module duonative.main
--]]--

local Widget = require("app/ui/widget")
local Library = require("app/views/library")
local Reader = require("app/views/reader")
local TypographyView = require("app/views/typography")
local DuoHost = require("app/duohost")
local Books = require("app/books")
local Light = require("app/light")
local Store = require("app/store")
local DeviceApi = require("app/device/api")
local EngineApi = require("app/engine/api")

local App = {}
App.__index = App

--[[--
@tparam table options
    device    a `device/api.lua` implementation, already open
    engine    an `engine/api.lua` implementation (the module, not a doc)
    book_dir  where the books are
    store     path to the settings file
--]]--
function App.new(options)
    options = options or {}
    local device = assert(options.device, "an app needs a device")
    local ok, missing = DeviceApi.check(device)
    if not ok then
        error("this device does not satisfy the contract: " .. tostring(missing), 2)
    end

    local width, height = device:size()
    local self = setmetatable({
        device = device,
        engine = assert(options.engine, "an app needs a document engine"),
        book_dir = options.book_dir or ".",
        store = Store.open(options.store or "/tmp/duonative-settings.lua"),
        rect = Widget.Rect.new(0, 0, width, height),
        stack = Widget.stack(),
        notices = {},
        running = false,
    }, App)

    self.duo = DuoHost.new{ app = self, store = self.store }
    self.layout = EngineApi.layout(self.store:get("layout"))

    self.library = Library.new{ path = self.book_dir, delegate = self }
    self.stack:reset(self.library)
    self.duo:attachBrowser(self.library)

    device:onSuspend(function() self:onSuspend() end)
    device:onResume(function() self:onResume() end)
    return self
end

--------------------------------------------------------------------------
-- The loop
--------------------------------------------------------------------------

--[[--
Draws, if anything changed, and refreshes once.

Full refresh when the screen changed identity -- shelf to book, book to
panel -- and partial otherwise. The distinction is the difference between
a page turn that feels instant and one that flashes the whole panel black,
and it is the single most noticeable thing about a reader's software.
--]]--
function App:draw(force)
    if not (self.stack.dirty or force) then return false end
    self.stack:paint(self.device:screen(), self.rect)
    local how = self.needs_full and DeviceApi.FULL or DeviceApi.PARTIAL
    self.needs_full = false
    self.device:refresh(self.rect, how)
    return true
end

function App:markDirty() self.stack:markDirty() end
function App:markFullRefresh() self.needs_full = true self.stack:markDirty() end

--[[--
One turn of the loop.

The engine is polled every time round, before and after whatever the user
did, because on a wire the other device can speak at any moment and the
only thing that notices is this call. The plugin's own note applies: what
a page turn waits for is not the link, it is the other device *noticing*.

@treturn boolean false when the app should stop
--]]--
function App:tick(timeout_ms)
    self.duo:poll()
    local event = self.device:poll(timeout_ms or 50)
    if event then
        if event.kind == "quit" then return false end
        self.stack:handle(event)
    end
    self.duo:poll()
    self:refreshSpreadLabel()
    self:draw()
    return true
end

function App:run()
    self.running = true
    self:markFullRefresh()
    self:draw(true)
    while self.running do
        if not self:tick() then break end
    end
    self.device:close()
    return true
end

function App:stop() self.running = false end

--------------------------------------------------------------------------
-- Books
--------------------------------------------------------------------------

--[[--
Opens a book and puts the reader on screen.

The engine's document replaces whatever was open, and the old one is
closed rather than left to the collector: CREngine holds a parsed DOM and
a rendered page cache, and on a device with 512MB two of those is the
difference between a reader and a reader that is killed by the kernel.
--]]--
function App:openBook(path, msg)
    if not path then return false end
    local doc, err = self.engine.open(path, {
        width = self.rect.w,
        height = self.rect.h,
        layout = self.layout,
    })
    if not doc then
        self:showNotice(tostring(err))
        return false
    end
    if self.reader and self.reader:document() then
        self.reader:document():close()
    end
    self.duo:detachReader()
    self.reader = Reader.new{ doc = doc, delegate = self }
    self.stack:reset(self.reader)
    self.duo:attachReader(self.reader)
    self:restorePosition(path, doc, msg)
    self:markFullRefresh()
    return true
end

--[[--
Back to where this book was last left.

Stored per book under its path. A position rather than a page, because the
font size may have changed since -- which is exactly the case a page number
gets wrong and quietly: the reader comes back to a page that is now in the
wrong chapter.
--]]--
function App:restorePosition(path, doc, msg)
    if msg and msg.arrived then return end
    local positions = self.store:get("positions", {})
    local saved = positions[path]
    if saved then doc:gotoPosition(saved) end
end

function App:rememberPosition()
    local doc = self.reader and self.reader:document()
    if not doc then return false end
    local positions = self.store:get("positions", {})
    positions[doc.path] = doc:position()
    self.store:set("positions", positions)
    self.store:flush()
    return true
end

function App:closeBook()
    if not self.reader then return false end
    self:rememberPosition()
    local doc = self.reader:document()
    if doc then doc:close() end
    self.duo:detachReader()
    self.reader = nil
    self.stack:reset(self.library)
    self.duo:attachBrowser(self.library)
    self.library:refresh()
    self:markFullRefresh()
    return true
end

--[[--
Rebuilds the book, which is what the engine asks for after some style changes.

Reopened at the position it was on rather than the page: the whole reason a
rebuild is being asked for is that the pagination is about to change.
--]]--
function App:reloadBook()
    local doc = self.reader and self.reader:document()
    if not doc then return false end
    local path, position = doc.path, doc:position()
    doc:close()
    local fresh, err = self.engine.open(path, {
        width = self.rect.w, height = self.rect.h, layout = self.layout,
    })
    if not fresh then
        self:showNotice(tostring(err))
        return false
    end
    fresh:gotoPosition(position)
    self.reader.doc = fresh
    self.duo:attachReader(self.reader)
    self:markFullRefresh()
    return true
end

--------------------------------------------------------------------------
-- What the views call back
--------------------------------------------------------------------------

function App:onTurnRequest(diff) return self.duo:onTurnRequest(diff) end
function App:onLibraryTurn(diff) return self.duo:onLibraryTurn(diff) end

--- Every page change, reported to the engine, which sorts out whose it was.
function App:onPageMoved(page) return self.duo:onPageChanged(page) end
function App:onReflow(doc)
    self.layout = doc:getLayout()
    self.store:set("layout", self.layout)
    self.store:flush()
    self:markFullRefresh()
    return self.duo:onReflow(doc)
end

function App:onBookChosen(path) return self:openBook(path) end

function App:onLibraryUp(path)
    local moved = self.library:changeDir(path)
    if moved then self:markFullRefresh() end
    return moved
end

--[[--
The menu, which for now is the typography panel and a way out of the book.

One screen rather than a tree of them. A reader has few enough settings
that worth having a menu to navigate is a thing to be suspicious of, and
the two-device settings live on the other side of the engine anyway.
--]]--
function App:onMenuRequest()
    if not self.reader then return false end
    local panel
    panel = TypographyView.new{
        layout = self.reader:getLayout(),
        onApply = function(layout) self.reader:applyLayout(layout) end,
        onClose = function()
            self.stack:pop()
            self:markFullRefresh()
        end,
    }
    self.stack:push(panel)
    self:markFullRefresh()
    return true
end

function App:onProgressRequest(fraction)
    local doc = self.reader and self.reader:document()
    if not doc then return false end
    local page = math.max(1, math.floor(fraction * doc:pageCount() + 0.5))
    -- Through the reader, which reports the move itself.
    return self.reader:gotoPage(page)
end

function App:coverFor(path, width, height)
    -- Covers are asked for while drawing, so this must never parse a book.
    -- Cached on first sight and nil until then, which draws an outline.
    self.covers = self.covers or {}
    if self.covers[path] ~= nil then return self.covers[path] or nil end
    self.covers[path] = false
    return nil
end

--------------------------------------------------------------------------
-- What the engine asks of the host
--------------------------------------------------------------------------

function App:bookDir() return self.book_dir end
function App:listFolder(path) return Books.list(path or self.book_dir) end
function App:deviceName() return self.store:get("device_name", "duo") end

function App:showNotice(text)
    self.notices[#self.notices+1] = tostring(text)
    if #self.notices > 20 then table.remove(self.notices, 1) end
    self:markDirty()
    return true
end

--[[--
The light, through the plugin's own module.

Both of these have an exact contract that is easy to get wrong, and this
pair got it wrong first time: `getFrontlight` must return percentages, not
raw levels, and `applyFrontlight` must return the table of changes it made
or nil -- never a boolean, which the engine then indexes and dies on. See
`light.lua`.
--]]--
function App:getFrontlight()
    return Light.snapshot(self.device)
end

function App:applyFrontlight(wanted)
    return Light.apply(self.device, wanted)
end

function App:setAwake() return true end

function App:sleep()
    self:rememberPosition()
    return true
end

function App:onSuspend()
    self:rememberPosition()
    return true
end

--[[--
Back from sleep.

A full refresh, unconditionally. E-ink holds its last frame with no power
at all, so what is on the panel after a suspend is whatever was there
before it -- which may be a screensaver this app did not draw, and which a
partial refresh would leave half of.
--]]--
function App:onResume()
    self:markFullRefresh()
    return true
end

function App:refreshSpreadLabel()
    local label = self.duo:spreadLabel()
    if label == self.last_spread_label then return end
    self.last_spread_label = label
    if self.reader then self.reader:setSpreadLabel(label) end
    if self.library then self.library:setSpreadLabel(label) end
    self:markDirty()
end

return App
