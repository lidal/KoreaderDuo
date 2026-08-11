--[[--
Sending the book itself down the link.
--]]--

local T = require("spec/testrunner")
local Base64 = require("duo/base64")
local BookTransfer = require("duo/booktransfer")

local TMP = (os.getenv("DUO_LOG_DIR") or "/tmp") .. "/duo-transfer-spec"
os.execute("rm -rf " .. TMP .. " && mkdir -p " .. TMP)

local function writeFile(path, contents)
    local file = assert(io.open(path, "wb"))
    file:write(contents)
    file:close()
    return path
end

local function readFile(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local contents = file:read("*a")
    file:close()
    return contents
end

T.describe("base64", function()
    T.it("matches the published vectors", function()
        T.assertEquals(Base64.encode(""), "")
        T.assertEquals(Base64.encode("f"), "Zg==")
        T.assertEquals(Base64.encode("fo"), "Zm8=")
        T.assertEquals(Base64.encode("foo"), "Zm9v")
        T.assertEquals(Base64.encode("foob"), "Zm9vYg==")
        T.assertEquals(Base64.encode("fooba"), "Zm9vYmE=")
        T.assertEquals(Base64.encode("foobar"), "Zm9vYmFy")
    end)

    T.it("decodes them back", function()
        for _, text in ipairs({ "", "f", "fo", "foo", "foob", "fooba", "foobar" }) do
            T.assertEquals(Base64.decode(Base64.encode(text)), text)
        end
    end)

    T.it("round-trips every byte value, which is what a book is made of", function()
        local all_bytes = {}
        for value = 0, 255 do all_bytes[#all_bytes+1] = string.char(value) end
        all_bytes = table.concat(all_bytes)
        T.assertEquals(Base64.decode(Base64.encode(all_bytes)), all_bytes)
    end)

    T.it("refuses rubbish rather than returning it", function()
        T.assertNil(Base64.decode("Zm9v!!!!"))
        T.assertNil(Base64.decode("Zm9"))     -- truncated
    end)

    T.it("has a URL-safe alphabet that differs in its last two characters", function()
        -- Every other character is the same, so anything that avoids 62 and
        -- 63 encodes identically under both.
        T.assertEquals(Base64.encodeUrl("foobar"), Base64.encode("foobar"))
        T.assertEquals(Base64.encode("\251\255\191"), "+/+/")
        T.assertEquals(Base64.encodeUrl("\251\255\191"), "-_-_")
        T.assertEquals(Base64.decodeUrl("-_-_"), "\251\255\191")
    end)

    T.it("round-trips every byte value through the URL-safe alphabet too", function()
        local all_bytes = {}
        for value = 0, 255 do all_bytes[#all_bytes+1] = string.char(value) end
        all_bytes = table.concat(all_bytes)
        T.assertEquals(Base64.decodeUrl(Base64.encodeUrl(all_bytes)), all_bytes)
    end)

    T.it("keeps the two alphabets apart", function()
        T.assertNil(Base64.decodeUrl("+/+/"), "the standard alphabet is not URL-safe base64")
        T.assertNil(Base64.decode("-_-_"), "and the URL-safe one is not standard base64")
    end)

    --[[--
    A chunk has to fit in one line whatever the book is made of.

    The obvious version of this test — a chunk of one repeated byte — is
    the easiest possible case and passes on anything: its base64 is all
    letters, and the protocol lets letters through untouched. A real book
    is compressed, so its bytes look random, and roughly one base64
    character in thirty comes out as `+` or `/`, which the protocol escapes
    to three characters each. That is what used to push a chunk over the
    limit partway through a real EPUB, and it is what this checks.
    --]]--
    T.it("stays inside the protocol's line limit, whatever the book holds", function()
        local Protocol = require("duo/protocol")
        local cases = {
            -- Every single base64 character lands on 62 or 63: the worst
            -- input that exists, not merely an awkward one.
            ["all the awkward characters"] = string.rep("\251\255\191", BookTransfer.CHUNK / 3),
            ["one repeated byte"] = string.rep("x", BookTransfer.CHUNK),
        }
        local sequence = {}
        for index = 1, BookTransfer.CHUNK do
            sequence[index] = string.char((index * 37 + index * index) % 256)
        end
        cases["bytes that do not repeat"] = table.concat(sequence)

        for what, chunk in pairs(cases) do
            T.assertEquals(#chunk, BookTransfer.CHUNK, what .. ": wrong size")
            local line = Protocol.encode(Protocol.BOOK_DATA, { b = Base64.encodeUrl(chunk) })
            T.assertTrue(line ~= nil, what .. ": a full chunk did not fit in one message")
            T.assertTrue(#line <= Protocol.MAX_LINE,
                ("%s: a full chunk came to %d bytes, over the %d limit")
                    :format(what, line and #line or 0, Protocol.MAX_LINE))
            -- And back out of the line unharmed.
            local msg = Protocol.decode(line:sub(1, -2))
            T.assertEquals(Base64.decodeUrl(msg.b), chunk, what .. ": did not survive the round trip")
        end
    end)
end)

T.describe("file names from the other device", function()
    T.it("keeps a plain name", function()
        T.assertEquals(BookTransfer.safeName("moby-dick.epub"), "moby-dick.epub")
    end)

    T.it("refuses to be told where to write", function()
        -- A peer names the book, not the destination.
        T.assertEquals(BookTransfer.safeName("/etc/passwd"), "passwd")
        T.assertEquals(BookTransfer.safeName("../../.ssh/authorized_keys"), "authorized_keys")
        T.assertEquals(BookTransfer.safeName("books\\..\\evil.sh"), "evil.sh")
        T.assertNil(BookTransfer.safeName(".."))
        T.assertNil(BookTransfer.safeName(""))
    end)
end)

T.describe("sending and receiving a file", function()
    T.it("carries the bytes across exactly", function()
        -- Something with every byte value in it, and not a round number of
        -- chunks, so the tail is exercised too.
        local parts = {}
        for index = 1, 5000 do
            parts[index] = string.char((index * 7) % 256)
        end
        local contents = table.concat(parts)
        local source = writeFile(TMP .. "/source.epub", contents)

        local sender = assert(BookTransfer.newSender(source))
        T.assertEquals(sender.size, #contents)

        local receiver = assert(BookTransfer.newReceiver{
            directory = TMP .. "/incoming",
            name = "source.epub",
            size = #contents,
        })

        local chunks = 0
        while true do
            local chunk = sender:next()
            if not chunk then break end
            chunks = chunks + 1
            T.assertTrue(receiver:write(chunk))
        end
        sender:close()
        T.assertTrue(chunks > 1, "the fixture should take more than one chunk")

        local path = assert(receiver:finish())
        T.assertEquals(readFile(path), contents, "the book did not survive the trip")
    end)

    T.it("leaves nothing behind when a transfer is cut off", function()
        local source = writeFile(TMP .. "/half.epub", string.rep("abc", 4000))
        local sender = assert(BookTransfer.newSender(source))
        local receiver = assert(BookTransfer.newReceiver{
            directory = TMP .. "/incoming",
            name = "half.epub",
            size = sender.size,
        })
        receiver:write(sender:next())
        receiver:abort()
        sender:close()

        T.assertNil(readFile(TMP .. "/incoming/half.epub"),
            "an aborted transfer left something that looks like a book")
        T.assertNil(readFile(TMP .. "/incoming/half.epub.duopart"))
    end)

    T.it("refuses a book that arrives short", function()
        local source = writeFile(TMP .. "/short.epub", string.rep("z", 3000))
        local sender = assert(BookTransfer.newSender(source))
        local receiver = assert(BookTransfer.newReceiver{
            directory = TMP .. "/incoming",
            name = "short.epub",
            size = sender.size,
        })
        receiver:write(sender:next()) -- only the first chunk
        sender:close()
        local path, err = receiver:finish()
        T.assertNil(path)
        T.assertMatch(err, "incomplete")
    end)

    T.it("refuses more than it was promised", function()
        local receiver = assert(BookTransfer.newReceiver{
            directory = TMP .. "/incoming",
            name = "small.epub",
            size = 10,
        })
        local ok, err = receiver:write(Base64.encode(string.rep("x", 100)))
        T.assertTrue(not ok)
        T.assertMatch(err, "more than it promised")
        receiver:abort()
    end)

    T.it("refuses a book over the size limit", function()
        local receiver, err = BookTransfer.newReceiver{
            directory = TMP .. "/incoming",
            name = "huge.epub",
            size = 100 * 1024 * 1024,
            max_bytes = 8 * 1024 * 1024,
        }
        T.assertNil(receiver)
        T.assertMatch(err, "over the")
    end)

    T.it("reports a file it cannot read", function()
        local sender, err = BookTransfer.newSender(TMP .. "/not-here.epub")
        T.assertNil(sender)
        T.assertTrue(err ~= nil)
    end)
end)

-- After the run, not before it: describe() only registers, run() executes.
local exit_code = T.run()
os.execute("rm -rf " .. TMP)
return exit_code
