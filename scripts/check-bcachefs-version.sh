#!/usr/bin/env bash
# Debian/Ubuntu hardware preflight and explicit idle-host maintenance.
# --check is called with the managed runner's storage lock already held.
set -euo pipefail

case "${1:-}" in
  --check) ;;
  --upgrade)
    exec 9>/run/lock/modern-fs-benchmark.lock
    flock -n 9 || {
      echo 'benchmark storage is busy; refusing bcachefs upgrade' >&2
      exit 75
    }
    ;;
  *) echo "usage: $0 <--check|--upgrade>" >&2; exit 2 ;;
esac

# Never trust yesterday's cached candidate. Fail on any repository error,
# rather than silently accepting stale indexes after a partial update.
apt-get update -qq -o APT::Update::Error-Mode=any
if [[ $1 == --upgrade ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y bcachefs-tools bcachefs-kernel-dkms "linux-headers-$(uname -r)"
fi

kernel_version=
for package in bcachefs-tools bcachefs-kernel-dkms; do
  candidate=$(apt-cache policy "$package" | awk '/Candidate:/ {print $2}')
  [[ -n $candidate && $candidate != '(none)' ]] || {
    echo "no APT candidate for $package; configure the upstream bcachefs repository" >&2
    exit 1
  }
  installed=$(dpkg-query -W -f='${Version}' "$package")
  if [[ $installed != "$candidate" ]]; then
    echo "$package is $installed; latest APT candidate is $candidate. Run sudo bash scripts/check-bcachefs-version.sh --upgrade while idle." >&2
    exit 1
  fi
  if [[ $package == bcachefs-kernel-dkms ]]; then
    kernel_version=${installed#*:}
    kernel_version=${kernel_version%%-*}
  fi
done

# modinfo reports the module on disk, not the one already loaded in RAM.
disk_version=$(modinfo -F version bcachefs)
disk_version=${disk_version#v}
if [[ $disk_version != "$kernel_version" ]]; then
  echo "bcachefs module on disk is $disk_version; expected $kernel_version. Check DKMS for kernel $(uname -r)." >&2
  exit 1
fi
modprobe bcachefs
loaded_version=$(cat /sys/module/bcachefs/version)
loaded_version=${loaded_version#v}
if [[ $loaded_version != "$kernel_version" ]]; then
  echo "loaded bcachefs module is $loaded_version; expected $kernel_version. Reboot the idle host or safely reload the module before benchmarking." >&2
  exit 1
fi
echo "bcachefs preflight passed: packages current, module $loaded_version"
