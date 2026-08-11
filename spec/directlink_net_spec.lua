--[[--
Two devices on their own link, with no router and no DHCP.

This is the network the direct-link script creates: two readers joined to
each other, each with a static link-local address, nothing else on the wire.
Two network namespaces joined by a veth pair reproduce exactly that, so
everything above the radio — the search broadcast, the connection, the
spread — is tested under the real conditions.

The radio itself cannot be simulated. What this proves is that once two
Kindles are on the same link by whatever means, Duo needs nothing else:
no router, no DHCP server, no address typed in by hand.

Needs root and iproute2; skips itself otherwise.
--]]--

local T = require("spec/testrunner")
local Controller = require("spec/harness/controller")

local interpreter = arg and arg[-1] or "luajit"

local NS_HOST = "duo-host"       -- the device hosting the link
local NS_JOIN = "duo-join"       -- the device that joined it
local HOST_IP = "169.254.13.1"   -- the addresses duo-direct-link.sh assigns
local JOIN_IP = "169.254.13.2"
local DUO_PORT = 19980
local DISCOVERY_PORT = 19981

local function shell(command)
    local pipe = io.popen(command .. " 2>&1; echo EXIT=$?")
    local output = pipe:read("*a")
    pipe:close()
    return output:match("EXIT=(%d+)") == "0", output
end

local function canRunNamespaces()
    local ok = shell("id -u | grep -q '^0$'")
    if not ok then return false, "not root" end
    if not shell("command -v ip") then return false, "iproute2 missing" end
    if not shell("ip netns add duo-probe && ip netns del duo-probe") then
        return false, "network namespaces unavailable"
    end
    return true
end

local function teardownNetwork()
    shell(("ip netns del %s"):format(NS_HOST))
    shell(("ip netns del %s"):format(NS_JOIN))
end

--- Builds the link the direct-link script would leave behind.
local function setupNetwork()
    teardownNetwork()
    local steps = {
        ("ip netns add %s"):format(NS_HOST),
        ("ip netns add %s"):format(NS_JOIN),
        "ip link add duo-a type veth peer name duo-b",
        ("ip link set duo-a netns %s"):format(NS_HOST),
        ("ip link set duo-b netns %s"):format(NS_JOIN),
        -- Static link-local addressing, /16, exactly as the script assigns.
        ("ip netns exec %s ip addr add %s/16 dev duo-a"):format(NS_HOST, HOST_IP),
        ("ip netns exec %s ip addr add %s/16 dev duo-b"):format(NS_JOIN, JOIN_IP),
        ("ip netns exec %s ip link set duo-a up"):format(NS_HOST),
        ("ip netns exec %s ip link set duo-b up"):format(NS_JOIN),
        ("ip netns exec %s ip link set lo up"):format(NS_HOST),
        ("ip netns exec %s ip link set lo up"):format(NS_JOIN),
    }
    for _, step in ipairs(steps) do
        local ok, output = shell(step)
        if not ok then
            teardownNetwork()
            return false, step .. " -> " .. output
        end
    end
    return true
end

--------------------------------------------------------------------------
-- Outside the namespace: build the link, then re-enter as the host device
--------------------------------------------------------------------------

if os.getenv("DUO_IN_NETNS") ~= "1" then
    local possible, why = canRunNamespaces()
    if not possible then
        print("# " .. why .. " — skipping the direct-link network tests")
        return 0
    end

    local ok, err = setupNetwork()
    if not ok then
        print("# could not build the test link (" .. tostring(err) .. ") — skipping")
        return 0
    end

    -- Re-run this file inside the hosting device's namespace.
    local command = ("DUO_IN_NETNS=1 LUA_PATH=%q ip netns exec %s %s spec/directlink_net_spec.lua"):format(
        "./?.lua;./duo.koplugin/?.lua;;", NS_HOST, interpreter)
    local status = os.execute(command)
    teardownNetwork()
    if type(status) == "boolean" then return status and 0 or 1 end
    if status > 255 then status = math.floor(status / 256) end
    return status
