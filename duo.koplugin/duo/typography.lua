--[[--
Keeping the two devices laying the book out identically.

A spread only works if both readers break lines in the same places. Font
size, margins, line spacing and a dozen other settings all move those
breaks, and asking someone to match them by hand on two e-readers is the
kind of instruction nobody follows.

So Duo matches them itself. The set below is deliberately curated: every
entry changes where the text falls, and settings that are properly personal
or particular to one device — rotation, night mode, image smoothing — are
left alone on purpose.

KOReader keeps these in `document.configurable` and declares the event that
applies each one in `ui/data/creoptions`. This module reads that mapping at
runtime so it stays right across KOReader versions, with a copy of what it
found built in as a fallback.

Only reflowable formats need any of this. A PDF has the pages the file says
it has, so two devices agree about it whatever their settings.

@module duo.typography
--]]--

local Typography = {}

--[[--
The settings that decide where the lines break.

Ordered so that the coarse ones apply first: changing the view mode or the
margins and *then* the font size costs one relayout, the other way round
costs two.
--]]--
Typography.KEYS = {
    "view_mode",
    "visible_pages",
    "h_page_margins",
    "sync_t_b_page_margins",
    "t_page_margin",
    "b_page_margin",
    "block_rendering_mode",
    "render_dpi",
    "status_line",
    "embedded_css",
    "embedded_fonts",
    "font_size",
    "font_base_weight",
    "font_hinting",
    "font_kerning",
    "line_spacing",
    "word_spacing",
    "word_expansion",
    "cjk_width_scaling",
}

--- The typeface, which lives in ReaderFont rather than in `configurable`.
Typography.FONT_FACE = "font_face"

-- Used when ui/data/creoptions cannot be read (a stripped build, or a test).
local FALLBACK_EVENTS = {
    view_mode = "SetViewMode",
    visible_pages = "SetVisiblePages",
    h_page_margins = "SetPageHorizMargins",
    sync_t_b_page_margins = "SyncPageTopBottomMargins",
    t_page_margin = "SetPageTopMargin",
    b_page_margin = "SetPageBottomMargin",
    block_rendering_mode = "SetBlockRenderingMode",
    render_dpi = "SetRenderDPI",
    status_line = "SetStatusLine",
    embedded_css = "ToggleEmbeddedStyleSheet",
    embedded_fonts = "ToggleEmbeddedFonts",
    font_size = "SetFontSize",
    font_base_weight = "SetFontBaseWeight",
    font_hinting = "SetFontHinting",
    font_kerning = "SetFontKerning",
    line_spacing = "SetLineSpace",
    word_spacing = "SetWordSpacing",
    word_expansion = "SetWordExpansion",
    cjk_width_scaling = "SetCJKWidthScaling",
}

local event_map

--- name -> event, read from KOReader's own option table when available.
function Typography.getEventMap()
    if event_map then return event_map end
    event_map = {}
    for key, event in pairs(FALLBACK_EVENTS) do
        event_map[key] = event
    end
    local ok, CreOptions = pcall(require, "ui/data/creoptions")
    if ok and type(CreOptions) == "table" then
        for _, group in ipairs(CreOptions) do
            for _, option in ipairs(group.options or {}) do
                if option.name and option.event then
                    event_map[option.name] = option.event
                end
            end
        end
    end
    return event_map
end

--------------------------------------------------------------------------
-- Values on the wire
--------------------------------------------------------------------------

--- Turns a setting value into a string. Margins are pairs, so an array of
-- numbers becomes "10,10"; everything else is a number or a short string.
function Typography.encodeValue(value)
    local kind = type(value)
    if kind == "number" or kind == "string" then
        return tostring(value)
    end
    if kind == "boolean" then
        return value and "1" or "0"
    end
    if kind == "table" then
        local parts = {}
        for index, item in ipairs(value) do
            parts[index] = tostring(item)
        end
        return table.concat(parts, ",")
    end
    return nil
end

