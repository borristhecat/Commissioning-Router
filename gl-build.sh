#!/bin/sh
# gl-build.sh - configure a blank unit into its DOT-mode role.
# Run over the LAN cable: this restarts networking and wifi.

set -u
BASE=/etc/gl-mode
for f in "$BASE/site.conf" "$BASE/unit.conf"; do
    [ -f "$f" ] || { echo "ERROR: $f missing."; exit 1; }
    . "$f"
done

: "${UNIT_ROLE:?}"; : "${UNIT_IP:?}"; : "${AP_MGMT_IP:?}"
: "${WIFI_KEY:?WIFI_KEY not set - it belongs in /etc/gl-mode/unit.conf}"
SSID_SUFFIX="${SSID_SUFFIX:-}"
case "$UNIT_ROLE" in router|repeater) ;; *) echo "ERROR: bad UNIT_ROLE"; exit 1 ;; esac

echo "Building $UNIT_ROLE at $UNIT_IP"

# --- network ---
uci set network.lan.proto='static'
uci set network.lan.ipaddr="$UNIT_IP"
uci set network.lan.netmask="$NETMASK"
uci set network.lan.ip6assign='60'
uci set network.lan.isolate='0'

# Real static alias. 'option fallback_ip' does not exist in netifd.
uci set network.fallback='interface'
uci set network.fallback.proto='static'
uci set network.fallback.device='br-lan'
uci set network.fallback.ipaddr="$AP_MGMT_IP"
uci set network.fallback.netmask="$NETMASK"

if [ "$UNIT_ROLE" = "router" ]; then
    uci set network.wan.proto='dhcp'
    uci set network.wan.metric='2'
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
set_radio() {
    uci set "wireless.$1.channel=auto"
    uci set "wireless.$1.htmode=$2"
    uci set "wireless.$1.country=$COUNTRY"
    uci set "wireless.$1.txpower=$TXPOWER"
    uci set "wireless.$1.disabled=0"
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

set_radio "$DEV24" "$HTMODE_24"
set_radio "$DEV5"  "$HTMODE_5"

for s in $(uci show wireless | sed -n "s/^wireless\.\([^.]*\)=wifi-iface$/\1/p"); do
    [ "$(uci -q get "wireless.$s.guest")" = "1" ] && { uci set "wireless.$s.disabled=1"; continue; }
    [ "$(uci -q get "wireless.$s.iot")"   = "1" ] && { uci set "wireless.$s.disabled=1"; continue; }
    case "$(uci -q get "wireless.$s.device")" in
        "$DEV24") set_iface "$s" "${SSID_24}${SSID_SUFFIX}" ;;
        "$DEV5")  set_iface "$s" "${SSID_5}${SSID_SUFFIX}"  ;;
    esac
done
uci commit wireless

echo "Applying..."
/etc/init.d/network restart
/etc/init.d/dnsmasq restart 2>/dev/null
if [ -x /etc/init.d/mtk-wifi-configurator ]; then
    /etc/init.d/mtk-wifi-configurator restart 2>/dev/null
else
    wifi reload 2>/dev/null || wifi 2>/dev/null
fi

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
