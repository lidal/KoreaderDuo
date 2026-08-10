--[[--
Network odds and ends: finding our own address and getting through the
Kindle's firewall.

@module duo.netutil
--]]--

local socket = require("socket")

local NetUtil = {}

--- Best guess at this device's address on the local network.
-- A connected UDP socket sends no packets, but the kernel still picks the
-- interface it would use, which is exactly the address we want to show the
-- user. Falls back to parsing `ip`/`ifconfig` when there is no route out.
-- @treturn string an IPv4 address, or nil when the device is offline
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
            for ip in output:gmatch("inet%s+addr?:?%s*(%d+%.%d+%.%d+%.%d+)") do
                if not ip:match("^127%.") then
                    return ip
                end
            end
        end
    end
    return nil
end

--- The /24 broadcast address for `ip`, used as an extra discovery probe on
-- networks that drop 255.255.255.255.
function NetUtil.getBroadcastAddress(ip)
    if not ip then return nil end
    local a, b, c = ip:match("^(%d+)%.(%d+)%.(%d+)%.%d+$")
    if not a then return nil end
    return string.format("%s.%s.%s.255", a, b, c)
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
