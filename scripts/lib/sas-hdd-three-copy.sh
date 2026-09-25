#!/usr/bin/env bash
# Repeatable drive-loss helpers for the isolated sas-hdd three-copy scenario.
# shellcheck disable=SC2034,SC2317,SC2329

THREE_COPY_PHYSICAL_MEMBERS=()
THREE_COPY_PHYSICAL_SPARES=()
THREE_COPY_MEMBER_NAMES=()
THREE_COPY_SPARE_NAMES=()
THREE_COPY_BTRFS_IDS=()
THREE_COPY_BCACHEFS_IDS=()
THREE_COPY_FAILED_MEMBERS=(0 0 0)
THREE_COPY_MAPPINGS_STARTED=0
THREE_COPY_FS_STARTED=0
THREE_COPY_MOUNT_DEVICE=
THREE_COPY_TOPOLOGY_ID=

three_copy_cleanup_stale() {
  local name pools
  if findmnt -Rrn "$MNT" >/dev/null 2>&1; then
    die "$MNT still has a mounted filesystem; refusing stale cleanup"
  fi
  [[ ! -e /dev/md/fsbench ]] \
    || die "/dev/md/fsbench already exists; refusing stale cleanup"
  if command -v zpool >/dev/null; then
    pools=$(zpool list -H -o name) \
      || die "failed to enumerate imported ZFS pools"
    if grep -Fxq fsbench <<<"$pools"; then
      die "ZFS pool fsbench is already imported; refusing stale cleanup"
    fi
  fi
  for name in fsbench-fd-member{0..2} fsbench-fd-spare{0..1}; do
    ! dmsetup info "$name" >/dev/null 2>&1 \
      || die "device-mapper target $name already exists; refusing stale cleanup"
  done
}

three_copy_create_mapping() {
  local name=$1 device=$2 sectors
  sectors=$(blockdev --getsz "$device")
  dmsetup create "$name" --uuid "fsbench-three-copy-v1-$name" \
    --table "0 $sectors linear $device 0"
}

three_copy_assert_mapping_owned() {
  local name=$1 uuid
  uuid=$(dmsetup info -c --noheadings -o uuid "$name" 2>/dev/null | tr -d ' ') \
    || return 1
  [[ $uuid == "fsbench-three-copy-v1-$name" ]]
}

three_copy_mapping_device() {
  local name=$1 i
  for i in "${!THREE_COPY_MEMBER_NAMES[@]}"; do
    if [[ ${THREE_COPY_MEMBER_NAMES[i]} == "$name" ]]; then
      printf '%s\n' "${THREE_COPY_PHYSICAL_MEMBERS[i]}"
      return
    fi
  done
  for i in "${!THREE_COPY_SPARE_NAMES[@]}"; do
    if [[ ${THREE_COPY_SPARE_NAMES[i]} == "$name" ]]; then
      printf '%s\n' "${THREE_COPY_PHYSICAL_SPARES[i]}"
      return
    fi
  done
  return 1
}

three_copy_assert_mapping_table() {
  local name=$1 allow_error=${2:-0} device sectors major_minor
  local start length target backing offset extra table
  three_copy_assert_mapping_owned "$name" || return
  device=$(three_copy_mapping_device "$name") || return
  sectors=$(blockdev --getsz "$device") || return
  table=$(dmsetup table "$name") || return
  read -r start length target backing offset extra <<<"$table"
  [[ $start == 0 && $length == "$sectors" && -z ${extra:-} ]] || return 1
  if [[ $target == error && $allow_error == 1 ]]; then
    return 0
  fi
  major_minor=$(lsblk -dnro MAJ:MIN "$device") || return
  [[ $target == linear && $backing == "$major_minor" && $offset == 0 ]]
}

