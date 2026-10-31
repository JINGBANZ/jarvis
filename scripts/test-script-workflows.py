#!/usr/bin/env python3
"""Synthetic command contracts; no signing keys, app launches, capture, or providers."""

import os
import json
from pathlib import Path
import plistlib
import runpy
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


class BuildCacheTests(ScriptTests):
    def setUp(self):
        super().setUp()
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        self.module = runpy.run_path(str(self.root / 'scripts/ci-build-cache.py'))
        self.manifest = self.root / '.build/ci-cache-inputs.json'
        self.source = self.root / 'Source.swift'
        self.source.write_text('let value = 1\n')
        subprocess.run(['git', 'add', 'Source.swift'], cwd=self.root, check=True)

    def test_fresh_checkout_reuses_only_unchanged_input_timestamps(self):
        original = self.source.stat().st_mtime_ns
        self.module['snapshot'](self.root, self.manifest)
        os.utime(self.source, ns=(original + 10_000_000_000,) * 2)
        self.module['restore'](self.root, self.manifest)
        self.assertEqual(self.source.stat().st_mtime_ns, original)
        self.source.write_text('let value = 2\n')
        modified = self.source.stat().st_mtime_ns
        self.module['restore'](self.root, self.manifest)
        self.assertEqual(self.source.stat().st_mtime_ns, modified)
        self.assertEqual(self.source.read_text(), 'let value = 2\n')

    def test_cache_miss_and_deleted_or_untracked_inputs_are_untouched(self):
        self.module['restore'](self.root, self.manifest)
        self.module['snapshot'](self.root, self.manifest)
        self.source.unlink()
        untracked = self.root / 'untracked'
        untracked.write_text('private fixture')
        original = untracked.stat().st_mtime_ns
        entries = json.loads(self.manifest.read_text())
        entries['untracked'] = entries['Source.swift']
        self.manifest.write_text(json.dumps(entries))
        self.module['restore'](self.root, self.manifest)
        self.assertFalse(self.source.exists())
        self.assertEqual(untracked.stat().st_mtime_ns, original)

    def test_symlink_does_not_change_its_target(self):
        self.module['snapshot'](self.root, self.manifest)
        self.source.unlink()
        target = self.root / 'target'
        target.write_text('let value = 1\n')
        self.source.symlink_to(target)
        original = target.stat().st_mtime_ns
        self.module['restore'](self.root, self.manifest)
        self.assertEqual(target.stat().st_mtime_ns, original)


class GuardTests(ScriptTests):
    def test_process_boundary_guard_rejects_context_import_and_transitive_dependency(self):
        guard = runpy.run_path(str(self.root / 'scripts/check-process-launching.py'))
        package = {'targets': [{'name': name, 'dependencies': []}
                              for name in (*guard['PRODUCTION_TARGETS'], 'Intermediate')]}
        for area in guard['SOURCE_AREAS']:
            (self.root / 'Sources' / area).mkdir(parents=True)
        check = guard['check_boundary']
        check(self.root, package)
        source = self.root / 'Sources/JarvisProcess/Fixture.swift'
        for forbidden in ('import JarvisTestSupport',
                          'let context = environment["JARVIS_TEST_RUN_SOCKET"]',
                          'TestCommandOwnership.makeLauncher()'):
            source.write_text(forbidden)
            with self.assertRaisesRegex(ValueError, 'test ownership in production logic'):
                check(self.root, package)
        source.unlink()
        package['targets'][0]['dependencies'] = [{'byName': ['Intermediate', None]}]
        package['targets'][-1]['dependencies'] = [{'target': ['JarvisTestSupport', None]}]
        with self.assertRaisesRegex(ValueError, 'depends on JarvisTestSupport'):
            check(self.root, package)

    def test_non_debug_tests_refused_before_admission_in_both_entrypoints(self):
        # Admission and every Python command must remain untouched, even under a foreign owner.
        marker = self.root / 'admission-touched'
        (self.root / 'scripts/lib/test-display.sh').write_text(
            'isolate_test_display() { touch admission-touched; exit 99; }\n')
        self.executable(self.bin / 'python3', '#!/bin/bash\ntouch admission-touched\nexit 99\n')
        self.environment.update(JARVIS_TEST_RUN_SOCKET='/foreign-owner', JARVIS_TEST_RUN_TOKEN='foreign')
        for entry in ('run-tests.sh', 'run-ci-tests.sh'):
            for flags in (['-c', 'release'], ['--configuration', 'release'],
                          ['--configuration=release'], ['-crelease'], ['-c=release'],
                          ['-c', 'debug', '--configuration=release'],
                          ['-c', 'release', '-c', 'debug'], ['-c'], ['--configuration=']):
                with self.subTest(entry=entry, flags=flags):
                    result = self.run_script(entry, *flags)
                    self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                    self.assertIn('require debug configuration', result.stderr)
                    self.assertFalse(marker.exists())
            for flags in ([], ['-c', 'debug'], ['--configuration=debug'], ['-cdebug'], ['-c=debug']):
                with self.subTest(entry=entry, flags=flags):
                    result = self.run_script(entry, *flags)
                    self.assertEqual(result.returncode, 99, result.stdout + result.stderr)
                    self.assertTrue(marker.exists())
                    marker.unlink()

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


