# Session handoff — Project Halcyon deployment

Status as of this session ending. Written for a fresh session/model to pick up
without re-deriving everything from scratch.

## Overall state

Full toolchain (VMware Workstation, Vagrant + vagrant-vmware-desktop, Packer,
Ansible) is installed and working on this host. All 4 base box images built
successfully at least once (`halcyon/win2022`, `halcyon/win11`,
`halcyon/ubuntu22`, `halcyon/attack-kali`). A full 6-VM `vagrant up` +
Ansible run got **deep into real provisioning** — AD forest promotion, OU
creation, security groups, and the DA-flag share all succeeded — before
hitting the blocker described below.

**~15 distinct real bugs were found and fixed this session** across Packer
templates, the Vagrantfile, Ansible roles/inventory, and host network/firewall
config. Full list in "Bugs fixed this session" below. Read the inline comments
left in each changed file — they explain the *why*, not just the *what*.

## Current blocker — RESOLVED (root-caused + fixed)

**Root cause: `win2022.pkr.hcl` was missing the fixed-IP pinning that
`win11.pkr.hcl` already had.** Without VMware Tools, Packer discovers the guest
IP from the vmnet8 DHCP lease file and caches it once. On the *second*
`windows-restart` the guest renews onto a different lease, but Packer keeps
reconnecting to the stale cached IP (`172.16.109.129`) — nothing answers ARP for
it anymore, which is exactly the "no route to host" seen at the sysprep upload.
Hypothesis #1 in the old notes below was correct; the `pause_before` timing
hacks never helped because it was never a WinRM-readiness problem.

Fix applied to `packer/win2022/win2022.pkr.hcl`: added `winrm_host =
"172.16.109.202"`, `winrm_use_ntlm = true`, and a `vmx_data` fixed MAC
(`00:50:56:20:20:22`) — mirroring what `win11.pkr.hcl` already does. That pins
the guest to one IP across all reboots, so Packer never chases a stale lease.
Rebuild with the command in "How to resume" to confirm; the `pause_before` on
the sysprep provisioner is now belt-and-suspenders and can stay.

The original diagnostic notes are kept below for context.

## Original blocker notes (pre-fix, for context)

**Rebuilding `halcyon/win2022` with a sysprep step fails 3/3 times** with:

```
Error uploading script: Error uploading file to $env:TEMP\winrmcp-....tmp:
Couldn't create shell: unknown error Post "http://172.16.109.129:5985/wsman":
dial tcp 172.16.109.129:5985: connect: no route to host
```

