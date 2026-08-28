--[[--
A reconnect benchmark that runs on the two readers themselves.

Why this exists. Everything about how fast the pair comes back together has
been tuned from logs of somebody using the devices: a sleep here, a wake
there, one sample per attempt and a day between rounds. The numbers that
matter -- how long the joiner must wait for the host's cell, how long a
sleep has to be before the link is really gone, whether a wake is announced
-- cannot be measured that way in any useful quantity.

So: both devices run the same plan at the same wall-clock times, without
talking to each other about it. Each trial takes the network away, freezes
the event loop the way a suspend does, gives it back, and times what Duo
then does. The parameters under test are varied between trials, the same
way on both devices, and each writes what it saw to its own file.

Nothing here is used by Duo in ordinary running. It is a measuring
instrument, and it is allowed to be blunt: it takes the interface down, it
blocks the loop on purpose, and it puts everything back at the end.

## Keeping the two in step

There is no message that could coordinate this, because the thing being
measured is what happens when there is nothing to send messages over. So
the schedule is absolute: trials begin at wall-clock times both devices can
work out on their own, aligned to a two-minute boundary. Start the
benchmark on both devices within that window and they will agree.

Whether their clocks agree is itself worth knowing, and the log answers it:
both record the same physical events -- a link closing, a connection
accepted -- so comparing the two files gives the offset.
--]]--

local Benchmark = {}
Benchmark.__index = Benchmark

--- Trials begin on a boundary this many seconds wide, so two devices
--- started within one of each other agree on the schedule without asking.
Benchmark.ALIGN = 120

--- How long one trial gets, start to finish.
Benchmark.SLOT = 60

--- How far into a slot the emulated sleep begins, leaving room for the
--- trial's parameters to be set and the pair to be found already connected.
Benchmark.SETTLE = 5

--- How long the emulated sleep lasts. Longer than Core.SLEPT_THROUGH, so
--- Duo is meant to notice it as a sleep rather than a slow pass.
Benchmark.SLEEP = 20

--- How long to keep waiting for a reconnect before calling the trial lost.
Benchmark.PATIENCE = 30

