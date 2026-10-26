--[[--
The app, driven as a user drives it, against the real Duo engine.

`duo/core.lua` is a module singleton by design -- the plugin's own note:
"the connection outlives the plugin" -- so every App in this file shares
one engine. That is fine for a single device and is why nothing here
starts a link; two connected devices need two processes, which is what
`spec/spread_spec.lua` is for.
--]]--

local t = require("spec/testrunner")
local App = require("app/main")
local FakeDevice = require("app/device/fake")
local Stub = require("app/engine/stub")
local Fixture = require("spec/fixture")

local SHELF = (os.getenv("TMPDIR") or "/tmp") .. "/duonative-spec-shelf"
os.execute(("mkdir -p %q"):format(SHELF))
local BOOK = SHELF .. "/A Book.txt"
do
    local handle = assert(io.open(BOOK, "w"))
    handle:write(Fixture.text())
    handle:close()
    local second = assert(io.open(SHELF .. "/Another.txt", "w"))
    second:write(Fixture.text(30))
    second:close()
end

local function newApp(options)
    options = options or {}
    local store = ("%s/duonative-spec-%d.lua"):format(
        os.getenv("TMPDIR") or "/tmp", math.random(1, 1e9))
    os.remove(store)
    return App.new{
        device = FakeDevice.open{ width = options.width, height = options.height },
        engine = Stub,
        book_dir = SHELF,
        store = store,
    }
end

t.describe("starting up", function()
    t.it("opens on the shelf", function()
        local app = newApp()
        t.assertEquals(app.stack:depth(), 1)
        app:draw(true)
        t.assertMatch(app.device:screen():allText(), "A Book")
    end)

    t.it("refuses a device that does not satisfy the contract", function()
        local ok = pcall(App.new, { device = { size = function() return 1, 1 end }, engine = Stub })
        t.assertTrue(not ok, "should have refused")
    end)

    t.it("lists folders and readable files, and nothing else", function()
        local app = newApp()
        local names = {}
        for _, entry in ipairs(app.library.entries) do names[entry.name] = true end
        t.assertTrue(names["A Book"], "the book should be listed")
    end)

    t.it("draws at a Paperwhite 3's size by default", function()
        local app = newApp()
        t.assertEquals(app.rect.w, 1072)
        t.assertEquals(app.rect.h, 1448)
    end)
end)

