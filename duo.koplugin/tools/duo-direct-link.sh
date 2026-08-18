#!/bin/sh
#
# duo-direct-link — put two e-readers on their own Wi-Fi link, with no
# router, no DHCP server and no internet.
#
# One device hosts the link and takes 169.254.13.1; the other joins it and
# takes 169.254.13.2. Because the host address is fixed, the joining device
# already knows where to find it: nothing has to be typed on either screen.
#
#   ./duo-direct-link.sh probe            what can this device actually do?
#   ./duo-direct-link.sh host             host the link  (169.254.13.1)
#   ./duo-direct-link.sh join             join the link  (169.254.13.2)
#   ./duo-direct-link.sh status
#   ./duo-direct-link.sh restore          give Wi-Fi back to the system
#
# Add --dry-run to any command to print what would happen and change nothing.
#
# Overrides, for devices that differ: DUO_IFACE, DUO_SSID, DUO_PASSPHRASE,
# DUO_CHANNEL, DUO_FREQUENCY, DUO_HOST_IP, DUO_JOIN_IP, DUO_ADDR_TOOL.
#
# This touches the Wi-Fi interface directly and stops the system's own
# Wi-Fi daemon, so read `probe` output first and keep `restore` in mind.
# Nothing here is permanent: a reboot restores the stock configuration.

set -u

SSID="${DUO_SSID:-KOReaderDuo}"
PASSPHRASE="${DUO_PASSPHRASE:-koreaderduo}"
CHANNEL="${DUO_CHANNEL:-6}"
FREQUENCY="${DUO_FREQUENCY:-2437}"     # channel 6
#[[
# The cell's own address, fixed rather than generated.
#
# An ad-hoc cell is identified by a BSSID, and a device that forms one
# invents a random address for it. Two readers coming back from sleep at the
# same moment therefore each invent their own, and end up in two cells with
# the same name that never merge — everything looks right on both screens
# and no traffic passes. Naming it removes the race entirely.
#
# Locally administered (the 02 prefix), so it cannot collide with real
# hardware.
#]]
BSSID="${DUO_BSSID:-02:44:55:4f:00:01}"
IFACE="${DUO_IFACE:-}"
HOST_IP="${DUO_HOST_IP:-169.254.13.1}"
JOIN_IP="${DUO_JOIN_IP:-169.254.13.2}"
NETMASK_BITS=16
NETMASK="255.255.0.0"
RUN_DIR="${DUO_RUN_DIR:-/tmp/duo-direct}"
DRY_RUN=0

log()  { echo "$*"; }
warn() { echo "warning: $*" >&2; }
die()  { echo "error: $*" >&2; exit 1; }

# Every state-changing command goes through here, so --dry-run is honest.
run() {
    if [ "$DRY_RUN" = "1" ]; then
        echo "would run: $*"
        return 0
    fi
    "$@"
}

run_sh() {
    if [ "$DRY_RUN" = "1" ]; then
        echo "would run: $1"
        return 0
    fi
    sh -c "$1"
}

has() { command -v "$1" >/dev/null 2>&1; }

#--------------------------------------------------------------------------
# Probing
#--------------------------------------------------------------------------

detect_iface() {
    [ -n "$IFACE" ] && { echo "$IFACE"; return; }
    for candidate in wlan0 wlan1 mlan0 eth0; do
        if [ -e "/sys/class/net/$candidate" ]; then
            echo "$candidate"
            return
        fi
    done
    # Anything that is not loopback will do.
    for path in /sys/class/net/*; do
        name=$(basename "$path")
        [ "$name" = "lo" ] && continue
        echo "$name"
        return
    done
    echo ""
}

detect_driver() {
    iface="$1"
    if [ -L "/sys/class/net/$iface/device/driver" ]; then
        basename "$(readlink -f "/sys/class/net/$iface/device/driver")"
    else
        echo "unknown"
    fi
}

# `iw list` reports the modes an nl80211 driver supports. Older readers use
# the WEXT interface instead, where iw reports nothing and iwconfig is the
# only way in — and where AP mode is not available at all.
supported_modes() {
    if has iw; then
        iw list 2>/dev/null | awk '
            /Supported interface modes/ { inside = 1; next }
            /^[[:space:]]*[A-Za-z].*:/ && inside && !/\*/ { inside = 0 }
            inside && /\*/ { gsub(/[* \t]/, ""); print }
        '
    fi
}

