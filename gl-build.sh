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
RELAY_LAN_IP="${RELAY_LAN_IP:-192.168.254.1}"   # extender only: private address on its LAN bridge
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
        glinet,gl-sft1200*) GPIO_NUM=1; DOT_STATE=hi ;;   # opposite of the MT3000 - confirmed on the bench 2026-09-28
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

# --- the extender role is for the Opal (standard mac80211 wifi) only ---
# The MT3000's MediaTek driver makes client links through GL's own repeater
# system, not a 'sta' wifi-iface, so an MT3000 extender would have no uplink.
if [ "$UNIT_ROLE" = "repeater" ] && uci -q show wireless | grep -q "=wifi-device" \
   && uci -q show wireless | grep -q "\.type='mtk'"; then
    echo "ERROR: the extender (repeater) role is for the Opal only - this unit is an MT3000."
    echo "       Reinstall as a router:  sh /tmp/install.sh 'wifi-key' router"
    exit 1
fi

# --- in DOT the WAN port must never be a LAN bridge member (either role) ---
# A port cannot be a routed WAN and a switch port at once. With eth0 left in
# br-lan (e.g. from an AP template) the WAN never gets an address - not even a
# static one - while the LAN side still serves DHCP. Seen on a field unit on
# 2026-09-28; it needed a factory reset. On an Opal extender, GL's firmware put
# it there itself when the WAN was disabled. Remove it, whatever put it there.
if true; then
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
# An extender uses the same address (.5) for both, so in DOT the alias would
# duplicate the LAN address - it is left out, and commissioning adds it to the
# NO-DOT template where the LAN switches to DHCP.
if [ "$AP_MGMT_IP" = "$UNIT_IP" ]; then
    uci -q delete network.fallback
else
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
fi

if [ "$UNIT_ROLE" = "router" ]; then
    uci set network.wan.proto='dhcp'
    uci set network.wan.ipv6='0'
    uci set network.wan.classlessroute='0'
    uci set network.wan.disabled='0'
    uci -q delete network.lan.gateway
    uci -q delete network.lan.dns
    uci -q delete network.uplink
    uci -q delete network.stabridge
else
    # Extender, via relayd. The Opal's wifi driver cannot do 4-address (WDS)
    # client mode, so its link to the router cannot sit in the LAN bridge
    # (confirmed 2026-09-28: 'iw ... 4addr on' -> Not supported). Instead:
    #   uplink     the wifi client link; holds UNIT_IP, gateway/DNS = router
    #   lan        the local bridge (5 GHz _Ext1 + LAN port); a private address
    #              used only between this unit and relayd
    #   stabridge  relayd joins the two: clients' DHCP goes to the router, so
    #              they get 172.24.172.x; broadcasts are forwarded too
    uci set network.lan.ipaddr="$RELAY_LAN_IP"
    uci -q delete network.lan.gateway
    uci -q delete network.lan.dns
    uci set network.uplink='interface'
    uci set network.uplink.proto='static'
    uci set network.uplink.ipaddr="$UNIT_IP"
    uci set network.uplink.netmask="$NETMASK"
    uci set network.uplink.gateway="$ROUTER_IP"
    uci set network.uplink.dns="$ROUTER_IP"
    uci set network.stabridge='interface'
    uci set network.stabridge.proto='relay'
    uci set network.stabridge.network='lan uplink'
    uci set network.stabridge.ipaddr="$UNIT_IP"
    # The WAN port is unused in DOT. Disabling it made GL's firmware treat it
    # as a spare LAN port and bridge it in (seen 2026-09-28), so it is kept
    # claimed with proto none instead. Commissioning still finds it by name.
    if uci -q get network.wan >/dev/null; then
        uci set network.wan.proto='none'
        uci -q delete network.wan.disabled
    fi
fi
uci -q set network.guest.disabled='1'
uci commit network

if [ "$UNIT_ROLE" = "repeater" ]; then
    Z=$(uci show firewall | sed -n "s/^firewall\.\([^.]*\)\.name='lan'$/\1/p" | head -n 1)
    if [ -n "$Z" ]; then
        CUR=$(uci -q get "firewall.$Z.network")
        case " $CUR " in
            *" uplink "*) ;;
            *) uci set "firewall.$Z.network=$CUR uplink"; uci commit firewall
               echo "  firewall: uplink added to the lan zone" ;;
        esac
    else
        echo "WARNING: no firewall zone named 'lan' found - uplink not added."
    fi
fi

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
        uplink)    continue ;;   # the extender's own client link, handled below
    esac
    [ "$(uci -q get "wireless.$s.guest")" = "1" ] && { uci set "wireless.$s.disabled=1"; continue; }
    [ "$(uci -q get "wireless.$s.iot")"   = "1" ] && { uci set "wireless.$s.disabled=1"; continue; }
    echo "  left alone: wireless.$s"
done

