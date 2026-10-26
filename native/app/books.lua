--[[--
What is on the card.

A folder scan and a little metadata, kept apart from the view that shows
it because the two-device code asks the same questions for an entirely
different reason: the plugin's shelf syncing wants to know what this
device has so it can work out what the other one is missing, and that has
nothing to do with drawing a grid.

Directory listing goes through `ls` rather than a C library. Not elegant,
but the alternative on a device is LuaJIT FFI against `readdir`, whose
`struct dirent` layout differs by libc and architecture, and getting that
wrong gives garbage filenames rather than an error. `ls` is on every
Kindle, and being slightly slow to list a folder is not a problem a reader
has.

@module duonative.books
--]]--

local Books = {}

--- Formats a reader opens. Anything else is shown but not offered.
Books.READABLE = {
    epub = true, fb2 = true, mobi = true, azw = true, azw3 = true,
    txt = true, html = true, htm = true, pdf = true, cbz = true,
    djvu = true, rtf = true, doc = true,
}

function Books.extension(path)
    return (tostring(path):match("%.([%a%d]+)$") or ""):lower()
end

function Books.isReadable(path)
    return Books.READABLE[Books.extension(path)] == true
end

--- The name to show: the filename without its extension.
function Books.displayName(path)
    local base = tostring(path):match("([^/]+)$") or tostring(path)
    return (base:gsub("%.[%a%d]+$", ""))
end

--[[--
Lists one folder.

Returns directories first, then readable files, each group sorted -- which
is the order every file manager uses and the order a reader expects
without being able to say why. Unreadable files are dropped rather than
shown greyed out: a card with a `.sdr` sidecar folder per book is mostly
noise, and a listing that is mostly noise is worse than one that is
incomplete.

@string path the folder to list
@treturn table array of { path =, name =, is_dir = }
--]]--
function Books.list(path)
    path = tostring(path or "."):gsub("/+$", "")
    if path == "" then path = "/" end
    local dirs, files = {}, {}
    -- -A to skip . and .., -p to mark directories with a trailing slash,
    -- which is how a name is told from a folder without a second stat.
    local pipe = io.popen(("ls -Ap %q 2>/dev/null"):format(path))
    if not pipe then return {} end
    for line in pipe:lines() do
        if line:sub(-1) == "/" then
            local name = line:sub(1, -2)
            if name:sub(1, 1) ~= "." then
                dirs[#dirs+1] = { path = path .. "/" .. name, name = name, is_dir = true }
            end
        elseif Books.isReadable(line) then
            files[#files+1] = {
                path = path .. "/" .. line,
                name = Books.displayName(line),
                is_dir = false,
            }
        end
    end
    pipe:close()
    local function byName(a, b) return a.name:lower() < b.name:lower() end
    table.sort(dirs, byName)
    table.sort(files, byName)
    local out = {}
    for _, entry in ipairs(dirs) do out[#out+1] = entry end
    for _, entry in ipairs(files) do out[#out+1] = entry end
    return out
end

--[[--
A stable summary of a listing, for comparing two devices' shelves.

The same job `Browser.signature` does in the plugin: cheap to compute, and
equal on both devices exactly when they are showing the same thing. Names
and not sizes, because a book copied across arrives byte-identical only if
nothing re-encoded it, and the shelf question is "do we have the same
books" rather than "are they the same files".
--]]--
function Books.signature(entries)
    local parts = {}
    for _, entry in ipairs(entries or {}) do
        parts[#parts+1] = (entry.is_dir and "d:" or "f:") .. entry.name
    end
    return table.concat(parts, "\n")
end

return Books
