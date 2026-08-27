--[[--
Network odds and ends: finding our own address and getting through the
Kindle's firewall.

@module duo.netutil
--]]--

local socket = require("socket")

local NetUtil = {}

--[[--
Picks this device's address out of the output of `ip addr` or `ifconfig`.

Both spellings have to be understood: `ifconfig` on older readers prints
`inet addr:192.168.1.5`, while `ip` and newer `ifconfig` print
`inet 192.168.1.5/24`.

A routable address wins over a link-local one when the device has both;
when a direct reader-to-reader link is the only network there is, the
169.254 address *is* the answer.

@string text command output
@treturn string an address, or nil
--]]--
function NetUtil.parseAddresses(text)
    local routable, link_local
    for _, pattern in ipairs({ "inet%s+addr:%s*(%d+%.%d+%.%d+%.%d+)",
                               "inet%s+(%d+%.%d+%.%d+%.%d+)" }) do
        for ip in tostring(text or ""):gmatch(pattern) do
            if not ip:match("^127%.") then
                if ip:match("^169%.254%.") then
                    link_local = link_local or ip
                else
                    routable = routable or ip
                end
            end
        end
        if routable then return routable end
    end
    return routable or link_local
end

--- Best guess at this device's address on the local network.
-- A connected UDP socket sends no packets, but the kernel still picks the
-- interface it would use. That fails when there is no route off the link,
-- which is the normal state of two readers talking only to each other, so
-- the interface list is the fallback.
-- @treturn string an IPv4 address, or nil when the device has no network
function NetUtil.getLocalIP()
    local udp = socket.udp()
    if udp then
        udp:settimeout(0)
        -- Any off-link address works; nothing is transmitted.
        local ok = udp:setpeername("203.0.113.1", 9)
        if ok then
            local ip = udp:getsockname()
            udp:close()
            if ip and ip ~= "0.0.0.0" and ip ~= "*" then
                return ip
            end
        else
            udp:close()
        end
    end

    for _, command in ipairs({ "ip -4 -o addr show 2>/dev/null", "ifconfig 2>/dev/null" }) do
        local pipe = io.popen(command)
        if pipe then
            local output = pipe:read("*a") or ""
            pipe:close()
            local ip = NetUtil.parseAddresses(output)
            if ip then return ip end
        end
    end
    return nil
end