#[[
# Whether the wpa_supplicant on this device can actually be an access
# point, which is a different question from whether the driver can.
#
# `iw` reports the driver's capabilities and stops there. Kindle firmware
# ships a stripped wpa_supplicant with CONFIG_AP left out — AP mode drags
# in most of hostapd, so it is the first thing dropped — and the result is
# a device that advertises AP, accepts the configuration, forks into the
# background and then refuses, with the network never appearing.
#
# The build gives itself away. That error string is compiled in only by the
# #else branch, so finding it in the binary means the feature is missing.
#]]
wpa_can_do_ap() {
    binary=$(command -v wpa_supplicant 2>/dev/null) || return 1
    [ -n "$binary" ] || return 1
    grep -q "AP mode support not included" "$binary" 2>/dev/null && return 1
    return 0
}

probe() {
    iface=$(detect_iface)
    [ -n "$iface" ] || die "no network interface found"
    driver=$(detect_driver "$iface")
    modes=$(supported_modes)

    echo "interface=$iface"
    echo "driver=$driver"
    # What a device with no Duo on it would have to join by hand.
    echo "ssid=$SSID"
    echo "passphrase=$PASSPHRASE"
    echo "host_ip=$HOST_IP"
    for tool in iw iwconfig wpa_supplicant hostapd ip ifconfig; do
        if has "$tool"; then echo "tool_$tool=yes"; else echo "tool_$tool=no"; fi
    done

    ap=no
    ibss=no
    p2p_go=no
    for mode in $modes; do
        [ "$mode" = "AP" ] && ap=yes
        [ "$mode" = "IBSS" ] && ibss=yes
        [ "$mode" = "P2P-GO" ] && p2p_go=yes
    done
    echo "mode_ap=$ap"
    echo "mode_ibss=$ibss"
    echo "mode_p2p_go=$p2p_go"

    # Ad-hoc is driven straight through `iw`, so it needs nothing from
    # wpa_supplicant. Access point mode needs everything from it.
    wpa_ap=no
    if has wpa_supplicant && wpa_can_do_ap; then wpa_ap=yes; fi
    echo "wpa_ap=$wpa_ap"

    # WEXT drivers report no modes to iw but can usually still do ad-hoc.
    wext=no
    if [ -z "$modes" ] && has iwconfig; then
        wext=yes
    fi
    echo "wext=$wext"

    if [ "$ap" = yes ] && [ "$wpa_ap" = yes ]; then
        echo "method=ap"
        echo "verdict=This device can host the link by itself. Run: $0 host"
    elif [ "$ibss" = yes ] && has iw; then
        echo "method=ibss"
        if [ "$ap" = yes ]; then
            #[[
            # The confusing case, and the reason the check above exists. The
            # driver says AP, so anyone reading `iw phy` concludes an access
            # point is possible, and it is not. Saying which half is missing
            # saves the next person the afternoon it cost the last one.
            #]]
            echo "verdict=The driver can do access point mode but the wpa_supplicant on this device was built without it, so ad-hoc it is. That works between two readers, and needs nothing from wpa_supplicant, but other devices will not list the network. Run: $0 host"
        else
            echo "verdict=No access point mode, but ad-hoc works, which is just as good for two readers. Run: $0 host"
        fi
    elif [ "$wext" = yes ]; then
        echo "method=ibss-wext"
        echo "verdict=Old-style Wi-Fi driver; ad-hoc is worth trying. Run: $0 host"
    elif [ "$p2p_go" = yes ]; then
        # Wi-Fi Direct can host a group, but joining one means agreeing an
        # SSID and passphrase this script did not choose, so it is a lead to
        # follow by hand rather than something to run.
        echo "method=none"
        echo "verdict=No access point or ad-hoc mode, but this driver does report Wi-Fi Direct (P2P-GO). That is worth trying by hand with wpa_cli p2p_group_add; Duo will pair over it like any other network, but cannot set it up for you. Otherwise use a phone hotspot or any Wi-Fi network."
    else
        echo "method=none"
        echo "verdict=This device cannot make its own link. Use a phone hotspot or any Wi-Fi network instead; Duo works the same over either."
    fi
}

