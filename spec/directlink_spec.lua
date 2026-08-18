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

--[[--
A fake `iw` whose interface reports the given mode once asked.

`info` carries an `ssid` line as the real one does when a cell has been
joined, because that is the only thing telling a joined cell from an
interface merely switched to ad-hoc — `set type ibss` reports `type IBSS`
straight away, join or no join. Pass `joined = false` for the case that
distinction exists for.
--]]--
local function iwThatSettlesOn(mode, joined)
    local ssid = ""
    if joined ~= false then ssid = "\n\tssid KOReaderDuo" end
    return ([[
if [ "$1" = "dev" ] && [ "$3" = "info" ]; then printf '\ttype %s%s\n' "%s" "%s"; exit 0; fi
if [ "$1" = "dev" ] && [ "$3" = "link" ]; then echo "Not connected."; exit 0; fi
]]):format("%s", "%s", mode, ssid) .. IW_LIST_AP
end

T.describe("probing what a device can do", function()
    T.it("spots a driver that can be an access point", function()
        local environment = fakeEnvironment{ iw = IW_LIST_AP, wpa_supplicant = "exit 0" }
        local output = runScript(environment, "probe")
        T.assertEquals(field(output, "mode_ap"), "yes")
        T.assertEquals(field(output, "mode_ibss"), "yes")
        T.assertEquals(field(output, "method"), "ap")
        T.assertMatch(field(output, "verdict"), "host the link")
    end)

    T.it("does not trust a driver's AP mode when wpa_supplicant cannot drive it", function()
        --[[
        The case that cost a real afternoon. `iw phy` lists AP, so the
        device looks capable; the wpa_supplicant Kindle firmware ships was
        built without CONFIG_AP, so the network never appears and nothing
        says why. Choosing ad-hoc up front beats failing over to it after a
        timeout, and the verdict has to name the half that is missing.
        ]]
        local environment = fakeEnvironment{
            iw = IW_LIST_AP,
            -- The giveaway: that message is compiled in only when the
            -- feature is not.
            wpa_supplicant = "# AP mode support not included in the build\nexit 0",
        }
        local output = runScript(environment, "probe")
        T.assertEquals(field(output, "mode_ap"), "yes", "the driver really can")
        T.assertEquals(field(output, "wpa_ap"), "no", "the software really cannot")
        T.assertEquals(field(output, "method"), "ibss")
        T.assertMatch(output, "built without it")
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

    T.it("puts the interface back to managed, not just down", function()
        --[[
        The reason handing control back meant a reboot, or toggling
        airplane mode by hand and restarting the reader. An interface left
        in ad-hoc is one the system's Wi-Fi daemon cannot use, and it never
        says so — it simply never connects.
        ]]
        local environment = fakeEnvironment{
            iw = iwThatSettlesOn("IBSS"), ip = "exit 0", ["lipc-set-prop"] = "exit 0",
        }
        local output = runScript(environment, "restore --dry-run")
        T.assertMatch(output, "ibss leave", "leave the cell before changing the mode")
        T.assertMatch(output, "set type managed")
        T.assertMatch(output, "link set wlan0 down", "nl80211 wants it down to change type")
        T.assertMatch(output, "link set wlan0 up")
    end)

    T.it("flicks the device's own Wi-Fi switch, both properties and both ways", function()
        -- The airplane-mode toggle, done for you. Two properties, not one,
        -- and in KOReader's own order.
        local environment = fakeEnvironment{
            iw = iwThatSettlesOn("IBSS"), ip = "exit 0", ["lipc-set-prop"] = "exit 0",
        }
        local output = runScript(environment, "restore --dry-run")
        T.assertMatch(output, "com%.lab126%.wifid enable 0")
        T.assertMatch(output, "com%.lab126%.cmd wirelessEnable 0")
        T.assertMatch(output, "com%.lab126%.wifid enable 1")
        T.assertMatch(output, "com%.lab126%.cmd wirelessEnable 1")
        T.assertTrue(output:find("wifid enable 0") < output:find("wifid enable 1"),
            "off before on, or the toggle is not a toggle")
    end)

    T.it("says nothing about lipc on a device that has none", function()
        local environment = fakeEnvironment{ iw = iwThatSettlesOn("IBSS"), ip = "exit 0" }
        local output = runScript(environment, "restore --dry-run")
        T.assertTrue(not output:find("lipc"), "a desktop has no Kindle switch to flick")
        T.assertMatch(output, "set type managed", "but the interface still has to go back")
    end)

    T.it("hands Wi-Fi back on restore", function()
        local environment = fakeEnvironment{
            iw = IW_LIST_AP, ip = "exit 0", iwconfig = "exit 0",
            stop = "exit 0", start = "exit 0",
        }
        local output = runScript(environment, "restore --dry-run")
        T.assertMatch(output, "killall wpa_supplicant")
        T.assertMatch(output, "iw dev wlan0 set type managed",
            "iw is the right tool for the job where it exists")
        T.assertMatch(output, "start wifid")
    end)

    T.it("falls back to iwconfig on a device with no iw", function()
        -- The WEXT world. `ip` comes from the test machine's own PATH here,
        -- so only the wireless half of the fallback is what this checks.
        local environment = fakeEnvironment{ iwconfig = "exit 0" }
        local output = runScript(environment, "restore --dry-run")
        T.assertMatch(output, "iwconfig wlan0 mode managed")
        T.assertTrue(not output:find("set type managed"),
            "there is no iw on this device to use")
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

T.describe("checking the link actually came up", function()
    --[[
    The failure that sent somebody looking for a network that was not
    there. Every command can succeed while the radio quietly does nothing:
    wpa_supplicant forks into the background before it finds out the driver
    will not do AP mode, and the script used to announce "this device is
    hosting the link" on the strength of having run it.
    ]]

    --- An `iw` that reports the driver can do AP, but whose interface never
    --- leaves managed mode — which is what a wpa_supplicant built without
    --- AP support looks like from the outside.
    T.it("reports an error instead of a link that never appeared", function()
        local environment = fakeEnvironment{
            iw = iwThatSettlesOn("managed"),
            wpa_supplicant = "exit 0",   -- forks happily, achieves nothing
            ip = "exit 0",
        }
        local output = runScript(environment, "host")
        T.assertMatch(output, "error:", "a link that never came up must not read as success")
        T.assertMatch(output, "never came up as ap")
        T.assertTrue(not output:find("This device is hosting the link"),
            "it announced a network nobody can see")
    end)

    T.it("falls back to ad-hoc when access point mode does not take", function()
        -- The driver says it can be an access point; the interface says
        -- otherwise until it is asked to be ad-hoc instead. Two readers do
        -- not care which of the two they got.
        local iw = [[
if [ "$1" = "dev" ] && [ "$3" = "info" ]; then
    if [ -f "$DUO_RUN_DIR/became-ibss" ]; then printf '\ttype IBSS\n\tssid KOReaderDuo\n'; else printf '\ttype managed\n'; fi
    exit 0
fi
if [ "$1" = "dev" ] && [ "$2" = "wlan0" ] && [ "$3" = "set" ]; then
    mkdir -p "$DUO_RUN_DIR"; : > "$DUO_RUN_DIR/became-ibss"; exit 0
fi
if [ "$1" = "dev" ] && [ "$3" = "link" ]; then echo "Not connected."; exit 0; fi
]] .. IW_LIST_AP
        local environment = fakeEnvironment{
            iw = iw, wpa_supplicant = "exit 0", ip = "exit 0",
        }
        local output = runScript(environment, "host")
        T.assertMatch(output, "trying ad%-hoc instead")
        T.assertMatch(output, "verified: wlan0 is IBSS")
        T.assertMatch(output, "This device is hosting the link")
        T.assertTrue(not output:find("\nerror:"), "a link that came up must not report an error")
    end)

    T.it("warns that an ad-hoc cell will not show up in most Wi-Fi lists", function()
        -- The complaint this exists for: the reader says it is hosting, the
        -- laptop scans, and the network is nowhere. An ad-hoc cell is not
        -- broken, it is simply invisible to most clients, and the device
        -- that made one should say so rather than leave people hunting.
        local environment = fakeEnvironment{
            iw = iwThatSettlesOn("IBSS"), ip = "exit 0",
        }
        local output = runScript(environment, "host")
        T.assertMatch(output, "mode=IBSS")
        T.assertMatch(output, "not an access point")
        T.assertMatch(output, "will not list it when they scan")
    end)

    T.it("says nothing about ad-hoc when it really is an access point", function()
        local environment = fakeEnvironment{
            iw = iwThatSettlesOn("AP"), wpa_supplicant = "exit 0", ip = "exit 0",
        }
        local output = runScript(environment, "host")
        T.assertMatch(output, "mode=AP")
        T.assertTrue(not output:find("ad%-hoc cell"),
            "an access point must not be described as an ad-hoc cell")
    end)

    T.it("says so plainly when the interface does come up", function()
        local environment = fakeEnvironment{
            iw = iwThatSettlesOn("AP"),
            wpa_supplicant = "exit 0",
            ip = "exit 0",
        }
        local output = runScript(environment, "host")
        T.assertTrue(not output:find("error:"), "a working link must not report an error")
        T.assertMatch(output, "verified: wlan0 is AP")
        T.assertMatch(output, "This device is hosting the link")
    end)
end)

T.describe("coming back after a sleep", function()
    T.it("reports the mode in the words the plugin reads", function()
        --[[
        The live bug. `status` printed the mode as its own reworded line,
        while the plugin was looking for what `host` prints — so the check
        for "did the link survive the sleep" could never match, whatever
        the interface was actually doing.
        ]]
        local environment = fakeEnvironment{
            iw = iwThatSettlesOn("IBSS"), ip = "exit 0",
        }
        local output = runScript(environment, "status")
        T.assertMatch(output, "mode=IBSS")
    end)

    T.it("names the cell, so two readers rebuilding at once land in the same one", function()
        --[[
        An ad-hoc cell is identified by a BSSID, and a device forming one
        invents a random address for it. Two readers waking together each
        invent their own and sit in two cells of the same name that never
        merge: both screens look right and no traffic passes.
        ]]
        local environment = fakeEnvironment{
            iw = iwThatSettlesOn("IBSS"), ip = "exit 0",
        }
        local output = runScript(environment, "host --dry-run")
        T.assertMatch(output, "ibss join KOReaderDuo 2437 fixed%-freq 02:44:55:4f:00:01")
    end)
end)

os.execute("rm -rf " .. FAKE_BIN)
os.exit(T.run())
