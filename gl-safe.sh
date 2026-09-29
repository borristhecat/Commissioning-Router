#!/bin/sh
#
# gl-safe.sh - build and commission with automatic rollback.
#
# Use this whenever you are NOT on the LAN cable - e.g. over GoodCloud Remote
# SSH - so a unit that loses its internet connection puts itself back instead
# of needing a factory reset.
#
#   sh /root/gl-safe.sh             build + commission, keep if online, else roll back
#   sh /root/gl-safe.sh rollback    put the saved config back by hand, and reboot
#
# What it does:
#   1. Refuses to start unless the unit can reach the internet right now.
#   2. Saves the current config, rc.local and any original switch scripts to
#      /root/gl-rollback.tar.gz.
#   3. Runs gl-build.sh then gl-mode-commission.sh back to back - no gap in
#      which a reboot could bring the original watcher back.
#   4. Waits up to 5 minutes for the internet to come back.
#   5. Still offline: restores the saved files, disables the new watcher and
#      reboots. The unit comes back exactly as it was before step 2.
#
# It runs detached, like gl-build.sh: the session WILL drop when networking
# restarts. Reconnect after a few minutes and read /root/gl-safe.log.

set -u
LOG=/root/gl-safe.log
SNAP=/root/gl-rollback.tar.gz
INFO=/root/gl-rollback.info
WAIT=300

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

stamp() { echo "[$(date '+%H:%M:%S')] $*"; }

online() {
    ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 || ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1
}

rollback() {
    [ -f "$SNAP" ] || { stamp "ERROR: no snapshot at $SNAP - cannot roll back."; return 1; }
    stamp "Rolling back to the config saved before the build."
    /etc/init.d/modewatch stop 2>/dev/null
    tar -xzf "$SNAP" -C / || { stamp "ERROR: restore failed."; return 1; }
    WATCH_WAS=no
    [ -f "$INFO" ] && . "$INFO"
    if [ "$WATCH_WAS" = "no" ]; then
        /etc/init.d/modewatch disable 2>/dev/null
        stamp "New watcher disabled (it was not enabled before)."
    fi
    stamp "Restored. Rebooting in 5 seconds."
    sync
    sleep 5
    reboot
}

if [ "${1:-}" = "rollback" ]; then
    rollback
    exit $?
fi

stamp "gl-safe starting on $(cat /etc/glversion 2>/dev/null || echo '?')"

# 1. must be online now, or the check at the end means nothing
if ! online; then
    stamp "ERROR: no internet right now, so a rollback check afterwards would be meaningless."
    stamp "       Nothing changed. Fix the connection first."
    exit 1
fi
stamp "Internet reachable before the build."

for f in /root/gl-build.sh /root/gl-mode-commission.sh; do
    [ -f "$f" ] || { stamp "ERROR: $f missing - run install.sh first. Nothing changed."; exit 1; }
done

# 2. snapshot
FILES="etc/config etc/rc.local etc/sysupgrade.conf"
for f in etc/gl-mode usr/bin/switch_logic.sh usr/bin/switch_watcher.sh; do
    [ -e "/$f" ] && FILES="$FILES $f"
done
WATCH_WAS=no
[ -e /etc/rc.d/S99modewatch ] && WATCH_WAS=yes
if ! tar -czf "$SNAP" -C / $FILES; then
    stamp "ERROR: could not save a snapshot. Nothing changed."
    exit 1
fi
echo "WATCH_WAS=$WATCH_WAS" > "$INFO"
stamp "Snapshot saved: $SNAP ($FILES)"

# 3. build, then commission straight after
stamp "Running gl-build.sh"
GL_DETACHED=1 sh /root/gl-build.sh
B=$?
stamp "gl-build.sh exited $B"
C=skipped
if [ "$B" = 0 ]; then
    stamp "Running gl-mode-commission.sh"
    GL_DETACHED=1 sh /root/gl-mode-commission.sh
    C=$?
    stamp "gl-mode-commission.sh exited $C"
fi

# 4. wait for the internet
stamp "Checking internet for up to $WAIT seconds"
t=0
while [ "$t" -lt "$WAIT" ]; do
    online && break
    sleep 10
    t=$((t + 10))
done

# 5. keep or roll back
if online; then
    stamp "ONLINE after ${t}s - keeping the new config."
    stamp "build=$B commission=$C"
    stamp "Snapshot kept at $SNAP; 'sh /root/gl-safe.sh rollback' restores it."
    [ "$B" = 0 ] && [ "$C" = 0 ] && exit 0
    exit 2
fi

stamp "STILL OFFLINE after ${WAIT}s (build=$B commission=$C)."
# The system log is in RAM and the rollback reboots, so keep what explains
# the failure here first.
stamp "Diagnostics before rollback:"
ip -br addr 2>/dev/null
ip route 2>/dev/null
for i in uplink wan lan; do
    ifstatus "$i" >/dev/null 2>&1 && echo "$i: $(ifstatus "$i" | grep -o '"up": [a-z]*')"
done
if command -v iw >/dev/null; then
    for i in $(iw dev | awk '/Interface/ {n=$2} /type managed/ {print n}'); do
        echo "--- $i"; iw dev "$i" link 2>/dev/null
    done
fi
pidof relayd >/dev/null && echo "relayd running" || echo "relayd NOT running"
logread 2>/dev/null | grep -iE 'wpa_supplicant|relayd|netifd' | tail -n 40
rollback