probe_value() {
    probe 2>/dev/null | sed -n "s/^$1=//p"
}

#--------------------------------------------------------------------------
# Bringing the link up
#--------------------------------------------------------------------------

#[[
# Starting and stopping one of the system's services.
#
# `initctl` first. Upstart's bare `start` and `stop` are conveniences that
# are not on every device's PATH, and asking `has stop` on a reader without
# them quietly answers no — so the system's Wi-Fi daemon was never stopped
# at all, and it went on managing the interface underneath a link that
# looked like it had come up.
#]]
service_control() {
    action="$1"
    service="$2"
    if has initctl; then
        run_sh "initctl $action $service >/dev/null 2>&1 || true"
    elif has "$action"; then
        run_sh "$action $service >/dev/null 2>&1 || true"
    fi
}

#[[
# Amazon's Wi-Fi daemons, which have to be out of the way before the
# interface can be borrowed. `wifis` as well as `wifid`: it is the second
# half of the pair on a Kindle and stopping only the first leaves something
# still watching.
#
# Absent elsewhere, which is why failures are ignored rather than fatal —
# but a daemon that is still running after being asked to stop is worth
# saying out loud, because the link will appear to come up and then quietly
# stop working when the daemon takes the interface back.
#]]
stop_system_wifi() {
    if has lipc-set-prop; then
        run_sh "lipc-set-prop -i com.lab126.cmd wirelessEnable 1 >/dev/null 2>&1 || true"
    fi
    for service in wifid wifis cmd_wifid; do
        service_control stop "$service"
    done
    run_sh "killall wpa_supplicant >/dev/null 2>&1 || true"
    run_sh "killall dhclient udhcpc >/dev/null 2>&1 || true"
    sleep_a_moment
    [ "$DRY_RUN" = "1" ] && return 0
    if has pidof && pidof wifid >/dev/null 2>&1; then
        warn "the system's Wi-Fi daemon is still running and will take the interface back"
    fi
}

sleep_a_moment() {
    [ "$DRY_RUN" = "1" ] && return 0
    sleep 1
}

# DUO_ADDR_TOOL forces ip or ifconfig. Worth having: some busybox builds
# ship an `ip` applet that exists but cannot do `addr add`.
set_address() {
    iface="$1"
    address="$2"
    tool="${DUO_ADDR_TOOL:-auto}"
    if [ "$tool" = "ifconfig" ] || { [ "$tool" = "auto" ] && ! has ip; }; then
        has ifconfig || die "ifconfig requested but not available"
        run ifconfig "$iface" "$address" netmask "$NETMASK" up
        log "address $address is up on $iface"
        return
    fi
    if has ip; then
        run_sh "ip addr flush dev $iface 2>/dev/null || true"
        run ip addr add "$address/$NETMASK_BITS" dev "$iface"
        run ip link set "$iface" up
    elif has ifconfig; then
        run ifconfig "$iface" "$address" netmask "$NETMASK" up
    else
        die "neither ip nor ifconfig is available"
    fi
    log "address $address is up on $iface"
}

write_wpa_conf() {
    mode="$1"   # 2 = access point, 1 = ad-hoc
    conf="$RUN_DIR/wpa_supplicant.conf"
    run mkdir -p "$RUN_DIR"
    if [ "$DRY_RUN" = "1" ]; then
        echo "would write $conf (mode=$mode, ssid=$SSID)"
        echo "$conf"
        return 0
    fi
    cat > "$conf" <<EOF
ctrl_interface=$RUN_DIR
ap_scan=2
network={
    ssid="$SSID"
    mode=$mode
    frequency=$FREQUENCY
    key_mgmt=WPA-PSK
    proto=RSN
    pairwise=CCMP
    group=CCMP
    psk="$PASSPHRASE"
}
EOF
    echo "$conf"
}

start_wpa_supplicant() {
    iface="$1"
    conf="$2"
    driver_arg="-Dnl80211"
    if ! has iw; then
        driver_arg="-Dwext"
    fi
    run_sh "wpa_supplicant -B $driver_arg -i $iface -c $conf >$RUN_DIR/wpa.log 2>&1"
    sleep_a_moment
}