three_copy_wrap_devices() {
  local i name
  [[ ${#DEVICES[@]} -eq 3 ]] || die "three-copy requires exactly three members"
  [[ ${#SPARE_DEVICES[@]} -eq 2 ]] || die "three-copy requires exactly two spares"
  THREE_COPY_PHYSICAL_MEMBERS=("${DEVICES[@]}")
  THREE_COPY_PHYSICAL_SPARES=("${SPARE_DEVICES[@]}")
  THREE_COPY_MEMBER_NAMES=(fsbench-fd-member0 fsbench-fd-member1 fsbench-fd-member2)
  THREE_COPY_SPARE_NAMES=(fsbench-fd-spare0 fsbench-fd-spare1)
  THREE_COPY_MAPPINGS_STARTED=1
  DEVICES=()
  SPARE_DEVICES=()
  for i in "${!THREE_COPY_PHYSICAL_MEMBERS[@]}"; do
    name=${THREE_COPY_MEMBER_NAMES[i]}
    three_copy_create_mapping "$name" "${THREE_COPY_PHYSICAL_MEMBERS[i]}"
    DEVICES+=("/dev/mapper/$name")
  done
  for i in "${!THREE_COPY_PHYSICAL_SPARES[@]}"; do
    name=${THREE_COPY_SPARE_NAMES[i]}
    three_copy_create_mapping "$name" "${THREE_COPY_PHYSICAL_SPARES[i]}"
    SPARE_DEVICES+=("/dev/mapper/$name")
  done
  SPARE_DEV=${SPARE_DEVICES[0]}
  udevadm settle
}

three_copy_reload_member() {
  local index=$1 target=$2 name device sectors table
  name=${THREE_COPY_MEMBER_NAMES[index]}
  three_copy_assert_mapping_owned "$name" \
    || { log "WARNING: refusing to reload unowned mapping $name"; return 1; }
  device=${THREE_COPY_PHYSICAL_MEMBERS[index]}
  sectors=$(blockdev --getsz "$device")
  case "$target" in
    error) table="0 $sectors error" ;;
    linear) table="0 $sectors linear $device 0" ;;
    *) log "WARNING: unknown device-mapper target: $target"; return 1 ;;
  esac
  dmsetup load "$name" --table "$table"
  if ! dmsetup suspend "$name"; then
    dmsetup clear "$name" 2>/dev/null || true
    return 1
  fi
  if ! dmsetup resume "$name"; then
    dmsetup resume "$name" 2>/dev/null || true
    return 1
  fi
  if [[ $target == linear ]]; then
    three_copy_assert_mapping_table "$name" \
      || { log "WARNING: mapping $name did not restore its expected backing"; return 1; }
  elif [[ $(dmsetup table "$name" | awk 'NR == 1 {print $3}') != error ]]; then
    log "WARNING: mapping $name did not switch to error"
    return 1
  fi
}

three_copy_restore_members() {
  local i
  for i in "${!THREE_COPY_PHYSICAL_MEMBERS[@]}"; do
    dmsetup info "${THREE_COPY_MEMBER_NAMES[i]}" >/dev/null 2>&1 || continue
    three_copy_reload_member "$i" linear || return
  done
  udevadm settle
}

three_copy_resume_mappings() {
  local name
  for name in "${THREE_COPY_MEMBER_NAMES[@]}" "${THREE_COPY_SPARE_NAMES[@]}"; do
    dmsetup info "$name" >/dev/null 2>&1 || continue
    three_copy_assert_mapping_table "$name" 1 || continue
    dmsetup resume "$name" 2>/dev/null || true
  done
}

benchmark_mount_started() {
  THREE_COPY_MOUNT_DEVICE=$(stat -Lc '%d' "$MNT")
  case "$FS" in
    ext4 | xfs)
      THREE_COPY_TOPOLOGY_ID=$(mdadm --detail /dev/md/fsbench \
        | awk '$1 == "UUID" {print $3; exit}')
      ;;
    zfs)
      THREE_COPY_TOPOLOGY_ID=$(zpool get -H -o value guid "$POOL")
      ;;
  esac
  if [[ $FS == ext4 || $FS == xfs || $FS == zfs ]]; then
    [[ -n $THREE_COPY_TOPOLOGY_ID ]] \
      || die "failed to capture the created $FS topology identity"
  fi
}

three_copy_assert_mount_owned() {
  local line source target fstype source_node md_node mount_output
  local mounts=()
  mountpoint -q "$MNT" || return 0
  mount_output=$(findmnt -Rrn -o TARGET,SOURCE,FSTYPE "$MNT") || return
  mapfile -t mounts <<<"$mount_output"
  case "$FS" in
    ext4 | xfs)
      ((${#mounts[@]} == 1)) || return 1
      read -r target source fstype <<<"${mounts[0]}"
      [[ $target == "$MNT" && $fstype == "$FS" ]] || return 1
      source_node=$(readlink -f "$source")
      md_node=$(readlink -f /dev/md/fsbench)
      [[ -n $source_node && $source_node == "$md_node" ]]
      ;;
    zfs)
      for line in "${mounts[@]}"; do
        read -r target source fstype <<<"$line"
        [[ $target == "$MNT" || $target == "$MNT/"* ]] || return 1
        [[ $fstype == zfs && ($source == fsbench || $source == fsbench/*) ]] \
          || return 1
      done
      ;;
    btrfs | bcachefs)
      [[ -n $THREE_COPY_MOUNT_DEVICE \
        && $(stat -Lc '%d' "$MNT") == "$THREE_COPY_MOUNT_DEVICE" ]]
      ;;
  esac
}

three_copy_assert_detached() {
  local name node holder pools
  if findmnt -Rrn "$MNT" >/dev/null 2>&1; then
    log "WARNING: $MNT remains mounted"
    return 1
  fi
  if [[ -e /dev/md/fsbench ]]; then
    log "WARNING: /dev/md/fsbench remains active"
    return 1
  fi
  if command -v zpool >/dev/null; then
    pools=$(zpool list -H -o name) \
      || { log "WARNING: failed to enumerate imported ZFS pools"; return 1; }
    if grep -Fxq fsbench <<<"$pools"; then
      log "WARNING: ZFS pool fsbench remains imported"
      return 1
    fi
  fi
  for name in "${THREE_COPY_MEMBER_NAMES[@]}" "${THREE_COPY_SPARE_NAMES[@]}"; do
    dmsetup info "$name" >/dev/null 2>&1 || continue
    node=$(readlink -f "/dev/mapper/$name")
    node=${node##*/}
    for holder in "/sys/class/block/$node/holders/"*; do
      [[ -e $holder ]] || continue
      log "WARNING: $name remains held by ${holder##*/}"
      return 1
    done
  done
}

three_copy_assert_topology_owned() {
  local md node slave source path pool_status topology_id found=0
  local allowed=" ${THREE_COPY_MEMBER_NAMES[*]} ${THREE_COPY_SPARE_NAMES[*]} "
  three_copy_assert_mount_owned \
    || { log "WARNING: $MNT contains an unowned mount"; return 1; }
  case "$FS" in
    ext4 | xfs)
      [[ -e /dev/md/fsbench ]] || return 0
      topology_id=$(mdadm --detail /dev/md/fsbench 2>/dev/null \
        | awk '$1 == "UUID" {print $3; exit}')
      [[ -n $THREE_COPY_TOPOLOGY_ID && $topology_id == "$THREE_COPY_TOPOLOGY_ID" ]] \
        || { log "WARNING: /dev/md/fsbench UUID does not match this run"; return 1; }
      md=$(readlink -f /dev/md/fsbench)
      md=${md##*/}
      for slave in "/sys/class/block/$md/slaves/"*; do
        [[ -e $slave ]] || continue
        found=1
        if [[ -r $slave/dm/name ]]; then
          read -r node <"$slave/dm/name"
        else
          node=${slave##*/}
        fi
        [[ $allowed == *" $node "* ]] \
          || { log "WARNING: /dev/md/fsbench contains foreign member $node"; return 1; }
        three_copy_assert_mapping_table "$node" \
          || { log "WARNING: /dev/md/fsbench member $node has an unexpected table"; return 1; }
      done
      ((found == 1))
      ;;
    zfs)
      zpool list -H -o name fsbench >/dev/null 2>&1 || return 0
      topology_id=$(zpool get -H -o value guid fsbench 2>/dev/null) \
        || { log "WARNING: failed to read ZFS pool fsbench GUID"; return 1; }
      [[ -n $THREE_COPY_TOPOLOGY_ID && $topology_id == "$THREE_COPY_TOPOLOGY_ID" ]] \
        || { log "WARNING: ZFS pool fsbench GUID does not match this run"; return 1; }
      pool_status=$(zpool status -LP fsbench) \
        || { log "WARNING: failed to inspect ZFS pool fsbench"; return 1; }
      while IFS= read -r path; do
        [[ -n $path ]] || continue
        case "$path" in
          fsbench | mirror-[0-9]* | replacing-[0-9]* | spares | spare-[0-9]*)
            continue
            ;;
          /*) ;;
          *)
            log "WARNING: ZFS pool fsbench contains unrecognized leaf $path"
            return 1
            ;;
        esac
        found=1
        node=$(readlink -f "$path")
        node=${node##*/}
        if [[ -r /sys/class/block/$node/dm/name ]]; then
          read -r node <"/sys/class/block/$node/dm/name"
        fi
        [[ $allowed == *" $node "* ]] \
          || { log "WARNING: ZFS pool fsbench contains foreign member $path"; return 1; }
        three_copy_assert_mapping_table "$node" \
          || { log "WARNING: ZFS member $path has an unexpected table"; return 1; }
      done < <(awk '
        /^[[:space:]]*NAME[[:space:]]+STATE/ { in_config = 1; next }
        in_config && /^[[:space:]]*$/ { exit }
        in_config { print $1 }
      ' <<<"$pool_status")
      ((found == 1))
      ;;
    btrfs | bcachefs)
      source=$(findmnt -rn -o SOURCE --target "$MNT" 2>/dev/null || true)
      [[ -z $source ]] && return 0
      [[ -n $THREE_COPY_MOUNT_DEVICE \
        && $(stat -Lc '%d' "$MNT") == "$THREE_COPY_MOUNT_DEVICE" ]] \
        || { log "WARNING: $MNT is backed by an unowned filesystem"; return 1; }
      ;;
  esac
}

three_copy_cold_cache() {
  local i args=()
  if [[ $FS == zfs ]]; then
    zpool export "$POOL" || return
    echo 3 >/proc/sys/vm/drop_caches
    for i in "${!DEVICES[@]}"; do
      [[ ${THREE_COPY_FAILED_MEMBERS[i]} == 1 ]] || args+=(-d "${DEVICES[i]}")
    done
    zpool import -l "${args[@]}" "$POOL"
  else
    sync || true
    echo 3 >/proc/sys/vm/drop_caches
  fi
}

three_copy_capture_bcachefs_ids() {
  local device id
  THREE_COPY_BCACHEFS_IDS=()
  [[ $FS == bcachefs ]] || return 0
  for device in "${DEVICES[@]}"; do
    id=$(bcachefs show-super "$device" \
      | awk -F: '/^Device index:/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')
    [[ $id =~ ^[0-9]+$ ]] || die "cannot determine bcachefs index for $device"
    THREE_COPY_BCACHEFS_IDS+=("$id")
  done
}

three_copy_capture_btrfs_ids() {
  local device id path candidate
  THREE_COPY_BTRFS_IDS=()
  [[ $FS == btrfs ]] || return 0
  for device in "${DEVICES[@]}"; do
    id=
    while read -r candidate path; do
      if [[ $(readlink -f "$path") == "$(readlink -f "$device")" ]]; then
        id=$candidate
        break
      fi
    done < <(btrfs filesystem show "$MNT" \
      | awk '$1 == "devid" {for (i = 1; i <= NF; i++) if ($i == "path") print $2, $(i+1)}')
    [[ $id =~ ^[0-9]+$ ]] || die "cannot determine Btrfs device ID for $device"
    THREE_COPY_BTRFS_IDS+=("$id")
  done
}

three_copy_wait_bcachefs_reconcile() {
  local prefix="$RESULTS_DIR/raw/$BENCH_ID-$1-reconcile"
  bcachefs reconcile wait "$MNT" >"$prefix-wait.txt" 2>&1 || return
  bcachefs reconcile status "$MNT" >"$prefix-status.txt" 2>&1 || return
}

three_copy_fail_member() {
  local index=$1 device=${DEVICES[$1]}
  sync || true
  three_copy_reload_member "$index" error
  if dd if="$device" of=/dev/null bs=4096 count=1 iflag=direct status=none \
    2>/dev/null; then
    die "$device remained readable after dm-error activation"
  fi
  THREE_COPY_FAILED_MEMBERS[index]=1
  case "$FS" in
    ext4 | xfs)
      mdadm --fail /dev/md/fsbench "$device"
      mdadm --remove /dev/md/fsbench "$device"
      ;;
    zfs | btrfs | bcachefs) ;;
  esac
}