# --- extender uplink ---
# A client (sta) interface joins the router's SSID on its own 'uplink' network;
# relayd (above) joins it to the LAN. UPLINK_BAND in unit.conf picks the radio;
# 2g is the default - longer range, and it avoids the router landing the
# extender on a radar-checked 5 GHz channel its own AP cannot use.
UPLINK_BAND="${UPLINK_BAND:-2g}"
if [ "$UNIT_ROLE" = "repeater" ]; then
    case "$UPLINK_BAND" in
        5g) UP_DEV="$DEV5";  UP_SSID="$SSID_5"  ;;
        *)  UP_DEV="$DEV24"; UP_SSID="$SSID_24" ;;
    esac
    uci set wireless.uplink='wifi-iface'
    uci set wireless.uplink.device="$UP_DEV"
    uci set wireless.uplink.mode='sta'
    uci set wireless.uplink.network='uplink'
    uci set wireless.uplink.ssid="$UP_SSID"
    uci set wireless.uplink.key="$WIFI_KEY"
    uci set wireless.uplink.encryption="$ENCRYPTION"
    uci -q delete wireless.uplink.wds
    uci set wireless.uplink.disabled='0'
    echo "  uplink: joins '$UP_SSID' on $UPLINK_BAND ($UP_DEV), relayed to the LAN"

    # Dedicated backhaul: by default the extender does NOT also run a client
    # access point on the uplink's radio. Sharing a radio halves its airtime
    # and ties that access point to the router's channel and to the uplink
    # staying up. Clients use the other band's _Ext1 network instead.
    # UPLINK_RADIO_AP=on in unit.conf brings it back (e.g. for 2.4-only devices).
    # In NO-DOT there is no uplink, so commissioning turns it back on.
    case "$UP_DEV" in "$DEV24") UP_AP="$MAIN24" ;; *) UP_AP="$MAIN5" ;; esac
    if [ "${UPLINK_RADIO_AP:-off}" = "on" ]; then
        echo "  access point on the uplink radio kept on (UPLINK_RADIO_AP=on)"
    else
        uci set "wireless.$UP_AP.disabled=1"
        echo "  access point on the uplink radio ($UP_AP) off - dedicated backhaul"
    fi
else
    uci -q delete wireless.uplink
fi
uci commit wireless

# GL's own repeater manager scans for and rewrites client links. On an
# extender it would fight the uplink above, so it is switched off there.
if [ "$UNIT_ROLE" = "repeater" ] && [ -x /etc/init.d/repeater ]; then
    /etc/init.d/repeater stop 2>/dev/null
    /etc/init.d/repeater disable 2>/dev/null
    echo "  GL repeater manager stopped and disabled."
fi

echo "Applying..."
/etc/init.d/network restart
/etc/init.d/dnsmasq restart 2>/dev/null
# 'wifi', NOT 'mtk-wifi-configurator restart' - see gl-mode.sh.
sleep 3
wifi 2>/dev/null

if [ "$UNIT_ROLE" = "repeater" ]; then
    if [ -x /etc/init.d/relayd ]; then
        /etc/init.d/relayd enable 2>/dev/null
        t=0
        while [ "$t" -lt 60 ]; do
            ifstatus uplink 2>/dev/null | grep -q '"up": true' && break
            sleep 3; t=$((t + 3))
        done
        /etc/init.d/relayd restart 2>/dev/null
        if ifstatus uplink 2>/dev/null | grep -q '"up": true'; then
            echo "  uplink up after ${t}s; relayd started"
        else
            echo "WARNING: uplink not up after 60s."
            if logread 2>/dev/null | tail -n 200 | grep -q 'reason=WRONG_KEY'; then
                echo "         The router rejected the wifi key (WRONG_KEY). Check WIFI_KEY in"
                echo "         /etc/gl-mode/unit.conf matches the router's Legrand-TechNet key."
            else
                echo "         Is the router's Legrand-TechNet in range? (Units side by side can"
                echo "         also fail - keep them a couple of metres apart.)"
            fi
            iw dev 2>/dev/null | grep -q Interface && for i in $(iw dev | awk '/Interface/ {n=$2} /type managed/ {print n}'); do
                echo "         $i: $(iw dev "$i" link 2>/dev/null | head -n 1)"
            done
        fi
    else
        echo "ERROR: relayd is not installed - the extender cannot pass traffic."
    fi
fi

echo
if [ "$UNIT_ROLE" = "repeater" ]; then
    echo "Built. Extender at $UNIT_IP (over the uplink), SSIDs ${SSID_24}${SSID_SUFFIX} / ${SSID_5}${SSID_SUFFIX}"
else
    echo "Built. LAN $UNIT_IP (alias $AP_MGMT_IP), SSIDs ${SSID_24}${SSID_SUFFIX} / ${SSID_5}${SSID_SUFFIX}"
fi
echo "Still manual: GoodCloud registration, Toggle Button -> No Function, root password."
echo "Then verify, then run gl-mode-commission.sh with the switch in DOT."

# --- WAN failover order (GL multi-wan) ---
# Priority is the 'metric' on each kmwan member: lower wins. IPv6 twins
# mirror their IPv4 parent - named wan6/tethering6 but modem_1_1_2_6, so
# both spellings are tried. Members absent on this unit are skipped.
# Router only: an extender's internet is the uplink, which kmwan does not manage.
if [ "$UNIT_ROLE" = "router" ] && [ -f /etc/config/kmwan ] && [ -n "${WAN_ORDER:-}" ]; then
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
