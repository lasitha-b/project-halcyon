# Project Halcyon — Custom AD + Web Pentest Range

A self-hosted, deliberately vulnerable practice range for Active Directory and web
application penetration testing, built for local **KVM/libvirt** deployment.

This is **not** a fork of GOAD (Game of Active Directory) or any public lab. It uses an
original topology, naming scheme, and web application, and randomizes secrets and which
vulnerability paths are active on every deploy — see `docs/architecture.md` for why.

## What's inside

- `corp.halcyon.local` — single-forest AD domain: a DC (with AD CS), an MSSQL server,
  two Windows clients, and a domain-joined Linux web server (Ubuntu, SSSD).
- A **pfSense edge firewall** (`fw01`) segmenting the range into WAN / DMZ / LAN, so the
  attacker starts outside the perimeter and must breach the web app and pivot inward —
  direct access to the internal AD network is blocked at the edge. See
  `docs/architecture.md` ("Network segmentation").
- A hand-written vulnerable intranet web app (Flask) as the only external entry point,
  reachable from the outside solely via the firewall's port-forward.
- Non-CVE, configuration-class vulnerabilities only: OWASP-style web bugs, Kerberos
  misconfigs, ACL abuse, ADCS ESC1/ESC4/ESC6/ESC8, delegation/RBCD, NTLM relay,
  MSSQL misconfig, endpoint credential exposure.
- Windows Defender AV **on** throughout — this is not an AV-off lab.

## Deployment targets: KVM (local) or AWS

**Local KVM/libvirt** is the primary/reference deployment (below). This is a
**one-time deployment**, not a repeatable pipeline: the seven VMs are
built once (see "Building the VMs" below) and left running under libvirt. There
is no snapshot/reset flow — if you need a fresh deployment, tear the VMs down
and rebuild.

**AWS** is also supported, via `terraform/` + `scripts/aws-deploy.sh` —
see `docs/architecture-aws.md` for the topology and, importantly, the
deliberate scope differences from the KVM version (no pfSense edge firewall,
WS01/WS02 become Windows Server 2022 instead of real Windows 11 clients).
This is a **paid, always-on environment** while running — use
`scripts/aws-destroy.sh` when done; see `terraform/budget.tf` for a cost
backstop alarm.

## Requirements

- Linux host with KVM/QEMU + libvirt (`virt-install`, `virsh`) —
  Rocky/RHEL/Fedora: `dnf install qemu-kvm libvirt virt-install libguestfs-tools-c`;
  Debian/Ubuntu: `apt install qemu-kvm libvirt-daemon-system virtinst libguestfs-tools`
- `genisoimage`/`mkisofs` (to build the unattended-install seed ISOs) and
  `qemu-img` (disk conversion for the Kali image)
- Ansible (control node, native on Linux):
  ```
  pip3 install -r requirements-control.txt
  ansible-galaxy collection install -r ansible/requirements.yml
  ```
- Windows Server 2022 and Windows 11 evaluation ISOs (Microsoft eval, 180-day)
- Ubuntu 22.04 Server ISO
- pfSense CE (Netgate Installer ISO) for the edge firewall — see
  `packer/pfsense/README.md`
- A Kali Linux image (VMware `.vmdk` or similar, converted to qcow2 — see
  "Building the VMs")
- Host: ≥32 GB RAM, ≥100 GB free disk for VM storage (disks are created sparse,
  not preallocated, since this is a single lab deployment rather than a
  reusable image pipeline), network access disabled to any real/production LAN

## Building the VMs

There is no equivalent of the old `build-images.sh`/Vagrantfile clone step —
each VM is created directly with `virt-install` against its own installer
media, then handed off to Ansible for provisioning:

1. `scripts/setup-networks.sh` — one-time host prep: defines the three isolated
   libvirt networks (`lab-wan`/`lab-dmz`/`lab-lan`, matching the IP scheme
   below) and the VM storage pool. Idempotent; also run automatically by
   `scripts/deploy.sh`.
2. **`fw01` (pfSense)** — built manually via the Netgate installer + a
   `config.xml` restore. This step is interactive (the installer isn't
   scriptable) — see `packer/pfsense/README.md` for the full walkthrough.
3. **`dc01`/`srv01`/`ws01`/`ws02` (Windows)** — `virt-install` against the
   Windows ISO with a generated `autounattend.xml` seed ISO
   (`--boot uefi=off --machine pc`, BIOS/MBR firmware — required for the
   existing unattend files' disk layout; `bus=sata` + `e1000e` NIC, not
   virtio). Each VM's NICs attach directly to its lab segment(s) per
   `ansible/inventory.yml`.
4. **`web01` (Ubuntu)** — `virt-install` against the Ubuntu ISO with a
   cloud-init NoCloud seed ISO (`user-data`/`meta-data`), NIC on `lab-dmz`.
5. **`attack` (Kali)** — convert the Kali VMware image to qcow2
   (`qemu-img convert -O qcow2 kali.vmdk attack.qcow2`) and `virt-install
   --import` it. It gets two NICs: one on `lab-wan` (the lab vantage point,
   `192.168.50.66`) and one on libvirt's default NAT network (for internet
   access to pull tools) — SSH isn't enabled by default on the Kali desktop
   image, so enable it once via the VNC console (`kali`/`kali`, NOPASSWD sudo).

Any VM that needs temporary internet access during its own build (e.g. `apt`/
Chocolatey installs before the lab network is fully live) should have that NAT
NIC **detached again once provisioning finishes** — a leftover NAT interface
silently breaks the pfSense WAN port-forward by winning the default route
over the isolated segment's gateway. See `docs/architecture.md` for the full
IP/network table.

Once all seven VMs are running and answering WinRM/SSH on their lab-segment
IPs, continue with "Quick start" below.

## Quick start

```
scripts/setup-networks.sh    # one-time host net + storage pool prep (run by deploy.sh too)
scripts/deploy.sh            # randomize secrets/paths, then Ansible provisioning
scripts/health.sh            # verify every host/service is reachable and correctly configured
scripts/verify-segmentation.sh   # run from ATTACK: confirm WAN can't reach LAN/DMZ directly
```

### AWS quick start

```
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # fill in real values
scripts/aws-deploy.sh              # terraform apply, SSM tunnels, randomize + Ansible provisioning
scripts/aws-health.sh              # verify instance status + services
scripts/aws-verify-segmentation.sh # run from attack: confirm the Security Group boundary holds
scripts/aws-destroy.sh             # tear down when done - this costs money while running
```

See `docs/architecture-aws.md` for the topology and documented scope
differences from the KVM version before running this path.

See `docs/student-brief.md` for the in-lab starting point (what a tester is told),
`docs/architecture.md` for the full design rationale, topology, and vulnerability map, and
`docs/attack-chain.md` for the complete stage-by-stage attack chain and vulnerability
dossier (why each bug exists, which config produces it, how the stages chain together —
operator-facing, static across deploys).
The answer key is generated per-deploy at `docs/answer-key.md` (gitignored — it contains
the randomized secrets and solution paths for this specific deployment).

## Isolation

This lab runs on isolated libvirt networks only (`lab-wan`/`lab-dmz`/`lab-lan`; none has
a `<forward>` element to the real network — pfSense is the only router between them, and
the host's own management adapters are the only other thing with direct access). Do not
bridge any VM to your real LAN or the internet, beyond the single deliberate NAT NIC on
`attack` described above. Hosts run intentionally weakened configurations, eval Windows
licenses, and default/weak credentials — treat all three subnets as hostile.
