--[[--
The router-free link setup script.

Two things are checked here without any Wi-Fi hardware:

  * that the probe reads a driver's capabilities correctly and picks the
    right method — access point, ad-hoc, old-style ad-hoc, or "this device
    cannot", which is the answer that matters most because it is the one
    that stops somebody breaking their Wi-Fi for nothing;
  * that each method issues the commands it should, via --dry-run.

The capability fixtures are real `iw list` output shapes.
--]]--

local T = require("spec/testrunner")

local SCRIPT = "duo.koplugin/tools/duo-direct-link.sh"
local FAKE_BIN = (os.getenv("DUO_LOG_DIR") or "/tmp") .. "/duo-fakebin"

--- Builds a PATH containing only the tools we say the device has.
-- Each fake tool prints a fixture, which is how a driver's capabilities are
-- simulated.
local function fakeEnvironment(tools)
    os.execute("rm -rf " .. FAKE_BIN .. " && mkdir -p " .. FAKE_BIN)
    for name, body in pairs(tools) do
        local file = assert(io.open(FAKE_BIN .. "/" .. name, "w"))
        file:write("#!/bin/sh\n" .. body .. "\n")
        file:close()
        os.execute("chmod +x " .. FAKE_BIN .. "/" .. name)
    end
    -- coreutils the script itself needs, kept out of the way of the fakes.
    return ("PATH=%s:/usr/bin:/bin DUO_IFACE=wlan0 DUO_RUN_DIR=%s/run "):format(
        FAKE_BIN, FAKE_BIN)
end

local function runScript(environment, arguments)
    local pipe = assert(io.popen(environment .. "sh " .. SCRIPT .. " " .. arguments .. " 2>&1"))
    local output = pipe:read("*a")
    pipe:close()
    return output
end

local function field(output, key)
    return output:match("\n?" .. key .. "=([^\n]*)")
end

local IW_LIST_AP = [[
cat <<'EOF'
Wiphy phy0
	max # scan SSIDs: 4
	Supported interface modes:
		 * IBSS
		 * managed
		 * AP
		 * AP/VLAN
		 * monitor
	Band 1:
		Capabilities: 0x1062
EOF
]]

local IW_LIST_IBSS_ONLY = [[
cat <<'EOF'
Wiphy phy0
	Supported interface modes:
		 * IBSS
		 * managed
	Band 1:
		Capabilities: 0x1062
EOF
]]

local IW_LIST_MANAGED_ONLY = [[
cat <<'EOF'
Wiphy phy0
	Supported interface modes:
		 * managed
	Band 1:
EOF
]]

local IW_LIST_P2P_ONLY = [[
cat <<'EOF'
Wiphy phy0
	Supported interface modes:
		 * managed
		 * P2P-client
		 * P2P-GO
	Band 1:
EOF
]]

T.describe("probing what a device can do", function()
    T.it("spots a driver that can be an access point", function()
        local environment = fakeEnvironment{ iw = IW_LIST_AP, wpa_supplicant = "exit 0" }
        local output = runScript(environment, "probe")
        T.assertEquals(field(output, "mode_ap"), "yes")
        T.assertEquals(field(output, "mode_ibss"), "yes")
        T.assertEquals(field(output, "method"), "ap")
        T.assertMatch(field(output, "verdict"), "host the link")
    end)

    T.it("falls back to ad-hoc when there is no access point mode", function()
        local environment = fakeEnvironment{ iw = IW_LIST_IBSS_ONLY, wpa_supplicant = "exit 0" }
        local output = runScript(environment, "probe")
        T.assertEquals(field(output, "mode_ap"), "no")
        T.assertEquals(field(output, "mode_ibss"), "yes")
        T.assertEquals(field(output, "method"), "ibss")
    end)

    T.it("says nothing can be hosted, but names Wi-Fi Direct when it is there", function()
        -- Neither mode Duo drives, but a lead worth handing over rather
        -- than a flat no: a P2P group is still a network to pair across.
        local environment = fakeEnvironment{ iw = IW_LIST_P2P_ONLY, wpa_supplicant = "exit 0" }
        local output = runScript(environment, "probe")
        T.assertEquals(field(output, "mode_ap"), "no")
        T.assertEquals(field(output, "mode_ibss"), "no")
        T.assertEquals(field(output, "mode_p2p_go"), "yes")
        T.assertEquals(field(output, "method"), "none",
            "Duo does not set a P2P group up, so it must not claim it can")
        T.assertMatch(field(output, "verdict"), "Wi%-Fi Direct")
    end)

    T.it("does not mention Wi-Fi Direct on a driver that has none", function()
        local environment = fakeEnvironment{ iw = IW_LIST_MANAGED_ONLY }
        local output = runScript(environment, "probe")
        T.assertEquals(field(output, "mode_p2p_go"), "no")
        T.assertEquals(field(output, "method"), "none")
        T.assertTrue(not field(output, "verdict"):find("Direct"),
            "no point naming a way out the device does not have")
    end)

    T.it("tries old-style ad-hoc when the driver predates nl80211", function()
        -- No iw at all: the WEXT world, where iwconfig is the only way in.
        local environment = fakeEnvironment{ iwconfig = "exit 0" }
        local output = runScript(environment, "probe")
        T.assertEquals(field(output, "wext"), "yes")
        T.assertEquals(field(output, "method"), "ibss-wext")
    end)

    T.it("says so plainly when the device cannot do it", function()
        local environment = fakeEnvironment{ iw = IW_LIST_MANAGED_ONLY }
        local output = runScript(environment, "probe")
        T.assertEquals(field(output, "method"), "none")
        T.assertMatch(field(output, "verdict"), "hotspot")
        -- And refuses to touch anything.
        local attempt = runScript(environment, "host")
        T.assertMatch(attempt, "cannot create its own Wi%-Fi link")
    end)

    T.it("reports which tools are present", function()
        local environment = fakeEnvironment{ iw = IW_LIST_AP }
        local output = runScript(environment, "probe")
        T.assertEquals(field(output, "tool_iw"), "yes")
        T.assertEquals(field(output, "tool_hostapd"), "no")
        T.assertEquals(field(output, "interface"), "wlan0")
    end)
end)