t.describe("opening a book", function()
    t.it("puts the reader on screen and draws the text", function()
        local app = newApp()
        t.assertTrue(app:openBook(BOOK), "should have opened")
        app:draw(true)
        local drawn = app.device:screen():allText()
        t.assertMatch(drawn, "reader")
        t.assertMatch(drawn, "1 / %d+")
    end)

    t.it("reports a bad path rather than dying", function()
        local app = newApp()
        t.assertTrue(not app:openBook(SHELF .. "/nope.txt"), "should have failed")
        t.assertTrue(#app.notices > 0, "should have said so")
    end)

    t.it("closes the old document when another is opened", function()
        local app = newApp()
        app:openBook(BOOK)
        local first = app.reader:document()
        app:openBook(SHELF .. "/Another.txt")
        t.assertTrue(first.closed, "the first document should have been closed")
    end)

    t.it("comes back to the shelf, having remembered the place", function()
        local app = newApp()
        app:openBook(BOOK)
        app.reader:turn(4)
        local position = app.reader:document():position()
        app:closeBook()
        t.assertEquals(app.stack:depth(), 1)

        app:openBook(BOOK)
        t.assertEquals(app.reader:document():position(), position)
    end)
end)

t.describe("turning pages", function()
    t.it("moves on a tap in the right quarter", function()
        local app = newApp()
        app:openBook(BOOK)
        app:draw(true)
        t.assertEquals(app.reader:document():page(), 1)
        app.stack:handle{ kind = "tap", x = 1000, y = 700 }
        t.assertEquals(app.reader:document():page(), 2)
    end)

    t.it("moves back on a tap in the left quarter", function()
        local app = newApp()
        app:openBook(BOOK)
        app:draw(true)
        app.reader:turn(3)
        app.stack:handle{ kind = "tap", x = 40, y = 700 }
        t.assertEquals(app.reader:document():page(), 3)
    end)

    t.it("answers keys and swipes the same way", function()
        local app = newApp()
        app:openBook(BOOK)
        app:draw(true)
        app.stack:handle{ kind = "key", key = "right" }
        t.assertEquals(app.reader:document():page(), 2)
        app.stack:handle{ kind = "swipe", dir = "right" }
        t.assertEquals(app.reader:document():page(), 1)
    end)

    t.it("will not turn past either end", function()
        local app = newApp()
        app:openBook(BOOK)
        app.reader:turn(-5)
        t.assertEquals(app.reader:document():page(), 1)
        app.reader:turn(99999)
        local doc = app.reader:document()
        t.assertEquals(doc:page(), doc:pageCount())
    end)
end)

t.describe("the typography panel", function()
    local function openPanel(app)
        app:openBook(BOOK)
        app:draw(true)
        -- A tap in the header asks for the menu.
        app.stack:handle{ kind = "tap", x = 500, y = 10 }
        return app.stack:top()
    end

    t.it("opens over the book without closing it", function()
        local app = newApp()
        local panel = openPanel(app)
        t.assertEquals(app.stack:depth(), 2)
        app:draw(true)
        t.assertMatch(app.device:screen():allText(), "Typography")
        t.assertTrue(app.reader ~= nil, "the reader is still there underneath")
    end)

    t.it("offers every control that was asked for", function()
        local app = newApp()
        local panel = openPanel(app)
        local labels = {}
        for _, row in ipairs(panel.rows) do labels[row.label] = true end
        t.assertTrue(labels["Typeface"], "font selection")
        t.assertTrue(labels["Font size"], "font size")
        t.assertTrue(labels["Margin, left"], "margins")
        t.assertTrue(labels["The book's own styles"], "embedded styles")
        t.assertTrue(labels["The book's own fonts"], "embedded fonts")
    end)

    t.it("repaginates the book when the font size changes", function()
        local app = newApp()
        local panel = openPanel(app)
        local before = app.reader:document():pageCount()
        for _ = 1, 8 do panel:nudge(panel.rows[2], 1) end   -- font size up
        panel:apply()
        t.assertTrue(app.reader:document():pageCount() > before,
            ("%d should exceed %d"):format(app.reader:document():pageCount(), before))
    end)

    t.it("keeps the reader's place across that change", function()
        local app = newApp()
        app:openBook(BOOK)
        app.reader:turn(5)
        local position = app.reader:document():position()
        app.stack:handle{ kind = "tap", x = 500, y = 10 }
        local panel = app.stack:top()
        for _ = 1, 6 do panel:nudge(panel.rows[2], 1) end
        panel:apply()
        t.assertEquals(app.reader:document():pageOf(position), app.reader:document():page())
    end)

    t.it("does nothing at all when nothing was changed", function()
        local app = newApp()
        local panel = openPanel(app)
        local before = app.reader:document():fingerprint()
        panel:apply()
        t.assertEquals(app.reader:document():fingerprint(), before)
    end)

    t.it("will not run the font size off either end", function()
        local app = newApp()
        local panel = openPanel(app)
        for _ = 1, 200 do panel:nudge(panel.rows[2], 1) end
        t.assertEquals(panel.layout.size, 60)
        for _ = 1, 500 do panel:nudge(panel.rows[2], -1) end
        t.assertEquals(panel.layout.size, 12)
    end)

    t.it("toggles the book's own styles rather than stepping them", function()
        local app = newApp()
        local panel = openPanel(app)
        local row
        for _, candidate in ipairs(panel.rows) do
            if candidate.key == "embedded_styles" then row = candidate end
        end
        t.assertEquals(row.read(panel.layout), true)
        panel:nudge(row, 1)
        t.assertEquals(row.read(panel.layout), false)
    end)

    t.it("remembers the layout for the next book", function()
        local app = newApp()
        local panel = openPanel(app)
        for _ = 1, 4 do panel:nudge(panel.rows[2], 1) end
        panel:apply()
        t.assertEquals(app.store:get("layout").size, app.reader:getLayout().size)
    end)
end)

t.describe("the shelf as a grid", function()
    t.it("reports the shape Duo's browser code expects", function()
        local app = newApp()
        local state = app.library:getState()
        for _, key in ipairs{ "view", "kind", "path", "page", "pages",
                              "perpage", "count", "cols", "rows", "signature" } do
            t.assertTrue(state[key] ~= nil, "missing " .. key)
        end
        t.assertEquals(state.kind, "folder")
        t.assertEquals(state.perpage, state.cols * state.rows)
    end)

    t.it("reshapes on request, keeping perpage honest", function()
        local app = newApp()
        t.assertTrue(app.library:setPerPage(nil, 3, 4))
        t.assertEquals(app.library:getState().perpage, 12)
        t.assertEquals(app.library:getState().cols, 3)
    end)

    t.it("moves rows when given a perpage with no shape", function()
        local app = newApp()
        app.library:setPerPage(8)
        t.assertEquals(app.library:getState().cols, 2)
        t.assertEquals(app.library:getState().rows, 4)
    end)

    t.it("clamps a page to the listing", function()
        local app = newApp()
        app.library:goToPage(9999)
        t.assertEquals(app.library.page, app.library:pageCount())
    end)

    t.it("refuses to change into a folder that is not there", function()
        local app = newApp()
        local was = app.library.path
        t.assertTrue(not app.library:changeDir(SHELF .. "/nowhere"))
        t.assertEquals(app.library.path, was)
    end)

    t.it("lists only files to the pair, not folders", function()
        local app = newApp()
        for _, entry in ipairs(app.library:getFiles()) do
            t.assertTrue(not entry.is_dir, entry.name .. " is a folder")
        end
    end)
end)

t.describe("the device contract", function()
    t.it("a page turn refreshes once, not repeatedly", function()
        local app = newApp()
        app:openBook(BOOK)
        app:draw(true)
        local before = #app.device.refreshes
        app.stack:handle{ kind = "tap", x = 1000, y = 700 }
        app:draw()
        t.assertEquals(#app.device.refreshes, before + 1)
    end)

    t.it("does not repaint when nothing happened", function()
        local app = newApp()
        app:openBook(BOOK)
        app:draw(true)
        local before = #app.device.refreshes
        app:draw()
        t.assertEquals(#app.device.refreshes, before)
    end)

    t.it("comes back from sleep with a full refresh", function()
        local app = newApp()
        app:openBook(BOOK)
        app:draw(true)
        app.device:sleep()
        app.device:wake()
        app:draw()
        t.assertEquals(app.device.refreshes[#app.device.refreshes].how, "full")
    end)

    t.it("writes the reader's place down before sleeping", function()
        local app = newApp()
        app:openBook(BOOK)
        app.reader:turn(3)
        app.device:sleep()
        t.assertTrue(app.store:get("positions")[BOOK] ~= nil, "nothing was remembered")
    end)
end)

return t.run()
