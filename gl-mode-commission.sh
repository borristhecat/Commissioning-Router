#!/bin/sh
# gl-mode-commission.sh - snapshot the DOT config, derive the AP template.
# Run with the switch in DOT, after the role is built and verified.

set -u
BASE=/etc/gl-mode
DOT="$BASE/dot"; NODOT="$BASE/nodot"
FILES="network dhcp wireless repeater"

for f in "$BASE/site.conf" "$BASE/unit.conf"; do
    [ -f "$f" ] || { echo "ERROR: $f missing."; exit 1; }
    . "$f"
done
: "${UNIT_ROLE:?}"; : "${AP_MGMT_IP:?}"; : "${CH_24:?}"; : "${CH_5:?}"

if [ ! -f "$BASE/switch.conf" ]; then
    case "$(cat /tmp/sysinfo/board_name 2>/dev/null)" in
        glinet,mt3000*) printf 'GPIO_NUM=455\nDOT_STATE=lo\n' > "$BASE/switch.conf"
                        echo "Applied known MT3000 mapping (gpio-455, dot=lo)." ;;
        glinet,gl-sft1200*) printf 'GPIO_NUM=1\nDOT_STATE=hi\n' > "$BASE/switch.conf"
                        echo "Applied known SFT1200 mapping (gpio-1, dot=hi)." ;;
        *) echo "ERROR: no switch.conf and unknown board. Run gl-mode-calibrate.sh."; exit 1 ;;
    esac
fi
. "$BASE/switch.conf"

[ -f /sys/kernel/debug/gpio ] || mount -t debugfs none /sys/kernel/debug 2>/dev/null
NOW=$(grep -E "gpio-${GPIO_NUM}[^0-9]" /sys/kernel/debug/gpio | grep -oE '\b(hi|lo)\b' | head -n1)
[ "$NOW" = "$DOT_STATE" ] || { echo "ERROR: switch not in DOT (reads '$NOW', expected '$DOT_STATE')."; exit 1; }

if [ "$UNIT_ROLE" = "repeater" ] && [ "$(uci -q get dhcp.lan.ignore)" != "1" ]; then
    echo "ERROR: repeater unit still has an active DHCP pool."
    echo "  uci set dhcp.lan.ignore=1; uci set dhcp.lan.force=0; uci commit dhcp"
    exit 1
fi

mkdir -p "$DOT" "$NODOT"
for f in $FILES; do [ -f "/etc/config/$f" ] && cp "/etc/config/$f" "$DOT/$f"; done
echo "Snapshotted DOT ($UNIT_ROLE) template."

for f in $FILES; do [ -f "$DOT/$f" ] && cp "$DOT/$f" "$NODOT/$f"; done
U() { uci -q -c "$NODOT" "$@"; }

# --- network: bridge WAN into LAN ---
WAN_DEV=$(U get network.wan.device); [ -n "$WAN_DEV" ] || WAN_DEV=$(U get network.wan.ifname)
[ -n "$WAN_DEV" ] || { echo "ERROR: cannot find WAN port."; exit 1; }
case "$WAN_DEV" in @*) echo "ERROR: wan device is an alias."; exit 1 ;; esac

BR_IDX=''; BR_NAME=''; i=0
while [ -n "$(U get network.@device[$i])" ]; do
    if [ "$(U get network.@device[$i].type)" = "bridge" ]; then
        BR_IDX=$i; BR_NAME=$(U get network.@device[$i].name); break
    fi
    i=$((i+1)); [ "$i" -gt 32 ] && break
done

if [ -n "$BR_IDX" ]; then
    U add_list "network.@device[$BR_IDX].ports=$WAN_DEV"
    U set "network.@device[$BR_IDX].stp=1"
    LAN_DEV="${BR_NAME:-br-lan}"; STYLE=device
else
    U set "network.lan.ifname=$(U get network.lan.ifname) $WAN_DEV"
    U set network.lan.type=bridge
    U set network.lan.stp=1
    LAN_DEV=br-lan; STYLE=ifname
fi
echo "Bridging $WAN_DEV into $LAN_DEV ($STYLE style)."

U delete network.wan
U delete network.wan6
U delete network.uplink       # extender's relayd layout - not used in NO-DOT
U delete network.stabridge
U del_list "dhcp.@dnsmasq[0].server=$ROUTER_IP"   # extender's DNS pointer, DOT only
U set network.lan.proto=dhcp
for o in ipaddr netmask gateway dns ip6assign; do U delete "network.lan.$o"; done

U set network.fallback=interface
[ "$STYLE" = device ] && U set "network.fallback.device=$LAN_DEV" \
                      || U set "network.fallback.ifname=$LAN_DEV"
U set network.fallback.proto=static
U set "network.fallback.ipaddr=$AP_MGMT_IP"
U set "network.fallback.netmask=$NETMASK"
U commit network

