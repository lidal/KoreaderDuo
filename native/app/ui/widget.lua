--[[--
Rectangles, a view stack, and where a tap landed.

Everything the UI needs and nothing it does not. There is no widget tree,
no layout solver and no invalidation graph, because a reader has perhaps
eight screens and e-ink repaints the whole thing anyway -- the cost of a
full repaint is the panel, not the drawing, so the cheapest correct thing
is to redraw everything and let the refresh mode decide what it costs.

A view is a table with:

    view:paint(surface, rect)       draw yourself into rect
    view:onTap(x, y)                -> true if you handled it
    view:onKey(key)                 -> true if you handled it
    view:onSwipe(dir)               -> true if you handled it

All but `paint` are optional. A view that handles nothing is a view that
only shows.

@module duonative.ui.widget
--]]--

local Widget = {}

--------------------------------------------------------------------------
-- Rectangles
--------------------------------------------------------------------------

local Rect = {}
Widget.Rect = Rect

function Rect.new(x, y, w, h)
    return { x = x or 0, y = y or 0, w = w or 0, h = h or 0 }
end

function Rect.contains(rect, x, y)
    return rect ~= nil
        and x >= rect.x and x < rect.x + rect.w
        and y >= rect.y and y < rect.y + rect.h
end

--- The rect shrunk on every side. Negative grows it, which is occasionally wanted.
function Rect.inset(rect, by)
    return Rect.new(rect.x + by, rect.y + by, rect.w - 2 * by, rect.h - 2 * by)
end

--[[--
Splits a rect into `count` rows, with `gap` between them.

Integer arithmetic throughout, and the remainder is given to the last row
rather than spread. Rounding a grid by thirds leaves a one-pixel seam that
on e-ink is a visible grey line, and "the last cell is a pixel taller" is
invisible where "there is a line down the screen" is not.
--]]--
function Rect.rows(rect, count, gap)
    gap = gap or 0
    local out = {}
    local height = math.floor((rect.h - gap * (count - 1)) / count)
    for index = 1, count do
        local y = rect.y + (index - 1) * (height + gap)
        local h = index == count and (rect.y + rect.h - y) or height
        out[index] = Rect.new(rect.x, y, rect.w, h)
    end
    return out
end

function Rect.columns(rect, count, gap)
    gap = gap or 0
    local out = {}
    local width = math.floor((rect.w - gap * (count - 1)) / count)
    for index = 1, count do
        local x = rect.x + (index - 1) * (width + gap)
        local w = index == count and (rect.x + rect.w - x) or width
        out[index] = Rect.new(x, rect.y, w, rect.h)
    end
    return out
end

--------------------------------------------------------------------------
-- Text metrics
--------------------------------------------------------------------------

--[[--
How wide a string is, approximately.

The same crude `size * 0.5` the stub engine uses, and for the same reason:
the UI needs to centre a label and truncate a long title, and both want an
answer that is reproducible rather than correct. On the device this is
replaced by FreeType's own measurement -- see `device/kobase.lua`, which
overrides it -- and a label that was a few pixels off in the suite is a
label that is right on the reader.
--]]--
function Widget.textWidth(text, size)
    return math.floor(#tostring(text) * size * 0.5)
end

--- A string cut to fit, with an ellipsis when it had to be.
function Widget.truncate(text, size, max_width)
    text = tostring(text)
    if Widget.textWidth(text, size) <= max_width then return text end
    local per_char = math.max(math.floor(size * 0.5), 1)
    local room = math.floor(max_width / per_char) - 1
    if room < 1 then return "" end
    return text:sub(1, room) .. "\u{2026}"
end

--------------------------------------------------------------------------
-- The stack
--------------------------------------------------------------------------

local Stack = {}
Stack.__index = Stack
Widget.Stack = Stack

--[[--
A stack of views, the top one visible.

A stack rather than a single current view because a reader is a book with
things put *over* it -- the table of contents, the typography panel, a
dialogue -- and all of them want the same behaviour on being dismissed:
the thing underneath comes back untouched. Replacing the view instead
would mean rebuilding the reader, and rebuilding the reader means losing
the page it was on, which is the bug this shape prevents.
--]]--
function Widget.stack()
    return setmetatable({ views = {}, dirty = true }, Stack)
end

function Stack:push(view)
    self.views[#self.views+1] = view
    self.dirty = true
    if view.onShow then view:onShow() end
    return view
end

function Stack:pop()
    local view = table.remove(self.views)
    if view and view.onHide then view:onHide() end
    self.dirty = true
    return view
end

function Stack:top() return self.views[#self.views] end
function Stack:depth() return #self.views end

--- Replaces everything, for the one case that really is a new screen.
function Stack:reset(view)
    while #self.views > 0 do self:pop() end
    return self:push(view)
end

function Stack:markDirty() self.dirty = true end

--[[--
Paints the whole stack bottom to top.

Everything, every time, including the views underneath. Cheaper than
tracking what a dialogue overlapped, and on e-ink the refresh dominates
anyway.
--]]--
function Stack:paint(surface, rect)
    surface:reset()
    for _, view in ipairs(self.views) do
        view:paint(surface, rect)
    end
    self.dirty = false
end

--[[--
Hands an event to the top view, and only to the top view.

No bubbling. A tap that the topmost view did not want is a tap on a
dialogue's own background, and passing it down to the reader behind would
turn a missed button into a page turn -- which is exactly the kind of
thing that makes a device feel broken.
--]]--
function Stack:handle(event)
    local view = self:top()
    if not view then return false end
    local handled = false
    if event.kind == "tap" and view.onTap then
        handled = view:onTap(event.x, event.y)
    elseif event.kind == "key" and view.onKey then
        handled = view:onKey(event.key)
    elseif event.kind == "swipe" and view.onSwipe then
        handled = view:onSwipe(event.dir)
    end
    if handled then self.dirty = true end
    return handled
end

return Widget
