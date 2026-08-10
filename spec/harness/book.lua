--[[--
A real book, laid out into pages.

The fake document in the harness normally has a page count and nothing
else, which is enough to test page arithmetic. It is not enough to *see*
whether the arithmetic is right: for that you want real prose on the
screens, so you can read across from one device to the next and watch the
sentence continue.

The layout here is deliberately crude — a fixed number of characters per
line and lines per page — but it has the one property that matters: it is
deterministic. Two devices laying out the same book the same way get the
same pagination, which is exactly the condition Duo asks of two real
readers (same font, same margins), and exactly why it warns when they
differ.

@module spec.harness.book
--]]--

local Book = {}
Book.__index = Book

--- Strips Project Gutenberg's licence header and footer.
local function stripBoilerplate(text)
    local body = text:match("%*%*%* ?START OF TH[EI][^\n]*%*%*%*\r?\n(.*)")
    if body then text = body end
    local trimmed = text:match("(.-)%*%*%* ?END OF TH[EI][^\n]*%*%*%*")
    if trimmed then text = trimmed end
    return text
end

--- Greedy word wrap; returns an array of lines.
local function wrap(paragraph, columns)
    local lines, line = {}, ""
    for word in paragraph:gmatch("%S+") do
        if line == "" then
            line = word
        elseif #line + 1 + #word <= columns then
            line = line .. " " .. word
        else
            lines[#lines+1] = line
            line = word
        end
    end
    if line ~= "" then lines[#lines+1] = line end
    return lines
end

--[[--
Loads a plain-text book and lays it out.

@string path
@tparam[opt] table options columns (default 46), rows (default 24), skip
    (paragraphs of front matter to drop before starting)
@treturn table the book, or nil plus an error message
--]]--
function Book.load(path, options)
    options = options or {}
    local file, err = io.open(path, "r")
    if not file then return nil, err or ("could not open " .. tostring(path)) end
    local text = file:read("*a")
    file:close()

    local columns = options.columns or 46
    local rows = options.rows or 24

    text = text:gsub("\r\n", "\n")
    -- Project Gutenberg puts the real title in the header, above the licence.
    local title = options.title or text:match("\nTitle:%s*([^\n]+)")
    text = stripBoilerplate(text)
    -- Plain-text Gutenberg marks italics with underscores; a reader showing
    -- the EPUB would set them in italics, so they are not shown as marks.
    text = text:gsub("_([^_\n]+)_", "%1")

    -- Blank lines separate paragraphs; a paragraph break becomes a blank
    -- line on the page, which is what makes the pages look like a book.
    -- `.` matches newlines in Lua patterns, so a paragraph may span lines —
    -- which nearly all of them do.
    local lines = {}
    local paragraphs = 0
    for paragraph in (text .. "\n\n"):gmatch("(.-)\n\n+") do
        if paragraph:match("%S") then
            paragraphs = paragraphs + 1
            if paragraphs > (options.skip or 0) then
                local wrapped = wrap(paragraph:gsub("\n", " "), columns)
                for _, line in ipairs(wrapped) do
                    lines[#lines+1] = line
                end
                lines[#lines+1] = ""
            end
        end
    end

    local pages = {}
    for start = 1, #lines, rows do
        local page = {}
        for offset = 0, rows - 1 do
            page[#page+1] = lines[start + offset] or ""
        end
        -- Drop a page that is nothing but blank lines.
        if table.concat(page):match("%S") then
            pages[#pages+1] = page
        end
    end

    return setmetatable({
        path = path,
        title = title or path:match("([^/]+)%.%w+$") or "Book",
        paragraphs = paragraphs,
        columns = columns,
        rows = rows,
        pages = pages,
    }, Book)
end

function Book:getPageCount()
    return #self.pages
end

--- The lines on a page, as an array.
function Book:getPageLines(number)
    return self.pages[number] or {}
end

--- The text of a page, newline separated.
function Book:getPageText(number)
    return table.concat(self:getPageLines(number), "\n")
end

--- The first words of a page, for a log line.
function Book:getPageOpening(number, words)
    local opening = {}
    for word in self:getPageText(number):gmatch("%S+") do
        opening[#opening+1] = word
        if #opening >= (words or 6) then break end
    end
    return table.concat(opening, " ")
end

return Book
