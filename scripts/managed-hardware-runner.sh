#!/usr/bin/env bash
# Privileged hardware runner policy. Invoke only through a root-owned launcher
# that fixes every MANAGED_* value; never grant sudo access to this file alone.
set -euo pipefail

: "${MANAGED_BENCHMARK_PROFILE:?hardware profile is not configured}"
: "${MANAGED_BENCHMARK_DEVICES:?member devices are not configured}"
: "${MANAGED_BENCHMARK_SPARE_DEVICE:?spare device is not configured}"
: "${MANAGED_BENCHMARK_ZFS_SINGLE_DEVICE:?ZFS single device is not configured}"
: "${MANAGED_BENCHMARK_COMMAND:?benchmark command is not configured}"

MANAGED_RESULTS_ROOT=${MANAGED_RESULTS_ROOT:-/var/lib/modern-fs-benchmark/results}
MANAGED_DEVICE_SIZE_BYTES=${MANAGED_DEVICE_SIZE_BYTES:-17179869184}
MANAGED_ZFS_SINGLE_SIZE_BYTES=${MANAGED_ZFS_SINGLE_SIZE_BYTES:-34359738368}
MANAGED_CALIB_MIN_SEQ_MBPS=${MANAGED_CALIB_MIN_SEQ_MBPS:-300}
MANAGED_CALIB_MIN_RAND_IOPS=${MANAGED_CALIB_MIN_RAND_IOPS:-8000}