end

--------------------------------------------------------------------------
-- Inside the hosting device's namespace
--------------------------------------------------------------------------

local controller = Controller.new{
    bind = "*",                 -- reachable from both namespaces
    reach_host = HOST_IP,
    first_port = 19100,
    interpreter = interpreter,
}
local host_device = controller:spawn("host-kindle")                       -- this namespace
local join_device = controller:spawn("join-kindle", { namespace = NS_JOIN })

local function configure(device)
    controller:call(device, "Core:stop('reset')")
    controller:call(device, "Core.settings.token = 'D1RECT'")
    controller:call(device, ("Core.settings.port = %d"):format(DUO_PORT))
    controller:call(device, ("Core.settings.peer_port = %d"):format(DUO_PORT))
    controller:call(device, ("Core.settings.discovery_port = %d"):format(DISCOVERY_PORT))
end

T.describe("a link with no router on it", function()
    T.it("really is two separate hosts", function()
        T.assertEquals(controller:call(host_device, "require('duo/netutil').getLocalIP()"), HOST_IP)
        T.assertEquals(controller:call(join_device, "require('duo/netutil').getLocalIP()"), JOIN_IP)
    end)

    T.it("finds the other device by broadcast, with nothing typed in", function()
        configure(host_device)
        configure(join_device)
        controller:call(host_device, "Core:start('master')")

        -- The joining device knows nothing but the port: no address, no DHCP,
        -- no router. It has to shout and see who answers.
        controller:call(join_device, "Core.scan_results = nil")
        controller:call(join_device, "Core:startScan(function(r) Core.scan_results = r end)")
        controller:assertEventually(join_device, "Core.scan_results ~= nil", true, "the search never finished")
        T.assertEquals(controller:call(join_device, "#Core.scan_results"), "1",
            "the master was not found across the link")
        T.assertEquals(controller:call(join_device, "Core.scan_results[1].host"), HOST_IP)
        T.assertEquals(controller:call(join_device, "Core.scan_results[1].name"), "host-kindle")
    end)

    T.it("connects to whatever the search found", function()
        controller:call(join_device,
            "Core:start('slave', { host = Core.scan_results[1].host, port = Core.scan_results[1].port })")
        controller:assertEventually(host_device, "Core:isConnected()", true, "nobody arrived")
        controller:assertEventually(join_device, "Core:isConnected()", true, "did not reach the host")
        T.assertEquals(controller:call(join_device, "Core:getReadyLinks()[1].peer_name"), "host-kindle")
    end)

    T.it("runs the spread over the direct link", function()
        controller:call(host_device, "D:jumpToPage(10)")
        controller:assertEventually(join_device, "D:getPage()", 11, "not showing the next page")

        controller:call(host_device, "D:tapForward()")
        controller:assertEventually(host_device, "D:getPage()", 12)
        controller:assertEventually(join_device, "D:getPage()", 13)

        controller:call(join_device, "D:tapForward()")
        controller:assertEventually(host_device, "D:getPage()", 14, "the tap did not cross the link")
        controller:assertEventually(join_device, "D:getPage()", 15)
    end)

    T.it("comes back by itself when the link drops", function()
        -- The radio going away for a moment, which on two battery-powered
        -- readers sitting on a table is the normal case, not the exception.
        shell(("ip netns exec %s ip link set duo-b down"):format(NS_JOIN))
        -- An interface going down sends no reset, so the only thing that can
        -- notice is the heartbeat running out: allow for PEER_TIMEOUT.
        controller:assertEventually(host_device, "Core:isConnected()", false,
            "the host did not notice", 30)

        shell(("ip netns exec %s ip link set duo-b up"):format(NS_JOIN))
        controller:assertEventually(join_device, "Core:isConnected()", true, "never reconnected", 30)

        controller:call(host_device, "D:jumpToPage(80)")
        controller:assertEventually(join_device, "D:getPage()", 81, "came back on the wrong page")
    end)
end)

local exit_code = T.run()
controller:shutdown()
os.exit(exit_code)
