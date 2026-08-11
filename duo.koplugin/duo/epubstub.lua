--[[--
A stand-in for a book: its cover and its name, and nothing else.

The point is to let a device show a book it does not have. A folder listing
comes from the filesystem, so a book nobody has copied yet simply is not
there — no row, no cover, and the two halves of a shared list drift apart
by however many books are missing. Copying whole libraries fixes that at
the cost of moving every byte before anything can be read.

A stub is the middle. It is a real EPUB, valid enough for KOReader to read
a cover and a title out of, and small enough to be worth sending
immediately: everything except the book. The shelf fills up at once, and
the bytes arrive when somebody actually opens something.

Only EPUB is handled. A stub has to carry the name of the book it stands in
for — otherwise the listings do not line up, which is the whole point — so
it also has to be the same format, and there is no such thing as a PDF
holding no pages. Anything else is copied whole instead.

@module duo.epubstub
--]]--

local EpubStub = {}

--- The marker that says a book is only a stand-in. It goes in the OPF as
--- the identifier, so a stub can be recognised again from the file alone.
EpubStub.MARKER = "urn:duo:placeholder"

--- Injected by the tests, which have no libarchive to talk to.
EpubStub.archiver = nil

local function archiver()
    if EpubStub.archiver then return EpubStub.archiver end
    local ok, module = pcall(require, "ffi/archiver")
    if not ok then return nil, "no archive library on this device" end
    return module
end

--- Everything before the last slash, or "" — the OPF's own folder, which
--- is what the hrefs inside it are relative to.
local function directoryOf(path)
    return path:match("^(.*)/[^/]*$") or ""
end

local function resolve(base, href)
    -- Only the shapes an OPF actually uses; a full URL resolver would be
    -- more than this needs.
    href = href:gsub("^%./", "")
    if href:sub(1, 1) == "/" then return href:sub(2) end
    while href:sub(1, 3) == "../" do
        href = href:sub(4)
        base = directoryOf(base)
    end
    if base == "" then return href end
    return base .. "/" .. href
end

--- Strips XML entities and tags from a metadata value.
local function plainText(text)
    if not text then return nil end
    text = text:gsub("<[^>]*>", "")
    text = text:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
    text = text:gsub("&apos;", "'"):gsub("&#39;", "'"):gsub("&amp;", "&")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil end
    return text
end

--- Reads a `<dc:x>` element, with or without its namespace prefix.
local function dublinCore(opf, name)
    local value = opf:match("<dc:" .. name .. "[^>]*>(.-)</dc:" .. name .. ">")
        or opf:match("<" .. name .. "[^>]*>(.-)</" .. name .. ">")
    return plainText(value)
end

--[[--
Finds the cover image named by an OPF.

Three ways of saying it, in the order they should be trusted: EPUB 2's
`<meta name="cover">` pointing at a manifest id, EPUB 3's `cover-image`
property, and failing both, an image in the manifest whose id or href says
"cover".

@treturn string the href, and its media type
--]]--
function EpubStub.findCover(opf)
    local cover_id = opf:match('<meta[^>]-name="cover"[^>]-content="([^"]+)"')
        or opf:match('<meta[^>]-content="([^"]+)"[^>]-name="cover"')
    for item in opf:gmatch("<item[^>]->") do
        local id = item:match('id="([^"]*)"')
        local href = item:match('href="([^"]*)"')
        local media = item:match('media%-type="([^"]*)"') or ""
        if href and media:match("^image/") then
            if cover_id and id == cover_id then return href, media end
        end
    end
    for item in opf:gmatch("<item[^>]->") do
        local href = item:match('href="([^"]*)"')
        local media = item:match('media%-type="([^"]*)"') or ""
        local properties = item:match('properties="([^"]*)"') or ""
        if href and media:match("^image/") and properties:match("cover%-image") then
            return href, media
        end
    end
    for item in opf:gmatch("<item[^>]->") do
        local id = item:match('id="([^"]*)"') or ""
        local href = item:match('href="([^"]*)"')
        local media = item:match('media%-type="([^"]*)"') or ""
        if href and media:match("^image/")
                and (id:lower():match("cover") or href:lower():match("cover")) then
            return href, media
        end
    end
    return nil
end

