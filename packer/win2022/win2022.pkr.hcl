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
  description = "Path or URL to the Windows Server 2022 evaluation ISO (Microsoft Evaluation Center)"
}

variable "iso_checksum" {
  type    = string
  default = "sha256:3e4fa6d8507b554856fc9ca6079cc402df11a8b79344871669f0251535255325"
}

source "vmware-iso" "win2022" {
  iso_url          = var.iso_url
  iso_checksum     = var.iso_checksum
  guest_os_type    = "windows2019srv-64"
  communicator     = "winrm"
  winrm_username   = "vagrant"
  winrm_password   = "vagrant"
  # Pin the WinRM target to a fixed IP (backed by the fixed MAC in vmx_data
  # below, which lands the guest on a stable vmnet8 lease). Without this, Packer
  # auto-discovers the guest IP from the vmnet8 DHCP lease file (there's no
  # VMware Tools to query) and caches it once. On the second windows-restart the
  # guest renews onto a *different* lease, but Packer keeps reconnecting to the
  # stale cached IP - which nothing answers ARP for anymore, hence the "no route
  # to host" on the sysprep provisioner's file upload. win11 already pins its IP
  # this way; win2022 was missing it, which is exactly why only the win2022
  # sysprep rebuild failed.
  # NOTE: for winrm_host to be reachable, vmnet8's dhcpd must reserve this IP
  # for the fixed MAC below. Add to /etc/vmware/vmnet8/dhcpd/dhcpd.conf:
  #   host halcyon-win2022 { hardware ethernet 00:50:56:20:20:22;
  #                          fixed-address 172.16.109.202; }
  # then `sudo vmware-networks --stop && sudo vmware-networks --start`.
  winrm_host       = "172.16.109.202"
  winrm_use_ntlm   = true
  winrm_timeout    = "6h"
  # No shutdown_command - the final provisioner (sysprep.ps1) shuts the VM
  # down itself via `sysprep /shutdown`. Packer just waits for that.
  shutdown_timeout = "15m"
  cpus             = 2
  memory           = 3072
  disk_size        = 60000
  version          = 19
  headless         = true
  firmware         = "bios"
  disk_adapter_type = "sata"
  network_adapter_type = "e1000e"
  output_directory = "/mnt/halcyon-lab/packer-output/win2022"

  vmx_data = {
    # Fixed MAC so DHCP consistently hands this VM the same lease
    # (172.16.109.202 on vmnet8), matching winrm_host above. VMware Tools isn't
    # installed in this image, so Packer's normal getGuestIPAddress lookup has
    # nothing to query - a fixed IP sidesteps that instead of depending on it.
    "ethernet0.addressType" = "static"
    "ethernet0.address"     = "00:50:56:20:20:22"
  }

  floppy_files = [
    "packer/win2022/autounattend.xml",
    "packer/win2022/scripts/enable-winrm.ps1",
    "packer/win2022/unattend-specialize.xml",
  ]

  boot_command = ["<enter>"]
  boot_wait    = "5s"
}

build {
  sources = ["source.vmware-iso.win2022"]

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
    output             = "/mnt/halcyon-lab/packer-output/boxes/halcyon-win2022.box"
    provider_override  = "vmware"
  }
}
