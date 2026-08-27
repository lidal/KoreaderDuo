local T = require("spec/testrunner")
local Protocol = require("duo/protocol")
local Sha256 = require("duo/sha256")
local Util = require("duo/util")

T.describe("protocol encoding", function()
    T.it("round-trips a plain message", function()
        local line = Protocol.encode(Protocol.STATE, { page = 12, pages = 300 })
        T.assertEquals(line, "STATE page=12 pages=300\n")
        local msg = Protocol.decode(line:sub(1, -2))
        T.assertEquals(msg.type, "STATE")
        T.assertEquals(msg.page, "12")
        T.assertEquals(Protocol.num(msg, "pages"), 300)
    end)

    T.it("survives spaces, equals signs and newlines in values", function()
        local nasty = "/mnt/us/books/Moby Dick = the whale\n(2nd ed).epub"
        local line = Protocol.encode(Protocol.DOC, { file = nasty })
        T.assertEquals(line:find("\n"), #line, "only the terminator may be a newline")
        local msg = Protocol.decode(line:sub(1, -2))
        T.assertEquals(msg.file, nasty)
    end)

    T.it("round-trips every byte value", function()
        local all_bytes = {}
        for i = 0, 255 do all_bytes[#all_bytes+1] = string.char(i) end
        all_bytes = table.concat(all_bytes)
        local line = Protocol.encode(Protocol.NOTE, { text = all_bytes })
        T.assertEquals(Protocol.decode(line:sub(1, -2)).text, all_bytes)
    end)

    T.it("encodes booleans as 1 and 0", function()
        local line = Protocol.encode(Protocol.STATE, { mirror = true, blank = false })
        T.assertEquals(line, "STATE blank=0 mirror=1\n")
        T.assertTrue(Protocol.bool(Protocol.decode("STATE mirror=1"), "mirror"))
        T.assertTrue(not Protocol.bool(Protocol.decode("STATE mirror=0"), "mirror"))
    end)

    T.it("rejects malformed types and field names", function()
        T.assertNil(Protocol.encode("lowercase", {}))
        T.assertNil(Protocol.encode("STATE", { ["Bad Key"] = 1 }))
        T.assertNil(Protocol.decode("state page=1"))
        T.assertNil(Protocol.decode("STATE page"))
    end)

    T.it("refuses to encode an over-long message", function()
        local line, err = Protocol.encode(Protocol.NOTE, { text = string.rep("x", Protocol.MAX_LINE) })
        T.assertNil(line)
        T.assertMatch(err, "too long")
    end)

    T.it("defaults missing numeric fields", function()
        T.assertEquals(Protocol.num(Protocol.decode("STATE"), "page", 7), 7)
        T.assertEquals(Protocol.num(Protocol.decode("STATE page=abc"), "page", 7), 7)
    end)
end)

T.describe("protocol stream reader", function()
    T.it("reassembles messages split across reads", function()
        local reader = Protocol.newReader()
        local wire = Protocol.encode(Protocol.PING, { t = 1 }) .. Protocol.encode(Protocol.PONG, { t = 2 })
        -- Feed the stream one byte at a time, the worst case a TCP link can hand us.
        local messages = {}
        for i = 1, #wire do
            reader:feed(wire:sub(i, i))
            while true do
                local msg = reader:next()
                if not msg then break end
                messages[#messages+1] = msg
            end
        end
        T.assertEquals(#messages, 2)
        T.assertEquals(messages[1].type, "PING")
        T.assertEquals(messages[2].type, "PONG")
        T.assertEquals(messages[2].t, "2")
    end)

    T.it("handles several messages in one read", function()
        local reader = Protocol.newReader()
        reader:feed(Protocol.encode(Protocol.PING) .. Protocol.encode(Protocol.PING) .. "PIN")
        T.assertEquals(reader:next().type, "PING")
        T.assertEquals(reader:next().type, "PING")
        T.assertNil(reader:next(), "partial line must not be returned")
    end)

    T.it("tolerates CRLF and blank lines", function()
        local reader = Protocol.newReader()
        reader:feed("\r\n\r\nSTATE page=3\r\n")
        local msg = reader:next()
        T.assertEquals(msg.type, "STATE")
        T.assertEquals(msg.page, "3")
    end)

    T.it("keeps up with a poll's worth of messages without copying them all again", function()
        --[[
        The reader used to cut the front off its buffer after every message.
        One poll during a transfer takes a couple of hundred kilobytes off
        the socket, which is dozens of messages, and each cut copied
        everything still unread -- so delivering a poll's worth of book
        meant moving several times that in memory, over and over, for the
        length of the book.

        What is asserted is the behaviour, not the speed: read with a
        cursor, and what has already been read stops counting as waiting.
        ]]
        local reader = Protocol.newReader()
        local lines = {}
        for index = 1, 50 do
            lines[index] = Protocol.encode("STATE", { page = index, pad = string.rep("x", 2000) })
        end
        reader:feed(table.concat(lines))
        local whole = reader:backlog()
        T.assertTrue(whole > 100000, "the fixture is not big enough to be worth asking about")

        for index = 1, 50 do
            local msg = assert(reader:next())
            T.assertEquals(msg.page, tostring(index), "the messages came out in the wrong order")
        end
        T.assertEquals(reader:backlog(), 0, "the reader still thinks it has work left")
        T.assertNil(reader:next())
    end)

    T.it("carries on across a feed that lands mid-message", function()
        -- The cursor has to survive more bytes arriving, which is the case
        -- the naive version got for free by throwing the buffer away.
        local reader = Protocol.newReader()
        reader:feed("PING a=1\nPING a=2\nPI")
        T.assertEquals(assert(reader:next()).a, "1")
        T.assertEquals(assert(reader:next()).a, "2")
        T.assertNil(reader:next())
        T.assertEquals(reader:backlog(), 2, "the half-message should still be waiting")
        reader:feed("NG a=3\n")
        T.assertEquals(assert(reader:next()).a, "3")
        T.assertEquals(reader:backlog(), 0)
    end)

    T.it("errors out instead of buffering forever", function()
        local reader = Protocol.newReader()
        reader:feed(string.rep("x", Protocol.MAX_LINE + 10))
        local msg, err = reader:next()
        T.assertNil(msg)
        T.assertMatch(err, "too long")
    end)
end)

T.describe("sha256", function()
    T.it("matches the published test vectors", function()
        T.assertEquals(Sha256.hex(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        T.assertEquals(Sha256.hex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        T.assertEquals(Sha256.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    end)

    T.it("handles inputs that straddle the block padding boundary", function()
        -- 55, 56 and 64 bytes are the cases where padding grows an extra block.
        T.assertEquals(Sha256.hex(string.rep("a", 55)),
            "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318")
        T.assertEquals(Sha256.hex(string.rep("a", 56)),
            "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a")
        T.assertEquals(Sha256.hex(string.rep("a", 64)),
            "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb")
    end)
end)

T.describe("reading our own address", function()
    local NetUtil = require("duo/netutil")

    T.it("understands old ifconfig output", function()
        T.assertEquals(NetUtil.parseAddresses([[
lo        Link encap:Local Loopback
          inet addr:127.0.0.1  Mask:255.0.0.0
wlan0     Link encap:Ethernet  HWaddr 00:11:22:33:44:55
          inet addr:192.168.1.24  Bcast:192.168.1.255  Mask:255.255.255.0
]]), "192.168.1.24")
    end)

    T.it("understands ip and modern ifconfig output", function()
        T.assertEquals(NetUtil.parseAddresses([[
1: lo    inet 127.0.0.1/8 scope host lo
2: wlan0    inet 192.168.1.24/24 scope global wlan0
]]), "192.168.1.24")
    end)

    T.it("accepts a link-local address when that is the only link there is", function()
        -- Two readers talking only to each other have no routable address at
        -- all; refusing 169.254 here would break the direct link entirely.
        T.assertEquals(NetUtil.parseAddresses([[
1: lo    inet 127.0.0.1/8 scope host lo
2: wlan0    inet 169.254.13.1/16 scope link wlan0
]]), "169.254.13.1")
    end)

    T.it("prefers a routable address over a link-local one", function()
        T.assertEquals(NetUtil.parseAddresses([[
2: wlan0    inet 169.254.13.1/16 scope link wlan0
3: eth0    inet 192.168.1.24/24 scope global eth0
]]), "192.168.1.24")
    end)

    T.it("finds an address on a USB network interface too", function()
        -- A Kindle running USBNetwork brings up `usb0` and takes
        -- 192.168.15.244. Nothing here is looking for a wireless card, and
        -- nothing should: whatever carries IP will do.
        T.assertEquals(NetUtil.parseAddresses([[
1: lo    inet 127.0.0.1/8 scope host lo
2: usb0    inet 192.168.15.244/24 scope global usb0
]]), "192.168.15.244")
    end)

    T.it("returns nothing when there is only loopback", function()
        T.assertNil(NetUtil.parseAddresses("1: lo    inet 127.0.0.1/8 scope host lo"))
        T.assertNil(NetUtil.parseAddresses(""))
        T.assertNil(NetUtil.parseAddresses(nil))
    end)

    T.it("knows where to broadcast on a link-local network", function()
        local addresses = NetUtil.getBroadcastAddresses("169.254.13.1")
        local found = false
        for _, address in ipairs(addresses) do
            if address == "169.254.255.255" then found = true end
        end
        T.assertTrue(found, "a /16 link-local network broadcasts to 169.254.255.255")
        T.assertEquals(NetUtil.getBroadcastAddresses("192.168.1.24")[1], "192.168.1.255")
    end)

    T.it("reads power saving out of what the tool printed", function()
        --[[
        Both spellings, because both tools are asked. `iw` says one thing in
        one line; `iwconfig` says another somewhere in a paragraph about the
        association, and older builds put an `=` where newer ones put a `:`.

        Backwards from what it reads, deliberately: true means the radio is
        kept awake, which is power saving being off.
        ]]
        T.assertEquals(NetUtil.parsePowerSave("Power save: off"), true)
        T.assertEquals(NetUtil.parsePowerSave("Power save: on"), false)
        T.assertEquals(NetUtil.parsePowerSave([[
wlan0     IEEE 802.11  ESSID:"home"
          Mode:Managed  Frequency:2.437 GHz  Access Point: AA:BB:CC:DD:EE:FF
          Power Management:on
]]), false)
        T.assertEquals(NetUtil.parsePowerSave("          Power Management=off"), true)
    end)

    T.it("says nothing rather than guessing when the card does not answer", function()
        -- A driver that prints the line with no value is a driver saying it
        -- does not know, and a caller that cannot tell should leave the
        -- radio alone rather than poke it on a hunch.
        T.assertNil(NetUtil.parsePowerSave("          Power Management:"))
        T.assertNil(NetUtil.parsePowerSave("command not found"))
        T.assertNil(NetUtil.parsePowerSave(""))
        T.assertNil(NetUtil.parsePowerSave(nil))
    end)
end)

T.describe("util", function()
    T.it("makes readable pairing tokens", function()
        for _ = 1, 50 do
            local token = Util.newPairingToken(6)
            T.assertEquals(#token, 6)
            T.assertMatch(token, "^[234679ACDEFGHJKMNPQRTUVWXYZ]+$")
        end
    end)

    T.it("normalizes what the user types", function()
        T.assertEquals(Util.normalizeToken(" k7f-2qx "), "K7F2QX")
        T.assertEquals(Util.normalizeToken(nil), "")
    end)

    T.it("makes distinct nonces", function()
        local seen = {}
        for _ = 1, 100 do
            local nonce = Util.randomHex(8)
            T.assertEquals(#nonce, 16)
            T.assertNil(seen[nonce], "nonce repeated")
            seen[nonce] = true
        end
    end)

    T.it("clamps", function()
        T.assertEquals(Util.clamp(5, 1, 10), 5)
        T.assertEquals(Util.clamp(0, 1, 10), 1)
        T.assertEquals(Util.clamp(11, 1, 10), 10)
    end)
end)

os.exit(T.run())
