--[[--
The book list, spread across the devices.

One simulated device here; the two-device version is in integration_spec,
where the halves of the listing have to line up across a real socket.
--]]--

local T = require("spec/testrunner")
local Browser = require("duo/browser")
local Instance = require("spec/harness/instance")

local function books(count, prefix)
    local names = {}
    for index = 1, count do
        names[index] = ("%s%02d.epub"):format(prefix or "book", index)
    end
    return names
end

T.describe("reading the listing", function()
    local device = Instance.new{
        name = "Kindle-B", file_manager = true,
        path = "/books", items = books(20), perpage = 6,
    }

    T.it("sees the browser when there is one", function()
        T.assertTrue(Browser.isAvailable(device.ui))
        T.assertTrue(not Browser.isAvailable({}))
    end)

    T.it("reports the page, the size of a page and the folder", function()
        local state = Browser.snapshot(device.ui)
        T.assertEquals(state.path, "/books")
        T.assertEquals(state.page, 1)
        T.assertEquals(state.perpage, 6)
        T.assertEquals(state.count, 20)
        T.assertEquals(state.pages, 4) -- 20 books, 6 to a screen
    end)

    T.it("shows the first screenful", function()
        T.assertTableEquals(device:visibleBooks(),
            { "book01.epub", "book02.epub", "book03.epub", "book04.epub", "book05.epub", "book06.epub" })
    end)

    T.it("moves to a page", function()
        Browser.goToPage(device.ui, 2)
        T.assertEquals(device.ui.file_chooser.page, 2)
        T.assertTableEquals(device:visibleBooks(),
            { "book07.epub", "book08.epub", "book09.epub", "book10.epub", "book11.epub", "book12.epub" })
        Browser.goToPage(device.ui, 1)
    end)

    T.it("will not go off the end of the list", function()
        Browser.goToPage(device.ui, 99)
        T.assertEquals(device.ui.file_chooser.page, 4)
        Browser.goToPage(device.ui, -5)
        T.assertEquals(device.ui.file_chooser.page, 1)
    end)
end)

T.describe("noticing a different library", function()
    T.it("hashes the names in order", function()
        local one = Browser.hashNames({ "a.epub", "b.epub" })
        T.assertEquals(one, Browser.hashNames({ "a.epub", "b.epub" }))
        -- The order is what decides which book lands on which screen, so a
        -- reordered list is a different list.
        T.assertNotEquals(one, Browser.hashNames({ "b.epub", "a.epub" }))
        T.assertNotEquals(one, Browser.hashNames({ "a.epub", "c.epub" }))
        T.assertNotEquals(one, Browser.hashNames({ "a.epub" }))
    end)

    T.it("does not confuse names that share a boundary", function()
        -- Without a separator "ab" + "c" would hash the same as "a" + "bc".
        T.assertNotEquals(Browser.hashNames({ "ab", "c" }), Browser.hashNames({ "a", "bc" }))
    end)

    T.it("changes when the folder's contents change", function()
        local device = Instance.new{
            name = "Kindle-C", file_manager = true,
            path = "/books", items = books(8), perpage = 4,
        }
        local before = Browser.signature(device.ui)
        device.ui.file_chooser:setItems(books(9))
        T.assertNotEquals(Browser.signature(device.ui), before)
    end)
end)

