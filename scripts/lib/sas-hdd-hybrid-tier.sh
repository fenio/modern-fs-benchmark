#!/usr/bin/env bash
# Topology lifecycle for the isolated sas-hdd hybrid-tier-v1 scenario.
# The caller must install its cleanup trap before invoking hybrid_prepare.
# shellcheck disable=SC2034,SC2317,SC2329

HYBRID_VG=fsbench_hybrid
HYBRID_MD_HDD=/dev/md/fsbench-hybrid-hdd
HYBRID_MD_HOT=/dev/md/fsbench-hybrid-hot
HYBRID_MD_META=/dev/md/fsbench-hybrid-meta
HYBRID_ZPOOL=fsbench_hybrid

HYBRID_HDDS=()
HYBRID_HOT=()
HYBRID_META=()
HYBRID_READ_CACHE=
HYBRID_ALL_DEVICES=()
HYBRID_MOUNT_TARGETS=()

hybrid_role_contains() {
  local candidate=$1 role
  candidate=$(readlink -f "$candidate")
  for role in "${HYBRID_ALL_DEVICES[@]}"; do
    [[ $candidate != "$(readlink -f "$role")" ]] || return 0
  done
  return 1
}

hybrid_assert_md_owned() {
  local md=$1 resolved slave found=0
  [[ -e $md ]] || return 0
  resolved=$(readlink -f "$md")
  for slave in "/sys/class/block/${resolved##*/}/slaves/"*; do
    [[ -e $slave ]] || continue
    found=1
    hybrid_role_contains "/dev/${slave##*/}" \
      || die "$md contains non-scenario member /dev/${slave##*/}"
  done
  (( found == 1 )) || die "$md has no verifiable scenario members"
}

hybrid_assert_vg_owned() {
  local pv resolved allowed found=0
  vgs "$HYBRID_VG" >/dev/null 2>&1 || return 0
  while read -r pv; do
    [[ -n $pv ]] || continue
    found=1
    resolved=$(readlink -f "$pv")
    allowed=0
    for md in "$HYBRID_MD_HDD" "$HYBRID_MD_HOT" "$HYBRID_MD_META"; do
      [[ $resolved != "$(readlink -f "$md")" ]] || allowed=1
    done
    (( allowed == 1 )) || die "$HYBRID_VG contains non-scenario PV $pv"
  done < <(pvs --noheadings -o pv_name --select "vg_name=$HYBRID_VG" | xargs -n1)
  (( found == 1 )) || die "$HYBRID_VG has no verifiable scenario PVs"
}

hybrid_assert_zpool_owned() {
  local member found=0
  zpool list -H -o name "$HYBRID_ZPOOL" >/dev/null 2>&1 || return 0
  while read -r member; do
    [[ -n $member ]] || continue
    found=1
    hybrid_role_contains "$member" \
      || die "$HYBRID_ZPOOL contains non-scenario member $member"
  done < <(zpool status -LP "$HYBRID_ZPOOL" | awk '$1 ~ /^\// {print $1}')
  (( found == 1 )) || die "$HYBRID_ZPOOL has no verifiable scenario members"
}

hybrid_assert_no_imported_zpool_members() {
  local pools pool status member
  if ! pools=$(zpool list -H -o name 2>/dev/null); then
    [[ ! -d /sys/module/zfs ]] && return 0
    die "cannot enumerate imported ZFS pools"
  fi
  while read -r pool; do
    [[ -n $pool ]] || continue
    status=$(zpool status -LP "$pool") \
      || die "cannot inspect imported ZFS pool $pool"
    while read -r member; do
      [[ -n $member ]] || continue
      if hybrid_role_contains "$member"; then
        die "$member is still owned by imported ZFS pool $pool"
      fi
    done < <(awk '$1 ~ /^\// {print $1}' <<<"$status")
  done <<<"$pools"
}

