# SAS HDD three-copy and drive-loss scenario

`three-copy-v1` compares equivalent three-copy layouts on three independent SAS
HDDs, then injects repeatable member-path failures. It is an isolated scenario:
it has its own managed launcher, workflow, result history, and dashboard, and it
does not change the `sas-hdd` baseline matrix.

## Compared layouts

| Configuration | Copies | Expected arbitrary member-loss tolerance |
|---|---:|---:|
| Ext4 on three-member md RAID1 | 3 | 2 |
| XFS on three-member md RAID1 | 3 | 2 |
| Btrfs RAID1C3 | 3 | 2 |
| One three-way ZFS mirror | 3 | 2 |
| bcachefs `replicas=3` | 3 | 2 |
| Btrfs RAID1 control | 2 per chunk | 1 |

Btrfs RAID1 on three devices is deliberately a control, not a three-copy row.
It distributes two copies over device pairs and therefore does not guarantee
survival after two arbitrary device losses. RAID1C3 is the matching Btrfs
three-copy profile.

## Physical roles

The scenario reuses five independently backed 16 GiB partitions from the
reviewed baseline inventory. Actions cannot choose or override these paths.

| Role | Stable path |
|---|---|
| member 0 | `/dev/disk/by-id/wwn-0x5000c50094426153-part1` |
| member 1 | `/dev/disk/by-id/wwn-0x5000c5009441febb-part1` |
| member 2 | `/dev/disk/by-id/wwn-0x5000c50094426003-part1` |
| replacement 0 | `/dev/disk/by-id/wwn-0x5000c50094425a03-part1` |
| replacement 1 | `/dev/disk/by-id/wwn-0x5000c50094425f93-part1` |

The managed runner verifies all five block-device identities, their exact
sizes, and their uniqueness before wiping anything. The host-wide benchmark
lock and Actions concurrency group serialize this scenario with every other
SAS benchmark.

## Failure method

Each physical partition is exposed to the filesystem through a fixed
device-mapper linear target. A failure is injected only after `sync` by
suspending the selected mapping, atomically replacing its table with the
`dm-error` target, and resuming it. Every subsequent read or write to that
member returns a hard I/O error. This is deterministic and repeatable without
physically pulling a disk.

Filesystem-native commands mark or replace the failed member after the path
starts returning errors:

- md RAID1 uses `mdadm --fail`, `--remove`, and `--add`;
- Btrfs uses blocking `btrfs replace`;
- ZFS uses `zpool replace` and `zpool wait -t resilver` after the path failure;
- bcachefs adds a spare, removes the failed member by its recorded numeric
  device index, and waits for background reconciliation to finish, so recovery
  does not require opening the failed path.

Unlike the throughput-oriented baseline, md RAID1 completes its initial full
member synchronization before measurements begin.

## Campaign

After the normal healthy workload, the scenario:

1. fails one member and records degraded random-read and random-write IOPS;
2. verifies the prepared file checksum;
3. replaces the failed member, waits for full reconstruction, and verifies the
   checksum again;
4. runs the existing separate corruption-and-scrub phase;
5. recreates a clean filesystem and prepares a dedicated failure-probe file;
6. fails two members sequentially and records mount, checksum, read, and write
   outcomes;
7. for true three-copy layouts, attempts to replace both members, verifies the
   checksum, and runs a final full scrub/check when recovery completes.

Bcachefs reconciliation waits are bounded so a stuck kernel worker cannot hold
the hardware runner indefinitely. A reconciliation timeout after successful
device removal is published as a negative recovery outcome, shown as
`NO`/missing timing data, and raised as a hard audit anomaly. Other command,
topology, ownership, cleanup, schema, and evidence failures still fail the job
and suppress publication. Corruption testing is skipped when one-member
recovery did not complete. The Btrfs RAID1 control records its two-loss outcome
without attempting recovery.

## Scope and publication

This tests independent **drive paths and media members**, not independent
controllers, expanders, enclosures, hosts, racks, or sites. All selected disks
share the host's LSI SAS3008 controller and SAS expander, so the results must
not be described as controller- or enclosure-failure-domain testing.

- Workflow: `.github/workflows/bench-real-hw-sas-hdd-three-copy.yml`
- Enable variable: `ENABLE_SAS_HDD_THREE_COPY_BENCHMARKS`
- History: `results-real-hw-sas-hdd-three-copy-v1`
- Dashboard: `/sas-hdd/three-copy/`
- Schedule: monthly, because the campaign performs repeated full rebuilds

The Actions run artifact contains raw fio output, the full command trace,
topology evidence, scrub logs, and result JSON. The long-lived history branch
retains result JSON plus the compact text topology and scrub evidence needed to
interpret the published dashboard without making every monthly commit carry
all fio traces indefinitely.

Before a successful run removes its owned mappings, cleanup revalidates each
mapping's UUID, exact physical backing partition, mount/swap/open state,
holders, and imported-pool membership. It then clears filesystem signatures
from all five fixed roles so failed members cannot later be auto-assembled from
stale metadata. Any failed ownership, teardown, evidence, or wipe check
suppresses the completion marker and publication.