class EntrypointAdmissionTests(ScriptTests):
    def setUp(self):
        super().setUp()
        shutil.copy2(REPOSITORY / 'scripts/lib/test-display.sh', self.root / 'scripts/lib')
        (self.root / 'scripts/test-display/supervisor.py').write_text('''import json, os, subprocess, sys
from pathlib import Path
operation, *arguments = sys.argv[1:]
with open('admission.jsonl', 'a') as stream:
    stream.write(json.dumps([operation, *arguments]) + '\\n')
if operation == 'run':
    entry, *arguments = arguments
    environment = {**os.environ, 'JARVIS_TEST_RUN_SOCKET': 'fixture', 'JARVIS_TEST_RUN_TOKEN': 'fixture'}
    result = subprocess.run(['/bin/bash', str(Path(__file__).resolve().parent.parent / entry), *arguments],
                            env=environment)
    sys.exit(result.returncode)
if operation not in ('admit', 'transition-reference'):
    raise AssertionError(operation)
''')
        self.executable(self.root / 'scripts/build-app.sh', '''#!/bin/bash
echo '["build"]' >> admission.jsonl
exit 99
''')
        self.environment['EVAL_AGENT'] = 'codex'

    def test_help_and_invalid_arguments_do_not_enter_supervisor(self):
        cases = (
            ('run-live-tests.sh', ['--help'], 0),
            ('run-live-tests.sh', ['-h'], 0),
            ('run-live-tests.sh', ['unknown'], 2),
            ('run-live-tests.sh', ['--provider'], 2),
            ('run-live-tests.sh', ['--provider=unknown'], 2),
            ('run-live-tests.sh', ['B', '--evaluate'], 2),
            ('run-reference-tests.sh', ['unknown'], 2),
            ('run-capture-privacy-tests.sh', ['0'], 2),
            ('run-capture-privacy-tests.sh', ['1', '2'], 2),
            ('transcription-benchmark.sh', [], 2),
            ('transcription-benchmark.sh', ['unknown'], 2),
            ('transcription-benchmark.sh', ['standard', '--repetitions'], 2),
            ('transcription-benchmark.sh', ['standard', '--repetitions', '2'], 2),
            ('transcription-benchmark.sh', ['turns', '--filter', 'arm'], 2),
        )
        for context in ({}, {'JARVIS_TEST_RUN_SOCKET': 'foreign', 'JARVIS_TEST_RUN_TOKEN': 'foreign'}):
            self.environment.update(context)
            for entry, arguments, status in cases:
                with self.subTest(entry=entry, arguments=arguments, inherited=bool(context)):
                    result = self.run_script(entry, *arguments)
                    self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                    self.assertFalse((self.root / 'admission.jsonl').exists())
                    self.assertFalse((self.root / '.jarvis').exists())

    def test_valid_arguments_survive_reentry_and_reference_transition(self):
        cases = (
            ('run-live-tests.sh', ['A', '--provider=openai', '--keep-going']),
            ('run-live-tests.sh', ['A', '--provider', 'openai', '--evaluate']),
            ('run-live-tests.sh', ['REF01']),
            ('run-reference-tests.sh', ['REF03']),
            ('run-capture-privacy-tests.sh', ['2']),
            ('transcription-benchmark.sh', ['standard', '--repetitions', '4', '--filter', 'arm with spaces']),
        )
        for entry, arguments in cases:
            with self.subTest(entry=entry, arguments=arguments):
                result = self.run_script(entry, *arguments)
                self.assertEqual(result.returncode, 99, result.stdout + result.stderr)
                expected = [['run', entry, *arguments], ['admit']]
                if arguments == ['REF01']:
                    expected += [['transition-reference', 'REF01'], ['admit']]
                expected += [['build']]
                marker = self.root / 'admission.jsonl'
                self.assertEqual([json.loads(row) for row in marker.read_text().splitlines()], expected)
                marker.unlink()


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


