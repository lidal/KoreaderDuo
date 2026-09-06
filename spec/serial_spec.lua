--[[--
The Bluetooth path, over a real character device.

A bound RFCOMM channel appears as `/dev/rfcomm0`: a character device with
no connect step, where both ends simply open the same line. A pseudo-terminal
pair behaves the same way, so `socat` gives us the two ends of a Bluetooth
link to test against without any Bluetooth hardware.

Two device processes again — the same processes and the same plugin as the
Wi-Fi tests, with the transport swapped underneath.
--]]--

local T = require("spec/testrunner")
local socket = require("socket")
local Controller = require("spec/harness/controller")
local SerialTransport = require("duo/transport_serial")

local LOG_DIR = os.getenv("DUO_LOG_DIR") or "/tmp"
--- Named for this run, so two of them cannot fight over one pair of ends.
local RUN = tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
local PTY_A = LOG_DIR .. "/duo-pty-a-" .. RUN
local PTY_B = LOG_DIR .. "/duo-pty-b-" .. RUN

--------------------------------------------------------------------------
-- A stand-in for a bound RFCOMM channel
--------------------------------------------------------------------------

--- True once something written on one end can be read from the other.
local function carriesAByte()
    local a = SerialTransport.open(PTY_A, { skip_stty = true })
    if not a then return false end
    local b = SerialTransport.open(PTY_B, { skip_stty = true })
    if not b then a:close() return false end
    a:send("\n")
    a:flush()
    local carried = false
    local deadline = socket.gettime() + 1
    while socket.gettime() < deadline do
        if (b:receive() or "") ~= "" then carried = true break end
        socket.sleep(0.02)
    end
    a:close()
    b:close()
    return carried
end

local function startPtyPair()
    os.remove(PTY_A)
    os.remove(PTY_B)
    os.execute(("socat -d -d pty,raw,echo=0,link=%s pty,raw,echo=0,link=%s >%s/duo-socat.log 2>&1 &")
        :format(PTY_A, PTY_B, LOG_DIR))
    --[[
    Waited for by carrying a byte, not by sleeping.

    The symlinks appear before socat has finished wiring the two ends
    together, so this used to sleep two tenths of a second and hope. Under
    the full suite that was sometimes not enough and this file failed on its
    first test while passing every time it was run alone -- which is the
    least useful kind of failure there is.

    A pair that has moved a byte is a pair that is ready. Nothing else
    proves it, and the check costs less than the sleep it replaces.
    ]]
    local deadline = socket.gettime() + 10
    while socket.gettime() < deadline do
        if SerialTransport.exists(PTY_A) and SerialTransport.exists(PTY_B) then
            if carriesAByte() then return true end
        end
        socket.sleep(0.05)
    end
    return false
end

local function stopPtyPair()
    -- By this run's own ends, so a suite running beside this one keeps its.
    os.execute(("pkill -f 'link=%s' 2>/dev/null"):format(PTY_A))
    os.remove(PTY_A)
    os.remove(PTY_B)
end

--------------------------------------------------------------------------
-- Tests
--------------------------------------------------------------------------

--[[
A skip that says nothing is a pass that means nothing.

This file used to print a line and `return 0` when socat was missing, which
reads in the suite exactly like a file whose tests all passed. Nobody
looking at "All suites passed" would know the serial transport had not been
exercised at all -- and that is a fair description of how it came to be
believed tested when it was not.

So a skip is loud now, and it is counted as a failure of the suite rather
than a silence in it. Install socat, or know that this is untested.
]]
if not SerialTransport.isAvailable() then
    print("")
    print("!! SERIAL TESTS DID NOT RUN: this interpreter has no LuaJIT ffi.")
    print("!! The serial transport is UNTESTED in this run.")
    return 1
end

if not startPtyPair() then
    stopPtyPair()
    print("")
    print("!! SERIAL TESTS DID NOT RUN: socat is not installed.")
    print("!! The serial transport is UNTESTED in this run. Install socat.")
    return 1
