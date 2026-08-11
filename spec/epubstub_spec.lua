--[[--
Stand-ins: the cover and the title of a book, without the book.

The archive layer is KOReader's libarchive binding, which is not here, so
these tests give the module an in-memory one instead. That is the boring
half; the interesting half is reading an OPF, and every EPUB in the world
disagrees about how to name its cover.
--]]--

local T = require("spec/testrunner")
local EpubStub = require("duo/epubstub")

--------------------------------------------------------------------------
-- An archive library that keeps everything in a table
--------------------------------------------------------------------------

local archives = {}   -- path -> { entry path -> content }

local FakeReader = {}
FakeReader.__index = FakeReader
function FakeReader:new() return setmetatable({}, FakeReader) end
function FakeReader:open(path)
    self.entries = archives[path]
    return self.entries ~= nil
end
function FakeReader:iterate()
    -- Only there because the real one has to be walked before it can seek.
    local pending = {}
    for name in pairs(self.entries or {}) do pending[#pending+1] = name end
    local index = 0
    return function()
        index = index + 1
        return pending[index] and { path = pending[index] } or nil
    end
end
function FakeReader:extractToMemory(name) return (self.entries or {})[name] end
function FakeReader:close() self.entries = nil end

local FakeWriter = {}
FakeWriter.__index = FakeWriter
function FakeWriter:new() return setmetatable({}, FakeWriter) end
function FakeWriter:open(path)
    self.path = path
    self.entries = {}
    self.order = {}
    return true
end
function FakeWriter:setZipCompression() return true end
function FakeWriter:addFileFromMemory(name, content)
    self.entries[name] = content
    self.order[#self.order+1] = name
    return true
end
function FakeWriter:close()
    archives[self.path] = self.entries
    archives[self.path .. ":order"] = self.order
end

EpubStub.archiver = { Reader = FakeReader, Writer = FakeWriter }

--- Puts an archive on the fake disk.
local function givenEpub(path, entries)
    archives[path] = entries
    return path
end

local COVER_BYTES = "\137PNG\r\n\26\nnot really a png but it is bytes"

local function opfWith(manifest, meta, title, author)
    return ([[<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>%s</dc:title>
    <dc:creator>%s</dc:creator>
%s  </metadata>
  <manifest>
%s
  </manifest>
</package>]]):format(title or "Moby Dick", author or "Herman Melville", meta or "", manifest)
end

local CONTAINER = [[<?xml version="1.0"?><container>
<rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>]]

--------------------------------------------------------------------------

T.describe("finding the cover an OPF means", function()
    T.it("follows the EPUB 2 way, a meta pointing at a manifest id", function()
        local opf = opfWith(
            '    <item id="c" href="images/front.jpg" media-type="image/jpeg"/>\n'
            .. '    <item id="p" href="p.xhtml" media-type="application/xhtml+xml"/>',
            '    <meta name="cover" content="c"/>\n')
        local href, media = EpubStub.findCover(opf)
        T.assertEquals(href, "images/front.jpg")
        T.assertEquals(media, "image/jpeg")
    end)

    T.it("follows the EPUB 3 way, a properties attribute", function()
        local opf = opfWith(
            '    <item id="x1" href="art/plate.png" media-type="image/png" properties="cover-image"/>\n'
            .. '    <item id="x2" href="art/other.png" media-type="image/png"/>')
        T.assertEquals(EpubStub.findCover(opf), "art/plate.png")
    end)

    T.it("falls back to an image that calls itself a cover", function()
        local opf = opfWith('    <item id="cover-img" href="c.jpg" media-type="image/jpeg"/>')
        T.assertEquals(EpubStub.findCover(opf), "c.jpg")
        local by_name = opfWith('    <item id="i1" href="Cover.jpeg" media-type="image/jpeg"/>')
        T.assertEquals(EpubStub.findCover(by_name), "Cover.jpeg")
    end)

    T.it("prefers the named cover over a lucky filename", function()
        local opf = opfWith(
            '    <item id="c" href="real.jpg" media-type="image/jpeg"/>\n'
            .. '    <item id="cover-decoy" href="cover-of-something-else.jpg" media-type="image/jpeg"/>',
            '    <meta name="cover" content="c"/>\n')
        T.assertEquals(EpubStub.findCover(opf), "real.jpg")
    end)

    T.it("says nothing when there is no image at all", function()
        T.assertNil(EpubStub.findCover(opfWith(
            '    <item id="p" href="p.xhtml" media-type="application/xhtml+xml"/>')))
    end)

    T.it("does not mistake a stylesheet named cover for one", function()
        T.assertNil(EpubStub.findCover(opfWith(
            '    <item id="cover-css" href="cover.css" media-type="text/css"/>')))
    end)
end)

T.describe("reading a book", function()
    T.it("takes the title, the author and the cover", function()
        givenEpub("/books/moby.epub", {
            ["META-INF/container.xml"] = CONTAINER,
            ["OEBPS/content.opf"] = opfWith(
                '    <item id="c" href="cover.png" media-type="image/png"/>',
                '    <meta name="cover" content="c"/>\n'),
            ["OEBPS/cover.png"] = COVER_BYTES,
        })
        local info = assert(EpubStub.describe("/books/moby.epub"))
        T.assertEquals(info.title, "Moby Dick")
        T.assertEquals(info.author, "Herman Melville")
        T.assertEquals(info.cover, COVER_BYTES)
        T.assertEquals(info.media, "image/png")
        T.assertEquals(info.extension, "png")
        T.assertTrue(not info.placeholder, "a real book is not a stand-in")
    end)

    T.it("resolves the cover against the package document's own folder", function()
        givenEpub("/books/nested.epub", {
            ["META-INF/container.xml"] =
                [[<container><rootfiles><rootfile full-path="content/book.opf"/></rootfiles></container>]],
            ["content/book.opf"] = opfWith(
                '    <item id="c" href="../images/cover.jpg" media-type="image/jpeg"/>',
                '    <meta name="cover" content="c"/>\n'),
            ["images/cover.jpg"] = COVER_BYTES,
        })
        local info = assert(EpubStub.describe("/books/nested.epub"))
        T.assertEquals(info.cover, COVER_BYTES, "a ../ href was not followed")
    end)

    T.it("unescapes what XML escaped", function()
        givenEpub("/books/amp.epub", {
            ["META-INF/container.xml"] = CONTAINER,
            ["OEBPS/content.opf"] = opfWith("", nil, "Sense &amp; Sensibility", "Jane Austen"),
        })
        T.assertEquals(EpubStub.describe("/books/amp.epub").title, "Sense & Sensibility")
    end)

    T.it("falls back to the file name when there is no title", function()
        givenEpub("/books/Some Book.epub", {
            ["META-INF/container.xml"] = CONTAINER,
            ["OEBPS/content.opf"] = [[<package><metadata></metadata><manifest></manifest></package>]],
        })
        T.assertEquals(EpubStub.describe("/books/Some Book.epub").title, "Some Book")
    end)

    T.it("refuses something that is not an EPUB", function()
        givenEpub("/books/notepub.zip", { ["hello.txt"] = "hi" })
        T.assertNil(EpubStub.describe("/books/notepub.zip"))
        T.assertNil(EpubStub.describe("/books/nothing-here.epub"))
    end)
end)

T.describe("building a stand-in", function()
    local function buildFrom(source)
        local info = assert(EpubStub.describe(source))
        assert(EpubStub.build("/out/stub.epub", info))
        return "/out/stub.epub"
    end

    T.it("carries the cover and the title straight through", function()
        givenEpub("/books/moby2.epub", {
            ["META-INF/container.xml"] = CONTAINER,
            ["OEBPS/content.opf"] = opfWith(
                '    <item id="c" href="cover.png" media-type="image/png"/>',
                '    <meta name="cover" content="c"/>\n'),
            ["OEBPS/cover.png"] = COVER_BYTES,
        })
        local stub = buildFrom("/books/moby2.epub")
        local info = assert(EpubStub.describe(stub))
        T.assertEquals(info.title, "Moby Dick")
        T.assertEquals(info.author, "Herman Melville")
        T.assertEquals(info.cover, COVER_BYTES, "the cover did not survive")
    end)

    T.it("marks itself, so it can be told from a book afterwards", function()
        givenEpub("/books/moby3.epub", {
            ["META-INF/container.xml"] = CONTAINER,
            ["OEBPS/content.opf"] = opfWith('    <item id="p" href="p.xhtml" media-type="application/xhtml+xml"/>'),
        })
        local stub = buildFrom("/books/moby3.epub")
        T.assertTrue(EpubStub.isPlaceholder(stub), "a stand-in should own up to being one")
        T.assertTrue(not EpubStub.isPlaceholder("/books/moby3.epub"),
            "a real book should not look like a stand-in")
    end)

    T.it("opens with an uncompressed mimetype, as an EPUB must", function()
        givenEpub("/books/moby4.epub", {
            ["META-INF/container.xml"] = CONTAINER,
            ["OEBPS/content.opf"] = opfWith('    <item id="p" href="p.xhtml" media-type="application/xhtml+xml"/>'),
        })
        local stub = buildFrom("/books/moby4.epub")
        T.assertEquals(archives[stub .. ":order"][1], "mimetype")
        T.assertEquals(archives[stub]["mimetype"], "application/epub+zip")
    end)

    T.it("still builds one for a book with no cover", function()
        givenEpub("/books/plain.epub", {
            ["META-INF/container.xml"] = CONTAINER,
            ["OEBPS/content.opf"] = opfWith("", nil, "No Pictures", "Nobody"),
        })
        local stub = buildFrom("/books/plain.epub")
        local info = assert(EpubStub.describe(stub))
        T.assertEquals(info.title, "No Pictures")
        T.assertNil(info.cover)
        T.assertTrue(info.placeholder)
    end)

    T.it("keeps a title with XML in it from breaking the package document", function()
        givenEpub("/books/tricky.epub", {
            ["META-INF/container.xml"] = CONTAINER,
            ["OEBPS/content.opf"] = opfWith("", nil, "A &lt;Tag&gt; &amp; A &quot;Quote&quot;", "X"),
        })
        local stub = buildFrom("/books/tricky.epub")
        T.assertEquals(EpubStub.describe(stub).title, 'A <Tag> & A "Quote"')
    end)
end)

os.exit(T.run())
