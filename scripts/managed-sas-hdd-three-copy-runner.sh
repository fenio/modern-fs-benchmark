#!/usr/bin/env bash
# Privileged policy for three-copy-v1. Invoke only through the immutable
# root-owned launcher that fixes every MANAGED_THREE_COPY_* value.
set -euo pipefail

: "${MANAGED_BENCHMARK_PROFILE:?hardware profile is not configured}"
: "${MANAGED_BENCHMARK_SCENARIO:?benchmark scenario is not configured}"
: "${MANAGED_THREE_COPY_MEMBER_DEVICES:?member roles are not configured}"
: "${MANAGED_THREE_COPY_SPARE_DEVICES:?spare roles are not configured}"
: "${MANAGED_BENCHMARK_COMMAND:?benchmark command is not configured}"

readonly DEVICE_SIZE_BYTES=17179869184
MANAGED_RESULTS_ROOT=${MANAGED_RESULTS_ROOT:-/var/lib/modern-fs-benchmark/results}

[[ $MANAGED_BENCHMARK_SCENARIO == three-copy-v1 ]] \
  || { echo "unsupported benchmark scenario: $MANAGED_BENCHMARK_SCENARIO" >&2; exit 2; }

if [[ $# -eq 1 && $1 == --capabilities ]]; then
  printf '%s\n' "hardware-profile:$MANAGED_BENCHMARK_PROFILE" \
    "benchmark-scenario:$MANAGED_BENCHMARK_SCENARIO" \
    failure-domain-dm-error-v1 three-copy-topology-v1 hardware-random-scaling-v2
  exit 0
fi

if [[ $# -ne 4 ]]; then
  echo "usage: modern-fs-benchmark-three-copy-run <run-id> <attempt> <fs> <layout>" >&2
  exit 2
fi
run_id=$1
attempt=$2
fs=$3
layout=$4
configuration="$fs/$layout"
[[ $run_id =~ ^[0-9]+$ && $attempt =~ ^[0-9]+$ ]] \
  || { echo "run ID and attempt must be numeric" >&2; exit 2; }
case "$configuration" in
  ext4/md-raid1 | xfs/md-raid1 | btrfs/raid1c3 | btrfs/raid1 | \
  zfs/mirror3 | bcachefs/replicas3) ;;
  *) echo "unsupported three-copy configuration: $configuration" >&2; exit 2 ;;
esac
if [[ $fs == bcachefs ]]; then
  command -v bcachefs >/dev/null \
    || { echo "bcachefs tools are not installed" >&2; exit 2; }
  bcachefs reconcile wait --help >/dev/null \
    || { echo "bcachefs reconcile wait is unavailable" >&2; exit 2; }
  bcachefs reconcile status --help >/dev/null \
    || { echo "bcachefs reconcile status is unavailable" >&2; exit 2; }
fi

exec 9>/run/lock/modern-fs-benchmark.lock
if ! flock -w 3600 9; then
  echo "timed out waiting for another filesystem benchmark to finish" >&2
  exit 75
fi

require_size() {
  local device=$1 actual
  [[ -b $device ]] || { echo "$device is not a block device" >&2; exit 2; }
  actual=$(blockdev --getsize64 "$device")
  [[ $actual -eq $DEVICE_SIZE_BYTES ]] \
    || { echo "$device has size $actual bytes; expected $DEVICE_SIZE_BYTES" >&2; exit 2; }
}

read -ra members <<<"$MANAGED_THREE_COPY_MEMBER_DEVICES"
read -ra spares <<<"$MANAGED_THREE_COPY_SPARE_DEVICES"
[[ ${#members[@]} -eq 3 ]] || { echo "exactly three member roles are required" >&2; exit 2; }
[[ ${#spares[@]} -eq 2 ]] || { echo "exactly two spare roles are required" >&2; exit 2; }

identities=
swap_devices=$(swapon --show=NAME --noheadings) \
  || { echo "failed to enumerate active swap devices" >&2; exit 2; }
for device in "${members[@]}" "${spares[@]}"; do
  require_size "$device"
  identity=$(stat -Lc '%t:%T' -- "$device")
  case " $identities " in
    *" $identity "*) echo "$device resolves to a duplicate partition" >&2; exit 2 ;;
  esac
  identities+=" $identity"
done

for device in "${members[@]}" "${spares[@]}"; do
  node=$(readlink -f "$device")
  node=${node##*/}
  for holder in "/sys/class/block/$node/holders/"*; do
    [[ -e $holder ]] || continue
    echo "$device is held by ${holder##*/}; refusing destructive setup" >&2
    exit 2
  done
  mountpoints=$(lsblk -nrpo MOUNTPOINTS "$device") \
    || { echo "failed to enumerate mounts for $device" >&2; exit 2; }
  if [[ -n ${mountpoints//[[:space:]]/} ]]; then
    echo "$device is mounted; refusing destructive setup" >&2
    exit 2
  fi
  while IFS= read -r swap_device; do
    [[ -n $swap_device ]] || continue
    if [[ $(stat -Lc '%t:%T' -- "$swap_device") == $(stat -Lc '%t:%T' -- "$device") ]]; then
      echo "$device is active swap; refusing destructive setup" >&2
      exit 2
    fi
  done <<<"$swap_devices"
done

if command -v zpool >/dev/null; then
  pools=$(zpool list -H -o name) \
    || { echo "failed to enumerate imported ZFS pools" >&2; exit 2; }
  while IFS= read -r pool; do
    [[ -n $pool ]] || continue
    pool_status=$(zpool status -LP "$pool") \
      || { echo "failed to inspect ZFS pool $pool" >&2; exit 2; }
    while IFS= read -r pool_device; do
      [[ -b $pool_device ]] || continue
      pool_identity=$(stat -Lc '%t:%T' -- "$pool_device")
      case " $identities " in
        *" $pool_identity "*)
          echo "$pool_device is an active member of ZFS pool $pool; refusing destructive setup" >&2
          exit 2
          ;;
      esac
    done < <(awk '$1 ~ /^\/dev\// {print $1}' <<<"$pool_status")
  done <<<"$pools"
fi

results_dir="$MANAGED_RESULTS_ROOT/$run_id-$attempt/$fs-$layout"
install -d -m 0755 "$MANAGED_RESULTS_ROOT"
rm -rf -- "$results_dir"
install -d -m 0755 "$results_dir"

export BENCH_DEVICES="$MANAGED_THREE_COPY_MEMBER_DEVICES"
export BENCH_SPARE_DEVICES="$MANAGED_THREE_COPY_SPARE_DEVICES"
export BENCH_SPARE_DEVICE=${spares[0]}
export BENCH_WIPE=1 BENCH_MD_INITIAL_SYNC=1
export BENCH_HARDWARE_PROFILE="$MANAGED_BENCHMARK_PROFILE"
export BENCH_SCENARIO="$MANAGED_BENCHMARK_SCENARIO"
export BENCH_REVISION="${MANAGED_BENCHMARK_REVISION:-}"
export BENCH_RESULT_DEVICES="$MANAGED_THREE_COPY_MEMBER_DEVICES"
export BENCH_RESULT_NDEV=3
export BENCH_HARDWARE_RANDOM_SCALING=1
export RESULTS_DIR="$results_dir"
export NDEV=3 DEV_SIZE=16G SEQ_SIZE=2G READ_SIZE=2G AGING_SIZE=2G
export AGING_IO=64M AGING_ITERS=8 COMP_SIZE=2G RUNTIME=30 SNAPSCALE_COUNT=250
export CALIB_MIN_SEQ_MBPS=20 CALIB_MIN_RAND_IOPS=100

exec "$MANAGED_BENCHMARK_COMMAND" "$fs" "$layout"
