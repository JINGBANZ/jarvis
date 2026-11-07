#!/usr/bin/env python3
"""Packaged-app diagnostic contracts without launching macOS applications."""

import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


sys.dont_write_bytecode = True
SCRIPT = Path(__file__).with_name("verify-installation.py")


class InstallationVerificationTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("installation_verification", SCRIPT)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        temporary = tempfile.TemporaryDirectory(prefix="jarvis-installation-contract-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.app = self.root / "Jarvis.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleShortVersionString": "0.5.14", "CFBundleExecutable": "JarvisApp"}))
        self.binary = self.app / "Contents/MacOS/JarvisApp"
        self.binary.write_bytes(b"fixture JARVIS_INSTALLATION_CHECK ")
        self.binary.chmod(0o700)
        self.receipt_change = lambda receipt: receipt
        self.output_change = lambda output: output
        self.launch_status = 0
        self.launch_timeout = False
        self.launch_interrupt = False
        self.launches = []

    def run_process(self, command, **kwargs):
        if command[0] == "/usr/bin/ditto":
            shutil.copytree(command[1], command[2], symlinks=True)
            return subprocess.CompletedProcess(command, 0)
        self.assertEqual(command[0], "/usr/bin/open")
        self.assertIn("-n", command)
        self.assertIn("-W", command)
        self.assertIn("-g", command)
        self.assertEqual(command[-2:], ["--args", "--verify-installation"])
        self.assertEqual(command[command.index("--arch") + 1], "arm64")
        self.assertEqual(kwargs["timeout"], 45)
        app = Path(command[command.index("--args") - 1])
        self.assertNotEqual(app, self.app)
        self.assertFalse(app.is_relative_to(self.root))
        self.assertEqual((app / "Contents/MacOS/JarvisApp").read_bytes(), self.binary.read_bytes())
        self.launches.append(app)
        self.addCleanup(shutil.rmtree, app.parent, ignore_errors=True)
        if self.launch_timeout:
            raise subprocess.TimeoutExpired(command, 45)
        if self.launch_interrupt:
            raise KeyboardInterrupt()
        receipt = self.receipt_change({
            "schema": 1, "status": "passed", "version": "0.5.14",
            "architecture": "arm64", "bundlePath": str(app.resolve()),
            "skills": ["behavioral", "coding", "coding-with-ai", "customer-scenario-design", "system-design"],
            "checks": ["speech-model", "speech-inference", "audio-processing", "skills"],
        })
        output = "JARVIS_INSTALLATION_CHECK " + json.dumps(receipt) + "\n"
        Path(command[command.index("--stdout") + 1]).write_text(self.output_change(output))
        Path(command[command.index("--stderr") + 1]).write_text("")
        return subprocess.CompletedProcess(command, self.launch_status, "", "")

    def verify(self):
        with patch.object(self.module, "native_architecture", return_value="arm64"), \
                patch.object(self.module.subprocess, "run", side_effect=self.run_process):
            return self.module.verify_app(self.app)

    def test_verified_receipt_comes_from_isolated_copy_and_copy_is_removed(self):
        result = self.verify()
        self.assertEqual(result["architecture"], "arm64")
        self.assertEqual(len(self.launches), 1)
        self.assertFalse(self.launches[0].exists())
        self.assertTrue(self.binary.exists())

    def test_nonzero_launcher_rejects_even_a_passing_receipt(self):
        self.launch_status = 1
        with self.assertRaisesRegex(self.module.VerificationError, "launch"):
            self.verify()

    def test_timeout_is_not_success(self):
        self.launch_timeout = True
        with self.assertRaisesRegex(self.module.VerificationError, "timed out"):
            self.verify()
        self.assertTrue(self.launches[0].exists())

    def test_interrupted_launch_preserves_copy_until_exit_can_be_proven(self):
        self.launch_interrupt = True
        with self.assertRaises(KeyboardInterrupt):
            self.verify()
        self.assertTrue(self.launches[0].exists())

    def test_missing_malformed_or_duplicate_receipt_is_not_success(self):
        for change in [lambda _: "", lambda _: "JARVIS_INSTALLATION_CHECK invalid\n",
                       lambda output: output + output]:
            with self.subTest(change=change):
                self.output_change = change
                with self.assertRaises(self.module.VerificationError):
                    self.verify()

    def test_wrong_version_architecture_path_or_incomplete_checks_are_rejected(self):
        for field, value in [("schema", 2), ("version", "0.5.13"), ("architecture", "x86_64"),
                             ("bundlePath", str(self.app)), ("checks", ["skills"]),
                             ("skills", []), ("status", "failed")]:
            with self.subTest(field=field):
                self.receipt_change = lambda receipt: {**receipt, field: value}
                with self.assertRaises(self.module.VerificationError):
                    self.verify()

    def test_app_failure_reports_component(self):
        self.receipt_change = lambda receipt: {**receipt, "status": "failed", "error": "speech-model"}
        with self.assertRaisesRegex(self.module.VerificationError, "speech-model"):
            self.verify()

    def test_receipt_accepts_absolute_bundle_path_alias(self):
        self.receipt_change = lambda receipt: {
            **receipt, "bundlePath": receipt["bundlePath"].replace("/private/tmp/", "/tmp/", 1)}
        self.assertEqual(self.verify()["architecture"], "arm64")

    def test_receipt_rejects_invalid_missing_or_different_bundle_paths(self):
        for path in (None, [], "Jarvis.app", str(self.root / "missing.app"), str(self.app), "/bad\x00path"):
            with self.subTest(path=path):
                self.receipt_change = lambda receipt: {**receipt, "bundlePath": path}
                with self.assertRaisesRegex(self.module.VerificationError, "bundlePath"):
                    self.verify()

    def test_old_app_without_diagnostic_is_never_launched(self):
        self.binary.write_bytes(b"old application")
        with self.assertRaisesRegex(self.module.VerificationError, "diagnostic"):
            self.verify()
        self.assertEqual(self.launches, [])

    def test_unexpected_declared_executable_is_rejected_before_copy_or_launch(self):
        info = self.app / "Contents/Info.plist"
        for executable in (None, "helper", "../Other.app/Contents/MacOS/JarvisApp"):
            with self.subTest(executable=executable):
                contents = {"CFBundleShortVersionString": "0.5.14"}
                if executable is not None:
                    contents["CFBundleExecutable"] = executable
                info.write_bytes(plistlib.dumps(contents))
                with patch.object(self.module.subprocess, "run") as run:
                    with self.assertRaisesRegex(self.module.VerificationError, "executable"):
                        self.module.verify_app(self.app)
                    run.assert_not_called()

    def test_native_intel_accepts_absent_or_zero_translation_flag(self):
        for output in ("", "0\n"):
            with self.subTest(output=output):
                with patch.object(self.module.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, output)) as run, \
                        patch.object(self.module.platform, "machine", return_value="x86_64"):
                    self.assertEqual(self.module.native_architecture(), "x86_64")
                    self.assertEqual(run.call_args.args[0],
                                     ["/usr/sbin/sysctl", "-n", "-i", "sysctl.proc_translated"])

    def test_arm64_and_unsupported_architectures_do_not_query_translation(self):
        with patch.object(self.module.subprocess, "run") as run:
            with patch.object(self.module.platform, "machine", return_value="arm64"):
                self.assertEqual(self.module.native_architecture(), "arm64")
            with patch.object(self.module.platform, "machine", return_value="i386"):
                with self.assertRaisesRegex(self.module.VerificationError, "unsupported"):
                    self.module.native_architecture()
            run.assert_not_called()

    def test_rosetta_does_not_count_as_native_intel_evidence(self):
        with patch.object(self.module.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "1\n")), \
                patch.object(self.module.platform, "machine", return_value="x86_64"):
            with self.assertRaisesRegex(self.module.VerificationError, "Rosetta"):
                self.module.native_architecture()


if __name__ == "__main__":
    unittest.main()
