#!/usr/bin/env bash
# Reduce the Btrfs RAID6 degraded-write EIO to disposable loop devices while
# varying preallocation, sync mode, prior allocation, and the missing member.
set -Eeuo pipefail

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
for command in btrfs filefrag fio findmnt jq losetup modprobe mount mountpoint \
  python3 timeout truncate umount; do
  command -v "$command" >/dev/null || die "missing command: $command"
done
modprobe btrfs
grep -qw btrfs /proc/filesystems || die "kernel has no btrfs support"

WORK_ROOT=${WORK_ROOT:-/var/tmp}
OUTPUT_DIR=${OUTPUT_DIR:-$PWD/btrfs-raid6-degraded-write-output}
DEVICE_SIZE=${DEVICE_SIZE:-16G}
PRELOAD_SIZE=${PRELOAD_SIZE:-0}
FALLOCATE_MODE=${FALLOCATE_MODE:-default}
SYNC_MODE=${SYNC_MODE:-fdatasync16}
MISSING_INDEX=${MISSING_INDEX:-1}
RUNTIME=${RUNTIME:-10}

case "$FALLOCATE_MODE" in default | none) ;; *) die "invalid FALLOCATE_MODE: $FALLOCATE_MODE" ;; esac
case "$SYNC_MODE" in fdatasync16 | end-fsync | none) ;; *) die "invalid SYNC_MODE: $SYNC_MODE" ;; esac
[[ $MISSING_INDEX =~ ^[0-3]$ ]] || die "MISSING_INDEX must be 0, 1, 2, or 3"

mkdir -p "$WORK_ROOT" "$OUTPUT_DIR"
WORK_DIR=$(mktemp -d "$WORK_ROOT/btrfs-raid6-degraded-write.XXXXXX")
MNT="$WORK_DIR/mnt"
DATA="$MNT/data"
TEST_FILE="$DATA/degraded-write.0.0"
mkdir -p "$MNT"
declare -a LOOPS=()

exec > >(tee -a "$OUTPUT_DIR/reproducer.log") 2>&1

cleanup() {
  set +e
  log "cleanup"
  if mountpoint -q "$MNT"; then
    timeout 30s umount "$MNT"
  fi
  if mountpoint -q "$MNT"; then
    log "mount is still busy; preserving $WORK_DIR and its loop devices"
  else
    local device
    for device in "${LOOPS[@]}"; do
      losetup -d "$device" 2>/dev/null || true
    done
    rm -rf "$WORK_DIR"
  fi
  chmod -R a+rX "$OUTPUT_DIR" 2>/dev/null || true
}
trap cleanup EXIT

capture_diagnostics() { # <label>
  local label=$1
  local prefix="$OUTPUT_DIR/$label"
  {
    printf '===== identity =====\n'
    date -u +%FT%TZ
    uname -a
    btrfs --version
    printf '\n===== mount =====\n'
    findmnt "$MNT"
    printf '\n===== filesystem show =====\n'
    timeout 15s btrfs filesystem show "$MNT"
    printf '\n===== filesystem usage =====\n'
    timeout 15s btrfs filesystem usage -T "$MNT"
    printf '\n===== filesystem df =====\n'
    timeout 15s btrfs filesystem df "$MNT"
    printf '\n===== device stats =====\n'
    timeout 15s btrfs device stats "$MNT"
    if [ -e "$TEST_FILE" ]; then
      printf '\n===== failed-file stat =====\n'
      stat "$TEST_FILE"
      printf '\n===== failed-file extents =====\n'
      filefrag -v "$TEST_FILE"
    fi
  } >"$prefix-btrfs.txt" 2>&1 || true
  dmesg --time-format iso --color=never >"$prefix-dmesg.txt" 2>&1 || true
}

log "kernel: $(uname -r)"
log "tools: $(btrfs --version)"
log "variant: preload=$PRELOAD_SIZE fallocate=$FALLOCATE_MODE sync=$SYNC_MODE missing-index=$MISSING_INDEX"