--[[--
Turns a string back into a value of the same shape as the one it replaces.

The local value is the template: KOReader is particular about whether a
setting is a number, a string or a pair, and a margin arriving as the
string "10,10" would be quietly wrong rather than loudly wrong.
--]]--
function Typography.decodeValue(text, local_value)
    if text == nil then return nil end
    if type(local_value) == "table" then
        local out = {}
        for item in tostring(text):gmatch("[^,]+") do
            out[#out+1] = tonumber(item) or item
        end
        return out
    end
    if type(local_value) == "number" then
        return tonumber(text)
    end
    if type(local_value) == "string" then
        return tostring(text)
    end
    -- Nothing local to compare against: a number if it looks like one.
    return tonumber(text) or tostring(text)
end

--- True when two encoded values are the same.
local function sameEncoded(a, b)
    if a == nil or b == nil then return a == b end
    return tostring(a) == tostring(b)
end

--------------------------------------------------------------------------
-- Reading and applying
--------------------------------------------------------------------------

--[[--
Reads the current layout settings.

@tparam table ui a ReaderUI
@treturn table key -> encoded string, empty when the document has no
    typography to speak of (a PDF, or no document at all)
--]]--
function Typography.snapshot(ui)
    local out = {}
    if not ui or not ui.document then return out end
    -- Paged formats have fixed pages; nothing here would change them.
    if ui.document.info and ui.document.info.has_pages then return out end

    local configurable = ui.document.configurable
    if configurable then
        for _, key in ipairs(Typography.KEYS) do
            local encoded = Typography.encodeValue(configurable[key])
            if encoded ~= nil then
                out[key] = encoded
            end
        end
    end
    if ui.font and ui.font.font_face then
        out[Typography.FONT_FACE] = tostring(ui.font.font_face)
    end
    return out
end

--- Keys whose values differ between two snapshots.
function Typography.differences(mine, theirs)
    local changed = {}
    for key, value in pairs(theirs or {}) do
        if not sameEncoded((mine or {})[key], value) then
            changed[#changed+1] = key
        end
    end
    table.sort(changed)
    return changed
end

--[[--
Applies settings from the other device.

Each one goes through the same event the settings dialog would send, so
KOReader relayouts and saves exactly as if a person had changed it.

@tparam table ui a ReaderUI
@tparam table settings key -> encoded string
@tparam table Event KOReader's Event class
@treturn table the keys actually changed
--]]--
function Typography.apply(ui, settings, Event)
    local applied = {}
    if not ui or not ui.document or not settings then return applied end
    if ui.document.info and ui.document.info.has_pages then return applied end

    local configurable = ui.document.configurable
    local events = Typography.getEventMap()

    for _, key in ipairs(Typography.KEYS) do
        local wanted = settings[key]
        if wanted ~= nil and configurable then
            local current = Typography.encodeValue(configurable[key])
            if not sameEncoded(current, wanted) then
                local event = events[key]
                local value = Typography.decodeValue(wanted, configurable[key])
                if event and value ~= nil then
                    -- Set it first: a few handlers read the configurable
                    -- back rather than trusting their argument.
                    configurable[key] = value
                    local ok, err = pcall(function()
                        ui:handleEvent(Event:new(event, value))
                    end)
                    if ok then
                        applied[#applied+1] = key
                    else
                        configurable[key] = Typography.decodeValue(current, configurable[key])
                        applied.errors = applied.errors or {}
                        applied.errors[key] = tostring(err)
                    end
                end
            end
        end
    end

    local face = settings[Typography.FONT_FACE]
    if face and ui.font and ui.font.font_face ~= face then
        local ok = pcall(function()
            ui:handleEvent(Event:new("SetFont", face))
        end)
        -- A typeface the other device has and this one does not is the one
        -- mismatch that cannot be fixed by copying a number across.
        if ok and ui.font.font_face == face then
            applied[#applied+1] = Typography.FONT_FACE
        else
            applied.missing_font = face
        end
    end

    return applied
end

--- "font size, margins and 2 more", for a notification.
function Typography.describe(keys)
    local names = {
        font_size = "font size",
        font_face = "typeface",
        font_base_weight = "font weight",
        line_spacing = "line spacing",
        h_page_margins = "margins",
        t_page_margin = "top margin",
        b_page_margin = "bottom margin",
        view_mode = "view mode",
        visible_pages = "columns",
        word_spacing = "word spacing",
        word_expansion = "word expansion",
        render_dpi = "zoom",
        embedded_css = "embedded styles",
        embedded_fonts = "embedded fonts",
        status_line = "status bar",
    }
    local listed, extra = {}, 0
    for _, key in ipairs(keys) do
        if #listed < 3 then
            listed[#listed+1] = names[key] or key:gsub("_", " ")
        else
            extra = extra + 1
        end
    end
    if #listed == 0 then return "nothing" end
    local text = table.concat(listed, ", ")
    if extra > 0 then
        text = text .. (" and %d more"):format(extra)
    end
    return text
end

return Typography