bring_up_ibss_wext() {
    iface="$1"
    run_sh "ifconfig $iface down 2>/dev/null || true"
    run iwconfig "$iface" mode ad-hoc
    run iwconfig "$iface" essid "$SSID"
    run iwconfig "$iface" channel "$CHANNEL"
    run_sh "ifconfig $iface up 2>/dev/null || true"
    sleep_a_moment
}

#[[
# Whether the interface has actually joined the cell, rather than merely
# being willing to.
#
# Worth the separate check, and the reason a release once went out that
# could not connect at all: `iw dev X set type ibss` makes the interface
# report `type IBSS` immediately, before any join and whether or not one
# ever succeeds. Anything reading the type therefore reads success the
# moment the mode is set, and a join that failed looks exactly like one
# that worked. The cell's name is the thing that only appears once there
# really is a cell.
#]]
cell_joined() {
    iface="$1"
    if has iw; then
        iw dev "$iface" link 2>/dev/null | grep -qi "SSID: *$SSID" && return 0
        iw dev "$iface" info 2>/dev/null | grep -qi "ssid $SSID" && return 0
    fi
    if has iwconfig; then
        iwconfig "$iface" 2>/dev/null | grep -q "ESSID:\"$SSID\"" && return 0
    fi
    return 1
}

bring_up_ibss_iw() {
    iface="$1"
    run_sh "ip link set $iface down 2>/dev/null || true"
    run iw dev "$iface" set type ibss
    run_sh "ip link set $iface up 2>/dev/null || true"
    sleep_a_moment
    #[[
    # Naming the cell keeps two readers rebuilding at the same moment out
    # of two cells with the same name. Not every `iw` accepts a fixed
    # BSSID, though, and one that does not simply refuses the join — so
    # the plain form is tried after it, judged on whether a cell appeared
    # rather than on what the interface calls itself.
    #]]
    run_sh "iw dev $iface ibss join $SSID $FREQUENCY fixed-freq $BSSID 2>/dev/null || true"
    [ "$DRY_RUN" = "1" ] && return 0
    sleep_a_moment
    if ! cell_joined "$iface"; then
        log "no cell with a fixed address; joining the ordinary way"
        run_sh "iw dev $iface ibss join $SSID $FREQUENCY 2>/dev/null || true"
        sleep_a_moment
    fi
}

# What the interface says it is doing right now: AP, IBSS, managed, or
# nothing at all. Two spellings, because old drivers have no `iw`.
current_mode() {
    iface="$1"
    if has iw; then
        iw dev "$iface" info 2>/dev/null | sed -n 's/^[[:space:]]*type[[:space:]]*//p'
    elif has iwconfig; then
        iwconfig "$iface" 2>/dev/null | sed -n 's/.*Mode:\([A-Za-z-]*\).*/\1/p'
    fi
}

# True once the interface is doing what we asked. `iw` says AP/IBSS,
# `iwconfig` says Master/Ad-Hoc, and a joiner on an access point is an
# ordinary station that has to have associated.
mode_reached() {
    iface="$1"
    want="$2"      # ap | ibss | client
    mode=$(current_mode "$iface")
    case "$want" in
        ap)   case "$mode" in AP|Master) return 0 ;; esac ;;
        ibss)
            # Both halves: the mode, and a cell actually joined in it.
            case "$mode" in
                IBSS|Ad-Hoc) cell_joined "$iface" && return 0 ;;
            esac
            ;;
        client)
            if has iw; then
                iw dev "$iface" link 2>/dev/null | grep -qi "Connected to" && return 0
            elif has iwconfig; then
                iwconfig "$iface" 2>/dev/null | grep -q "ESSID:\"$SSID\"" && return 0
            fi
            ;;
    esac
    return 1
}

