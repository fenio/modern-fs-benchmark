#!/usr/bin/env python3
"""Report queue settings for the leaf block devices behind benchmark roots."""

import argparse
import json
from pathlib import Path

from block_topology import leaf_names


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


def collect_queue_settings(device_paths, sysfs_root):
    leaves = {}
    for name in leaf_names(device_paths, sysfs_root, collapse_partitions=True):
        entry = sysfs_root / name
        identity = read_text(entry / "dev") or name
        queue = entry / "queue"
        result = {
            "device": f"/dev/{name}",
            "scheduler": selected_scheduler(queue / "scheduler"),
        }
        for field in QUEUE_INTEGER_FIELDS:
            result[field] = read_integer(queue / field)
        leaves[identity] = result
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
