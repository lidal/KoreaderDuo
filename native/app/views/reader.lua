--[[--
The book on screen.

Draws whatever the engine renders, plus the two strips of chrome a reader
needs: what you are reading at the top, where you are at the bottom.

**Page turns go through one method.** `Reader:turn(n)` is the only way the
page ever changes, and it asks the delegate first. That is deliberately the
same shape the plugin found its way to -- "page turns are intercepted, not
simulated" -- because with two devices a turn is not a local event: the
leader has to move by the width of the whole spread, and a follower's tap
is a *request* that may be refused. Any view that moved the page itself
would be a view that silently broke the pair, and there would be no single
place to look.

So: taps, keys and swipes all land in `turn`, `turn` offers it to the
delegate, and only an unclaimed turn moves this device on its own.

@module duonative.views.reader
--]]--

local Widget = require("app/ui/widget")
local Rect = Widget.Rect

local Reader = {}
Reader.__index = Reader

local HEADER_H = 46
local FOOTER_H = 46
local CHROME_SIZE = 20

--[[--
@tparam table options
    doc       an engine document
    delegate  gets first refusal on turns and taps (optional)
    chrome    false to draw the page and nothing else
--]]--
function Reader.new(options)
    options = options or {}
    return setmetatable({
        doc = options.doc,
        delegate = options.delegate,
        chrome = options.chrome ~= false,
        title = options.title,
    }, Reader)
end

function Reader:document() return self.doc end

--------------------------------------------------------------------------
-- Moving
--------------------------------------------------------------------------

--[[--
The one way the page changes.

@number diff pages to move, signed
@tparam[opt] table options `local_only` to skip the delegate, which is what
    the delegate itself calls back with once it has decided
@treturn boolean whether anything moved
--]]--
--[[--
Says the page moved, whatever moved it.

Called after *every* change, including ones the pair itself asked for. That
looks redundant and is not: the engine is built to hear about every move
and work out for itself which ones were its own -- KOReader hands it the
same firehose through `onPageUpdate` -- and the alternative, reporting only
moves the engine did not cause, means the engine never hears about the
ones it most needs to.

Leaving this out is a specific and quiet bug, and the suite caught it:
turns worked, because a turn goes through the engine on the way in, while
a *jump* -- a table of contents, the progress bar, a position restored
after a relayout -- moved this device and nothing else. Which is the
plugin's own rule: jumps are noticed rather than intercepted, so there has
to be something doing the noticing.
--]]--
function Reader:report()
    if not self.doc then return false end
    if self.delegate and self.delegate.onPageMoved then
        self.delegate:onPageMoved(self.doc:page())
    end
    return true
end

function Reader:turn(diff, options)
    options = options or {}
    if not self.doc then return false end
    if not options.local_only and self.delegate and self.delegate.onTurnRequest then
        -- Claimed: the pair is deciding, and it will call back here with
        -- local_only when it has. Nothing moves yet.
        if self.delegate:onTurnRequest(diff) then return false end
    end
    local from = self.doc:page()
    local to = self.doc:gotoPage(from + diff)
    if to ~= from then self:report() end
    return to ~= from
end

--- An absolute move, for a table of contents, a jump, or the other device.
function Reader:gotoPage(page)
    if not self.doc then return false end
    local from = self.doc:page()
    local moved = self.doc:gotoPage(page) ~= from
    if moved then self:report() end
    return moved
end

function Reader:gotoPosition(position)
    if not self.doc then return false end
    local from = self.doc:page()
    self.doc:gotoPosition(position)
    if self.doc:page() ~= from then self:report() end
    return true
end

--------------------------------------------------------------------------
-- Typography
--------------------------------------------------------------------------

