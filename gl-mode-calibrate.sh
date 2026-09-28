#!/bin/sh
#
# gl-mode-calibrate.sh
#
# Discovers which GPIO line the side switch is on and which state means DOT.
# Not needed on the GL-MT3000 (known: gpio-455, dot=lo) — run it on the Opal
# and after any firmware upgrade.
#

CONF_DIR=/etc/gl-mode
CONF="$CONF_DIR/switch.conf"
GPIO=/sys/kernel/debug/gpio

[ -f "$GPIO" ] || mount -t debugfs none /sys/kernel/debug 2>/dev/null
[ -f "$GPIO" ] || { echo "ERROR: $GPIO not readable (no debugfs?)"; exit 1; }

mkdir -p "$CONF_DIR"

pairs() {
    awk '{
        num=""; st="";
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^gpio-[0-9]+$/) { n = $i; sub("gpio-", "", n); num = n }
            else if ($i == "hi" || $i == "lo") { st = $i }
        }
        if (num != "" && st != "") print num, st
    }' "$1"
}

printf 'Put the switch in the DOT position, then press Enter: '; read _d
pairs "$GPIO" > /tmp/gpio.dot
printf 'Move the switch to NO-DOT, then press Enter: '; read _d
pairs "$GPIO" > /tmp/gpio.nodot

CAND=$(awk 'NR==FNR { s[$1]=$2; next } ($1 in s) && s[$1] != $2 { print $1 }' \
       /tmp/gpio.dot /tmp/gpio.nodot)
N=$(echo "$CAND" | grep -c '[0-9]')

if [ "$N" -eq 0 ]; then
    echo "ERROR: no GPIO changed state. Did the switch move?"
    echo "Some firmware exposes it only as an input event; check:"
    echo "  cat /proc/bus/input/devices"
    exit 1
fi

if [ "$N" -gt 1 ]; then
    echo "Several GPIOs changed:"
    for g in $CAND; do grep -E "gpio-$g[^0-9]" "$GPIO"; done
    printf 'Enter the GPIO number to use: '; read GPIO_NUM
else
    GPIO_NUM=$(echo "$CAND" | tr -d ' \n')
fi

DOT_STATE=$(awk -v g="$GPIO_NUM" '$1 == g { print $2 }' /tmp/gpio.dot)
[ -n "$DOT_STATE" ] || { echo "ERROR: no dot state for gpio-$GPIO_NUM"; exit 1; }

cat > "$CONF" <<EOF
# Generated $(date)
# Model: $(cat /tmp/sysinfo/model 2>/dev/null || echo unknown)
GPIO_NUM=$GPIO_NUM
DOT_STATE=$DOT_STATE
EOF

echo
echo "Written to $CONF:  gpio-$GPIO_NUM, dot=$DOT_STATE"
echo "Put the switch back in DOT before commissioning."
