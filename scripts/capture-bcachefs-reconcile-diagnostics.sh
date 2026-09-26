#!/usr/bin/env bash
# Best-effort root diagnostics for a bounded bcachefs reconciliation wait.
set +e

prefix=${1:?usage: capture-bcachefs-reconcile-diagnostics.sh <prefix> <label> <mount> <started-epoch> [sysrq]}
label=${2:?missing label}
mnt=${3:?missing mount}
started_at=${4:?missing start epoch}
sysrq=${5:-}

find_reconcile_wait() {
  local path command
  for path in /proc/[0-9]*; do
    command=$(tr '\0' ' ' <"$path/cmdline" 2>/dev/null) || continue
    [[ $command == "bcachefs reconcile wait $mnt " ]] || continue
    printf '%s\n' "${path##*/}"
    return 0
  done
  return 1
}

if [[ $sysrq == w || $sysrq == t ]]; then
  timeout --signal=TERM --kill-after=2s 5 \
    sh -c "printf '%s' \"\$1\" >/proc/sysrq-trigger" sh "$sysrq"
  sleep 1
fi

# Preserve SysRq output before slower userspace queries consume log space.
timeout --signal=TERM --kill-after=2s 15 \
  dmesg --time-format iso >"$prefix-dmesg-$label.txt" 2>&1
if [[ $label == 0s && -r /boot/config-$(uname -r) ]]; then
  cp "/boot/config-$(uname -r)" "$prefix-kernel-config.txt"
fi

pid=$(find_reconcile_wait || true)
{
  printf 'captured_at='; timeout --signal=TERM --kill-after=2s 5 date -u +%FT%TZ
  printf 'sample=%s\nreconcile_wait_pid=%s\n' "$label" "${pid:-not-running}"
  printf '\n=== uname ===\n'
  timeout --signal=TERM --kill-after=2s 5 uname -a
  printf '\n=== bcachefs version ===\n'
  timeout --signal=TERM --kill-after=2s 10 bcachefs version
  printf '\n=== module ===\n'
  timeout --signal=TERM --kill-after=2s 10 modinfo bcachefs
  printf '\n=== packages ===\n'
  timeout --signal=TERM --kill-after=2s 10 \
    dpkg-query -W bcachefs-tools "linux-image-$(uname -r)"
  printf '\n=== kernel command line and sysrq mask ===\n'
  timeout --signal=TERM --kill-after=2s 5 cat /proc/cmdline
  printf 'sysrq='; timeout --signal=TERM --kill-after=2s 5 cat /proc/sys/kernel/sysrq
  if [[ -n $pid ]]; then
    for item in status wchan syscall stack; do
      printf '\n=== /proc/%s/%s ===\n' "$pid" "$item"
      timeout --signal=TERM --kill-after=2s 5 cat "/proc/$pid/$item"
    done
    task_count=0
    for task in "/proc/$pid/task/"[0-9]*; do
      [[ -d $task ]] || continue
      printf '\n=== task %s ===\n' "${task##*/}"
      for item in status wchan syscall stack; do
        printf '%s:\n' "$item"
        timeout --signal=TERM --kill-after=2s 5 cat "$task/$item"
      done
      task_count=$((task_count + 1))
      (( task_count < 32 )) || break
    done
  fi
  printf '\n=== process wait channels ===\n'
  timeout --signal=TERM --kill-after=2s 10 \
    ps -eLo pid,tid,ppid,user,etimes,stat,wchan:40,comm,args
  printf '\n=== reconcile status ===\n'
  timeout --signal=TERM --kill-after=10s 30 bcachefs reconcile status "$mnt"
  printf '\n=== filesystem usage ===\n'
  timeout --signal=TERM --kill-after=10s 30 bcachefs fs usage "$mnt"
  printf '\n=== mounts and block topology ===\n'
  timeout --signal=TERM --kill-after=2s 10 findmnt -R "$mnt"
  timeout --signal=TERM --kill-after=2s 10 \
    lsblk -b -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL,WWN
  printf '\n=== device-mapper tables ===\n'
  timeout --signal=TERM --kill-after=2s 10 dmsetup table
  printf '\n=== device-mapper status ===\n'
  timeout --signal=TERM --kill-after=2s 10 dmsetup status
  printf '\n=== diskstats ===\n'
  timeout --signal=TERM --kill-after=2s 5 cat /proc/diskstats
  printf '\n=== locks ===\n'
  timeout --signal=TERM --kill-after=2s 5 cat /proc/locks
  printf '\n=== memory ===\n'
  timeout --signal=TERM --kill-after=2s 5 cat /proc/meminfo
} >"$prefix-diagnostics-$label.txt" 2>&1

if [[ $label == final ]] && command -v journalctl >/dev/null; then
  timeout --signal=TERM --kill-after=5s 30 \
    journalctl -k --since "@$started_at" --no-pager \
    >"$prefix-journal-kernel.txt" 2>&1
fi
