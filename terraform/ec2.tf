# Project Halcyon — AWS deployment path, EC2 instances.
#
# Six hosts (no fw01 - see docs/architecture-aws.md for why): dc01/srv01/
# ws01/ws02 (Windows Server 2022 - not real Windows 11 clients, EC2 can't do
# that without a Dedicated Host + BYOL license), web01 (Ubuntu 22.04),
# attack (Kali, via a Marketplace AMI).

# --- AMIs ------------------------------------------------------------

data "aws_ami" "windows_server_2022" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Windows_Server-2022-English-Full-Base-*"]
  }
}

data "aws_ami" "ubuntu_2204" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# attack's Kali AMI is NOT auto-discovered: AWS Marketplace AMIs require a
# one-time manual subscription in the console before the AMI ID is usable in
# your account/region (Terraform can't auto-subscribe). Subscribe first,
# then set var.kali_ami_id in terraform.tfvars - see variables.tf.

# --- Bootstrap secrets / key pair -------------------------------------

resource "random_password" "windows_bootstrap" {
  length      = 20
  special     = true
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
  min_special = 2
}

resource "aws_key_pair" "lab" {
  key_name   = var.key_name
  public_key = file(var.public_key_path)
}

locals {
  windows_userdata = templatefile("${path.module}/templates/windows-userdata.ps1.tftpl", {
    bootstrap_password = random_password.windows_bootstrap.result
  })

  web01_userdata = templatefile("${path.module}/templates/linux-userdata.yaml.tftpl", {
    public_key = trimspace(file(var.public_key_path))
  })
}

# --- Windows: dc01/srv01/ws01/ws02 -------------------------------------

resource "aws_instance" "dc01" {
  ami                    = data.aws_ami.windows_server_2022.id
  instance_type            = var.windows_instance_type
  subnet_id                  = aws_subnet.lan.id
  vpc_security_group_ids       = [aws_security_group.lan_internal.id]
  iam_instance_profile           = aws_iam_instance_profile.ssm.name
  key_name                          = aws_key_pair.lab.key_name
  user_data                            = local.windows_userdata

  root_block_device {
    volume_size = 80
    volume_type = "gp3"
  }

  tags = { Name = "halcyon-dc01" }
}

resource "aws_instance" "srv01" {
  ami                    = data.aws_ami.windows_server_2022.id
  instance_type            = var.windows_instance_type
  subnet_id                  = aws_subnet.lan.id
  vpc_security_group_ids       = [aws_security_group.lan_internal.id]
  iam_instance_profile           = aws_iam_instance_profile.ssm.name
  key_name                          = aws_key_pair.lab.key_name
  user_data                            = local.windows_userdata

  root_block_device {
    volume_size = 80
    volume_type = "gp3"
  }

  tags = { Name = "halcyon-srv01" }
}

resource "aws_instance" "ws01" {
  ami                    = data.aws_ami.windows_server_2022.id
  instance_type            = var.windows_instance_type
  subnet_id                  = aws_subnet.lan.id
  vpc_security_group_ids       = [aws_security_group.lan_internal.id]
  iam_instance_profile           = aws_iam_instance_profile.ssm.name
  key_name                          = aws_key_pair.lab.key_name
  user_data                            = local.windows_userdata

  root_block_device {
    volume_size = 50
    volume_type = "gp3"
  }

  tags = { Name = "halcyon-ws01" }
}

resource "aws_instance" "ws02" {
  ami                    = data.aws_ami.windows_server_2022.id
  instance_type            = var.windows_instance_type
  subnet_id                  = aws_subnet.lan.id
  vpc_security_group_ids       = [aws_security_group.lan_internal.id]
  iam_instance_profile           = aws_iam_instance_profile.ssm.name
  key_name                          = aws_key_pair.lab.key_name
  user_data                            = local.windows_userdata

  root_block_device {
    volume_size = 50
    volume_type = "gp3"
  }

  tags = { Name = "halcyon-ws02" }
}

# --- Linux: web01 --------------------------------------------------------
# Public subnet (subnet_wan) - the DMZ boundary is enforced by Security
# Group here, not subnet placement (see docs/architecture-aws.md).

resource "aws_instance" "web01" {
  ami                    = data.aws_ami.ubuntu_2204.id
  instance_type            = var.web01_instance_type
  subnet_id                  = aws_subnet.wan.id
  vpc_security_group_ids       = [aws_security_group.wan_web01.id]
  iam_instance_profile           = aws_iam_instance_profile.ssm.name
  key_name                          = aws_key_pair.lab.key_name
  user_data                            = local.web01_userdata

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  tags = { Name = "halcyon-web01" }
}

# --- attack (Kali) -------------------------------------------------------
# Never an Ansible provisioning target (see ansible/site.yml's opening
# comment) - just needs the key pair + SG in place. Marketplace Kali AMIs
# ship with cloud-init + SSH already enabled, unlike the KVM path's manual
# VNC-console SSH-enable step.

resource "aws_instance" "attack" {
  ami                    = var.kali_ami_id
  instance_type            = var.attack_instance_type
  subnet_id                  = aws_subnet.wan.id
  vpc_security_group_ids       = [aws_security_group.attack.id]
  iam_instance_profile           = aws_iam_instance_profile.ssm.name
  key_name                          = aws_key_pair.lab.key_name

  tags = { Name = "halcyon-attack" }
}
