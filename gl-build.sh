#!/bin/sh
# gl-build.sh - configure a unit into its DOT-mode role.
#
# The build restarts networking, which drops SSH and GoodCloud sessions. So it
# runs itself detached: the real work happens in a background copy that ignores
# the hang-up and writes everything to /root/gl-build.log (flash, so the log
# survives a reboot). This terminal just follows the log. If the session drops,
# the build carries on; reconnect and read the log. Its last line is EXIT=<code>.

set -u
LOG=/root/gl-build.log
if [ -z "${GL_DETACHED:-}" ]; then
    : > "$LOG"
    ( trap '' HUP PIPE; GL_DETACHED=1 sh "$0" "$@" >> "$LOG" 2>&1; echo "EXIT=$?" >> "$LOG" ) &
    worker=$!
    tail -f "$LOG" &
    follower=$!
    wait "$worker"
    sleep 1
    kill "$follower" 2>/dev/null
    rc=$(sed -n 's/^EXIT=//p' "$LOG" | tail -n 1)
    exit "${rc:-1}"
fi
trap '' HUP PIPE
BASE=/etc/gl-mode
for f in "$BASE/site.conf" "$BASE/unit.conf"; do
    [ -f "$f" ] || { echo "ERROR: $f missing."; exit 1; }
    . "$f"
done

: "${UNIT_ROLE:?}"; : "${UNIT_IP:?}"; : "${AP_MGMT_IP:?}"
: "${WIFI_KEY:?WIFI_KEY not set - it belongs in /etc/gl-mode/unit.conf}"
SSID_SUFFIX="${SSID_SUFFIX:-}"
case "$UNIT_ROLE" in router|repeater) ;; *) echo "ERROR: bad UNIT_ROLE"; exit 1 ;; esac

# --- refuse to run unless the switch is in DOT ---
# The build writes the DOT-mode role. Run on an AP-mode config it would produce
# a half-router: LAN static .1, WAN still bridged, no WAN interface, and no
# internet for the unit itself - so no GoodCloud either.
GPIO_FILE="${GPIO_FILE:-/sys/kernel/debug/gpio}"
if [ -f "$BASE/switch.conf" ]; then
    . "$BASE/switch.conf"
else
    case "$(cat /tmp/sysinfo/board_name 2>/dev/null)" in
        glinet,mt3000*) GPIO_NUM=455; DOT_STATE=lo ;;
        glinet,gl-sft1200*) GPIO_NUM=1; DOT_STATE=lo ;;
    esac
fi
if [ -n "${GPIO_NUM:-}" ]; then
    [ -f "$GPIO_FILE" ] || mount -t debugfs none /sys/kernel/debug 2>/dev/null
    NOW=$(grep -E "gpio-${GPIO_NUM}[^0-9]" "$GPIO_FILE" 2>/dev/null | grep -oE '\b(hi|lo)\b' | head -n1)
    if [ "$NOW" != "$DOT_STATE" ]; then
        echo "ERROR: the switch is not in DOT (gpio-$GPIO_NUM reads '${NOW:-nothing}', DOT is '$DOT_STATE')."
        echo "       Move it to DOT, wait a minute for the unit to settle, and run this again."
        exit 1
    fi
else
    echo "WARNING: unknown board and no switch.conf - cannot check the switch position."
    echo "         Make sure it is in DOT. Continuing in 10 seconds (Ctrl-C to stop)."
    sleep 10
fi

# --- refuse to build a router on top of an AP-mode config ---
if [ "$UNIT_ROLE" = "router" ] && ! uci -q get network.wan >/dev/null; then
    echo "ERROR: there is no network.wan section, so the live config looks like AP mode."
    echo "       Put the switch in DOT and let the unit switch to router mode first."
    exit 1
fi

# --- in router mode the WAN port must not be a LAN bridge member ---
# A port cannot be a routed WAN and a switch port at once. With eth0 left in
# br-lan (e.g. from an AP template) the WAN never gets an address - not even a
# static one - while the LAN side still serves DHCP. Seen on a field unit on
# 2026-09-28; it needed a factory reset. Remove it here, whatever put it there.
if [ "$UNIT_ROLE" = "router" ]; then
    WAN_DEV=$(uci -q get network.wan.device)
    if [ -n "$WAN_DEV" ]; then
        # 21.02+ style (MT3000): the bridge is a 'config device' with a ports list
        i=0
        while uci -q get "network.@device[$i]" >/dev/null; do
            if [ "$(uci -q get "network.@device[$i].type")" = "bridge" ]; then
                case " $(uci -q get "network.@device[$i].ports") " in
                    *" $WAN_DEV "*)
                        uci del_list "network.@device[$i].ports=$WAN_DEV"
                        echo "WARNING: $WAN_DEV (the WAN port) was in the LAN bridge - removed it." ;;
                esac
            fi
            i=$((i + 1)); [ "$i" -gt 32 ] && break
        done
    else
        # 18.06 style (Opal): the bridge members are lan's space-separated ifname
        WAN_IF=$(uci -q get network.wan.ifname)
        LAN_IF=$(uci -q get network.lan.ifname)
        if [ -n "$WAN_IF" ]; then
            case " $LAN_IF " in
                *" $WAN_IF "*)
                    NEW_IF=$(echo " $LAN_IF " | sed "s/ $WAN_IF / /; s/^ *//; s/ *$//")
                    uci set "network.lan.ifname=$NEW_IF"
                    echo "WARNING: $WAN_IF (the WAN port) was in the LAN bridge - removed it." ;;
            esac
        fi
    fi