--[[--
The trials, in order, identical on both devices.

Read as a sentence: measure Wi-Fi as it stands, measure it again when Duo
is told about the sleep, move to the direct link, sweep the joiner's lead
from nothing to plenty, and put the Wi-Fi back.

The sweep is what the whole thing is for. With the driver refusing a fixed
cell address, two devices that rebuild at the same moment can each form a
cell of the same name and never meet; the lead is the only thing keeping
them apart, and eight seconds was a guess made from two log lines. Each
value is tried twice, because one convergence proves nothing.
--]]--
function Benchmark.plan()
    local trials = {
        { phase = "wifi", label = "wi-fi, sleep unannounced" },
        { phase = "wifi", label = "wi-fi, sleep unannounced" },
        { phase = "wifi", label = "wi-fi, sleep unannounced" },
        { phase = "wifi", announced = true, label = "wi-fi, sleep announced" },
        { phase = "wifi", announced = true, label = "wi-fi, sleep announced" },
        -- Nothing taken away: what a link does when left alone, which is
        -- the control every number above is measured against.
        { phase = "wifi", control = true, label = "wi-fi, left alone" },
        { phase = "to-direct", label = "switching to the direct link" },
    }
    for _, lead in ipairs({ 0, 2, 4, 6, 8, 12 }) do
        for _ = 1, 2 do
            trials[#trials + 1] = {
                phase = "direct", joiner_lead = lead,
                label = ("direct link, joiner lead %ds"):format(lead),
            }
        end
    end
    trials[#trials + 1] = { phase = "direct", control = true,
                            label = "direct link, left alone" }
    trials[#trials + 1] = { phase = "to-wifi", label = "putting the wi-fi back" }
    return trials
end

--[[--
Builds a benchmark.

Everything it touches comes in through here so the whole thing can be run
against a fake clock and a fake shell in the suite, which is the only way
any of this gets tested at all -- the real one takes twenty minutes and two
Kindles.

@tparam table options core, shell, write, now, iface, role
--]]--
function Benchmark.new(options)
    return setmetatable({
        core = options.core,
        shell = options.shell,          -- function(command) -> output
        write = options.write,          -- function(line)
        now = options.now,              -- function() -> seconds, wall clock
        iface = options.iface or "wlan0",
        role = options.role or "host",  -- "host" or "follower"
        trials = options.trials or Benchmark.plan(),
        results = {},
        running = false,
    }, Benchmark)
end

--[[--
Takes the other device's proposal, and says whether ours changed.

The later of the two wins, on both devices, so they agree whoever spoke
first and neither has to be in charge. Only a device whose own answer moved
needs to say anything back, which is what stops the two of them agreeing at
each other for ever.

@number at  the second the other device means to begin on
@treturn boolean  true if this device moved, and so should say so
--]]--
function Benchmark:agree(at)
    if not at or at <= 0 then return false end
    if not self.began_at then
        self.began_at = at
        self:log("-- the other device says the first trial is at", ("%d"):format(at))
        return false
    end
    if at <= self.began_at then return false end
    self:log("-- moving the first trial from", ("%d"):format(self.began_at),
        "to", ("%d"):format(at), "to meet the other device")
    self.began_at = at
    --[[
    And starting the plan over, because the schedule it was keeping no
    longer exists. This is the ordinary case, not a corner: the device
    tapped first begins on its own if the second is slow to be tapped, and
    what it does alone is a measurement of nothing -- half of every trial is
    what the *other* device did. Better to throw those away and run the
    whole plan together than to leave a file whose first rows were taken
    against nobody and say nothing about it.
    ]]
    if self.stage then
        self:log("-- starting again from the top; what ran before this was measured alone")
    end
    self.stage = nil
    self.current = nil
    self.results = {}
    return true
end

--- The wall-clock second the first trial begins, from the time it is asked.
function Benchmark.startsAt(now, align)
    align = align or Benchmark.ALIGN
    -- The next boundary strictly after now, so that a device started a
    -- moment before one does not begin mid-trial.
    return math.floor(now / align) * align + align
end

function Benchmark:log(...)
    local parts = {}
    for index = 1, select("#", ...) do
        parts[index] = tostring((select(index, ...)))
    end
    self.write(("%.3f %s"):format(self.now(), table.concat(parts, " ")))
end

--- Which trial a moment belongs to, and how far into it we are.
function Benchmark:at(now)
    if not self.began_at then return nil end
    local since = now - self.began_at
    if since < 0 then return nil end
    local index = math.floor(since / Benchmark.SLOT) + 1
    if index > #self.trials then return nil end
    return index, since - (index - 1) * Benchmark.SLOT
end

function Benchmark:start(now)
    self.running = true
    self.began_at = Benchmark.startsAt(now)
    self.stage = nil
    self.current = nil
    self:log("-- benchmark starting, role", self.role,
        "- first trial at", ("%d"):format(self.began_at),
        ("(%ds from now)"):format(self.began_at - now))
    self:log("-- trials:", #self.trials, "slot:", Benchmark.SLOT,
        "sleep:", Benchmark.SLEEP)
    return self.began_at
end

function Benchmark:stop(reason)
    if not self.running then return end
    self.running = false
    self:log("-- benchmark stopped:", tostring(reason))
    self:report()
end

--- What the driver says about power saving, for the record.
function Benchmark:radioState()
    local out = self.shell(("iw dev %s get power_save 2>&1"):format(self.iface))
    return (tostring(out or ""):gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1"))
end

--- How many peers the interface can see in its cell, which is the only
--- honest answer to "did the joiner land in the host's cell or its own".
function Benchmark:peers()
    local out = self.shell(("iw dev %s station dump 2>/dev/null"):format(self.iface))
    local count = 0
    for _ in tostring(out or ""):gmatch("\nStation") do count = count + 1 end
    if tostring(out or ""):match("^Station") then count = count + 1 end
    return count
end

--[[--
Takes the network away and freezes the loop, the way a suspend does.

Both halves matter and they are different failures. Losing the radio is
what kills the connection; freezing the loop is what stops Duo noticing,
and is why so many sleeps arrive unannounced. A benchmark that only did
the first would measure a case that never happens on the device.
--]]--
function Benchmark:emulateSleep(trial)
    self:log("sleep: taking", self.iface, "down for", Benchmark.SLEEP, "s")
    self.shell(("ip link set %s down >/dev/null 2>&1"):format(self.iface))
    if trial.announced and self.core then
        self:log("sleep: telling Duo about it, as a reader sometimes does")
        pcall(function() self.core:suspend() end)
    end
    -- Blocking on purpose: this is the event loop stopping, which is the
    -- half of a suspend that Duo has to work out for itself.
    self.shell(("sleep %d"):format(Benchmark.SLEEP))
    self.shell(("ip link set %s up >/dev/null 2>&1"):format(self.iface))
    if trial.announced and self.core then
        pcall(function() self.core:resume() end)
    end
    self:log("sleep: over,", self.iface, "back up")
end

function Benchmark:connected()
    if not self.core then return false end
    local ok, answer = pcall(function() return self.core:isConnected() end)
    return ok and answer or false
end

--- Counters Duo keeps, sampled either side of a trial.
function Benchmark:counters()
    local core = self.core or {}
    return {
        dials = core.dials_made or 0,
        rebuilds = core.rebuilds_made or 0,
        sleeps = core.sleeps_noticed or 0,
    }
end

function Benchmark:beginTrial(index, now)
    local trial = self.trials[index]
    self.current = {
        index = index, trial = trial, began = now,
        before = self:counters(),
    }
    self:log(("-- trial %d/%d: %s"):format(index, #self.trials, trial.label))
    if trial.joiner_lead and self.core then
        self.core.JOINER_LEAD = trial.joiner_lead
        self:log("parameter: joiner lead =", trial.joiner_lead)
    end
    self:log("state: connected =", tostring(self:connected()),
        "- power save:", self:radioState(), "- peers:", self:peers())
end

function Benchmark:switchTransport(to)
    local role = self.role == "host" and "host" or "join"
    if to == "direct" then
        self:log("switching to the direct link as", role)
        local began = self.now()
        local out = self.shell(("sh %s %s 2>&1"):format(self.script or "", role))
        self:log(("the script took %.1fs"):format(self.now() - began))
        for line in tostring(out or ""):gmatch("[^\n]+") do
            self:log("  script:", (line:gsub("%s+$", "")))
        end
    else
        self:log("putting the wi-fi back")
        local began = self.now()
        self.shell(("sh %s restore 2>&1"):format(self.script or ""))
        self:log(("restore took %.1fs"):format(self.now() - began))
    end
end

function Benchmark:finishTrial(now, outcome, seconds)
    local record = self.current
    if not record then return end
    local after = self:counters()
    record.outcome = outcome
    record.seconds = seconds
    record.dials = after.dials - record.before.dials
    record.rebuilds = after.rebuilds - record.before.rebuilds
    record.sleeps = after.sleeps - record.before.sleeps
    record.peers = self:peers()
    self.results[#self.results + 1] = record
    self:log(("result: %s%s - dials %d, rebuilds %d, sleeps noticed %d, peers %d"):format(
        outcome,
        seconds and (" in %.1fs"):format(seconds) or "",
        record.dials, record.rebuilds, record.sleeps, record.peers))
    self.current = nil
end

--[[--
One turn of the benchmark, called from the poll loop.

A state machine on wall-clock time rather than a sequence of waits, so that
a device which was busy for a second lands in the same place as one that
was not, and so both devices act on the same second without either being
told to.
--]]--
function Benchmark:update(now)
    if not self.running then return end
    local index, into = self:at(now)
    if not index then
        if self.began_at and now >= self.began_at then self:stop("plan finished") end
        return
    end
    if index ~= self.stage then
        -- A trial that never reported is one that never came back.
        if self.current then self:finishTrial(now, "NEVER RECONNECTED") end
        self.stage = index
        self:beginTrial(index, now)
        return
    end
    local trial = self.trials[index]
    local record = self.current
    if not record then return end

    if trial.phase == "to-direct" or trial.phase == "to-wifi" then
        if not record.done and into >= Benchmark.SETTLE then
            record.done = true
            self:switchTransport(trial.phase == "to-direct" and "direct" or "wifi")
        end
        if into >= Benchmark.SLOT - 3 then
            self:finishTrial(now, self:connected() and "connected" or "not connected yet")
        end
        return
    end

    if trial.control then
        if into >= Benchmark.SLOT - 3 then
            self:finishTrial(now, self:connected() and "still connected" or "dropped by itself")
        end
        return
    end

    if not record.slept and into >= Benchmark.SETTLE then
        record.slept = true
        self:emulateSleep(trial)
        record.woke = self.now()
        return
    end
    if record.slept and not record.outcome then
        if self:connected() then
            self:finishTrial(now, "connected", now - record.woke)
        elseif now - record.woke >= Benchmark.PATIENCE then
            self:finishTrial(now, "NEVER RECONNECTED")
        end
    end
end

--- The table at the end, which is the point of the whole exercise.
function Benchmark:report()
    self:log("")
    self:log("-- summary")
    self:log(("%-34s %-22s %8s %6s %8s %6s"):format(
        "trial", "outcome", "seconds", "dials", "rebuilds", "peers"))
    for _, record in ipairs(self.results) do
        self:log(("%-34s %-22s %8s %6d %8d %6d"):format(
            record.trial.label, record.outcome,
            record.seconds and ("%.1f"):format(record.seconds) or "-",
            record.dials, record.rebuilds, record.peers))
    end
    local best
    for _, record in ipairs(self.results) do
        if record.trial.joiner_lead and record.seconds then
            if not best or record.seconds < best.seconds then best = record end
        end
    end
    if best then
        self:log(("-- quickest direct-link reconnect: %.1fs at a joiner lead of %ds"):format(
            best.seconds, best.trial.joiner_lead))
    end
end

return Benchmark
