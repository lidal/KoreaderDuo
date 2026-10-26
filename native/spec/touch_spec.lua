--[[--
The touch protocol, decoded from the records a Kindle actually sends.

The one part of `device/kobase.lua` that can be tested without a device,
and the part most likely to be wrong: everything else in that file is a
call into koreader-base, but this is our own arithmetic over a kernel
protocol. Feeding it synthetic frames costs nothing and retires most of
the risk of the first run on hardware being a reader that does not answer
a finger.

The frames below are protocol B as a PW3's controller reports it:
`ABS_MT_TRACKING_ID` opening a contact, positions filling it in,
`SYN_REPORT` closing each frame, tracking id -1 ending it.
--]]--

local t = require("spec/testrunner")
local Kobase = require("app/device/kobase")

local EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
local SYN_REPORT = 0
local ABS_MT_SLOT = 0x2f
local ABS_MT_POSITION_X, ABS_MT_POSITION_Y = 0x35, 0x36
local ABS_MT_TRACKING_ID = 0x39

local function record(kind, code, value)
    return { type = kind, code = code, value = value, fd = 3,
             time = { sec = 0, usec = 0 } }
end

--- Feeds a list of records, returning every event that came out.
local function feed(touch, records)
    local out = {}
    for _, item in ipairs(records) do
        local event = touch:feed(item)
        if event then out[#out+1] = event end
    end
    return out
end

--- A whole contact: down at (x1,y1), up at (x2,y2).
local function contact(x1, y1, x2, y2, id)
    return {
        record(EV_ABS, ABS_MT_TRACKING_ID, id or 100),
        record(EV_ABS, ABS_MT_POSITION_X, x1),
        record(EV_ABS, ABS_MT_POSITION_Y, y1),
        record(EV_SYN, SYN_REPORT, 0),
        record(EV_ABS, ABS_MT_POSITION_X, x2),
        record(EV_ABS, ABS_MT_POSITION_Y, y2),
        record(EV_SYN, SYN_REPORT, 0),
        record(EV_ABS, ABS_MT_TRACKING_ID, -1),
        record(EV_SYN, SYN_REPORT, 0),
    }
end

t.describe("a tap", function()
    t.it("is reported where the finger left, on release", function()
        local events = feed(Kobase.newTouch(), contact(500, 700, 502, 703))
        t.assertEquals(#events, 1)
        t.assertEquals(events[1].kind, "tap")
        t.assertEquals(events[1].x, 502)
        t.assertEquals(events[1].y, 703)
    end)

    t.it("is not reported until the finger lifts", function()
        local touch = Kobase.newTouch()
        local events = feed(touch, {
            record(EV_ABS, ABS_MT_TRACKING_ID, 7),
            record(EV_ABS, ABS_MT_POSITION_X, 300),
            record(EV_ABS, ABS_MT_POSITION_Y, 400),
            record(EV_SYN, SYN_REPORT, 0),
        })
        t.assertEquals(#events, 0, "a press alone is not a tap")
    end)

    t.it("tolerates a wobbling finger", function()
        -- 30px is under the 40px slop: still a tap, not a swipe.
        local events = feed(Kobase.newTouch(), contact(500, 700, 530, 715))
        t.assertEquals(#events, 1)
        t.assertEquals(events[1].kind, "tap")
    end)

    t.it("survives the position arriving in the same frame as the id", function()
        -- Which is how a real controller usually reports it.
        local events = feed(Kobase.newTouch(), contact(100, 200, 100, 200))
        t.assertEquals(#events, 1)
        t.assertEquals(events[1].kind, "tap")
    end)
end)

t.describe("a swipe", function()
    t.it("leftwards, from a finger moving left", function()
        local events = feed(Kobase.newTouch(), contact(800, 700, 200, 710))
        t.assertEquals(#events, 1)
        t.assertEquals(events[1].kind, "swipe")
        t.assertEquals(events[1].dir, "left")
    end)

    t.it("rightwards", function()
        local events = feed(Kobase.newTouch(), contact(200, 700, 800, 690))
        t.assertEquals(events[1].dir, "right")
    end)

    t.it("upwards and downwards, by the dominant axis", function()
        t.assertEquals(feed(Kobase.newTouch(), contact(500, 1200, 510, 300))[1].dir, "up")
        t.assertEquals(feed(Kobase.newTouch(), contact(500, 300, 490, 1200))[1].dir, "down")
    end)

    t.it("is nothing when it is too far to be a tap and too short to be a swipe", function()
        -- 70px: past the slop, short of the swipe minimum. A thumb
        -- dragging across a page should not turn it.
        local events = feed(Kobase.newTouch(), contact(500, 700, 570, 700))
        t.assertEquals(#events, 0)
    end)
end)

t.describe("more than one finger", function()
    --[[
    Only the first contact is followed. A pinch read as two taps would be
    an accident turned into two page turns, which on a spread is four
    pages and a reader who has lost their place.
    ]]
    t.it("ignores a second contact entirely", function()
        local touch = Kobase.newTouch()
        local events = feed(touch, {
            record(EV_ABS, ABS_MT_SLOT, 0),
            record(EV_ABS, ABS_MT_TRACKING_ID, 1),
            record(EV_ABS, ABS_MT_POSITION_X, 300),
            record(EV_ABS, ABS_MT_POSITION_Y, 400),
            record(EV_SYN, SYN_REPORT, 0),
            -- A second finger arrives and leaves.
            record(EV_ABS, ABS_MT_SLOT, 1),
            record(EV_ABS, ABS_MT_TRACKING_ID, 2),
            record(EV_ABS, ABS_MT_POSITION_X, 900),
            record(EV_ABS, ABS_MT_POSITION_Y, 1000),
            record(EV_SYN, SYN_REPORT, 0),
            record(EV_ABS, ABS_MT_TRACKING_ID, -1),
            record(EV_SYN, SYN_REPORT, 0),
        })
        t.assertEquals(#events, 0, "the second finger should have emitted nothing")

        -- And the first finger still works when it lifts.
        local after = feed(touch, {
            record(EV_ABS, ABS_MT_SLOT, 0),
            record(EV_ABS, ABS_MT_TRACKING_ID, -1),
            record(EV_SYN, SYN_REPORT, 0),
        })
        t.assertEquals(#after, 1)
        t.assertEquals(after[1].kind, "tap")
        t.assertEquals(after[1].x, 300)
    end)
end)

t.describe("keys", function()
    t.it("report on the press and not on the release", function()
        local touch = Kobase.newTouch()
        local events = feed(touch, {
            record(EV_KEY, 116, 1),
            record(EV_KEY, 116, 0),
        })
        t.assertEquals(#events, 1, "a press and a release is one event")
        t.assertEquals(events[1].kind, "key")
        t.assertEquals(events[1].key, "power")
    end)

    t.it("ignore codes this app has no use for", function()
        local events = feed(Kobase.newTouch(), { record(EV_KEY, 9999, 1) })
        t.assertEquals(#events, 0)
    end)
end)

t.describe("two taps in one frame are both kept", function()
    --[[
    A single waitForEvent can return a whole kernel queue, so a frame may
    hold more than one completed gesture. The device queues them and hands
    them out one per poll; this checks the decoder produces both rather
    than the last.
    ]]
    t.it("decodes both", function()
        local touch = Kobase.newTouch()
        local records = {}
        for _, item in ipairs(contact(100, 100, 100, 100, 1)) do records[#records+1] = item end
        for _, item in ipairs(contact(900, 900, 900, 900, 2)) do records[#records+1] = item end
        local events = feed(touch, records)
        t.assertEquals(#events, 2)
        t.assertEquals(events[1].x, 100)
        t.assertEquals(events[2].x, 900)
    end)
end)

return t.run()
