# Commissioning-Router

Makes the side switch on a GL.iNet GL-MT3000 select between two whole
configurations:

- **Dot** - the unit's own role (router: LAN 172.24.172.1/24, DHCP server)
- **No dot** - AP / inline bridge: WAN bridged into LAN, no DHCP server,
  firewall off, static management address plus a customer lease if offered

Tested on GL firmware 4.9.0 and 4.11.0 (kernel 5.4.211). Switch is gpio-455,
dot = `lo`.

## Install on a router

Over SSH (local, or GoodCloud Remote SSH). Single-quote the wifi key:

```sh
wget -qO /tmp/install.sh https://raw.githubusercontent.com/borristhecat/Commissioning-Router/main/install.sh
sh /tmp/install.sh 'wifi-key-here'
```

Then with the switch in **dot**:

```sh
sh /root/gl-build.sh
sh /root/gl-mode-commission.sh
```

Build restarts networking - run it over the LAN cable when local.

## Retrofitting a unit running the old switch_logic.sh

Stop the old watcher first, then install as above. Busybox has no pkill:

```sh
ps | grep switch_watcher | grep -v grep
kill <PID>
```

Commissioning removes the old scripts and their rc.local line itself.
Afterwards, once it works:

```sh
rm -f /etc/config/network.ap /etc/config/network.router
```

## Check

```sh
/usr/bin/gl-mode.sh status
logread -e gl-mode
```

## Not in this repo

The wifi key. It lives only in `/etc/gl-mode/unit.conf` on each device.
