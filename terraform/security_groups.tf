# Project Halcyon — AWS deployment path, Security Groups.
#
# This is the load-bearing segmentation control on AWS (NACLs in nacls.tf are
# defense-in-depth only) — see docs/architecture-aws.md. Rules are scoped by
# SECURITY GROUP ID, not by VPC/subnet CIDR: a naive "allow all from VPC
# CIDR" on the LAN group would let `attack` (also inside the VPC, just in
# subnet_wan) skip straight to dc01/srv01/ws01/ws02, since AWS subnets alone
# don't block traffic between each other — only SGs/NACLs do. SG-to-SG
# references are what makes "only web01 may pivot into LAN" hold.
#
# Reachability for Ansible provisioning goes over SSM Session Manager
# port-forwarding (see scripts/aws-deploy.sh), which rides on outbound
# HTTPS to the SSM service — no inbound rule is needed on any of these
# groups for that path.

# --- web01 -------------------------------------------------------------
# Public-facing: this is the only host with an internet-reachable inbound
# rule, mirroring pfSense's WAN->WEB01:80/443-only port-forward.
resource "aws_security_group" "wan_web01" {
  name        = "halcyon-lab-sg-wan-web01"
  description = "web01: public HTTP/HTTPS (the sole external entry point), SSH from admin_cidr"
  vpc_id      = aws_vpc.lab.id

  tags = { Name = "halcyon-lab-sg-wan-web01" }
}

resource "aws_vpc_security_group_ingress_rule" "web01_http" {
  security_group_id = aws_security_group.wan_web01.id
  cidr_ipv4          = "0.0.0.0/0"
  from_port            = 80
  to_port                = 80
  ip_protocol              = "tcp"
  description                = "Web app HTTP - the lab's only public entry point"
}

resource "aws_vpc_security_group_ingress_rule" "web01_https" {
  security_group_id = aws_security_group.wan_web01.id
  cidr_ipv4          = "0.0.0.0/0"
  from_port            = 443
  to_port                = 443
  ip_protocol              = "tcp"
  description                = "Web app HTTPS - the lab's only public entry point"
}

resource "aws_vpc_security_group_ingress_rule" "web01_ssh_admin" {
  security_group_id = aws_security_group.wan_web01.id
  cidr_ipv4          = var.admin_cidr
  from_port            = 22
  to_port                = 22
  ip_protocol              = "tcp"
  description                = "Operator SSH for ops/debugging - not part of the lab exercise"
}

resource "aws_vpc_security_group_egress_rule" "web01_all_out" {
  security_group_id = aws_security_group.wan_web01.id
  cidr_ipv4          = "0.0.0.0/0"
  ip_protocol              = "-1"
  description                = "web01 must reach LAN (AD/DNS/MSSQL) and the internet (apt/pip during provisioning)"
}

# --- LAN internal (dc01/srv01/ws01/ws02) --------------------------------
# Flat/trusting between LAN hosts (matches the KVM intra-LAN design - the
# firewall/segmentation governs traffic *between zones*, not within the
# LAN). Inbound is allowed ONLY from this group itself (LAN-to-LAN) and from
# web01's group (the legitimate DMZ->LAN pivot) - never from attack or
# 0.0.0.0/0.
resource "aws_security_group" "lan_internal" {
  name        = "halcyon-lab-sg-lan-internal"
  description = "dc01/srv01/ws01/ws02: flat LAN, reachable only from itself and from web01"
  vpc_id      = aws_vpc.lab.id

  tags = { Name = "halcyon-lab-sg-lan-internal" }
}

resource "aws_vpc_security_group_ingress_rule" "lan_from_lan" {
  security_group_id = aws_security_group.lan_internal.id
  referenced_security_group_id = aws_security_group.lan_internal.id
  ip_protocol                     = "-1"
  description                       = "LAN internal -> any (flat, trusting - matches KVM design)"
}

// web01 -> LAN is the deliberate pivot surface, but split around 5985-5986
// (WinRM) rather than a single "-1" rule: SGs can't express a deny, so the
// only way to keep the pivot open for AD/DNS/MSSQL while excluding remote
// management is to allow everything else and leave that range out.
resource "aws_vpc_security_group_ingress_rule" "lan_from_web01_tcp_low" {
  security_group_id = aws_security_group.lan_internal.id
  referenced_security_group_id = aws_security_group.wan_web01.id
  ip_protocol                     = "tcp"
  from_port                          = 0
  to_port                              = 5984
  description                       = "DMZ pivot: web01 -> LAN (AD/DNS/MSSQL), TCP below WinRM"
}

resource "aws_vpc_security_group_ingress_rule" "lan_from_web01_tcp_high" {
  security_group_id = aws_security_group.lan_internal.id
  referenced_security_group_id = aws_security_group.wan_web01.id
  ip_protocol                     = "tcp"
  from_port                          = 5987
  to_port                              = 65535
  description                       = "DMZ pivot: web01 -> LAN (AD/DNS/MSSQL), TCP above WinRM"
}

resource "aws_vpc_security_group_ingress_rule" "lan_from_web01_udp" {
  security_group_id = aws_security_group.lan_internal.id
  referenced_security_group_id = aws_security_group.wan_web01.id
  ip_protocol                     = "udp"
  from_port                          = 0
  to_port                              = 65535
  description                       = "DMZ pivot: web01 -> LAN (AD/DNS/MSSQL), UDP"
}

resource "aws_vpc_security_group_ingress_rule" "lan_from_web01_icmp" {
  security_group_id = aws_security_group.lan_internal.id
  referenced_security_group_id = aws_security_group.wan_web01.id
  ip_protocol                     = "icmp"
  from_port                          = -1
  to_port                              = -1
  description                       = "DMZ pivot: web01 -> LAN ICMP"
}

# WinRM (5985/5986) deliberately NOT allowed from web01 -> LAN: the pivot is
# for legitimate AD/DNS/DB traffic, not a shortcut straight to a management
# shell on dc01/srv01 with whatever domain credential got harvested on
# web01 - that would let an RCE on web01 skip Stage 3/4 (Kerberoasting,
# ADCS abuse, etc.) entirely instead of exercising them.

resource "aws_vpc_security_group_egress_rule" "lan_all_out" {
  security_group_id = aws_security_group.lan_internal.id
  cidr_ipv4          = "0.0.0.0/0"
  ip_protocol              = "-1"
  description                = "Egress for Windows Update / Chocolatey (mssql role) via the NAT Gateway"
}

# --- attack --------------------------------------------------------------
# The tester's own vantage point. No inbound rule exists in config.xml for
# WAN itself (it's the attacker's box, not a lab target) - only the operator
# needs to reach it, to manage/reset it.
resource "aws_security_group" "attack" {
  name        = "halcyon-lab-sg-attack"
  description = "attack: SSH from admin_cidr only"
  vpc_id      = aws_vpc.lab.id

  tags = { Name = "halcyon-lab-sg-attack" }
}

resource "aws_vpc_security_group_ingress_rule" "attack_ssh_admin" {
  security_group_id = aws_security_group.attack.id
  cidr_ipv4          = var.admin_cidr
  from_port            = 22
  to_port                = 22
  ip_protocol              = "tcp"
  description                = "Operator SSH - attack is never an Ansible provisioning target (see ansible/site.yml)"
}

resource "aws_vpc_security_group_egress_rule" "attack_all_out" {
  security_group_id = aws_security_group.attack.id
  cidr_ipv4          = "0.0.0.0/0"
  ip_protocol              = "-1"
  description                = "Attacker needs to reach web01 (the target) and the internet (tool pulls)"
}
