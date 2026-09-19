#!/usr/bin/env bash
# Destructively create the fixed hybrid-tier-v1 role partitions.
set -euo pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

readonly EXPECTED_CONFIRMATION=destroy-sas-hdd-hybrid-tier-disks
readonly HDD_MODEL=ST6000NM0095
readonly HDD_SIZE=6001175126016
readonly SSD_MODEL=HUSMM1640ASS200
readonly SSD_SIZE=400088457216
readonly HDD_SECTORS=268435456
readonly HOT_SECTORS=134217728
readonly META_SECTORS=8388608
readonly FORBIDDEN_OS_DISK=/dev/sda

hdds=(
  /dev/disk/by-id/wwn-0x5000c50094425a2b
  /dev/disk/by-id/wwn-0x5000c50094420143
  /dev/disk/by-id/wwn-0x5000c500944224af
  /dev/disk/by-id/wwn-0x5000c50094420323
  /dev/disk/by-id/wwn-0x5000c5009442212f
  /dev/disk/by-id/wwn-0x5000c5009442640f
  /dev/disk/by-id/wwn-0x5000c500944259f7
  /dev/disk/by-id/wwn-0x5000c50094422a7f
)
hot_ssds=(
  /dev/disk/by-id/wwn-0x5000cca04ec26e38
  /dev/disk/by-id/wwn-0x5000cca04ec25d84
)
read_cache_ssd=/dev/disk/by-id/wwn-0x5000cca04ec25e3c
devices=("${hdds[@]}" "${hot_ssds[@]}" "$read_cache_ssd")

