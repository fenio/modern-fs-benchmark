#!/usr/bin/env bash
# Explicit maintenance for the dedicated SAS runner, never run by hosted CI.
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
[[ ${1:-} == --apply && $# == 1 && $EUID == 0 ]] || {
  echo "usage: sudo bash $0 --apply (dedicated SAS benchmark host only)" >&2
  exit 2
}
exec 9>/run/lock/modern-fs-benchmark.lock
flock -n 9 || { echo 'benchmark storage is busy; refusing MD maintenance' >&2; exit 75; }
read -r revision </opt/modern-fs-benchmark/REVISION
/usr/local/sbin/modern-fs-benchmark-run --revision "$revision" --capabilities \
  | grep -Fxq hardware-profile:sas-hdd

allowed=()
for wwn in 5000c50094426153 5000c5009441febb 5000c50094426003 \
  5000c50094425a03 5000c50094425f93; do
  device=$(readlink -e "/dev/disk/by-id/wwn-0x$wwn-part1")
  allowed+=("${device##*/}")
done

# Validate every candidate before stopping anything. Never stop active arrays
# or arrays containing devices outside this host's fixed benchmark inventory.
stale=()
stale_members=()
for md in /sys/class/block/md*; do
  [[ -d $md/md ]] || continue
  state=$(cat "$md/md/array_state")
  [[ $state == inactive || $state == clear ]] || {
    echo "${md##*/} is $state; refusing host-wide MD policy change" >&2; exit 1;
  }
  slaves=("$md"/slaves/*)
  [[ -e ${slaves[0]} ]] || continue
  for slave in "${slaves[@]}"; do
    owned=0
    for device in "${allowed[@]}"; do
      [[ ${slave##*/} != "$device" ]] || owned=1
    done
    ((owned)) || { echo "${md##*/} holds a non-benchmark device; refusing cleanup" >&2; exit 1; }
    mountpoints=$(lsblk -nrpo MOUNTPOINTS "/dev/${slave##*/}")
    [[ -z ${mountpoints//[[:space:]]/} ]] || {
      echo "${slave##*/} is mounted; refusing cleanup" >&2; exit 1;
    }
    stale_members+=("/dev/${slave##*/}")
  done
  stale+=("/dev/${md##*/}")
done
config=/etc/mdadm/mdadm.conf
if grep -Eq '^[[:space:]]*AUTO[[:space:]]' "$config" \
  && ! grep -Eq '^[[:space:]]*AUTO[[:space:]]+-all[[:space:]]*$' "$config"; then
  echo 'existing custom AUTO policy; review mdadm.conf manually' >&2
  exit 1
fi
for md in "${stale[@]}"; do
  mdadm --stop "$md"
done
udevadm settle
for device in "${stale_members[@]}"; do
  if mdadm --examine "$device" >/dev/null 2>&1; then
    mdadm --zero-superblock "$device"
  fi
done
if ! grep -Eq '^[[:space:]]*AUTO[[:space:]]+-all[[:space:]]*$' "$config"; then
  cp -a "$config" "$config.fsbench-backup-$(date -u +%Y%m%dT%H%M%SZ)"
  printf '\n# Dedicated benchmark host: arrays are created explicitly, not assembled at boot.\nAUTO -all\n' >>"$config"
fi
for unit in mdcheck_start.timer mdcheck_continue.timer \
  mdcheck_start.service mdcheck_continue.service; do
  systemctl mask --now "$unit"
done
update-initramfs -u -k all
echo 'SAS MD maintenance complete; explicit benchmark creation and scrubs remain enabled'