#[[
# Waits for the link to actually come up, and says so plainly when it does
# not.
#
# Worth more than it looks. Every command here can succeed while the link
# quietly fails to appear: wpa_supplicant forks into the background before
# it discovers the driver will not do AP mode, `iw` prints nothing when a
# join is refused, and the system's own Wi-Fi service may take the
# interface straight back. Reporting success from "the commands ran" told
# people the link was up when there was nothing to join.
#]]
await_link() {
    iface="$1"
    want="$2"
    [ "$DRY_RUN" = "1" ] && return 0

    waited=0
    while [ "$waited" -lt 12 ]; do
        if mode_reached "$iface" "$want"; then
            log "verified: $iface is $(current_mode "$iface")"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

link_failure() {
    iface="$1"
    want="$2"
    reason="the interface never came up as $want (it says: $(current_mode "$iface" | tr '\n' ' '))"
    if [ -s "$RUN_DIR/wpa.log" ]; then
        reason="$reason; wpa_supplicant said: $(tail -n 3 "$RUN_DIR/wpa.log" | tr '\n' ' ')"
    fi
    echo "$reason"
}

verify_link() {
    await_link "$1" "$2" || die "$(link_failure "$1" "$2")"
}

establish() {
    role="$1"      # host | join
    iface=$(detect_iface)
    [ -n "$iface" ] || die "no network interface found"
    method=$(probe_value method)
    address="$HOST_IP"
    [ "$role" = "join" ] && address="$JOIN_IP"

    log "interface: $iface"
    log "method:    $method"
    log "role:      $role"
    log "address:   $address"

    case "$method" in
        none)
            die "this device cannot create its own Wi-Fi link (see: $0 probe)"
            ;;
    esac

    stop_system_wifi

    case "$method" in
        ap)
            # An access point on the host; an ordinary client on the joiner.
            if [ "$role" = "host" ]; then
                conf=$(write_wpa_conf 2)
            else
                conf=$(write_wpa_conf 0)
            fi
            start_wpa_supplicant "$iface" "$conf"
            ;;
        ibss)
            # Ad-hoc is symmetric: both sides do exactly the same thing.
            bring_up_ibss_iw "$iface"
            ;;
        ibss-wext)
            bring_up_ibss_wext "$iface"
            ;;
    esac

    # Before claiming anything, check the radio actually did it.
    case "$method" in
        ap)
            if [ "$role" = "host" ]; then
                if ! await_link "$iface" ap; then
                    #[[
                    # A driver can advertise AP mode while the
                    # wpa_supplicant on the device has no AP support built
                    # in, and nothing says so until the network fails to
                    # appear. Ad-hoc is just as good for two readers, so it
                    # is worth trying before giving up on the whole idea.
                    #]]
                    failure=$(link_failure "$iface" ap)
                    if [ "$(probe_value mode_ibss)" = yes ] && has iw; then
                        warn "$failure"
                        log "access point mode did not take; trying ad-hoc instead"
                        bring_up_ibss_iw "$iface"
                        await_link "$iface" ibss || die "$(link_failure "$iface" ibss)"
                    else
                        die "$failure"
                    fi
                fi
            else
                verify_link "$iface" client
            fi
            ;;
        ibss|ibss-wext)
            verify_link "$iface" ibss
            ;;
    esac

    set_address "$iface" "$address"

    settled=$(current_mode "$iface")
    log ""
    log "mode=$settled"
    if [ "$role" = "host" ]; then
        log "This device is hosting the link at $HOST_IP."
        log "On the other device run: $0 join"
        log "Then start Duo as the leader here, and the follower there."
        case "$settled" in
            IBSS|Ad-Hoc)
                #[[
                # Worth spelling out. An ad-hoc cell carries the spread
                # perfectly well between two readers, but it is not an
                # access point and most phones and laptops will not offer it
                # in their list of networks — modern Linux Wi-Fi daemons
                # dropped ad-hoc support altogether. Somebody scanning for
                # the SSID and finding nothing has not got a broken link;
                # they have got a client that cannot see this kind of one.
                #]]
                log ""
                log "NOTE: this is an ad-hoc cell, not an access point."
                log "The join above still works from another reader, but most"
                log "phones and laptops will not list it when they scan, and"
                log "some cannot join one even when told to by name."
                ;;
        esac
    else
        log "Joined the link as $address; the other device is at $HOST_IP."
        log "Start Duo as the follower here and point it at $HOST_IP."
    fi
}

