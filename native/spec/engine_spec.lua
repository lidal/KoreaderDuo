local t = require("spec/testrunner")
local Api = require("app/engine/api")
local Stub = require("app/engine/stub")
local Fixture = require("spec/fixture")

local BOOK = Fixture.book("engine")

t.describe("the engine contract", function()
    t.it("is satisfied by the stub", function()
        local doc = assert(Stub.open(BOOK))
        local ok, missing = Api.check(doc)
        t.assertTrue(ok, "missing: " .. tostring(missing))
    end)

    t.it("fills in a partial layout rather than leaving holes", function()
        local layout = Api.layout{ size = 30 }
        t.assertEquals(layout.size, 30)
        t.assertEquals(layout.face, Api.DEFAULT_LAYOUT.face)
    end)

    t.it("hands out a fresh layout table each time", function()
        local one = Api.layout()
        one.size = 99
        t.assertEquals(Api.layout().size, Api.DEFAULT_LAYOUT.size)
    end)

    t.it("ignores keys that are not layout settings", function()
        local layout = Api.layout{ nonsense = true }
        t.assertNil(layout.nonsense)
    end)
end)

t.describe("pagination", function()
    t.it("produces more than one page from a real book", function()
        local doc = assert(Stub.open(BOOK))
        t.assertTrue(doc:pageCount() > 3, "got " .. doc:pageCount())
    end)

    t.it("gets longer when the font gets bigger", function()
        local small = assert(Stub.open(BOOK, { layout = { size = 18 } }))
        local large = assert(Stub.open(BOOK, { layout = { size = 36 } }))
        t.assertTrue(large:pageCount() > small:pageCount(),
            ("%d should exceed %d"):format(large:pageCount(), small:pageCount()))
    end)

    t.it("gets longer when the margins grow", function()
        local narrow = assert(Stub.open(BOOK, { layout = { margin_left = 10, margin_right = 10 } }))
        local wide = assert(Stub.open(BOOK, { layout = { margin_left = 200, margin_right = 200 } }))
        t.assertTrue(wide:pageCount() > narrow:pageCount(),
            ("%d should exceed %d"):format(wide:pageCount(), narrow:pageCount()))
    end)

    t.it("clamps a page turn to the book", function()
        local doc = assert(Stub.open(BOOK))
        t.assertEquals(doc:gotoPage(0), 1)
        t.assertEquals(doc:gotoPage(99999), doc:pageCount())
    end)

    t.it("finds the chapters", function()
        local doc = assert(Stub.open(BOOK))
        local toc = doc:toc()
        t.assertTrue(#toc >= 2, "got " .. #toc .. " entries")
        t.assertMatch(toc[1].title, "Chapter")
    end)
end)

t.describe("determinism, which the two-device design rests on", function()
    t.it("two engines on the same book and layout agree exactly", function()
        local one = assert(Stub.open(BOOK, { layout = { size = 24, margin_left = 55 } }))
        local two = assert(Stub.open(BOOK, { layout = { size = 24, margin_left = 55 } }))
        t.assertEquals(two:fingerprint(), one:fingerprint())
        t.assertEquals(two:pageCount(), one:pageCount())
    end)

    t.it("and disagree, visibly, when a single setting differs", function()
        local one = assert(Stub.open(BOOK, { layout = { size = 24 } }))
        local two = assert(Stub.open(BOOK, { layout = { size = 25 } }))
        t.assertNotEquals(two:fingerprint(), one:fingerprint())
    end)

    t.it("says what differs, not merely that something did", function()
        local doc = assert(Stub.open(BOOK, { layout = { size = 24 } }))
        t.assertMatch(doc:fingerprint(), "size=24")
        t.assertMatch(doc:fingerprint(), "pages=%d+")
    end)

    t.it("is independent of the order settings were given in", function()
        local one = assert(Stub.open(BOOK, { layout = { size = 24, margin_top = 11 } }))
        local two = assert(Stub.open(BOOK, { layout = { margin_top = 11, size = 24 } }))
        t.assertEquals(two:fingerprint(), one:fingerprint())
    end)
end)

t.describe("a position outlives a relayout", function()
    --[[
    The contract is page granularity, not exactness. A reflow moves every
    break, so the words that were at the top of the screen are now
    somewhere in the middle of a page and no page begins with them. What
    must hold is that they are still *on screen*.
    ]]
    t.it("keeps the reader looking at the same words when the font changes", function()
        local doc = assert(Stub.open(BOOK, { layout = { size = 20 } }))
        doc:gotoPage(4)
        local remembered = doc:pageLines()[1].text
        local pages_before = doc:pageCount()

        t.assertTrue(doc:applyLayout{ size = 32 }, "should have reflowed")
        t.assertNotEquals(doc:pageCount(), pages_before)

        local still_here = false
        for _, line in ipairs(doc:pageLines()) do
            if line.text:find(remembered:sub(1, 30), 1, true) then still_here = true end
        end
        t.assertTrue(still_here,
            ("lost the reader's place: %q is not on page %d")
                :format(remembered:sub(1, 30), doc:page()))
    end)

    t.it("leaves the remembered position on the page it landed on", function()
        local doc = assert(Stub.open(BOOK, { layout = { size = 20 } }))
        doc:gotoPage(5)
        local before = doc:position()
        doc:applyLayout{ size = 21 }
        t.assertEquals(doc:pageOf(before), doc:page())
    end)

    t.it("holds across a large relayout too", function()
        local doc = assert(Stub.open(BOOK, { layout = { size = 18, margin_left = 20 } }))
        doc:gotoPage(6)
        local before = doc:position()
        doc:applyLayout{ size = 40, margin_left = 180 }
        t.assertEquals(doc:pageOf(before), doc:page())
    end)

    t.it("reports no reflow when nothing actually changed", function()
        local doc = assert(Stub.open(BOOK, { layout = { size = 20 } }))
        t.assertTrue(not doc:applyLayout{ size = 20 }, "should be a no-op")
    end)

    t.it("survives a round trip through gotoPosition", function()
        local doc = assert(Stub.open(BOOK))
        doc:gotoPage(3)
        local position = doc:position()
        doc:gotoPage(1)
        doc:gotoPosition(position)
        t.assertEquals(doc:position(), position)
    end)
end)

return t.run()
