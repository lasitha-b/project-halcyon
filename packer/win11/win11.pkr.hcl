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
  type        = string
  description = "Path or URL to the Windows 11 evaluation ISO (Microsoft Evaluation Center)"
}

variable "iso_checksum" {
  type    = string
  default = "sha256:a61adeab895ef5a4db436e0a7011c92a2ff17bb0357f58b13bbc4062e535e7b9"
}

source "vmware-iso" "win11" {
  iso_url          = var.iso_url
  iso_checksum     = var.iso_checksum
  guest_os_type    = "windows9-64"
  communicator     = "winrm"
  winrm_username   = "vagrant"
  winrm_password   = "vagrant"
  # NOTE: vmnet8's dhcpd must reserve this IP for the fixed MAC in vmx_data
  # below, or winrm_host won't be reachable. Add to
  # /etc/vmware/vmnet8/dhcpd/dhcpd.conf:
  #   host halcyon-win11 { hardware ethernet 00:50:56:20:11:99;
  #                        fixed-address 172.16.109.199; }
  # then `sudo vmware-networks --stop && sudo vmware-networks --start`.
  winrm_host       = "172.16.109.199"
  winrm_use_ntlm   = true
  winrm_timeout    = "6h"
  # No shutdown_command - the final provisioner (sysprep.ps1) shuts the VM
  # down itself via `sysprep /shutdown`. Packer just waits for that.
  shutdown_timeout = "15m"
  cpus             = 2
  memory           = 2560
  disk_size        = 60000
  version          = 19
  headless         = true
  firmware         = "bios"
  disk_adapter_type = "sata"
  network_adapter_type = "e1000e"
  output_directory = "/mnt/halcyon-lab/packer-output/win11"

  vmx_data = {
    # Fixed MAC so DHCP always hands this VM the same reserved IP
    # (172.16.109.199 - see /etc/vmware/vmnet8/dhcpd/dhcpd.conf), matching
    # winrm_host above. VMware Tools isn't installed in this image, so
    # Packer's normal getGuestIPAddress lookup has nothing to query - a
    # fixed IP sidesteps that instead of depending on it.
    "ethernet0.addressType" = "static"
    "ethernet0.address"     = "00:50:56:20:11:99"
  }

  floppy_files = [
    "packer/win11/autounattend.xml",
    "packer/win2022/scripts/enable-winrm.ps1",
    "packer/win2022/unattend-specialize.xml",
  ]

  boot_command = ["<enter>"]
  boot_wait    = "5s"
}

build {
  sources = ["source.vmware-iso.win11"]
  provisioner "windows-restart" {}
  provisioner "powershell" {
    script = "packer/win2022/scripts/base-hardening-baseline.ps1"
  }
  provisioner "windows-restart" {}

  provisioner "powershell" {
    # Must be the last provisioner - it shuts the VM down (see
    # shutdown_command above). Regenerates the machine SID on each clone's
    # first boot; see the script for why that matters.
    #
    # pause_before: the preceding windows-restart reports the machine
    # "restarted" as soon as WinRM answers once, but the network stack
    # sometimes isn't fully settled yet - the very next provisioner's file
    # upload has reliably hit "no route to host" without this pause.
    pause_before = "60s"
    script       = "packer/win2022/scripts/sysprep.ps1"
  }

  post-processor "vagrant" {
    output             = "/mnt/halcyon-lab/packer-output/boxes/halcyon-win11.box"
    provider_override  = "vmware"
  }
}
