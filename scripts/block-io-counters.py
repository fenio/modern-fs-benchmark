#!/usr/bin/env python3
"""Snapshot and diff block I/O counters of the leaf devices behind benchmark roots.

`snapshot <roots...>` prints the current counters; `delta <before-json>
<roots...>` takes a second snapshot and prints per-leaf and total deltas.
Partitions are leaves: benchmark partitions sharing one disk are counted
separately from each other and from the rest of that disk.
"""

import argparse
import json
import sys
from collections.abc import Iterable
from pathlib import Path
from typing import Literal, TypedDict, cast

from block_topology import leaf_names


SECTOR_BYTES = 512  # /sys/block/*/stat sectors, independent of logical block size

CounterName = Literal[
    "read_ios", "read_bytes", "write_ios", "write_bytes",
    "discard_ios", "discard_bytes",
]
COUNTERS: tuple[CounterName, ...] = (
    "read_ios", "read_bytes", "write_ios", "write_bytes",
    "discard_ios", "discard_bytes",
)


class Counters(TypedDict):
    """Block counters in I/Os and bytes; None where the kernel lacks the field."""

    read_ios: int | None
    read_bytes: int | None
    write_ios: int | None
    write_bytes: int | None
    discard_ios: int | None
    discard_bytes: int | None


class Leaf(Counters):
    device: str


class Delta(TypedDict):
    leaves: list[Leaf]
    total: Counters


# Leaves keyed by their sysfs `dev` major:minor.
Snapshot = dict[str, Leaf]


def parse_stat(line: str) -> Counters:
    """Map one sysfs ``stat`` line (Documentation/block/stat.rst) to counters.

    Discard fields exist since Linux 4.18; on older kernels they are None.
    """
    fields = [int(value) for value in line.split()]
    if len(fields) < 11:
        raise ValueError(f"short block stat line: {line!r}")
    has_discard = len(fields) >= 15
    return {
        "read_ios": fields[0],
        "read_bytes": fields[2] * SECTOR_BYTES,
        "write_ios": fields[4],
        "write_bytes": fields[6] * SECTOR_BYTES,
        "discard_ios": fields[11] if has_discard else None,
        "discard_bytes": fields[13] * SECTOR_BYTES if has_discard else None,
    }


def snapshot(device_paths: Iterable[str], sysfs_root: Path) -> Snapshot:
    counters: Snapshot = {}
    for name in leaf_names(device_paths, sysfs_root, collapse_partitions=False):
        entry = sysfs_root / name
        identity = (entry / "dev").read_text().strip()
        counters[identity] = Leaf(
            device=f"/dev/{name}", **parse_stat((entry / "stat").read_text())
        )
    if not counters:
        raise ValueError("no leaf block devices found for benchmark roots")
    return counters


def delta(before: Snapshot, after: Snapshot) -> Delta:
    """Per-leaf and total counter growth between two snapshots of the same leaves."""
    if set(before) != set(after):
        raise ValueError(
            "leaf devices changed inside the window: "
            f"before {sorted(before)}, after {sorted(after)}"
        )
    leaves: list[Leaf] = []
    total = cast(Counters, dict.fromkeys(COUNTERS, 0))
    for identity in sorted(before, key=lambda key: before[key]["device"]):
        old, new = before[identity], after[identity]
        leaf = cast(Leaf, {"device": new["device"]})
        for counter in COUNTERS:
            old_value, new_value = old[counter], new[counter]
            change: int | None = None
            if old_value is not None and new_value is not None:
                change = new_value - old_value
                if change < 0:
                    raise ValueError(f"{new['device']}: {counter} decreased")
            leaf[counter] = change
            running = total[counter]
            if running is not None:
                total[counter] = None if change is None else running + change
        leaves.append(leaf)
    return {"leaves": leaves, "total": total}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--sysfs-root", type=Path, default=Path("/sys/class/block")
    )
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("snapshot").add_argument("devices", nargs="+")
    delta_parser = commands.add_parser("delta")
    delta_parser.add_argument("before", help="JSON printed by `snapshot`")
    delta_parser.add_argument("devices", nargs="+")
    args = parser.parse_args()

    try:
        current = snapshot(args.devices, args.sysfs_root)
        if args.command == "snapshot":
            print(json.dumps(current))
        else:
            print(json.dumps(delta(json.loads(args.before), current)))
    except (OSError, ValueError) as error:
        sys.exit(f"block-io-counters: {error}")


if __name__ == "__main__":
    main()
