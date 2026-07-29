# Project Halcyon — AWS deployment path, input variables.
# Copy terraform.tfvars.example to terraform.tfvars and fill in real values.

variable "region" {
  description = "AWS region to deploy the lab into."
  type        = string
  default     = "us-east-1"
}

variable "admin_cidr" {
  description = <<-EOT
    CIDR allowed to reach lab management ports (SSH to web01/attack, and
    admin RDP if ever added) — this is the operator's own IP, NOT the
    student/attacker's vantage point. attack itself is the in-lab attacker
    box; admin_cidr is who's allowed to manage the range from outside it.
    Set to your own IP/32, never leave as 0.0.0.0/0.
  EOT
  type        = string
}

variable "key_name" {
  description = "Name for the Terraform-managed EC2 key pair used for web01/attack SSH."
  type        = string
  default     = "halcyon-lab"
}

variable "public_key_path" {
  description = "Path to a local SSH public key file to import as the lab key pair."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "kali_ami_id" {
  description = <<-EOT
    AMI ID for the `attack` instance, sourced from the AWS Marketplace Kali
    Linux listing. Marketplace AMIs require a one-time manual subscription
    in the console before the AMI ID is usable in your account/region —
    Terraform cannot auto-discover or auto-subscribe to it. Subscribe at
    https://aws.amazon.com/marketplace (search "Kali Linux"), then copy the
    AMI ID for your chosen region here.
  EOT
  type        = string
}

variable "windows_instance_type" {
  description = "Instance type for dc01/srv01/ws01/ws02 (AD DS/CA/SQL workloads need real headroom)."
  type        = string
  default     = "t3.large"
}

variable "web01_instance_type" {
  description = "Instance type for web01 (Flask+nginx+Postgres, light load)."
  type        = string
  default     = "t3.small"
}

variable "attack_instance_type" {
  description = "Instance type for attack (tester's working box, needs some headroom)."
  type        = string
  default     = "t3.medium"
}

variable "budget_limit_usd" {
  description = "Monthly USD budget threshold for the halcyon-lab AWS Budget alarm."
  type        = string
  default     = "50"
}

variable "budget_alert_email" {
  description = "Email address to notify at 80% of budget_limit_usd."
  type        = string
}

variable "project_tag" {
  description = "Value for the Project tag applied to every resource — drives destroy verification and the budget cost filter."
  type        = string
  default     = "halcyon-lab"
}
