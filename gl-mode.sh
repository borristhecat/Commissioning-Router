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

    if [ -x /etc/init.d/mtk-wifi-configurator ]; then
        /etc/init.d/mtk-wifi-configurator restart 2>/dev/null
    else
        wifi reload 2>/dev/null || wifi 2>/dev/null
    fi

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