T.describe("matching the shape of a screenful", function()
    T.it("changes how many items fit, and repaginates", function()
        local device = Instance.new{
            name = "Kindle-D", file_manager = true,
            path = "/books", items = books(24), perpage = 6,
        }
        T.assertEquals(device.ui.file_chooser.page_num, 4)
        T.assertTrue(Browser.setPerPage(device.ui, 8))
        T.assertEquals(device.ui.file_chooser.perpage, 8)
        T.assertEquals(device.ui.file_chooser.page_num, 3)
        -- Nothing to do when it already matches.
        T.assertTrue(not Browser.setPerPage(device.ui, 8))
    end)

    T.it("tells the cover browser instead, when that is drawing the list", function()
        local device = Instance.new{
            name = "Kindle-D2", file_manager = true,
            path = "/books", items = books(24), perpage = 6,
        }
        local chooser = device.ui.file_chooser:asCoverBrowser("list", { files_per_page = 10 })
        T.assertEquals(chooser.page_num, 3) -- 24 books, 10 to a screen

        T.assertTrue(Browser.setPerPage(device.ui, 8))
        T.assertEquals(chooser.files_per_page, 8, "the cover browser's own number")
        T.assertEquals(chooser.perpage, 8)
        T.assertEquals(chooser.page_num, 3)
        -- The global is the plain browser's setting, and means nothing here.
        T.assertEquals(G_reader_settings:readSetting("items_per_page"), nil)
    end)

    T.it("takes a grid of covers from another grid, shape and all", function()
        local device = Instance.new{
            name = "Kindle-D3", file_manager = true,
            path = "/books", items = books(24), perpage = 6,
        }
        local chooser = device.ui.file_chooser:asCoverBrowser("mosaic", { cols = 2, rows = 3 })
        T.assertEquals(chooser.perpage, 6)

        T.assertTrue(Browser.setPerPage(device.ui, 12, 3, 4))
        T.assertEquals(chooser.nb_cols, 3)
        T.assertEquals(chooser.nb_rows, 4)
        T.assertEquals(chooser.perpage, 12, "three across and four down is twelve")
        T.assertEquals(chooser.page_num, 2)
    end)

    T.it("keeps the grid to the orientation it is in", function()
        local device = Instance.new{
            name = "Kindle-D4", file_manager = true,
            path = "/books", items = books(24), perpage = 6,
        }
        local chooser = device.ui.file_chooser:asCoverBrowser("mosaic",
            { cols = 2, rows = 3, portrait = false })
        T.assertTrue(Browser.setPerPage(device.ui, 12, 3, 4))
        T.assertEquals(chooser.nb_cols_landscape, 3)
        T.assertEquals(chooser.nb_rows_landscape, 4)
        T.assertEquals(chooser.nb_cols_portrait, nil,
            "the other orientation's grid is not this one's to change")
    end)

    T.it("leaves a grid alone when told only a total", function()
        local device = Instance.new{
            name = "Kindle-D5", file_manager = true,
            path = "/books", items = books(24), perpage = 6,
        }
        local chooser = device.ui.file_chooser:asCoverBrowser("mosaic", { cols = 3, rows = 3 })
        T.assertTrue(not Browser.setPerPage(device.ui, 8),
            "eight could be two by four or one by eight; guessing would rearrange the screen")
        T.assertEquals(chooser.perpage, 9)
    end)
end)

