# `sas-hdd` real-hardware profile

The `sas-hdd` profile is an independent self-hosted benchmark stream for the
Supermicro X10DRi host at `141.14.219.209`. It must not carry the generic
`fs-benchmark` runner label used by farm3.

## Profile identity

- Runner label: `fs-benchmark-sas-hdd`
- Result field: `hardware_profile: "sas-hdd"`
- Workflow: `.github/workflows/bench-real-hw-sas-hdd.yml`
- History branch: `results-real-hw-sas-hdd`
- Dashboard: `/sas-hdd/`
- Scheduled-run variable: `ENABLE_SAS_HDD_BENCHMARKS`

`sas-hdd` identifies the physical hardware inventory, not a permanently fixed
filesystem topology. The current workflow is the `baseline` scenario: four
equal HDD members, one HDD spare, and a separate HDD for ZFS single-device
runs.

Future cache-tier, foreground/promote-target, or other heterogeneous scenarios
should be added alongside the baseline rather than changing its meaning. Each
new scenario must have its own result provenance, fixed root-owned WWN-to-role
mapping, managed-runner capability, history stream, and dashboard below
`/sas-hdd/<scenario>/`. Device-role values must remain launcher-controlled;
Actions jobs must never be allowed to supply raw device paths. This preserves
baseline comparability while allowing experiments that hosted runners cannot
represent.

The first such design is documented in
[`sas-hdd-hybrid-tier.md`](sas-hdd-hybrid-tier.md). It compares a layered
Btrfs cache, ZFS special/L2ARC classes, and native bcachefs targets under one
fixed eight-HDD/three-SSD physical budget. The separate
[`hybrid-tier-v2`](sas-hdd-hybrid-tier-v2.md) stream keeps the Btrfs and ZFS
controls unchanged while testing a three-SSD durable bcachefs hot target.

## Hardware

- CPU: Intel Xeon E5-2640 v4, 10 cores / 20 threads
- RAM: 251 GiB
- Data media: Seagate ST6000NM0095 6 TB 7200 RPM SAS HDDs
- Controller path: LSI SAS3008 through SAS expander
- OS disk: `/dev/sda`, permanently excluded

The benchmark uses small fixed partitions so its capacity matches the hosted
and farm3 matrices. Each partition is on a different physical HDD.

| Role | Stable whole-disk path | Size |
|---|---|---:|
| member 0 | `/dev/disk/by-id/wwn-0x5000c50094426153` | 16 GiB |
| member 1 | `/dev/disk/by-id/wwn-0x5000c5009441febb` | 16 GiB |
| member 2 | `/dev/disk/by-id/wwn-0x5000c50094426003` | 16 GiB |
| member 3 | `/dev/disk/by-id/wwn-0x5000c50094425a03` | 16 GiB |
| spare | `/dev/disk/by-id/wwn-0x5000c50094425f93` | 16 GiB |
| ZFS single | `/dev/disk/by-id/wwn-0x5000c500944259d3` | 32 GiB |

The selected disks reported SMART health `OK`, no grown defects, and lower
non-medium error counts than the excluded disks. `/dev/sdp` and `/dev/sdr`
are explicitly avoided because reconnaissance found 36 grown defects on the
former and 9,988 non-medium errors on the latter.

## Safety boundary

`contrib/sas-hdd/provision-storage.sh` is destructive and accepts only the six
WWNs above. Before writing, it verifies root privileges, the exact model and
capacity, distinct device identities, no mounts, no active swap, block-device
holders, or imported ZFS pool, and that none resolves to `/dev/sda` or any
device backing `/`. Run it with `--check` for a read-only preflight. A write
also requires root and the explicit
`CONFIRM_DESTROY_SAS_HDD=destroy-sas-hdd-profile-disks` confirmation value.

The Actions account receives passwordless sudo access only to a root-owned
installed copy of `contrib/sas-hdd/modern-fs-benchmark-run`. The complete
`/opt/modern-fs-benchmark` tree must also be recursively root-owned, contain no
symlinks, and not be group- or other-writable; the launcher verifies these
properties before executing repository code as root. It fixes the profile,
devices, benchmark tree, calibration floors, and result directory before
invoking `scripts/managed-hardware-runner.sh`. Actions cannot supply or
override device paths.

## Debian host setup

Run these steps from a clean checkout of the commit that will be benchmarked.
Do not use the Actions work directory as the privileged source tree.

Install the base tools, then use the repository installer for every filesystem:

```bash
sudo apt-get update
sudo apt-get install -y bc cryptsetup curl e2fsprogs gawk gdisk git gzip parted \
  procps python3 rsync smartmontools util-linux
for fs in ext4 xfs btrfs zfs bcachefs; do
  sudo scripts/install-deps.sh "$fs"
done
sudo modprobe dm_raid dm_snapshot dm_integrity zfs bcachefs
```

Install an exact commit as an immutable root-owned tree while the runner is
stopped. `REVISION` is checked against `${{ github.sha }}` before every job and
is recorded in each result as `benchmark_revision`.

```bash
revision=$(git rev-parse HEAD)
staging=$(mktemp -d)
git archive "$revision" | tar -x -C "$staging"
printf '%s\n' "$revision" > "$staging/REVISION"
sudo rm -rf /opt/modern-fs-benchmark
sudo install -d -o root -g root -m 0755 /opt/modern-fs-benchmark
sudo cp -a "$staging/." /opt/modern-fs-benchmark/
sudo chown -R root:root /opt/modern-fs-benchmark
sudo chmod -R go-w /opt/modern-fs-benchmark
sudo chmod 0755 /opt/modern-fs-benchmark
sudo install -o root -g root -m 0755 \
  /opt/modern-fs-benchmark/contrib/sas-hdd/modern-fs-benchmark-run \
  /usr/local/sbin/modern-fs-benchmark-run
sudo install -o root -g root -m 0755 \
  /opt/modern-fs-benchmark/contrib/sas-hdd/modern-fs-benchmark-hybrid-tier-run \
  /usr/local/sbin/modern-fs-benchmark-hybrid-tier-run
sudo install -o root -g root -m 0755 \
  /opt/modern-fs-benchmark/contrib/sas-hdd/modern-fs-benchmark-hybrid-tier-v2-run \
  /usr/local/sbin/modern-fs-benchmark-hybrid-tier-v2-run
rm -rf "$staging"
```

Create the result directory and grant the runner account only the fixed
launcher. Replace `actions-runner` if the service uses another account.

```bash
sudo install -d -o root -g root -m 0755 /var/lib/modern-fs-benchmark/results
sudo install -o root -g root -m 0440 /dev/stdin \
  /etc/sudoers.d/modern-fs-benchmark <<'EOF'
actions-runner ALL=(root) NOPASSWD: /usr/local/sbin/modern-fs-benchmark-run *
actions-runner ALL=(root) NOPASSWD:NOSETENV: /usr/local/sbin/modern-fs-benchmark-hybrid-tier-run *
actions-runner ALL=(root) NOPASSWD:NOSETENV: /usr/local/sbin/modern-fs-benchmark-hybrid-tier-v2-run *
EOF
sudo visudo -cf /etc/sudoers.d/modern-fs-benchmark
```

Run the read-only storage validation after ZFS is installed. Only the second
command writes partition tables, and it still performs the complete preflight
before the first write.

```bash
sudo /opt/modern-fs-benchmark/contrib/sas-hdd/provision-storage.sh --check
sudo env CONFIRM_DESTROY_SAS_HDD=destroy-sas-hdd-profile-disks \
  /opt/modern-fs-benchmark/contrib/sas-hdd/provision-storage.sh
```

## Actions runner

Create a dedicated unprivileged `actions-runner` account and install the
current x64 Actions runner under `/opt/actions-runner`. Verify the release
checksum from GitHub before extracting it. Register it with the repository URL
and a short-lived registration token:

```bash
sudo useradd --create-home --shell /bin/bash actions-runner
sudo install -d -o actions-runner -g actions-runner -m 0755 /opt/actions-runner
runner_archive=$(mktemp)
curl -fL -o "$runner_archive" \
  "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
printf '%s  %s\n' "$RUNNER_SHA256" "$runner_archive" | sha256sum -c -
sudo -u actions-runner tar -xzf "$runner_archive" -C /opt/actions-runner
rm -f "$runner_archive"
sudo -u actions-runner /opt/actions-runner/config.sh \
  --url https://github.com/fenio/modern-fs-benchmark \
  --token "$RUNNER_REGISTRATION_TOKEN" \
  --name sas-hdd --labels fs-benchmark-sas-hdd --unattended --replace
sudo /opt/actions-runner/svc.sh install actions-runner
sudo /opt/actions-runner/svc.sh start
```

Set `RUNNER_VERSION` and `RUNNER_SHA256` from the current release page before
running those commands. Keep the default `self-hosted`, `Linux`, and `X64`
labels, add only
`fs-benchmark-sas-hdd`, and never add farm3's `fs-benchmark` label. Finally,
enable scheduled runs with repository variable `ENABLE_SAS_HDD_BENCHMARKS=true`,
or leave it unset and use `workflow_dispatch` for manual runs.
