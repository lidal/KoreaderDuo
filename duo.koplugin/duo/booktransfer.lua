--[[--
Sending the book itself.

"Follow the leader's book" is only useful if the other device has the book.
When it does not, the file goes down the same link the page numbers do,
which means a follower can be handed a book it has never seen and be reading
the right page of it a moment later.

Reading and writing happen a chunk at a time, driven from the poll loop, so
a 4 MB EPUB never blocks the reader. The sender stops pushing when the
transport's outgoing buffer fills, which is what keeps a slow serial link
from swallowing memory.

@module duo.booktransfer
--]]--

local Base64 = require("duo/base64")

local BookTransfer = {}

--- Bytes per message. Encoded this is 3840 characters, comfortably inside
--- the protocol's line limit.
BookTransfer.CHUNK = 2880

--- Stop pushing when this much is already queued on the transport.
BookTransfer.HIGH_WATER = 48 * 1024

--[[--
How many chunks one turn of the poll loop may send.

The high-water mark alone is not a limit. It counts the bytes still waiting
for the socket, and on a link that keeps up that number is nearly always
zero -- the kernel takes everything offered. So "send until the link is
backed up" meant "send the whole book", in one turn of the loop, with no
repaint and no chance to touch anything in between: the reader froze for as
long as the book took, and the way out of a transfer became unreachable at
exactly the size that makes somebody want it.

This is the ceiling that makes the pump yield. Set well above what any
reader's Wi-Fi will carry in a fiftieth of a second, so it costs nothing on
a link that is going slowly and everything on one that is not.
--]]--
BookTransfer.CHUNKS_PER_POLL = 48

--[[--
What counts as a book, and so as something worth copying between devices.

An allowlist rather than a filter on what to leave out. The file browser
already hides what KOReader cannot open, but "already hides" is a setting
somebody can turn off, and the folder being shared is whichever one the
leader happens to be looking at: point it at a downloads folder by mistake
and a device that copies whatever it is shown will copy all of it, slowly,
over a link with no router on it. The cost of an extension missing from
this list is one book that has to be copied by hand; the cost of not having
the list at all is a folder of firmware images crossing an ad-hoc cell.

Formats are KOReader's own, from `DocumentRegistry`'s providers.
--]]--
BookTransfer.BOOK_EXTENSIONS = {
    -- crengine
    epub = true, fb2 = true, fbz = true, mobi = true, azw = true,
    azw3 = true, prc = true, pdb = true, chm = true, htm = true,
    html = true, xhtml = true, rtf = true, doc = true, docx = true,
    odt = true, md = true, markdown = true, txt = true, tcr = true,
    zip = true, opf = true,
    -- mupdf and djvu
    pdf = true, xps = true, cbz = true, cbt = true, cbr = true,
    djvu = true, djv = true,
}

--[[--
True when a name looks like something a reader would open.

@tparam string name  a bare file name
--]]--
function BookTransfer.isBookName(name)
    local extension = tostring(name or ""):match("%.([%a%d]+)$")
    if not extension then return false end
    return BookTransfer.BOOK_EXTENSIONS[extension:lower()] == true
end

--- Strips any directory part, so a peer cannot choose where a file lands.
function BookTransfer.safeName(name)
    name = tostring(name or ""):gsub("^.*[/\\]", "")
    name = name:gsub("%c", "")
    if name == "" or name == "." or name == ".." then
        return nil
    end
    return name
end

--------------------------------------------------------------------------
-- Sender
--------------------------------------------------------------------------

local Sender = {}
Sender.__index = Sender

--- Opens a file for sending.
-- @treturn table a Sender, or nil plus an error message
function BookTransfer.newSender(path, options)
    options = options or {}
    local file, err = io.open(path, "rb")
    if not file then
        return nil, err or ("cannot read " .. tostring(path))
    end
    local size = file:seek("end")
    file:seek("set")
    return setmetatable({
        file = file,
        path = path,
        size = size,
        sent = 0,
        chunk_size = options.chunk_size or BookTransfer.CHUNK,
        done = false,
    }, Sender)
end

--- The next chunk, already encoded, or nil at the end of the file.
function Sender:next()
    if self.done or not self.file then return nil end
    local data = self.file:read(self.chunk_size)
    if not data or #data == 0 then
        self.done = true
        return nil
    end
    self.sent = self.sent + #data
    return Base64.encodeUrl(data)
end

function Sender:progress()
    if not self.size or self.size == 0 then return 1 end
    return self.sent / self.size
end

function Sender:close()
    if self.file then
        self.file:close()
        self.file = nil
    end
    self.done = true
end

--------------------------------------------------------------------------
-- Receiver
--------------------------------------------------------------------------

local Receiver = {}
Receiver.__index = Receiver

--[[--
Opens somewhere to put an incoming book.

Written to a part-file first and only moved into place once the whole thing
has arrived, so an interrupted transfer never leaves something that looks
like a readable book.

@tparam table options directory, name, size
--]]--
function BookTransfer.newReceiver(options)
    local name = BookTransfer.safeName(options.name)
    if not name then
        return nil, "that is not a file name"
    end
    -- No ceiling on the size. A big book is a long wait, which is worth
    -- saying and worth being able to stop, and neither of those is a
    -- refusal -- least of all one delivered after the reader has already
    -- tapped the book and been told it is on its way.
    local size = tonumber(options.size) or 0

    local directory = options.directory or "."
    os.execute(("mkdir -p %q 2>/dev/null"):format(directory))
    local final_path = directory .. "/" .. name
    local part_path = final_path .. ".duopart"

    local file, err = io.open(part_path, "wb")
    if not file then
        return nil, err or ("cannot write to " .. directory)
    end

    return setmetatable({
        file = file,
        name = name,
        directory = directory,
        final_path = final_path,
        part_path = part_path,
        size = size,
        received = 0,
    }, Receiver)
end

--- Writes one encoded chunk.
-- @treturn boolean true, or false plus an error message
function Receiver:write(encoded)
    if not self.file then return false, "transfer already finished" end
    local data, err = Base64.decodeUrl(encoded)
    if not data then return false, err end
    if self.size > 0 and self.received + #data > self.size then
        return false, "the sender is sending more than it promised"
    end
    self.file:write(data)
    self.received = self.received + #data
    return true
end

function Receiver:progress()
    if not self.size or self.size == 0 then return 0 end
    return self.received / self.size
end

--- Moves the finished file into place.
-- @treturn string the path, or nil plus an error message
function Receiver:finish()
    if not self.file then return nil, "transfer already finished" end
    self.file:close()
    self.file = nil
    if self.size > 0 and self.received ~= self.size then
        os.remove(self.part_path)
        return nil, ("the book arrived incomplete (%d of %d bytes)"):format(self.received, self.size)
    end
    os.remove(self.final_path)
    local ok, err = os.rename(self.part_path, self.final_path)
    if not ok then
        os.remove(self.part_path)
        return nil, err or "could not put the book in place"
    end
    return self.final_path
end

function Receiver:abort()
    if self.file then
        self.file:close()
        self.file = nil
    end
    os.remove(self.part_path)
end

return BookTransfer