check_only=0
case ${1:-} in
  --check) [[ $# -eq 1 ]] || { echo "usage: $0 [--check]" >&2; exit 2; }; check_only=1 ;;
  "") ;;
  *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

if (( ! check_only )); then
  [[ ${CONFIRM_DESTROY_SAS_HDD_HYBRID:-} == "$EXPECTED_CONFIRMATION" ]] \
    || { echo "refusing: set CONFIRM_DESTROY_SAS_HDD_HYBRID=$EXPECTED_CONFIRMATION" >&2; exit 2; }
  [[ $(id -u) -eq 0 ]] || { echo "must run as root" >&2; exit 2; }
  exec 9>/run/lock/modern-fs-benchmark.lock
  flock -n 9 \
    || { echo "another filesystem benchmark or provisioner is running" >&2; exit 75; }
fi

for command in findmnt lsblk swapon zpool readlink grep xargs wipefs sgdisk \
  partprobe udevadm blockdev smartctl flock; do
  command -v "$command" >/dev/null \
    || { echo "$command is required for provisioning" >&2; exit 2; }
done

root_source=$(findmnt -no SOURCE /)
mapfile -t root_chain < <(lsblk -snrpo NAME "$root_source")
((${#root_chain[@]} > 0)) || { echo "cannot resolve root device $root_source" >&2; exit 2; }
swap_state=$(swapon --show=NAME --noheadings) \
  || { echo "cannot query active swap devices" >&2; exit 2; }
swap_devices=()
[[ -z $swap_state ]] || mapfile -t swap_devices <<<"$swap_state"
zpool_names=$(zpool list -H -o name) \
  || { echo "cannot query imported ZFS pools" >&2; exit 2; }
zpool_state=
if [[ -n $zpool_names ]]; then
  zpool_state=$(zpool status -LP) \
    || { echo "cannot query imported ZFS pool devices" >&2; exit 2; }
fi

declare -A seen=()
for device in "${devices[@]}"; do
  resolved=$(readlink -f "$device")
  [[ -b $resolved ]] || { echo "$device is not a block device" >&2; exit 2; }
  [[ $resolved != "$FORBIDDEN_OS_DISK" ]] \
    || { echo "refusing permanently excluded OS disk $resolved" >&2; exit 2; }
  for root_device in "${root_chain[@]}"; do
    [[ $resolved != "$(readlink -f "$root_device")" ]] \
      || { echo "refusing root device $resolved" >&2; exit 2; }
  done
  [[ -z ${seen[$resolved]:-} ]] || { echo "duplicate disk $resolved" >&2; exit 2; }
  seen[$resolved]=1

  expected_model=$HDD_MODEL
  expected_size=$HDD_SIZE
  case "$device" in
    /dev/disk/by-id/wwn-0x5000cca*) expected_model=$SSD_MODEL; expected_size=$SSD_SIZE ;;
  esac
  [[ $(lsblk -ndo MODEL "$resolved" | xargs) == "$expected_model" ]] \
    || { echo "$resolved has unexpected model" >&2; exit 2; }
  [[ $(lsblk -bdno SIZE "$resolved" | xargs) -eq $expected_size ]] \
    || { echo "$resolved has unexpected size" >&2; exit 2; }
  smart=$(smartctl -a "$resolved") \
    || { echo "cannot read SMART data from $resolved" >&2; exit 2; }
  grep -q 'SMART Health Status: OK' <<<"$smart" \
    || { echo "$resolved does not report SMART health OK" >&2; exit 2; }
  grown=$(awk -F: '/Elements in grown defect list/ {gsub(/[[:space:]]/, "", $2); print $2}' <<<"$smart")
  [[ ${grown:-unknown} == 0 ]] \
    || { echo "$resolved has ${grown:-unknown} grown defects" >&2; exit 2; }
  if lsblk -nrpo MOUNTPOINTS "$resolved" | grep -q '[^[:space:]]'; then
    echo "$resolved or one of its partitions is mounted" >&2
    exit 2
  fi
  mapfile -t related_devices < <(lsblk -nrpo NAME "$resolved")
  for related in "${related_devices[@]}"; do
    node=${related##*/}
    compgen -G "/sys/class/block/$node/holders/*" >/dev/null \
      && { echo "$related has active block-device holders" >&2; exit 2; }
    for swap_device in "${swap_devices[@]}"; do
      [[ $(readlink -f "$swap_device") != "$related" ]] \
        || { echo "$related is active swap" >&2; exit 2; }
    done
  done
  if [[ -n $zpool_state ]] && grep -Fq "$resolved" <<<"$zpool_state"; then
    echo "$resolved is part of an imported ZFS pool" >&2
    exit 2
  fi
done

if (( check_only )); then
  echo "sas-hdd hybrid-tier storage preflight passed; no changes made"
  exit 0
fi

for i in "${!hdds[@]}"; do
  device=${hdds[i]}
  wipefs --all --force "$device"
  sgdisk --zap-all "$device"
  sgdisk --new="1:2048:$((2048 + HDD_SECTORS - 1))" \
    --typecode=1:8300 --change-name="1:fsbench-hybrid-hdd$i" "$device"
done

for i in "${!hot_ssds[@]}"; do
  device=${hot_ssds[i]}
  wipefs --all --force "$device"
  sgdisk --zap-all "$device"
  sgdisk --new="1:2048:$((2048 + HOT_SECTORS - 1))" \
    --typecode=1:8300 --change-name="1:fsbench-hybrid-hot$i" \
    --new="2:$((2048 + HOT_SECTORS)):$((2048 + HOT_SECTORS + META_SECTORS - 1))" \
    --typecode=2:8300 --change-name="2:fsbench-hybrid-meta$i" "$device"
done

wipefs --all --force "$read_cache_ssd"
sgdisk --zap-all "$read_cache_ssd"
sgdisk --new="1:2048:$((2048 + HOT_SECTORS - 1))" \
  --typecode=1:8300 --change-name=1:fsbench-hybrid-readcache "$read_cache_ssd"

partprobe "${devices[@]}"
udevadm settle
partitions=()
for device in "${hdds[@]}"; do partitions+=("${device}-part1"); done
for device in "${hot_ssds[@]}"; do
  partitions+=("${device}-part1" "${device}-part2")
done
partitions+=("${read_cache_ssd}-part1")
for partition in "${partitions[@]}"; do wipefs --all --force "$partition"; done

for device in "${hdds[@]}"; do
  [[ $(blockdev --getsize64 "${device}-part1") -eq 137438953472 ]]
done
for device in "${hot_ssds[@]}"; do
  [[ $(blockdev --getsize64 "${device}-part1") -eq 68719476736 ]]
  [[ $(blockdev --getsize64 "${device}-part2") -eq 4294967296 ]]
done
[[ $(blockdev --getsize64 "${read_cache_ssd}-part1") -eq 68719476736 ]]

echo "sas-hdd hybrid-tier role partitions are ready"