three_copy_rebuild_one() {
  case "$FS" in
    ext4 | xfs)
      mdadm --add /dev/md/fsbench "${SPARE_DEVICES[0]}"
      layered_md_wait_idle
      ;;
    btrfs)
      btrfs replace start -B "${THREE_COPY_BTRFS_IDS[1]}" "${SPARE_DEVICES[0]}" "$MNT"
      ;;
    zfs)
      zpool replace "$POOL" "${DEVICES[1]}" "${SPARE_DEVICES[0]}"
      zpool wait -t resilver "$POOL"
      ;;
    bcachefs)
      bcachefs device add "$MNT" "${SPARE_DEVICES[0]}"
      bcachefs device remove "${THREE_COPY_BCACHEFS_IDS[1]}" "$MNT"
      three_copy_wait_bcachefs_reconcile single-rebuild
      ;;
  esac
  DEVICES[1]=${SPARE_DEVICES[0]}
  THREE_COPY_FAILED_MEMBERS[1]=0
}

three_copy_rebuild_two() {
  case "$FS" in
    ext4 | xfs)
      mdadm --add /dev/md/fsbench "${SPARE_DEVICES[0]}"
      mdadm --add /dev/md/fsbench "${SPARE_DEVICES[1]}"
      layered_md_wait_idle
      ;;
    btrfs)
      btrfs replace start -B "${THREE_COPY_BTRFS_IDS[1]}" "${SPARE_DEVICES[0]}" "$MNT"
      btrfs replace start -B "${THREE_COPY_BTRFS_IDS[2]}" "${SPARE_DEVICES[1]}" "$MNT"
      ;;
    zfs)
      zpool replace "$POOL" "${DEVICES[1]}" "${SPARE_DEVICES[0]}"
      zpool replace "$POOL" "${DEVICES[2]}" "${SPARE_DEVICES[1]}"
      zpool wait -t resilver "$POOL"
      ;;
    bcachefs)
      bcachefs device add "$MNT" "${SPARE_DEVICES[0]}"
      bcachefs device add "$MNT" "${SPARE_DEVICES[1]}"
      bcachefs device remove "${THREE_COPY_BCACHEFS_IDS[1]}" "$MNT"
      bcachefs device remove "${THREE_COPY_BCACHEFS_IDS[2]}" "$MNT"
      three_copy_wait_bcachefs_reconcile double-rebuild
      ;;
  esac
  DEVICES[1]=${SPARE_DEVICES[0]}
  DEVICES[2]=${SPARE_DEVICES[1]}
  THREE_COPY_FAILED_MEMBERS[1]=0
  THREE_COPY_FAILED_MEMBERS[2]=0
}