hybrid_assert_mounts_owned() {
  local source fstype target member resolved expected mount_table
  mount_table=$(findmnt -rn -o TARGET,SOURCE,FSTYPE) \
    || die "cannot enumerate mounted filesystems"
  HYBRID_MOUNT_TARGETS=()
  while read -r target source fstype; do
    [[ -n $target ]] || continue
    case "$target" in "$MNT" | "$MNT"/*) ;; *) continue ;; esac
    HYBRID_MOUNT_TARGETS+=("$target")
    case "$fstype" in
      zfs)
        [[ $source == "$HYBRID_ZPOOL" || $source == "$HYBRID_ZPOOL/"* ]] \
          || die "$target is a foreign ZFS mount from $source"
        ;;
      btrfs)
        resolved=$(readlink -f "${source%%\[*}")
        expected=$(readlink -f "/dev/$HYBRID_VG/origin")
        [[ -n $expected && $resolved == "$expected" ]] \
          || die "$target is a foreign Btrfs mount from $source"
        ;;
      bcachefs)
        IFS=: read -ra mounted_members <<<"$source"
        ((${#mounted_members[@]} > 0)) \
          || die "$target has no verifiable bcachefs source"
        for member in "${mounted_members[@]}"; do
          hybrid_role_contains "${member%%\[*}" \
            || die "$target uses foreign bcachefs member $member"
        done
        ;;
      *) die "$target is a foreign $fstype mount from $source" ;;
    esac
  done <<<"$mount_table"
  return 0
}

hybrid_load_roles() {
  : "${BENCH_HYBRID_HDD_DEVICES:?hybrid HDD roles are not configured}"
  : "${BENCH_HYBRID_HOT_DEVICES:?hybrid durable SSD roles are not configured}"
  : "${BENCH_HYBRID_META_DEVICES:?hybrid cache-metadata roles are not configured}"
  : "${BENCH_HYBRID_READ_CACHE_DEVICE:?hybrid read-cache role is not configured}"

  read -ra HYBRID_HDDS <<<"$BENCH_HYBRID_HDD_DEVICES"
  read -ra HYBRID_HOT <<<"$BENCH_HYBRID_HOT_DEVICES"
  read -ra HYBRID_META <<<"$BENCH_HYBRID_META_DEVICES"
  HYBRID_READ_CACHE=$BENCH_HYBRID_READ_CACHE_DEVICE
  [[ ${#HYBRID_HDDS[@]} -eq 8 ]] || die "hybrid scenario requires eight HDD devices"
  [[ ${#HYBRID_HOT[@]} -eq 2 ]] || die "hybrid scenario requires two durable SSD devices"
  [[ ${#HYBRID_META[@]} -eq 2 ]] || die "hybrid scenario requires two cache-metadata devices"
  HYBRID_ALL_DEVICES=(
    "${HYBRID_HDDS[@]}" "${HYBRID_HOT[@]}" "${HYBRID_META[@]}"
    "$HYBRID_READ_CACHE"
  )
}

hybrid_cleanup() {
  local failed=0 md device resolved node restore_errexit=0 i mount_table target
  local holder dm_name
  [[ $- == *e* ]] && restore_errexit=1
  set +e
  sync
  if zpool list -H -o name "$HYBRID_ZPOOL" >/dev/null 2>&1; then
    hybrid_assert_zpool_owned
  fi
  for md in "$HYBRID_MD_META" "$HYBRID_MD_HOT" "$HYBRID_MD_HDD"; do
    [[ ! -e $md ]] || hybrid_assert_md_owned "$md"
  done
  if vgs "$HYBRID_VG" >/dev/null 2>&1; then
    hybrid_assert_vg_owned
  fi
  hybrid_assert_mounts_owned
  for ((i = ${#HYBRID_MOUNT_TARGETS[@]} - 1; i >= 0; i--)); do
    umount "${HYBRID_MOUNT_TARGETS[i]}" || failed=1
  done
  mount_table=$(findmnt -rn -o TARGET) || failed=1
  while read -r target; do
    case "$target" in
      "$MNT" | "$MNT"/*)
        echo "$target remains mounted after cleanup" >&2
        (( restore_errexit == 0 )) || set -e
        return 1
        ;;
    esac
  done <<<"$mount_table"
  if (( failed != 0 )); then
    (( restore_errexit == 0 )) || set -e
    return 1
  fi
  if zpool list -H -o name "$HYBRID_ZPOOL" >/dev/null 2>&1; then
    zpool destroy -f "$HYBRID_ZPOOL" || failed=1
  fi
  if vgs "$HYBRID_VG" >/dev/null 2>&1; then
    if vgchange -an "$HYBRID_VG"; then
      vgremove -y "$HYBRID_VG" || failed=1
    else
      failed=1
    fi
  fi
  udevadm settle || failed=1
  if ! vgs "$HYBRID_VG" >/dev/null 2>&1; then
    for md in "$HYBRID_MD_META" "$HYBRID_MD_HOT" "$HYBRID_MD_HDD"; do
      if [[ -e $md ]]; then
        resolved=$(readlink -f "$md")
        for holder in "/sys/class/block/${resolved##*/}/holders/"dm-*; do
          [[ -e $holder/dm/name ]] || continue
          read -r dm_name < "$holder/dm/name"
          case "$dm_name" in
            "$HYBRID_VG"-*) dmsetup remove --retry "$dm_name" || failed=1 ;;
            *)
              echo "$md has non-scenario holder $dm_name" >&2
              failed=1
              ;;
          esac
        done
        mdadm --stop "$md" || failed=1
      fi
    done
  fi
  udevadm settle
  for device in "${HYBRID_ALL_DEVICES[@]}"; do
    resolved=$(readlink -f "$device")
    [[ -b $resolved ]] || continue
    node=${resolved##*/}
    if compgen -G "/sys/class/block/$node/holders/*" >/dev/null; then
      echo "$device retains a block-device holder after cleanup" >&2
      failed=1
    fi
  done
  (( restore_errexit == 0 )) || set -e
  return "$failed"
}