fi

# --- retire the original switch_watcher, if present ---
# It must not be running while the build changes config, and it must not come
# back at boot before commissioning replaces it. Its scripts and templates stay
# on disk until commissioning (and gl-safe.sh's rollback restores rc.local).
if ps | grep -q '[s]witch_watcher'; then
    kill $(ps | grep '[s]witch_watcher' | awk '{print $1}') 2>/dev/null
    echo "Stopped the original switch_watcher."
fi
if grep -q switch_watcher /etc/rc.local 2>/dev/null; then
    sed -i '/switch_watcher/d' /etc/rc.local
    echo "Removed switch_watcher from rc.local."
fi

echo "Building $UNIT_ROLE at $UNIT_IP"

# --- network ---
uci set network.lan.proto='static'
uci set network.lan.ipaddr="$UNIT_IP"
uci set network.lan.netmask="$NETMASK"
uci set network.lan.ip6assign='60'
uci set network.lan.isolate='0'

# Real static alias. 'option fallback_ip' does not exist in netifd.
# 21.02+ interfaces take 'device'; 18.06 (Opal) only understands 'ifname'.
uci set network.fallback='interface'
uci set network.fallback.proto='static'
if uci -q get network.lan.device >/dev/null; then
    uci set network.fallback.device='br-lan'
else
    uci -q delete network.fallback.device
    uci set network.fallback.ifname='br-lan'
fi
uci set network.fallback.ipaddr="$AP_MGMT_IP"
uci set network.fallback.netmask="$NETMASK"

if [ "$UNIT_ROLE" = "router" ]; then
    uci set network.wan.proto='dhcp'
    uci set network.wan.ipv6='0'
    uci set network.wan.classlessroute='0'
    uci set network.wan.disabled='0'
fi
uci -q set network.guest.disabled='1'
uci commit network

# --- dhcp ---
if [ "$UNIT_ROLE" = "router" ]; then
    uci set dhcp.lan.ignore='0'
    uci set dhcp.lan.start="$DHCP_START"
    uci set dhcp.lan.limit="$DHCP_LIMIT"
    uci set dhcp.lan.leasetime="$DHCP_LEASETIME"
    uci set dhcp.lan.force='1'
else
    uci set dhcp.lan.ignore='1'
    uci set dhcp.lan.force='0'
fi
uci set dhcp.lan.dhcpv6='disabled'
uci set dhcp.lan.ra='disabled'
for s in guest iot; do
    uci -q get "dhcp.$s" >/dev/null && uci set "dhcp.$s.ignore=1"
done
uci commit dhcp

# --- wireless ---
# Channel stays auto in dot mode; commission fixes channels in the AP template.
# Width and power depend on the driver:
#   mtk (MT3000)       htmode from site.conf (HE20); txpower is a 0-100 percentage
#   mac80211 (Opal)    no wifi 6, so HT20 on 2.4 GHz and VHT20 on 5 GHz; txpower is
#                      dBm and already at the unit's maximum, so it is left alone
set_radio() {   # $1 = section, $2 = mtk htmode, $3 = band
    uci set "wireless.$1.channel=auto"
    uci set "wireless.$1.country=$COUNTRY"
    uci set "wireless.$1.disabled=0"
    if [ "$(uci -q get "wireless.$1.type")" = "mtk" ]; then
        uci set "wireless.$1.htmode=$2"
        uci set "wireless.$1.txpower=$TXPOWER"
    else
        case "$3" in
            2g) uci set "wireless.$1.htmode=HT20" ;;
            5g) uci set "wireless.$1.htmode=VHT20" ;;
        esac
    fi
}
set_iface() {
    uci set "wireless.$1.mode=ap"
    uci set "wireless.$1.network=lan"
    uci set "wireless.$1.ssid=$2"
    uci set "wireless.$1.key=$WIFI_KEY"
    uci set "wireless.$1.encryption=$ENCRYPTION"
    uci set "wireless.$1.disabled=0"
    uci set "wireless.$1.hidden=0"
    uci set "wireless.$1.isolate=0"
    uci set "wireless.$1.wds=1"
    uci set "wireless.$1.ieee80211k=1"
    uci set "wireless.$1.bss_transition=1"
}

