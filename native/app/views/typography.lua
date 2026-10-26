--[[--
Font, margins, spacing, and whether the book's own styling wins.

The panel a reader of a *spread* opens most, because on two devices a
typography change is not a private act: it moves the line breaks, so it
moves where every page ends, so it has to be agreed. That is why this is a
panel reached by a tap rather than a gesture -- a gesture nobody can see is
fine for a brightness nudge and wrong for a change that repaginates the
other device too.

Rows are declared, not laid out by hand. Each knows how to read its value,
how to change it, and how to say what it is now; the panel draws them and
turns taps into those calls. Adding a setting is one table entry, which
matters because this is the screen that will grow.

Every change goes out through `apply`, which hands the whole layout to the
reader at once rather than one field at a time. A layout is a value here
(see `engine/api.lua`) and setting it in pieces would mean several
relayouts for one visit to this screen -- on a Paperwhite that is several
seconds of a book being rebuilt while somebody waits.

@module duonative.views.typography
--]]--

local Widget = require("app/ui/widget")
local EngineApi = require("app/engine/api")
local Rect = Widget.Rect

local Typography = {}
Typography.__index = Typography

local HEADER_H = 70
local ROW_H = 78
local GAP = 16

--[[--
The faces offered.

Shipped with the app rather than discovered on the device, which is the
study's point about pagination being correct by construction: "a typeface
only one device has" stops being a category of failure when the only
typefaces on offer are the ones in the bundle. A face found on the card
can still be added here, but it is then the reader's business to put it on
both.
--]]--
Typography.FACES = {
    "Noto Serif", "Noto Sans", "Literata", "Bitter", "Libertinus Serif",
}

local function clamp(value, low, high)
    return math.max(low, math.min(value, high))
end

--[[--
A stepper: a number with bounds and a step.

`wrap = false` throughout, deliberately. A font size that goes from its
maximum back to its minimum on one more tap is a reader suddenly holding a
page of ants, and the tap that did it was probably a mis-hit.
--]]--
local function stepper(key, label, low, high, step, unit)
    return {
        key = key, label = label, kind = "stepper",
        read = function(layout) return layout[key] end,
        show = function(layout) return tostring(layout[key]) .. (unit or "") end,
        nudge = function(layout, direction)
            layout[key] = clamp(layout[key] + direction * step, low, high)
        end,
    }
end

local function toggle(key, label)
    return {
        key = key, label = label, kind = "toggle",
        read = function(layout) return layout[key] end,
        show = function(layout) return layout[key] and "on" or "off" end,
        nudge = function(layout) layout[key] = not layout[key] end,
    }
end

local function chooser(key, label, values)
    return {
        key = key, label = label, kind = "chooser",
        read = function(layout) return layout[key] end,
        show = function(layout) return tostring(layout[key]) end,
        nudge = function(layout, direction)
            local at = 1
            for index, value in ipairs(values) do
                if value == layout[key] then at = index end
            end
            at = at + direction
            if at < 1 then at = #values elseif at > #values then at = 1 end
            layout[key] = values[at]
        end,
    }
end

--[[--
The rows, in the order a reader reaches for them.

Typeface and size first because they are what somebody opens this screen
to change; the book's own styling last because it is the one that is
usually left alone and is the most confusing to have moved by accident.
--]]--
function Typography.rows()
    return {
        chooser("face", "Typeface", Typography.FACES),
        stepper("size", "Font size", 12, 60, 1, "px"),
        stepper("weight", "Weight", 300, 700, 100),
        stepper("line_spacing", "Line spacing", 80, 200, 5, "%"),
        stepper("word_spacing", "Word spacing", 80, 150, 5, "%"),
        stepper("margin_left", "Margin, left", 0, 300, 10, "px"),
        stepper("margin_right", "Margin, right", 0, 300, 10, "px"),
        stepper("margin_top", "Margin, top", 0, 200, 10, "px"),
        stepper("margin_bottom", "Margin, bottom", 0, 200, 10, "px"),
        toggle("justify", "Justified"),
        toggle("hyphenate", "Hyphenation"),
        toggle("embedded_styles", "The book's own styles"),
        toggle("embedded_fonts", "The book's own fonts"),
    }