end

local controller = Controller.new{ first_port = 18950 }
local leader = controller:spawn("ser-leader")
local follower = controller:spawn("ser-follower")

local function connectOverSerial()
    controller:call(leader, "Core:stop('reset')")
    controller:call(follower, "Core:stop('reset')")
    for _, device in ipairs({ leader, follower }) do
        controller:call(device, "Core.settings.transport = 'serial'")
        controller:call(device, "Core.settings.token = 'S3R14L'")
    end
    controller:call(leader, ("Core.settings.serial_device = %q"):format(PTY_A))
    controller:call(follower, ("Core.settings.serial_device = %q"):format(PTY_B))
    controller:call(leader, "Core:start('leader')")
    controller:call(follower, "Core:start('follower')")
    --[[
    The ordinary window, deliberately. This used to fail here and be widened
    on the theory that a shared machine was just being slow; it was not, and
    the waiting only delayed the report. What was actually happening is in
    the restart test below.
    ]]
    controller:assertEventually(leader, "Core:isConnected()", true,
        "no follower on the serial line")
    controller:assertEventually(follower, "Core:isConnected()", true,
        "did not reach the leader")
end

T.describe("serial transport", function()
    T.it("opens a device and moves bytes both ways", function()
        local a = assert(SerialTransport.open(PTY_A, { skip_stty = true }))
        local b = assert(SerialTransport.open(PTY_B, { skip_stty = true }))

        T.assertTrue(a:send("hello down the line\n"))
        local received = ""
        local deadline = socket.gettime() + 3
        while socket.gettime() < deadline and not received:find("\n") do
            received = received .. (b:receive() or "")
            socket.sleep(0.01)
        end
        T.assertEquals(received, "hello down the line\n")

        -- And back, because a serial line is symmetric.
        T.assertTrue(b:send("and back\n"))
        received = ""
        deadline = socket.gettime() + 3
        while socket.gettime() < deadline and not received:find("\n") do
            received = received .. (a:receive() or "")
            socket.sleep(0.01)
        end
        T.assertEquals(received, "and back\n")

        a:close(); b:close()
    end)

    T.it("configures the line it opens, and does not wait for carrier", function()
        --[[
        Every other test in this file opens with skip_stty, because a
        pseudo-terminal needs no setting up -- which means the stty a real
        device actually gets was never run here at all. It is not a small
        thing to leave untested. Raw mode is what stops a tty echoing every
        message back to its sender, and `clocal` is what stops the line
        waiting for a carrier that three soldered wires do not carry: the
        reader that never finished starting was an open blocking on exactly
        that.
        ]]
        local a = assert(SerialTransport.open(PTY_A, { baud = 115200 }))
        local b = assert(SerialTransport.open(PTY_B, { baud = 115200 }))

        T.assertTrue(a:send("still carries bytes\n"))
        local received = ""
        local deadline = socket.gettime() + 3
        while socket.gettime() < deadline and not received:find("\n") do
            received = received .. (b:receive() or "")
            socket.sleep(0.01)
        end
        T.assertEquals(received, "still carries bytes\n")
        a:close(); b:close()

        -- stty is the authority on what landed: it prints a name for a flag
        -- that is on, and -name for one that is off.
        local function flagsOn(path)
            local pipe = assert(io.popen(("stty -F %s -a 2>&1"):format(path)))
            local out = pipe:read("*a") or ""
            pipe:close()
            return out
        end
        local flags = flagsOn(PTY_A)
        T.assertTrue(not flags:find("%-clocal"),
            "the line still waits for a carrier three wires do not carry")
        T.assertMatch(flags, "%-crtscts", "it expects an RTS and a CTS that are not wired")
        T.assertMatch(flags, "%-echo", "the line echoes what it is sent")
        -- Off unless asked for: on these readers this line is the console,
        -- and one stray XOFF on a console stops everything that writes to it.
        T.assertMatch(flags, "%-ixon", "flow control was on without being asked for")
        T.assertMatch(flags, "%-ixoff", "flow control was on without being asked for")

        -- And on when it is asked for.
        local c = assert(SerialTransport.open(PTY_A, { baud = 115200, flow_control = true }))
        flags = flagsOn(PTY_A)
        c:close()
        T.assertTrue(not flags:find("%-ixon"), "asking for flow control did nothing")
        T.assertTrue(not flags:find("%-ixoff"), "asking for flow control did nothing")
        -- Put it back, so nothing after this runs with it on.
        SerialTransport.open(PTY_A, { baud = 115200 }):close()
    end)

    T.it("does not block on a device it cannot get a carrier from", function()
        --[[
        The fault that looked like a reader refusing to start. Checking
        whether a device is there used to be a blocking open, and a blocking
        open on a tty with no carrier never returns. It has to answer
        whatever state the line is in.
        ]]
        local started = socket.gettime()
        T.assertTrue(SerialTransport.exists(PTY_A))
        T.assertTrue(not SerialTransport.exists("/dev/definitely-not-here"))
        T.assertTrue(not SerialTransport.exists(""))
        T.assertTrue(socket.gettime() - started < 1,
            "checking whether a device is there blocked")
    end)

    T.it("reports a device that is not there", function()
        local stream, err = SerialTransport.open("/dev/definitely-not-here")
        T.assertNil(stream)
        T.assertMatch(err, "could not open")
    end)

    T.it("does not block when there is nothing to read", function()
        local a = assert(SerialTransport.open(PTY_A, { skip_stty = true }))
        local started = socket.gettime()
        for _ = 1, 50 do a:receive() end
        T.assertTrue(socket.gettime() - started < 0.5, "reads are blocking")
        a:close()
    end)
end)

