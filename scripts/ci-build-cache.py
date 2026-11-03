#!/usr/bin/env python3
"""Keep Swift's incremental inputs stable across fresh CI checkouts."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


def tracked_files(root):
    names = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode().split("\0")
    return [root / name for name in names if name and (root / name).is_file()
            and not (root / name).is_symlink()]


def snapshot(root, manifest):
    entries = {}
    for path in tracked_files(root):
        entries[str(path.relative_to(root))] = {
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "mtime_ns": path.stat().st_mtime_ns,
        }
    manifest.parent.mkdir(parents=True, exist_ok=True)
    manifest.write_text(json.dumps(entries))


def restore(root, manifest):
    if not manifest.exists():
        return
    entries = json.loads(manifest.read_text())
    restored = 0
    # Only current tracked files with identical bytes may inherit a cached timestamp.
    for path in tracked_files(root):
        entry = entries.get(str(path.relative_to(root)))
        if entry and entry["sha256"] == hashlib.sha256(path.read_bytes()).hexdigest():
            os.utime(path, ns=(path.stat().st_atime_ns, entry["mtime_ns"]))
            restored += 1
    print(f"Restored timestamps for {restored} unchanged build inputs.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("snapshot", "restore"))
    arguments = parser.parse_args()
    root = Path.cwd()
    {"snapshot": snapshot, "restore": restore}[arguments.operation](
        root, root / ".build/ci-cache-inputs.json")
