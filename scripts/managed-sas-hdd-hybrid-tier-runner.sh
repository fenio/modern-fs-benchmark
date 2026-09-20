#!/usr/bin/env bash
# Privileged policy for hybrid-tier-v1. Invoke only through the immutable
# root-owned sas-hdd launcher that fixes every MANAGED_HYBRID_* value.
set -euo pipefail

: "${MANAGED_BENCHMARK_PROFILE:?hardware profile is not configured}"
: "${MANAGED_BENCHMARK_SCENARIO:?benchmark scenario is not configured}"
: "${MANAGED_HYBRID_HDD_DEVICES:?HDD roles are not configured}"
: "${MANAGED_HYBRID_HOT_DEVICES:?durable SSD roles are not configured}"
: "${MANAGED_HYBRID_META_DEVICES:?cache metadata roles are not configured}"
: "${MANAGED_HYBRID_READ_CACHE_DEVICE:?read-cache role is not configured}"
: "${MANAGED_BENCHMARK_COMMAND:?benchmark command is not configured}"

readonly HDD_SIZE_BYTES=137438953472
readonly HOT_SIZE_BYTES=68719476736
readonly META_SIZE_BYTES=4294967296
readonly READ_CACHE_SIZE_BYTES=68719476736
MANAGED_RESULTS_ROOT=${MANAGED_RESULTS_ROOT:-/var/lib/modern-fs-benchmark/results}

case "$MANAGED_BENCHMARK_SCENARIO" in
  hybrid-tier-v1) topology_capability=hybrid-tier-topology-v1 ;;
  hybrid-tier-v2) topology_capability=hybrid-tier-topology-v2 ;;
  *) echo "unsupported benchmark scenario: $MANAGED_BENCHMARK_SCENARIO" >&2; exit 2 ;;
esac

if [[ $# -eq 1 && $1 == --capabilities ]]; then
  printf '%s\n' "hardware-profile:$MANAGED_BENCHMARK_PROFILE" \
    "benchmark-scenario:$MANAGED_BENCHMARK_SCENARIO" \
    "$topology_capability" hardware-random-scaling-v2
  exit 0
fi

if [[ $# -ne 3 ]]; then
  echo "usage: modern-fs-benchmark-hybrid-tier-run <run-id> <attempt> <btrfs|zfs|bcachefs>" >&2
  exit 2
fi
run_id=$1
attempt=$2
fs=$3
[[ $run_id =~ ^[0-9]+$ && $attempt =~ ^[0-9]+$ ]] \
  || { echo "run ID and attempt must be numeric" >&2; exit 2; }
case "$fs" in btrfs | zfs | bcachefs) ;; *) echo "unsupported filesystem: $fs" >&2; exit 2 ;; esac

exec 9>/run/lock/modern-fs-benchmark.lock
if ! flock -n 9; then
  echo "another filesystem benchmark is already running" >&2
  exit 75
fi

require_size() {
  local device=$1 expected=$2 actual
  [[ -b $device ]] || { echo "$device is not a block device" >&2; exit 2; }
  actual=$(blockdev --getsize64 "$device")
  [[ $actual -eq $expected ]] \
    || { echo "$device has size $actual bytes; expected $expected" >&2; exit 2; }
}

read -ra hdds <<<"$MANAGED_HYBRID_HDD_DEVICES"
read -ra hot <<<"$MANAGED_HYBRID_HOT_DEVICES"
read -ra meta <<<"$MANAGED_HYBRID_META_DEVICES"
[[ ${#hdds[@]} -eq 8 ]] || { echo "exactly eight HDD roles are required" >&2; exit 2; }
[[ ${#hot[@]} -eq 2 && ${#meta[@]} -eq 2 ]] \
  || { echo "exactly two durable SSD and metadata roles are required" >&2; exit 2; }

all_devices=("${hdds[@]}" "${hot[@]}" "${meta[@]}" "$MANAGED_HYBRID_READ_CACHE_DEVICE")
identities=
for device in "${all_devices[@]}"; do
  identity=$(stat -Lc '%t:%T' -- "$device")
  case " $identities " in
    *" $identity "*) echo "$device resolves to a duplicate partition" >&2; exit 2 ;;
  esac
  identities+=" $identity"
done
for device in "${hdds[@]}"; do require_size "$device" "$HDD_SIZE_BYTES"; done
for device in "${hot[@]}"; do require_size "$device" "$HOT_SIZE_BYTES"; done
for device in "${meta[@]}"; do require_size "$device" "$META_SIZE_BYTES"; done
require_size "$MANAGED_HYBRID_READ_CACHE_DEVICE" "$READ_CACHE_SIZE_BYTES"

case "$MANAGED_BENCHMARK_SCENARIO/$fs" in
  hybrid-tier-v1/btrfs | hybrid-tier-v2/btrfs) layout=hybrid-dmcache ;;
  hybrid-tier-v1/zfs | hybrid-tier-v2/zfs) layout=hybrid-special-l2arc ;;
  hybrid-tier-v1/bcachefs) layout=hybrid-native ;;
  hybrid-tier-v2/bcachefs) layout=hybrid-native-3ssd ;;
esac
results_dir="$MANAGED_RESULTS_ROOT/$run_id-$attempt/$fs-$layout"
install -d -m 0755 "$MANAGED_RESULTS_ROOT"
rm -rf -- "$results_dir"
install -d -m 0755 "$results_dir"

export BENCH_HYBRID_HDD_DEVICES="$MANAGED_HYBRID_HDD_DEVICES"
export BENCH_HYBRID_HOT_DEVICES="$MANAGED_HYBRID_HOT_DEVICES"
export BENCH_HYBRID_META_DEVICES="$MANAGED_HYBRID_META_DEVICES"
export BENCH_HYBRID_READ_CACHE_DEVICE="$MANAGED_HYBRID_READ_CACHE_DEVICE"
export BENCH_HARDWARE_PROFILE="$MANAGED_BENCHMARK_PROFILE"
export BENCH_REVISION="${MANAGED_BENCHMARK_REVISION:-}"
export BENCH_HARDWARE_RANDOM_SCALING=1
export RESULTS_DIR="$results_dir"
export SEQ_SIZE=16G READ_SIZE=16G AGING_SIZE=32G AGING_IO=512M
export AGING_ITERS=32 COMP_SIZE=8G RUNTIME=60 SNAPSCALE_COUNT=250
export CALIB_MIN_SEQ_MBPS=20 CALIB_MIN_RAND_IOPS=100

exec "$MANAGED_BENCHMARK_COMMAND" "$fs"