--- Broadcast addresses worth probing for a device holding `ip`, used on
-- networks that drop 255.255.255.255.
-- @treturn table array of addresses (possibly empty)
function NetUtil.getBroadcastAddresses(ip)
    if not ip then return {} end
    local a, b, c = ip:match("^(%d+)%.(%d+)%.(%d+)%.%d+$")
    if not a then return {} end
    local addresses = { string.format("%s.%s.%s.255", a, b, c) }
    if a == "169" and b == "254" then
        -- Link-local is a /16, which is what a router-free direct link
        -- between two readers uses.
        addresses[#addresses+1] = "169.254.255.255"
    end
    return addresses
end

--- The /24 broadcast address for `ip`.
function NetUtil.getBroadcastAddress(ip)
    return NetUtil.getBroadcastAddresses(ip)[1]
end

--- True when `address` looks like a usable IPv4 literal.
function NetUtil.isValidIP(address)
    if type(address) ~= "string" then return false end
    local octets = { address:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$") }
    if #octets ~= 4 then return false end
    for _, octet in ipairs(octets) do
        if tonumber(octet) > 255 then return false end
    end
    return true
end

--- Resolves a host name to an address, or returns nil when it cannot.
-- Only ever called once per connection attempt, never from the poll loop,
-- because a name lookup can block for a moment.
function NetUtil.resolve(name)
    if NetUtil.isValidIP(name) then return name end
    if not name or name == "" then return nil end
    local ok, address = pcall(function()
        return socket.dns.toip(name)
    end)
    if ok and address and NetUtil.isValidIP(address) then
        return address
    end
    return nil
end

-- Kindles ship with a default-deny INPUT chain, so a listening socket is
-- invisible until a hole is opened. Same approach the HTTP inspector plugin
-- uses; the rules are removed again when Duo stops.
local function iptables(action, port)
    for _, protocol in ipairs({ "tcp", "udp" }) do
        os.execute(string.format(
            "iptables -%s INPUT -p %s --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT 2>/dev/null",
            action, protocol, port))
        os.execute(string.format(
            "iptables -%s OUTPUT -p %s --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT 2>/dev/null",
            action, protocol, port))
    end
end

function NetUtil.openFirewall(port)
    iptables("A", port)
end

function NetUtil.closeFirewall(port)
    iptables("D", port)
end

--------------------------------------------------------------------------
-- Keeping the radio awake
--------------------------------------------------------------------------

--[[--
The wireless interface, by the names readers use for it.

Kept to a short list rather than asked of the system, because this runs on a
device where `iw` may not exist and the answer is one of four names anyway.
--]]--
local WIFI_INTERFACES = { "wlan0", "wlan1", "mlan0", "eth0" }

local function wirelessInterface()
    for _, name in ipairs(WIFI_INTERFACES) do
        local handle = io.open("/sys/class/net/" .. name .. "/wireless", "r")
            or io.open("/sys/class/net/" .. name .. "/phy80211/name", "r")
        if handle then
            handle:close()
            return name
        end
    end
    return nil
end

--[[--
Turns the wireless card's power saving off, or puts it back.

Why this exists. A reader associated to a router sleeps its radio between
beacons and lets the router hold anything that arrives meanwhile, handing it
over at the next DTIM -- a tenth of a second on a good router and several
times that on an ordinary one. A page turn is one small packet each way, so
it can wait for that twice, and the reader feels it. A transfer never does,
because the traffic is constant and the radio never gets to sleep, which is
why the two symptoms have different causes and only one of them is this.

None of it applies to a link the two devices make between themselves: the
device hosting it cannot sleep, because it has to send the beacons, and an
ad-hoc cell has no router holding anything back. That is a large part of why
a direct link feels immediate and the same pair through a router does not.

Both spellings are tried. `iw` is the modern one and is missing from some
firmwares; `iwconfig` is the old one and is present on most Kindles. Failure
is silent on purpose: a device that will not turn power saving off still
works, just less briskly, and there is nothing useful to say to somebody
about a knob their firmware does not have.

@bool awake  true to keep the radio awake, false to hand it back
@treturn ?string  the interface it was applied to, or nil
--]]--
--- os.execute reports a status number on 5.1 and a boolean on 5.2 and up.
local function worked(status)
    if status == true then return true end
    if status == 0 then return true end
    return false
end

--[[--
Stops the wireless card dozing between beacons, or lets it doze again.

One command, not two. `iwconfig` is here as a fallback for drivers whose
`iw` does not understand `power_save`, and running both for one decision
meant poking the radio twice -- on hardware that may answer a power-save
change by re-associating, which drops the link Duo was holding open.

@bool awake  true to keep the radio responsive, false to hand it back
@treturn ?string  the interface, or nil when there is no wireless one
@treturn string   which tool was used
@treturn boolean  whether it reported success
--]]--
function NetUtil.setRadioAlwaysOn(awake)
    local iface = wirelessInterface()
    if not iface then return nil end
    local setting = awake and "off" or "on"
    local status = os.execute(
        ("iw dev %s set power_save %s >/dev/null 2>&1"):format(iface, setting))
    if worked(status) then return iface, "iw", true end
    status = os.execute(
        ("iwconfig %s power %s >/dev/null 2>&1"):format(iface, setting))
    return iface, "iwconfig", worked(status)
end

--[[--
Reads power saving out of a driver's own words.

Both tools are covered because both are asked. `iw dev wlan0 get power_save`
says `Power save: on`; `iwconfig wlan0` says `Power Management:on` somewhere
in a paragraph about the association, and older builds spell it with an `=`.
Some drivers answer `Power Management:off` and mean it, and some print the
line without a value at all, which is a driver saying it does not know.

Backwards from what it reads, deliberately: this returns whether the radio
is being *kept awake*, which is power saving being off, so that it can be
compared with what Duo asked for without anybody having to invert it in
their head at the call site.

@string output  what the tool printed
@treturn ?boolean  true if the radio is kept awake, false if it is dozing,
    nil if the output does not say
--]]--
function NetUtil.parsePowerSave(output)
    if not output then return nil end
    local state = output:lower():match("power%s*save[:=]%s*(%a+)")
        or output:lower():match("power%s*management[:=]%s*(%a+)")
    if state == "off" then return true end
    if state == "on" then return false end
    return nil
end

--[[--
Asks the card whether power saving is on, rather than assuming it stayed
where it was put.

It does not stay. A driver reapplies its defaults when the interface
re-associates, and a reader re-associates every time it wakes from sleep, so
a `set` from before the sleep is gone and nothing announces that it went.
The only way to know is to read it back.

Silent when neither tool answers, and `nil` rather than a guess: a caller
that cannot tell should leave the radio alone, not poke it on a hunch.

@treturn ?boolean  true if kept awake, false if dozing, nil if unknown
@treturn ?string   the interface it asked about
@treturn ?string   which tool answered
--]]--
function NetUtil.radioIsAwake()
    local iface = wirelessInterface()
    if not iface then return nil end
    for _, attempt in ipairs({
        { tool = "iw", command = "iw dev %s get power_save 2>/dev/null" },
        { tool = "iwconfig", command = "iwconfig %s 2>/dev/null" },
    }) do
        local pipe = io.popen(attempt.command:format(iface))
        if pipe then
            local output = pipe:read("*a")
            pipe:close()
            local state = NetUtil.parsePowerSave(output)
            if state ~= nil then return state, iface, attempt.tool end
        end
    end
    return nil, iface
end

return NetUtil
