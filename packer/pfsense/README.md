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

### About the installer (Netgate Installer, network-based)

The ISO in use is the **Netgate Installer** (`netgate-installer-v1.2-RELEASE-amd64.iso`,
decompressed to `/mnt/halcyon-lab/isos/`). Unlike the old self-contained pfSense
CE ISO, it boots a small live FreeBSD environment and **downloads** the pfSense
CE image from Netgate's repos during install (`pfSense-repoc-static` is on the
media; there is no bundled OS image). Two consequences:

- **It needs internet during install.** The install VM's NIC must be on
  **`vmnet8`** (the NAT network with outbound access), *not* the isolated lab
  vmnets. You attach the three lab NICs later, at box-run time, via the
  Vagrantfile; the base install just needs one internet-capable NIC.
- **It's interactive and is not Packer-automated here.** A `communicator =
  "none"` build can neither drive the wizard nor detect completion, and the
  wizard isn't a fixed keystroke script — so `pfsense.pkr.hcl` is kept only as a
  box-packaging reference. The real build is the manual path below.

### Reliable path: manual install + config restore (~10 min, once)

1. VMware Workstation GUI → **New VM** → installer disc image =
   `/mnt/halcyon-lab/isos/netgate-installer-v1.2-RELEASE-amd64.iso` → guest OS
   **FreeBSD 13+ 64-bit** → 1 GB RAM, 1 vCPU, **8 GB SATA disk**, **one NIC on
   NAT (`vmnet8`)** for internet. Power on.
2. Work through the Netgate installer: accept the EULA, choose **Install pfSense
   CE** (Community Edition — no registration), accept the Auto/ZFS defaults. It
   downloads and installs CE, then reboots.
3. After reboot, at the console say **no** to VLANs; if it prompts for interface
   assignment just accept whatever it offers — the config restore in step 5
   overrides all of it. Note the LAN IP it prints.
4. Browse to that LAN IP (over `vmnet8`/the console-shown address); log in
   `admin` / `pfsense`.
5. **Diagnostics → Backup & Restore → Restore configuration** → upload
   `packer/pfsense/config.xml` → restore. pfSense reboots fully configured
   (interfaces wan=em0/lan=em1/opt1=em2, DHCP, NAT, firewall rules).
6. Shut the VM down and package it:
   `vagrant package --base <vm-name> --output /mnt/halcyon-lab/packer-output/boxes/halcyon-pfsense.box`
   then `vagrant box add halcyon/pfsense <that .box> --force`.

Once step 2's base install is done and the VM is registered in VMware, steps 5–6
are mechanical and can be handed off to be finished for you.

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
