#!/usr/bin/env python3
"""Exercise the live runner's real signal handler without launching Jarvis."""

import os
from pathlib import Path
import re
import select
import signal
import subprocess
import sys
import tempfile
import threading
import unittest


HANDLER = Path(__file__).resolve().parent / "lib/live-test-cancellation.sh"
APP = """
from pathlib import Path
import sys, time
scenario = Path(sys.argv[1])
while not (scenario / 'abort').exists():
    time.sleep(0.02)
(scenario / 'sealed').touch()
"""


class LiveCancellationTests(unittest.TestCase):
    def test_signals_finish_detached_app_cleanup(self):
        for number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=number.name), tempfile.TemporaryDirectory() as directory:
                scenario = Path(directory) / "B"
                scenario.mkdir()
                (scenario / "scenario.json").write_text("{}")
                app = subprocess.Popen(
                    [sys.executable, "-c", APP, str(scenario)], start_new_session=True
                )
                # Reap promptly so pgrep observes the app's exit while the handler waits.
                reaper = threading.Thread(target=app.wait)
                reaper.start()
                runner = None
                try:
                    runner = subprocess.Popen(
                        ["/bin/bash", "-c",
                         'set -euo pipefail\nFIXTURE_PYTHON="$2"\n'
                         'stop_test_app() { "$FIXTURE_PYTHON" -c \'import os,sys,time; p=int(sys.argv[1]); '
                         'end=time.monotonic()+5; '
                         'exec("while time.monotonic()<end:\\n try: os.kill(p,0)\\n except ProcessLookupError: sys.exit(0)\\n time.sleep(.02)\\nsys.exit(1)")'
                         '\' "$FIXTURE_APP_PID"; }\nsource "$1"\n'
                         '"$2" -c \'import time; print("ready", flush=True); time.sleep(30)\'\necho done',
                         "live-cancellation-test", str(HANDLER), sys.executable],
                        env={**{k: v for k, v in os.environ.items() if not k.startswith('JARVIS_TEST_')}, "RUN_DIR": directory,
                             "FIXTURE_APP_PID": str(app.pid)},
                        start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        text=True,
                    )
                    self.assertTrue(select.select([runner.stdout], [], [], 10)[0], "handler not ready")
                    self.assertEqual(runner.stdout.readline().strip(), "ready")
                    os.killpg(runner.pid, number)
                    output, error = runner.communicate(timeout=15)
                    self.assertEqual(runner.returncode, 130, error)
                    self.assertNotIn("done", output)
                    self.assertTrue((scenario / "abort").exists(), "abort was not requested")
                    self.assertTrue((scenario / "sealed").exists(), "app did not finish cleanup")
                    reaper.join(timeout=1)
                    self.assertEqual(app.poll(), 0, "detached app outlived cancellation")
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


if __name__ == "__main__":
    unittest.main()
