#!/usr/bin/env python3
"""Synthetic command contracts; no signing keys, app launches, capture, or providers."""

import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


REPOSITORY = Path(__file__).resolve().parent.parent


class ScriptTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="jarvis-script-tests-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        shutil.copytree(REPOSITORY / "scripts", self.root / "scripts")
        # Replace admission only inside this copied fixture checkout. Production has no bypass.
        (self.root / "scripts/lib/test-display.sh").write_text("""isolate_test_display() { :; }
launch_test_app() { open -W -n "$@"; }
wait_test_app() { :; }
stop_test_app() { :; }
""")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.environment = {**{k: v for k, v in os.environ.items() if not k.startswith("JARVIS_TEST_")},
                            "PATH": str(self.bin) + ":" + os.environ["PATH"]}

    def executable(self, path, body):
        path.write_text(body)
        path.chmod(0o700)

    def run_script(self, name, *arguments):
        return subprocess.run(["/bin/bash", str(self.root / "scripts" / name), *arguments],
                              cwd=self.root, env=self.environment, text=True,
                              capture_output=True, timeout=15)


class GuardTests(ScriptTests):
    def test_missing_source_cannot_pass_audio_guard(self):
        for name in ("Sources", "Resources"):
            shutil.copytree(REPOSITORY / name, self.root / name)
        shutil.copy2(REPOSITORY / "Package.swift", self.root / "Package.swift")
        baseline = self.run_script("check-audio-capture-config.sh")
        self.assertEqual(baseline.returncode, 0, baseline.stderr)
        (self.root / "Sources/JarvisCore/Transcription/TranscriptionSession.swift").unlink()
        result = self.run_script("check-audio-capture-config.sh")
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_scans_reject_errors_and_preserve_matches(self):
        (self.root / "source").write_text("allowed\nforbidden\n")
        for pattern, expected in (("forbidden", 1), ("absent", 0), ("[", 2)):
            result = subprocess.run(
                ["/bin/bash", "-euo", "pipefail", "-c",
                 'source scripts/lib/guard.sh; guard_forbid "violation" -nE "$1" source',
                 "guard-test", pattern], cwd=self.root, text=True, capture_output=True)
            self.assertEqual(result.returncode, expected, result.stderr)


class AppBundleTests(ScriptTests):
    def test_development_bundle_assembles_resources_and_keeps_independent_identity(self):
        shutil.copytree(REPOSITORY / "Resources", self.root / "Resources")
        artifacts = self.root / "artifacts"
        artifacts.mkdir()
        for name in ("JarvisApp", "JarvisReferenceHelper", "cliproxyapi"):
            self.executable(artifacts / name, "synthetic binary\n")
        for name in ("Jarvis_JarvisApp.bundle", "Jarvis_JarvisCore.bundle", "ZIPFoundation_ZIPFoundation.bundle"):
            (artifacts / name).mkdir()
            (artifacts / name / "PrivacyInfo.xcprivacy").write_text("synthetic resource")
        sparkle = artifacts / "Sparkle.framework"
        (sparkle / "Versions/Current/XPCServices").mkdir(parents=True)
        (sparkle / "XPCServices").symlink_to("Versions/Current/XPCServices")
        self.environment["SYNTHETIC_ARTIFACTS"] = str(artifacts)
        self.executable(self.bin / "swift", '#!/bin/bash\necho "$SYNTHETIC_ARTIFACTS"\n')
        self.executable(self.bin / "security", "#!/bin/bash\necho 'Jarvis Dev'\n")
        self.executable(self.bin / "codesign", "#!/bin/bash\nexit 0\n")
        (self.root / "scripts/lib/cliproxyapi.sh").write_text('''bundle_cliproxyapi() {
  cp "$SYNTHETIC_ARTIFACTS/cliproxyapi" "$1/Contents/MacOS/cliproxyapi"
}
''')
        script = self.root / "scripts/build-app.sh"
        script.write_text(script.read_text().replace('APP_NAME="Jarvis Dev"', "APP_NAME='Jarvis Dev'"))
        result = self.run_script("build-app.sh", "debug")
        self.assertEqual(result.returncode, 0, result.stderr)
        bundle = self.root / "Jarvis Dev.app"
        with (bundle / "Contents/Info.plist").open("rb") as stream: info = plistlib.load(stream)
        self.assertEqual(info["CFBundleIdentifier"], "com.jarvis.coach.dev")
        self.assertEqual(info["CFBundleName"], "Jarvis Dev")
        self.assertEqual(info["CFBundleDisplayName"], "Jarvis Dev")
        self.assertTrue(info["JarvisDevelopmentBuild"])
        self.assertNotIn("SUFeedURL", info)
        with (self.root / "Resources/Info.plist").open("rb") as stream: production = plistlib.load(stream)
        self.assertEqual(production["CFBundleIdentifier"], "com.jarvis.coach")
        self.assertIn("SUFeedURL", production)
        resources = bundle / "Contents/Resources"
        for name in ("Jarvis.icns", "Jarvis_JarvisApp.bundle", "Jarvis_JarvisCore.bundle",
                     "ZIPFoundation_ZIPFoundation.bundle/PrivacyInfo.xcprivacy",
                     "ReferenceHelper/JarvisReferenceHelper"):
            self.assertTrue((resources / name).exists(), name)
        for name in ("XPCServices", "Versions/Current/XPCServices"):
            self.assertFalse(os.path.lexists(bundle / "Contents/Frameworks/Sparkle.framework" / name))


