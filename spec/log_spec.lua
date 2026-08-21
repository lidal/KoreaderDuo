--[[--
Duo's own log file.

The point of it is a file somebody can copy off a reader and send on, so
what is tested here is the awkward half: staying inside its bounds, and
never taking the reader down with it when the card is full.
--]]--

local T = require("spec/testrunner")
local Log = require("duo/log")

local DIR = (os.getenv("DUO_LOG_DIR") or "/tmp") .. "/duo-log-spec"
local PATH = DIR .. "/duo.log"

local function fresh()
    os.execute(("rm -rf %q && mkdir -p %q"):format(DIR, DIR))
    return assert(Log.open(PATH))
end

local function readFile(path)
    local handle = io.open(path, "rb")
    if not handle then return nil end
    local contents = handle:read("*a")
    handle:close()
    return contents
end

local function exists(path)
    local handle = io.open(path, "rb")
    if not handle then return false end
    handle:close()
    return true
end

T.describe("writing the log", function()
    T.it("writes a line at a time", function()
        local writer = fresh()
        writer:write("first")
        writer:write("second")
        writer:close()
        T.assertEquals(readFile(PATH), "first\nsecond\n")
    end)

    T.it("is on disk before the next thing happens", function()
        -- A log is read after something went wrong, which is exactly the
        -- case where the last thing buffered is the thing worth reading.
        local writer = fresh()
        writer:write("about to do the risky thing")
        T.assertMatch(readFile(PATH) or "", "risky",
            "the line was still in a buffer when it was needed on disk")
        writer:close()
    end)

    T.it("picks up where it left off rather than starting again", function()
        -- KOReader rebuilds the plugin every time a document opens, and a
        -- log that started fresh at each of those would hold nothing but
        -- the last few seconds.
        local writer = fresh()
        writer:write("before")
        writer:close()
        local again = assert(Log.open(PATH))
        again:write("after")
        again:close()
        T.assertEquals(readFile(PATH), "before\nafter\n")
    end)

    T.it("says so rather than throwing when it cannot be written", function()
        local writer, err = Log.open("/nowhere/at/all/duo.log")
        T.assertNil(writer, "a log in a folder that does not exist was opened")
        T.assertTrue(err ~= nil, "and it should say why")
    end)
end)

T.describe("keeping the log inside its bounds", function()
    T.it("rolls over instead of filling the card", function()
        local writer = fresh()
        local line = string.rep("x", 1000)
        -- Comfortably past the cap, which is what a long evening of page
        -- turns looks like.
        for _ = 1, math.ceil(Log.MAX_BYTES / 1000) + 10 do
            writer:write(line)
        end
        writer:close()

        T.assertTrue(exists(PATH .. ".1"), "nothing was rolled over")
        local size = #(readFile(PATH) or "")
        T.assertTrue(size <= Log.MAX_BYTES,
            ("the live log grew to %d bytes, past its cap of %d"):format(size, Log.MAX_BYTES))
    end)

    T.it("keeps one generation and no more", function()
        local writer = fresh()
        local line = string.rep("y", 1000)
        for _ = 1, math.ceil(Log.MAX_BYTES / 1000) * 3 do
            writer:write(line)
        end
        writer:close()
        T.assertTrue(exists(PATH .. ".1"))
        T.assertTrue(not exists(PATH .. ".2"),
            "a second generation was kept, which is a card filling up slowly")
    end)

    T.it("still holds what just happened after rolling over", function()
        -- The whole reason for two files: rolling over must not throw away
        -- the moment somebody is about to report.
        local writer = fresh()
        for _ = 1, math.ceil(Log.MAX_BYTES / 1000) + 2 do
            writer:write(string.rep("z", 1000))
        end
        writer:write("the thing that went wrong")
        writer:close()
        T.assertMatch(readFile(PATH) or "", "the thing that went wrong")
    end)

    T.it("names both files when there are two to hand over", function()
        local writer = fresh()
        T.assertEquals(#writer:getPaths(), 1)
        for _ = 1, math.ceil(Log.MAX_BYTES / 1000) + 2 do
            writer:write(string.rep("w", 1000))
        end
        local paths = writer:getPaths()
        T.assertEquals(#paths, 2, "the rolled-over log was not offered")
        T.assertEquals(paths[2], PATH, "the live log should come last")
        writer:close()
    end)
end)

T.describe("the shape of a line", function()
    T.it("stamps the time and what the device was being", function()
        local line = Log.format("leader", "link", "up")
        T.assertMatch(line, "%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d %[leader%] link up")
    end)

    T.it("keeps one event on one line", function()
        -- A log read by eye is read a line at a time, and an alert with a
        -- paragraph in it would otherwise swallow the timestamps around it.
        local line = Log.format("follower", "alert:", "Something\nover two lines")
        T.assertTrue(not line:find("\n"), "a message broke its line in two")
        T.assertMatch(line, "Something | over two lines")
    end)

    T.it("says something for a device that is not being anything yet", function()
        T.assertMatch(Log.format(nil, "starting up"), "%[off%] starting up")
    end)

    T.it("takes whatever it is handed", function()
        -- Callers pass numbers, nils and tables without thinking about it,
        -- and a log that failed on one would go missing exactly when the
        -- unusual thing happened.
        local line = Log.format("leader", "page", 42, nil, true)
        T.assertMatch(line, "page 42 nil true")
    end)
end)

os.execute(("rm -rf %q"):format(DIR))
os.exit(T.run())
