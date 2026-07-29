# Project Halcyon — AWS Deployment Path

Operator-facing document, additive to `docs/architecture.md` (the KVM
version, which stays the primary/reference design). This describes the
`terraform/` + `scripts/aws-*.sh` deployment path and — most importantly —
the deliberate scope differences from the local KVM lab. Read this before
running the AWS path so gaps read as documented tradeoffs, not bugs.

## Topology

Six hosts, no `fw01`: `dc01`/`srv01`/`ws01`/`ws02` (Windows Server 2022),
`web01` (Ubuntu 22.04), `attack` (Kali, via AWS Marketplace AMI). One VPC
(`10.30.0.0/16` — deliberately distinct from the KVM lab's
`10.20.10.0/24`/`172.20.1.0/24`/`192.168.50.0/24` and libvirt's default
`192.168.122.0/24`, so the two labs never collide), three subnets in one AZ:

```
        ATTACK (Kali)                    WEB01 (public IP)
             │                                  │
     ┌───────┴──────────────────────────────────┴───────┐
     │            subnet_wan (public, 10.30.0.0/24)      │
     └─────────────────────────┬──────────────────────────┘
                                │  Security Group boundary
                                │  (sg-lan-internal: only self + web01's SG)
     ┌──────────────────────────┴─────────────────────────┐
     │            subnet_lan (private, 10.30.2.0/24)       │
     │      dc01   srv01   ws01   ws02                     │
     └───────────────────────────────────────────────────┘
        subnet_dmz (private, 10.30.1.0/24) — defined, unused
```

Segmentation is enforced by AWS Security Groups (SG-to-SG referenced, not
CIDR-scoped — see `terraform/security_groups.tf`), with Network ACLs as a
stateless second layer (`terraform/nacls.tf`). Ansible reaches every host
over an SSM Session Manager port-forward tunnel opened per-instance by
`scripts/aws-deploy.sh` — the AWS analog of the KVM host's ".1 management
adapter on every libvirt network" out-of-band reachability.

## Deliberate scope changes vs. the KVM version

These are accepted tradeoffs made explicitly during planning, not oversights:

- **No firewall-enumeration stage.** The KVM lab's `fw01` (pfSense) is both a
  segmentation control *and* a pentest-relevant enumeration target in its own
  right (admin GUI reachability, NAT rule discovery, a probe-able "DMZ →
  firewall admin: deny" control). On AWS there is no discrete firewall
  device, no admin GUI, and no equivalent stage. The AWS path is a
  **segmentation-only exercise**: the attacker must still prove WAN can't
  reach LAN and must pivot through `web01`, but there's no fourth host to
  compromise or fingerprint along the way.
- **`web01`'s DMZ boundary is enforced by Security Group, not subnet
  placement.** It has a public IP in `subnet_wan`, unlike the KVM version's
  genuinely-private DMZ segment. AWS has no inbound port-forward device the
  way pfSense did; introducing an ALB/NLB to keep `web01` in a private subnet
  would be heavier machinery than the KVM model warrants, so the boundary
  moved to the SG layer instead. A student inspecting AWS network metadata
  will see this and should not read it as a segmentation failure — the
  control (only :80/:443 reach `web01`, nothing reaches LAN except from
  `web01`) still holds, just expressed differently.
- **`attack` has one NIC**, not the KVM version's two-NIC (isolated WAN +
  separate default-NAT) pattern. A single AWS public-subnet ENI gives both
  lab reachability and internet egress for tool-pulling, so the second NIC
  simply isn't needed — functionally equivalent, structurally simpler.
- **Kali SSH-enable is automatic.** The AWS Marketplace Kali AMI ships with
  cloud-init and OpenSSH already enabled, unlike the KVM path's manual
  VNC-console SSH-enable step (README "Building the VMs" step 5). A genuine
  simplification, not an inconsistency.
- **WS01/WS02 are Windows Server 2022, not Windows 11 clients.** EC2 can't
  run client Windows on standard (shared-tenancy) instances — that requires
  an EC2 Dedicated Host plus a BYOL Windows 11 license, which is expensive
  and resists full automation. The AWS lab is effectively four Windows
  Servers + one Linux host + one Kali box, not two servers + two real
  desktop clients. If real Windows 11 clients matter for a given exercise,
  use the KVM path for that portion.

## What did NOT need to change

The Ansible role logic itself — `ad_forest`, `adcs`, `ad_identities`,
`domain_join_win`, `mssql`, `linux_web`, `web_app`, `posture`, `randomize`,
and `ansible/site.yml` — is unmodified from the KVM version. It resolves
hosts via AD-integrated DNS (`dc01.{{domain_name}}`, never raw IPs) and
connects over WinRM/SSH without any hypervisor-specific assumptions. The
entire AWS path is new Terraform + bootstrap user-data + a generated
inventory (`ansible/generated/inventory_aws.yml`) wired to run the same
`ansible-playbook ... ansible/site.yml` command. `gen_seed.py`'s per-deploy
secret/vuln-path randomization is also untouched and runs identically on
both paths — the same `HALCYON_SEED` value produces the same answer key
regardless of which infrastructure it's provisioned onto.

## Operating the AWS lab

```
scripts/aws-deploy.sh      # terraform apply, open SSM tunnels, randomize + provision
scripts/aws-health.sh      # verify reachability/services (AWS analog of health.sh)
scripts/aws-verify-segmentation.sh   # run from attack: confirm the SG boundary holds
scripts/aws-destroy.sh     # terraform destroy (manual confirm, not auto-approved)
```

Prerequisites beyond the KVM path's: an AWS account/credentials, the `aws`
CLI with the Session Manager plugin installed, an SSH key pair
(`terraform.tfvars`'s `public_key_path`), and a one-time manual subscription
to the AWS Marketplace Kali Linux listing (Terraform cannot auto-subscribe to
Marketplace products — copy the resulting AMI ID into `kali_ami_id`).

This is a **paid, always-on environment** while up — see `terraform/budget.tf`
for the AWS Budget alarm backstop, but the primary cost control is running
`scripts/aws-destroy.sh` when a session ends. Rough orientation: ~$0.44/hr
compute + NAT Gateway, roughly $3-4 for a multi-hour session (see
`terraform/variables.tf` for the instance-type knobs if you want to trade
cost for headroom).
