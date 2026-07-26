# Project Halcyon — AWS deployment path, provider configuration.

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project = var.project_tag
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}
