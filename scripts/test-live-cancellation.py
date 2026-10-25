#!/usr/bin/env python3
"""Exercise the live runner's real signal handler without launching Jarvis."""

import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest


HANDLER = Path(__file__).resolve().parent / "lib/live-test-cancellation.sh"
APP = """
from pathlib import Path
import signal, sys, time
scenario = Path(sys.argv[1])
ignore = sys.argv[2] == 'ignore-term'
if ignore: signal.signal(signal.SIGTERM, signal.SIG_IGN)
(scenario / 'ready').touch()
while not (scenario / 'abort').exists():
    time.sleep(0.02)
(scenario / 'draining').touch()
time.sleep(10 if ignore else 0.15)
(scenario / 'sealed').touch()
"""
STOP = """
import os, signal, sys, time
from pathlib import Path
pid, scenario = int(sys.argv[1]), Path(sys.argv[2])
(scenario / 'stop-called').touch()
try: os.kill(pid, signal.SIGTERM)
except ProcessLookupError: sys.exit(0)
deadline = time.monotonic() + .2
while time.monotonic() < deadline:
    try: os.kill(pid, 0)
    except ProcessLookupError: sys.exit(0)
    time.sleep(.01)
os.kill(pid, signal.SIGKILL)
"""


class LiveCancellationTests(unittest.TestCase):
    def check_cancellation(self, numbers, ignore=False):
        for number in numbers:
            with self.subTest(signal=number.name), tempfile.TemporaryDirectory() as directory:
                scenario = Path(directory) / "B"
                scenario.mkdir()
                (scenario / "scenario.json").write_text("{}")
                handler = Path(directory) / 'handler.sh'
                handler.write_text(HANDLER.read_text().replace('sleep 10', 'sleep 0.4'))
                stop = Path(directory) / 'stop.py'
                stop.write_text(STOP)
                app = subprocess.Popen(
                    [sys.executable, "-c", APP, str(scenario), 'ignore-term' if ignore else 'drain'],
                    env={k: v for k, v in os.environ.items() if not k.startswith('JARVIS_TEST_')},
                    start_new_session=True
                )
                # The stop stand-in observes exit only after the child is reaped.
                reaper = threading.Thread(target=app.wait)
                reaper.start()
                runner = None
                try:
                    runner = subprocess.Popen(
                        ["/bin/bash", "-c",
                         'set -euo pipefail\nFIXTURE_PYTHON="$2"\n'
                         'STOP_SCRIPT="$3"\nSCENARIO_DIR="$4"\n'
                         'stop_test_app() { "$FIXTURE_PYTHON" "$STOP_SCRIPT" "$FIXTURE_APP_PID" "$SCENARIO_DIR"; }\n'
                         'source "$1"\n'
                         '"$2" -c \'import time; print("ready", flush=True); time.sleep(30)\'\necho done',
                         "live-cancellation-test", str(handler), sys.executable, str(stop), str(scenario)],
                        env={**{k: v for k, v in os.environ.items() if not k.startswith('JARVIS_TEST_')}, "RUN_DIR": directory,
                             "FIXTURE_APP_PID": str(app.pid)},
                        start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        text=True,
                    )
                    self.assertTrue(select.select([runner.stdout], [], [], 10)[0], "handler not ready")
                    self.assertEqual(runner.stdout.readline().strip(), "ready")
                    deadline = time.monotonic() + 5
                    while not (scenario / 'ready').exists():
                        self.assertLess(time.monotonic(), deadline, 'app did not become ready')
                        time.sleep(.01)
                    os.killpg(runner.pid, number)
                    output, error = runner.communicate(timeout=15)
                    self.assertEqual(runner.returncode, 130, error)
                    self.assertNotIn("done", output)
                    self.assertTrue((scenario / "abort").exists(), "abort was not requested")
                    self.assertTrue((scenario / 'draining').exists(), 'app never observed abort')
                    self.assertTrue((scenario / 'stop-called').exists(), 'exact fallback was skipped')
                    self.assertEqual((scenario / "sealed").exists(), not ignore,
                                     "app did not receive its natural-exit grace")
                    reaper.join(timeout=1)
                    self.assertEqual(app.poll(), -signal.SIGKILL if ignore else 0,
                                     "detached app outlived cancellation")
                finally:
                    for process in (runner, app):
                        if process is not None:
                            try:
                                os.killpg(process.pid, signal.SIGKILL)
                            except ProcessLookupError:
                                pass
                            process.wait()
                    if runner is not None:
                        runner.communicate(timeout=5)
                    reaper.join()

    def test_signals_finish_detached_app_cleanup(self):
        self.check_cancellation((signal.SIGHUP, signal.SIGINT, signal.SIGTERM))

    def test_term_ignoring_app_reaches_bounded_forced_cleanup(self):
        self.check_cancellation((signal.SIGTERM,), ignore=True)


if __name__ == "__main__":
    unittest.main()