three_copy_probe_io() {
  local suffix=$1 file=$2 write_var=$3 read_var=$4 hash_var=$5 out value write_file
  write_file="$DATA/$suffix-write.dat"
  printf -v "$write_var" '%s' null
  printf -v "$read_var" '%s' null
  printf -v "$hash_var" '%s' ''
  if out=$(fio_json "$suffix-randwrite" --filename="$write_file" --rw=randwrite \
    --bs=4k --size=256M --runtime="$RUNTIME" --time_based --fdatasync=16); then
    if value=$(jq -er \
      'select(all(.jobs[]; .error == 0)) | .jobs[0].write.iops | select(. > 0)' \
      "$out"); then
      printf -v "$write_var" '%s' "$value"
      printf -v "$hash_var" '%s' "$(md5sum "$write_file" | cut -d' ' -f1)"
    fi
  fi
  three_copy_cold_cache
  if out=$(fio_json "$suffix-randread" --filename="$file" --rw=randread \
    --bs=4k --size="$READ_SIZE" --runtime="$RUNTIME" --time_based); then
    if value=$(jq -er \
      'select(all(.jobs[]; .error == 0)) | .jobs[0].read.iops | select(. > 0)' \
      "$out"); then
      printf -v "$read_var" '%s' "$value"
    fi
  fi
}

