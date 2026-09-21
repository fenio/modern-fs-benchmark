#!/usr/bin/env python3
"""Verify bcachefs hybrid-tier allocation targets and observed placement."""

import argparse
import re
import sys
from pathlib import Path


HDD_MODEL = "ST6000NM0095"
SSD_MODEL = "HUSMM1640ASS200"
TARGETS = (
    "metadata_target",
    "foreground_target",
    "background_target",
    "promote_target",
)


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)


def parse_super(text):
    targets = {name: set() for name in TARGETS}
    devices = {}
    current = None

    def save_current():
        if current is None or current.get("label") is None:
            return
        label = current["label"]
        observed = (current.get("model"), current.get("rotational"), current.get("data"))
        devices.setdefault(label, set()).add(observed)

    for line in text.splitlines():
        target = re.match(
            r"^  (metadata_target|foreground_target|background_target|promote_target):\s+(\S+)",
            line,
        )
        if target:
            targets[target.group(1)].add(target.group(2))
            continue

        device = re.match(r"^Device \d+:\s+\S+\s+(\S+)", line)
        if device:
            save_current()
            current = {"model": device.group(1)}
            continue
        if current is None:
            continue

        label = re.match(r"^  Label:\s+(.+?)\s*$", line)
        if label:
            current["label"] = label.group(1)
            continue
        data = re.match(r"^  Has data:\s+(.+?)\s*$", line)
        if data:
            current["data"] = frozenset(
                item for item in data.group(1).split(",") if item != "(none)"
            )
            continue
        rotational = re.match(r"^  Rotational:\s+([01])\s*$", line)
        if rotational:
            current["rotational"] = int(rotational.group(1))

    save_current()
    return targets, devices


def require_device(
    devices, label, model, rotational, required_data=(), forbidden_data=()
):
    observed = devices.get(label)
    if not observed:
        fail(f"missing bcachefs device evidence for {label}")
    if len(observed) != 1:
        fail(f"inconsistent bcachefs device evidence for {label}: {list(observed)!r}")
    actual_model, actual_rotational, data = next(iter(observed))
    if actual_model != model or actual_rotational != rotational or data is None:
        fail(
            f"unexpected device evidence for {label}: "
            f"model={actual_model}, rotational={actual_rotational}, data={data}"
        )
    missing = set(required_data) - set(data)
    forbidden = set(forbidden_data) & set(data)
    if missing:
        fail(f"{label} is missing required allocation types: {', '.join(sorted(missing))}")
    if forbidden:
        fail(f"{label} contains forbidden allocation types: {', '.join(sorted(forbidden))}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--usage", required=True, type=Path)
    parser.add_argument("--super", required=True, type=Path)
    parser.add_argument(
        "--expected-hot-count", required=True, type=int, choices=(2, 3)
    )
    parser.add_argument(
        "--expected-promote-target", required=True, choices=("hot", "readcache")
    )
    args = parser.parse_args()

    try:
        usage = args.usage.read_text()
        super_text = args.super.read_text()
    except OSError as exc:
        fail(str(exc))

    for marker in ("Data type", "Btree usage:"):
        if marker not in usage:
            fail(
                f"{args.usage} is not a full 'bcachefs fs usage -a' dump: "
                f"missing {marker!r}"
            )

    targets, devices = parse_super(super_text)
    expected_targets = {
        "metadata_target": "hot",
        "foreground_target": "hot",
        "background_target": "hdd",
        "promote_target": args.expected_promote_target,
    }
    for name, expected in expected_targets.items():
        if targets[name] != {expected}:
            fail(f"unexpected {name}: {sorted(targets[name])!r}; expected {expected!r}")

    expected_labels = {f"hdd.disk{i}" for i in range(8)}
    expected_labels.update(f"hot.ssd{i}" for i in range(args.expected_hot_count))
    if args.expected_hot_count == 2:
        expected_labels.add("readcache.ssd0")
    if set(devices) != expected_labels:
        fail(
            "unexpected bcachefs device labels: "
            f"{sorted(devices)!r}; expected {sorted(expected_labels)!r}"
        )
    for label in sorted(expected_labels):
        if label not in usage:
            fail(f"full usage dump does not include {label}")

    for i in range(8):
        require_device(
            devices,
            f"hdd.disk{i}",
            HDD_MODEL,
            1,
            forbidden_data=("journal", "btree"),
        )
    for i in range(args.expected_hot_count):
        label = f"hot.ssd{i}"
        require_device(
            devices,
            label,
            SSD_MODEL,
            0,
            required_data=("journal", "btree"),
        )
    if args.expected_hot_count == 2:
        require_device(
            devices,
            "readcache.ssd0",
            SSD_MODEL,
            0,
            forbidden_data=("journal", "btree"),
        )

    print("bcachefs hybrid-tier placement evidence verified")


if __name__ == "__main__":
    main()