--[[--
Applies a layout and says whether the book had to be rebuilt.

Worth routing through here rather than letting callers touch the document:
a relayout is the one operation that changes the page count underneath
everything, and the pair has to be told. The delegate hears about it, and
what it does with that is the two-device code's business.
--]]--
function Reader:applyLayout(layout)
    if not self.doc then return false end
    local reflowed = self.doc:applyLayout(layout)
    if reflowed and self.delegate and self.delegate.onReflow then
        self.delegate:onReflow(self.doc)
    end
    return reflowed
end

function Reader:getLayout()
    return self.doc and self.doc:getLayout() or nil
end

--------------------------------------------------------------------------
-- Input
--------------------------------------------------------------------------

--[[--
Tap zones: left quarter back, right quarter on, the middle asks for the menu.

A quarter rather than a third because the middle is doing more work here
than on a single-device reader -- it is the only way to the typography
panel, and the panel is the thing a reader of a *spread* reaches for most,
since a font change has to be agreed by both devices and so cannot be left
to a gesture nobody can see.
--]]--
function Reader:onTap(x, y)
    local width = self.last_rect and self.last_rect.w or 1072
    local height = self.last_rect and self.last_rect.h or 1448
    if self.chrome and y < HEADER_H then
        if self.delegate and self.delegate.onMenuRequest then
            return self.delegate:onMenuRequest()
        end
        return false
    end
    if x < width / 4 then return self:turn(-1) end
    if x > width * 3 / 4 then return self:turn(1) end
    -- The middle band, excluding the footer, which is a progress tap.
    if self.chrome and y > height - FOOTER_H then
        if self.delegate and self.delegate.onProgressRequest then
            return self.delegate:onProgressRequest(x / width)
        end
        return false
    end
    if self.delegate and self.delegate.onMenuRequest then
        return self.delegate:onMenuRequest()
    end
    return false
end

function Reader:onKey(key)
    if key == "right" or key == "down" then return self:turn(1) end
    if key == "left" or key == "up" then return self:turn(-1) end
    return false
end

function Reader:onSwipe(dir)
    if dir == "left" then return self:turn(1) end
    if dir == "right" then return self:turn(-1) end
    return false
end

--------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------

function Reader:paint(surface, rect)
    self.last_rect = rect
    surface:fill(rect, 15)
    if not self.doc then
        surface:text(rect.x + 40, rect.y + 60, "No book open", { size = 28 })
        return
    end

    local page_rect = rect
    if self.chrome then
        page_rect = Rect.new(rect.x, rect.y + HEADER_H,
            rect.w, rect.h - HEADER_H - FOOTER_H)
        self:paintHeader(surface, rect)
        self:paintFooter(surface, rect)
    end
    surface:clip(page_rect, function()
        self.doc:render(surface, page_rect)
    end)
end

function Reader:paintHeader(surface, rect)
    local props = self.doc:props()
    local title = self.title or props.title or ""
    surface:text(rect.x + 24, rect.y + 30,
        Widget.truncate(title, CHROME_SIZE, rect.w - 48),
        { size = CHROME_SIZE, grey = 4 })
end

--[[--
The footer says the page, and when the pair is up, both pages.

`spread_label` is set by the app from Duo's own description of the layout,
so a reader looking at one screen of two can see that the other is where it
should be -- which is the only way to notice a pair that has drifted
without picking both devices up.
--]]--
function Reader:paintFooter(surface, rect)
    local y = rect.y + rect.h - 16
    local label = self.spread_label
        or ("%d / %d"):format(self.doc:page(), self.doc:pageCount())
    surface:text(rect.x + 24, y, label, { size = CHROME_SIZE, grey = 4 })

    local percent = math.floor(self.doc:page() / math.max(self.doc:pageCount(), 1) * 100)
    local text = percent .. "%"
    surface:text(rect.x + rect.w - 24 - Widget.textWidth(text, CHROME_SIZE), y,
        text, { size = CHROME_SIZE, grey = 4 })
end

function Reader:setSpreadLabel(label)
    self.spread_label = label
end

return Reader
