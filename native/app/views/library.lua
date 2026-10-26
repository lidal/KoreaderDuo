--[[--
The shelf, as a grid of covers.

Designed as one grid that happens to be *shown* on two screens, which is
the thing the study said a native app can do and a plugin cannot: the
plugin spreads a listing by moving two independent file browsers to
adjacent pages and hoping they agree about how many rows fit. Here the
grid's shape is a value -- `cols`, `rows`, and therefore `perpage` -- and
the pair agrees on it the same way it agrees on typography, by one device
deciding.

The state this reports is deliberately the shape `duo/core.lua` already
reads off KOReader's file browser: `view`, `kind`, `path`, `page`,
`pages`, `perpage`, `count`, `cols`, `rows`, `signature`. Matching it
exactly is what lets the existing library-spread code drive this view with
no changes at all.

@module duonative.views.library
--]]--

local Widget = require("app/ui/widget")
local Books = require("app/books")
local Rect = Widget.Rect

local Library = {}
Library.__index = Library

local HEADER_H = 60
local FOOTER_H = 50
local LABEL_H = 34
local GAP = 18

function Library.new(options)
    options = options or {}
    local self = setmetatable({
        path = options.path or ".",
        delegate = options.delegate,
        cols = options.cols or 2,
        rows = options.rows or 3,
        page = 1,
        entries = {},
    }, Library)
    self:refresh()
    return self
end

--------------------------------------------------------------------------
-- Contents
--------------------------------------------------------------------------

function Library:refresh()
    self.entries = Books.list(self.path)
    self.cached_signature = Books.signature(self.entries)
    self:clampPage()
    return true
end

function Library:perPage() return self.cols * self.rows end

