#!/bin/sh
# /usr/bin/gl-uplink.sh - the extender's link to the router (Opal only).
#
# The Opal's wifi script never hands a client (sta) interface to netifd: its
# supplicant setup reports failure even when the link works, so a network on
# top of it stays NO_DEVICE (found on the bench 2026-09-29). This loop does the
# netifd part itself, every 5 s:
#   - while the uplink radio is connected: put UNIT_IP on it, default route
#     via the router, and run relayd between it and br-lan
#   - otherwise (NO-DOT, or out of range): stop relayd
# relayd passes DHCP and broadcasts, so clients of the extender get their
# addresses from the router.

. /etc/gl-mode/site.conf
. /etc/gl-mode/unit.conf
[ "${UNIT_ROLE:-}" = "repeater" ] || exit 0

prefix() {   # dotted netmask -> prefix length
    n=0
    for o in $(echo "$1" | tr '.' ' '); do
        case "$o" in
            255) n=$((n+8)) ;; 254) n=$((n+7)) ;; 252) n=$((n+6)) ;; 248) n=$((n+5)) ;;
            240) n=$((n+4)) ;; 224) n=$((n+3)) ;; 192) n=$((n+2)) ;; 128) n=$((n+1)) ;;
        esac
    done
    echo "$n"
}
PFX=$(prefix "$NETMASK")
log() { logger -t gl-uplink "$*"; }

RPID=''; RKEY=''; STATE=''
stop_relay() {
    [ -n "$RPID" ] && kill "$RPID" 2>/dev/null
    RPID=''; RKEY=''
}
trap 'stop_relay; exit 0' TERM INT
# A relayd left over from a previous run (or GL's own service) would fight ours.
killall relayd 2>/dev/null

while true; do
    D=''
    if [ "$(uci -q get wireless.uplink.disabled)" = "0" ]; then
        D=$(iw dev 2>/dev/null | awk '/Interface/ {n=$2} /type managed/ {print n; exit}')
    fi
    if [ -n "$D" ] && iw dev "$D" link 2>/dev/null | grep -q '^Connected'; then
        [ "$STATE" = up ] || { log "uplink $D connected"; STATE=up; }
        echo 1 > /proc/sys/net/ipv4/ip_forward
        ip -4 addr show dev "$D" | grep -q "inet $UNIT_IP/" \
            || { ip addr add "$UNIT_IP/$PFX" dev "$D" && log "$UNIT_IP added to $D"; }
        ip route show default | grep -q "via $ROUTER_IP dev $D" \
            || ip route replace default via "$ROUTER_IP" dev "$D"
        # Forwarding between the uplink and the LAN. GL's firewall keeps coming
        # back (FORWARD policy DROP, uplink in no zone), so the two accept rules
        # are re-checked here every pass rather than relying on it staying off.
        for dir in -i -o; do
            iptables -C FORWARD $dir "$D" -j ACCEPT 2>/dev/null \
                || { iptables -I FORWARD 1 $dir "$D" -j ACCEPT && log "forward rule $dir $D added"; }
        done
        # restart relayd if it died or either interface was recreated
        KEY="$D:$(cat /sys/class/net/$D/ifindex 2>/dev/null):$(cat /sys/class/net/br-lan/ifindex 2>/dev/null)"
        if [ -z "$RPID" ] || ! kill -0 "$RPID" 2>/dev/null || [ "$KEY" != "$RKEY" ]; then
            stop_relay
            relayd -I br-lan -I "$D" -L "$UNIT_IP" -G "$ROUTER_IP" -D -B &
            RPID=$!; RKEY="$KEY"
            log "relayd started (br-lan <-> $D, pid $RPID)"
        fi
    else
        if [ "$STATE" != down ]; then log "uplink not connected"; STATE=down; fi
        [ -n "$RPID" ] && { stop_relay; log "relayd stopped"; }
    fi
    sleep 5
done
