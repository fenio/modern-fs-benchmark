# `sas-hdd` hybrid-tier-v1 scenario

`hybrid-tier-v1` compares three practical ways to combine eight capacity HDDs
with three fast SSDs. It fixes the physical budget and workload, not the
internal mechanism: bcachefs has native allocation targets, ZFS has allocation
classes and L2ARC, and Btrfs requires a block-layer cache.

The follow-up [`hybrid-tier-v2`](sas-hdd-hybrid-tier-v2.md) preserves this
scenario and its results while testing all three SSDs as one durable bcachefs
foreground, metadata, and promotion target. Btrfs and ZFS are unchanged controls.

The scenario is independent from the 28-case `sas-hdd` baseline:

- Workflow: `.github/workflows/bench-real-hw-sas-hdd-hybrid-tier.yml`
- History: `results-real-hw-sas-hdd-hybrid-tier-v1`
- Dashboard: `/sas-hdd/hybrid-tier/`
- Result provenance: `benchmark_scenario: "hybrid-tier-v1"`
- Schedule variable: `ENABLE_SAS_HDD_HYBRID_TIER_BENCHMARKS`

Changing placement, cache mode, redundancy, or role capacity requires a new
scenario ID and history branch.

## Physical contract

All paths are root-owned launcher policy, never workflow inputs.

| Role | Stable whole-disk WWNs | Partition |
|---|---|---:|
| HDD capacity tier | `0x5000c50094425a2b`, `0x5000c50094420143`, `0x5000c500944224af`, `0x5000c50094420323`, `0x5000c5009442212f`, `0x5000c5009442640f`, `0x5000c500944259f7`, `0x5000c50094422a7f` | 128 GiB each |
| Durable SSD tier | `0x5000cca04ec26e38`, `0x5000cca04ec25d84` | 64 GiB data plus 4 GiB cache metadata each |
| Disposable read cache | `0x5000cca04ec25e3c` | 64 GiB |

The HDDs report zero grown defects. The SSDs report zero grown defects and
0-3% endurance used. Four suspect HDDs remain excluded. All SAS media share one
SAS3008 and one SAS3x40 expander, so controller or expander failure is outside
the redundancy claim.

The capacity contract is approximately four HDDs usable, one arbitrary HDD
failure tolerated, one durable-tier SSD failure tolerated, and complete loss
of the read-cache SSD tolerated. Device-level guarantees still depend on
correct flush/FUA handling and power-loss-safe SSD behavior.

## Comparable topologies

| Filesystem | Capacity layer | Durable acceleration | Read promotion |
|---|---|---|---|
| Btrfs | eight-device md RAID10 | mirrored LVM `dm-cache`, writeback | the same `dm-cache`; Btrfs has no separate target |
| ZFS | four HDD mirror vdevs | mirrored metadata-only special vdev | SSD3 L2ARC |
| bcachefs | eight-device `hdd` background group, replicas=2 | two-device `hot` foreground and metadata group | SSD3 `readcache` group with durability 0 |

The Btrfs row is deliberately named `hybrid-dmcache`: redundancy and placement
below the filesystem are part of that deployed solution. Btrfs data and
metadata profiles are `single` on the logical cached device because the HDD
RAID10 and SSD mirrors already provide the second physical copy. Btrfs profiles
cannot target an SSD device class.

The ZFS special vdev uses `special_small_blocks=0`, making it metadata-only.
It is permanent, pool-critical allocation, not a write cache. L2ARC is a
disposable read cache populated through ARC. No SLOG is included because SLOG
accelerates synchronous ZIL traffic, not general foreground writes. Filesystem
metadata is therefore SSD-backed, while ZIL records remain on the HDD pool.

The bcachefs targets are placement preferences with fallback behavior, not
hard partitions. New writes prefer the mirrored `hot` group, background work
migrates data toward `hdd`, reads can create a non-authoritative SSD3 copy, and
metadata prefers `hot`.

## Workload policy

The scenario reuses the standard phases so metric definitions remain stable,
but scales data beyond the hosted-runner workload:

- 16 GiB sequential write and read files
- 32 GiB aging file with 32 x 512 MiB overwrite rounds
- 8 GiB compression input
- 60-second timed random workloads
- 250-snapshot scale phase

Direct member corruption and degraded-device rebuild are skipped in v1. Their
meaning differs across the layered cache and target-aware filesystems, and a
naive raw-device overwrite can be hidden or reordered by a cache. Near-full
testing remains skipped on real hardware.

Raw artifacts capture md/LVM cache status, ZFS topology and per-vdev IO, or
detailed `bcachefs fs usage -a -h` and device roles. The text evidence is
retained with each history run. A result is publishable only after the
filesystem is unmounted, dynamic cache topology is removed, all holders are
released, and a filesystem-specific cleanup marker exists.

Result provenance lists active partitions, not merely reserved scenario roles:
Btrfs reports 12 (eight HDD, two cache-data, two cache-metadata), while ZFS and
bcachefs report 11 (eight HDD, two durable SSD, one disposable read-cache SSD).

## Provisioning

`contrib/sas-hdd/provision-hybrid-tier-storage.sh --check` is read-only. The
write mode requires root and this exact confirmation value:

```bash
CONFIRM_DESTROY_SAS_HDD_HYBRID=destroy-sas-hdd-hybrid-tier-disks
```

It validates WWNs, models, capacities, SMART health, zero grown defects,
mounts, swap, holders, root ancestry, and imported ZFS pools before writing.
It creates only the fixed role partitions above and wipes signatures from the
new partitions after udev settles.

Do not provision or run this scenario concurrently with the baseline. Both
workflows use the same GitHub concurrency group and `/run/lock` file.
