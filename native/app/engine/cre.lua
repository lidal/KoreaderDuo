--[[--
CREngine, through koreader-base.

**Not yet run on a Paperwhite**, and the single biggest unknown in the
project -- Stage 2 of `FEASIBILITY.md`. koreader-base publishes itself as a
framework for building document readers, but driving CREngine from a Lua
frontend that is not KOReader's is not a well-trodden path, and if it turns
out to need large parts of that frontend then the whole approach shifts
from "new frontend on the base" to "fork KOReader and strip it".

So this file is written to find that out cheaply. Every entry point it
needs is listed in `NEEDS` and probed at `open()`, which means the first
run on a device reports *which* call is missing rather than dying in C.

The names come from how KOReader's own `document/credocument.lua` drives
the same engine. They are the most likely thing here to be wrong, and
checking them against the pinned revision is the first job of Stage 2.

Everything the request asked for is one of these calls, which is the whole
argument for not writing an engine:

    font selection     setFontFace
    embedded fonts     crengine.doc.embedded.fonts.enabled
    embedded styles    crengine.doc.embedded.styles.enabled
    margins            setPageMargins
    line spacing       setInterlineSpacePercent

@module duonative.engine.cre
--]]--

local Api = require("app/engine/api")

local Cre = {}

--- The C module, as koreader-base builds it.
Cre.LIBRARY = "libs/libkoreader-cre"

--[[--
What this adapter calls, and on what.

Probed rather than assumed, so a rename upstream is a clear message on the
first run instead of a segfault. `newDocView` is the one that must exist
for anything else to be reachable.
--]]--
Cre.NEEDS = {
    library = { "newDocView" },
    document = {
        "loadDocument", "renderDocument", "getPages", "gotoPage",
        "getCurrentPage", "drawCurrentPage", "setFontFace", "setFontSize",
        "setPageMargins", "getXPointer", "gotoXPointer", "getToc",
        "getDocumentProps",
    },
}

--[[--
CREngine's own property names for the things this app calls settings.

Integers, not booleans: crengine's property store is strings and numbers,
and handing it a Lua boolean sets the property to nothing in particular.
--]]--
Cre.PROPERTIES = {
    embedded_styles = "crengine.doc.embedded.styles.enabled",
    embedded_fonts = "crengine.doc.embedded.fonts.enabled",
    hyphenate = "crengine.hyphenation.enabled",
}

local Doc = {}
Doc.__index = Doc

local function probe()
    local ok, library = pcall(require, Cre.LIBRARY)
    if not ok or type(library) ~= "table" then
        return nil, ("%s did not load (is koreader-base built?)"):format(Cre.LIBRARY)
    end
    for _, name in ipairs(Cre.NEEDS.library) do
        if library[name] == nil then
            return nil, ("%s has no %s"):format(Cre.LIBRARY, name)
        end
    end
    return library
end

--[[--
Opens a document.

The cache has to be initialised once per process before any document is
loaded -- CREngine keeps its rendered pages and its parsed DOM there, and
without it the engine either refuses or re-renders constantly. Where it
goes is a decision for the device: on a Kindle, somewhere on the user
partition rather than the read-only root.
--]]--
function Cre.init(options)
    options = options or {}
    local library, err = probe()
    if not library then return nil, err end
    if library.initCache and not Cre.cache_ready then
        local path = options.cache_dir or "/mnt/us/duo/cache"
        os.execute(("mkdir -p %q 2>/dev/null"):format(path))
        pcall(library.initCache, path, options.cache_size or (1024 * 1024 * 32))
        Cre.cache_ready = true
    end
    if library.initHyphDict and options.hyph_dir then
        pcall(library.initHyphDict, options.hyph_dir)
    end
    Cre.library = library
    return library
end

function Cre.open(path, options)
    options = options or {}
    --[[
    Two statements, not `Cre.library or Cre.init(options)`.

    An `or` expression in a multiple assignment is adjusted to one value,
    so the second return -- the reason it failed -- is silently dropped and
    the caller gets `nil, nil`. Which is how this returned "could not open"
    with no explanation at all on its first run.
    ]]
    local library, err = Cre.library, nil
    if not library then library, err = Cre.init(options) end
    if not library then return nil, err or "CREngine is not available" end

    local width = options.width or 1072
    local height = options.height or 1448
    -- View mode 0 is paged, which is the only one a spread makes sense in:
    -- scrolling has no page to be one of two.
    local ok, view = pcall(library.newDocView, width, height, 0)
    if not ok or not view then
        return nil, "newDocView failed: " .. tostring(view)
    end

    for _, name in ipairs(Cre.NEEDS.document) do
        if view[name] == nil then
            return nil, ("a CREngine document has no %s; the bindings have moved"):format(name)
        end
    end

    local loaded = pcall(function() return view:loadDocument(path) end)
    if not loaded then return nil, ("CREngine would not open %s"):format(path) end

    local doc = setmetatable({
        view = view,
        path = path,
        width = width,
        height = height,
        current_layout = Api.layout(options.layout),
    }, Doc)
    doc:pushLayout()
    doc:rebuild()
    return doc
end

