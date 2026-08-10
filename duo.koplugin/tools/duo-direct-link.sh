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

probe() {
    iface=$(detect_iface)
    [ -n "$iface" ] || die "no network interface found"
    driver=$(detect_driver "$iface")
    modes=$(supported_modes)

    echo "interface=$iface"
    echo "driver=$driver"
    for tool in iw iwconfig wpa_supplicant hostapd ip ifconfig; do
        if has "$tool"; then echo "tool_$tool=yes"; else echo "tool_$tool=no"; fi
    done

    ap=no
    ibss=no
    for mode in $modes; do
        [ "$mode" = "AP" ] && ap=yes
        [ "$mode" = "IBSS" ] && ibss=yes
    done
    echo "mode_ap=$ap"
    echo "mode_ibss=$ibss"

    # WEXT drivers report no modes to iw but can usually still do ad-hoc.
    wext=no
    if [ -z "$modes" ] && has iwconfig; then
        wext=yes
    fi
    echo "wext=$wext"

    if [ "$ap" = yes ] && has wpa_supplicant; then
        echo "method=ap"
        echo "verdict=This device can host the link by itself. Run: $0 host"
    elif [ "$ibss" = yes ] && has iw; then
        echo "method=ibss"
        echo "verdict=No access point mode, but ad-hoc works, which is just as good for two readers. Run: $0 host"
    elif [ "$wext" = yes ]; then
        echo "method=ibss-wext"
        echo "verdict=Old-style Wi-Fi driver; ad-hoc is worth trying. Run: $0 host"
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

stop_system_wifi() {
    # Amazon's Kindle daemons. Absent elsewhere, which is why failures here
    # are ignored rather than fatal.
    if has lipc-set-prop; then
        run_sh "lipc-set-prop com.lab126.cmd wirelessEnable 1 >/dev/null 2>&1 || true"
    fi
    for service in wifid cmd_wifid; do
        if has stop; then
            run_sh "stop $service >/dev/null 2>&1 || true"
        fi
    done
    run_sh "killall wpa_supplicant >/dev/null 2>&1 || true"
    run_sh "killall dhclient udhcpc >/dev/null 2>&1 || true"
    sleep_a_moment
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

bring_up_ibss_iw() {
    iface="$1"
    run_sh "ip link set $iface down 2>/dev/null || true"
    run iw dev "$iface" set type ibss
    run_sh "ip link set $iface up 2>/dev/null || true"
    sleep_a_moment
    run_sh "iw dev $iface ibss join $SSID $FREQUENCY 2>/dev/null || true"
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

    set_address "$iface" "$address"

    log ""
    if [ "$role" = "host" ]; then
        log "This device is hosting the link at $HOST_IP."
        log "On the other device run: $0 join"
        log "Then start Duo as master here, and as slave there."
    else
        log "Joined the link as $address; the other device is at $HOST_IP."
        log "Start Duo as slave here and point it at $HOST_IP."
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
    if has iwconfig; then
        iwconfig "$iface" 2>/dev/null | sed -n 's/.*Mode:\([A-Za-z-]*\).*/mode:     \1/p'
    fi
    if [ -f "$RUN_DIR/wpa_supplicant.conf" ]; then
        log "duo link: configured ($RUN_DIR)"
    else
        log "duo link: not configured by Duo"
    fi
}

restore() {
    iface=$(detect_iface)
    run_sh "killall wpa_supplicant >/dev/null 2>&1 || true"
    if has ip; then
        run_sh "ip addr flush dev $iface 2>/dev/null || true"
    fi
    if has iwconfig; then
        run_sh "iwconfig $iface mode managed 2>/dev/null || true"
    fi
    run_sh "rm -rf $RUN_DIR"
    for service in wifid cmd_wifid; do
        if has start; then
            run_sh "start $service >/dev/null 2>&1 || true"
        fi
    done
    log "Wi-Fi handed back to the system. A reboot is the sure way if it misbehaves."
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
