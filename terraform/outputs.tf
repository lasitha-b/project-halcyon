# Project Halcyon — AWS deployment path, outputs.
#
# Consumed by scripts/aws-gen-inventory.py (via `terraform output -json`) to
# build ansible/generated/inventory_aws.yml, and by scripts/aws-deploy.sh to
# open SSM port-forward tunnels per instance.

output "hosts" {
  description = "Per-host instance ID / private IP / inventory group, keyed by hostname."
  value = {
    dc01 = {
      instance_id = aws_instance.dc01.id
      private_ip  = aws_instance.dc01.private_ip
      os          = "windows"
      group       = "domain_controllers"
    }
    srv01 = {
      instance_id = aws_instance.srv01.id
      private_ip  = aws_instance.srv01.private_ip
      os          = "windows"
      group       = "member_servers"
    }
    ws01 = {
      instance_id = aws_instance.ws01.id
      private_ip  = aws_instance.ws01.private_ip
      os          = "windows"
      group       = "clients"
    }
    ws02 = {
      instance_id = aws_instance.ws02.id
      private_ip  = aws_instance.ws02.private_ip
      os          = "windows"
      group       = "clients"
    }
    web01 = {
      instance_id = aws_instance.web01.id
      private_ip  = aws_instance.web01.private_ip
      os          = "linux"
      group       = "linux"
    }
    attack = {
      instance_id = aws_instance.attack.id
      private_ip  = aws_instance.attack.private_ip
      os          = "linux"
      group       = "attacker"
    }
  }
}

output "windows_bootstrap_password" {
  description = "Password for the local 'vagrant' bootstrap user on every Windows host."
  value       = random_password.windows_bootstrap.result
  sensitive   = true
}

output "ssh_private_key_hint" {
  description = "Reminder of which local private key pairs with the deployed public key (var.public_key_path)."
  value       = replace(var.public_key_path, ".pub", "")
}
