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

--[[--
The furthest the leader may go and still have a spread that fits.

The last device in the row is the one that runs out of book first, so the
leader's ceiling is the last page minus everything held to its right. Two
devices on a two-page book put the leader on 1 and the follower on 2, and
that is the end of it: there is no third page for the pair to move on to.

Without this the leader turned anyway. Its own page was clamped to the last
one, the follower's was clamped to the same, and a spread that had been
showing 1 and 2 ended up showing 2 and 2 — the same page twice, from a tap
that should have done nothing at all.

Returns nil when nothing is known about the length, and may return less
than 1 for a book too short to fill the spread, which the caller clamps.

@number page_count pages in the book
@number follower_count devices to the leader's right
@tparam table options mode, reverse, pages_per_view
--]]--
function Spread.leaderCeiling(page_count, follower_count, options)
    options = options or {}
    if not page_count or page_count <= 0 then return nil end
    if options.mode == Spread.MIRROR then return page_count end
    local per_screen = options.pages_per_view or 1
    local held = (follower_count or 0) * per_screen
    -- Reversed, the leader holds the right-hand page and the followers run
    -- off the *front* of the book, so the ceiling is the whole book and it
    -- is the floor that moves instead.
    if options.reverse then return page_count end
    return page_count - held
end

--- The earliest page the leader may sit on, the mirror of the above.
function Spread.leaderFloor(page_count, follower_count, options)
    options = options or {}
    if options.mode == Spread.MIRROR or not options.reverse then return 1 end
    local per_screen = options.pages_per_view or 1
    return 1 + (follower_count or 0) * per_screen
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
