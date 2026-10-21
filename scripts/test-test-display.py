#!/usr/bin/env python3
"""Offline contracts by default; --live checks real local WindowServer/ColorSync lifecycle."""

import hashlib
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / ".build/test-display"
SOURCE = ROOT / "scripts/test-display"
LIVE = "--live" in sys.argv
if LIVE:
    sys.argv.remove("--live")


def compile_contracts():
    BUILD.mkdir(parents=True, exist_ok=True)
    sources = [SOURCE / name for name in ("TestDisplay.swift", "TestDisplayIdentity.swift", "TestDisplayProfiles.swift")]
    sources.append(ROOT / "scripts/test-display-contracts.swift")
    header = SOURCE / "DeskPad/CGVirtualDisplayPrivate.h"
    version = subprocess.check_output(["swiftc", "--version"], stderr=subprocess.STDOUT)
    digest = hashlib.sha256(version + b"".join(path.read_bytes() for path in [header, *sources])).hexdigest()
    binary = BUILD / ("contracts-" + digest)
    if not binary.exists():
        temporary = binary.with_suffix("." + str(os.getpid()))
        result = subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library",
                                 "-module-cache-path", str(ROOT / ".build/ModuleCache"),
                                 "-import-objc-header", str(header), *map(str, sources), "-o", str(temporary)],
                                capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        temporary.replace(binary)
    return binary


def ready(process):
    deadline = time.monotonic() + 20
    pending = ""
    while time.monotonic() < deadline:
        if select.select([process.stdout], [], [], 0.1)[0]:
            chunk = os.read(process.stdout.fileno(), 4096).decode()
            if not chunk:
                raise AssertionError("helper exited before child readiness: " + process.stderr.read())
            pending += chunk
            while "\n" in pending:
                line, pending = pending.split("\n", 1)
                if line.startswith("READY "):
                    return int(line.split()[1])
    raise AssertionError("helper did not become ready")


class DisplayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.contracts = compile_contracts()

    def start(self, command, cwd):
        process = subprocess.Popen(command, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

        def cleanup():
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=20)
        self.addCleanup(cleanup)
        return process


class IdentityTests(DisplayTests):
    def test_profile_selection_and_identity_contracts(self):
        result = subprocess.run([self.contracts], capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        print(result.stdout.strip())

    def test_worktrees_share_bounded_leases_and_signals_release_them(self):
        with tempfile.TemporaryDirectory(prefix="jarvis-display-leases-") as temporary:
            root = Path(temporary)
            locks = root / "locks"
            worktrees = [root / str(index) for index in range(4)]
            for path in worktrees:
                path.mkdir()
            holders = [self.start([self.contracts, "--hold", locks], cwd) for cwd in worktrees]
            serials = [ready(process) for process in holders]
            self.assertEqual(len(set(serials)), 4)
            rejected = subprocess.run([self.contracts, "--hold", locks], capture_output=True, text=True, timeout=10)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("All four", rejected.stderr)
            for process, number, serial in zip(holders, (signal.SIGHUP, signal.SIGINT, signal.SIGTERM, signal.SIGKILL), serials):
                process.send_signal(number)
                process.communicate(timeout=10)
                replacement = self.start([self.contracts, "--hold", locks], root)
                self.assertEqual(ready(replacement), serial)


@unittest.skipUnless(LIVE, "requires --live on a logged-in macOS desktop")
class LifecycleTests(DisplayTests):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        output = subprocess.check_output(
            ["/bin/bash", "-c", 'source scripts/lib/test-display.sh; build_test_display; echo "$display_runner"'],
            cwd=ROOT, text=True)
        cls.runner = output.strip().splitlines()[-1]

    def snapshot(self):
        return json.loads(subprocess.check_output([self.contracts, "--snapshot"], text=True, timeout=20))

    def profiles(self):
        return set(Path("/Library/ColorSync/Profiles/Displays").glob("Jarvis Tests-*.icc"))

    def wait_for_displays(self, expected):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            current = self.snapshot()
            if current == expected:
                return
            time.sleep(0.1)
        self.assertEqual(current, expected)

    def test_real_repetition_concurrency_and_cancellation(self):
        original = self.snapshot()
        physical = [item for item in original if item["vendor"] != 0x4A56 or item["product"] != 0x5453]
        self.assertEqual(original, physical, "run this check with no other test displays active")
        counts = []
        for _ in range(4):
            result = subprocess.run([self.runner, "--", "/bin/sleep", "2"], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            time.sleep(1)
            counts.append(len(self.profiles()))
            self.assertEqual(self.snapshot(), physical)
        self.assertGreater(counts[0], 0, "ColorSync must actually persist a profile for this check")
        self.assertEqual(len(set(counts)), 1, f"profile growth across repeated cycles: {counts}")
        print("Repeated real create/run/teardown profile counts:", counts)

        helpers = []
        with tempfile.TemporaryDirectory(prefix="jarvis-display-worktrees-") as temporary:
            for index in range(4):
                worktree = Path(temporary) / str(index)
                worktree.mkdir()
                helper = self.start([self.runner, "--", self.contracts, "--child"], worktree)
                helpers.append((helper, ready(helper)))
            displays = self.snapshot()
            active = [item for item in displays if item not in physical]
            self.assertEqual({item["id"] for item in active}, {identity for _, identity in helpers})
            self.assertEqual(len({item["serial"] for item in active}), 4)
            self.assertEqual([item for item in displays if item in physical], physical)
            rejected = subprocess.run([self.runner, "--", "/bin/echo", "CHILD_MUST_NOT_START"],
                                      capture_output=True, text=True, timeout=20)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("All four", rejected.stderr)
            self.assertNotIn("CHILD_MUST_NOT_START", rejected.stdout)
            beforePreview = self.profiles()
            preview = subprocess.run([self.runner, "--cleanup-profiles"], capture_output=True, text=True, timeout=20)
            self.assertEqual(preview.returncode, 0, preview.stderr)
            self.assertEqual(self.profiles(), beforePreview)
            full = self.profiles()
            for (helper, _), number in zip(helpers, (signal.SIGHUP, signal.SIGINT, signal.SIGTERM, signal.SIGHUP)):
                helper.send_signal(number)
                stdout, stderr = helper.communicate(timeout=20)
                self.assertEqual(helper.returncode, 128 + number, stdout + stderr)
            self.wait_for_displays(physical)
            for _ in range(2):
                repeated = []
                for index in range(4):
                    helper = self.start([self.runner, "--", self.contracts, "--child"], Path(temporary) / str(index))
                    repeated.append(helper)
                    ready(helper)
                self.assertEqual(self.profiles(), full)
                for helper in repeated:
                    helper.send_signal(signal.SIGTERM)
                    stdout, stderr = helper.communicate(timeout=20)
                    self.assertEqual(helper.returncode, 128 + signal.SIGTERM, stdout + stderr)
                self.wait_for_displays(physical)
            self.assertEqual(self.profiles(), full)
            print("Concurrent helpers: 4 distinct identities; fifth rejected; HUP/INT/TERM cleanup passed; profiles:", len(full))


if __name__ == "__main__":
    unittest.main()