hybrid_preflight_and_wipe() {
  local device resolved node identity identities=
  for device in "${HYBRID_ALL_DEVICES[@]}"; do
    resolved=$(readlink -f "$device")
    [[ -b $resolved ]] || die "$device is not a block device"
    identity=$(stat -Lc '%t:%T' -- "$resolved")
    case " $identities " in
      *" $identity "*) die "$device resolves to a duplicate partition" ;;
    esac
    identities+=" $identity"
    if lsblk -nrpo MOUNTPOINTS "$resolved" | grep -q '[^[:space:]]'; then
      die "$device or a descendant is mounted"
    fi
    node=${resolved##*/}
    if compgen -G "/sys/class/block/$node/holders/*" >/dev/null; then
      die "$device has an unexplained block-device holder"
    fi
  done
  hybrid_assert_no_imported_zpool_members
  for device in "${HYBRID_ALL_DEVICES[@]}"; do
    wipefs --all --force "$device"
  done
  udevadm settle
}

hybrid_setup_btrfs_stack() {
  log "hybrid topology: HDD RAID10 + mirrored dm-cache writeback"
  mdadm --create "$HYBRID_MD_HDD" --run --metadata=1.2 --level=10 \
    --raid-devices=8 --assume-clean "${HYBRID_HDDS[@]}"
  mdadm --create "$HYBRID_MD_HOT" --run --metadata=1.2 --level=1 \
    --raid-devices=2 --assume-clean "${HYBRID_HOT[@]}"
  mdadm --create "$HYBRID_MD_META" --run --metadata=1.2 --level=1 \
    --raid-devices=2 --assume-clean "${HYBRID_META[@]}"
  udevadm settle

  pvcreate -ff -y "$HYBRID_MD_HDD" "$HYBRID_MD_HOT" "$HYBRID_MD_META"
  vgcreate "$HYBRID_VG" "$HYBRID_MD_HDD" "$HYBRID_MD_HOT" "$HYBRID_MD_META"
  lvcreate -y -l 100%PVS -n origin "$HYBRID_VG" "$HYBRID_MD_HDD"
  lvcreate -y -l 100%PVS -n cache_data "$HYBRID_VG" "$HYBRID_MD_HOT"
  lvcreate -y -l 100%PVS -n cache_meta "$HYBRID_VG" "$HYBRID_MD_META"
  lvconvert -y --type cache-pool --poolmetadataspare n \
    --poolmetadata "$HYBRID_VG/cache_meta" "$HYBRID_VG/cache_data"
  lvconvert -y --type cache --cachepool "$HYBRID_VG/cache_data" \
    --cachemode writeback --cachepolicy smq "$HYBRID_VG/origin"
  DEVICES=("/dev/$HYBRID_VG/origin")
}

hybrid_btrfs_setup() {
  # The underlying HDD RAID10 and SSD mirrors provide the second copy.
  mkfs.btrfs -f -d single -m single "${DEVICES[0]}"
  mount -t btrfs -o noatime "${DEVICES[0]}" "$MNT"
  btrfs subvolume create "$MNT/data"
  DATA="$MNT/data"
}

