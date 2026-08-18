--[[--
Two readers on their own Wi-Fi link, with nothing else involved.

This is the self-contained arrangement: one device hosts a link — as an
access point if its driver can, as an ad-hoc network otherwise — and the
other joins it. No router, no phone, no DHCP server, and because the host
always takes 169.254.13.1, no address for anybody to type.

The work itself is done by `tools/duo-direct-link.sh`, which lives next to
this file so it can also be read and run over SSH before anyone trusts it
with their Wi-Fi. This module finds it, runs it, and turns its output into
something worth showing on a screen.

@module duo.directlink
--]]--

local DirectLink = {}

--- The address the hosting device always takes, which is what makes this
-- zero-configuration: the joining device already knows where to look.
DirectLink.HOST_ADDRESS = "169.254.13.1"

--- And the address the joining device takes, for the same reason.
DirectLink.JOIN_ADDRESS = "169.254.13.2"

--- The address this device should be holding, given the role it took.
function DirectLink.addressFor(role)
    if role == "host" then return DirectLink.HOST_ADDRESS end
    if role == "join" then return DirectLink.JOIN_ADDRESS end
    return nil
end

--[[--
Whether a link this device built itself is still standing.

Both halves have to hold. A radio can be in the right mode with its address
flushed, and an address can survive on an interface the system has quietly
taken back into managed mode; either way there is nothing to talk over.

@tparam string status  what `duo-direct-link.sh status` printed
@tparam string role    "host" or "join"
--]]--
function DirectLink.isUp(status, role)
    if not status then return false end
    local mode = DirectLink.modeOf(status)
    if mode ~= "ap" and mode ~= "ibss" then return false end
    local address = DirectLink.addressFor(role)
    return address ~= nil and status:find(address, 1, true) ~= nil
end

local function pluginDirectory()
    -- .../duo.koplugin/duo/directlink.lua -> .../duo.koplugin
    local source = debug.getinfo(1, "S").source:gsub("^@", "")
    local directory = source:match("^(.*)/[^/]*$")
    if not directory then return "." end
    return directory:match("^(.*)/[^/]*$") or directory
end

function DirectLink.scriptPath()
    return pluginDirectory() .. "/tools/duo-direct-link.sh"
end

--- Runs a script command and returns its output.
-- Deliberately synchronous: these are explicit, rare, user-initiated
-- actions that take a second or two, and there is nothing sensible to do
-- with a half-configured network in the meantime.
function DirectLink.run(command)
    local pipe = io.popen(("sh %q %s 2>&1"):format(DirectLink.scriptPath(), command))
    if not pipe then return nil, "could not run the setup script" end
    local output = pipe:read("*a") or ""
    pipe:close()
    return output
end

--- Asks the device what it is capable of.
-- @treturn table { interface=, driver=, method=, verdict=, mode_ap=, ... }
function DirectLink.probe()
    local output, err = DirectLink.run("probe")
    if not output then return nil, err end
    local report = { raw = output }
    for key, value in output:gmatch("([%w_]+)=([^\n]*)") do
        report[key] = value
    end
    return report
end

--- True when this device can make a link of its own at all.
function DirectLink.isPossible(report)
    return report ~= nil and report.method ~= nil and report.method ~= "none"
end

--- A few lines fit for an InfoMessage.
function DirectLink.describe(report)
    if not report then return "Could not ask this device what it can do." end
    local method_names = {
        ap = "access point",
        ibss = "ad-hoc network",
        ["ibss-wext"] = "ad-hoc network (older driver)",
        none = "not possible",
    }
    local lines = {
        ("Wi-Fi interface: %s"):format(report.interface or "?"),
        ("Driver: %s"):format(report.driver or "?"),
        ("Can host a link: %s"):format(method_names[report.method] or report.method or "?"),
        "",
        report.verdict or "",
    }
    return table.concat(lines, "\n")
end

--[[--
Which kind of link actually came up: "ap", "ibss", or nil when the output
does not say.

The two are not interchangeable to anyone standing outside. An ad-hoc cell
carries the spread between two readers perfectly well, but it is not a
network a phone or a laptop will offer in its list — modern Wi-Fi daemons
dropped ad-hoc support altogether. A device that quietly fell back to one
and then told its owner to "join this Wi-Fi network" sent them looking for
something they were never going to find.

@tparam string output  what the script printed
@treturn ?string  "ap", "ibss", or nil
--]]--
function DirectLink.modeOf(output)
    if not output then return nil end
    local mode = output:match("\nmode=([%w%-]+)") or output:match("^mode=([%w%-]+)")
    if not mode then return nil end
    mode = mode:lower()
    if mode == "ap" or mode == "master" then return "ap" end
    if mode == "ibss" or mode == "ad-hoc" then return "ibss" end
    return mode
end

function DirectLink.host()
    return DirectLink.run("host")
end

function DirectLink.join()
    return DirectLink.run("join")
end

function DirectLink.restore()
    return DirectLink.run("restore")
end

return DirectLink
