# -*- mode: ruby -*-
# Project Halcyon — VMware Workstation topology.
# Seven VMs across three isolated host-only networks, segmented by a pfSense
# edge firewall (fw01):
#   WAN  vmnet22  203.0.113.0/24  — attacker (Kali) sits here
#   DMZ  vmnet21  172.20.1.0/24   — WEB01 only (the sole externally-facing host)
#   LAN  vmnet20  10.20.10.0/24   — the internal AD network (DC/SRV/clients)
# fw01 has one NIC on each and routes/filters between them (see
# packer/pfsense/ and docs/architecture.md "Network segmentation"). WAN→LAN is
# blocked; the only way in is the web app via a pfSense port-forward, then a
# pivot through the DMZ. Guests' default gateway is pfSense (.254 on each
# segment), handed out — together with deterministic static-MAC IP mappings —
# by pfSense's own DHCP.
#
# This file ONLY defines VM lifecycle (boot, network, sizing) - it does NOT
# provision them. Provisioning is a separate, explicit `ansible-playbook`
# step in scripts/deploy.sh, run after `vagrant up` rather than via Vagrant's
# built-in "ansible" provisioner. That's a deliberate choice, not laziness:
# on a Windows host, `vagrant` runs as a native Windows binary, and Ansible
# has no supported Windows control node, so the built-in provisioner (which
# shells out to `ansible-playbook` on the same OS running `vagrant`) simply
# cannot work there - provisioning has to run from WSL2 instead. Keeping
# both host OSes on one code path (this same decoupled flow) rather than
# branching Windows vs. Linux behavior in the Vagrantfile itself. See
# README.md's "Host OS: Linux vs. Windows" section.
#
# Networking note: these base boxes have no VMware Tools installed, and none of
# the three lab vmnets has a NAT service (isolation - see docs/architecture.md).
# vagrant-vmware-desktop's WinRM/SSH communicator only knows how to reach a
# guest via NAT port-forwarding or via VMware Tools' own IP report - neither is
# available here, and standing up real NAT/Tools just to satisfy Vagrant's own
# connectivity check isn't worth compromising the lab's isolation for. So each
# VM gets a fixed MAC, pfSense hands it a deterministic IP by that MAC (static
# DHCP mapping, kept in sync with ansible/inventory.yml), and Vagrant's own
# communicator is disabled entirely - `vagrant up` only boots machines, it
# never talks to them. Ansible (run separately, straight after `vagrant up`)
# reaches every guest directly over the host's own management adapter on each
# vmnet (the host holds .1 on all three), independent of the firewall rules.

require 'yaml'

VAGRANTFILE_API_VERSION = "2"

# Per-segment vmnets. Overridable for hosts that relocate them, but the three
# must exist (scripts/setup-networks.sh creates vmnet21/vmnet22 and disables
# VMware's own DHCP on all three so pfSense can own it).
WAN = ENV.fetch("HALCYON_WAN_VMNET", "vmnet22")
DMZ = ENV.fetch("HALCYON_DMZ_VMNET", "vmnet21")
LAN = ENV.fetch("HALCYON_LAN_VMNET", "vmnet20")

# fw01 (pfSense) is defined first so `vagrant up --no-parallel` boots it before
# anything that depends on its DHCP/gateway. It is multi-homed: one NIC per
# segment, in em0/em1/em2 order = WAN, LAN, DMZ (must match config.xml's
# interface assignment - see packer/pfsense/README.md).
FIREWALL = {
  "fw01" => {
    box: "halcyon/pfsense", cpus: 1, mem: 1024, gui: false,
    # [vnet, mac] per NIC, ordered em0, em1, em2:
    nics: [
      [WAN, "00:50:56:20:ff:22"],  # em0 -> WAN
      [LAN, "00:50:56:20:ff:20"],  # em1 -> LAN
      [DMZ, "00:50:56:20:ff:21"],  # em2 -> DMZ (opt1)
    ],
  },
}