if [[ $# -eq 1 && $1 == --capabilities ]]; then
  printf '%s\n' hardware-random-scaling-v1 hardware-random-scaling-v2 \
    "hardware-profile:$MANAGED_BENCHMARK_PROFILE"
  exit 0
fi

if [[ $# -ne 10 ]]; then
  echo "usage: modern-fs-benchmark-run <run-id> <attempt> <fs> <layout> <dev-size> <aging-iters> <aging-io> <snap-count> <min-seq-mbps> <min-rand-iops>" >&2
  exit 2
fi

run_id=$1
attempt=$2
fs=$3
layout=$4
dev_size=$5
aging_iters=$6
aging_io=$7
snap_count=$8
min_seq_mbps=$9
min_rand_iops=${10}
configuration="$fs/$layout"

if [[ ! $run_id =~ ^[0-9]+$ || ! $attempt =~ ^[0-9]+$ ]]; then
  echo "run ID and attempt must be numeric" >&2
  exit 2
fi

case "$configuration" in
  ext4/single | ext4/md-raid10 | ext4/lvm-raid10 | ext4/md-raid6 | \
  ext4/md-raid10-luks | xfs/single | xfs/md-raid10 | xfs/lvm-raid10 | \
  xfs/zvol | xfs/lvm-raid10-int | btrfs/raid1 | btrfs/raid6 | \
  btrfs/single | btrfs/raid1-luks | zfs/mirror | zfs/mirror-8k | \
  zfs/single | zfs/raidz1 | zfs/raidz2 | zfs/raidz1-enc | \
  zfs/raidz2-enc | zfs/mirror-enc | bcachefs/replicas2 | \
  bcachefs/single | bcachefs/ec | bcachefs/replicas2-enc) ;;
  *)
    echo "unsupported benchmark configuration: $configuration" >&2
    exit 2
    ;;
esac

if [[ ! $dev_size =~ ^[1-9][0-9]*[KMGT]?$ || ! $aging_io =~ ^[1-9][0-9]*[KMGT]?$ ]]; then
  echo "device and aging sizes must use fio size syntax" >&2
  exit 2
fi
for value in "$aging_iters" "$snap_count" "$min_seq_mbps" "$min_rand_iops"; do
  if [[ ! $value =~ ^[0-9]+$ ]]; then
    echo "benchmark counts and calibration floors must be numeric" >&2
    exit 2
  fi
done

expected_dev_size=16G
expected_aging_iters=100
case "$configuration" in
  ext4/lvm-raid10 | xfs/lvm-raid10 | xfs/lvm-raid10-int)
    expected_aging_iters=8
    ;;
  xfs/zvol)
    expected_aging_iters=25
    ;;
  zfs/single)
    expected_dev_size=32G
    expected_aging_iters=10
    ;;
  zfs/mirror-8k) ;;
  zfs/*)
    expected_aging_iters=10
    ;;
esac
if [[ $dev_size != "$expected_dev_size" || $aging_iters != "$expected_aging_iters" \
      || $aging_io != 64M || $snap_count != 500 \
      || $min_seq_mbps != "$MANAGED_CALIB_MIN_SEQ_MBPS" \
      || $min_rand_iops != "$MANAGED_CALIB_MIN_RAND_IOPS" ]]; then
  echo "benchmark settings do not match the reviewed workflow matrix" >&2
  exit 2
fi

exec 9>/run/lock/modern-fs-benchmark.lock
if ! flock -n 9; then
  echo "another filesystem benchmark is already running" >&2
  exit 75
fi

require_size() {
  local device=$1 expected=$2 actual
  if [[ ! -b $device ]]; then
    echo "$device is not a block device" >&2
    exit 2
  fi
  actual=$(blockdev --getsize64 "$device")
  if [[ $actual -ne $expected ]]; then
    echo "$device has size $actual bytes; expected $expected" >&2
    exit 2
  fi
}

read -ra devices <<< "$MANAGED_BENCHMARK_DEVICES"
if [[ ${#devices[@]} -ne 4 ]]; then
  echo "managed runner must configure exactly four member devices" >&2
  exit 2
fi
all_devices=("${devices[@]}" "$MANAGED_BENCHMARK_SPARE_DEVICE" \
  "$MANAGED_BENCHMARK_ZFS_SINGLE_DEVICE")
device_identities=
for device in "${all_devices[@]}"; do
  identity=$(stat -Lc '%t:%T' -- "$device")
  case " $device_identities " in
    *" $identity "*)
      echo "$device resolves to a duplicate block device" >&2
      exit 2
      ;;
  esac
  device_identities+=" $identity"
done

for device in "${devices[@]}" "$MANAGED_BENCHMARK_SPARE_DEVICE"; do
  require_size "$device" "$MANAGED_DEVICE_SIZE_BYTES"
done
require_size "$MANAGED_BENCHMARK_ZFS_SINGLE_DEVICE" \
  "$MANAGED_ZFS_SINGLE_SIZE_BYTES"

results_dir="$MANAGED_RESULTS_ROOT/$run_id-$attempt/$fs-$layout"
install -d -m 0755 "$MANAGED_RESULTS_ROOT"
rm -rf -- "$results_dir"
install -d -m 0755 "$results_dir"

export BENCH_DEVICES="$MANAGED_BENCHMARK_DEVICES"
export BENCH_SPARE_DEVICE="$MANAGED_BENCHMARK_SPARE_DEVICE"
export BENCH_ZFS_SINGLE_DEVICE="$MANAGED_BENCHMARK_ZFS_SINGLE_DEVICE"
export BENCH_WIPE=1
export DEV_SIZE="$dev_size"
export AGING_ITERS="$aging_iters"
export AGING_IO="$aging_io"
export SNAPSCALE_COUNT="$snap_count"
export CALIB_MIN_SEQ_MBPS="$min_seq_mbps"
export CALIB_MIN_RAND_IOPS="$min_rand_iops"
export BENCH_HARDWARE_RANDOM_SCALING=1
export BENCH_HARDWARE_PROFILE="$MANAGED_BENCHMARK_PROFILE"
export BENCH_REVISION="${MANAGED_BENCHMARK_REVISION:-}"
export RESULTS_DIR="$results_dir"

exec "$MANAGED_BENCHMARK_COMMAND" "$fs" "$layout"