hybrid_zfs_setup() {
  local vdevs=() i
  modprobe zfs
  for ((i = 0; i < ${#HYBRID_HDDS[@]}; i += 2)); do
    vdevs+=(mirror "${HYBRID_HDDS[i]}" "${HYBRID_HDDS[i + 1]}")
  done
  zpool create -f -O mountpoint="$MNT" -O compression=off -O atime=off \
    -o cachefile=none \
    "$HYBRID_ZPOOL" "${vdevs[@]}" \
    special mirror "${HYBRID_HOT[0]}" "${HYBRID_HOT[1]}" \
    cache "$HYBRID_READ_CACHE"
  zfs create -o special_small_blocks=0 "$HYBRID_ZPOOL/data"
  DATA="$MNT/data"
}

hybrid_zfs_drop_caches() {
  local args=() device
  zpool export "$HYBRID_ZPOOL"
  drop_caches
  for device in "${HYBRID_HDDS[@]}" "${HYBRID_HOT[@]}" "$HYBRID_READ_CACHE"; do
    args+=(-d "$device")
  done
  zpool import -o cachefile=none "${args[@]}" "$HYBRID_ZPOOL"
}

hybrid_bcachefs_setup() {
  local fmt i devlist
  modprobe bcachefs
  grep -qw bcachefs /proc/filesystems \
    || die "kernel has no bcachefs support"
  fmt=(bcachefs format -f --data_replicas=2 --metadata_replicas=2
    --foreground_target=hot --background_target=hdd
    --promote_target=readcache --metadata_target=hot)
  for i in "${!HYBRID_HDDS[@]}"; do
    fmt+=(--label="hdd.disk$i" "${HYBRID_HDDS[i]}")
  done
  for i in "${!HYBRID_HOT[@]}"; do
    fmt+=(--label="hot.ssd$i" "${HYBRID_HOT[i]}")
  done
  fmt+=(--label=readcache.ssd0 --durability=0 "$HYBRID_READ_CACHE")
  "${fmt[@]}"
  DEVICES=("${HYBRID_HDDS[@]}" "${HYBRID_HOT[@]}" "$HYBRID_READ_CACHE")
  devlist=$(IFS=:; echo "${DEVICES[*]}")
  mount -t bcachefs "$devlist" "$MNT"
  bcachefs subvolume create "$MNT/data"
  DATA="$MNT/data"
}

hybrid_bcachefs_mount() {
  local devlist
  devlist=$(IFS=:; echo "${DEVICES[*]}")
  mount -t bcachefs "$devlist" "$MNT"
}

hybrid_install_backend() {
  case "$FS" in
    btrfs)
      hybrid_setup_btrfs_stack
      fs_setup() { hybrid_btrfs_setup; }
      ;;
    zfs)
      POOL=$HYBRID_ZPOOL
      DEVICES=("${HYBRID_HDDS[@]}")
      fs_setup() { hybrid_zfs_setup; }
      fs_drop_caches() { hybrid_zfs_drop_caches; }
      ;;
    bcachefs)
      DEVICES=("${HYBRID_HDDS[@]}" "${HYBRID_HOT[@]}" "$HYBRID_READ_CACHE")
      fs_setup() { hybrid_bcachefs_setup; }
      bcachefs_mount() { hybrid_bcachefs_mount; }
      ;;
    *) die "unsupported hybrid filesystem: $FS" ;;
  esac
}

hybrid_capture_topology() {
  local suffix=${1:-hybrid}
  local prefix="$RESULTS_DIR/raw/$BENCH_ID-$suffix"
  lsblk -b -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS >"$prefix-lsblk.txt"
  case "$FS" in
    btrfs)
      mdadm --detail "$HYBRID_MD_HDD" >"$prefix-md-hdd.txt" 2>&1 || true
      mdadm --detail "$HYBRID_MD_HOT" >"$prefix-md-hot.txt" 2>&1 || true
      lvs -a -o+devices,cache_mode,cache_policy,cache_settings,cache_total_blocks,cache_used_blocks \
        "$HYBRID_VG" >"$prefix-lvm-cache.txt" 2>&1 || true
      ;;
    zfs)
      zpool status -P "$HYBRID_ZPOOL" >"$prefix-zpool-status.txt" 2>&1 || true
      zpool iostat -P -v "$HYBRID_ZPOOL" >"$prefix-zpool-iostat.txt" 2>&1 || true
      ;;
    bcachefs)
      bcachefs fs usage -a -h "$MNT" >"$prefix-fs-usage.txt" 2>&1 || true
      bcachefs show-super "${DEVICES[0]}" >"$prefix-device-super.txt" 2>&1 || true
      ;;
  esac
}

hybrid_prepare() {
  hybrid_load_roles
  hybrid_cleanup || die "failed to clean stale hybrid topology"
  hybrid_preflight_and_wipe
  hybrid_install_backend

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
  BENCH_SCENARIO=hybrid-tier-v1
  case "$FS" in
    btrfs) BENCH_TOPOLOGY=mdraid10-dmcache-writeback ;;
    zfs) BENCH_TOPOLOGY=mirrors-special-metadata-l2arc ;;
    bcachefs) BENCH_TOPOLOGY=native-foreground-background-promote ;;
  esac
  export BENCH_DEVICES BENCH_RESULT_DEVICES BENCH_RESULT_NDEV
  export BENCH_RESULT_DEVICE_SIZE_BYTES BENCH_SCENARIO BENCH_TOPOLOGY
}