--[[--
Reads what a stub needs out of a real EPUB.

@string path  the book
@treturn table { title=, author=, cover=, media= }, or nil plus a reason
--]]--
function EpubStub.describe(path)
    local Archiver, err = archiver()
    if not Archiver then return nil, err end

    local reader = Archiver.Reader:new()
    if not reader:open(path) then return nil, "not readable as an archive" end
    -- The entry list is only filled in by walking it once.
    for _ in reader:iterate() do end

    local container = reader:extractToMemory("META-INF/container.xml")
    if not container then
        reader:close()
        return nil, "no container.xml, so not an EPUB"
    end
    local opf_path = container:match('full%-path="([^"]+)"')
    if not opf_path then
        reader:close()
        return nil, "no package document named"
    end
    local opf = reader:extractToMemory(opf_path)
    if not opf then
        reader:close()
        return nil, "the package document is missing"
    end

    local info = {
        title = dublinCore(opf, "title") or path:gsub("^.*/", ""):gsub("%.epub$", ""),
        author = dublinCore(opf, "creator") or "",
        placeholder = opf:find(EpubStub.MARKER, 1, true) ~= nil,
    }
    local href, media = EpubStub.findCover(opf)
    if href then
        info.cover = reader:extractToMemory(resolve(directoryOf(opf_path), href))
        info.media = media
        info.extension = href:match("%.([^.]+)$") or "jpg"
    end
    reader:close()
    return info
end

local CONTAINER = [[<?xml version="1.0" encoding="utf-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>]]

local function escapeXml(text)
    return (tostring(text or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
        :gsub('"', "&quot;"))
end

--[[--
Writes a stub EPUB.

@string out_path  where to write it
@tparam table info  as returned by `describe`
@treturn boolean true, or nil plus a reason
--]]--
function EpubStub.build(out_path, info)
    local Archiver, err = archiver()
    if not Archiver then return nil, err end

    local title = escapeXml(info.title or "Untitled")
    local author = escapeXml(info.author or "")
    local extension = info.extension or "jpg"
    local media = info.media or "image/jpeg"

    local manifest = {
        '    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
        '    <item id="page" href="page.xhtml" media-type="application/xhtml+xml"/>',
    }
    local cover_meta = ""
    if info.cover then
        table.insert(manifest, 1, ('    <item id="cover-image" href="cover.%s" media-type="%s" properties="cover-image"/>')
            :format(extension, media))
        cover_meta = '    <meta name="cover" content="cover-image"/>\n'
    end

    local opf = ([[<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="duo-id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:title>%s</dc:title>
    <dc:creator opf:role="aut">%s</dc:creator>
    <dc:language>en</dc:language>
    <dc:identifier id="duo-id">%s</dc:identifier>
%s  </metadata>
  <manifest>
%s
  </manifest>
  <spine toc="ncx"><itemref idref="page"/></spine>
</package>]]):format(title, author, EpubStub.MARKER, cover_meta, table.concat(manifest, "\n"))

    local page = ([[<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>%s</title></head>
<body><h1>%s</h1>
<p>This book is on the other device. Duo will fetch it when you open it.</p>
</body></html>]]):format(title, title)

    local ncx = ([[<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="%s"/></head>
  <docTitle><text>%s</text></docTitle>
  <navMap><navPoint id="p1" playOrder="1"><navLabel><text>%s</text></navLabel>
  <content src="page.xhtml"/></navPoint></navMap>
</ncx>]]):format(EpubStub.MARKER, title, title)

    local writer = Archiver.Writer:new()
    if not writer:open(out_path, "zip") then
        return nil, "could not write " .. out_path
    end
    -- An EPUB must open with an uncompressed `mimetype` entry.
    writer:setZipCompression("store")
    local ok = writer:addFileFromMemory("mimetype", "application/epub+zip")
    writer:setZipCompression("deflate")
    ok = ok and writer:addFileFromMemory("META-INF/container.xml", CONTAINER)
    ok = ok and writer:addFileFromMemory("OEBPS/content.opf", opf)
    ok = ok and writer:addFileFromMemory("OEBPS/toc.ncx", ncx)
    ok = ok and writer:addFileFromMemory("OEBPS/page.xhtml", page)
    if ok and info.cover then
        -- Already a compressed image; deflating it again only costs time.
        writer:setZipCompression("store")
        ok = writer:addFileFromMemory("OEBPS/cover." .. extension, info.cover)
    end
    writer:close()
    if not ok then
        os.remove(out_path)
        return nil, "could not fill " .. out_path
    end
    return true
end

--- Real book in, stub out.
-- @treturn boolean true, or nil plus a reason
function EpubStub.make(source_path, out_path)
    local info, err = EpubStub.describe(source_path)
    if not info then return nil, err end
    return EpubStub.build(out_path, info)
end

--- Whether a file is one of ours, asked of the file itself.
function EpubStub.isPlaceholder(path)
    local info = EpubStub.describe(path)
    return info ~= nil and info.placeholder == true
end

return EpubStub
