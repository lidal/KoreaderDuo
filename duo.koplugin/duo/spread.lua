--[[--
Where each device sits in the spread.

This is the whole idea of the plugin in twenty lines: with N devices in
spread mode the leader shows page P and the device in slot i shows P+i, so
one page turn has to advance the leader by N pages rather than one. Mirror
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

--- How many pages one turn should move the leader.
-- @string mode Spread.SPREAD or Spread.MIRROR
-- @number follower_count number of connected followers
function Spread.stepFor(mode, follower_count)
    if mode == Spread.MIRROR then return 1 end
    return 1 + math.max(follower_count or 0, 0)
end

--[[--
The page a follower should display.

@number leader_page the page the leader is on
@number slot the follower's index, 1 for the first one
@tparam table options mode, page_count, reverse
@treturn number page to display
@treturn boolean true when that page had to be clamped, i.e. the follower is
    being asked to show something outside the book
--]]--
function Spread.pageForSlot(leader_page, slot, options)
    options = options or {}
    local page_count = options.page_count
    if options.mode == Spread.MIRROR then
        return leader_page, false
    end
    -- `reverse` puts the leader on the right-hand page, for right-to-left
    -- books or simply for whichever device sits on the right of the table.
    -- A device configured to show two pages side by side consumes two page
    -- numbers per screen, so the gap between devices has to grow to match.
    local per_screen = options.pages_per_view or 1
    local wanted = leader_page + slot * per_screen * (options.reverse and -1 or 1)
    local clamped = Util.clamp(wanted, 1, page_count or math.huge)
    return clamped, clamped ~= wanted
end

--- The full layout, leader included, left to right.
-- @treturn table array of { slot = 0 for the leader, page = n, clamped = bool }
function Spread.layout(leader_page, follower_count, options)
    local pages = { { slot = 0, page = leader_page, clamped = false } }
    for slot = 1, (follower_count or 0) do
        local page, clamped = Spread.pageForSlot(leader_page, slot, options)
        pages[#pages+1] = { slot = slot, page = page, clamped = clamped }
    end
    if options and options.reverse then
        -- Highest slot is leftmost when the leader holds the right page.
        local reversed = {}
        for i = #pages, 1, -1 do reversed[#reversed+1] = pages[i] end
        return reversed
    end
    return pages
end

--- "12–13" or "12" — the pages currently on show, for the status line.
function Spread.describeLayout(leader_page, follower_count, options)
    local layout = Spread.layout(leader_page, follower_count, options)
    local parts = {}
    for _, entry in ipairs(layout) do
        parts[#parts+1] = tostring(entry.page)
    end
    return table.concat(parts, "–")
end

return Spread