three_copy_phase_single_loss() {
  local before after write_after t0 single_write_hash
  DEG_WRITE_IOPS=null
  DEG_READ_IOPS=null
  REBUILD_S=null
  SINGLE_LOSS_DATA_INTACT=false
  POST_SINGLE_REBUILD_DATA_INTACT=false
  before=$(md5sum "$DATA/read.dat" | cut -d' ' -f1)
  three_copy_capture_btrfs_ids
  three_copy_capture_bcachefs_ids
  log "phase: one hard member loss"
  three_copy_fail_member 1
  three_copy_cold_cache
  three_copy_probe_io single-loss "$DATA/read.dat" \
    DEG_WRITE_IOPS DEG_READ_IOPS single_write_hash
  after=$(md5sum "$DATA/read.dat" 2>/dev/null | cut -d' ' -f1 || true)
  [[ -n $after && $after == "$before" ]] && SINGLE_LOSS_DATA_INTACT=true

  log "phase: rebuild after one member loss"
  t0=$(now_ms)
  three_copy_rebuild_one
  REBUILD_S=$(( ($(now_ms) - t0) / 1000 ))
  three_copy_cold_cache
  after=$(md5sum "$DATA/read.dat" 2>/dev/null | cut -d' ' -f1 || true)
  write_after=$(md5sum "$DATA/single-loss-write.dat" 2>/dev/null | cut -d' ' -f1 || true)
  [[ -n $after && $after == "$before" && -n $single_write_hash \
    && $write_after == "$single_write_hash" ]] && POST_SINGLE_REBUILD_DATA_INTACT=true
  [[ $SINGLE_LOSS_DATA_INTACT == true && $DEG_WRITE_IOPS != null \
    && $DEG_READ_IOPS != null && $POST_SINGLE_REBUILD_DATA_INTACT == true ]] \
    || die "$FS/$LAYOUT did not preserve data through one member loss and rebuild"
}

three_copy_prepare_fresh_double_loss() {
  local name
  three_copy_assert_topology_owned \
    || die "refusing to reset an unowned one-loss filesystem"
  fs_teardown || die "failed to tear down the one-loss filesystem"
  three_copy_assert_detached \
    || die "failed to detach the one-loss filesystem before reformatting"
  THREE_COPY_FS_STARTED=0
  THREE_COPY_MOUNT_DEVICE=
  DEVICES=()
  for name in "${THREE_COPY_MEMBER_NAMES[@]}"; do
    DEVICES+=("/dev/mapper/$name")
  done
  SPARE_DEVICES=()
  for name in "${THREE_COPY_SPARE_NAMES[@]}"; do
    SPARE_DEVICES+=("/dev/mapper/$name")
  done
  SPARE_DEV=${SPARE_DEVICES[0]}
  THREE_COPY_FAILED_MEMBERS=(0 0 0)
  three_copy_restore_members
  three_copy_assert_detached \
    || die "restored mappings are not detached before reformatting"
  three_copy_wipe_owned_mappings \
    || die "failed to clear the owned mappings before reformatting"
  THREE_COPY_FS_STARTED=1
  fs_setup
}

