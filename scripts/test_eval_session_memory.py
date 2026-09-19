import importlib.util
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('memory_eval', Path(__file__).with_name('eval-session-memory.py'))
evaluation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evaluation)


class TailParityTests(unittest.TestCase):
    def test_same_recent_tail_survives_valid_summary(self):
        tail = [{'role': 'user', 'text': 'recent'}]
        evaluation.ensure_tail_parity(tail, [{'text': 'older'}] + tail, [{'text': 'summary'}] + tail)

    def test_changed_compacted_tail_is_rejected(self):
        with self.assertRaises(RuntimeError):
            evaluation.ensure_tail_parity([{'text': 'recent'}], [{'text': 'recent'}], [{'text': 'changed'}])

    def test_different_full_tail_is_rejected(self):
        with self.assertRaises(RuntimeError):
            evaluation.ensure_tail_parity([{'text': 'recent'}], [{'text': 'different'}], [{'text': 'recent'}])

    def test_failed_summary_must_preserve_entire_history(self):
        history = [{'text': 'older'}, {'text': 'recent'}]
        evaluation.ensure_preservation(False, history, list(history))
        with self.assertRaises(RuntimeError):
            evaluation.ensure_preservation(False, history, history[1:])


class SetupTests(unittest.TestCase):
    def test_fresh_workspace_creates_private_artifact_parent(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / '.jarvis' / 'run'
            evaluation.create_run_directory(directory)
            self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
            self.assertEqual(directory.parent.stat().st_mode & 0o777, 0o700)
            with self.assertRaises(FileExistsError):
                evaluation.create_run_directory(directory)

    def test_failed_fresh_build_stops_setup_and_preserves_log(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            result = SimpleNamespace(returncode=1, stdout='compile failed', stderr='')
            with mock.patch.object(evaluation.subprocess, 'run', return_value=result) as run:
                with self.assertRaises(RuntimeError):
                    evaluation.build_bridge(directory)
            self.assertNotIn('--skip-build', run.call_args.args[0])
            self.assertEqual((directory / 'bridge-build.log').read_text(), 'compile failed')


if __name__ == '__main__':
    unittest.main()
