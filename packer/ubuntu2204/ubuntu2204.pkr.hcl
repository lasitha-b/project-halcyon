packer {
  required_plugins {
    vmware = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/vmware"
    }
    vagrant = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/vagrant"
    }
  }
}

variable "iso_url" {
  type    = string
  default = "/run/media/lasitha/SSD 1TB/ubuntu-22.04.5-live-server-amd64.iso"
}

variable "iso_checksum" {
  type    = string
  default = "sha256:9bc6028870aef3f74f4e16b900008179e78b130e6b0b9a140635434a46aa98b0"
}

source "vmware-iso" "ubuntu2204" {
  iso_url          = var.iso_url
  iso_checksum     = var.iso_checksum
  guest_os_type    = "ubuntu-64"
  communicator     = "ssh"
  ssh_username     = "vagrant"
  ssh_password     = "vagrant"
  ssh_timeout      = "2h"
  shutdown_command = "echo 'vagrant' | sudo -S shutdown -P now"
  cpus             = 2
  memory           = 3072
  disk_size        = 30000
  version          = 19
  headless         = true
  network_adapter_type = "vmxnet3"
  output_directory = "/mnt/halcyon-lab/packer-output/ubuntu2204"

  http_directory = "packer/ubuntu2204/http"
  boot_command = [
    "e",
    "<down><down><down><end><left><left><left>",
    " autoinstall ds=nocloud-net\\;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ ",
    "<f10>"
  ]
  boot_wait = "2s"
}

build {
  sources = ["source.vmware-iso.ubuntu2204"]

  provisioner "shell" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get -y upgrade",
      "sudo apt-get -y install open-vm-tools",
      "echo 'vagrant ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/vagrant"
    ]
  }

  post-processor "vagrant" {
    output             = "/mnt/halcyon-lab/packer-output/boxes/halcyon-ubuntu2204.box"
    provider_override  = "vmware"
  }
}
