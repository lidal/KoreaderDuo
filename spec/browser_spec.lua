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

return T.run()
