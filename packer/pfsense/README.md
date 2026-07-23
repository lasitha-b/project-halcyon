# pfSense edge firewall — `fw01`

Adds a pfSense CE firewall in front of the lab so the range is segmented into
**WAN / DMZ / LAN** instead of one flat network. The attacker (Kali) sits on the
outside WAN; `WEB01` sits alone in a DMZ; all AD hosts sit on the internal LAN.
The only inbound path is the web app, and the attacker must breach it and pivot
through the firewall to reach Active Directory — see `docs/architecture.md`
("Network segmentation").

```
  ATTACK (Kali) 203.0.113.66
        │  WAN  vmnet22  203.0.113.0/24
   ┌────┴─────┐
   │ pfSense  │  fw01   NAT :80/:443 ──► WEB01
   │ .254 all │
   └─┬──────┬─┘
 DMZ │      │ LAN
 vmnet21    vmnet20
 172.20.1/24   10.20.10/24
   WEB01 .40   DC01 .10  SRV01 .20  WS01 .31  WS02 .32
```

Interface / IP plan:

| Zone | vmnet  | subnet          | pfSense (gw / DHCP / DNS relay) | host mgmt | NIC  |
|------|--------|-----------------|---------------------------------|-----------|------|
| WAN  | vmnet22| 203.0.113.0/24  | 203.0.113.254                   | .1        | em0  |
| LAN  | vmnet20| 10.20.10.0/24   | 10.20.10.254                    | .1        | em1  |
| DMZ  | vmnet21| 172.20.1.0/24   | 172.20.1.254                    | .1        | em2  |

The host keeps a `.1` management adapter on **every** vmnet (VMware host-only
adapters), so Ansible still reaches every guest directly for provisioning — the
firewall only governs traffic **between guest VMs**, whose default gateway is
pfSense. WAN uses `203.0.113.0/24` (TEST-NET-3, non-RFC1918) on purpose, so
pfSense's default "block private networks" WAN rule doesn't interfere.

## Files

- `config.xml` — **the actual firewall configuration** (interfaces, DHCP with
  deterministic static-MAC mappings, NAT port-forward, firewall rules). This is
  the deliverable; the box is just a vehicle for it.
- `pfsense.pkr.hcl` — best-effort automated box build from the pfSense CE ISO.

## Building the box

### Reliable path (recommended): manual install + config restore

pfSense CE has no unattended-install answer file, so a scripted install is
inherently brittle. The dependable way, ~10 minutes, once:

1. Create/boot a VM from the pfSense CE ISO with **three e1000 NICs** in this
   order: `vmnet22` (WAN), `vmnet20` (LAN), `vmnet21` (DMZ). Order fixes
   `em0/em1/em2`.
2. Run the installer, accepting all defaults (Auto/ZFS). Reboot when prompted.
3. At the console, if it asks to set up interfaces/VLANs, decline VLANs and let
   it assign `em0→WAN, em1→LAN, em2→DMZ` (or just skip — the restore fixes it).
4. From a browser on the LAN management adapter, open `https://10.20.10.254`
   (or the pfSense-assigned LAN IP shown on the console). Log in `admin` /
   `pfsense`.
5. **Diagnostics → Backup & Restore → Restore configuration** → upload
   `config.xml` → restore. pfSense reboots fully configured.
6. Capture it as a Vagrant box:
   `vagrant package --base <vm-name> --output /mnt/halcyon-lab/packer-output/boxes/halcyon-pfsense.box`
   then `vagrant box add halcyon/pfsense <that .box> --force`.

### Automated path (best-effort)

`scripts/build-images.sh` runs `packer build packer/pfsense/pfsense.pkr.hcl`
with `HALCYON_PFSENSE_ISO`. The `boot_command` keystroke timings in the template
**will likely need tuning** on your host — watch the first run over VNC (endpoint
is printed in the Packer log) and adjust the `<waitNs>` values. If it drifts, use
the manual path above; the result is identical.

## Interface-order gotcha

If after boot the zones look wrong (e.g. LAN IP on the WAN port), the NIC↔`emN`
mapping came up in a different order. Fix it once from console **option 1
(Assign Interfaces)**: set `WAN=em0`, `LAN=em1`, `OPT1(DMZ)=em2`, matching the
Vagrantfile NIC order. Then re-restore `config.xml`.

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