# --- dhcp: off. proto dhcp on lan does NOT stop dnsmasq serving. ---
i=0
while [ -n "$(U get dhcp.@dhcp[$i])" ]; do
    U set "dhcp.@dhcp[$i].ignore=1"
    U set "dhcp.@dhcp[$i].force=0"
    U set "dhcp.@dhcp[$i].dhcpv6=disabled"
    U set "dhcp.@dhcp[$i].ra=disabled"
    U set "dhcp.@dhcp[$i].ndp=disabled"
    i=$((i+1)); [ "$i" -gt 32 ] && break
done
U commit dhcp

# --- repeater uplink off ---
if [ -f "$NODOT/repeater" ]; then
    U set repeater.@repeater[0].enable=0 2>/dev/null
    U set repeater.default.enable=0 2>/dev/null
    U commit repeater
fi

# --- wireless: fixed non-overlapping channels ---
i=0
while [ -n "$(U get wireless.@wifi-device[$i])" ]; do
    # mtk (MT3000): HE widths and txpower as a percentage.
    # mac80211 (Opal): HT20/VHT20, txpower left at the unit's dBm maximum.
    TYPE=$(U get "wireless.@wifi-device[$i].type")
    case "$(U get wireless.@wifi-device[$i].band)" in
        2g) U set "wireless.@wifi-device[$i].channel=$CH_24"
            [ "$TYPE" = mtk ] && W=$HTMODE_24 || W=HT20
            U set "wireless.@wifi-device[$i].htmode=$W" ;;
        5g) U set "wireless.@wifi-device[$i].channel=$CH_5"
            [ "$TYPE" = mtk ] && W=$HTMODE_5 || W=VHT20
            U set "wireless.@wifi-device[$i].htmode=$W" ;;
    esac
    U set "wireless.@wifi-device[$i].country=$COUNTRY"
    [ "$TYPE" = mtk ] && U set "wireless.@wifi-device[$i].txpower=$TXPOWER"
    U set "wireless.@wifi-device[$i].disabled=0"
    i=$((i+1)); [ "$i" -gt 8 ] && break
done
i=0; g=0
while [ -n "$(U get wireless.@wifi-iface[$i])" ]; do
    g=$((g+1)); [ "$g" -gt 64 ] && break
    # Disable (never delete) client and mesh interfaces in AP mode, so the unit
    # is not associated upstream while also bridged inline. Deleting GL's own
    # sections risks confusing its mesh/repeater tooling.
    case "$(U get wireless.@wifi-iface[$i].mode)" in
        sta|wds|mesh|adhoc|monitor) U set "wireless.@wifi-iface[$i].disabled=1" ;;
    esac
    case "$(U get wireless.@wifi-iface[$i].ifname)" in
        apcli*) U set "wireless.@wifi-iface[$i].disabled=1" ;;
    esac
    i=$((i+1))
done
# An extender's DOT config may have its uplink-radio access point off (the
# radio is a dedicated backhaul there). In NO-DOT there is no uplink, so both
# main access points come back on.
if [ "$UNIT_ROLE" = "repeater" ]; then
    for sec in wifi2g wifi5g default_radio0 default_radio1; do
        U get "wireless.$sec" >/dev/null && U set "wireless.$sec.disabled=0"
    done
fi
for sec in bbss5g bbss2g bsta5g bsta2g; do
    U get "wireless.$sec" >/dev/null && U set "wireless.$sec.disabled=1"
done
U commit wireless
echo "Derived NO-DOT (AP) template."

# --- install runtime, retire the old implementation ---
chmod +x /usr/bin/gl-mode.sh /etc/init.d/modewatch
/etc/init.d/modewatch enable
sed -i '/switch_watcher/d' /etc/rc.local 2>/dev/null
kill $(ps | grep '[s]witch_watcher' | grep -v grep | awk '{print $1}') 2>/dev/null
rm -f /usr/bin/switch_logic.sh /usr/bin/switch_watcher.sh
sed -i '\#^/usr/bin/switch_logic.sh$#d;\#^/usr/bin/switch_watcher.sh$#d' /etc/sysupgrade.conf 2>/dev/null

if [ -x /etc/init.d/gl_switch_button_check ]; then
    /etc/init.d/gl_switch_button_check stop 2>/dev/null
    /etc/init.d/gl_switch_button_check disable 2>/dev/null
    echo "Disabled vendor handler gl_switch_button_check."
fi
[ -x /etc/init.d/gpio_switch ] && echo "NOTE: gpio_switch left running (stock OpenWrt, also drives usb_power/fan)."

for p in /etc/gl-mode/ /usr/bin/gl-mode.sh /etc/init.d/modewatch /etc/rc.d/S99modewatch \
         /usr/bin/gl-uplink.sh /etc/init.d/gl-uplink /etc/rc.d/S98gl-uplink; do
    grep -qxF "$p" /etc/sysupgrade.conf 2>/dev/null || echo "$p" >> /etc/sysupgrade.conf
done

/etc/init.d/modewatch restart

echo
echo "Done. DOT=$UNIT_ROLE  NO-DOT=AP bridge, no DHCP, mgmt $AP_MGMT_IP"
echo "Channels in AP mode: 2.4=$CH_24 5=$CH_5"
