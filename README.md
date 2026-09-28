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

Then put the switch in **dot** and wait a minute for the unit to settle.

**Remote (GoodCloud Remote SSH) - always use this:**

```sh
sh /root/gl-safe.sh
```

Saves the current config, builds, commissions, then checks the unit can
still reach the internet. If it cannot within 5 minutes, it restores the saved
config and reboots, so the unit comes back as it was. Your session will drop
when networking restarts; reconnect after a few minutes and read
`/root/gl-safe.log`. `sh /root/gl-safe.sh rollback` restores the saved config
by hand later.

**Local, on the LAN cable:**

```sh
sh /root/gl-build.sh
sh /root/gl-mode-commission.sh
```

The build refuses to run unless the switch is in dot and the live config is
router mode, and it stops any original `switch_watcher` itself. It runs
detached and logs to `/root/gl-build.log`, so a dropped session cannot stop it
part-way. The log's last line is `EXIT=<code>`.

## Retrofitting a unit running the original switch_logic.sh

Switch to **dot first**, wait for router mode, then install and run as above.
No need to stop the old watcher by hand - the build does it. Once the flip test
passes:

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
