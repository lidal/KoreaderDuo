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
        switch = options.switch,        -- function("direct"|"wifi")
        show = options.show,            -- function(text) -> on the screen
        hold = options.hold,            -- function(bool) keep the reader awake
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

--[[--
Puts something on the screen.

Because twenty minutes of a reader doing nothing visible is twenty minutes
of not knowing whether it is working, and the only way to find out was to
plug in a cable and read the file it was still writing.
--]]--
function Benchmark:say(text)
    if not self.show then return end
    pcall(self.show, text)
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
    --[[
    And the reader is kept awake for the whole of it. The first run lost
    three trials to the device suspending underneath the benchmark -- the
    host jumped from trial 12 to trial 16 with a 222-second gap in the file
    -- because nothing was touching the screen and a reader left alone goes
    to sleep. It was measuring reconnects while asleep, which is a thing it
    could only ever fail at.
    ]]
    if self.hold then pcall(self.hold, true) end
    self.began_at = Benchmark.startsAt(now)
    self.stage = nil
    self.current = nil
    self:log("-- benchmark starting, role", self.role,
        "- first trial at", ("%d"):format(self.began_at),
        ("(%ds from now)"):format(self.began_at - now))
    self:log("-- trials:", #self.trials, "slot:", Benchmark.SLOT,
        "sleep:", Benchmark.SLEEP)
    --[[
    And which way it is reconnecting, because that is the thing two runs
    are now compared on and neither file said. A run whose settings are not
    in it is a run that has to be dated against a memory.
    ]]
    local plain = self.core and self.core.isPlain and self.core:isPlain()
    self:log("-- reconnecting the", plain and "plain" or "usual", "way")
    return self.began_at
end

function Benchmark:stop(reason)
    if not self.running then return end
    self.running = false
    if self.hold then pcall(self.hold, false) end
    self:log("-- benchmark stopped:", tostring(reason))
    self:report()
    self:say("Duo benchmark finished\n" .. tostring(reason))
end

--- What the driver says about power saving, for the record.
function Benchmark:radioState()
    local out = self.shell(("iw dev %s get power_save 2>&1"):format(self.iface))
    return (tostring(out or ""):gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1"))
end

--[[--
Which cell this device is actually in.

`station dump` was the first answer to "did the joiner land in the host's
cell or its own" and it turned out to be no answer at all: on this driver it
lists nothing even while the two are connected and passing traffic, so every
trial of the first real run reported peers 0, connected and disconnected
alike.

The cell's address does answer it, and better, because it can be compared
between the two logs directly: if the host says one address and the joiner
another, they are in rival cells of the same name, which is the failure the
joiner's head start existed to prevent. `iw link` prints it as "Joined IBSS
<address>" or names the SSID it associated to.
--]]--
function Benchmark:cell()
    local out = tostring(self.shell(
        ("iw dev %s link 2>/dev/null"):format(self.iface)) or "")
    local bssid = out:match("[Jj]oined IBSS%s+(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)")
        or out:match("[Cc]onnected to%s+(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)")
    return bssid or (out:match("Not connected") and "none") or "?"
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
    --[[
    The cell goes, not just the interface. Taking the link down and putting
    it back leaves the driver's ad-hoc configuration intact, so it rejoins
    the same cell by itself -- which is not what a suspend does, and made
    the first run flatter than the truth: one trial reconnected in 0.2s
    having done nothing at all, because nothing had been taken away.

    Leaving the cell first makes the wake face what a real one faces. It
    fails harmlessly on an interface that is not in ad-hoc mode, which is
    every Wi-Fi trial.
    ]]
    self.shell(("iw dev %s ibss leave >/dev/null 2>&1"):format(self.iface))
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
    self:say(("Duo benchmark %d/%d\n%s\n%s"):format(
        index, #self.trials, trial.label,
        self.last_result or "starting"))
    if trial.joiner_lead and self.core then
        self.core.JOINER_LEAD = trial.joiner_lead
        self:log("parameter: joiner lead =", trial.joiner_lead)
    end
    self:log("state: connected =", tostring(self:connected()),
        "- power save:", self:radioState(), "- cell:", self:cell())
end

--[[--
Moves this device onto the other transport, the way the menu does.

Running the setup script and stopping there is not switching transports,
and the first run of this benchmark proved it by measuring nothing at all:
fourteen direct-link trials, every one of them NEVER RECONNECTED, and
`rebuilds 0` on both devices throughout. The script had done its half --
the interface was in IBSS mode at the right address, verified -- but Duo
had not been told, so it still believed it was on the house Wi-Fi. It went
on dialling the router's address for the peer, and its repair asked
`directLinkRole()`, got nothing, and answered "not ours" every time. The
joiner's lead being swept from zero to twelve was swept past code that
never ran.

So this goes through the plugin's own switch, which sets the role, sets the
address, runs the script and starts Duo again over it.
--]]--
function Benchmark:switchTransport(to)
    local began = self.now()
    if to == "direct" then
        self:log("switching to the direct link as", self.role)
    else
        self:log("putting the wi-fi back")
    end
    if not self.switch then
        self:log("no way to switch transports; this trial measures nothing")
        return
    end
    local ok, err = pcall(self.switch, to)
    self:log(("the switch took %.1fs"):format(self.now() - began),
        ok and "" or ("- it went wrong: " .. tostring(err)))
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
    record.cell = self:cell()
    self.results[#self.results + 1] = record
    self:log(("result: %s%s - dials %d, rebuilds %d, sleeps noticed %d, cell %s"):format(
        outcome,
        seconds and (" in %.1fs"):format(seconds) or "",
        record.dials, record.rebuilds, record.sleeps, record.cell))
    self.last_result = ("last: %s%s"):format(
        outcome, seconds and (" in %.1fs"):format(seconds) or "")
    self:say(("Duo benchmark %d/%d\n%s\n%s"):format(
        record.index, #self.trials, record.trial.label, self.last_result))
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
    self:log(("%-34s %-22s %8s %6s %8s %-18s"):format(
        "trial", "outcome", "seconds", "dials", "rebuilds", "cell"))
    for _, record in ipairs(self.results) do
        self:log(("%-34s %-22s %8s %6d %8d %-18s"):format(
            record.trial.label, record.outcome,
            record.seconds and ("%.1f"):format(record.seconds) or "-",
            record.dials, record.rebuilds, record.cell))
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
