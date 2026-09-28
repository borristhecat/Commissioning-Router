# Commissioning-Router

Makes the side switch on a GL.iNet GL-MT3000 select between two whole
configurations:

- **Dot** - the unit's own role (router: LAN 172.24.172.1/24, DHCP server)
- **No dot** - AP / inline bridge: WAN bridged into LAN, no DHCP server,
  firewall off, static management address plus a customer lease if offered

Supported units:

| Unit | Firmware tested | Switch | Notes |
| --- | --- | --- | --- |
| GL-MT3000 (Beryl AX) | GL 4.9.0, 4.11.0 | gpio-455, dot = `lo` | MediaTek driver, HE20 |
| GL-SFT1200 (Opal) | GL 4.8.3 (first bench test pending) | gpio-1, dot = `hi` (opposite of the MT3000) | mac80211, HT20/VHT20, OpenWrt 18.06 |

The scripts detect the platform: wifi sections, channel width, transmit power
and interface syntax are chosen per unit.

## Install on a router

Over SSH (local, or GoodCloud Remote SSH). Single-quote the wifi key:

```sh
wget -qO /tmp/install.sh https://raw.githubusercontent.com/borristhecat/Commissioning-Router/main/install.sh
sh /tmp/install.sh 'wifi-key-here'             # router (default)
sh /tmp/install.sh 'wifi-key-here' repeater    # extender
```

Giving a role rewrites `/etc/gl-mode/unit.conf` for it. Without one, an
existing `unit.conf` is kept.

### Roles

| | Router | Extender (`repeater`) |
| --- | --- | --- |
| Dot | router at .1, DHCP server, own SSIDs | joins the router's `Legrand-TechNet` wifi and bridges it; fixed at .5, gateway .1, DHCP off, broadcasts `_Ext1` SSIDs |
| No dot | AP / inline bridge, mgmt .254 | AP / inline bridge, mgmt .5, uplink off |
| Channels (no dot) | 1 / 36 | 11 / 44 |

The extender's uplink uses 2.4 GHz as a dedicated backhaul by default
(`UPLINK_BAND=2g` in `unit.conf`): in dot it broadcasts only the 5 GHz `_Ext1`
network, so clients and backhaul never share a radio. `UPLINK_RADIO_AP=on`
brings the 2.4 GHz `_Ext1` back for 2.4-only devices. In no dot both bands
broadcast. `gl-mode.sh status` on an extender shows the
uplink's signal - use that, not a laptop's signal bars, to place it.

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
