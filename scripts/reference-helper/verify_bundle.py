"""Build-only license completeness and cache manifest generation."""
import hashlib
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
notices = root / "notices/python"
metadata = json.loads((notices / "PYTHON.json").read_text())

def verify(value):
    if isinstance(value, dict):
        paths = value.get("license_paths", [])
        if value.get("license_path"):
            paths = [*paths, value["license_path"]]
        for path in paths:
            source = notices / path
            if not source.is_file() or not source.stat().st_size:
                raise ValueError("missing runtime notice: " + path)
        for item in value.values():
            verify(item)
    elif isinstance(value, list):
        for item in value:
            verify(item)

verify(metadata)
site = root / "python/lib/python3.13/site-packages"
for distribution in site.glob("*.dist-info"):
    if not any(p.is_file() and p.stat().st_size for p in distribution.rglob("*") if "license" in p.name.lower() or "licence" in p.name.lower() or "copying" in p.name.lower()):
        raise ValueError("missing wheel license: " + distribution.name)
with (root / "manifest.sha256").open("w") as output:
    for directory in [root / "python", root / "notices"]:
        for path in sorted(directory.rglob("*")):
            if path.is_symlink():
                if not path.resolve().is_relative_to(root.resolve()):
                    raise ValueError("escaping runtime link")
            elif path.is_file():
                output.write(hashlib.sha256(path.read_bytes()).hexdigest() + "  " + str(path.relative_to(root)) + "\n")
