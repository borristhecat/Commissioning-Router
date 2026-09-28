#!/bin/sh
#
# install.sh - fetch the GL mode-switch kit onto this router.
#
#   wget -qO /tmp/install.sh <RAW_URL>/install.sh && sh /tmp/install.sh 'wifi-key'
#
# Installs the files only. It does NOT build or commission - run those
# yourself afterwards (see README). Safe to re-run: it refreshes the scripts
# and keeps an existing /etc/gl-mode/unit.conf, updating only its WIFI_KEY.
#
# The wifi key is passed as an argument so it never lives in this public repo.
# Single-quote it on the command line.

set -u

KEY="${1:-}"
[ -n "$KEY" ] || { echo "Usage: sh install.sh 'wifi-key' [base-url]"; exit 1; }
case "$KEY" in *"'"*) echo "ERROR: key contains a single quote; not supported."; exit 1 ;; esac

BASE="${2:-https://raw.githubusercontent.com/borristhecat/Commissioning-Router/main}"
case "$BASE" in *OWNER/REPO*) echo "ERROR: install.sh still has the placeholder URL. Edit BASE."; exit 1 ;; esac

fetch() {   # $1 = file in repo, $2 = destination
    tmp="$2.new"
    if ! wget -q -O "$tmp" "$BASE/$1"; then
        rm -f "$tmp"; echo "FAILED to fetch $1"; exit 1
    fi
    [ -s "$tmp" ] || { rm -f "$tmp"; echo "FAILED: $1 is empty"; exit 1; }
    sed -i 's/\r$//' "$tmp"
    mv "$tmp" "$2"
    echo "  $2  ($(wc -l < "$2") lines)"
}

echo "Fetching kit from $BASE"
mkdir -p /etc/gl-mode
fetch site.conf             /etc/gl-mode/site.conf
fetch gl-mode.sh            /usr/bin/gl-mode.sh
fetch modewatch             /etc/init.d/modewatch
fetch gl-build.sh           /root/gl-build.sh
fetch gl-mode-commission.sh /root/gl-mode-commission.sh
fetch gl-mode-calibrate.sh  /root/gl-mode-calibrate.sh
fetch gl-safe.sh            /root/gl-safe.sh
chmod +x /usr/bin/gl-mode.sh /etc/init.d/modewatch /root/gl-*.sh

U=/etc/gl-mode/unit.conf
if [ -f "$U" ]; then
    sed -i '/^WIFI_KEY=/d' "$U"
    echo "WIFI_KEY='$KEY'" >> "$U"
    echo "Kept existing $U, updated WIFI_KEY."
else
    cat > "$U" <<EOF
UNIT_ROLE=router
UNIT_IP=172.24.172.1
AP_MGMT_IP=172.24.172.254
SSID_SUFFIX=''
CH_24=1
CH_5=36
WIFI_KEY='$KEY'
EOF
    echo "Wrote default router $U - edit it for an extender unit."
fi
chmod 600 "$U"

ok=1
for f in /usr/bin/gl-mode.sh /root/gl-build.sh /root/gl-mode-commission.sh /root/gl-mode-calibrate.sh /root/gl-safe.sh; do
    sh -n "$f" || { echo "SYNTAX ERROR in $f"; ok=0; }
done
[ "$ok" = 1 ] || exit 1

echo
echo "Installed. Next, with the switch in DOT:"
echo "  Remote (GoodCloud):  sh /root/gl-safe.sh      (rolls back if the unit loses internet)"
echo "  On the LAN cable:    sh /root/gl-build.sh  then  sh /root/gl-mode-commission.sh"