DEV24=''; DEV5=''
for s in $(uci show wireless | sed -n "s/^wireless\.\([^.]*\)=wifi-device$/\1/p"); do
    case "$(uci -q get "wireless.$s.band")" in
        2g) DEV24="$s" ;;
        5g) DEV5="$s"  ;;
    esac
done
[ -n "$DEV24" ] && [ -n "$DEV5" ] || { echo "ERROR: radios not found."; exit 1; }

set_radio "$DEV24" "$HTMODE_24" 2g
set_radio "$DEV5"  "$HTMODE_5"  5g

# Only the two main access points are configured. Everything else is either
# switched off (guest, IoT, mesh backhaul) or left exactly as found.
#
# GL 4.11 added mesh backhaul interfaces - bbss5g (rax3, hidden backhaul AP)
# and bsta5g (apclix0, backhaul client). An earlier version of this script
# treated them as main APs and enabled them, which put ra0 on the 5 GHz band
# and duplicated the 5 GHz SSID. They must stay disabled.
main_iface() {   # $1 $2 = candidate section names, $3 $4 = candidate ifnames
    for n in "$1" "$2"; do
        uci -q get "wireless.$n" >/dev/null && { echo "$n"; return; }
    done
    for s in $(uci show wireless | sed -n "s/^wireless\.\([^.]*\)=wifi-iface$/\1/p"); do
        case "$(uci -q get "wireless.$s.ifname")" in
            "$3"|"$4") echo "$s"; return ;;
        esac
    done
}
MAIN24=$(main_iface wifi2g default_radio0 ra0  wlan0)
MAIN5=$(main_iface  wifi5g default_radio1 rax0 wlan1)
[ -n "$MAIN24" ] && [ -n "$MAIN5" ] || { echo "ERROR: main wifi interfaces not found."; exit 1; }

for s in $(uci show wireless | sed -n "s/^wireless\.\([^.]*\)=wifi-iface$/\1/p"); do
    case "$s" in
        "$MAIN24") set_iface "$s" "${SSID_24}${SSID_SUFFIX}"; continue ;;
        "$MAIN5")  set_iface "$s" "${SSID_5}${SSID_SUFFIX}";  continue ;;
        bsta*)     uci set "wireless.$s.disabled=1"; uci set "wireless.$s.mode=sta"; continue ;;
        bbss*)     uci set "wireless.$s.disabled=1"; continue ;;
    esac
    [ "$(uci -q get "wireless.$s.guest")" = "1" ] && { uci set "wireless.$s.disabled=1"; continue; }
    [ "$(uci -q get "wireless.$s.iot")"   = "1" ] && { uci set "wireless.$s.disabled=1"; continue; }
    echo "  left alone: wireless.$s"
done
uci commit wireless

echo "Applying..."
/etc/init.d/network restart
/etc/init.d/dnsmasq restart 2>/dev/null
# 'wifi', NOT 'mtk-wifi-configurator restart' - see gl-mode.sh.
sleep 3
wifi 2>/dev/null

echo
echo "Built. LAN $UNIT_IP (alias $AP_MGMT_IP), SSIDs ${SSID_24}${SSID_SUFFIX} / ${SSID_5}${SSID_SUFFIX}"
echo "Still manual: GoodCloud registration, Toggle Button -> No Function, root password."
echo "Then verify, then run gl-mode-commission.sh with the switch in DOT."

# --- WAN failover order (GL multi-wan) ---
# Priority is the 'metric' on each kmwan member: lower wins. IPv6 twins
# mirror their IPv4 parent - named wan6/tethering6 but modem_1_1_2_6, so
# both spellings are tried. Members absent on this unit are skipped.
if [ -f /etc/config/kmwan ] && [ -n "${WAN_ORDER:-}" ]; then
    m=1
    for w in $WAN_ORDER; do
        if uci -q get "kmwan.$w" >/dev/null; then
            uci set "kmwan.$w.metric=$m"
            for v6 in "${w}6" "${w}_6"; do
                uci -q get "kmwan.$v6" >/dev/null && uci set "kmwan.$v6.metric=$m"
            done
            echo "  wan priority $m: $w"
            m=$((m+1))
        fi
    done
    uci set kmwan.global.mode='failover'
    uci set kmwan.global.enable='1'
    uci commit kmwan
    /etc/init.d/kmwan restart 2>/dev/null
fi

echo "Build complete."
exit 0
