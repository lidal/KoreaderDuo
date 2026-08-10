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

return NetUtil
