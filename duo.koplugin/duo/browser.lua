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

--- Everything the other devices need to show their part of the listing.
function Browser.snapshot(ui)
    if not Browser.isAvailable(ui) then return nil end
    local chooser = ui.file_chooser
    return {
        path = tostring(chooser.path or ""),
        page = chooser.page or 1,
        pages = chooser.page_num or 1,
        perpage = chooser.perpage or 0,
        count = #(chooser.item_table or {}),
    }
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

Applied the way KOReader's own settings screen applies it: save the global
and rebuild the listing. Without this the offset means nothing — device two
would start its page somewhere in the middle of device one's.
--]]--
function Browser.setPerPage(ui, perpage)
    if not Browser.isAvailable(ui) then return false end
    perpage = tonumber(perpage)
    if not perpage or perpage < 1 then return false end
    if (ui.file_chooser.perpage or 0) == perpage then return false end
    if not G_reader_settings then return false end
    G_reader_settings:saveSetting("items_per_page", perpage)
    -- The widget's own override would win over the global we just set.
    ui.file_chooser.items_per_page = perpage
    ui.file_chooser:refreshPath()
    return true
end

return Browser
