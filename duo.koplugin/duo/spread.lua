--[[--
Where each device sits in the spread.

This is the whole idea of the plugin in twenty lines: with N devices in
spread mode the master shows page P and the device in slot i shows P+i, so
one page turn has to advance the master by N pages rather than one. Mirror
mode puts everyone on the same page instead, which is what you want when
two people read one book together.

Kept free of any KOReader or socket dependency so the arithmetic can be
tested on its own — off-by-ones here are exactly the bugs that would be
maddening to chase on a pair of e-readers.

@module duo.spread
--]]--

local Util = require("duo/util")

local Spread = {}

Spread.SPREAD = "spread"
Spread.MIRROR = "mirror"

--- How many pages one turn should move the master.
-- @string mode Spread.SPREAD or Spread.MIRROR
-- @number slave_count number of connected slaves
function Spread.stepFor(mode, slave_count)
    if mode == Spread.MIRROR then return 1 end
    return 1 + math.max(slave_count or 0, 0)
end

--[[--
The page a slave should display.

@number master_page the page the master is on
@number slot the slave's index, 1 for the first one
@tparam table options mode, page_count, reverse
@treturn number page to display
@treturn boolean true when that page had to be clamped, i.e. the slave is
    being asked to show something outside the book
--]]--
function Spread.pageForSlot(master_page, slot, options)
    options = options or {}
    local page_count = options.page_count
    if options.mode == Spread.MIRROR then
        return master_page, false
    end
    -- `reverse` puts the master on the right-hand page, for right-to-left
    -- books or simply for whichever device sits on the right of the table.
    -- A device configured to show two pages side by side consumes two page
    -- numbers per screen, so the gap between devices has to grow to match.
    local per_screen = options.pages_per_view or 1
    local wanted = master_page + slot * per_screen * (options.reverse and -1 or 1)
    local clamped = Util.clamp(wanted, 1, page_count or math.huge)
    return clamped, clamped ~= wanted
end

--- The full layout, master included, left to right.
-- @treturn table array of { slot = 0 for the master, page = n, clamped = bool }
function Spread.layout(master_page, slave_count, options)
    local pages = { { slot = 0, page = master_page, clamped = false } }
    for slot = 1, (slave_count or 0) do
        local page, clamped = Spread.pageForSlot(master_page, slot, options)
        pages[#pages+1] = { slot = slot, page = page, clamped = clamped }
    end
    if options and options.reverse then
        -- Highest slot is leftmost when the master holds the right page.
        local reversed = {}
        for i = #pages, 1, -1 do reversed[#reversed+1] = pages[i] end
        return reversed
    end
    return pages
end

--- "12–13" or "12" — the pages currently on show, for the status line.
function Spread.describeLayout(master_page, slave_count, options)
    local layout = Spread.layout(master_page, slave_count, options)
    local parts = {}
    for _, entry in ipairs(layout) do
        parts[#parts+1] = tostring(entry.page)
    end
    return table.concat(parts, "–")
end

return Spread
