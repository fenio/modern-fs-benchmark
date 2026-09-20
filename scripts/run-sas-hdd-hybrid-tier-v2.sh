#!/usr/bin/env bash
# Run the isolated sas-hdd hybrid-tier-v2 scenario with the standard workload.
# shellcheck disable=SC1091,SC2034
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=run-bench.sh
source "$SCRIPT_DIR/run-bench.sh"
# shellcheck source=lib/sas-hdd-hybrid-tier-v2.sh
source "$SCRIPT_DIR/lib/sas-hdd-hybrid-tier-v2.sh"

HYBRID_COMPLETED=0

hybrid_v2_skip_degraded_rebuild() {
  DEG_WRITE_IOPS=null
  DEG_READ_IOPS=null
  REBUILD_S=null
  log "degraded/rebuild phase deferred for hybrid-tier-v2"
}

hybrid_v2_skip_corruption_scrub() {
  SCRUB_S=null
  SCRUB_FOUND=null
  SCRUB_REPAIRED=null
  DATA_INTACT=null
  log "direct corruption/scrub phase deferred for hybrid-tier-v2"
}

hybrid_v2_on_exit() {
  local status=$? cleanup_status=0
  trap - EXIT INT TERM
  set +e
  if [[ $HYBRID_COMPLETED -eq 1 ]]; then
    hybrid_v2_capture_topology
  fi
  hybrid_cleanup
  cleanup_status=$?
  if [[ $status -eq 0 && $cleanup_status -eq 0 && $HYBRID_COMPLETED -eq 1 ]]; then
    touch "$RESULTS_DIR/hybrid-v2-cleanup-$FS-complete"
    chmod a+r "$RESULTS_DIR/hybrid-v2-cleanup-$FS-complete"
  elif [[ $status -eq 0 ]]; then
    status=1
  fi
  exit "$status"
}

main() {
  local fs=${1:?usage: run-sas-hdd-hybrid-tier-v2.sh <btrfs|zfs|bcachefs>}
  local layout
  case "$fs" in
    btrfs) layout=hybrid-dmcache ;;
    zfs) layout=hybrid-special-l2arc ;;
    bcachefs) layout=hybrid-native-3ssd ;;
    *) die "unsupported hybrid filesystem: $fs" ;;
  esac

  configure_benchmark "$fs" "$layout"
  require_root
  mkdir -p "$RESULTS_DIR/raw" "$MNT"
  enable_trace
  trap hybrid_v2_on_exit EXIT INT TERM
  hybrid_v2_prepare

  phase_degraded_rebuild() { hybrid_v2_skip_degraded_rebuild; }
  phase_corruption_scrub() { hybrid_v2_skip_corruption_scrub; }
  run_benchmark_phases
  HYBRID_COMPLETED=1
}

main "$@"
