#!/usr/bin/env python3
"""Bounded clean-start check of benchmark MD, dm-raid and dm-integrity stacks."""

import argparse
import os
from pathlib import Path
import subprocess
import sys
import time


def stack_names(devices, sysfs):
    """Walk holders as well as slaves: callers may supply physical members."""
    seen = set()
    pending = [os.path.basename(os.path.realpath(device)) for device in devices]
    while pending:
        name = pending.pop()
        if name in seen:
            continue
        entry = sysfs / name
        if not entry.exists():
            raise RuntimeError(f"missing benchmark block device: {name}")
        seen.add(name)
        for relation in ("slaves", "holders"):
            pending.extend(child.name for child in (entry / relation).glob("*"))
    return sorted(seen)


def dm_pending(name, status):
    if not status.strip():
        raise RuntimeError(f"empty dm status for {name}")
    pending = []
    for line in status.splitlines():
        fields = line.split()
        if len(fields) < 3:
            raise RuntimeError(f"unrecognized dm status for {name}: {line}")
        if fields[2] == "raid":
            if len(fields) < 8:
                raise RuntimeError(f"unrecognized dm-raid status for {name}: {line}")
            health, progress, action = fields[5:8]
            done, total = map(int, progress.split("/"))
            if set(health) != {"A"} or done != total or action != "idle":
                pending.append(f"{name}: raid health={health}, sync={progress}, action={action}")
        elif fields[2] == "integrity":
            if len(fields) < 6:
                raise RuntimeError(f"unrecognized dm-integrity status for {name}: {line}")
            if int(fields[3]) != 0:
                raise RuntimeError(f"{name}: dm-integrity reports checksum mismatches")
            provided, position = fields[4:6]
            if position != "-" and int(position) < int(provided):
                pending.append(f"{name}: integrity recalculation={position}/{provided}")
    return pending


def pending_work(devices, sysfs=Path("/sys/class/block"), dm_status=None):
    pending = []
    for name in stack_names(devices, sysfs):
        entry = sysfs / name
        if (entry / "md").exists():
            state = (entry / "md" / "array_state").read_text().strip()
            if state in ("inactive", "clear"):
                raise RuntimeError(f"{name}: stale {state} MD array; clean up before benchmarking")
            action = (entry / "md" / "sync_action").read_text().strip()
            degraded = int((entry / "md" / "degraded").read_text().strip())
            if action != "idle" or degraded != 0:
                pending.append(f"{name}: action={action}, degraded={degraded}")
        if (entry / "dm").exists():
            if dm_status is None:
                status = subprocess.check_output(
                    ["dmsetup", "status", "--noflush", f"/dev/{name}"], text=True)
            else:
                status = dm_status(name)
            pending.extend(dm_pending(name, status))
    return pending


def wait_ready(devices, timeout, interval=2, inspect=pending_work,
               clock=time.monotonic, sleep=time.sleep):
    deadline = clock() + timeout
    previous = None
    while True:
        pending = inspect(devices)
        if not pending:
            return
        message = "; ".join(pending)
        if clock() >= deadline:
            raise RuntimeError(f"block devices did not become healthy and idle within {timeout}s: {message}")
        if message != previous:
            print(f"waiting for clean benchmark start: {message}", file=sys.stderr)
            previous = message
        sleep(min(interval, max(0, deadline - clock())))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=int, default=3600)
    parser.add_argument("devices", nargs="+")
    args = parser.parse_args()
    if args.timeout < 0:
        parser.error("timeout must be nonnegative")
    try:
        wait_ready(args.devices, args.timeout)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"ERROR: benchmark clean-start check failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