status() {
    iface=$(detect_iface)
    log "interface: $iface"
    if has ip; then
        ip addr show "$iface" 2>/dev/null | sed -n 's/^[[:space:]]*inet /address:  /p'
    elif has ifconfig; then
        ifconfig "$iface" 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/address:  \1/p'
    fi
    # `mode=` in the same spelling `host` ends with, because Duo reads this
    # to decide whether a link it built itself survived a sleep. It used to
    # print `mode:` with the value reworded, which matched nothing.
    log "mode=$(current_mode "$iface")"
    if [ -f "$RUN_DIR/wpa_supplicant.conf" ]; then
        log "duo link: configured ($RUN_DIR)"
    else
        log "duo link: not configured by Duo"
    fi
}

#[[
# The Kindle's own Wi-Fi switch, in the order KOReader uses it.
#
# Two properties, not one, and the order matters in each direction: the
# radio and the daemon that manages it are separate switches, and setting
# only the first leaves wifid holding an interface it has not been told
# about. This is the airplane-mode toggle people end up doing by hand.
#]]
kindle_wifi() {
    has lipc-set-prop || return 0
    if [ "$1" = "1" ]; then
        run_sh "lipc-set-prop -i com.lab126.cmd wirelessEnable 1 >/dev/null 2>&1 || true"
        run_sh "lipc-set-prop -i com.lab126.wifid enable 1 >/dev/null 2>&1 || true"
    else
        run_sh "lipc-set-prop -i com.lab126.wifid enable 0 >/dev/null 2>&1 || true"
        run_sh "lipc-set-prop -i com.lab126.cmd wirelessEnable 0 >/dev/null 2>&1 || true"
    fi
}

#[[
# Gives the interface back, properly.
#
# Undoing the setup is not the same as stopping it. An interface left in
# ad-hoc mode is one the system's Wi-Fi daemon cannot use, and it will not
# say so — it simply never connects, which is why handing control back used
# to mean rebooting, or toggling airplane mode by hand and restarting the
# reader. So the cell is left, the type put back to managed, and the
# Kindle's own two-property switch flicked off and on again, which is the
# thing that makes the framework pick the interface up as if nothing had
# happened.
#]]
restore() {
    iface=$(detect_iface)
    run_sh "killall wpa_supplicant >/dev/null 2>&1 || true"

    # Leave the cell before touching the mode: an interface still in one
    # can refuse to change type.
    if has iw; then
        run_sh "iw dev $iface ibss leave >/dev/null 2>&1 || true"
    fi
    if has ip; then
        run_sh "ip addr flush dev $iface 2>/dev/null || true"
        run_sh "ip link set $iface down 2>/dev/null || true"
    elif has ifconfig; then
        run_sh "ifconfig $iface down 2>/dev/null || true"
    fi
    # nl80211 wants the interface down for this; WEXT does not care.
    if has iw; then
        run_sh "iw dev $iface set type managed >/dev/null 2>&1 || true"
    elif has iwconfig; then
        run_sh "iwconfig $iface mode managed 2>/dev/null || true"
    fi
    if has ip; then
        run_sh "ip link set $iface up 2>/dev/null || true"
    elif has ifconfig; then
        run_sh "ifconfig $iface up 2>/dev/null || true"
    fi

    run_sh "rm -rf $RUN_DIR"
    # `wifis` first and `wifid` a moment later: the daemon expects the
    # supplicant service to be there when it starts looking.
    service_control start wifis
    sleep_a_moment
    for service in wifid cmd_wifid; do
        service_control start "$service"
    done

    # Off, then on: the toggle that makes the framework take the interface
    # back rather than assume it still knows its state.
    kindle_wifi 0
    sleep_a_moment
    kindle_wifi 1

    log "Wi-Fi handed back to the system."
    log "It may take a few seconds to rejoin your usual network."
}

#--------------------------------------------------------------------------

COMMAND="${1:-probe}"
shift 2>/dev/null || true
for argument in "$@"; do
    case "$argument" in
        --dry-run) DRY_RUN=1 ;;
        *) die "unknown option: $argument" ;;
    esac
done

case "$COMMAND" in
    probe)   probe ;;
    host)    establish host ;;
    join)    establish join ;;
    status)  status ;;
    restore) restore ;;
    *)
        echo "usage: $0 {probe|host|join|status|restore} [--dry-run]" >&2
        exit 2
        ;;
esac
