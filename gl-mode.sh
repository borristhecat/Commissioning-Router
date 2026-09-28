#!/bin/sh
# /usr/bin/gl-mode.sh   apply | watch | status
# Replaces switch_logic.sh + switch_watcher.sh.

BASE=/etc/gl-mode
CONF="$BASE/switch.conf"
STATE_FILE=/tmp/.gl-mode-current
POLL="${POLL:-2}"

# repeater is GL's uplink config. The client link is NOT a mode='sta'
# wifi-iface on this firmware - it is /etc/config/repeater onto apcli0.
FILES="network dhcp wireless repeater"

[ -f "$CONF" ] || { echo "gl-mode: $CONF missing" >&2; exit 1; }
. "$CONF"

read_switch() {
    [ -f /sys/kernel/debug/gpio ] || mount -t debugfs none /sys/kernel/debug 2>/dev/null
    # Exact whole-field match: the reset line reads "hi ... ACTIVE LOW".
    grep -E "gpio-${GPIO_NUM}[^0-9]" /sys/kernel/debug/gpio 2>/dev/null \
        | grep -oE '\b(hi|lo)\b' | head -n1
}

current_mode() {
    s=$(read_switch)
    [ -z "$s" ] && return 1
    if [ "$s" = "$DOT_STATE" ]; then echo dot; else echo nodot; fi
}

# Wait for every enabled AP interface on 'lan' to join br-lan. If one has
# not appeared after ~40 s, add it by hand and log it, so a recurrence is
# visible in logread rather than failing silently.
check_bridge() {
    want=''
    for s in $(uci -q show wireless | sed -n "s/^wireless\.\([^.]*\)=wifi-iface$/\1/p"); do
        [ "$(uci -q get "wireless.$s.disabled")" = "1" ] && continue
        [ "$(uci -q get "wireless.$s.mode")" = "ap" ]     || continue
        [ "$(uci -q get "wireless.$s.network")" = "lan" ] || continue
        n=$(uci -q get "wireless.$s.ifname"); [ -n "$n" ] && want="$want $n"
    done
    [ -z "$want" ] && return 0
    t=0
    while [ "$t" -lt 40 ]; do
        miss=''
        for n in $want; do [ -e "/sys/class/net/br-lan/brif/$n" ] || miss="$miss $n"; done
        [ -z "$miss" ] && return 0
        sleep 2; t=$((t+2))
    done
    for n in $miss; do
        ip link set "$n" up 2>/dev/null
        ip link set "$n" master br-lan 2>/dev/null
        logger -t gl-mode "WARNING: $n was not in br-lan after 40s, added by hand"
    done
}

apply() {
    m=$(current_mode) || { logger -t gl-mode "cannot read gpio-$GPIO_NUM"; return 1; }

    for f in $FILES; do
        [ -f "$BASE/$m/$f" ] || { logger -t gl-mode "missing $BASE/$m/$f, refusing"; return 1; }
    done

    [ "$(cat "$STATE_FILE" 2>/dev/null)" = "$m" ] && return 0
    logger -t gl-mode "switching to $m"

    for f in $FILES; do cp "$BASE/$m/$f" "/etc/config/$f"; done

    if [ "$m" = "dot" ]; then
        /etc/init.d/firewall enable 2>/dev/null
        /etc/init.d/firewall start  2>/dev/null
    else
        /etc/init.d/firewall stop    2>/dev/null
        /etc/init.d/firewall disable 2>/dev/null
    fi

    /etc/init.d/network restart
    /etc/init.d/dnsmasq restart 2>/dev/null
    /etc/init.d/odhcpd  restart 2>/dev/null

    if [ -x /etc/init.d/repeater ]; then
        [ "$m" = "dot" ] && /etc/init.d/repeater restart 2>/dev/null \
                         || /etc/init.d/repeater stop    2>/dev/null
    fi

    # 'wifi', NOT 'mtk-wifi-configurator restart'. On GL 4.11 the latter
    # leaves the radios on factory defaults (blank open SSID, ch 6) and out
    # of the bridge. Verified on the bench 2026-09-28.
    sleep 3
    wifi 2>/dev/null
    check_bridge

    echo "$m" > "$STATE_FILE"
    logger -t gl-mode "now in $m mode"
}

case "${1:-apply}" in
    apply) apply ;;
    watch) while true; do apply; sleep "$POLL"; done ;;
    status)
        echo "gpio-$GPIO_NUM = $(read_switch)   (dot = $DOT_STATE)"
        echo "position     = $(current_mode 2>/dev/null || echo unknown)"
        echo "applied      = $(cat "$STATE_FILE" 2>/dev/null || echo none)"
        [ -f "$BASE/unit.conf" ] && cat "$BASE/unit.conf"
        ip -br addr show br-lan 2>/dev/null
        uci -q show dhcp | grep -E '\.(ignore|force|start|limit)='
        ;;
    *) echo "Usage: $0 apply|watch|status"; exit 1 ;;
esac
