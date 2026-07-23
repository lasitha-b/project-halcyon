#!/usr/bin/env python3
"""DEPRECATED - no longer part of the deploy flow.

This used to scrape VMware's vmnet20 DHCP lease table to find each VM's IP,
because VMware's own static reservations were unreliable without VMware Tools.

Since the pfSense edge firewall (fw01) was added, pfSense owns DHCP on every
segment and hands out deterministic IPs via static-MAC mappings (see
packer/pfsense/config.xml), and VMware's per-vmnet dhcpd is disabled by
scripts/setup-networks.sh - so there's no VMware lease table to scrape and no
guesswork left. ansible/inventory.yml now carries the real, fixed IPs directly
and is the single source of truth. scripts/deploy.sh no longer calls this.

Kept only as a signpost; safe to delete.
"""
import sys

if __name__ == "__main__":
    sys.stderr.write(__doc__)
    sys.stderr.write(
        "\nNothing to do. IPs are static via pfSense DHCP; see ansible/inventory.yml.\n"
    )
    sys.exit(0)
