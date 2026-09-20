#!/usr/bin/env python3
"""Report queue settings for the leaf block devices behind benchmark roots."""

import argparse
import json
import os
from pathlib import Path


QUEUE_INTEGER_FIELDS = (
    "nr_requests",
    "read_ahead_kb",
    "nomerges",
    "rotational",
    "wbt_lat_usec",
)


def read_text(path):
    try:
        return path.read_text().strip()
    except OSError:
        return None


def read_integer(path):
    value = read_text(path)
    try:
        return int(value) if value is not None else None
    except ValueError:
        return None


def selected_scheduler(path):
    value = read_text(path)
    if value is None:
        return None
    for token in value.split():
        if token.startswith("[") and token.endswith("]"):
            return token[1:-1]
    tokens = value.split()
    return tokens[0] if len(tokens) == 1 else None


def partition_parent(sysfs_root, name):
    entry = sysfs_root / name
    if not (entry / "partition").exists():
        return None
    try:
        parent = entry.resolve().parent.name
    except OSError:
        return None
    return parent if (sysfs_root / parent).exists() else None


def collect_queue_settings(device_paths, sysfs_root):
    leaves = {}
    visited = set()

    def walk(name):
        parent = partition_parent(sysfs_root, name)
        if parent is not None:
            name = parent
        if name in visited:
            return
        visited.add(name)

        entry = sysfs_root / name
        if not entry.exists():
            return
        slaves = sorted(
            child.name for child in (entry / "slaves").glob("*")
        )
        if slaves:
            for child in slaves:
                walk(child)
            return

        identity = read_text(entry / "dev") or name
        queue = entry / "queue"
        result = {
            "device": f"/dev/{name}",
            "scheduler": selected_scheduler(queue / "scheduler"),
        }
        for field in QUEUE_INTEGER_FIELDS:
            result[field] = read_integer(queue / field)
        leaves[identity] = result

    for device in device_paths:
        walk(os.path.basename(os.path.realpath(device)))
    return sorted(leaves.values(), key=lambda item: item["device"])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("devices", nargs="+")
    parser.add_argument(
        "--sysfs-root", type=Path, default=Path("/sys/class/block")
    )
    args = parser.parse_args()
    print(json.dumps(collect_queue_settings(args.devices, args.sysfs_root)))


if __name__ == "__main__":
    main()