# Single-NIC lab hosts. `ip` is the pfSense static-DHCP mapping (source of
# truth also in ansible/inventory.yml and packer/pfsense/config.xml); `vnet`
# is which segment the host lives on.
HOSTS = {
  "dc01"   => { ip: "10.20.10.10",  mac: "00:50:56:20:10:10", vnet: LAN, box: "halcyon/win2022",     cpus: 2, mem: 3072, gui: false },
  "srv01"  => { ip: "10.20.10.20",  mac: "00:50:56:20:10:20", vnet: LAN, box: "halcyon/win2022",     cpus: 2, mem: 3072, gui: false },
  "ws01"   => { ip: "10.20.10.31",  mac: "00:50:56:20:10:31", vnet: LAN, box: "halcyon/win11",       cpus: 2, mem: 2560, gui: true  },
  "ws02"   => { ip: "10.20.10.32",  mac: "00:50:56:20:10:32", vnet: LAN, box: "halcyon/win11",       cpus: 2, mem: 2560, gui: true  },
  "web01"  => { ip: "172.20.1.40",  mac: "00:50:56:20:10:40", vnet: DMZ, box: "halcyon/ubuntu22",    cpus: 2, mem: 1536, gui: false },
  "attack" => { ip: "203.0.113.66", mac: "00:50:56:20:10:66", vnet: WAN, box: "halcyon/attack-kali", cpus: 4, mem: 2048, gui: false },
}

Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|
  # -- fw01 (pfSense), multi-homed, defined first so it boots first ----------
  FIREWALL.each do |name, spec|
    config.vm.define name do |node|
      node.vm.box = spec[:box]
      node.vm.hostname = name
      node.vm.communicator = "none"
      node.vm.boot_timeout = 60
      node.vm.synced_folder ".", "/vagrant", disabled: true
      node.vm.network "forwarded_port", guest: 22, host: 2222, id: "ssh", disabled: true

      node.vm.provider "vmware_desktop" do |v|
        v.gui = spec[:gui]
        v.vmx["memsize"] = spec[:mem].to_s
        v.vmx["numvcpus"] = spec[:cpus].to_s
        spec[:nics].each_with_index do |(vnet, mac), i|
          # ethernet0/1/2 -> em0/em1/em2 inside pfSense. Order is load-bearing
          # (config.xml pins wan=em0, lan=em1, opt1=em2).
          v.vmx["ethernet#{i}.present"] = "TRUE"
          v.vmx["ethernet#{i}.connectiontype"] = "custom"
          v.vmx["ethernet#{i}.vnet"] = "/dev/#{vnet}"
          v.vmx["ethernet#{i}.addresstype"] = "static"
          v.vmx["ethernet#{i}.address"] = mac
          v.vmx["ethernet#{i}.virtualdev"] = "e1000"
        end
        # Vagrant still tracks an address even with communicator "none"; point
        # it at the LAN vmnet (fw01's management side) so the lookup doesn't
        # hang. We never actually use it (no communicator).
        v.nat_device = LAN
        v.force_vmware_license = "workstation"
        v.clone_directory = "/mnt/halcyon-lab/vms"
      end
    end
  end

  # -- single-NIC lab hosts --------------------------------------------------
  HOSTS.each do |name, spec|
    config.vm.define name do |node|
      node.vm.box = spec[:box]
      node.vm.hostname = name

      # No communicator - Vagrant only boots these VMs, it never connects to
      # them. See header comment for why.
      node.vm.communicator = "none"
      node.vm.boot_timeout = 60
      # No VMware Tools in these boxes, so HGFS (the shared-folder transport)
      # doesn't exist - Vagrant's default root-folder auto-sync would hang
      # forever on "Waiting for HGFS to become available". We don't use
      # synced folders at all (Ansible handles all file transfer), so just
      # turn it off.
      node.vm.synced_folder ".", "/vagrant", disabled: true
      # Vagrant/the box both default to forwarding guest port 22 to host
      # 2222 for SSH access, regardless of communicator - with several VMs
      # that's a hard collision on host port 2222 (this plugin's port-forward
      # check doesn't auto-correct like Vagrant core's own forwarded_port
      # handling does). We never connect through this forward (no communicator,
      # Ansible talks straight to the static lab IPs), so just turn it off.
      node.vm.network "forwarded_port", guest: 22, host: 2222, id: "ssh", disabled: true

      node.vm.provider "vmware_desktop" do |v|
        v.gui = spec[:gui]
        v.vmx["memsize"] = spec[:mem].to_s
        v.vmx["numvcpus"] = spec[:cpus].to_s
        # Single NIC on this host's segment, fixed MAC so pfSense's static DHCP
        # mapping always hands it the same IP. Isolation: never bridge, never
        # attach to a real-LAN vmnet.
        v.vmx["ethernet0.present"] = "TRUE"
        v.vmx["ethernet0.connectiontype"] = "custom"
        v.vmx["ethernet0.vnet"] = "/dev/#{spec[:vnet]}"
        v.vmx["ethernet0.addresstype"] = "static"
        v.vmx["ethernet0.address"] = spec[:mac]
        # Vagrant still tries to report/track the guest's address even with
        # communicator "none" - it reads the vmnet DHCP lease table by MAC,
        # but always checks config.nat_device, which defaults to vmnet8.
        # Point it at this host's actual segment or the lookup silently checks
        # the wrong table and "vagrant up" hangs on "Waiting for the VM to
        # receive an address".
        v.nat_device = spec[:vnet]
        # Modern free-for-personal-use VMware Workstation (17.5.2+) reports
        # license "standard" even though it's the full-featured product (no
        # license key needed anymore). vagrant-vmware-desktop's stale
        # standard-license check misreads that as the crippled Player
        # product and picks the wrong vmrun mode, breaking the snapshot
        # calls linked clones depend on. Override the detected value.
        v.force_vmware_license = "workstation"
        # VM clones default to .vagrant/machines inside the project dir,
        # which lives on the small root filesystem. Redirect to the large
        # dedicated lab drive instead.
        v.clone_directory = "/mnt/halcyon-lab/vms"
      end

      # No provisioner block here on purpose - see the header comment.
      # scripts/deploy.sh runs `ansible-playbook` separately after `vagrant up`.
    end
  end
end