This happens consistently right after the *second* `windows-restart`
provisioner (following `base-hardening-baseline.ps1`), just before the final
`sysprep.ps1` provisioner's file upload. Packer reports "Machine successfully
restarted, moving on" and then the upload fails with **no route to host**
(a routing-level failure, not a "connection refused"/timeout that would
suggest WinRM just isn't ready yet).

### What's been ruled out
- **Not WinRM-readiness timing**: added `pause_before = "60s"` on the
  sysprep provisioner (see `packer/win2022/win2022.pkr.hcl`,
  `packer/win11/win11.pkr.hcl`) — same failure, same IP, same spot.
- **Not a one-off flake**: reproduced 3 times in a row, identical error each
  time (down to the same IP `172.16.109.129`).
- The *first* `windows-restart` (right after initial WinRM connect, before
  `base-hardening-baseline.ps1`) always succeeds fine. It's specifically the
  *second* restart cycle that breaks connectivity.

### Leading hypotheses (untested)
1. Something in `base-hardening-baseline.ps1` or the restart sequence is
   actually changing the guest's network config or IP address, and Packer is
   retrying the *stale* IP it cached from before the restart. Worth checking:
   does the guest get a *different* DHCP lease after the second reboot vs.
   the first? (`cat /etc/vmware/vmnet8/dhcpd/dhcpd.leases` on the host, or
   connect via VNC and run `ipconfig` on the guest mid-failure.)
2. `network_adapter_type = "e1000e"` (set in both `.pkr.hcl` files) might
   have a reliability issue with rapid back-to-back Windows Server reboots in
   this VMware Workstation version — untested whether `vmxnet3` (used
   successfully for the Ubuntu box) behaves differently for Windows.
3. Worth checking `packer/win2022/scripts/base-hardening-baseline.ps1` itself
   — it currently fails on `Install-WindowsUpdate` (see "known cosmetic
   issue" below) but that failure is caught by
   `-ErrorAction SilentlyContinue` and doesn't stop the script. Confirm
   nothing *else* in that script (or a Windows Update side-effect despite the
   failed cmdlet call) touches networking.

### Suggested next diagnostic step
Catch the VM live during the failure window instead of reasoning about it
after the fact: run the build, and as soon as the second `windows-restart`
begins, connect via VNC (endpoint/password are printed in the Packer log
right after "Powering on virtual machine...") and watch what actually happens
to the network adapter — does it show "Network cable unplugged", does
`ipconfig` show a different subnet/no address, etc. This will settle which
hypothesis above (if any) is right, rather than guessing at Packer-level
timing fixes.

## How to resume

```bash
cd /home/lasitha/project-halcyon
export PATH="$HOME/.local/bin:$PATH"
export VAGRANT_HOME="/mnt/halcyon-lab/vagrant.d"
export PACKER_CACHE_DIR="/mnt/halcyon-lab/packer_cache"
export VAGRANT_EXPERIMENTAL=none_communicator  # required, see Vagrantfile header

# ISOs (on external USB drive, may need to be reattached/remounted):
#   Windows Server 2022: /run/media/lasitha/SSD 1TB/SERVER_EVAL_x64FRE_en-us.iso
#   Windows 11:          /run/media/lasitha/SSD 1TB/26200.6584.250915-1905.25h2_ge_release_svc_refresh_CLIENTENTERPRISEEVAL_OEMRET_x64FRE_en-us.iso
#   Ubuntu 22.04.5:       /run/media/lasitha/SSD 1TB/ubuntu-22.04.5-live-server-amd64.iso

# Rebuild win2022 with sysprep (the currently-failing step):
packer build -var "iso_url=/run/media/lasitha/SSD 1TB/SERVER_EVAL_x64FRE_en-us.iso" packer/win2022/win2022.pkr.hcl
```

If `/etc/vmware/vmnet20/nat/nat.conf` is missing (it gets wiped by
`vmware-networks --stop/--start` cycles), `scripts/deploy.sh` recreates it
automatically — see the top of that script. If running Packer/Vagrant
commands directly (not via `deploy.sh`), recreate it manually first:

```bash
sudo mkdir -p /etc/vmware/vmnet20/nat
sudo tee /etc/vmware/vmnet20/nat/nat.conf > /dev/null << 'EOF'
[host]
device = /dev/vmnet20
hostIp = 10.20.10.1

[incomingtcp]

[incomingudp]
EOF
```

## Why sysprep matters (don't skip it)

Confirmed root cause of a *separate*, now-fixed-in-principle bug: VMware
linked clones of an un-sysprepped Windows box **share the same machine SID**.
Verified directly — `ws01` and `ws02` (both cloned from `halcyon/win11`)
have byte-identical `Get-LocalUser Administrator SID` values. This breaks AD
security-descriptor handling once more than one clone exists in the same
forest — it's very likely *the actual cause* of a real
`ERROR_DS_RANGE_CONSTRAINT` (0x80072082) failure hit when running
`Install-AdcsCertificationAuthority` on `dc01` during the full deploy
(ruled out hostname length, Global Catalog readiness, and FSMO roles as
causes first — see git history / this file's "Bugs fixed" list for the
diagnostic trail).

The sysprep fix (`packer/win2022/scripts/sysprep.ps1`,
`packer/win2022/unattend-specialize.xml`, wired into both `.pkr.hcl` files)
is designed correctly in principle — it's blocked purely by the Packer-level
"no route to host" issue above, not a flaw in the sysprep approach itself.
**Do not skip rebuilding with sysprep** — without it, expect the same
`ERROR_DS_RANGE_CONSTRAINT` to resurface as soon as a second Windows Server
box (`srv01`) joins the same domain as `dc01`.

Once `win2022` rebuilds successfully with sysprep, apply the identical
rebuild to `win11` (same template changes already in place in
`packer/win11/win11.pkr.hcl`) before re-running the full lab deploy.

## pfSense edge firewall (added this session)

The lab was re-segmented from one flat network into **WAN / DMZ / LAN** behind a
new pfSense CE firewall VM (`fw01`). Design + rationale: `docs/architecture.md`
("Network segmentation") and `packer/pfsense/README.md`.

New IP plan (LAN hosts keep their old IPs; only WEB01 and ATTACK moved):
- WAN `203.0.113.0/24` (vmnet22): attack `.66`, pfSense `.254`, host `.1`
- DMZ `172.20.1.0/24` (vmnet21): web01 `.40`, pfSense `.254`, host `.1`
- LAN `10.20.10.0/24` (vmnet20): dc01 `.10` srv01 `.20` ws01 `.31` ws02 `.32`,
  pfSense `.254`, host `.1`

pfSense owns DHCP on every segment (deterministic static-MAC mappings + itself as
gateway); VMware's per-vmnet dhcpd is disabled by `scripts/setup-networks.sh`.
The host keeps a `.1` mgmt adapter on each vmnet, so Ansible still reaches every
guest directly — the firewall governs guest↔guest traffic only. WAN→LAN is
blocked; only a WAN:80/443 port-forward to WEB01 lets the attacker in, then they
pivot via the DMZ.

Files added/changed: `packer/pfsense/{config.xml,pfsense.pkr.hcl,README.md}`,
`scripts/setup-networks.sh`, plus `Vagrantfile`, `ansible/inventory.yml`,
`scripts/{deploy,reset,health,build-images}.sh`, `scripts/discover-ips.py`
(deprecated — pfSense static mappings replaced lease-scraping), and docs
(`architecture.md`, `student-brief.md`, `README.md`).

### What still needs on-hardware validation (I couldn't run any of it here)
1. **pfSense box build.** pfSense CE has no unattended-install answer file, so
   `pfsense.pkr.hcl`'s `boot_command` keystroke timing is best-effort and
   almost certainly needs tuning over VNC on the first run. The **reliable
   path** is the manual install + `config.xml` restore in
   `packer/pfsense/README.md` — treat that as authoritative if the automated
   build drifts. `config.xml` itself is XML-validated and is the real
   deliverable.
2. **Interface ordering.** config.xml pins wan=em0, lan=em1, opt1(DMZ)=em2, and
   the Vagrantfile pins the NIC order to match. If pfSense enumerates the NICs
   differently on this host, reassign once from console option 1 (README).
3. **`vmnet21`/`vmnet22` creation.** `setup-networks.sh` writes
   `/etc/vmware/networking` and restarts `vmware-networks`. Confirm the host
   adapters come up as `172.20.1.1` / `203.0.113.1` and that disabling VMware
   DHCP there didn't disturb vmnet1/vmnet8.
4. **DMZ→LAN breadth.** Shipped as an allow-all pivot on purpose (a DC01-only
   lockdown breaks the MSSQL/lateral/DCSync kill-chain paths — see README for
   the tight variant). Verify the intended paths still work end-to-end once the
   lab is up, and that WAN→LAN is actually dropped (test from ATTACK, not just
   the host mgmt adapter).

## Bugs fixed this session (chronological)

All still in place in the working tree / already applied to host config.
Grep the actual files for full context comments — these are just a locator
index.

1. **Packer templates missing `boot_command`** for both Windows templates —
   VM sat at "press any key to boot" until timeout. (`win2022.pkr.hcl`,
   `win11.pkr.hcl`)
2. **Missing `/IMAGE/INDEX` selector** in `win2022/autounattend.xml` — the
   Server 2022 eval ISO has 4 editions; without picking one, Setup hangs on
   an unanswered edition picker.
3. **Missing `xmlns:wcm` namespace declaration** in both `autounattend.xml`
   files — `wcm:action` attributes used throughout but the prefix was never
   declared, so the XML was invalid and Setup silently ignored the whole
   answer file, falling back to interactive install.
4. **`lsilogic` SCSI controller invisible to WinPE** — `diskpart` reported
   zero disks. Switched `disk_adapter_type` to `"sata"` in both Windows
   templates.
5. **Missing `LocalAccountTokenFilterPolicy` registry key** — Windows
   filters remote WinRM/NTLM tokens for any local admin account other than
   the built-in RID-500 Administrator by default, so the `vagrant` account
   got silently rejected. Fixed in `packer/win2022/scripts/enable-winrm.ps1`
   (shared by both Windows templates).
6. **`winrm_use_ntlm` not set** — Packer's WinRM communicator defaults to
   Basic auth, which needs `AllowUnencrypted=true` on the guest (unreliable —
   kept reverting). Set `winrm_use_ntlm = true` instead, which doesn't need
   that flag at all.
7. **Windows 11 build had no VMware Tools and no static IP path** — Packer's
   `vmrun getGuestIPAddress` requires Tools; without it and without a fixed
   IP, `vagrant up`/Packer has no way to find the guest. Fixed via a fixed
   MAC (`vmx_data`) + a DHCP host reservation for `vmnet8` (see
   `/etc/vmware/vmnet8/dhcpd/dhcpd.conf`) + explicit `winrm_host` in
   `win11.pkr.hcl`.
8. **Host firewall (`firewalld`) blocked Packer's own HTTP server** used to
   serve Ubuntu's `cloud-init` autoinstall config — guest got "No route to
   host" trying to reach it. Fixed by adding `vmnet1`, `vmnet8`, and
   `vmnet20` to the `trusted` firewalld zone (persistent,
   `firewall-cmd --zone=trusted --change-interface=... --permanent`).
9. **Ubuntu boot_command inserted `autoinstall` after the existing `---`
   delimiter** instead of before it — kernel never saw `autoinstall` as a
   real parameter, so it silently fell back to interactive install despite
   looking correct in `/proc/cmdline` at first glance. Fixed the cursor
   navigation in `ubuntu2204.pkr.hcl`'s `boot_command`.
10. **Ubuntu `boot_wait = "5s"` ate almost the entire ~12s GRUB auto-boot
    countdown** on this ISO (shorter than the 30s in the static
    `grub.cfg` — likely a separate embedded BIOS boot config) — reduced to
    `"2s"` and simplified the key sequence.
11. **Ubuntu VM OOM-killed mid-install** at `memory = 1536` — bumped to
    `3072` in `ubuntu2204.pkr.hcl`. Confirmed via `dmesg | grep -i "out of
    memory"` showing `apt-check` killed.
12. **`user-data`'s bcrypt/sha512 password hash was a fake placeholder**
    (per the repo's own `packer/README.md` note, never actually
    regenerated) — real hash generated via `openssl passwd -6` and swapped
    in.
13. **`vagrant-vmware-desktop` misdetects modern license-free VMware
    Workstation (17.5.2+) as the crippled "Player" product** — the plugin's
    `standard license -> player` check predates Broadcom's free-tier change,
    which reports license `"standard"` even for full Workstation. This
    breaks the `vmrun -T player snapshot` call linked clones need. Fixed via
    the documented `force_vmware_license = "workstation"` provider config in
    the Vagrantfile (no gem patching needed).
14. **`vmnet20` (the isolated lab network) didn't exist** — created via
    `/etc/vmware/networking` + `vmware-networks --stop/--start`, plus a
    firewalld trusted-zone entry (see #8).
15. **Vagrant clone directory defaulted to the project dir on the small root
    filesystem** — set `clone_directory = "/mnt/halcyon-lab/vms"` in the
    Vagrantfile.
16. **These Windows/Linux boxes have no VMware Tools**, so Vagrant's own
    WinRM/SSH communicator (which relies on NAT port-forwarding through a
    real NAT service) can never reach them on the isolated, NAT-less
    `vmnet20`. Fixed by setting `communicator = "none"` (requires
    `VAGRANT_EXPERIMENTAL=none_communicator`) — Vagrant only boots the VMs,
    Ansible handles all actual guest communication directly via static-ish
    IPs (see #17).
17. **No reliable way to get a *predictable* IP** without VMware Tools or
    working DHCP reservations (reservations set via the Vagrant VMware
    Utility's REST API don't persist outside an active `vagrant up`
    session — confirmed by testing). Solved with `scripts/discover-ips.py`:
    looks up each VM's current DHCP lease by its fixed MAC (set in the
    Vagrantfile's `HOSTS` map) and writes an Ansible inventory override
    (`ansible/inventory_discovered.yml`, gitignored). Wired into
    `scripts/deploy.sh` between `vagrant up` and `ansible-playbook`.
18. **`vagrant up` in parallel (the default) overloads the Vagrant VMware
    Utility** — starts throwing `Net::ReadTimeout` under load. Added
    `--no-parallel` in `scripts/deploy.sh`. *Also* patched
    `Net::HTTP#read_timeout`/`open_timeout` from the 60s default to 300s in
    the vagrant-vmware-desktop gem's `helper/vagrant_utility.rb` (system-wide
    gem, not project-tracked — re-apply if the gem gets reinstalled) since
    even sequential boots occasionally exceeded 60s under host memory
    pressure.
19. **Two duplicate NIC adapters** — the Vagrantfile used to set
    `v.vmx["ethernet0.connectiontype"]` directly *and* use
    `node.vm.network "private_network"` (which creates its own adapter),
    landing both on `vmnet20` with different MACs and confusing Vagrant's
    connection targeting. Removed `private_network` entirely in favor of
    direct fixed-MAC `vmx` config (see #16, #17).
20. **Default port-22→2222 SSH forward collided across all 6 VMs** (this
    plugin's port-forward collision check doesn't auto-correct like Vagrant
    core's own forwarded_port handling does) — explicitly disabled via
    `node.vm.network "forwarded_port", guest: 22, host: 2222, id: "ssh",
    disabled: true` in the Vagrantfile. Not needed anyway since
    `communicator = "none"`.
21. **`ansible_winrm_transport: negotiate`** in `ansible/inventory.yml` isn't
    a real transport name `pywinrm` recognizes (`pywinrm.FEATURE_SUPPORTED_
    AUTHTYPES` doesn't include it — the real value is `"ntlm"`). Pre-existing
    bug, not something introduced this session.
22. **No bootstrap credentials defined anywhere** in tracked Ansible config —
    `ansible/inventory.yml` never set `ansible_password`/`ansible_user` for
    Windows, Linux (`web01`), or the attack box, silently relying on
    Vagrant's own WinRM/SSH provisioning (which no longer runs — see #16).
    Added `ansible_user`/`ansible_password: vagrant` (Windows + web01) and
    `ansible_user: kali` / `ansible_password: kali` (attack box, standard
    Kali default — confirm if this VM's password was customized).
    SSH password auth also needed the `sshpass` binary installed on the
    control node (`sudo dnf install -y sshpass`).
23. **`groups:` variable name in `ansible/group_vars/all.yml` collides with
    Ansible's own reserved `groups` magic variable** (the inventory
    group-membership map) — silently shadowed it, causing `ad_forest`'s
    "Create security groups" task to iterate over inventory group names
    instead of the intended security-group definitions. Renamed to
    `security_groups` throughout (`group_vars/all.yml`,
    `roles/ad_forest/tasks/main.yml`).
24. **Built-in `Administrator` account had a blank password** — Windows
    Server's `Install-ADDSForest` refuses to promote if the local
    Administrator (RID 500) doesn't have a strong password, since it becomes
    the domain Administrator. The autounattend answer file only sets a
    password for the bootstrap `vagrant` account. Added a
    `ansible.windows.win_user` task in `roles/ad_forest/tasks/main.yml`
    before the forest-promotion task, using `halcyon_local_admin_password`
    (already generated by the `randomize` role).
25. **`icacls` lockdown ran *before* `Set-Content` wrote the DA flag file**
    in `ad_forest/tasks/main.yml`'s confidential-share task — by the time the
    write happened, the ACL already excluded the connecting account.
    Reordered: write first, lock down after.
26. **`Install-AdcsCertificationAuthority` fails with
    `ERROR_DS_RANGE_CONSTRAINT`** — see "Current blocker" above for the full
    diagnostic trail; root cause identified (duplicate machine SIDs from
    unsysprepped clones) but the *fix* (sysprep) is itself blocked by a
    separate Packer networking issue.

## Known cosmetic issue (not blocking)

`base-hardening-baseline.ps1` calls `Install-WindowsUpdate`, which isn't a
built-in cmdlet (needs the `PSWindowsUpdate` module, never installed) — fails
with `CommandNotFoundException` every time, but the script has no `throw`/
`exit 1` on that failure so the provisioner still reports success. Real
Windows Updates never actually get installed despite the comment saying
that's the intent. Not fixed this session (deprioritized behind the
higher-impact blockers above) — worth fixing if freshness of Windows Updates
in the base images matters for the lab's realism goals.
