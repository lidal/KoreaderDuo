--[[--
The benchmark, driven against a fake clock and a fake shell.

The real one takes twenty minutes and two Kindles, so everything about it
that can be wrong without hardware is checked here: that both devices work
out the same schedule from the clock alone, that a trial is timed from the
moment the network comes back rather than from when it went, that a trial
which never reconnects is recorded rather than hung on, and that the
parameters under test really are applied.
--]]--

package.path = "./?.lua;./duo.koplugin/?.lua;" .. package.path
local T = require("spec/testrunner")
local Benchmark = require("duo/benchmark")

--- A clock that only moves when told, and a shell that only remembers.
local function rig(options)
    options = options or {}
    local clock = { at = options.start or 10000 }
    local ran, wrote = {}, {}
    local core = options.core or { isConnected = function() return false end }
    local bench = Benchmark.new{
        core = core,
        role = options.role or "host",
        trials = options.trials,
        now = function() return clock.at end,
        write = function(line) wrote[#wrote + 1] = line end,
        shell = function(command)
            ran[#ran + 1] = command
            -- A sleep in the fake shell moves the fake clock, which is what
            -- a real one does to the event loop it is blocking.
            local seconds = command:match("^sleep (%d+)")
            if seconds then clock.at = clock.at + tonumber(seconds) end
            return options.output or ""
        end,
    }
    return bench, clock, ran, wrote, core
end

T.describe("agreeing on when to start without asking", function()
    T.it("puts the start on a boundary both devices can name", function()
        local align = Benchmark.ALIGN
        T.assertEquals(Benchmark.startsAt(10000) % align, 0)
        T.assertEquals(Benchmark.startsAt(10000 + 5) % align, 0)
    end)

    T.it("settles it over the link, because the clock alone has a seam", function()
        --[[
        Two devices either side of a boundary pick times a whole window
        apart, and then run different trials at each other for twenty
        minutes. They are connected when the benchmark is set up -- that is
        how it begins -- so the seam is avoidable by naming the second.

        The later of the two wins on both sides, so they agree whoever
        spoke first and neither has to be in charge.
        ]]
        local early = rig()
        local late = rig()
        early:start(10000)
        late:start(10000 + Benchmark.ALIGN)
        T.assertTrue(early.began_at ~= late.began_at, "the fixture proves nothing")

        -- Each hears the other's proposal, in either order.
        local early_moved = early:agree(late.began_at)
        local late_moved = late:agree(early.began_at)
        T.assertEquals(early.began_at, late.began_at,
            "the two would have run different plans at each other")
        T.assertTrue(early_moved, "the earlier device did not come to meet the later one")
        T.assertTrue(not late_moved, "the later device moved, and would say so for ever")
    end)

    T.it("starts the plan over when the other device turns up late", function()
        --[[
        The ordinary case, not a corner. Whoever is tapped first begins on
        its own if the second is slow, and what it does alone measures
        nothing -- half of every trial is what the other device did. So the
        rows taken against nobody go, rather than sitting in the file
        looking like results.
        ]]
        local connected = false
        local bench, clock = rig{
            trials = { { phase = "wifi", label = "one" },
                       { phase = "wifi", label = "two" } },
            core = { isConnected = function() return connected end },
        }
        bench:start(clock.at)
        clock.at = bench.began_at
        bench:update(clock.at)
        clock.at = bench.began_at + Benchmark.SETTLE
        bench:update(clock.at)
        connected = true
        clock.at = clock.at + 1
        bench:update(clock.at)
        T.assertEquals(#bench.results, 1, "the fixture ran nothing to throw away")

        -- And now the other device says when it is really starting.
        T.assertTrue(bench:agree(bench.began_at + 600))
        T.assertEquals(#bench.results, 0, "it kept rows measured against nobody")
        T.assertNil(bench.stage, "it would skip the first trial of the real run")

        clock.at = bench.began_at
        bench:update(clock.at)
        T.assertEquals(bench.stage, 1, "the plan did not begin again from the top")
    end)

    T.it("adopts a time outright when it has none of its own yet", function()
        local bench = rig()
        T.assertTrue(not bench:agree(12345), "it answered back on a proposal it simply took")
        T.assertEquals(bench.began_at, 12345)
    end)

    T.it("always leaves time to start the other device", function()
        -- Strictly after now, so a device started a moment before a
        -- boundary does not begin mid-trial with nobody to talk to.
        for offset = 0, Benchmark.ALIGN - 1 do
            local now = 20000 + offset
            T.assertTrue(Benchmark.startsAt(now) > now,
                "the benchmark would have started in the past")
        end
    end)
end)

T.describe("running a trial", function()
    local function oneTrial(extra)
        local trial = { phase = "wifi", label = "test" }
        for key, value in pairs(extra or {}) do trial[key] = value end
        return { trial }
    end

    T.it("times the reconnect from when the network came back", function()
        --[[
        Not from when it went. The sleep is twenty seconds of the loop
        being frozen on purpose, and counting that against the reconnect
        would make every result twenty seconds worse than the truth.
        ]]
        local connected = false
        local bench, clock = rig{
            trials = oneTrial(),
            core = { isConnected = function() return connected end },
        }
        bench:start(clock.at)
        clock.at = bench.began_at
        bench:update(clock.at)                    -- the trial opens

        clock.at = bench.began_at + Benchmark.SETTLE
        bench:update(clock.at)                    -- sleeps, moving the clock
        local woke = clock.at

        clock.at = woke + 3
        connected = true
        bench:update(clock.at)

        local record = bench.results[1]
        T.assertTrue(record ~= nil, "the trial never finished")
        T.assertEquals(record.outcome, "connected")
        T.assertTrue(math.abs(record.seconds - 3) < 0.001,
            ("timed the sleep as well as the reconnect: %.1fs"):format(record.seconds))
    end)

    T.it("takes the radio away and gives it back", function()
        local bench, clock, ran = rig{ trials = oneTrial() }
        bench:start(clock.at)
        clock.at = bench.began_at
        bench:update(clock.at)
        clock.at = bench.began_at + Benchmark.SETTLE
        bench:update(clock.at)

        local script = table.concat(ran, "\n")
        T.assertMatch(script, "ip link set wlan0 down")
        T.assertMatch(script, "sleep " .. Benchmark.SLEEP)
        T.assertMatch(script, "ip link set wlan0 up")
    end)

    T.it("writes down a trial that never came back rather than waiting on it", function()
        local bench, clock = rig{
            trials = oneTrial(),
            core = { isConnected = function() return false end },
        }
        bench:start(clock.at)
        clock.at = bench.began_at
        bench:update(clock.at)
        clock.at = bench.began_at + Benchmark.SETTLE
        bench:update(clock.at)
        clock.at = clock.at + Benchmark.PATIENCE + 1
        bench:update(clock.at)

        T.assertEquals(bench.results[1].outcome, "NEVER RECONNECTED")
        T.assertNil(bench.results[1].seconds)
    end)

    T.it("applies the setting the trial exists to measure", function()
        -- The sweep is the whole point: with the driver refusing a fixed
        -- cell address, the joiner's lead is the only thing keeping two
        -- rebuilds from making two cells, and eight seconds was a guess.
        local core = { isConnected = function() return false end, JOINER_LEAD = 8 }
        local bench, clock = rig{
            trials = { { phase = "direct", joiner_lead = 3, label = "swept" } },
            core = core,
        }
        bench:start(clock.at)
        clock.at = bench.began_at
        bench:update(clock.at)
        T.assertEquals(core.JOINER_LEAD, 3, "the trial measured the old value")
    end)

    T.it("leaves a control trial alone", function()
        local bench, clock, ran = rig{
            trials = oneTrial{ control = true },
            core = { isConnected = function() return true end },
        }
        bench:start(clock.at)
        clock.at = bench.began_at
        bench:update(clock.at)
        clock.at = bench.began_at + Benchmark.SETTLE + 1
        bench:update(clock.at)
        T.assertEquals(#ran > 0 and table.concat(ran, "\n"):match("ip link set") or nil, nil,
            "the control trial took the network away, which is not a control")
        clock.at = bench.began_at + Benchmark.SLOT - 2
        bench:update(clock.at)
        T.assertEquals(bench.results[1].outcome, "still connected")
    end)
end)

T.describe("the plan", function()
    T.it("sweeps the joiner's lead more than once for each value", function()
        local seen = {}
        for _, trial in ipairs(Benchmark.plan()) do
            if trial.joiner_lead then
                seen[trial.joiner_lead] = (seen[trial.joiner_lead] or 0) + 1
            end
        end
        local values = 0
        for lead, count in pairs(seen) do
            values = values + 1
            T.assertTrue(count >= 2,
                ("a lead of %ds was tried once, which proves nothing"):format(lead))
        end
        T.assertTrue(values >= 4, "too few values to find where it breaks")
        T.assertTrue(seen[0] ~= nil, "no trial with no lead at all to compare against")
    end)

    T.it("ends on the wi-fi, whatever happened in between", function()
        local plan = Benchmark.plan()
        T.assertEquals(plan[#plan].phase, "to-wifi",
            "it would leave the reader on an ad-hoc cell with no way home")
    end)

    T.it("measures the wi-fi before it touches anything", function()
        T.assertEquals(Benchmark.plan()[1].phase, "wifi")
    end)

    T.it("tries a sleep the reader announces and one it does not", function()
        -- The two are different failures and the logs show both happening
        -- on the same evening, so a benchmark that only did one would be
        -- measuring half the problem.
        local announced, silent = false, false
        for _, trial in ipairs(Benchmark.plan()) do
            if trial.phase == "wifi" and not trial.control then
                if trial.announced then announced = true else silent = true end
            end
        end
        T.assertTrue(announced and silent)
    end)
end)

T.run()
