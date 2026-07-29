# Project Halcyon — AWS deployment path, IAM.
#
# One role + instance profile, attached to all six instances, granting only
# SSM Session Manager access. This is what makes Ansible control-node
# reachability work without a bastion host (see scripts/aws-deploy.sh) — the
# AWS analog of the KVM host's ".1 management adapter on every libvirt
# network" out-of-band reachability trick. No other AWS API permissions are
# needed: nothing inside the guests calls AWS APIs.

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ssm" {
  name               = "halcyon-lab-ec2-ssm-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm" {
  name = "halcyon-lab-ec2-ssm-profile"
  role = aws_iam_role.ssm.name
}