--[[--
Pushes the whole layout into the engine, then re-renders once.

Once, at the end, and not after each setting. CREngine re-lays-out the
whole document on a property change, and on a Paperwhite that is seconds
-- so setting ten properties one at a time is ten relayouts for one visit
to the typography panel. This is the reason `applyLayout` takes a whole
layout rather than offering a setter per field.
--]]--
function Doc:pushLayout()
    local view, layout = self.view, self.current_layout
    pcall(function() view:setFontFace(layout.face) end)
    pcall(function() view:setFontSize(layout.size) end)
    pcall(function()
        view:setPageMargins(layout.margin_left, layout.margin_top,
            layout.margin_right, layout.margin_bottom)
    end)
    if view.setInterlineSpacePercent then
        pcall(function() view:setInterlineSpacePercent(layout.line_spacing) end)
    end
    if view.setIntProperty then
        for field, property in pairs(Cre.PROPERTIES) do
            local value = layout[field]
            if value ~= nil then
                pcall(function() view:setIntProperty(property, value and 1 or 0) end)
            end
        end
    end
    if view.setFontBaseWeight then
        pcall(function() view:setFontBaseWeight(layout.weight) end)
    end
end

function Doc:rebuild()
    pcall(function() self.view:renderDocument() end)
    local ok, pages = pcall(function() return self.view:getPages() end)
    self.pages = (ok and tonumber(pages)) or 1
    return self.pages
end

function Doc:close()
    if self.view and self.view.close then pcall(function() self.view:close() end) end
    self.closed = true
end

function Doc:props()
    local ok, props = pcall(function() return self.view:getDocumentProps() end)
    if not ok or type(props) ~= "table" then
        return { title = self.path:match("([^/]+)$") or self.path }
    end
    return {
        title = props.title ~= "" and props.title or (self.path:match("([^/]+)$")),
        author = props.authors ~= "" and props.authors or nil,
        language = props.language,
    }
end

function Doc:cover(width, height)
    if not self.view.getCoverPageImage then return nil end
    local ok, image = pcall(function() return self.view:getCoverPageImage() end)
    if not ok or not image then return nil end
    return { kind = "cre-cover", blitbuffer = image, w = width, h = height }
end

--[[--
Applies a layout, keeping the reader's place.

The position is taken *before* the relayout and restored after, because a
page number means something different on each side of it -- which is the
whole reason `position()` exists. See the same note in `engine/stub.lua`:
the contract is page granularity, not exactness.
--]]--
function Doc:applyLayout(layout)
    local wanted = Api.layout(layout)
    if Api.sameLayout(wanted, self.current_layout) then return false end
    local position = self:position()
    self.current_layout = wanted
    self:pushLayout()
    self:rebuild()
    if position then self:gotoPosition(position) end
    return true
end

function Doc:getLayout()
    local out = {}
    for key, value in pairs(self.current_layout) do out[key] = value end
    return out
end

function Doc:pageCount() return self.pages or 1 end

function Doc:page()
    local ok, page = pcall(function() return self.view:getCurrentPage() end)
    return (ok and tonumber(page)) or 1
end

function Doc:gotoPage(page)
    page = math.max(1, math.min(math.floor(page or 1), self:pageCount()))
    pcall(function() self.view:gotoPage(page) end)
    return self:page()
end

function Doc:render(surface, rect)
    -- CREngine draws into a BlitBuffer, so this reaches past the display
    -- list to the buffer underneath. The one place in the app that does,
    -- and it is unavoidable: the book is rendered by the engine, not
    -- described by the UI.
    local buffer = surface.buffer
    if not buffer then return false end
    local ok = pcall(function() self.view:drawCurrentPage(buffer) end)
    return ok
end

function Doc:toc()
    local ok, entries = pcall(function() return self.view:getToc() end)
    if not ok or type(entries) ~= "table" then return {} end
    local out = {}
    for _, entry in ipairs(entries) do
        out[#out+1] = { title = entry.title, page = entry.page }
    end
    return out
end

--- CREngine's XPointer: a place in the text that survives a relayout.
function Doc:position()
    local ok, pointer = pcall(function() return self.view:getXPointer() end)
    if not ok or not pointer or pointer == "" then return nil end
    return pointer
end

function Doc:gotoPosition(position)
    if not position then return self:page() end
    pcall(function() self.view:gotoXPointer(position) end)
    return self:page()
end

function Doc:pageOf(position)
    if not position then return nil end
    if self.view.getPageFromXPointer then
        local ok, page = pcall(function()
            return self.view:getPageFromXPointer(position)
        end)
        if ok and tonumber(page) then return tonumber(page) end
    end
    -- No direct query: go there and look, then come back. Costs nothing on
    -- a laid-out document -- an XPointer lookup is a tree walk, not a
    -- relayout.
    local was = self:page()
    local there = self:gotoPosition(position)
    self:gotoPage(was)
    return there
end

--[[--
What two devices compare to prove they paginated alike.

The document's own identity, the layout, and the page count. Legible
rather than hashed, for the reason the stub gives: when two devices
disagree this is what somebody has to read, and `pages=310` against
`pages=311` says it where two hashes say nothing.
--]]--
function Doc:fingerprint()
    local props = self:props()
    return ("title=%s %s pages=%d"):format(
        tostring(props.title), Api.describeLayout(self.current_layout), self:pageCount())
end

return Cre