for i in 0 1 2 3; do
  truncate -s "$DEVICE_SIZE" "$WORK_DIR/dev$i.img"
  LOOPS+=("$(losetup --find --show "$WORK_DIR/dev$i.img")")
done
log "loops: ${LOOPS[*]}"

mkfs.btrfs -f -d raid6 -m raid1c3 "${LOOPS[@]}"
mount -t btrfs -o noatime "${LOOPS[0]}" "$MNT"
btrfs subvolume create "$DATA"

if [ "$PRELOAD_SIZE" != 0 ]; then
  log "preload $PRELOAD_SIZE before device loss"
  fio --output-format=json --output="$OUTPUT_DIR/fio-preload.json" \
    --name=preload --filename="$DATA/preload.dat" --rw=write --bs=1M \
    --size="$PRELOAD_SIZE" --end_fsync=1 --fallocate=none
fi

umount "$MNT"
MISSING_DEV=${LOOPS[$MISSING_INDEX]}
log "detach index $MISSING_INDEX ($MISSING_DEV)"
losetup -d "$MISSING_DEV"
for ((attempt = 0; attempt < 100; attempt++)); do
  losetup "$MISSING_DEV" >/dev/null 2>&1 || break
  sleep 0.1
done
if losetup "$MISSING_DEV" >/dev/null 2>&1; then
  die "loop device remained attached: $MISSING_DEV"
fi

MOUNT_DEV=
for i in 0 1 2 3; do
  if [ "$i" -ne "$MISSING_INDEX" ]; then
    MOUNT_DEV=${LOOPS[$i]}
    break
  fi
done
mount -t btrfs -o degraded,noatime "$MOUNT_DEV" "$MNT"
capture_diagnostics before
btrfs filesystem show "$MNT" | grep -q MISSING \
  || die "Btrfs remounted without a missing member"

fio_args=(
  --output-format=json
  --output="$OUTPUT_DIR/fio-degraded-write.json"
  --name=degraded-write
  --directory="$DATA"
  --rw=randwrite
  --bs=4k
  --size=1G
  --runtime="$RUNTIME"
  --time_based
  --randrepeat=1
)
[ "$FALLOCATE_MODE" = default ] || fio_args+=(--fallocate=none)
case "$SYNC_MODE" in
  fdatasync16) fio_args+=(--fdatasync=16) ;;
  end-fsync) fio_args+=(--end_fsync=1) ;;
  none) ;;
esac

log "run degraded random write"
if fio "${fio_args[@]}"; then
  FIO_RC=0
else
  FIO_RC=$?
fi

EXPLICIT_FDATASYNC_RC=-1
if [ "$SYNC_MODE" = none ] && [ -e "$TEST_FILE" ]; then
  log "run explicit fdatasync after unsynchronized fio"
  if python3 - "$TEST_FILE" <<'PY'
import os
import sys

fd = os.open(sys.argv[1], os.O_RDWR)
try:
    os.fdatasync(fd)
finally:
    os.close(fd)
PY
  then
    EXPLICIT_FDATASYNC_RC=0
  else
    EXPLICIT_FDATASYNC_RC=$?
  fi
fi

capture_diagnostics after
jq -n \
  --arg preload_size "$PRELOAD_SIZE" \
  --arg fallocate_mode "$FALLOCATE_MODE" \
  --arg sync_mode "$SYNC_MODE" \
  --argjson missing_index "$MISSING_INDEX" \
  --argjson fio_rc "$FIO_RC" \
  --argjson explicit_fdatasync_rc "$EXPLICIT_FDATASYNC_RC" \
  '{preload_size: $preload_size,
    fallocate_mode: $fallocate_mode,
    sync_mode: $sync_mode,
    missing_index: $missing_index,
    fio_rc: $fio_rc,
    explicit_fdatasync_rc: $explicit_fdatasync_rc,
    reproduced: ($fio_rc != 0 or $explicit_fdatasync_rc > 0)}' \
  >"$OUTPUT_DIR/outcome.json"

log "outcome: fio=$FIO_RC explicit-fdatasync=$EXPLICIT_FDATASYNC_RC"
