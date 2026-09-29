# Commissioning-Router

The side switch on a GL.iNet unit picks one of two complete setups:

- **Dot** - the unit's role: a router, or a wifi extender of the router
- **No dot** - an access point bridged onto whatever the WAN port is plugged into
  (no DHCP server, no firewall, fixed management address)

## Recommended units

| Unit | Roles | Firmware tested |
| --- | --- | --- |
| GL-MT3000 (Beryl AX) | router | GL 4.9.0, 4.11.0 |
| GL-SFT1200 (Opal) | router or extender | GL 4.8.3 |

Other models are not supported. The scripts detect which of these two they are
running on.

## Addresses and wifi

| | Router | Extender |
| --- | --- | --- |
| Dot: address | 172.24.172.1, DHCP .230-.249 | 172.24.172.5 (over its wifi link to the router) |
| Dot: wifi | `Legrand-TechNet` / `Legrand-TechNet_5G` | `Legrand-TechNet_5G_Ext1` (2.4 GHz is its link to the router) |
| No dot: address | 172.24.172.254 + a DHCP lease | 172.24.172.5 + a DHCP lease |
| No dot: wifi | same names, channels 1 / 36 | `_Ext1` names, channels 11 / 44 |

All wifi is 20 MHz, maximum power, region DE. The wifi key is not stored in
this repo; it is given to `install.sh` on the command line.

## Onboard a unit (new or existing)

1. New unit only: in the web page at 192.168.8.1 set the admin password (it is
   also the SSH root password) and, for remote access, bind it to GoodCloud and
   turn on Remote SSH.
2. The unit has internet on its WAN port (a cable, or for an extender any cable
   with internet) and the switch is in **dot**.
3. SSH in: locally `ssh root@192.168.8.1` (new unit) or its kit address, or
   GoodCloud > Remote SSH. An Opal needs
   `ssh -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa root@<address>`
   from Windows.
4. Run one line, with `router` or `repeater` (extender, Opal only):

   ```sh
   wget -qO /tmp/install.sh https://raw.githubusercontent.com/borristhecat/Commissioning-Router/main/install.sh && sh /tmp/install.sh 'wifi-key' router && sh /root/gl-safe.sh
   ```

5. The session drops when networking restarts. Reconnect after 2 minutes at the
   unit's dot address and check:

   ```sh
   tail -n 5 /root/gl-safe.log; sh /usr/bin/gl-mode.sh status
   ```

   `ONLINE ... keeping the new config` = done. If the unit had no internet 5
   minutes after the build, it put its old setup back and rebooted; the log
   says why.

An extender needs its router already running and in range (keep them a
couple of metres apart - side by side can fail).

## Update the scripts only

Keeps the unit's role and setup:

```sh
wget -qO /tmp/install.sh https://raw.githubusercontent.com/borristhecat/Commissioning-Router/main/install.sh && sh /tmp/install.sh 'wifi-key' && /etc/init.d/gl-uplink restart
```

## Undo

`sh /root/gl-safe.sh rollback` restores the setup saved before the last
`gl-safe.sh` run and reboots.

## Files

| File | On the unit | Does |
| --- | --- | --- |
| `install.sh` | `/tmp` | fetches the rest, writes `/etc/gl-mode/unit.conf` for the role |
| `site.conf` | `/etc/gl-mode/` | shared addresses, names, radio settings |
| `gl-safe.sh` | `/root` | build + commission, rolls back if the unit loses internet |
| `gl-build.sh` | `/root` | writes the dot setup for the role |
| `gl-mode-commission.sh` | `/root` | saves the dot setup, derives the no-dot one, starts the switch watcher |
| `gl-mode.sh` + `modewatch` | `/usr/bin`, `/etc/init.d` | watches the switch and swaps setups |
| `gl-uplink.sh` + `gl-uplink` | `/usr/bin`, `/etc/init.d` | extender only: uplink address, route and relayd |
| `gl-mode-calibrate.sh` | `/root` | finds the switch GPIO on an unknown unit |

## How the extender works

The Opal cannot bridge a wifi client (no 4-address mode), so the extender
relays instead: its 2.4 GHz radio joins the router, `gl-uplink` gives that link
172.24.172.5 and a route via .1, and relayd passes DHCP and broadcasts between
it and the local bridge. Clients get addresses from the router. The Opal's own
wifi script never hands the client link to netifd, which is why `gl-uplink`
does this itself; it rechecks every 5 seconds and logs to
`logread -e gl-uplink`. GL's firmware restarts its firewall on its own, so
`gl-uplink` also keeps two FORWARD accept rules for the link in place.
