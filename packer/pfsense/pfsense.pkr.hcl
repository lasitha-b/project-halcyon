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

# ---------------------------------------------------------------------------
# pfSense CE edge firewall base box.
#
# IMPORTANT - read packer/pfsense/README.md before running this. Unlike the
# Windows/Ubuntu templates, pfSense CE has NO unattended-install answer-file
# mechanism: its installer is a fixed ncurses wizard, so the only way to drive
# it non-interactively is a timing-sensitive `boot_command` keystroke script
# (below). That is inherently brittle across pfSense point releases and host
# speeds, and it is the one build step in this repo that could not be validated
# on the build host yet.
#
# The RELIABLE, supported path (documented in the README) is:
#   1. Install pfSense CE once by hand (accept all installer defaults, ~5 min).
#   2. WebGUI -> Diagnostics -> Backup & Restore -> Restore packer/pfsense/config.xml
#   3. `vagrant package` / snapshot the result as the halcyon/pfsense box.
# The config.xml is the actual deliverable; this template just automates
# wrapping it into a box when the boot_command happens to line up.
# ---------------------------------------------------------------------------

variable "iso_url" {
  type        = string
  description = "Path or URL to the pfSense CE installer ISO (e.g. netgate pfSense-CE-2.7.2-RELEASE-amd64.iso, decompressed)"
}

variable "iso_checksum" {
  type        = string
  default     = "none"
  description = "sha256:... of the pfSense CE ISO. Left 'none' by default because the ISO is fetched manually; set it for reproducible builds."
}

source "vmware-iso" "pfsense" {
  iso_url          = var.iso_url
  iso_checksum     = var.iso_checksum
  guest_os_type    = "freebsd-64"
  # pfSense has no VMware Tools and no WinRM/SSH-by-default; like the other
  # Halcyon boxes we do NOT let Packer connect over a communicator. Packer only
  # needs to power the VM, run the install boot_command, and wait for the
  # installer to power off. Provisioning (the config.xml) is applied out of
  # band exactly like every other box in this repo.
  communicator     = "none"
  shutdown_timeout = "20m"
  cpus             = 1
  memory           = 1024
  disk_size        = 8000
  version          = 19
  headless         = true
  firmware         = "bios"
  disk_adapter_type    = "sata"
  network_adapter_type = "e1000"
  output_directory     = "/mnt/halcyon-lab/packer-output/pfsense"

  # config.xml rides along on a floppy so a post-install console step (or the
  # manual restore) can pull it from /dev/fd0. FAT label matters for pfSense's
  # own "import from media" flows.
  floppy_files = [
    "packer/pfsense/config.xml",
  ]
  floppy_label = "PFSENSE_CFG"

  # Best-effort unattended install for pfSense CE 2.7.x. These keystrokes walk
  # the installer wizard accepting defaults: Install -> Auto (ZFS) -> stripe ->
  # single disk -> proceed, then reboot. Timings WILL need tuning on the build
  # host; watch the first run over VNC and adjust the <waitNs>. If a release
  # changes the wizard, fix here or fall back to the manual path in the README.
  boot_wait = "40s"
  boot_command = [
    "<enter><wait30>",       # accept copyright / start installer
    "<enter><wait5>",        # Install pfSense
    "<enter><wait5>",        # Auto (ZFS) guided install
    "<enter><wait5>",        # Proceed with install (pool type: stripe)
    "<spacebar><enter><wait5>", # select the single disk
    "<enter><wait5>",        # confirm - last chance / proceed
    "<wait180>",             # let the base system extract & install
    "<enter><wait30>",       # 'Reboot' at the end of install
  ]

  vmx_data = {
    # Three NICs, order matters - it fixes em0/em1/em2 inside pfSense, which
    # config.xml pins to wan/lan/dmz respectively. The Vagrantfile pins the
    # SAME order for the running VM; keep the two in sync.
    #   ethernet0 -> em0 -> WAN (vmnet22)
    #   ethernet1 -> em1 -> LAN (vmnet20)
    #   ethernet2 -> em2 -> DMZ (vmnet21)
    "ethernet0.present"        = "TRUE"
    "ethernet0.virtualDev"     = "e1000"
    "ethernet0.connectionType" = "custom"
    "ethernet0.vnet"           = "/dev/vmnet22"
    "ethernet1.present"        = "TRUE"
    "ethernet1.virtualDev"     = "e1000"
    "ethernet1.connectionType" = "custom"
    "ethernet1.vnet"           = "/dev/vmnet20"
    "ethernet2.present"        = "TRUE"
    "ethernet2.virtualDev"     = "e1000"
    "ethernet2.connectionType" = "custom"
    "ethernet2.vnet"           = "/dev/vmnet21"
  }
}

build {
  sources = ["source.vmware-iso.pfsense"]

  # No provisioners: the box ships with the installer's default config. The
  # Halcyon firewall config (config.xml) is applied afterwards, either by the
  # manual WebGUI restore (README step 2) or by a one-time console import from
  # the /dev/fd0 floppy this template attaches. Kept out of the box build so
  # the box stays a clean, re-configurable pfSense install.
  post-processor "vagrant" {
    output            = "/mnt/halcyon-lab/packer-output/boxes/halcyon-pfsense.box"
    provider_override = "vmware"
  }
}
