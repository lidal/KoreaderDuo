--[[--
The book list, spread across the devices too.

The same idea as the reading spread, one level up: the master shows the
first screenful of the folder, the next device shows the screenful after
that, and one swipe moves the whole row along. Twelve books in view instead
of six, and picking one on either device opens it on both.

KOReader's file browser is a `Menu`, which already thinks in pages: it has
`page`, `perpage` and `onGotoPage`, so the arithmetic in `duo/spread` works
here unchanged.

Two things have to line up for the offset to mean anything, and both are
checked rather than assumed: the two devices must be looking at the same
folder with the same list in it, and they must fit the same number of items
on a screen.

@module duo.browser
--]]--

local Browser = {}

--- True when this device is showing a file browser at all.
function Browser.isAvailable(ui)
    return ui ~= nil and ui.file_chooser ~= nil
end

--[[--
A cheap order-sensitive hash of the names on show.

Not a checksum against tampering — a way to notice that two devices are
looking at different libraries, which would make the offset nonsense. Kept
small and exact in doubles so it costs nothing on a slow device.
--]]--
function Browser.hashNames(names)
    local hash = 5381
    for _, name in ipairs(names or {}) do
        for index = 1, #name do
            hash = (hash * 131 + name:byte(index)) % 16777213
        end
        hash = (hash * 131 + 10) % 16777213 -- separator, so order matters
    end
    return string.format("%x", hash)
end

--- The names in the current listing, in the order they are displayed.
function Browser.itemNames(ui)
    local names = {}
    if not Browser.isAvailable(ui) then return names end
    for _, item in ipairs(ui.file_chooser.item_table or {}) do
        names[#names+1] = tostring(item.text or item.path or "")
    end
    return names
end

local signature_cache = {}

--- Hash of the listing, recomputed only when the listing could have changed.
function Browser.signature(ui)
    if not Browser.isAvailable(ui) then return "" end
    local chooser = ui.file_chooser
    local count = #(chooser.item_table or {})
    local key = tostring(chooser.path) .. "#" .. count
    if signature_cache.key == key then
        return signature_cache.value
    end
    local value = Browser.hashNames(Browser.itemNames(ui))
    signature_cache = { key = key, value = value }
    return value
end

--[[--
The books in the current folder, as the browser lists them.

Taken from the browser's own list rather than from the filesystem, so it is
already what the user sees: KOReader's file filter has been applied, sub
folders are left out, and the order is the one both devices are paging
through.

@treturn table array of { name=, size= }
--]]--
function Browser.fileEntries(ui)
    local entries = {}
    if not Browser.isAvailable(ui) then return entries end
    for _, item in ipairs(ui.file_chooser.item_table or {}) do
        if item.is_file then
            entries[#entries+1] = {
                name = tostring(item.text or ""),
                size = (item.attr and item.attr.size) or 0,
            }
        end
    end
    return entries
end

--- Rebuilds the listing, after a book has arrived in the folder.
function Browser.refresh(ui)
    if not Browser.isAvailable(ui) then return false end
    ui.file_chooser:refreshPath()
    return true
end

--- Everything the other devices need to show their part of the listing.
-- `cols` and `rows` are only there when the cover browser is drawing the
-- listing as a grid, where a screenful is their product rather than a
-- number in its own right.
function Browser.snapshot(ui)
    if not Browser.isAvailable(ui) then return nil end
    local chooser = ui.file_chooser
    local state = {
        path = tostring(chooser.path or ""),
        page = chooser.page or 1,
        pages = chooser.page_num or 1,
        perpage = chooser.perpage or 0,
        count = #(chooser.item_table or {}),
    }
    if chooser.display_mode_type == "mosaic" then
        state.cols = chooser.nb_cols
        state.rows = chooser.nb_rows
    end
    return state
end

--- Moves this device's listing to a page.
function Browser.goToPage(ui, page)
    if not Browser.isAvailable(ui) then return false end
    local chooser = ui.file_chooser
    local total = chooser.page_num or 1
    page = math.max(1, math.min(page, total))
    if chooser.page == page then return true end
    chooser:onGotoPage(page)
    return true
end

--- Opens a different folder, when this device has it.
-- @treturn boolean true when the folder was there and we moved to it
function Browser.changeDir(ui, path)
    if not Browser.isAvailable(ui) or not path or path == "" then return false end
    local chooser = ui.file_chooser
    if chooser.path == path then return true end
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok and lfs and lfs.attributes(path, "mode") ~= "directory" then
        return false
    end
    chooser:changeToPath(path)
    return true
end

--[[--
Makes this device fit the same number of items on a screen.

Without this the offset means nothing — device two would start its page
somewhere in the middle of device one's.

Three different widgets can be drawing that list, and they disagree about
where the number comes from. The plain file browser reads `items_per_page`
out of the global settings. The cover browser's list mode works out a
`files_per_page` from the screen height and ignores that global entirely.
Its mosaic mode has no such number at all: a screenful there is a grid, and
the count is its columns times its rows. Whichever is actually in charge is
the one told, each the way its own settings screen does it.

A grid can therefore only be matched against another grid, where the shape
comes over as it is rather than being guessed back out of the total — nine
could be three by three or one by nine, and picking wrong would rearrange
somebody's screen. Told a bare number, a grid is left as it is and the
caller warns instead.

The new shape is applied but not saved: Duo sets it again on every
connection, and quietly rewriting the cover browser's stored settings would
outlive the pairing that wanted it.

@int perpage    items the other device fits on a screen
@int[opt] cols  columns, when the other device is showing a grid
@int[opt] rows  rows, likewise
@treturn boolean true when the listing was changed
--]]--
function Browser.setPerPage(ui, perpage, cols, rows)
    if not Browser.isAvailable(ui) then return false end
    perpage = tonumber(perpage)
    if not perpage or perpage < 1 then return false end
    local chooser = ui.file_chooser
    if (chooser.perpage or 0) == perpage then return false end

    if chooser.display_mode_type == "mosaic" then
        cols, rows = tonumber(cols), tonumber(rows)
        if not cols or not rows or cols < 1 or rows < 1 then return false end
        -- The grid is kept per orientation, and only the one in use now
        -- decides what is on the screen.
        if chooser.portrait_mode == false then
            chooser.nb_cols_landscape, chooser.nb_rows_landscape = cols, rows
        else
            chooser.nb_cols_portrait, chooser.nb_rows_portrait = cols, rows
        end
        chooser.no_refresh_covers = nil
        chooser:updateItems()
        return true
    end

    if chooser.display_mode_type == "list" then
        chooser.files_per_page = perpage
        chooser.no_refresh_covers = nil
        chooser:updateItems()
        return true
    end

    if not G_reader_settings then return false end
    G_reader_settings:saveSetting("items_per_page", perpage)
    -- The widget's own override would win over the global we just set.
    chooser.items_per_page = perpage
    chooser:refreshPath()
    return true
end

return Browser
