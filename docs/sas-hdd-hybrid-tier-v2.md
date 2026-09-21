# `sas-hdd` hybrid-tier-v2 scenario

`hybrid-tier-v2` preserves the v1 physical budget and workload while testing a
different bcachefs SSD policy. Btrfs and ZFS are repeated unchanged as controls,
so the v1 and v2 dashboards remain directly comparable.

- Workflow: `.github/workflows/bench-real-hw-sas-hdd-hybrid-tier-v2.yml`
- History: `results-real-hw-sas-hdd-hybrid-tier-v2`
- Dashboard: `/sas-hdd/hybrid-tier-v2/`
- Result provenance: `benchmark_scenario: "hybrid-tier-v2"`
- Schedule variable: `ENABLE_SAS_HDD_HYBRID_TIER_V2_BENCHMARKS`

The v1 results and contract remain published at
[`/sas-hdd/hybrid-tier/`](sas-hdd-hybrid-tier.md).

## Difference from v1

| Filesystem | v1 | v2 |
|---|---|---|
| Btrfs | eight-HDD md RAID10 with mirrored SSD LVM `dm-cache` | unchanged |
| ZFS | four HDD mirrors, mirrored metadata-only special vdev, SSD L2ARC | unchanged |
| bcachefs | two durable foreground/metadata SSDs plus one durability-0 promotion SSD | all three SSDs form one durable foreground, metadata, and promotion target |

The v2 bcachefs configuration follows the
[documented writeback arrangement](https://bcachefs-docs.readthedocs.io/en/latest/feat-caching.html):
`foreground_target=hot`, `promote_target=hot`, and `background_target=hdd`.
User data and metadata retain two replicas, so any one hot-tier SSD may fail
without losing the required durable copies. `promote_whole_extents=0` limits a
4 KiB cache miss to the requested range instead of promoting its whole extent.

The third SSD is no longer assigned `durability=0`. Its bcachefs device label is
`hot.ssd2`, alongside `hot.ssd0` and `hot.ssd1`. Allocation targets are
preferences with fallback behavior; they are not hard capacity partitions.

## Physical contract

V2 reuses the provisioned v1 partitions and fixed root-owned WWN mapping:

| Role | Count | Partition size |
|---|---:|---:|
| HDD capacity tier | 8 | 128 GiB each |
| SSD data tier | 3 | 64 GiB each |
| Btrfs-only cache metadata | 2 | 4 GiB each |

No repartitioning is required when switching between v1 and v2. Btrfs uses two
SSD data partitions and both metadata partitions. ZFS uses those same two data
partitions as its special mirror and the third as L2ARC. Bcachefs uses all three
data partitions as the `hot` target and does not use the metadata partitions.

The safety checks, excluded `/dev/sda` OS disk, SMART requirements, and shared
SAS controller caveat are identical to v1.

## Workload and evidence

V2 runs the same sizes, phase order, cache-dropping policy, and skipped
degraded/corruption/near-full phases as v1. This keeps every existing metric
comparable across the two dashboards.

In addition to detailed `bcachefs fs usage -a -h` and device-superblock
placement evidence, the bcachefs job captures reconcile status, cumulative
counters, `data_promote` timing, and the effective `promote_whole_extents`
option. These diagnostics are outside timed workload regions and explain
whether reads were promoted or skipped. Publication requires the effective
value to be `0`, verifies that journal and btree allocations are on the three
hot SSDs rather than the HDDs, and retains the text diagnostics with each
history run instead of relying only on the expiring Actions artifact.

V1 and v2 use the same GitHub concurrency group and host `/run/lock` file. They
must never run concurrently with each other or with the SAS HDD baseline.
