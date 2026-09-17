#!/usr/bin/env bash
# Destructively create the six fixed benchmark partitions for the sas-hdd
# profile. This script intentionally knows the selected disks by WWN.
set -euo pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

readonly EXPECTED_CONFIRMATION=destroy-sas-hdd-profile-disks
readonly EXPECTED_MODEL=ST6000NM0095
readonly EXPECTED_SIZE=6001175126016
readonly MEMBER_SECTORS=33554432
readonly ZFS_SINGLE_SECTORS=67108864
readonly FORBIDDEN_OS_DISK=/dev/sda

members=(
  /dev/disk/by-id/wwn-0x5000c50094426153
  /dev/disk/by-id/wwn-0x5000c5009441febb
  /dev/disk/by-id/wwn-0x5000c50094426003
  /dev/disk/by-id/wwn-0x5000c50094425a03
)
spare=/dev/disk/by-id/wwn-0x5000c50094425f93
zfs_single=/dev/disk/by-id/wwn-0x5000c500944259d3
devices=("${members[@]}" "$spare" "$zfs_single")

check_only=0
case ${1:-} in
  --check)
    [[ $# -eq 1 ]] || { echo "usage: $0 [--check]" >&2; exit 2; }
    check_only=1
    ;;
  "") ;;
  *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

if (( ! check_only )); then
  if [[ ${CONFIRM_DESTROY_SAS_HDD:-} != "$EXPECTED_CONFIRMATION" ]]; then
    echo "refusing: set CONFIRM_DESTROY_SAS_HDD=$EXPECTED_CONFIRMATION" >&2
    exit 2
  fi
  if [[ $(id -u) -ne 0 ]]; then
    echo "must run as root" >&2
    exit 2
  fi
fi

for required_command in findmnt lsblk swapon zpool readlink grep xargs \
  wipefs sgdisk partprobe udevadm blockdev; do
  command -v "$required_command" >/dev/null \
    || { echo "$required_command is required for provisioning" >&2; exit 2; }
done

root_source=$(findmnt -no SOURCE /)
mapfile -t root_chain < <(lsblk -snrpo NAME "$root_source")
((${#root_chain[@]} > 0)) || { echo "cannot resolve root device $root_source" >&2; exit 2; }
if ! swap_state=$(swapon --show=NAME --noheadings); then
  echo "cannot query active swap devices" >&2
  exit 2
fi
swap_devices=()
[[ -z $swap_state ]] || mapfile -t swap_devices <<<"$swap_state"

if ! zpool_names=$(zpool list -H -o name); then
  echo "cannot query imported ZFS pools" >&2
  exit 2
fi
zpool_state=
if [[ -n $zpool_names ]] && ! zpool_state=$(zpool status -LP); then
  echo "cannot query imported ZFS pool devices" >&2
  exit 2
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
  [[ $(lsblk -ndo MODEL "$resolved" | xargs) == "$EXPECTED_MODEL" ]] \
    || { echo "$resolved has unexpected model" >&2; exit 2; }
  [[ $(lsblk -bdno SIZE "$resolved" | xargs) -eq $EXPECTED_SIZE ]] \
    || { echo "$resolved has unexpected size" >&2; exit 2; }
  if lsblk -nrpo MOUNTPOINTS "$resolved" | grep -q '[^[:space:]]'; then
    echo "$resolved or one of its partitions is mounted" >&2
    exit 2
  fi
  mapfile -t related_devices < <(lsblk -nrpo NAME "$resolved")
  for related_device in "${related_devices[@]}"; do
    node=${related_device##*/}
    if compgen -G "/sys/class/block/$node/holders/*" >/dev/null; then
      echo "$related_device has active block-device holders" >&2
      exit 2
    fi
    for swap_device in "${swap_devices[@]}"; do
      [[ $(readlink -f "$swap_device") != "$related_device" ]] \
        || { echo "$related_device is active swap" >&2; exit 2; }
    done
  done
  if [[ -n $zpool_state ]] && grep -Fq "$resolved" <<<"$zpool_state"; then
    echo "$resolved is part of an imported ZFS pool" >&2
    exit 2
  fi
done

if (( check_only )); then
  echo "sas-hdd storage preflight passed; no changes made"
  exit 0
fi

for i in "${!members[@]}"; do
  device=${members[i]}
  wipefs --all --force "$device"
  sgdisk --zap-all "$device"
  sgdisk --new="1:2048:$((2048 + MEMBER_SECTORS - 1))" \
    --typecode=1:8300 --change-name="1:fsbench-sas-member$i" "$device"
done

wipefs --all --force "$spare"
sgdisk --zap-all "$spare"
sgdisk --new="1:2048:$((2048 + MEMBER_SECTORS - 1))" \
  --typecode=1:8300 --change-name=1:fsbench-sas-spare "$spare"

wipefs --all --force "$zfs_single"
sgdisk --zap-all "$zfs_single"
sgdisk --new="1:2048:$((2048 + ZFS_SINGLE_SECTORS - 1))" \
  --typecode=1:8300 --change-name=1:fsbench-sas-zfs-single "$zfs_single"

partprobe "${devices[@]}"
udevadm settle

for device in "${devices[@]}"; do
  wipefs --all --force "${device}-part1"
done

for device in "${members[@]}" "$spare"; do
  [[ $(blockdev --getsize64 "${device}-part1") -eq 17179869184 ]]
done
[[ $(blockdev --getsize64 "${zfs_single}-part1") -eq 34359738368 ]]

echo "sas-hdd benchmark partitions are ready"