class UniversalAppTests(ScriptTests):
    def setUp(self):
        super().setUp()
        source = self.root / "main.c"
        source.write_text("int main(void) { return 0; }\n")
        self.slices = {}
        for architecture in ("arm64", "x86_64"):
            binary = self.root / architecture
            subprocess.run(["xcrun", "clang", "-arch", architecture,
                            "-mmacosx-version-min=14.2", str(source), "-o", str(binary)],
                           check=True, capture_output=True)
            self.slices[architecture] = binary
        self.universal = self.root / "universal"
        subprocess.run(["lipo", "-create", *map(str, self.slices.values()),
                        "-output", str(self.universal)], check=True, capture_output=True)

    def test_every_bundled_executable_requires_both_architectures(self):
        app = self.root / "Jarvis.app"
        binaries = (
            "Contents/MacOS/JarvisApp", "Contents/MacOS/cliproxyapi",
            "Contents/Resources/ReferenceHelper/JarvisReferenceHelper",
            "Contents/Frameworks/Sparkle.framework/Versions/Current/Sparkle",
            "Contents/Frameworks/Sparkle.framework/Versions/Current/Autoupdate",
            "Contents/Frameworks/Sparkle.framework/Versions/Current/Updater.app/Contents/MacOS/Updater",
        )
        for name in binaries:
            destination = app / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(self.universal, destination)
        passed = self.run_script("check-universal-app.sh", str(app))
        self.assertEqual(passed.returncode, 0, passed.stderr)
        for name in binaries:
            for architecture, thin in self.slices.items():
                with self.subTest(binary=name, architecture=architecture):
                    shutil.copy2(thin, app / name)
                    refused = self.run_script("check-universal-app.sh", str(app))
                    self.assertNotEqual(refused.returncode, 0)
                    self.assertIn(name, refused.stderr)
            shutil.copy2(self.universal, app / name)

    def test_sdk_guard_checks_both_slices_and_rejects_non_binaries(self):
        for architecture in self.slices:
            subprocess.run(["xcrun", "vtool", "-set-build-version", "macos", "14.2", "26.0",
                            "-replace", "-output", str(self.slices[architecture]),
                            str(self.slices[architecture])], check=True, capture_output=True)
        subprocess.run(["lipo", "-create", *map(str, self.slices.values()),
                        "-output", str(self.universal)], check=True, capture_output=True)
        passed = self.run_script("check-release-sdk.sh", str(self.universal))
        self.assertEqual(passed.returncode, 0, passed.stderr)
        for architecture in self.slices:
            old = self.root / "old"
            subprocess.run(["xcrun", "vtool", "-set-build-version", "macos", "14.2", "25.0",
                            "-replace", "-output", str(old), str(self.slices[architecture])],
                           check=True, capture_output=True)
            other = next(path for arch, path in self.slices.items() if arch != architecture)
            subprocess.run(["lipo", "-create", str(old), str(other),
                            "-output", str(self.universal)], check=True, capture_output=True)
            refused = self.run_script("check-release-sdk.sh", str(self.universal))
            self.assertNotEqual(refused.returncode, 0)
            self.assertIn("SDK 25.0", refused.stderr)
        invalid = self.root / "not-a-binary"
        invalid.write_text("invalid")
        self.assertNotEqual(self.run_script("check-release-sdk.sh", str(invalid)).returncode, 0)

    def test_reference_helper_uses_the_supplied_universal_build(self):
        artifacts = self.root / "universal-build"
        privacy = artifacts / "ZIPFoundation_ZIPFoundation.bundle"
        privacy.mkdir(parents=True)
        (privacy / "PrivacyInfo.xcprivacy").write_text("privacy fixture")
        shutil.copy2(self.universal, artifacts / "JarvisReferenceHelper")
        self.executable(self.bin / "swift", "#!/bin/bash\nexit 99\n")
        result = subprocess.run(
            ["/bin/bash", "-euo", "pipefail", "-c",
             'source scripts/lib/reference-helper.sh; bundle_reference_helper app debug "$1"',
             "test", str(artifacts)], cwd=self.root, env=self.environment,
            text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        bundled = self.root / "app/Contents/Resources/ReferenceHelper/JarvisReferenceHelper"
        self.assertEqual(bundled.read_bytes(), self.universal.read_bytes())


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
    def check_cancellation(self, numbers, ignore_abort=False):
        self.executable(self.root / "scripts/build-app.sh", "#!/bin/bash\nexit 0\n")
        script = self.root / "scripts/transcription-benchmark.sh"
        script.write_text(script.read_text().replace('sleep 10', 'sleep 0.4'))
        self.environment.update(FIXTURE_PYTHON=sys.executable,
                                FIXTURE_IGNORE_ABORT=str(int(ignore_abort)))
        (self.root / "scripts/lib/test-display.sh").write_text('''isolate_test_display() { :; }
launch_test_app() { open -W -n "$@"; }
stop_test_app() { "$FIXTURE_PYTHON" "$PWD/stop.py" "$RUN_DIR"; }
''')
        (self.root / "stop.py").write_text('''from pathlib import Path
import os, signal, sys, time
root = Path(sys.argv[1])
(root / 'stop-called').touch()
pid = int((root / 'synthetic-app.pid').read_text())
try: os.kill(pid, signal.SIGTERM)
except ProcessLookupError: sys.exit(0)
deadline = time.monotonic() + .2
while time.monotonic() < deadline:
    try: os.kill(pid, 0)
    except ProcessLookupError: sys.exit(0)
    time.sleep(.01)
os.kill(pid, signal.SIGKILL)
''')
        self.executable(self.bin / "open", "#!" + sys.executable + "\n" + '''
from pathlib import Path
import subprocess, sys, time
assert '-W' in sys.argv and '-n' in sys.argv
assert './Jarvis Dev.app' in sys.argv
root = Path(sys.argv[sys.argv.index('--benchmark-output-dir') + 1])
app = subprocess.Popen([sys.executable, '-c', """
from pathlib import Path
import os, signal, sys, time
root = Path(sys.argv[1])
ignore = os.environ['FIXTURE_IGNORE_ABORT'] == '1'
if ignore: signal.signal(signal.SIGTERM, signal.SIG_IGN)
(root / 'app-ready').touch()
if ignore: time.sleep(30)
while not (root / 'abort').exists(): time.sleep(.01)
time.sleep(.15)
(root / 'sealed').touch()
""", str(root)], start_new_session=True)
(root / 'synthetic-app.pid').write_text(str(app.pid))
while not (root / 'app-ready').exists(): time.sleep(.01)
(root / 'ready').touch()
app.wait()
''')
        for number in numbers:
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
                    self.assertTrue((directory / "abort").exists(), "abort was not requested")
                    self.assertTrue((directory / "stop-called").exists(), "exact stop was skipped")
                    self.assertEqual((directory / "sealed").exists(), not ignore_abort,
                                     "cooperative app lost its evidence-drain grace")
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

    def test_signals_request_abort_and_reap_detached_app(self):
        self.check_cancellation((signal.SIGHUP, signal.SIGINT, signal.SIGTERM))

    def test_shell_only_term_bounds_an_app_ignoring_abort_and_term(self):
        self.check_cancellation((signal.SIGTERM,), ignore_abort=True)


class AECBuildTests(ScriptTests):
    def test_setup_failure_stops_build_and_stale_cache_is_not_reused(self):
        work = self.root / "aec-cache"
        (work / "wap").mkdir(parents=True)
        self.environment["AEC_WORK"] = str(work)
        self.executable(self.bin / "git", """#!/bin/bash
if [[ "$1" == -C ]]; then
  echo 846fe90a289f58b7c9303a635142aa2c7caa93e5
  exit 0
fi
for destination; do :; done
mkdir -p "$destination"
""")
        self.executable(self.bin / "meson", "#!/bin/bash\nexit 17\n")
        self.executable(self.bin / "ninja", "#!/bin/bash\necho 'ninja must not run after setup failure' >&2\nexit 99\n")
        result = self.run_script("build-aec.sh")
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertTrue((work / "wap-v2.1").is_dir(), "source cache must include the pinned tag")

    def test_source_commit_mismatch_stops_before_build(self):
        work = self.root / "aec-cache"
        (work / "wap-v2.1").mkdir(parents=True)
        self.environment["AEC_WORK"] = str(work)
        self.executable(self.bin / "git", "#!/bin/bash\necho wrong-commit\n")
        self.executable(self.bin / "meson", "#!/bin/bash\nexit 99\n")
        result = self.run_script("build-aec.sh")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("pinned commit", result.stderr)


if __name__ == "__main__":
    unittest.main()