three_copy_final_scrub() {
  local log_file="$RESULTS_DIR/raw/$BENCH_ID-post-double-scrub.log"
  local counts out status
  case "$FS" in
    ext4 | xfs)
      counts=$(fs_scrub 2>"$log_file") || return
      [[ $counts =~ ^[0-9]+[[:space:]][0-9]+$ && ${counts%% *} == 0 ]] || return 1
      ;;
    btrfs)
      out=$(btrfs scrub start -B "$MNT" 2>&1) || return
      status=$(btrfs scrub status -R "$MNT" 2>&1) || return
      printf '%s\n%s\n' "$out" "$status" >"$log_file"
      grep -q 'Status:[[:space:]]*finished' <<<"$status" || return 1
      grep -q 'Error summary:[[:space:]]*no errors found' <<<"$status" || return 1
      btrfs device stats -c "$MNT" >/dev/null 2>&1 || return
      counts='0 0'
      ;;
    zfs)
      counts=$(fs_scrub 2>"$log_file") || return
      [[ $counts =~ ^[0-9]+[[:space:]][0-9]+$ ]] || return 1
      zpool status "$POOL" | grep -q 'with 0 errors' || return 1
      ;;
    bcachefs)
      out=$(bcachefs scrub "$MNT" 2>&1) || return
      printf '%s\n' "$out" >"$log_file"
      grep -qiE 'uncorrectable|unrepairable|data[[:space:]]+lost|fatal|aborted|cancelled' \
        <<<"$out" && return 1
      bcachefs fs usage "$MNT" >/dev/null || return
      counts='0 0'
      ;;
  esac
  printf '%s\n' "$counts"
}

three_copy_phase_double_loss() {
  local probe="$DATA/failure-domain.dat" before after write_after t0 counts
  local double_write_hash expected=true
  DOUBLE_LOSS_MOUNTED=false
  DOUBLE_LOSS_DATA_INTACT=false
  DOUBLE_LOSS_WRITE_IOPS=null
  DOUBLE_LOSS_READ_IOPS=null
  DOUBLE_REBUILD_S=null
  POST_DOUBLE_REBUILD_DATA_INTACT=null
  POST_DOUBLE_SCRUB_S=null
  POST_DOUBLE_SCRUB_OK=null
  [[ $FS == btrfs && $LAYOUT == raid1 ]] && expected=false

  log "phase: fresh two-member-loss probe"
  three_copy_prepare_fresh_double_loss
  fio --name=failure-domain-prep --filename="$probe" --rw=write --bs=1M \
    --size="$READ_SIZE" --end_fsync=1 --output=/dev/null
  before=$(md5sum "$probe" | cut -d' ' -f1)
  three_copy_capture_btrfs_ids
  three_copy_capture_bcachefs_ids
  three_copy_fail_member 1
  three_copy_fail_member 2
  mountpoint -q "$MNT" && DOUBLE_LOSS_MOUNTED=true
  three_copy_cold_cache
  after=$(md5sum "$probe" 2>/dev/null | cut -d' ' -f1 || true)
  [[ -n $after && $after == "$before" ]] && DOUBLE_LOSS_DATA_INTACT=true
  three_copy_probe_io double-loss "$probe" \
    DOUBLE_LOSS_WRITE_IOPS DOUBLE_LOSS_READ_IOPS double_write_hash

  if [[ $expected == true ]]; then
    log "phase: rebuild after two member losses"
    t0=$(now_ms)
    three_copy_rebuild_two
    DOUBLE_REBUILD_S=$(( ($(now_ms) - t0) / 1000 ))
    three_copy_cold_cache
    POST_DOUBLE_REBUILD_DATA_INTACT=false
    after=$(md5sum "$probe" 2>/dev/null | cut -d' ' -f1 || true)
    write_after=$(md5sum "$DATA/double-loss-write.dat" 2>/dev/null | cut -d' ' -f1 || true)
    [[ -n $after && $after == "$before" && -n $double_write_hash \
      && $write_after == "$double_write_hash" ]] && POST_DOUBLE_REBUILD_DATA_INTACT=true
    t0=$(now_ms)
    if counts=$(three_copy_final_scrub); then
      POST_DOUBLE_SCRUB_S=$(( ($(now_ms) - t0) / 1000 ))
      POST_DOUBLE_SCRUB_OK=true
      printf '%s\n' "$counts" \
        >"$RESULTS_DIR/raw/$BENCH_ID-post-double-scrub-counts.txt"
    else
      POST_DOUBLE_SCRUB_OK=false
    fi
    [[ $DOUBLE_LOSS_MOUNTED == true && $DOUBLE_LOSS_DATA_INTACT == true \
      && $DOUBLE_LOSS_WRITE_IOPS != null && $DOUBLE_LOSS_READ_IOPS != null \
      && $POST_DOUBLE_REBUILD_DATA_INTACT == true && $POST_DOUBLE_SCRUB_OK == true ]] \
      || die "$FS/$LAYOUT did not survive and recover from two member losses"
  else
    # The two-copy control is expected to lose access after two failures. Bring
    # its paths back only so teardown can release the filesystem cleanly.
    three_copy_restore_members
    THREE_COPY_FAILED_MEMBERS=(0 0 0)
    sync || true
  fi
}

