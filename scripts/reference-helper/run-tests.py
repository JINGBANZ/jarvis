"""Discover host-only helper contracts with an explicit executable."""
from pathlib import Path
import sys
import unittest


if len(sys.argv) != 2:
    raise SystemExit("usage: run-tests.py /path/to/JarvisReferenceHelper")

directory = Path(__file__).resolve().parent
# Isolated Python excludes the script directory; admit only this repository-owned test directory.
sys.path.insert(0, str(directory))
import support

support.HELPER = Path(sys.argv[1]).resolve(strict=True)
suite = unittest.defaultTestLoader.discover(str(directory))
result = unittest.TextTestRunner().run(suite)
raise SystemExit(0 if result.wasSuccessful() else 1)