class HarnessDirectoryTests(ScriptTests):
    def test_private_directory_and_symlink_refusal(self):
        command = ["/bin/bash", "-euo", "pipefail", "-c",
                   'source scripts/lib/harness.sh; create_run_directory settings-harness']
        result = subprocess.run(command, cwd=self.root, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        directory = Path(result.stdout.strip())
        self.assertEqual(directory.parent, self.root / ".jarvis/settings-harness")
        for path in (directory, directory.parent, directory.parent.parent):
            self.assertEqual(path.stat().st_mode & 0o777, 0o700)
        shutil.rmtree(directory.parent)
        directory.parent.symlink_to(self.bin, target_is_directory=True)
        refused = subprocess.run(command, cwd=self.root, text=True, capture_output=True)
        self.assertNotEqual(refused.returncode, 0)


class LiveRunnerTests(ScriptTests):
    def test_empty_live_run_fails_and_completed_run_passes(self):
        self.executable(self.root / "scripts/build-app.sh", "#!/bin/bash\nexit 0\n")
        self.executable(self.bin / "swift", "#!/bin/bash\necho 'warning: No matching test cases were run'\n")
        empty = self.run_script("run-live-tests.sh", "A")
        self.assertNotEqual(empty.returncode, 0, empty.stdout)
        self.executable(self.bin / "swift", """#!/bin/bash
mkdir -p "$JARVIS_LIVE_E2E_RUN_DIR/A"
touch "$JARVIS_LIVE_E2E_RUN_DIR/A/scenario.json" "$JARVIS_LIVE_E2E_RUN_DIR/A/live-e2e-finished"
echo 'G01 pass' > "$JARVIS_LIVE_E2E_RUN_DIR/A/results.txt"
echo '✔ Test run with 1 test passed after 0.001 seconds.'
""")
        completed = self.run_script("run-live-tests.sh", "A")
        self.assertEqual(completed.returncode, 0, completed.stderr + completed.stdout)


class BenchmarkCancellationTests(ScriptTests):
    def test_signals_request_abort_and_reap_detached_app(self):
        self.executable(self.root / "scripts/build-app.sh", "#!/bin/bash\nexit 0\n")
        self.executable(self.bin / "open", "#!" + sys.executable + "\n" + '''
from pathlib import Path
import subprocess, sys
assert '-W' in sys.argv and '-n' in sys.argv
assert './Jarvis Dev.app' in sys.argv
root = Path(sys.argv[sys.argv.index('--benchmark-output-dir') + 1])
app = subprocess.Popen([sys.executable, '-c', """
from pathlib import Path
import sys, time
root = Path(sys.argv[1])
while not (root / 'abort').exists(): time.sleep(.01)
(root / 'sealed').touch()
""", str(root)], start_new_session=True)
(root / 'synthetic-app.pid').write_text(str(app.pid))
(root / 'ready').touch()
app.wait()
''')
        for number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=number.name):
                runner = subprocess.Popen(
                    ["/bin/bash", str(self.root / "scripts/transcription-benchmark.sh"), "standard"],
                    cwd=self.root, env=self.environment, text=True,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
                app_pid = None
                directory = None
                try:
                    deadline = time.monotonic() + 5
                    while time.monotonic() < deadline:
                        ready = list(self.root.glob(".jarvis/transcription-benchmarks/*/ready"))
                        if ready: break
                        time.sleep(.01)
                    self.assertTrue(ready, "synthetic launcher did not become ready")
                    directory = ready[0].parent
                    app_pid = int((directory / "synthetic-app.pid").read_text())
                    os.kill(runner.pid, number)
                    output, error = runner.communicate(timeout=5)
                    self.assertEqual(runner.returncode, 130, error + output)
                    self.assertTrue((directory / "sealed").exists(), "detached app did not seal")
                    with self.assertRaises(ProcessLookupError): os.kill(app_pid, 0)
                    shutil.rmtree(directory)
                finally:
                    if app_pid:
                        try: os.kill(app_pid, signal.SIGKILL)
                        except ProcessLookupError: pass
                    try: os.killpg(runner.pid, signal.SIGKILL)
                    except ProcessLookupError: pass
                    runner.communicate(timeout=5)
                    if directory is not None and directory.exists(): shutil.rmtree(directory)


class AECBuildTests(ScriptTests):
    def test_setup_failure_stops_build_and_stale_cache_is_not_reused(self):
        work = self.root / "aec-cache"
        (work / "wap").mkdir(parents=True)
        self.environment["AEC_WORK"] = str(work)
        self.executable(self.bin / "git", """#!/bin/bash
for destination; do :; done
mkdir -p "$destination"
""")
        self.executable(self.bin / "meson", "#!/bin/bash\nexit 17\n")
        self.executable(self.bin / "ninja", "#!/bin/bash\necho 'ninja must not run after setup failure' >&2\nexit 99\n")
        result = self.run_script("build-aec.sh")
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertTrue((work / "wap-v2.1").is_dir(), "source cache must include the pinned tag")


if __name__ == "__main__":
    unittest.main()
