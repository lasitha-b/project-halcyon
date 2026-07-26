# Project Halcyon — AWS deployment path, Network ACLs.
#
# Defense-in-depth only — Security Groups (security_groups.tf) are the
# actually-enforced, load-bearing segmentation control, because NACLs can
# only match by CIDR block (not by security-group reference), which is too
# coarse to precisely express "web01 may pivot into LAN but attack may not"
# when both sit in the same subnet_wan CIDR range. What NACLs *do* add here:
# a stateless second layer that gives a student a second, independently
# observable signal when probing the perimeter (SG-drop vs NACL-drop behave
# differently to tools like nmap), loosely mirroring pfSense's per-interface
# rule blocks in the KVM version.
#
# Gotcha this file works around: the NAT Gateway lives in subnet_wan
# (vpc.tf), so a LAN host's internet-bound return traffic arrives sourced
# from the NAT Gateway's private IP — which is itself inside subnet_wan's
# CIDR. A blanket "deny all of subnet_wan's CIDR into subnet_lan" would
# therefore also block the NAT Gateway's return traffic and silently break
# egress (Chocolatey/apt/pip during provisioning). We explicitly allow the
# NAT Gateway's own /32 ahead of the broader subnet_wan deny to avoid that.

resource "aws_network_acl" "lan" {
  vpc_id     = aws_vpc.lab.id
  subnet_ids = [aws_subnet.lan.id]

  tags = { Name = "halcyon-lab-nacl-lan" }
}

# Rule 90: NAT Gateway's own address, ahead of the subnet_wan deny below.
resource "aws_network_acl_rule" "lan_in_allow_natgw" {
  network_acl_id = aws_network_acl.lan.id
  rule_number      = 90
  egress             = false
  protocol             = "-1"
  rule_action            = "allow"
  cidr_block               = "${aws_nat_gateway.lab.private_ip}/32"
}

# Rule 100: LAN<->LAN and DMZ->LAN traffic (web01 lives in subnet_wan under
# the locked-in AWS design, but keep this rule for subnet_dmz too in case an
# operator later relocates a host there).
resource "aws_network_acl_rule" "lan_in_allow_lan" {
  network_acl_id = aws_network_acl.lan.id
  rule_number      = 100
  egress             = false
  protocol             = "-1"
  rule_action            = "allow"
  cidr_block               = aws_subnet.lan.cidr_block
}

resource "aws_network_acl_rule" "lan_in_allow_dmz" {
  network_acl_id = aws_network_acl.lan.id
  rule_number      = 110
  egress             = false
  protocol             = "-1"
  rule_action            = "allow"
  cidr_block               = aws_subnet.dmz.cidr_block
}

# Rule 115: deny WinRM (5985/5986) from web01 specifically, ahead of the
# broad web01 allow at 120 - mirrors the pfSense DMZ->LAN WinRM block rules
# (config.xml trackers 1000000024/1000000025). The pivot is for legitimate
# AD/DNS/MSSQL traffic; it should not double as a shortcut straight to a
# WinRM shell on dc01/srv01.
resource "aws_network_acl_rule" "lan_in_deny_web01_winrm" {
  network_acl_id = aws_network_acl.lan.id
  rule_number      = 115
  egress             = false
  protocol             = "6"
  rule_action            = "deny"
  cidr_block               = "${aws_instance.web01.private_ip}/32"
  from_port                  = 5985
  to_port                      = 5986
}

# Rule 120: web01 lives in subnet_wan under the locked-in design, so its
# legitimate pivot traffic must be allowed explicitly by its own host /32
# (not the whole subnet_wan CIDR, which would also cover attack). NACLs
# can't reference a security group the way SGs can reference each other, so
# a host-scoped /32 CIDR is the closest stateless equivalent.
resource "aws_network_acl_rule" "lan_in_allow_web01_host" {
  network_acl_id = aws_network_acl.lan.id
  rule_number      = 120
  egress             = false
  protocol             = "-1"
  rule_action            = "allow"
  cidr_block               = "${aws_instance.web01.private_ip}/32"
}

# Rule 140: deny the rest of subnet_wan (i.e. attack) explicitly, below the
# narrower allows above so they take precedence (NACL rules evaluate in
# ascending rule_number, first match wins).
resource "aws_network_acl_rule" "lan_in_deny_wan" {
  network_acl_id = aws_network_acl.lan.id
  rule_number      = 140
  egress             = false
  protocol             = "-1"
  rule_action            = "deny"
  cidr_block               = aws_subnet.wan.cidr_block
}

resource "aws_network_acl_rule" "lan_in_allow_rest" {
  network_acl_id = aws_network_acl.lan.id
  rule_number      = 32766
  egress             = false
  protocol             = "-1"
  rule_action            = "deny"
  cidr_block               = "0.0.0.0/0"
}

resource "aws_network_acl_rule" "lan_out_allow_all" {
  network_acl_id = aws_network_acl.lan.id
  rule_number      = 100
  egress             = true
  protocol             = "-1"
  rule_action            = "allow"
  cidr_block               = "0.0.0.0/0"
}
