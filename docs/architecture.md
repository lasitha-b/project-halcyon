# Project Halcyon — Architecture & Design Rationale

Operator-facing document. Not shown to students/testers — see `student-brief.md`
for that. The generated `answer-key.md` (gitignored) has the concrete per-deploy
solution; this document explains the *design*, which stays constant across deploys.

## Why this exists

A hard, realistic AD + web pentest range for local practice on a single 32 GB
KVM/libvirt host, using only non-CVE / configuration-class vulnerabilities
(AD misconfig, ADCS/PKI misconfig, OWASP-class web bugs), deliberately **not**
recognizable as a fork of GOAD or any other public lab — see "Anti-walkthrough
design" below for why that mattered enough to shape the whole build.

## Topology

Single forest/domain `corp.halcyon.local` ("Halcyon Logistics"). Seven VMs:
`FW01` (pfSense edge firewall), `DC01` (DC+CA), `SRV01` (MSSQL), `WS01`/`WS02`
(clients), `WEB01` (Ubuntu, domain-joined via SSSD, the only externally-facing
host), `ATTACK` (Kali). Full sizing table and RAM budget are in the top-level
README.

A single domain (vs. GOAD's 2-forest/3-domain design) is deliberate: it halves
the DC footprint, is a realistic SMB topology, and — combined with original
naming — removes the single biggest structural fingerprint that would let
someone recognize "this is GOAD" at a glance.

### Network segmentation

`FW01` (pfSense CE) segments the lab into three isolated libvirt networks
instead of one flat subnet, so the range mirrors a real perimeter and forces
the attacker to earn internal access rather than start with it:

```
  ATTACK (Kali) 192.168.50.66
        │  WAN  lab-wan  192.168.50.0/24
   ┌────┴─────┐
   │  FW01    │  pfSense   NAT :80/:443 ──► WEB01
   │  .254    │
   └─┬──────┬─┘
 DMZ │      │ LAN
 lab-dmz    lab-lan
 172.20.1/24   10.20.10/24
   WEB01 .40   DC01 .10  SRV01 .20  WS01 .31  WS02 .32
```

- **WAN (`192.168.50.0/24`)** — the attacker's vantage point. `WAN → LAN` and
  `WAN → DMZ` are blocked outright; the *only* inbound path is a pfSense
  port-forward of `192.168.50.254:80/443` to `WEB01`. The web app is genuinely
  the sole front door now — not just "the intended one."
- **DMZ (`172.20.1.0/24`)** — `WEB01` alone. It reaches the LAN (its legitimate
  AD/DNS/DB needs, and the attacker's pivot after popping it) but not the
  firewall's own admin plane. This `DMZ → LAN` allowance is the deliberate
  pivot surface; a tighter "pivot via `DC01` only" variant is documented in
  `packer/pfsense/README.md`.
- **LAN (`10.20.10.0/24`)** — the internal AD network, still flat and trusting
  between hosts (Defender firewall off per host), matching the original
  intra-domain design. The firewall governs traffic *between zones*, not within
  the LAN.

pfSense owns DHCP on every segment, handing each VM a deterministic IP by fixed
MAC (`packer/pfsense/config.xml`) plus itself (`.254`) as gateway. The host
retains a `.1` management adapter on all three libvirt networks (`lab-wan`/
`lab-dmz`/`lab-lan`, none of which has a `<forward>` element), so Ansible
provisions every guest out-of-band, independent of firewall policy — the
segmentation is part of the *scenario*, not an obstacle to building it. WAN
uses the private range `192.168.50.0/24`, distinct from libvirt's own default
NAT network (`192.168.122.0/24` on most hosts), so the two never collide;
`config.xml` leaves the WAN "block private networks"/"block bogons" options
off, so this doesn't get blocked at the edge.

The firewall does not weaken the "no CVE, config-class only" premise: it is
itself a configuration surface (segmentation policy, NAT, an over-broad
DMZ→LAN allow) and an enumeration target, not a patchable vulnerable service.

## Kill chain

See the project plan / README for the full stage breakdown. Summary: WEB01's
custom app is the only entry point — now enforced at the edge by `FW01`, which
port-forwards only `:80/:443` to `WEB01` and blocks the attacker's WAN segment
from reaching the LAN at all → chained web bugs → RCE as `www-data` →
Linux privesc + AD credential loot (SSSD config, keytab, cached tickets, a
deploy script) → multiple independent AD escalation routes (Kerberoast,
AS-REP roast, ACL→DCSync chain, ADCS ESC1/4/6/8, delegation/RBCD, NTLM
relay via coercion) → lateral movement (PtH, MSSQL xp_cmdshell/linked
servers) → Domain Admin / DCSync.

## Anti-walkthrough design

The core risk this design defends against: if the lab is recognizable as a
GOAD derivative (or uses a known vulnerable app like DVWA/Juice Shop), an
attacker — human or AI agent — can solve it by retrieving a published
walkthrough instead of doing the analysis. Countermeasures:

1. **No borrowed fingerprints.** Original domain/host/user/group/SPN naming
   ("Halcyon Logistics" theme), no GOAD/GoT terms, no reused OU/share layout,
   hand-written web app instead of a known vulnerable-app project.
2. **Per-deploy randomization** (`ansible/roles/randomize/files/gen_seed.py`,
   run by `scripts/deploy.sh` before any VM provisioning): all credentials,
   flag tokens, and a subset of *which* vulnerability paths are actually live
   (see `vuln_paths` in `ansible/group_vars/all.yml`) are re-rolled from a
   fresh seed every deploy. A walkthrough for one deployment does not solve
   the next one.
3. **Decoys.** `svc-scan` is a plausible-looking but empty lead; the
   description-field "hint" on it is a dead end by design.
4. **Independent parallel paths at each stage** so no single technique is
   load-bearing for the whole chain.

This does **not** mean the underlying techniques are novel — Kerberoasting,
ESC1, RBCD etc. are standard, well-documented AD attack primitives, and that's
intentional (the lab teaches real technique). What's original is the specific
combination, naming, sequencing, and per-deploy variability, which is what
actually defeats "search for a walkthrough and paste the commands."

## Vulnerability inventory

See the README's "non-CVE vulnerability inventory" table, and
`ansible/group_vars/all.yml`'s `vuln_paths` map, which is the single source of
truth for what exists and whether it's structural (`always: true`) or
randomized per deploy.

## Repo layout

```
packer/pfsense/           pfSense edge firewall: config.xml (the firewall policy)
                          + README (manual virt-install build path)
ansible/
  site.yml               top-level playbook, one play per host group
  inventory.yml           static inventory, IPs match the libvirt network plan
  group_vars/all.yml      identity fabric + vuln_paths catalogue (source of truth)
  group_vars/secrets_seed.yml   GENERATED per-deploy, gitignored
  roles/
    randomize/            seed generation (files/gen_seed.py) + a guard task
    ad_forest/             DC promo, DNS, OUs, DA-only confidential flag share
    adcs/                  Enterprise CA + ESC1/4/6/8 template provisioning
    ad_identities/         users, groups, SPNs, ACL grants, delegation, decoys
    domain_join_win/       WS01/WS02 join, LAPS-absent/local-admin handling
    mssql/                 MSSQL install, xp_cmdshell, linked server, deploy share
    linux_web/              SSSD join, credential loot, Linux privesc paths
    web_app/                custom Flask app deploy, Postgres schema/seed, nginx
    posture/                Defender/firewall/SMB-signing/LDAP/LLMNR toggles
webapp/                   the actual Flask app source (app.py, templates, static)
scripts/                  setup-networks.sh, deploy.sh, health.sh, verify-segmentation.sh
docs/                     this file, student-brief.md, answer-key.md (generated)
```

## Operating the lab

The seven VMs are built once via `virt-install` (see the top-level README's
"Building the VMs" section and `packer/pfsense/README.md` for `fw01`'s
manual install), then provisioned with Ansible:

```
scripts/setup-networks.sh   # one-time: libvirt networks + storage pool (idempotent)
scripts/deploy.sh           # randomize secrets/paths + ansible-playbook
scripts/health.sh           # verify reachability/services
scripts/verify-segmentation.sh   # run from ATTACK: confirm edge policy holds
```

There is no reset/snapshot flow — this is a one-time deployment. To generate
a genuinely new deployment (new secrets, new live-path selection), tear down
and rebuild the VMs, then re-run `scripts/deploy.sh`; reusing the same seed
via `HALCYON_SEED` is only for debugging reproducibility, not for normal use.
