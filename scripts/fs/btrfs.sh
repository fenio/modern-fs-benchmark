# shellcheck shell=bash
# btrfs backend. Layout: raid1 data + metadata across all devices.

FS_REFLINK=1

fs_setup() {
  local profile=${LAYOUT:-raid1}
  if [ "$profile" = single ]; then
    mkfs.btrfs -f "${DEVICES[0]}"
  else
    mkfs.btrfs -f -d "$profile" -m "$profile" "${DEVICES[@]}"
  fi
  mount -o noatime "${DEVICES[0]}" "$MNT"
  btrfs subvolume create "$MNT/data"
  DATA="$MNT/data"
}

fs_snapshot() {
  btrfs subvolume snapshot -r "$DATA" "$MNT/$1" >/dev/null
}

fs_setup_compression() {
  # compress-force bypasses the compressibility heuristic; the property-based
  # approach left data uncompressed on 6.17 (ratio 1.0 in CI)
  mount -o "remount,compress-force=zstd" "$MNT"
  btrfs subvolume create "$1" >/dev/null
}

fs_compress_ratio() {
  # compsize TOTAL line: "TOTAL  43%  900M  2.0G  2.0G" — perc = disk/uncompressed
  local perc
  perc=$(compsize "$1" 2>/dev/null | awk '/^TOTAL/ {gsub("%","",$2); print $2}')
  if [ -n "$perc" ] && [ "$perc" -gt 0 ]; then
    awk "BEGIN{printf \"%.2f\", 100/$perc}"
  else
    echo null
  fi
}

# Simulate device loss: unmount, drop one member, remount degraded.
# Loop-device only — real hardware would need a SCSI/NVMe offline mechanism.
fs_degrade() {
  [ "${LAYOUT:-raid1}" != single ] || return 1
  umount "$MNT"
  if ! losetup -d "${DEVICES[1]}" 2>/dev/null; then
    mount -o noatime "${DEVICES[0]}" "$MNT"
    return 1
  fi
  mount -o degraded,noatime "${DEVICES[0]}" "$MNT"
}

fs_rebuild() {
  local devid
  devid=$(btrfs filesystem show "$MNT" \
    | awk '/devid/ && /MISSING|missing/ {for (i = 1; i <= NF; i++) if ($i == "devid") print $(i+1)}' \
    | head -1)
  btrfs replace start -B "${devid:-2}" "$SPARE_DEV" "$MNT"
}

fs_teardown() {
  umount "$MNT" 2>/dev/null || true
}

fs_version() {
  btrfs --version 2>/dev/null | head -1
}
