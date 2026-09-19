import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "control", Path(__file__).with_name("microphone-benchmark-control.py"))
control = importlib.util.module_from_spec(spec)
spec.loader.exec_module(control)


class MicrophoneControlTests(unittest.TestCase):
    def test_previous_trial_recording_does_not_authorize_next_trial(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            (run / "progress.json").write_text(json.dumps({"phase": "recording", "detail": "1"}))
            with self.assertRaisesRegex(RuntimeError, "timed out"):
                control.wait_for(run, "recording", 2, timeout=0.01)

    def test_failure_wins_over_stale_ready_and_does_not_relay_error_content(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            (run / "progress.json").write_text(json.dumps({"phase": "recording", "detail": "1"}))
            (run / "benchmark-error.json").write_text("PRIVATE-PROVIDER-TEXT")
            with self.assertRaises(RuntimeError) as error:
                control.wait_for(run, "recording", 1)
            self.assertNotIn("PRIVATE", str(error.exception))
            self.assertIn("stopped", str(error.exception))

    def test_current_trial_ready_returns_without_starting_microphone(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            (run / "progress.json").write_text(json.dumps({"phase": "waiting-for-start", "detail": "1"}))
            control.wait_for(run, "waiting-for-start", 1)
            self.assertFalse((run / "start-1").exists())


if __name__ == "__main__":
    unittest.main()
