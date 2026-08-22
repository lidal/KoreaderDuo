--[[--
The book list, spread across the devices too.

The same idea as the reading spread, one level up: the leader shows the
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

--[[--
Every place a list of books might be on screen.

The file browser is one of several. KOReader shows History and each
collection through widgets of their own, and a skin like ZenOS leans on
exactly those to build the library it puts in front of you -- Favourites,
Collections, Series, To Be Read are KOReader's own list widgets wearing
different clothes. All of them are `Menu`s underneath, with the same
`page`, `perpage` and `onGotoPage` the spread arithmetic needs, so all of
them can be spread; only the file browser ever was.

Probed rather than assumed. Which field holds the menu has changed between
KOReader releases and is not something a plugin should be certain about, so
each candidate is tried and the first one that looks like a list wins. A
build that keeps it somewhere else costs Duo the library view, not the
plugin.
--]]--
--[[
Ordered by what is on top, not by what exists. The file browser stays alive
underneath while History or a collection is shown over it, so asking for it
first would answer "a folder" the whole time somebody was in the library.
KOReader builds these menus when it shows one and drops them when it
closes -- which is how it answers the same question itself -- so a view
being there at all is what makes it the thing on screen.
]]
local SOURCES = {
    {
        kind = "history",
        find = function(ui)
            local manager = ui.history
            if not manager then return nil end
            return manager.booklist_menu or manager.hist_menu
        end,
    },
    {
        kind = "collection",
        find = function(ui)
            local manager = ui.collections
            if not manager then return nil end
            return manager.booklist_menu or manager.coll_menu
        end,
    },
    {
        kind = "folder",
        find = function(ui) return ui.file_chooser end,
    },
}

--- Whether `menu` is a list this can page through.
local function isList(menu)
    return type(menu) == "table"
        and type(menu.item_table) == "table"
        and menu.onGotoPage ~= nil
end

--[[--
The list this device is showing, and what to call it.

`view` is the identity the two devices compare before either of them offsets
a page. A folder is named by its path, as it always was; the others are
named by what they are, because "page 2" of Favourites and "page 2" of a
folder have nothing to do with each other and offsetting between them would
put two devices confidently on unrelated screens.

@treturn table|nil { menu =, kind =, view =, path = } -- path only for folders
--]]--
function Browser.currentList(ui)
    if ui == nil then return nil end
    for _, source in ipairs(SOURCES) do
        local ok, menu = pcall(source.find, ui)
        if ok and isList(menu) then
            local path = source.kind == "folder" and tostring(menu.path or "") or nil
            local view = source.kind
            if source.kind == "folder" then
                view = "folder:" .. (path or "")
            elseif source.kind == "collection" then
                -- Which collection, not merely that it is one: Favourites
                -- and To Be Read are different lists of books.
                local name = menu.collection_name or menu.coll_name
                    or (ui.collections and ui.collections.coll_name)
                view = "collection:" .. tostring(name or "")
            end
            return { menu = menu, kind = source.kind, view = view, path = path }
        end
    end
    return nil
end

--- The menu on screen, or nil.
local function menuOf(ui)
    local list = Browser.currentList(ui)
    return list and list.menu or nil
end

--- True when this device is showing a list of books at all.
function Browser.isAvailable(ui)
    return Browser.currentList(ui) ~= nil
end

--- True when the list on show is a folder rather than one of the library's
--- own views, which is what tells "open that folder" from "page along".
function Browser.isFolder(ui)
    local list = Browser.currentList(ui)
    return list ~= nil and list.kind == "folder"
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
    local menu = menuOf(ui)
    if not menu then return names end
    for _, item in ipairs(menu.item_table or {}) do
        names[#names+1] = tostring(item.text or item.path or "")
    end
    return names
end

local signature_cache = {}

--- Hash of the listing, recomputed only when the listing could have changed.
function Browser.signature(ui)
    local list = Browser.currentList(ui)
    if not list then return "" end
    local menu = list.menu
    local count = #(menu.item_table or {})
    local key = list.view .. "#" .. count
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
    local menu = menuOf(ui)
    if not menu then return entries end
    for _, item in ipairs(menu.item_table or {}) do
        -- A library view lists nothing but books, and does not always say
        -- so on each row the way a folder listing has to.
        if item.is_file or item.file then
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
    local list = Browser.currentList(ui)
    if not list then return false end
    local menu = list.menu
    -- Only a folder has a path to read again. A library view is rebuilt
    -- from what it is a view of, and refreshing it is its own business.
    if menu.refreshPath then
        menu:refreshPath()
    elseif menu.updateItems then
        menu:updateItems()
    end
    return true
end

--- Everything the other devices need to show their part of the listing.
-- `cols` and `rows` are only there when the cover browser is drawing the
-- listing as a grid, where a screenful is their product rather than a
-- number in its own right.
function Browser.snapshot(ui)
    local list = Browser.currentList(ui)
    if not list then return nil end
    local chooser = list.menu
    local state = {
        view = list.view,
        kind = list.kind,
        path = tostring(list.path or ""),
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
    local chooser = menuOf(ui)
    if not chooser then return false end
    local total = chooser.page_num or 1
    page = math.max(1, math.min(page, total))
    if chooser.page == page then return true end
    chooser:onGotoPage(page)
    return true
end

--- Opens a different folder, when this device has it.
-- @treturn boolean true when the folder was there and we moved to it
function Browser.changeDir(ui, path)
    if not path or path == "" then return false end
    local list = Browser.currentList(ui)
    -- Only a folder listing can be sent to a folder. A library view is not
    -- a place on the disk, and telling one to change directory would swap
    -- the screen out from under somebody who chose that view.
    if not list or list.kind ~= "folder" then return false end
    local chooser = list.menu
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
    local chooser = menuOf(ui)
    if not chooser then return false end
    perpage = tonumber(perpage)
    if not perpage or perpage < 1 then return false end
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
