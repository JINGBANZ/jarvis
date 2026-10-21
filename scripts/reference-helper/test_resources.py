"""Debug-only checks of the real conversion pool, its limits, and worker ownership."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

from support import HELPER


class ConversionResources(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.fixture = self.root / "input"
        self.fixture.write_text("synthetic source")
        self.environment = {"PATH": "/usr/bin:/bin", "HOME": str(self.root), "LANG": "en_US.UTF-8"}

    def evaluate(self, format):
        result = subprocess.run([str(HELPER), "--test-conversion", str(self.fixture), format, str(self.root / "staging")],
                                capture_output=True, env=self.environment, timeout=25)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        report = json.loads(result.stdout)
        self.assertEqual(report["remaining_workers"], 0)
        self.assertLessEqual(report["peak_workers"], 2)
        self.assertEqual(report["poll_interval_ms"], 20)
        print("Conversion resource evidence:", json.dumps(report, sort_keys=True), flush=True)
        return report

    def test_two_worker_limit_and_active_queued_cancellation(self):
        report = self.evaluate("__test_concurrency")
        self.assertEqual(report["status"], "ok")
        self.assertEqual(report["peak_workers"], 2)
        self.assertEqual(report["cancelled_jobs"], 3)
        self.assertTrue(report["queued_job_observed"])
        self.assertEqual(report["foreground_waiters"], 0)
        self.assertLess(report["elapsed_ms"], 5_000)

    def test_memory_limit_terminates_and_reaps_worker(self):
        report = self.evaluate("__test_memory")
        self.assertEqual(report["status"], "resource_limit")
        self.assertGreaterEqual(report["peak_rss_bytes"], report["rss_limit_bytes"])
        self.assertLess(report["elapsed_ms"], 10_000)

    def test_wall_time_terminates_and_reaps_worker(self):
        report = self.evaluate("__test_hang")
        self.assertEqual(report["status"], "conversion_timeout")
        self.assertGreaterEqual(report["elapsed_ms"], 15_000)
        self.assertLess(report["elapsed_ms"], 22_000)

    def test_worker_exits_when_owning_process_dies(self):
        pidfile = self.root / "pid"
        wrapper_code = """import pathlib,subprocess,sys,time
worker=subprocess.Popen([sys.argv[1],'--worker',sys.argv[2],'__test_hang',sys.argv[3]],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
pathlib.Path(sys.argv[4]).write_text(str(worker.pid))
time.sleep(60)
"""
        owner = subprocess.Popen([sys.executable, "-I", "-c", wrapper_code, str(HELPER), str(self.fixture),
                                  str(self.root / "output"), str(pidfile)], env=self.environment)
        worker_pid = None
        try:
            deadline = time.monotonic() + 5
            while not pidfile.exists() and time.monotonic() < deadline: time.sleep(.01)
            self.assertTrue(pidfile.exists())
            worker_pid = int(pidfile.read_text())
            time.sleep(.2)
            owner.kill(); owner.wait(timeout=5)
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                try: os.kill(worker_pid, 0)
                except ProcessLookupError: break
                time.sleep(.02)
            else: self.fail("owned conversion worker survived parent death")
        finally:
            if owner.poll() is None: owner.kill()
            owner.wait(timeout=5)
            if worker_pid:
                try: os.kill(worker_pid, signal.SIGKILL)
                except ProcessLookupError: pass
