"""Resolve benchmark block-device roots to the leaf devices beneath them."""

import os
from collections.abc import Iterable
from pathlib import Path


def partition_parent(sysfs_root: Path, name: str) -> str | None:
    entry = sysfs_root / name
    if not (entry / "partition").exists():
        return None
    try:
        parent = entry.resolve().parent.name
    except OSError:
        return None
    return parent if (sysfs_root / parent).exists() else None


def leaf_names(
    device_paths: Iterable[str], sysfs_root: Path, *, collapse_partitions: bool
) -> list[str]:
    """Return the unique leaf sysfs names under device_paths, in walk order.

    A device with ``slaves/`` entries (dm, md, ...) is replaced by its slaves.
    With ``collapse_partitions`` a partition resolves to its parent disk, which
    owns the request queue; without it the partition itself is the leaf, so
    per-partition counters stay separate from siblings on the same disk.
    """
    leaves: list[str] = []
    visited: set[str] = set()

    def walk(name: str) -> None:
        if collapse_partitions:
            parent = partition_parent(sysfs_root, name)
            if parent is not None:
                name = parent
        if name in visited:
            return
        visited.add(name)

        entry = sysfs_root / name
        if not entry.exists():
            return
        slaves = sorted(child.name for child in (entry / "slaves").glob("*"))
        if slaves:
            for child in slaves:
                walk(child)
            return
        leaves.append(name)

    for device in device_paths:
        walk(os.path.basename(os.path.realpath(device)))
    return leaves