three_copy_extend_result() {
  local tmp="$RESULT_FILE.tmp"
  jq \
    --argjson single_loss_data_intact "$SINGLE_LOSS_DATA_INTACT" \
    --argjson post_single_rebuild_data_intact "$POST_SINGLE_REBUILD_DATA_INTACT" \
    --argjson double_loss_mounted "$DOUBLE_LOSS_MOUNTED" \
    --argjson double_loss_data_intact "$DOUBLE_LOSS_DATA_INTACT" \
    --argjson double_loss_write_iops "$DOUBLE_LOSS_WRITE_IOPS" \
    --argjson double_loss_read_iops "$DOUBLE_LOSS_READ_IOPS" \
    --argjson double_rebuild_s "$DOUBLE_REBUILD_S" \
    --argjson post_double_rebuild_data_intact "$POST_DOUBLE_REBUILD_DATA_INTACT" \
    --argjson post_double_scrub_s "$POST_DOUBLE_SCRUB_S" \
    --argjson post_double_scrub_ok "$POST_DOUBLE_SCRUB_OK" \
    '.results += {
      single_loss_data_intact: $single_loss_data_intact,
      post_single_rebuild_data_intact: $post_single_rebuild_data_intact,
      double_loss_mounted: $double_loss_mounted,
      double_loss_data_intact: $double_loss_data_intact,
      double_loss_randwrite_iops: $double_loss_write_iops,
      double_loss_randread_iops: $double_loss_read_iops,
      double_rebuild_s: $double_rebuild_s,
      post_double_rebuild_data_intact: $post_double_rebuild_data_intact,
      post_double_scrub_s: $post_double_scrub_s,
      post_double_scrub_ok: $post_double_scrub_ok
    }' "$RESULT_FILE" >"$tmp"
  mv "$tmp" "$RESULT_FILE"
  python3 "$SCRIPT_DIR/validate-result.py" "$RESULT_FILE"
}

three_copy_capture_topology() {
  local prefix="$RESULTS_DIR/raw/$BENCH_ID-three-copy" device
  lsblk -b -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS >"$prefix-lsblk.txt" \
    || return
  dmsetup table >"$prefix-dm-table.txt" || return
  case "$FS" in
    ext4 | xfs)
      mdadm --detail /dev/md/fsbench >"$prefix-mdadm.txt" 2>&1 || return
      grep -Eq 'Active Devices[[:space:]]*:[[:space:]]*3$' "$prefix-mdadm.txt" \
        || return
      grep -Eq 'Failed Devices[[:space:]]*:[[:space:]]*0$' "$prefix-mdadm.txt" \
        || return
      ;;
    btrfs)
      {
        btrfs filesystem show "$MNT"
        btrfs device stats "$MNT"
      } >"$prefix-btrfs.txt" 2>&1 || return
      grep -q 'Total devices 3 ' "$prefix-btrfs.txt" || return
      ! grep -qi missing "$prefix-btrfs.txt" || return
      if [[ $LAYOUT != raid1 ]]; then
        btrfs device stats -c "$MNT" >/dev/null 2>&1 || return
      fi
      ;;
    zfs)
      zpool status -P "$POOL" >"$prefix-zpool.txt" 2>&1 || return
      grep -Eq 'state:[[:space:]]+ONLINE' "$prefix-zpool.txt" || return
      ! grep -Eq 'DEGRADED|FAULTED|OFFLINE|REMOVED|UNAVAIL' "$prefix-zpool.txt" \
        || return
      for device in "${DEVICES[@]}"; do
        grep -Fq "$device" "$prefix-zpool.txt" \
          || grep -Fq "$(readlink -f "$device")" "$prefix-zpool.txt" \
          || return
      done
      ;;
    bcachefs)
      {
        bcachefs fs usage "$MNT"
        bcachefs reconcile status "$MNT"
      } >"$prefix-bcachefs.txt" 2>&1 || return
      for device in "${DEVICES[@]}"; do
        bcachefs show-super "$device" >/dev/null || return
      done
      ;;
  esac
}

