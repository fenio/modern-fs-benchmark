#!/usr/bin/env bash
# Topology overrides for the isolated sas-hdd hybrid-tier-v2 scenario.
# shellcheck disable=SC2034,SC2317,SC2329

# Reuse the audited role loading, ownership checks, cleanup, and unchanged
# Btrfs/ZFS topology implementations from v1.
# shellcheck source=sas-hdd-hybrid-tier.sh
source "$SCRIPT_DIR/lib/sas-hdd-hybrid-tier.sh"

HYBRID_VG=fsbench_hybrid_v2
HYBRID_MD_HDD=/dev/md/fsbench-hybrid-v2-hdd
HYBRID_MD_HOT=/dev/md/fsbench-hybrid-v2-hot
HYBRID_MD_META=/dev/md/fsbench-hybrid-v2-meta
HYBRID_ZPOOL=fsbench_hybrid_v2

hybrid_v2_bcachefs_uuid() {
  bcachefs fs usage "$MNT" 2>/dev/null \
    | awk '/^Filesystem:/ {print $2; exit}'
}

hybrid_v2_assert_bcachefs_options() {
  local uuid sysfs option value
  uuid=$(hybrid_v2_bcachefs_uuid)
  [[ -n $uuid ]] || die "cannot determine mounted bcachefs UUID"
  sysfs="/sys/fs/bcachefs/$uuid"
  option="$sysfs/options/promote_whole_extents"
  [[ -r $option ]] || die "cannot verify effective promote_whole_extents option"
  read -r value <"$option"
  [[ $value == 0 ]] \
    || die "effective promote_whole_extents option is $value, expected 0"
  [[ -r $sysfs/time_stats/data_promote ]] \
    || die "bcachefs data_promote timing is unavailable"
  [[ -d $sysfs/counters ]] || die "bcachefs counters are unavailable"
}

hybrid_v2_bcachefs_setup() {
  local fmt i devlist
  modprobe bcachefs
  grep -qw bcachefs /proc/filesystems \
    || die "kernel has no bcachefs support"
  fmt=(bcachefs format -f --data_replicas=2 --metadata_replicas=2
    --foreground_target=hot --background_target=hdd
    --promote_target=hot --metadata_target=hot)
  for i in "${!HYBRID_HDDS[@]}"; do
    fmt+=(--label="hdd.disk$i" "${HYBRID_HDDS[i]}")
  done
  for i in "${!HYBRID_HOT[@]}"; do
    fmt+=(--label="hot.ssd$i" "${HYBRID_HOT[i]}")
  done
  fmt+=(--label=hot.ssd2 "$HYBRID_READ_CACHE")
  "${fmt[@]}"
  DEVICES=("${HYBRID_HDDS[@]}" "${HYBRID_HOT[@]}" "$HYBRID_READ_CACHE")
  devlist=$(IFS=:; echo "${DEVICES[*]}")
  mount -t bcachefs -o promote_whole_extents=0 "$devlist" "$MNT"
  hybrid_v2_assert_bcachefs_options
  bcachefs subvolume create "$MNT/data"
  DATA="$MNT/data"
}

hybrid_v2_bcachefs_mount() {
  local devlist
  devlist=$(IFS=:; echo "${DEVICES[*]}")
  mount -t bcachefs -o promote_whole_extents=0 "$devlist" "$MNT"
  hybrid_v2_assert_bcachefs_options
}

hybrid_v2_install_backend() {
  if [[ $FS != bcachefs ]]; then
    hybrid_install_backend
    return
  fi
  DEVICES=("${HYBRID_HDDS[@]}" "${HYBRID_HOT[@]}" "$HYBRID_READ_CACHE")
  fs_setup() { hybrid_v2_bcachefs_setup; }
  bcachefs_mount() { hybrid_v2_bcachefs_mount; }
}

hybrid_v2_capture_bcachefs_diagnostics() {
  local uuid sysfs prefix path
  [[ $FS == bcachefs ]] || return 0
  prefix="$RESULTS_DIR/raw/$BENCH_ID-hybrid-v2"
  uuid=$(hybrid_v2_bcachefs_uuid)
  [[ -n $uuid ]] || return 0
  sysfs="/sys/fs/bcachefs/$uuid"
  bcachefs reconcile status "$MNT" >"$prefix-reconcile-status.txt" 2>&1 || true
  {
    for path in "$sysfs"/counters/*; do
      [[ -f $path ]] || continue
      printf '%s=' "${path##*/}"
      while IFS= read -r line; do printf '%s\n' "$line"; done <"$path"
    done
  } >"$prefix-counters.txt" 2>&1 || true
  {
    for path in "$sysfs"/time_stats/data_promote "$sysfs"/options/promote_whole_extents; do
      [[ -f $path ]] || continue
      printf '=== %s ===\n' "${path#"$sysfs"/}"
      while IFS= read -r line; do printf '%s\n' "$line"; done <"$path"
    done
  } >"$prefix-promotion.txt" 2>&1 || true
}

hybrid_v2_capture_topology() {
  hybrid_capture_topology
  hybrid_v2_capture_bcachefs_diagnostics
}

hybrid_v2_prepare() {
  hybrid_load_roles
  hybrid_cleanup || die "failed to clean stale hybrid-tier-v2 topology"
  hybrid_preflight_and_wipe
  hybrid_v2_install_backend

  case "$FS" in
    btrfs)
      BENCH_RESULT_DEVICES="${HYBRID_HDDS[*]} ${HYBRID_HOT[*]} ${HYBRID_META[*]}"
      BENCH_RESULT_NDEV=12
      ;;
    zfs | bcachefs)
      BENCH_RESULT_DEVICES="${HYBRID_HDDS[*]} ${HYBRID_HOT[*]} $HYBRID_READ_CACHE"
      BENCH_RESULT_NDEV=11
      ;;
  esac
  BENCH_DEVICES=$BENCH_RESULT_DEVICES
  BENCH_RESULT_DEVICE_SIZE_BYTES=omit
  BENCH_SCENARIO=hybrid-tier-v2
  case "$FS" in
    btrfs) BENCH_TOPOLOGY=mdraid10-dmcache-writeback ;;
    zfs) BENCH_TOPOLOGY=mirrors-special-metadata-l2arc ;;
    bcachefs) BENCH_TOPOLOGY=native-three-ssd-writeback ;;
  esac
  export BENCH_DEVICES BENCH_RESULT_DEVICES BENCH_RESULT_NDEV
  export BENCH_RESULT_DEVICE_SIZE_BYTES BENCH_SCENARIO BENCH_TOPOLOGY
}
