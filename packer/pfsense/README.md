# pfSense edge firewall — `fw01`

Adds a pfSense CE firewall in front of the lab so the range is segmented into
**WAN / DMZ / LAN** instead of one flat network. The attacker (Kali) sits on the
outside WAN; `WEB01` sits alone in a DMZ; all AD hosts sit on the internal LAN.
The only inbound path is the web app, and the attacker must breach it and pivot
through the firewall to reach Active Directory — see `docs/architecture.md`
("Network segmentation").

```
  ATTACK (Kali) 192.168.50.66
        │  WAN  lab-wan  192.168.50.0/24
   ┌────┴─────┐
   │ pfSense  │  fw01   NAT :80/:443 ──► WEB01
   │ .254 all │
   └─┬──────┬─┘
 DMZ │      │ LAN
 lab-dmz    lab-lan
 172.20.1/24   10.20.10/24
   WEB01 .40   DC01 .10  SRV01 .20  WS01 .31  WS02 .32
```

Interface / IP plan:

| Zone | libvirt network | subnet          | pfSense (gw / DHCP / DNS relay) | host mgmt | NIC  |
|------|------------------|-----------------|----------------------------------|-----------|------|
| WAN  | lab-wan          | 192.168.50.0/24 | 192.168.50.254                   | .1        | em0  |
| LAN  | lab-lan          | 10.20.10.0/24   | 10.20.10.254                     | .1        | em1  |
| DMZ  | lab-dmz          | 172.20.1.0/24   | 172.20.1.254                     | .1        | em2  |

The host keeps a `.1` management adapter on **every** lab network (see
`scripts/setup-networks.sh` — none of them define a `<forward>` element), so
Ansible still reaches every guest directly for provisioning — the firewall
only governs traffic **between guest VMs**, whose default gateway is pfSense.
WAN uses `192.168.50.0/24`, distinct from libvirt's own default NAT network
(usually `192.168.122.0/24`), so the two never collide. `config.xml` leaves
the WAN "block private networks"/"block bogons" options off, so a private WAN
subnet isn't blocked at the edge either.

## Files

- `config.xml` — **the actual firewall configuration** (interfaces, DHCP with
  deterministic static-MAC mappings, NAT port-forward, firewall rules). This is
  the deliverable; the VM is just a vehicle for it.

## Building the VM

### About the installer (Netgate Installer, network-based)

The ISO in use is the **Netgate Installer** (`netgate-installer-v1.2-RELEASE-amd64.iso`).
Unlike the old self-contained pfSense CE ISO, it boots a small live FreeBSD
environment and **downloads** the pfSense CE image from Netgate's repos during
install (`pfSense-repoc-static` is on the media; there is no bundled OS
image). Two consequences:

- **It needs internet during install.** The install VM's first NIC must be on
  libvirt's `default` NAT network (outbound access), *not* the isolated lab
  networks. The three lab NICs are attached afterward, once the base install
  and config restore are done.
- **It's interactive and can't be scripted like the Windows/Ubuntu
  autounattend/cloud-init builds.** The installer wizard has no unattended
  mode, so this VM is driven by hand over VNC — see the steps below.

### Manual install + config restore (~10 min, once)

1. Create the VM, NIC on the NAT network only, then use `virsh domdisplay
   fw01` to get its VNC endpoint and drive the rest with a VNC client (or
   `vncdotool`) since there's no serial/unattended path:
   ```
   virt-install --name fw01 --memory 1024 --vcpus 1 \
     --disk pool=halcyon-lab,size=8,sparse=yes,bus=sata \
     --network network=default,model=e1000 \
     --cdrom /path/to/netgate-installer-v1.2-RELEASE-amd64.iso \
     --os-variant freebsd13.0 --graphics vnc --noautoconsole
   ```
2. Work through the Netgate installer: accept the EULA, choose **Install pfSense
   CE** (Community Edition — no registration), accept the Auto/ZFS defaults. It
   downloads and installs CE, then reboots.
3. After reboot, at the console say **no** to VLANs; if it prompts for interface
   assignment just accept whatever it offers — the config restore in step 5
   overrides all of it. Note the LAN IP it prints.
4. Browse to that LAN IP (reachable over the NAT network); log in
   `admin` / `pfsense`.
5. **Diagnostics → Backup & Restore → Restore configuration** → upload
   `packer/pfsense/config.xml` → restore. pfSense reboots fully configured
   (interfaces wan=em0/lan=em1/opt1=em2, DHCP, NAT, firewall rules). This step
   can be scripted with `curl` (CSRF-token login, then a multipart upload to
   `/diag_backup.php`) once you have the admin session cookie.
6. Shut the VM down, detach the NAT NIC, and attach the three lab NICs in
   order — `lab-wan` (em0), `lab-lan` (em1), `lab-dmz` (em2):
   ```
   virsh detach-interface fw01 network --mac <nat-nic-mac> --config
   virsh attach-interface fw01 network lab-wan --model e1000 --config
   virsh attach-interface fw01 network lab-lan --model e1000 --config
   virsh attach-interface fw01 network lab-dmz --model e1000 --config
   virsh start fw01
   ```

## Interface-order gotcha

If after boot the zones look wrong (e.g. LAN IP on the WAN port), the NIC↔`emN`
mapping came up in a different order. Fix it once from console **option 1
(Assign Interfaces)**: set `WAN=em0`, `LAN=em1`, `OPT1(DMZ)=em2`, matching the
attach order above. Then re-restore `config.xml`.

## Login / password

`admin` / `pfsense` (pfSense factory default; `config.xml` keeps it). If a
restore ever leaves you locked out, console **option 3 (Reset webConfigurator
password)** forces `admin` / `pfsense` back regardless of the stored hash.
Change it for anything but a throwaway lab.

## Tightening DMZ → LAN (optional, harder variant)

`config.xml` ships DMZ → LAN as an **allow-all pivot** (rule tracker
`1000000022`, "DMZ pivot"). This is deliberate: `WEB01` legitimately needs AD,
DNS, and MSSQL on the LAN, and every kill-chain path (Kerberoast/MSSQL on
`SRV01`, lateral movement to `WS01/WS02`, DCSync/ADCS RPC+SMB to `DC01`) needs
more than the four "AD ports" would allow — locking it down naively makes the
range unsolvable.

For a harder "pivot only via `DC01`" variant, in **Firewall → Rules → DMZ**
replace that pass rule's destination with `DC01 (10.20.10.10)` and the port set
`53, 88, 135, 139, 389, 445, 464, 636, 3268, 3269, 9389, 49152–65535`. The
attacker then has to land on `DC01` first and pivot onward from there. Leave
**WAN → LAN blocked** either way — that is the control that makes the web app
the sole entry point.