three_copy_assert_mappings_unused() {
  local name node physical physical_node holder expected_holder mounts open_count
  local identity mapper_identity physical_identity swap_device imported_pool pool_device
  local swap_devices pools pool_status zfs_identities=" "
  swap_devices=$(swapon --show=NAME --noheadings) \
    || { log "WARNING: failed to enumerate active swap"; return 1; }
  if command -v zpool >/dev/null; then
    pools=$(zpool list -H -o name) \
      || { log "WARNING: failed to enumerate imported ZFS pools"; return 1; }
    while IFS= read -r imported_pool; do
      [[ -n $imported_pool ]] || continue
      pool_status=$(zpool status -LP "$imported_pool") \
        || { log "WARNING: failed to inspect ZFS pool $imported_pool"; return 1; }
      while IFS= read -r pool_device; do
        [[ -b $pool_device ]] || continue
        identity=$(stat -Lc '%t:%T' -- "$pool_device") || return
        zfs_identities+="$identity "
      done < <(awk '$1 ~ /^\/dev\// {print $1}' <<<"$pool_status")
    done <<<"$pools"
  fi
  for name in "${THREE_COPY_MEMBER_NAMES[@]}" "${THREE_COPY_SPARE_NAMES[@]}"; do
    dmsetup info "$name" >/dev/null 2>&1 || continue
    three_copy_assert_mapping_table "$name" \
      || { log "WARNING: mapping $name has an unexpected backing device"; return 1; }
    node="/dev/mapper/$name"
    physical=$(three_copy_mapping_device "$name") || return
    for identity in "$node" "$physical"; do
      mounts=$(lsblk -nrpo MOUNTPOINTS "$identity") \
        || { log "WARNING: failed to enumerate mounts for $identity"; return 1; }
      [[ -z ${mounts//[[:space:]]/} ]] \
        || { log "WARNING: $identity is mounted"; return 1; }
    done
    mapper_identity=$(stat -Lc '%t:%T' -- "$node") || return
    physical_identity=$(stat -Lc '%t:%T' -- "$physical") || return
    while IFS= read -r swap_device; do
      [[ -n $swap_device ]] || continue
      [[ -e $swap_device ]] \
        || { log "WARNING: cannot inspect active swap $swap_device"; return 1; }
      identity=$(stat -Lc '%t:%T' -- "$swap_device") || return
      [[ $identity != "$mapper_identity" && $identity != "$physical_identity" ]] \
        || { log "WARNING: $node or its backing device is active swap"; return 1; }
    done <<<"$swap_devices"
    [[ $zfs_identities != *" $mapper_identity "* \
      && $zfs_identities != *" $physical_identity "* ]] \
      || { log "WARNING: $node or its backing device is an imported ZFS member"; return 1; }
    node=$(readlink -f "$node")
    node=${node##*/}
    for holder in "/sys/class/block/$node/holders/"*; do
      [[ -e $holder ]] || continue
      log "WARNING: $name is held by ${holder##*/}"
      return 1
    done
    physical_node=$(readlink -f "$physical")
    physical_node=${physical_node##*/}
    expected_holder=$node
    for holder in "/sys/class/block/$physical_node/holders/"*; do
      [[ -e $holder ]] || continue
      [[ ${holder##*/} == "$expected_holder" ]] \
        || { log "WARNING: $physical has foreign holder ${holder##*/}"; return 1; }
    done
    open_count=$(dmsetup info -c --noheadings -o open "$name" | tr -d ' ') \
      || return
    [[ $open_count == 0 ]] \
      || { log "WARNING: $name has $open_count open reference(s)"; return 1; }
  done
}

three_copy_wipe_owned_mappings() {
  local name
  for name in "${THREE_COPY_MEMBER_NAMES[@]}" "${THREE_COPY_SPARE_NAMES[@]}"; do
    dmsetup info "$name" >/dev/null 2>&1 || continue
    three_copy_assert_mappings_unused || return
    three_copy_assert_mapping_table "$name" || return
    wipefs --lock=yes --all --force "/dev/mapper/$name" || return
    udevadm settle || return
  done
}

three_copy_remove_mappings() {
  local i name uuid failed=0
  for ((i = ${#THREE_COPY_SPARE_NAMES[@]} - 1; i >= 0; i--)); do
    name=${THREE_COPY_SPARE_NAMES[i]}
    dmsetup info "$name" >/dev/null 2>&1 || continue
    uuid=$(dmsetup info -c --noheadings -o uuid "$name" | tr -d ' ')
    [[ $uuid == "fsbench-three-copy-v1-$name" ]] \
      || { log "WARNING: refusing to remove foreign mapping $name"; failed=1; continue; }
    three_copy_assert_mapping_table "$name" \
      || { log "WARNING: refusing to remove retargeted mapping $name"; failed=1; continue; }
    dmsetup remove --retry "$name" 2>/dev/null || failed=1
  done
  for ((i = ${#THREE_COPY_MEMBER_NAMES[@]} - 1; i >= 0; i--)); do
    name=${THREE_COPY_MEMBER_NAMES[i]}
    dmsetup info "$name" >/dev/null 2>&1 || continue
    uuid=$(dmsetup info -c --noheadings -o uuid "$name" | tr -d ' ')
    [[ $uuid == "fsbench-three-copy-v1-$name" ]] \
      || { log "WARNING: refusing to remove foreign mapping $name"; failed=1; continue; }
    three_copy_assert_mapping_table "$name" \
      || { log "WARNING: refusing to remove retargeted mapping $name"; failed=1; continue; }
    dmsetup remove --retry "$name" 2>/dev/null || failed=1
  done
  ((failed == 0))
}
