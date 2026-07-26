# Fix pfSense TCP checksum offloading (KVM e1000 NIC)

## Problem

pfSense on KVM with e1000 NICs gets ~200 bytes/sec throughput through NAT
(3.5 MB ≈ 5 hours). KVM's e1000 emulation produces bad TCP checksums when
hardware offloading is enabled. FreeBSD's `em` driver trusts the virtual
"hardware" to compute checksums, but KVM computes them incorrectly. Every
packet gets dropped and retransmitted.

## Fix applied to repo

`packer/pfsense/config.xml` — added `<disablechecksumoffloading></disablechecksumoffloading>`
inside `<system>`, next to the existing TSO/LRO offload disables (lines 51-52).
Future builds from this config get the fix automatically.

## Live fix — running pfSense (fw01)

### Option A: immediate, non-persistent (takes effect instantly, lost on reboot)

Run these three commands on fw01 (console menu option 8 "Shell", or SSH if enabled):

```
ifconfig em0 -txcsum -rxcsum -tso -lro
ifconfig em1 -txcsum -rxcsum -tso -lro
ifconfig em2 -txcsum -rxcsum -tso -lro
```

### Option B: persistent (survives reboot)

On fw01, edit `/cf/conf/config.xml` and add this line inside the `<system>` block
(right after `<disablelargereceiveoffloading></disablelargereceiveoffloading>`):

```
<disablechecksumoffloading></disablechecksumoffloading>
```

Then either:
- Web GUI: Diagnostics → Backup & Restore → Restore → upload the modified config.xml
- Or reboot (pfSense reads `/cf/conf/config.xml` at boot)

## Verify the fix

```
# Check that checksum offloading is disabled
ifconfig em0 | grep -i checksum   # should show nothing or "-txcsum -rxcsum"
ifconfig em1 | grep -i checksum
ifconfig em2 | grep -i checksum
```

## Expected result

Throughput through pfSense NAT goes from ~0.2 KB/s → 50-100+ MB/s.
A 3.5 MB file transfers in under a second instead of ~5 hours.

## Optional: also bump fw01 resources

```
virsh setmaxmem fw01 2048M --config
virsh setmem fw01 2048M --config
virsh setvcpus fw01 2 --config --maximum
virsh setvcpus fw01 2 --config
```

Then reboot fw01. The extra vCPU helps packet processing (NAT + 3-interface firewall).
