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
    local document = setmetatable({
        file = options.file or (book and book.path) or "/books/moby-dick.epub",
        book = book,
        base_page_count = book and book:getPageCount() or options.page_count or 300,
        page_count = book and book:getPageCount() or options.page_count or 300,
        pages_per_view = options.pages_per_view or 1,
        -- A reflowable document by default: paged formats have fixed pages
        -- and no typography worth matching.
        info = { has_pages = options.has_pages == true },
        -- The same table KOReader hangs off a document, with the handful of
        -- settings Duo matches.
        configurable = {
            font_size = options.font_size or 22,
            line_spacing = 100,
            h_page_margins = { 10, 10 },
            t_page_margin = 10,
            b_page_margin = 10,
            view_mode = 0,
            visible_pages = 1,
            embedded_css = 1,
            font_hinting = 2,
        },
    }, Document)
    document:repaginate()
    return document
end

--[[--
Recomputes the page count from the typography.

Crude but monotone and deterministic, which is all a test needs: bigger
text means more pages, wider margins mean more pages. What matters is that
two devices with the same settings agree, and two devices with different
settings do not — exactly the condition the spread depends on.
--]]--
function Document:repaginate()
    local configurable = self.configurable
    local size = configurable.font_size or 22
    local spacing = (configurable.line_spacing or 100) / 100
    local margins = ((configurable.h_page_margins or { 10, 10 })[1] or 10) / 10
    local scale = (size / 22) * spacing * (0.9 + 0.1 * margins)
    self.page_count = math.max(1, math.floor(self.base_page_count * scale + 0.5))
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

--------------------------------------------------------------------------
-- Typography
--------------------------------------------------------------------------

-- The events KOReader's own modules answer, doing the one thing that
-- matters here: change the setting, then relayout.
local TYPOGRAPHY_EVENTS = {
    onSetFontSize = "font_size",
    onSetLineSpace = "line_spacing",
    onSetPageHorizMargins = "h_page_margins",
    onSetPageTopMargin = "t_page_margin",
    onSetPageBottomMargin = "b_page_margin",
    onSetViewMode = "view_mode",
    onSetVisiblePages = "visible_pages",
    onToggleEmbeddedStyleSheet = "embedded_css",
    onSetFontHinting = "font_hinting",
}

local Typeset = {}
Typeset.__index = Typeset

function Reader.newTypeset(ui)
    local typeset = setmetatable({ ui = ui }, Typeset)
    for handler, key in pairs(TYPOGRAPHY_EVENTS) do
        typeset[handler] = function(self_, value)
            self_.ui.document.configurable[key] = value
            self_.ui.document:repaginate()
            -- Relaying out can leave the reader past the end of the book.
            local paging = self_.ui.paging
            local count = self_.ui.document:getPageCount()
            if paging.current_page > count then
                paging.current_page = count
            end
            self_.ui:handleEvent(self_.ui.Event:new("UpdatePos"))
            return true
        end
    end
    return typeset
end

function Typeset:handleEvent(event)
    local handler = self[event.handler]
    if handler then
        return handler(self, unpack(event.args, 1, event.args.n))
    end
end

--- Stands in for ReaderFont, which owns the typeface.
local Font = {}
Font.__index = Font

function Reader.newFont(ui, face)
    return setmetatable({ ui = ui, font_face = face or "Noto Serif", installed = {
        ["Noto Serif"] = true, ["Noto Sans"] = true, ["Literata"] = true,
    } }, Font)
end

function Font:handleEvent(event)
    local handler = self[event.handler]
    if handler then
        return handler(self, unpack(event.args, 1, event.args.n))
    end
end

function Font:onSetFont(face)
    -- A face this device does not have is simply ignored, as KOReader does.
    if not self.installed[face] then return true end
    self.font_face = face
    self.ui.document:repaginate()
    self.ui:handleEvent(self.ui.Event:new("UpdatePos"))
    return true
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

    -- KOReader has two of these and picks between them on
    -- document.info.has_pages: ReaderPaging for PDFs and the like,
    -- ReaderRolling for reflowable formats. The parts Duo touches
    -- (current_page, onGotoViewRel, onGotoPage) are the same in both, so
    -- one stand-in is registered under both names and the document type
    -- decides which one the plugin reaches for — exactly as it does in
    -- KOReader.
    local module = Reader.newPaging(ui)
    ui.paging = module
    ui.rolling = module
    ui.view = { state = { page = 1 } }
    table.insert(ui.modules, module)

    -- Registered in KOReader's order: the core modules first, plugins last.
    ui.typeset = Reader.newTypeset(ui)
    ui.font = Reader.newFont(ui, options.font_face)
    table.insert(ui.modules, ui.typeset)
    table.insert(ui.modules, ui.font)
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