T.describe("changing folder", function()
    -- Built inside each test: every Instance installs its own stub of
    -- KOReader, so a device made later would replace the one this test set
    -- up (a single Lua state is a single device, which is why the
    -- two-device tests use two processes).
    local function deviceWithFolders()
        return Instance.new{
            name = "Kindle-E", file_manager = true,
            path = "/books", items = books(6), perpage = 3,
            folders = { ["/books"] = books(6), ["/books/sf"] = books(4, "sf") },
        }
    end

    T.it("follows the other device into a folder it has", function()
        local device = deviceWithFolders()
        T.assertTrue(Browser.changeDir(device.ui, "/books/sf"))
        T.assertEquals(device.ui.file_chooser.path, "/books/sf")
        T.assertEquals(#device.ui.file_chooser.item_table, 4)
        T.assertEquals(device.ui.file_chooser.page, 1, "a new folder starts at the top")
    end)

    T.it("says no to a folder it does not have", function()
        local device = deviceWithFolders()
        T.assertTrue(not Browser.changeDir(device.ui, "/books/nowhere-at-all"))
        T.assertEquals(device.ui.file_chooser.path, "/books", "it should not have moved")
    end)
end)

T.describe("the library's own views, not only folders", function()
    --[[
    A skin like ZenOS puts a library in front of the reader instead of a
    file browser: Favourites, History, a collection, To Be Read. Those are
    KOReader's own list widgets wearing different clothes -- `Menu`s with
    pages, the same as the file browser -- but they live somewhere else on
    the file manager, and Duo could only ever see `ui.file_chooser`. So the
    nicest half of the library was the half the spread could not touch.
    ]]
    local Reader = require("spec/harness/reader")
    local device = Instance.new{
        name = "Kindle-Z", file_manager = true,
        path = "/books", items = books(20), perpage = 6,
    }

    local function inFolder()
        Reader.closeLibraryView(device.ui)
    end

    T.it("pages through History the same way it pages through a folder", function()
        inFolder()
        Reader.openLibraryView(device.ui, "history", { items = books(20, "read"), perpage = 6 })
        T.assertTrue(Browser.isAvailable(device.ui), "History is a list of books like any other")
        local state = Browser.snapshot(device.ui)
        T.assertEquals(state.kind, "history")
        T.assertEquals(state.pages, 4)
        T.assertTrue(Browser.goToPage(device.ui, 3))
        T.assertEquals(Browser.snapshot(device.ui).page, 3)
        inFolder()
    end)

    T.it("tells one list from another before either offsets a page", function()
        --[[
        The whole reason a view has a name. Page 2 of Favourites and page 2
        of a folder have nothing to do with each other, and offsetting
        between them would put two devices confidently on unrelated screens.
        ]]
        inFolder()
        local folder = Browser.snapshot(device.ui).view
        T.assertEquals(folder, "folder:/books")

        Reader.openLibraryView(device.ui, "history", { items = books(8, "read") })
        local history = Browser.snapshot(device.ui).view
        T.assertEquals(history, "history")

        Reader.closeLibraryView(device.ui)
        Reader.openLibraryView(device.ui, "collection", { items = books(8, "fav"), name = "Favourites" })
        local favourites = Browser.snapshot(device.ui).view
        T.assertEquals(favourites, "collection:Favourites")

        Reader.closeLibraryView(device.ui)
        Reader.openLibraryView(device.ui, "collection", { items = books(8, "tbr"), name = "To Be Read" })
        T.assertNotEquals(Browser.snapshot(device.ui).view, favourites,
            "two collections are two different lists of books")
        inFolder()
    end)

    T.it("will not send a library view off to a folder", function()
        -- A view is something the reader chose. Duo pages along with one; it
        -- does not swap the screen out from under that choice.
        inFolder()
        Reader.openLibraryView(device.ui, "collection", { items = books(8, "fav") })
        T.assertTrue(not Browser.changeDir(device.ui, "/books"),
            "a collection was told to change directory")
        T.assertTrue(not Browser.isFolder(device.ui))
        inFolder()
        T.assertTrue(Browser.isFolder(device.ui))
    end)

    T.it("reads the books out of a view that does not label its rows", function()
        -- A folder listing marks each row a file because it also holds
        -- folders. A list of books is all books and often says nothing.
        inFolder()
        local menu = Reader.openLibraryView(device.ui, "history", { items = books(3, "read") })
        for _, item in ipairs(menu.item_table) do item.is_file = nil end
        T.assertEquals(#Browser.fileEntries(device.ui), 3,
            "the books in a library view went uncounted")
        inFolder()
    end)

    T.it("follows what is on top rather than what merely exists", function()
        --[[
        The file browser stays alive underneath while a view is shown over
        it, so "is there a file browser?" is true the whole time somebody is
        in the library. KOReader builds these menus when it shows one and
        drops them when it closes, which is how it answers the same question
        itself, so the view being there at all is what puts it on top.
        ]]
        inFolder()
        T.assertEquals(Browser.snapshot(device.ui).kind, "folder")
        Reader.openLibraryView(device.ui, "history", { items = books(8, "read") })
        T.assertEquals(Browser.snapshot(device.ui).kind, "history",
            "the folder underneath was answering for the view on top of it")
        inFolder()
        T.assertEquals(Browser.snapshot(device.ui).kind, "folder",
            "closing the view should hand the screen back to the folder")
    end)
end)

os.exit(T.run())
