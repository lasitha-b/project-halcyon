# Project Halcyon — AWS deployment path, Terraform provider pin.
#
# State is local (terraform/terraform.tfstate*, gitignored) — this is a
# single-operator, destroy-after-use lab, not team-shared infra. No backend
# block: local is Terraform's default.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