T.describe("two devices over a serial link", function()
    T.it("pairs with no network at all", function()
        connectOverSerial()
        T.assertEquals(controller:call(leader, "Core.role"), "leader")
        T.assertEquals(controller:call(follower, "Core:getReadyLinks()[1].peer_name"), "ser-leader")
        T.assertMatch(controller:call(leader, "Core:getStatusText()"), "Leader")
    end)

    T.it("waits for a leader that starts later", function()
        controller:call(leader, "Core:stop('reset')")
        controller:call(follower, "Core:stop('reset')")
        for _, device in ipairs({ leader, follower }) do
            controller:call(device, "Core.settings.transport = 'serial'")
            controller:call(device, "Core.settings.token = 'S3R14L'")
        end
        controller:call(leader, ("Core.settings.serial_device = %q"):format(PTY_A))
        controller:call(follower, ("Core.settings.serial_device = %q"):format(PTY_B))

        -- The follower opens the line first and hears nothing for a while.
        controller:call(follower, "Core:start('follower')")
        socket.sleep(1.5)
        T.assertEquals(controller:call(follower, "Core:isConnected()"), "false")

        controller:call(leader, "Core:start('leader')")
        controller:assertEventually(follower, "Core:isConnected()", true,
            "the repeated challenge never got through")
    end)

    T.it("comes back after being stopped and started again", function()
        --[[
        A serial line is not a connection: there is nothing to hang up, so
        the bytes the last session wrote are still in the device's buffer
        when the next one opens it, and the next one reads them as though
        they had just arrived. The leader restarted, sent a fresh challenge,
        and the follower answered the one from before the restart -- a proof
        against a nonce nobody was holding any more. Each side then reported
        the other as having the wrong pairing code, for ever: one message out
        of step, and every retry read more of the backlog rather than less.

        It showed up here as a test that failed every few runs, which is
        what a race looks like when you do not look at it. It is not a race.
        Restart the pair twice and it never came back at all.
        ]]
        connectOverSerial()
        for _ = 1, 3 do
            connectOverSerial()
        end
        T.assertEquals(controller:call(leader, "Core:isConnected()"), "true",
            "the pair would not go back together over the same line")
    end)

    T.it("runs the spread over a wire just as over Wi-Fi", function()
        connectOverSerial()
        controller:call(leader, "D:jumpToPage(10)")
        controller:assertEventually(follower, "D:getPage()", 11, "the follower is not on the next page")

        controller:call(leader, "D:tapForward()")
        controller:assertEventually(leader, "D:getPage()", 12)
        controller:assertEventually(follower, "D:getPage()", 13)

        controller:call(follower, "D:tapForward()")
        controller:assertEventually(leader, "D:getPage()", 14, "the follower's tap did not reach the leader")
        controller:assertEventually(follower, "D:getPage()", 15)
    end)

    T.it("is left exactly as it was by a sleep", function()
        --[[
        The whole reason to want a wire. On a network a suspend takes the
        sockets with it, so Duo closes them deliberately and rebuilds on the
        way back -- and rebuilding was the eight seconds. A character device
        survives a suspend: the descriptor is still open, the line is still
        there, the session key and the slot are still good. There is nothing
        to rebuild and nothing to reopen.
        ]]
        connectOverSerial()
        local before = controller:call(leader, "Core:getReadyLinks()[1].created_at")

        controller:call(leader, "Core:suspend()")
        T.assertEquals(controller:call(leader, "Core.role"), "leader",
            "the wire was put down for a sleep")
        T.assertEquals(controller:call(leader, "#Core.links"), "1",
            "the link was closed for a sleep")
        T.assertEquals(controller:call(leader, "Core:isConnected()"), "true")

        controller:call(leader, "Core:resume()")
        T.assertEquals(controller:call(leader, "Core:isConnected()"), "true",
            "it had to find the other device again after a sleep")
        T.assertEquals(controller:call(leader, "Core:getReadyLinks()[1].created_at"), before,
            "the session was made again for a sleep that took nothing away")

        -- And it is still a working pair, not merely a link-shaped object.
        controller:call(leader, "D:jumpToPage(30)")
        controller:assertEventually(follower, "D:getPage()", 31,
            "the pair stopped working across a sleep")
    end)

    T.it("does not let a long sleep look like a peer that went away", function()
        --[[
        The clocks move while the loop is stopped, and on a network a link
        whose silence is forgiven looks healthy when it is in fact dead --
        which is why a sleep is normally charged to the peer. A wire is the
        opposite case: nothing went away, so charging it means every wake
        starts the session again for nothing.
        ]]
        connectOverSerial()
        local before = controller:call(leader, "Core:getReadyLinks()[1].created_at")
        -- A wake with an hour of frozen loop behind it.
        controller:call(leader, "Core.last_poll_at = require('duo/util').now() - 3600")
        controller:call(leader, "Core:pollOnce()")

        T.assertEquals(controller:call(leader, "Core:isConnected()"), "true",
            "an hour of not running was charged to the other device")
        T.assertEquals(controller:call(leader, "Core:getReadyLinks()[1].created_at"), before,
            "it started the session again after a sleep that changed nothing")
    end)

    T.it("steps back instead of closing when the other end goes quiet", function()
        --[[
        Silence on a connection is evidence: TCP would have delivered. On a
        wire it is evidence of nothing -- the other reader is opening a
        large book, or asleep -- and the line is still there either way. So
        the session steps back and is offered again over the same stream,
        which costs a round trip rather than a reopen.
        ]]
        connectOverSerial()
        controller:call(leader, "Core:getReadyLinks()[1]:renegotiate('test')")
        T.assertEquals(controller:call(leader, "#Core.links"), "1",
            "it closed the wire rather than stepping back")
        T.assertEquals(controller:call(leader, "Core.reconnect_at == nil"), "true",
            "it went looking for a connection it never lost")
        controller:assertEventually(leader, "Core:isConnected()", true,
            "it never offered the other end a new session")
    end)

    T.it("hears a reader that restarted, rather than waiting out its silence", function()
        --[[
        A restarted peer arrives on a new socket over TCP, and the old one
        dies with it. On a wire the same channel carries the new
        conversation, so nothing tells this end that anything happened: it
        goes on signing heartbeats with a key the other end threw away. The
        call the unpaired end makes down the line is what says so.
        ]]
        connectOverSerial()
        -- The follower restarts. The leader still believes the old session.
        controller:call(follower, "Core:stop('restarting')")
        controller:call(follower, "Core:start('follower')")
        controller:assertEventually(leader, "Core:isConnected()", true,
            "the leader never noticed the other reader had started again")
        controller:assertEventually(follower, "Core:isConnected()", true)
        T.assertEquals(controller:call(leader, "#Core.links"), "1",
            "the leader piled up a second link on one line")
    end)

    T.it("reads through noise from whatever else is on the line", function()
        --[[
        On these readers the wire is the debug UART, which is also the
        console. A kernel message or a login prompt lands in the middle of
        the conversation, and one line that does not parse used to end the
        link -- on a transport where ending it is the one thing that helps
        least and the one thing there is no quick way back from.

        Written with a plain file handle rather than a third transport
        stream: opening one reads the line to clear it, which would take the
        bytes under the reader this test is about.
        ]]
        connectOverSerial()
        local function shout(text)
            local pipe = assert(io.open(PTY_A, "wb"))
            pipe:write(text)
            pipe:close()
        end
        -- What a console really puts on a line: whole lines, newline ended.
        shout("[ 1234.567890] usb 1-1: USB disconnect, device number 4\n")
        shout("\nKindle login: \n")
        socket.sleep(0.3)

        T.assertEquals(controller:call(follower, "Core:isConnected()"), "true",
            "a kernel message on the console ended the link")
        controller:call(leader, "D:jumpToPage(40)")
        controller:assertEventually(follower, "D:getPage()", 41,
            "the pair stopped talking after noise on the line")
    end)

    T.it("loses the message a half-written line lands in, and no more", function()
        --[[
        The honest limit of newline framing, stated rather than hoped for.
        Noise cut off mid-line has no newline to end it, so it runs into
        whatever the other reader says next and takes that one message with
        it. What it must not do is take the line: the damage stops at the
        newline after it, and everything from there is read as usual.
        ]]
        connectOverSerial()
        local pipe = assert(io.open(PTY_A, "wb"))
        pipe:write("\0\255 half a line, cut off with no newline")
        pipe:close()
        socket.sleep(0.3)

        T.assertEquals(controller:call(follower, "Core:isConnected()"), "true",
            "an unterminated line ended the link")
        -- Whatever the next message was is gone. The one after it is not.
        controller:call(leader, "D:jumpToPage(50)")
        controller:call(leader, "D:jumpToPage(60)")
        controller:assertEventually(follower, "D:getPage()", 61,
            "the line never recovered from an unterminated one")
    end)

    T.it("turns away a device with the wrong pairing code", function()
        controller:call(leader, "Core:stop('reset')")
        controller:call(follower, "Core:stop('reset')")
        for _, device in ipairs({ leader, follower }) do
            controller:call(device, "Core.settings.transport = 'serial'")
        end
        controller:call(leader, "Core.settings.token = 'S3R14L'")
        controller:call(follower, "Core.settings.token = 'WR0NG2'")
        controller:call(leader, ("Core.settings.serial_device = %q"):format(PTY_A))
        controller:call(follower, ("Core.settings.serial_device = %q"):format(PTY_B))
        controller:call(leader, "Core:start('leader')")
        controller:call(follower, "Core:start('follower')")

        socket.sleep(2)
        T.assertEquals(controller:call(leader, "Core:isConnected()"), "false",
            "a device with the wrong code got in over serial")
        controller:call(leader, "Core:stop('done')")
        controller:call(follower, "Core:stop('done')")
    end)
end)

local exit_code = T.run()
controller:shutdown()
stopPtyPair()
os.exit(exit_code)
