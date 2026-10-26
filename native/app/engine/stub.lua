--[[--
A paginator that is not a renderer.

**This is a test double.** It wraps words at a measured width, breaks the
wrapped lines into pages, and answers questions about where it put things.
It has no CSS, no font shaping, no hyphenation dictionary and no idea what
an EPUB's own stylesheet wanted. CREngine does all of that and this does
none of it; see `engine/cre.lua`.

It is here for three jobs that do not need a real engine and would
otherwise need a Kindle:

1. Driving the reader view -- a page of lines is a page of lines.
2. Making relayout *real*. Change the margins or the font size and the
   pagination genuinely moves, so the code that copes with a book getting
   longer under its feet is actually exercised.
3. Proving determinism. Two of these, given the same text and the same
   layout, must agree on every page break. That is the property the whole
   two-device design rests on, and it can be tested here for free.

The metrics are deliberately crude and deliberately exact: width is
`size * 0.5` per character, line height is `size * 1.2 * line_spacing`.
Crude because precision would be a lie at this layer; exact because a
fingerprint has to be reproducible to be worth anything, and floating
point that varies by platform would make it not.

Input is plain text. A line beginning `# ` is a chapter heading and goes
into the table of contents; blank lines separate paragraphs.

@module duonative.engine.stub
--]]--

local Api = require("app/engine/api")

local Stub = {}

local Doc = {}
Doc.__index = Doc

--[[--
Integer metrics, on purpose.

`math.floor` rather than leaving the division as it falls, because these
numbers end up in a fingerprint that two devices compare for equality.
Two LuaJIT builds agreeing on a float to the last bit is something to not
depend on when rounding costs nothing.
--]]--
local function charWidth(size) return math.floor(size * 0.5) end
local function lineHeight(size, spacing)
    return math.floor(size * 1.2 * (spacing or 100) / 100)
end