end

--[[--
@tparam table options
    layout    the layout to start from
    onApply   function(layout) -> called with the finished layout
    onClose   function()
--]]--
function Typography.new(options)
    options = options or {}
    return setmetatable({
        layout = EngineApi.layout(options.layout),
        rows = Typography.rows(),
        on_apply = options.onApply,
        on_close = options.onClose,
        scroll = 0,
        changed = false,
    }, Typography)
end

function Typography:visibleRows(rect)
    local room = rect.h - HEADER_H
    return math.max(math.floor(room / ROW_H), 1)
end

function Typography:rowRects(rect)
    local out = {}
    local shown = self:visibleRows(rect)
    for offset = 0, shown - 1 do
        local index = self.scroll + offset + 1
        if self.rows[index] then
            out[#out+1] = {
                index = index,
                row = self.rows[index],
                rect = Rect.new(rect.x + GAP, rect.y + HEADER_H + offset * ROW_H,
                    rect.w - 2 * GAP, ROW_H),
            }
        end
    end
    return out
end

--------------------------------------------------------------------------
-- Changing things
--------------------------------------------------------------------------

--[[--
Applies and leaves.

Only if something actually changed: `applyLayout` is a no-op for an
unchanged layout, but telling the other device that typography moved when
it did not would make the pair rebuild a book for nothing, and on these
readers that is seconds of staring at a frozen page.
--]]--
function Typography:apply()
    if self.changed and self.on_apply then self.on_apply(self.layout) end
    if self.on_close then self.on_close() end
    return true
end

function Typography:nudge(row, direction)
    local before = row.read(self.layout)
    row.nudge(self.layout, direction)
    if row.read(self.layout) ~= before then self.changed = true end
    return true
end

--------------------------------------------------------------------------
-- Input
--------------------------------------------------------------------------

function Typography:onTap(x, y)
    local rect = self.last_rect
    if not rect then return false end
    if y < rect.y + HEADER_H then return self:apply() end
    for _, entry in ipairs(self:rowRects(rect)) do
        if Rect.contains(entry.rect, x, y) then
            -- Left half down, right half up. A toggle ignores the sign.
            local direction = x < entry.rect.x + entry.rect.w / 2 and -1 or 1
            return self:nudge(entry.row, direction)
        end
    end
    return false
end

function Typography:onKey(key)
    if key == "back" or key == "menu" then return self:apply() end
    if key == "down" then
        self.scroll = math.min(self.scroll + 1,
            math.max(#self.rows - self:visibleRows(self.last_rect or { h = 1448 }), 0))
        return true
    end
    if key == "up" then
        self.scroll = math.max(self.scroll - 1, 0)
        return true
    end
    return false
end

function Typography:onSwipe(dir)
    if dir == "up" then return self:onKey("down") end
    if dir == "down" then return self:onKey("up") end
    return false
end

--------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------

function Typography:paint(surface, rect)
    self.last_rect = rect
    surface:fill(rect, 15)
    surface:text(rect.x + GAP, rect.y + 44, "Typography", { size = 28, bold = true })
    surface:text(rect.x + rect.w - GAP - Widget.textWidth("done", 22),
        rect.y + 44, "done", { size = 22, grey = 4 })

    for _, entry in ipairs(self:rowRects(rect)) do
        local row, box = entry.row, entry.rect
        surface:text(box.x + 8, box.y + 34, row.label, { size = 24 })
        local value = row.show(self.layout)
        surface:text(box.x + box.w - 8 - Widget.textWidth(value, 24),
            box.y + 34, value, { size = 24, bold = true })
        -- A rule under each row, which is the whole of the decoration this
        -- screen needs and all a grey panel can carry without looking busy.
        surface:fill(Rect.new(box.x, box.y + box.h - 1, box.w, 1), 11)
    end

    if #self.rows > self:visibleRows(rect) then
        local more = ("%d–%d of %d"):format(self.scroll + 1,
            math.min(self.scroll + self:visibleRows(rect), #self.rows), #self.rows)
        surface:text(rect.x + GAP, rect.y + rect.h - 14, more, { size = 18, grey = 6 })
    end
end

return Typography