T.describe("bringing the link up", function()
    T.it("hosts an access point and takes the fixed address", function()
        local environment = fakeEnvironment{ iw = IW_LIST_AP, wpa_supplicant = "exit 0", ip = "exit 0" }
        local output = runScript(environment, "host --dry-run")
        T.assertMatch(output, "method:%s+ap")
        T.assertMatch(output, "address:%s+169%.254%.13%.1")
        T.assertMatch(output, "mode=2")             -- access point
        T.assertMatch(output, "wpa_supplicant %-B")
        T.assertMatch(output, "ip addr add 169%.254%.13%.1/16")
    end)

    T.it("joins as a client of that access point", function()
        local environment = fakeEnvironment{ iw = IW_LIST_AP, wpa_supplicant = "exit 0", ip = "exit 0" }
        local output = runScript(environment, "join --dry-run")
        T.assertMatch(output, "address:%s+169%.254%.13%.2")
        T.assertMatch(output, "mode=0")             -- ordinary client
        T.assertMatch(output, "ip addr add 169%.254%.13%.2/16")
    end)

    T.it("uses ad-hoc symmetrically when that is all there is", function()
        local environment = fakeEnvironment{ iw = IW_LIST_IBSS_ONLY, ip = "exit 0" }
        local host = runScript(environment, "host --dry-run")
        local join = runScript(environment, "join --dry-run")
        for _, output in ipairs({ host, join }) do
            T.assertMatch(output, "iw dev wlan0 set type ibss")
            T.assertMatch(output, "ibss join KOReaderDuo")
        end
        -- Same network, different addresses: no DHCP server anywhere.
        T.assertMatch(host, "169%.254%.13%.1/16")
        T.assertMatch(join, "169%.254%.13%.2/16")
    end)

    T.it("uses iwconfig on an old driver", function()
        local environment = fakeEnvironment{ iwconfig = "exit 0", ifconfig = "exit 0" }
        local output = runScript(environment, "host --dry-run")
        T.assertMatch(output, "iwconfig wlan0 mode ad%-hoc")
        T.assertMatch(output, "iwconfig wlan0 essid KOReaderDuo")
        T.assertMatch(output, "iwconfig wlan0 channel 6")
    end)

    T.it("can be told to address the interface with ifconfig", function()
        -- Some busybox builds have an `ip` that exists but cannot add an
        -- address, so the tool has to be forceable.
        local environment = fakeEnvironment{ iwconfig = "exit 0", ifconfig = "exit 0" }
        local output = runScript(environment .. "DUO_ADDR_TOOL=ifconfig ", "host --dry-run")
        T.assertMatch(output, "ifconfig wlan0 169%.254%.13%.1 netmask 255%.255%.0%.0")
        T.assertNil(output:match("ip addr add"), "ip was used despite the override")
    end)

    T.it("stops the system's own Wi-Fi daemon before taking over", function()
        local environment = fakeEnvironment{
            iw = IW_LIST_AP, wpa_supplicant = "exit 0", ip = "exit 0",
            stop = "exit 0", start = "exit 0",
        }
        local output = runScript(environment, "host --dry-run")
        T.assertMatch(output, "stop wifid")
        T.assertMatch(output, "killall wpa_supplicant")
    end)

    T.it("hands Wi-Fi back on restore", function()
        local environment = fakeEnvironment{
            iw = IW_LIST_AP, ip = "exit 0", iwconfig = "exit 0",
            stop = "exit 0", start = "exit 0",
        }
        local output = runScript(environment, "restore --dry-run")
        T.assertMatch(output, "killall wpa_supplicant")
        T.assertMatch(output, "iwconfig wlan0 mode managed")
        T.assertMatch(output, "start wifid")
    end)

    T.it("changes nothing at all in a dry run", function()
        local environment = fakeEnvironment{ iw = IW_LIST_AP, wpa_supplicant = "exit 0", ip = "exit 0" }
        local output = runScript(environment, "host --dry-run")
        -- Every state-changing line is announced, never executed.
        for line in output:gmatch("[^\n]+") do
            if line:match("^ip ") or line:match("^iw ") or line:match("^wpa_supplicant") then
                error("a command escaped the dry run: " .. line)
            end
        end
        local handle = io.open(FAKE_BIN .. "/run/wpa_supplicant.conf", "r")
        if handle then
            handle:close()
            error("the dry run wrote a config file")
        end
    end)
end)

os.execute("rm -rf " .. FAKE_BIN)
os.exit(T.run())