--- Splits the source into paragraphs, noting which ones are headings.
local function parse(text)
    local paragraphs = {}
    local buffer = {}
    local function flush()
        if #buffer == 0 then return end
        local joined = table.concat(buffer, " ")
        paragraphs[#paragraphs+1] = { text = joined, heading = false }
        buffer = {}
    end
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local heading = line:match("^#%s+(.*)$")
        if heading then
            flush()
            paragraphs[#paragraphs+1] = { text = heading, heading = true }
        elseif line:match("^%s*$") then
            flush()
        else
            buffer[#buffer+1] = (line:gsub("^%s+", ""):gsub("%s+$", ""))
        end
    end
    flush()
    return paragraphs
end

--[[--
Wraps one paragraph to `columns` characters.

Greedy, which is what every reflowable engine on a reader does -- Knuth's
line breaker is for print. A word longer than the column is left to
overflow rather than broken, because breaking it would need the
hyphenation this double does not have, and pretending otherwise would make
the double disagree with the real engine in a way that flatters it.
--]]--
local function wrap(paragraph, columns)
    if columns < 1 then columns = 1 end
    local lines = {}
    local current = nil
    for word in paragraph:gmatch("%S+") do
        if current == nil then
            current = word
        elseif #current + 1 + #word <= columns then
            current = current .. " " .. word
        else
            lines[#lines+1] = current
            current = word
        end
    end
    if current then lines[#lines+1] = current end
    if #lines == 0 then lines[1] = "" end
    return lines
end

--[[--
Lays the whole book out and records where every line came from.

Each laid-out line keeps the paragraph and word index it started at, which
is what makes `position()` survive a relayout: the position is a place in
the text, and after a reflow the same place is simply on a different page.
--]]--
function Doc:relayout()
    local layout = self.current_layout
    local content_w = self.width - layout.margin_left - layout.margin_right
    local content_h = self.height - layout.margin_top - layout.margin_bottom
    local columns = math.floor(content_w / charWidth(layout.size))
    local line_h = lineHeight(layout.size, layout.line_spacing)
    local per_page = math.max(math.floor(content_h / line_h), 1)

    local lines = {}
    for index, paragraph in ipairs(self.paragraphs) do
        local words_before = 0
        for _, text in ipairs(wrap(paragraph.text, columns)) do
            lines[#lines+1] = {
                text = text,
                paragraph = index,
                word = words_before,
                heading = paragraph.heading,
            }
            local count = 0
            for _ in text:gmatch("%S+") do count = count + 1 end
            words_before = words_before + count
        end
        -- A blank line after a paragraph, which is what makes margins and
        -- spacing visibly change the page count rather than only the
        -- line count.
        if index < #self.paragraphs and not paragraph.heading then
            lines[#lines+1] = { text = "", paragraph = index, word = words_before }
        end
    end

    self.lines = lines
    self.per_page = per_page
    self.line_h = line_h
    self.columns = columns
    self.pages = math.max(math.ceil(#lines / per_page), 1)
    if self.current_page > self.pages then self.current_page = self.pages end
end

function Stub.open(path, options)
    options = options or {}
    local handle, err = io.open(path, "r")
    if not handle then return nil, ("cannot open %s: %s"):format(path, tostring(err)) end
    local text = handle:read("*a")
    handle:close()

    local doc = setmetatable({
        path = path,
        paragraphs = parse(text),
        width = options.width or 1072,
        height = options.height or 1448,
        current_layout = Api.layout(options.layout),
        current_page = 1,
        byte_size = #text,
    }, Doc)
    doc:relayout()
    return doc
end

function Doc:close() self.closed = true end

--[[--
Title and author.

Taken from the first heading and the filename, since plain text carries no
metadata. The real backend reads the EPUB's OPF instead; what matters here
is that the shape of the answer is the same.
--]]--
function Doc:props()
    local title
    for _, paragraph in ipairs(self.paragraphs) do
        if paragraph.heading then title = paragraph.text break end
    end
    return {
        title = title or (self.path:match("([^/]+)%.%w+$") or self.path),
        author = nil,
        language = "en",
    }
end

--- No covers in plain text; a handle the fake surface can record all the same.
function Doc:cover(width, height)
    return { kind = "stub-cover", path = self.path, w = width, h = height }
end

function Doc:applyLayout(layout)
    local wanted = Api.layout(layout)
    if Api.sameLayout(wanted, self.current_layout) then return false end
    local position = self:position()
    self.current_layout = wanted
    self:relayout()
    --[[
    Back to where the reader was, which is the whole point of positions
    outliving page numbers.

    To the page *containing* those words, not to a page starting with
    them -- a reflow moves every break, so the words that were at the top
    of the screen are generally now in the middle of a page, and there is
    no page that begins with them to go to. So `position()` round-trips
    only to page granularity, and that is the contract: what was on screen
    is still on screen. Promising more would mean repaginating from the
    reader's position outwards, which is a different and much stranger
    book.
    ]]
    self:gotoPosition(position)
    return true
end

function Doc:getLayout()
    local out = {}
    for key, value in pairs(self.current_layout) do out[key] = value end
    return out
end

function Doc:pageCount() return self.pages end
function Doc:page() return self.current_page end

function Doc:gotoPage(page)
    page = math.max(1, math.min(math.floor(page or 1), self.pages))
    self.current_page = page
    return page
end

--- The laid-out lines on a page, which is what the reader view draws.
function Doc:pageLines(page)
    page = page or self.current_page
    local first = (page - 1) * self.per_page + 1
    local out = {}
    for index = first, math.min(first + self.per_page - 1, #self.lines) do
        out[#out+1] = self.lines[index]
    end
    return out
end

function Doc:render(surface, rect)
    local layout = self.current_layout
    local x = rect.x + layout.margin_left
    local y = rect.y + layout.margin_top
    for _, line in ipairs(self:pageLines()) do
        if line.text ~= "" then
            surface:text(x, y, line.text, {
                size = layout.size,
                face = layout.face,
                bold = line.heading or false,
            })
        end
        y = y + self.line_h
    end
end

function Doc:toc()
    local out = {}
    for index, line in ipairs(self.lines) do
        if line.heading then
            out[#out+1] = {
                title = line.text,
                page = math.floor((index - 1) / self.per_page) + 1,
            }
        end
    end
    return out
end

--[[--
Where the reader is, as a place in the text rather than a page.

`p<paragraph>w<word>`, which is this double's answer to CREngine's
XPointer. The contract that matters is the one both share: hand it back to
`gotoPosition` after any relayout and the same words are on screen.
--]]--
function Doc:position()
    local lines = self:pageLines()
    local first = lines[1]
    if not first then return "p1w0" end
    return ("p%dw%d"):format(first.paragraph, first.word)
end

--[[--
Which page a position is on, without going there.

Separate from `gotoPosition` because it is the question a *test* asks --
"is the reader's place still on screen?" -- and because the two-device code
will want it too: a follower told to show the page holding a position needs
to know which page that is before it moves.
--]]--
function Doc:pageOf(position)
    local paragraph, word = tostring(position or ""):match("^p(%d+)w(%d+)$")
    if not paragraph then return nil end
    paragraph, word = tonumber(paragraph), tonumber(word)
    for index, line in ipairs(self.lines) do
        if line.paragraph > paragraph
            or (line.paragraph == paragraph and line.word >= word) then
            return math.floor((index - 1) / self.per_page) + 1
        end
    end
    return self.pages
end

function Doc:gotoPosition(position)
    local page = self:pageOf(position)
    if not page then return self.current_page end
    return self:gotoPage(page)
end

--[[--
A string two devices compare to prove they paginated alike.

Document identity, the layout, and the shape of the result. Not a hash:
when two devices disagree this is the thing somebody has to read to find
out why, and `pages=310` against `pages=311` says it immediately where two
differing hashes say nothing at all.
--]]--
function Doc:fingerprint()
    return ("bytes=%d %s cols=%d perpage=%d lines=%d pages=%d"):format(
        self.byte_size, Api.describeLayout(self.current_layout),
        self.columns, self.per_page, #self.lines, self.pages)
end

return Stub
