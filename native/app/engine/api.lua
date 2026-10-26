--[[--
What the app needs from a document engine.

Shaped to fit CREngine, because CREngine is what will be behind it. The
study in `FEASIBILITY.md` is blunt about why: font selection, embedded
styles, embedded fonts and margin adjustment are not four features, they
are one layout engine, and writing one is years with a bad ending. So this
is a thin contract over somebody else's engine, not an abstraction hoping
to have several.

Two implementations:

* `engine/cre.lua` -- CREngine through koreader-base's bindings. The real
  one. **Not yet run on a device**; see README.
* `engine/stub.lua` -- a deterministic paginator for the suite. It wraps
  words at a measured width and that is all it does. It is a test double
  and must never be mistaken for a renderer: it has no CSS, no shaping, no
  hyphenation, and no opinion about an EPUB's own stylesheet.

**Layout is a value, not a sequence of calls.** `applyLayout` takes the
whole set at once and returns whether the document had to be re-laid-out.
That shape is not cosmetic -- it is what makes `fingerprint()` meaningful,
and `fingerprint()` is what lets two devices prove they paginated the same
way instead of assuming it. The plugin cannot do that, and it is the one
real argument for this app existing.

@module duonative.engine.api
--]]--

local EngineApi = {}

--[[--
The default layout. Every field is a thing the reader's menus can change.

Margins are in pixels per side rather than a single number because that is
what CREngine takes, and because the gutter of a two-page spread wants to
be asymmetric: the inner edge of each screen is the middle of the book.
--]]--
EngineApi.DEFAULT_LAYOUT = {
    face = "Noto Serif",
    size = 22,
    weight = 400,
    line_spacing = 100,      -- percent
    word_spacing = 100,      -- percent
    margin_left = 40,
    margin_top = 30,
    margin_right = 40,
    margin_bottom = 30,
    embedded_styles = true,
    embedded_fonts = true,
    justify = true,
    hyphenate = true,
}

--[[--
The methods an implementation must provide.

    open(path, options)        -> doc, or nil plus a reason
    doc:close()
    doc:props()                -> { title =, author =, language = }
    doc:cover(w, h)            -> image handle, or nil
    doc:applyLayout(layout)    -> reflowed (boolean)
    doc:getLayout()            -> the layout now in force
    doc:pageCount()
    doc:page()                 -> current page
    doc:gotoPage(n)            -> landed page
    doc:render(surface, rect)  draw the current page into rect
    doc:toc()                  -> { { title =, page = }, ... }
    doc:position()             -> an opaque, stable position in the text
    doc:gotoPosition(pos)
    doc:pageOf(pos)            -> which page holds pos, without moving
    doc:fingerprint()          -> a string two devices can compare

`position()` is CREngine's XPointer under the real backend: a place in the
text that survives a relayout, which a page number does not. It is what a
follower is sent when the pair's layout has just changed underneath it.
--]]--
EngineApi.CONTRACT = {
    "close", "props", "cover", "applyLayout", "getLayout",
    "pageCount", "page", "gotoPage", "render", "toc",
    "position", "gotoPosition", "pageOf", "fingerprint",
}

function EngineApi.check(doc)
    local missing = {}
    for _, name in ipairs(EngineApi.CONTRACT) do
        if type(doc[name]) ~= "function" then missing[#missing+1] = name end
    end
    if #missing == 0 then return true end
    return false, table.concat(missing, ", ")
end

--[[--
Fills in whatever a caller left out.

Returns a fresh table every time. Sharing one would let a reader's
settings leak into the next book opened, which is the sort of bug that
takes an afternoon because nothing looks wrong at the point it is caused.
--]]--
function EngineApi.layout(overrides)
    local out = {}
    for key, value in pairs(EngineApi.DEFAULT_LAYOUT) do out[key] = value end
    for key, value in pairs(overrides or {}) do
        if out[key] ~= nil then out[key] = value end
    end
    return out
end

--[[--
True when two layouts would paginate the same way.

Compared field by field rather than by serialising, because a table's key
order is not stable in Lua and a fingerprint that depends on it would
differ between two devices running identical code -- which is precisely
the false alarm this is here to avoid.
--]]--
function EngineApi.sameLayout(a, b)
    if not a or not b then return false end
    for key in pairs(EngineApi.DEFAULT_LAYOUT) do
        if a[key] ~= b[key] then return false end
    end
    return true
end

--[[--
A layout as a stable, sorted string -- half of what goes into a fingerprint.

Sorted by key for the reason above. The other half is the document's own
identity and its page count, which the backend adds.
--]]--
function EngineApi.describeLayout(layout)
    local keys = {}
    for key in pairs(EngineApi.DEFAULT_LAYOUT) do keys[#keys+1] = key end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts+1] = ("%s=%s"):format(key, tostring(layout[key]))
    end
    return table.concat(parts, " ")
end

return EngineApi
