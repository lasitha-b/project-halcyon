# Project Halcyon — AWS deployment path, VPC + subnets + routing.
#
# One VPC, single AZ, three subnets mirroring the KVM lab's WAN/DMZ/LAN
# three-zone model — see docs/architecture-aws.md for how enforcement differs
# from the KVM pfSense version (Security Groups do the segmentation here, not
# subnet placement / a firewall device).
#
# 10.30.0.0/16 is deliberately distinct from the KVM lab's 10.20.10.0/24 /
# 172.20.1.0/24 / 192.168.50.0/24 and from libvirt's default
# 192.168.122.0/24, so the two labs' addressing never collides or gets
# confused if both are ever up at once.

locals {
  az = data.aws_availability_zones.available.names[0]
}

resource "aws_vpc" "lab" {
  cidr_block           = "10.30.0.0/16"
  enable_dns_support    = true
  enable_dns_hostnames  = true

  tags = { Name = "halcyon-lab-vpc" }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "halcyon-lab-igw" }
}

# WAN-equivalent: public subnet. Holds web01 (public-facing, SG-restricted to
# :80/:443) and attack (the in-lab attacker vantage point).
resource "aws_subnet" "wan" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block                = "10.30.0.0/24"
  availability_zone          = local.az
  map_public_ip_on_launch     = true
  tags                          = { Name = "halcyon-lab-subnet-wan" }
}

# DMZ-equivalent: private subnet, defined for symmetry with the KVM 3-zone
# model and NACL documentation value. No instance lives here under the
# locked-in AWS design (web01 sits in subnet_wan with its boundary enforced
# by Security Group instead — see docs/architecture-aws.md).
resource "aws_subnet" "dmz" {
  vpc_id             = aws_vpc.lab.id
  cidr_block           = "10.30.1.0/24"
  availability_zone     = local.az
  tags                    = { Name = "halcyon-lab-subnet-dmz" }
}

# LAN-equivalent: private subnet. Holds dc01/srv01/ws01/ws02.
resource "aws_subnet" "lan" {
  vpc_id             = aws_vpc.lab.id
  cidr_block           = "10.30.2.0/24"
  availability_zone     = local.az
  tags                    = { Name = "halcyon-lab-subnet-lan" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "halcyon-lab-nat-eip" }
}

# NAT Gateway lives in the public subnet, gives subnet_lan egress for the
# mssql role's Chocolatey install and general Windows Update/time sync.
resource "aws_nat_gateway" "lab" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.wan.id
  tags          = { Name = "halcyon-lab-nat" }

  depends_on = [aws_internet_gateway.lab]
}

resource "aws_route_table" "wan" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }

  tags = { Name = "halcyon-lab-rt-wan" }
}

resource "aws_route_table_association" "wan" {
  subnet_id      = aws_subnet.wan.id
  route_table_id = aws_route_table.wan.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.lab.id
  }

  tags = { Name = "halcyon-lab-rt-private" }
}

resource "aws_route_table_association" "dmz" {
  subnet_id      = aws_subnet.dmz.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "lan" {
  subnet_id      = aws_subnet.lan.id
  route_table_id = aws_route_table.private.id
}
