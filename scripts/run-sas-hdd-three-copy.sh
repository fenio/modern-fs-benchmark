#!/usr/bin/env bash
# Run the isolated sas-hdd three-copy-v1 scenario.
# shellcheck disable=SC1091,SC2034
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=run-bench.sh
source "$SCRIPT_DIR/run-bench.sh"
# shellcheck source=lib/sas-hdd-three-copy.sh
source "$SCRIPT_DIR/lib/sas-hdd-three-copy.sh"

THREE_COPY_COMPLETED=0

three_copy_on_exit() {
  local status=$? cleanup_status=0 teardown_safe=1
  trap - EXIT INT TERM
  set +e
  if [[ $THREE_COPY_COMPLETED -eq 1 ]]; then
    three_copy_capture_topology || cleanup_status=1
  fi
  three_copy_resume_mappings
  if [[ $THREE_COPY_FS_STARTED -eq 1 ]]; then
    if three_copy_assert_topology_owned; then
      if ! fs_teardown; then
        cleanup_status=1
        teardown_safe=0
      elif ! three_copy_assert_detached; then
        cleanup_status=1
        teardown_safe=0
      fi
    else
      cleanup_status=1
      teardown_safe=0
    fi
  fi
  if [[ $THREE_COPY_MAPPINGS_STARTED -eq 1 && $teardown_safe -eq 1 ]]; then
    if ! three_copy_wipe_owned_mappings "$THREE_COPY_FS_STARTED"; then
      cleanup_status=1
      teardown_safe=0
    fi
  fi
  if [[ $THREE_COPY_MAPPINGS_STARTED -eq 1 && $teardown_safe -eq 1 ]]; then
    if ! three_copy_restore_members || ! three_copy_assert_detached; then
      cleanup_status=1
      teardown_safe=0
    fi
  fi
  if [[ $THREE_COPY_MAPPINGS_STARTED -eq 1 && $teardown_safe -eq 1 ]]; then
    three_copy_remove_mappings || cleanup_status=1
  fi
  if [[ $status -eq 0 && $cleanup_status -eq 0 && $THREE_COPY_COMPLETED -eq 1 ]]; then
    touch "$RESULTS_DIR/three-copy-cleanup-$FS-$LAYOUT-complete"
    chmod a+r "$RESULTS_DIR/three-copy-cleanup-$FS-$LAYOUT-complete"
  elif [[ $status -eq 0 ]]; then
    status=1
  fi
  exit "$status"
}

three_copy_run_phases() {
  phase_host_calibration
  THREE_COPY_FS_STARTED=1
  THREE_COPY_MOUNT_DEVICE=
  setup_benchmark_filesystem
  phase_sequential_write
  phase_random_write
  phase_random_read
  phase_sequential_read
  phase_trivial_latency
  phase_source_tree
  phase_sparse_files
  phase_large_directory
  phase_aging
  phase_snapshot_reclaim
  phase_snapshot_scaling
  phase_compression
  phase_divergence
  three_copy_phase_single_loss
  phase_corruption_scrub
  three_copy_phase_double_loss
  phase_enospc
  BENCH_DEFER_RESULT_FINALIZATION=1 write_result
  three_copy_extend_result
}

main() {
  local fs=${1:?usage: run-sas-hdd-three-copy.sh <fs> <layout>}
  local layout=${2:?usage: run-sas-hdd-three-copy.sh <fs> <layout>}
  case "$fs/$layout" in
    ext4/md-raid1 | xfs/md-raid1) BENCH_TOPOLOGY=mdraid1-three-copy ;;
    btrfs/raid1c3) BENCH_TOPOLOGY=native-three-copy ;;
    btrfs/raid1) BENCH_TOPOLOGY=native-two-copy-three-device-control ;;
    zfs/mirror3) BENCH_TOPOLOGY=three-way-mirror ;;
    bcachefs/replicas3) BENCH_TOPOLOGY=native-three-copy ;;
    *) die "unsupported three-copy configuration: $fs/$layout" ;;
  esac

  configure_benchmark "$fs" "$layout"
  require_root
  mkdir -p "$RESULTS_DIR/raw" "$MNT"
  enable_trace
  trap three_copy_on_exit EXIT INT TERM
  three_copy_cleanup_stale
  setup_devices
  three_copy_wrap_devices
  three_copy_run_phases
  THREE_COPY_COMPLETED=1
}

main "$@"
