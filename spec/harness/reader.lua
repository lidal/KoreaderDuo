--[[--
A stand-in ReaderUI, with just enough of a document to turn pages in.

The paging module below follows KOReader's real one closely on the two
points the plugin depends on:

  * `onGotoViewRel(diff, no_page_turn)` is the funnel every tap, swipe and
    button press goes through, and `no_page_turn == true` means "look, do
    not move" (ReaderSearch does that);
  * changing the page emits a `PageUpdate` event that keeps propagating
    after the paging module has seen it, which is how plugins hear about it.

ReaderUI dispatches to its modules in registration order and stops at the
first one that returns true — plugins are registered last, which is exactly
why Duo wraps the paging module rather than listening for the event.

@module spec.harness.reader
--]]--

local Reader = {}

local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

--------------------------------------------------------------------------
-- Document
--------------------------------------------------------------------------

local Document = {}
Document.__index = Document

function Reader.newDocument(options)
    options = options or {}
    -- With a real book loaded, the page count comes from its layout and the
    -- pages have text on them; without one, the document is just a count.
    local book = options.book
    return setmetatable({
        file = options.file or (book and book.path) or "/books/moby-dick.epub",
        book = book,
        page_count = book and book:getPageCount() or options.page_count or 300,
        pages_per_view = options.pages_per_view or 1,
        info = { has_pages = options.has_pages ~= false },
    }, Document)
end

function Document:getPageCount() return self.page_count end

--- The text on a page, when a real book is loaded.
function Document:getPageText(number)
    if not self.book then return "" end
    return self.book:getPageText(number)
end
function Document:getVisiblePageNumberCount() return self.pages_per_view end

--------------------------------------------------------------------------
-- Paging
--------------------------------------------------------------------------

local Paging = {}
Paging.__index = Paging

function Reader.newPaging(ui)
    return setmetatable({ ui = ui, current_page = 1 }, Paging)
end

--- Dispatches like KOReader's EventListener: call on<Name> if we have it.
function Paging:handleEvent(event)
    local handler = self[event.handler]
    if handler then
        return handler(self, unpack(event.args, 1, event.args.n))
    end
end

function Paging:onGotoViewRel(diff, no_page_turn)
    if no_page_turn == true then return end
    self:gotoPageInternal(self.current_page + diff)
    return true
end

function Paging:onGotoPage(page)
    self:gotoPageInternal(page)
    return true
end

function Paging:onPageUpdate(page)
    self.current_page = page
    -- Returns nothing on purpose: the event must reach the plugin too.
end

function Paging:gotoPageInternal(page)
    local target = clamp(page, 1, self.ui.document:getPageCount())
    if target == self.current_page then return end
    self.current_page = target
    self.ui:handleEvent(self.ui.Event:new("PageUpdate", target))
end

--------------------------------------------------------------------------
-- ReaderUI
--------------------------------------------------------------------------

local ReaderUI = {}
ReaderUI.__index = ReaderUI

function Reader.newUI(options)
    options = options or {}
    local ui = setmetatable({
        Event = options.Event,
        document = options.document or Reader.newDocument(),
        doc_props = { display_title = options.title or "Moby Dick" },
        modules = {},
        registered_menus = {},
    }, ReaderUI)

    -- Kept on the ui table rather than captured in the closure so a test can
    -- change it: two devices holding different books is the interesting case.
    ui.digest = options.digest or "digest-moby"
    ui.doc_settings = {
        readSetting = function(_self, key)
            if key == "partial_md5_checksum" then return ui.digest end
            return nil
        end,
    }
    ui.menu = {
        registerToMainMenu = function(_self, plugin)
            table.insert(ui.registered_menus, plugin)
        end,
    }

    ui.paging = Reader.newPaging(ui)
    ui.view = { state = { page = 1 } }
    table.insert(ui.modules, ui.paging)
    return ui
end

--- Adds a module at the end of the chain, where KOReader puts plugins.
function ReaderUI:registerPlugin(plugin)
    table.insert(self.modules, plugin)
end

function ReaderUI:handleEvent(event)
    for _, module in ipairs(self.modules) do
        if module:handleEvent(event) then return true end
    end
    return false
end

return Reader