function Library:pageCount()
    return math.max(math.ceil(#self.entries / self:perPage()), 1)
end

function Library:clampPage()
    self.page = math.max(1, math.min(self.page, self:pageCount()))
end

--- The entries on a page, which is what both the grid and the pair ask for.
function Library:pageEntries(page)
    page = page or self.page
    local per = self:perPage()
    local first = (page - 1) * per + 1
    local out = {}
    for index = first, math.min(first + per - 1, #self.entries) do
        out[#out+1] = self.entries[index]
    end
    return out
end

--------------------------------------------------------------------------
-- The browser binding's questions
--------------------------------------------------------------------------

--[[--
The listing as `duo/core.lua` wants to hear about it.

`kind = "folder"` because this is a place on the disk and can be told to
change directory -- the plugin distinguishes that from a library view,
which cannot. `view` is the identity of the listing, used to notice that
the two devices are looking at different things.
--]]--
function Library:getState()
    return {
        view = "folder:" .. self.path,
        kind = "folder",
        path = self.path,
        page = self.page,
        pages = self:pageCount(),
        perpage = self:perPage(),
        count = #self.entries,
        cols = self.cols,
        rows = self.rows,
        signature = self.cached_signature,
    }
end

function Library:goToPage(page)
    local total = self:pageCount()
    page = math.max(1, math.min(math.floor(page or 1), total))
    self.page = page
    return true
end

function Library:getFiles()
    local out = {}
    for _, entry in ipairs(self.entries) do
        if not entry.is_dir then
            out[#out+1] = { path = entry.path, name = entry.name }
        end
    end
    return out
end

function Library:changeDir(path)
    if not path or path == "" then return false end
    -- Must exist, or a stale message from the other device would empty the
    -- shelf and leave somebody looking at nothing with no way back.
    local probe = io.popen(("test -d %q && echo yes"):format(path))
    local exists = probe and probe:read("*l") == "yes"
    if probe then probe:close() end
    if not exists then return false end
    self.path = (path:gsub("/+$", ""))
    if self.path == "" then self.path = "/" end
    self.page = 1
    self:refresh()
    return true
end

--[[--
Reshapes the grid, which is how the pair agrees on how much fits.

Takes `perpage` first to match the plugin's signature, but the grid is
`cols` by `rows` and those are what it actually needs -- a perpage with no
shape is ambiguous, and two devices resolving 6 into 2x3 and 3x2 would
show the same books in a different order, which looks exactly like a bug
in the spread.
--]]--
function Library:setPerPage(perpage, cols, rows)
    if cols and rows and cols > 0 and rows > 0 then
        self.cols, self.rows = math.floor(cols), math.floor(rows)
    elseif perpage and perpage > 0 then
        -- No shape given: keep the columns and move the rows, which is the
        -- less surprising of the two.
        self.rows = math.max(math.floor(perpage / self.cols), 1)
    else
        return false
    end
    self:clampPage()
    return true
end

--------------------------------------------------------------------------
-- Input
--------------------------------------------------------------------------

function Library:cellRects(rect)
    local body = Rect.new(rect.x + GAP, rect.y + HEADER_H,
        rect.w - 2 * GAP, rect.h - HEADER_H - FOOTER_H)
    local out = {}
    for row_index, row in ipairs(Rect.rows(body, self.rows, GAP)) do
        for col_index, cell in ipairs(Rect.columns(row, self.cols, GAP)) do
            out[#out+1] = { rect = cell, index = (row_index - 1) * self.cols + col_index }
        end
    end
    return out
end

function Library:onTap(x, y)
    local rect = self.last_rect
    if not rect then return false end
    if y < rect.y + HEADER_H then
        -- The header is the way up, when there is an up to go to.
        if self.path ~= "/" and self.delegate and self.delegate.onLibraryUp then
            return self.delegate:onLibraryUp(self.path:match("^(.*)/[^/]+$") or "/")
        end
        return false
    end
    if y > rect.y + rect.h - FOOTER_H then
        if x < rect.w / 2 then return self:turnPage(-1) end
        return self:turnPage(1)
    end
    local entries = self:pageEntries()
    for _, cell in ipairs(self:cellRects(rect)) do
        if Rect.contains(cell.rect, x, y) and entries[cell.index] then
            return self:choose(entries[cell.index])
        end
    end
    return false
end

function Library:onKey(key)
    if key == "right" or key == "down" then return self:turnPage(1) end
    if key == "left" or key == "up" then return self:turnPage(-1) end
    return false
end

function Library:onSwipe(dir)
    if dir == "left" then return self:turnPage(1) end
    if dir == "right" then return self:turnPage(-1) end
    return false
end

--[[--
A page of the shelf, offered to the delegate first.

The same chokepoint the reader has, for the same reason: with the listing
spread across two devices a page turn moves by two pages, not one, and the
device that was tapped is not necessarily the one that decides.
--]]--
function Library:turnPage(diff, options)
    options = options or {}
    if not options.local_only and self.delegate and self.delegate.onLibraryTurn then
        if self.delegate:onLibraryTurn(diff) then return false end
    end
    local from = self.page
    self:goToPage(from + diff)
    return self.page ~= from
end

function Library:choose(entry)
    if entry.is_dir then
        if self.delegate and self.delegate.onLibraryUp then
            return self.delegate:onLibraryUp(entry.path)
        end
        return self:changeDir(entry.path)
    end
    if self.delegate and self.delegate.onBookChosen then
        return self.delegate:onBookChosen(entry.path)
    end
    return false
end

--------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------

function Library:paint(surface, rect)
    self.last_rect = rect
    surface:fill(rect, 15)

    local shown = self.path:match("([^/]+)$") or self.path
    surface:text(rect.x + GAP, rect.y + 38,
        Widget.truncate(shown, 26, rect.w - 2 * GAP), { size = 26, bold = true })

    local entries = self:pageEntries()
    for _, cell in ipairs(self:cellRects(rect)) do
        local entry = entries[cell.index]
        if entry then self:paintCell(surface, cell.rect, entry) end
    end

    local label = ("%d / %d"):format(self.page, self:pageCount())
    surface:text(rect.x + rect.w - GAP - Widget.textWidth(label, 20),
        rect.y + rect.h - 18, label, { size = 20, grey = 4 })
    if self.spread_label then
        surface:text(rect.x + GAP, rect.y + rect.h - 18,
            self.spread_label, { size = 20, grey = 4 })
    end
end

--[[--
One book: its cover, its name underneath.

A folder gets an outline and no cover, which is enough to tell the two
apart at arm's length on a grey screen -- the distinction a colour or an
icon would make is not available here.
--]]--
function Library:paintCell(surface, rect, entry)
    local art = Rect.new(rect.x, rect.y, rect.w, rect.h - LABEL_H)
    if entry.is_dir then
        surface:rect(art, 6, 2)
        surface:text(art.x + 12, art.y + math.floor(art.h / 2), "folder",
            { size = 20, grey = 6 })
    else
        surface:rect(art, 8, 1)
        local cover = self.delegate and self.delegate.coverFor
            and self.delegate:coverFor(entry.path, art.w, art.h)
        if cover then surface:image(art, cover) end
    end
    surface:text(rect.x, rect.y + rect.h - 10,
        Widget.truncate(entry.name, 20, rect.w), { size = 20 })
end

function Library:setSpreadLabel(label) self.spread_label = label end

return Library
