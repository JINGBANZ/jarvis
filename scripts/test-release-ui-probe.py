#!/usr/bin/env python3
"""Check fail-closed result accounting without launching apps or touching TCC."""

from pathlib import Path
import contextlib
import io
import json
import os
import plistlib
import runpy
import shutil
from types import SimpleNamespace
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


PROBE = runpy.run_path(str(Path(__file__).with_name("probe-release-ui.py")))
ACCOUNT = runpy.run_path(str(Path(__file__).with_name("prepare-release-ui-account.py")))
ACCOUNT_GLOBALS = ACCOUNT["prepare"].__globals__


class ProbeResultsTests(unittest.TestCase):
    def test_subprocess_errors_do_not_publish_private_ui_logs(self):
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / 'test.log'
            with contextlib.redirect_stderr(io.StringIO()) as errors:
                with self.assertRaisesRegex(ValueError, '^Private subprocess failed: test.log$'):
                    PROBE['run']([sys.executable, '-c', 'print("private-ui-value"); raise SystemExit(1)'],
                                 timeout=5, log=log)
            self.assertNotIn('private-ui-value', errors.getvalue())

    def test_timeout_reaps_owned_detached_helper_without_touching_unrelated_process(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve()
            helper = directory / 'owned-sleep'
            subprocess.run(['cc', '-x', 'c', '-o', str(helper), '-'], check=True, capture_output=True,
                           input='#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n',
                           text=True, timeout=30)
            unrelated = subprocess.Popen(['/bin/sleep', '30'])
            try:
                command = [sys.executable, '-c',
                           'import pathlib, subprocess, sys, time; '
                           'child=subprocess.Popen([sys.argv[1], "30"], start_new_session=True); '
                           'pathlib.Path(sys.argv[2]).write_text(str(child.pid)); time.sleep(30)',
                           str(helper), str(directory / 'child.pid')]
                with self.assertRaisesRegex(ValueError, 'cleanup did not finish normally'):
                    PROBE['run_ui'](command, timeout=1, log=directory / 'test.log',
                                    roots=[directory], evidence=directory)
                receipt = json.loads((directory / 'cleanup.json').read_text())
                self.assertGreaterEqual(receipt['observedCount'], 2)
                self.assertIs(receipt['forcedCleanup'], True)
                self.assertIs(receipt['allOwnedProcessesAbsent'], True)
                command_receipt = json.loads((directory / 'ui-command.json').read_text())
                self.assertIsNone(command_receipt['returnCode'])
                self.assertIs(command_receipt['timedOut'], True)
                self.assertEqual(command_receipt['failurePhase'], 'command-deadline')
                self.assertEqual(command_receipt['failureKind'], 'validation')
                self.assertGreater(command_receipt['startedUptime'], 0)
                self.assertGreaterEqual(command_receipt['elapsedSeconds'], 1)
                self.assertIsNone(unrelated.poll())
            finally:
                unrelated.terminate()
                unrelated.wait(timeout=5)

    def test_cleanup_failure_preserves_closed_original_monitor_refusal(self):
        class Refused(RuntimeError):
            pass
        alive = True
        def signal_owned(_identity, _number):
            nonlocal alive
            alive = False
        ownership = {'Refused': Refused, 'birth': lambda pid: {'pid': pid, 'start': 'fixed'},
                     'same': lambda _: alive, 'signal_owned': signal_owned}
        child = mock.Mock(pid=42)
        child.poll.side_effect = lambda: None if alive else -15
        ticks = iter(range(100))
        globals_ = PROBE['run_ui'].__globals__
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with mock.patch.dict(globals_, owned_processes=mock.Mock(side_effect=[[], Refused('private native detail'), [], []])), \
                    mock.patch.object(PROBE['runpy'], 'run_path', return_value=ownership), \
                    mock.patch.object(PROBE['subprocess'], 'Popen', return_value=child), \
                    mock.patch.object(PROBE['time'], 'monotonic', side_effect=lambda: next(ticks)), \
                    mock.patch.object(PROBE['time'], 'sleep'):
                with self.assertRaisesRegex(ValueError, 'cleanup did not finish normally'):
                    PROBE['run_ui'](['private-command'], timeout=100, log=directory / 'test.log', roots=[directory], evidence=directory)
            receipt = json.loads((directory / 'ui-command.json').read_text())
            self.assertEqual(receipt['failurePhase'], 'process-monitor')
            self.assertEqual(receipt['failureKind'], 'ownership-refused')
            self.assertIs(receipt['timedOut'], False)
            self.assertIsNone(receipt['returnCode'])
            self.assertNotIn('private', json.dumps(receipt))
            self.assertIs(json.loads((directory / 'cleanup.json').read_text())['forcedCleanup'], True)

    def test_repeated_inventory_refusal_still_reaps_known_owned_command(self):
        class Refused(RuntimeError):
            pass
        alive = True
        def signal_owned(_identity, _number):
            nonlocal alive
            alive = False
        ownership = {'Refused': Refused, 'birth': lambda pid: {'pid': pid, 'start': 'fixed'},
                     'same': lambda _: alive, 'signal_owned': signal_owned}
        child = mock.Mock(pid=42)
        child.poll.side_effect = lambda: None if alive else -15
        ticks = iter(range(100))
        globals_ = PROBE['run_ui'].__globals__
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with mock.patch.dict(globals_, owned_processes=mock.Mock(side_effect=[[], Refused('private native detail'), Refused('private final detail'), Refused('private final detail')])), \
                    mock.patch.object(PROBE['runpy'], 'run_path', return_value=ownership), \
                    mock.patch.object(PROBE['subprocess'], 'Popen', return_value=child), \
                    mock.patch.object(PROBE['time'], 'monotonic', side_effect=lambda: next(ticks)), \
                    mock.patch.object(PROBE['time'], 'sleep'):
                with self.assertRaisesRegex(ValueError, 'cleanup did not finish normally'):
                    PROBE['run_ui'](['private-command'], timeout=100, log=directory / 'test.log', roots=[directory], evidence=directory)
            receipt = json.loads((directory / 'ui-command.json').read_text())
            self.assertEqual(receipt['failurePhase'], 'process-monitor')
            self.assertEqual(receipt['failureKind'], 'ownership-refused')
            self.assertIs(receipt['timedOut'], False)
            self.assertIsNone(receipt['returnCode'])
            self.assertNotIn('private', json.dumps(receipt))
            cleanup = json.loads((directory / 'cleanup.json').read_text())
            self.assertIs(cleanup['forcedCleanup'], True)
            self.assertIs(cleanup['allOwnedProcessesAbsent'], False)
            child.wait.assert_called_once_with(timeout=5)
            self.assertFalse(alive)

    def test_required_journey_case_passes(self):
        PROBE["validate_summary"]({
            "totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0,
        })

    def test_missing_partial_failed_skipped_or_mistyped_results_are_rejected(self):
        complete = {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0}
        for replacement in ({}, {"totalTestCount": 0}, {"totalTestCount": 2, "passedTests": 2},
                            {"passedTests": 2}, {"failedTests": 1}, {"skippedTests": 1},
                            {"failedTests": False}, {"passedTests": "1"}):
            with self.subTest(replacement=replacement):
                summary = {**complete, **replacement} if replacement else {}
                with self.assertRaises(ValueError):
                    PROBE["validate_summary"](summary)

    def test_environment_reaches_exactly_the_external_test_target(self):
        manifest = {"TestConfigurations": [{"TestTargets": [{
            "TestBundlePath": "__TESTROOT__/ReleaseReadiness.xctest",
            "EnvironmentVariables": {"EXISTING": "value"},
        }]}], "Metadata": {"EnvironmentVariables": {"UNRELATED": "value"}}}
        environment = {"JARVIS_READINESS_APP_PATH": "/Users/runner/Applications/Jarvis.app"}
        self.assertEqual(PROBE["inject_environment"](manifest, environment), 1)
        target = manifest["TestConfigurations"][0]["TestTargets"][0]
        self.assertEqual(target["EnvironmentVariables"], {"EXISTING": "value", **environment})
        self.assertIs(target["TestTimeoutsEnabled"], True)
        self.assertEqual(target["MaximumTestExecutionTimeAllowance"], 1200)
        self.assertEqual(manifest["Metadata"]["EnvironmentVariables"], {"UNRELATED": "value"})


class BasicJourneyTests(unittest.TestCase):
    def receipt(self, phase="fresh"):
        models = [("GPT Transcribe", 1)] if phase == "predecessor" else [
            (model, cycle) for model in ("GPT Transcribe", "GPT-4o Transcribe") for cycle in (1, 2)]
        return {"schemaVersion": 1, "phase": phase, "skills": 5,
                "nativeProcessVerified": True, "normalQuit": True, "defaultsRestored": True,
                "sessions": [{"model": model, "cycle": cycle, "fullActive": True, "freshSession": True,
                              "stimulusTranscript": True, "shortcutHint": True, "stopped": True,
                              "auditComplete": True} for model, cycle in models]}

    def test_each_fixed_journey_requires_all_model_cycles_and_positive_proof(self):
        for phase in ("fresh", "predecessor", "upgrade"):
            valid = self.receipt(phase)
            PROBE["validate_journey"](valid, phase)
            for mutate in (
                lambda r: r["sessions"].pop(),
                lambda r: r.update(phase="other"),
                lambda r: r.update(skills=True),
                lambda r: r.update(normalQuit=False),
                lambda r: r["sessions"][0].update(model="GPT-4o Transcribe"),
                lambda r: r["sessions"][0].update(cycle=True),
                lambda r: r["sessions"][0].update(freshSession=False),
                lambda r: r["sessions"][0].update(shortcutHint=1),
                lambda r: r["sessions"][0].update(stimulusTranscript=False),
                lambda r: r["sessions"][0].update(auditComplete=False),
                lambda r: r.update(rawTranscript="private"),
                lambda r: r.update(manualCoaching=True),
            ):
                receipt = json.loads(json.dumps(valid))
                mutate(receipt)
                with self.subTest(phase=phase, receipt=receipt), self.assertRaises(ValueError):
                    PROBE["validate_journey"](receipt, phase)
        duplicate = self.receipt()
        duplicate["sessions"][1] = duplicate["sessions"][0]
        with self.assertRaises(ValueError):
            PROBE["validate_journey"](duplicate, "fresh")

    def test_secret_is_consumed_before_children_and_never_allowed_in_manifest(self):
        environment = {"RELEASE_READINESS_OPENAI_API_KEY": "synthetic-test-key-123456789",
                       "OPENAI_API_KEY": "another-synthetic-key", "KEEP": "value"}
        self.assertEqual(PROBE["take_key"](environment), b"synthetic-test-key-123456789")
        self.assertEqual(environment, {"KEEP": "value"})
        for name in ("OPENAI_API_KEY", "RELEASE_READINESS_OPENAI_API_KEY"):
            with self.assertRaisesRegex(ValueError, "never enter"):
                PROBE["inject_environment"]({"TestBundlePath": "fixed"}, {name: "synthetic"})
        with mock.patch.dict(os.environ, {"RELEASE_READINESS_OPENAI_API_KEY": "", "OPENAI_API_KEY": "fallback"}, clear=True), \
                mock.patch.object(PROBE["subprocess"], "Popen") as child:
            with self.assertRaisesRegex(ValueError, "dedicated protected"):
                PROBE["main"]()
            child.assert_not_called()
            self.assertNotIn("OPENAI_API_KEY", os.environ)
            self.assertNotIn("RELEASE_READINESS_OPENAI_API_KEY", os.environ)

    def test_private_key_writer_refuses_existing_or_symlink_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            key = directory / "key"
            PROBE["private_write"](key, b"synthetic")
            self.assertEqual(key.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError):
                PROBE["private_write"](key, b"replacement")
            link = directory / "link"
            link.symlink_to(key)
            with self.assertRaises(OSError):
                PROBE["private_write"](link, b"replacement")
            self.assertEqual(key.read_bytes(), b"synthetic")

    def test_upgrade_version_comparison_requires_stable_ordered_versions(self):
        self.assertLess(PROBE["version_tuple"]("0.5.14"), PROBE["version_tuple"]("0.5.15"))
        self.assertLess(PROBE["version_tuple"]("0.9.99"), PROBE["version_tuple"]("0.10.0"))
        for value in (None, True, "v0.5.14", "0.5.14-dev", "00.5.14", "0.5", "0.5.14\n"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                PROBE["version_tuple"](value)

    def test_upgrade_preserves_real_preferences_key_and_completed_session(self):
        with tempfile.TemporaryDirectory() as temporary:
            profile = Path(temporary)
            preferences = profile / "preferences.plist"
            preferences.write_bytes(plistlib.dumps({"onboarding.completed": True, "coaching.mode": "automatic",
                                                     "transcription.openai.model": "gpt-transcribe", "unrelated": 1}))
            key = profile / "openai-api-key"
            key.write_bytes(b"synthetic-secret")
            session = profile / "sessions/real-session"
            session.mkdir(parents=True)
            activity = session / "jarvis-activity.jsonl"
            activity.write_text('{"k":"sessionEnded"}\n')
            health = session / "audit-health.json"
            health.write_text('{"state":"complete"}')
            snapshot = PROBE["profile_snapshot"](profile, preferences)
            self.assertNotIn("synthetic-secret", repr(snapshot))
            PROBE["require_preserved"](profile, preferences, snapshot, check_preferences=True)
            for path, changed in ((key, b"changed-key"), (activity, b"changed-history"), (health, b"{}")):
                original = path.read_bytes()
                path.write_bytes(changed)
                with self.subTest(path=path.name), self.assertRaises(ValueError):
                    PROBE["require_preserved"](profile, preferences, snapshot, check_preferences=False)
                path.write_bytes(original)
            values = plistlib.loads(preferences.read_bytes())
            values["coaching.mode"] = "manual"
            preferences.write_bytes(plistlib.dumps(values))
            with self.assertRaisesRegex(ValueError, "user preferences"):
                PROBE["require_preserved"](profile, preferences, snapshot, check_preferences=True)
            self.assertEqual(PROBE["profile_snapshot"](profile, preferences)[0]["coaching.mode"], "manual")
            del values["coaching.mode"]
            preferences.write_bytes(plistlib.dumps(values))
            snapshot = PROBE["profile_snapshot"](profile, preferences)
            self.assertNotIn("coaching.mode", snapshot[0])
            PROBE["require_preserved"](profile, preferences, snapshot, check_preferences=True)
            values["onboarding.completed"] = False
            preferences.write_bytes(plistlib.dumps(values))
            with self.assertRaisesRegex(ValueError, "genuinely used"):
                PROBE["profile_snapshot"](profile, preferences)


class FixedPhaseOrchestrationTests(unittest.TestCase):
    def run_driver(self, *, setup=False, predecessor_version="0.5.14"):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        home = root / "home"
        (home / "Library/Preferences").mkdir(parents=True)
        (home / "Library/Application Support").mkdir()
        candidate = root / "candidate.app"
        predecessor = root / "predecessor.app"
        candidate.mkdir()
        predecessor.mkdir()
        globals_ = PROBE["main"].__globals__
        phases = []
        def path(value):
            return home if value == "/Users/runner" else Path(value)
        def command(arguments, **_kwargs):
            self.assertNotIn("RELEASE_READINESS_OPENAI_API_KEY", os.environ)
            self.assertNotIn("OPENAI_API_KEY", os.environ)
            if arguments[0] == "/usr/bin/uname":
                return "arm64\n"
            if arguments[0] == "/usr/bin/say":
                Path(arguments[arguments.index("-o") + 1]).write_bytes(b"private synthetic audio")
            elif arguments[0] == "/usr/bin/ditto":
                shutil.copytree(arguments[1], arguments[2])
            elif arguments[0] == "/usr/bin/defaults":
                (home / "Library/Preferences/com.jarvis.coach.plist").unlink()
            return ""
        def phase(name, _version, _app, _evidence, _derived, _template, _speech, _architecture, upgrade=None):
            phases.append(name)
            profile = home / "Library/Application Support/Jarvis"
            self.assertEqual((profile / "openai-api-key").read_bytes(), b"synthetic-protected-key-123456")
            preferences = home / "Library/Preferences/com.jarvis.coach.plist"
            if name == "upgrade":
                self.assertTrue((profile / "sessions/predecessor/jarvis-activity.jsonl").exists())
                self.assertIsNotNone(upgrade)
                self.assertNotIn("coaching.mode", plistlib.loads(upgrade.read_bytes()))
            preferences.write_bytes(plistlib.dumps({"onboarding.completed": True}))
            session = profile / "sessions" / name
            session.mkdir(parents=True)
            (session / "jarvis-activity.jsonl").write_text('{"k":"sessionEnded"}\n')
            (session / "audit-health.json").write_text('{"state":"complete"}')
        argv = ["probe-release-ui.py", "--setup-candidate" if setup else "--candidate", str(candidate)]
        if not setup:
            argv += ["--predecessor", str(predecessor)]
        environment = {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted",
                       "RELEASE_READINESS_OPENAI_API_KEY": "synthetic-protected-key-123456"}
        with mock.patch.dict(os.environ, environment, clear=True), mock.patch.object(sys, "argv", argv), \
                mock.patch.object(sys, "platform", "darwin"), \
                mock.patch.object(PROBE["pwd"], "getpwuid", return_value=SimpleNamespace(pw_name="runner", pw_dir="/Users/runner")), \
                mock.patch.object(PROBE["runpy"], "run_path", return_value={}), \
                mock.patch.dict(globals_, ROOT=root, Path=path, run=command,
                                verify_app=lambda app, _: "0.5.15" if app == candidate else predecessor_version,
                                build_ui=lambda evidence, _: (evidence / "derived", evidence / "manifest"),
                                run_phase=phase, owned_processes=lambda *_: []):
            PROBE["main"]()
        evidence = next((root / ".jarvis/release-ui-probe").iterdir())
        self.assertFalse((home / "Library/Application Support/Jarvis/openai-api-key").exists())
        return phases, evidence

    def test_full_run_requires_fresh_predecessor_upgrade_and_retains_real_profile(self):
        phases, evidence = self.run_driver()
        self.assertEqual(phases, ["fresh", "predecessor", "upgrade"])
        receipt = json.loads((evidence / "readiness.json").read_text())
        self.assertIs(receipt["releaseReady"], True)
        self.assertIs(receipt["retainedSessionHistory"], True)
        self.assertFalse((evidence / "setup-feasibility.json").exists())

    def test_setup_can_never_produce_release_readiness(self):
        phases, evidence = self.run_driver(setup=True)
        self.assertEqual(phases, ["fresh"])
        receipt = json.loads((evidence / "setup-feasibility.json").read_text())
        self.assertEqual(receipt["check"], "setup-feasibility")
        self.assertIs(receipt["releaseReady"], False)
        self.assertFalse((evidence / "readiness.json").exists())

    def test_full_run_refuses_same_or_newer_predecessor(self):
        for version in ("0.5.15", "0.6.0"):
            with self.subTest(version=version), self.assertRaisesRegex(ValueError, "older predecessor"):
                self.run_driver(predecessor_version=version)


class NativeAuthorizationTests(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.dict(PROBE["collect_authorization"].__globals__, {"describe_focus_owner": mock.Mock()})
        patcher.start()
        self.addCleanup(patcher.stop)

    def receipt(self, *, authorized=True, stage="complete"):
        return {"authorized": authorized, "stage": stage, "diagnostics": {
            "uiElementsEnabled": True, "processCount": 1, "formCount": 1,
            "usernameCount": 1, "secureCount": 1, "modifySettingsCount": 1,
            "recognizedHeading": True, "recognizedText": True,
            "focusAvailable": True, "focusIsSecureField": True,
            "focusOwnerIsAuthenticationAgent": True, "focusOwnerIsSystemSettings": False,
            "focusOwnerIsSecurityPrivacyExtension": False,
            "focusOwnerPID": 12345, "focusError": 0,
            "usernameOwnerPID": 12345, "usernameOwnerIsAuthenticationAgent": True,
            "usernameOwnerIsSystemSettings": False, "usernameOwnerIsSecurityPrivacyExtension": False,
        }}

    def test_only_allowlisted_scalar_receipts_are_accepted(self):
        receipt = self.receipt()
        self.assertEqual(PROBE["validate_authorization_receipt"](json.dumps(receipt)), receipt)
        for replacement in ({"extra": "private"}, {"stage": []}, {"stage": "private-error"},
                            {"authorized": 1}, {"authorized": False}, {"diagnostics": {}},
                            {"diagnostics": {**receipt["diagnostics"], "processCount": True}},
                            {"diagnostics": {**receipt["diagnostics"], "processCount": 257}},
                            {"diagnostics": {**receipt["diagnostics"], "secureCount": 0}},
                            {"diagnostics": {**receipt["diagnostics"], "formCount": 0}},
                            {"diagnostics": {**receipt["diagnostics"], "focusAvailable": False}},
                            {"diagnostics": {**receipt["diagnostics"], "focusIsSecureField": False}},
                            {"diagnostics": {**receipt["diagnostics"], "focusOwnerIsAuthenticationAgent": False}},
                            {"diagnostics": {**receipt["diagnostics"], "focusOwnerIsSystemSettings": True}},
                            {"diagnostics": {**receipt["diagnostics"], "focusOwnerIsSecurityPrivacyExtension": True}},
                            {"diagnostics": {**receipt["diagnostics"], "focusOwnerPID": 2_147_483_648}},
                            {"diagnostics": {**receipt["diagnostics"], "focusOwnerPID": True}},
                            {"diagnostics": {**receipt["diagnostics"], "focusOwnerPID": 0}},
                            {"diagnostics": {**receipt["diagnostics"], "usernameOwnerPID": 0}},
                            {"diagnostics": {**receipt["diagnostics"], "usernameOwnerPID": True}},
                            {"diagnostics": {**receipt["diagnostics"], "usernameOwnerIsAuthenticationAgent": False}},
                            {"diagnostics": {**receipt["diagnostics"], "usernameOwnerIsSystemSettings": True}},
                            {"diagnostics": {**receipt["diagnostics"], "focusError": -1}},
                            {"diagnostics": {**receipt["diagnostics"], "uiElementsEnabled": False}}):
            with self.subTest(replacement=replacement), self.assertRaises(ValueError):
                PROBE["validate_authorization_receipt"](json.dumps({**receipt, **replacement}))

    def test_completion_requires_exactly_one_verified_native_owner(self):
        for owner in PROBE["FOCUS_OWNER_FLAGS"]:
            with self.subTest(owner=owner):
                receipt = self.receipt()
                receipt["diagnostics"].update({key: key == owner for key in PROBE["FOCUS_OWNER_FLAGS"]})
                self.assertEqual(PROBE["validate_authorization_receipt"](json.dumps(receipt)), receipt)

    def test_username_owner_is_independently_verified_across_native_processes(self):
        for owner in PROBE["USERNAME_OWNER_FLAGS"]:
            with self.subTest(owner=owner):
                receipt = self.receipt()
                receipt["diagnostics"]["usernameOwnerPID"] = 54321
                receipt["diagnostics"].update({key: key == owner for key in PROBE["USERNAME_OWNER_FLAGS"]})
                self.assertEqual(PROBE["validate_authorization_receipt"](json.dumps(receipt)), receipt)

    def test_native_operation_stages_preserve_failed_verdict(self):
        for stage in PROBE["AUTHORIZATION_STAGES"] - {"complete"}:
            receipt = self.receipt(authorized=False, stage=stage)
            self.assertEqual(PROBE["validate_authorization_receipt"](json.dumps(receipt)), receipt)
            receipt["authorized"] = True
            with self.assertRaises(ValueError):
                PROBE["validate_authorization_receipt"](json.dumps(receipt))

    def test_unsuccessful_native_authorization_cannot_pass_and_raw_errors_are_private(self):
        failed = self.receipt(authorized=False, stage="fields")
        process = mock.Mock(returncode=0)
        process.poll.return_value = 0
        process.communicate.return_value = (json.dumps(failed), "private credential in raw stderr")
        with tempfile.TemporaryDirectory() as temporary, contextlib.redirect_stdout(io.StringIO()) as output:
            with self.assertRaisesRegex(ValueError, "failed at stage fields"):
                PROBE["collect_authorization"](process, Path(temporary), required=True)
            self.assertNotIn("private credential", output.getvalue())
            self.assertEqual(json.loads((Path(temporary) / "authorization.json").read_text()), failed)

    def test_progress_requires_every_line_to_be_safe_and_uses_latest_receipt(self):
        early = self.receipt(authorized=False, stage="owner")
        complete = self.receipt()
        progress = json.dumps(early) + "\n" + json.dumps(complete) + "\n"
        self.assertEqual(PROBE["validate_authorization_progress"](progress), complete)
        for invalid in ("", "private\n" + progress, progress + "\n", progress * 65, " " * 65_537):
            with self.subTest(length=len(invalid)), self.assertRaises(ValueError):
                PROBE["validate_authorization_progress"](invalid)

    def test_failed_ui_collects_progress_and_process_scalars_without_raw_output(self):
        progress = self.receipt(authorized=False, stage="form")
        process = mock.Mock(returncode=-15)
        process.poll.return_value = None
        process.communicate.return_value = (json.dumps(progress) + "\n", "private native error")
        with tempfile.TemporaryDirectory() as temporary, contextlib.redirect_stdout(io.StringIO()) as output:
            PROBE["collect_authorization"](process, Path(temporary), required=False)
            process.terminate.assert_called_once()
            status = json.loads((Path(temporary) / "authorization-process.json").read_text())
            self.assertEqual(status, {"wasRunning": True, "returnCode": -15, "timedOut": False,
                                      "stdoutBytes": len(json.dumps(progress)) + 1,
                                      "stderrBytes": len("private native error")})
            self.assertNotIn("private native error", output.getvalue())
            self.assertEqual(json.loads((Path(temporary) / "authorization.json").read_text()), progress)

    def test_runtime_failure_keeps_raw_output_out_of_logs_and_artifacts(self):
        process = mock.Mock(returncode=1)
        process.poll.return_value = 1
        process.communicate.return_value = ("private output", "private error")
        with tempfile.TemporaryDirectory() as temporary, contextlib.redirect_stdout(io.StringIO()) as output:
            PROBE["collect_authorization"](process, Path(temporary), required=False)
            self.assertFalse((Path(temporary) / "authorization.json").exists())
            self.assertEqual(len(list(Path(temporary).iterdir())), 1)
            self.assertNotIn("private output", output.getvalue())
            self.assertNotIn("private error", output.getvalue())

    def test_password_reaches_only_helper_stdin(self):
        record = {"username": "jarvisacceptance", "password": "private-test-password-" * 2,
                  "verified": True, "uid": 502, "generated_uid": "owned"}
        account = {"hosted_directory": mock.Mock(return_value=Path("/private/hosted")),
                   "read_record": mock.Mock(return_value=(record, None)),
                   "account_identity": mock.Mock(return_value={"uid": 502, "generated_uid": "owned"})}
        process = mock.Mock()
        stdin = process.stdin
        with mock.patch("runpy.run_path", return_value=account), mock.patch("subprocess.Popen", return_value=process) as launch:
            self.assertIs(PROBE["start_authorization"](), process)
        self.assertNotIn(record["password"], repr(launch.call_args))
        self.assertEqual(json.loads(stdin.write.call_args.args[0]),
                         {"username": record["username"], "password": record["password"]})
        stdin.close.assert_called_once()


class TemporaryAccountSafetyTests(unittest.TestCase):
    def test_identity_uses_local_directory_record_fields(self):
        metadata = {"dsAttrTypeStandard:UniqueID": ["502"], "dsAttrTypeStandard:GeneratedUID": ["created"],
                    "dsAttrTypeStandard:NFSHomeDirectory": ["/Users/jarvisacceptance"]}
        command = mock.Mock(side_effect=[subprocess.CompletedProcess([], 0, "root\nrunner\njarvisacceptance\n", ""),
            subprocess.CompletedProcess([], 0, plistlib.dumps(metadata).decode(), "")])
        with mock.patch.dict(ACCOUNT_GLOBALS, {"command": command}), mock.patch("pwd.getpwnam") as cached:
            self.assertEqual(ACCOUNT["account_identity"](), {"uid": 502, "generated_uid": "created"})
            cached.assert_not_called()
            self.assertIn("/Local/Default", command.call_args.args[0])

    def test_authoritative_absence_does_not_read_cached_password_record(self):
        with mock.patch.dict(ACCOUNT_GLOBALS, {"command": mock.Mock(
            return_value=subprocess.CompletedProcess([], 0, "root\nrunner\n", ""))
        }), mock.patch("pwd.getpwnam") as cached:
            self.assertIsNone(ACCOUNT["account_identity"]())
            cached.assert_not_called()

    def test_empty_listing_and_wrong_home_are_not_accepted_as_safe_absence(self):
        with mock.patch.dict(ACCOUNT_GLOBALS, {"command": mock.Mock(
            return_value=subprocess.CompletedProcess([], 0, "", ""))
        }):
            with self.assertRaisesRegex(ValueError, "account-identity-list"):
                ACCOUNT["account_identity"]()
        metadata = {"dsAttrTypeStandard:UniqueID": ["502"], "dsAttrTypeStandard:GeneratedUID": ["created"],
                    "dsAttrTypeStandard:NFSHomeDirectory": ["/Users/runner"]}
        with mock.patch.dict(ACCOUNT_GLOBALS, {"command": mock.Mock(side_effect=[
            subprocess.CompletedProcess([], 0, "root\nrunner\njarvisacceptance\n", ""),
            subprocess.CompletedProcess([], 0, plistlib.dumps(metadata).decode(), "")])
        }):
            with self.assertRaisesRegex(ValueError, "account-identity-format"):
                ACCOUNT["account_identity"]()

    def test_unsafe_host_cannot_prepare(self):
        with mock.patch("sys.platform", "linux"), mock.patch("subprocess.run") as run:
            with self.assertRaisesRegex(ValueError, "host-guard"):
                ACCOUNT["hosted_directory"]()
            run.assert_not_called()

    def test_preexisting_account_cannot_be_replaced(self):
        with tempfile.TemporaryDirectory() as temporary, mock.patch.dict(ACCOUNT_GLOBALS, {
            "account_identity": mock.Mock(return_value={"uid": 502, "generated_uid": "existing"}),
            "command": mock.Mock(),
        }):
            with self.assertRaisesRegex(ValueError, "account-already-exists"):
                ACCOUNT["prepare"](Path(temporary))
            ACCOUNT_GLOBALS["command"].assert_not_called()
            self.assertEqual(list(Path(temporary).iterdir()), [])

    def test_preexisting_home_or_secret_cannot_be_reused(self):
        with tempfile.TemporaryDirectory() as temporary, mock.patch.dict(ACCOUNT_GLOBALS, {
            "account_identity": mock.Mock(return_value=None), "command": mock.Mock(),
        }):
            directory = Path(temporary)
            with mock.patch("os.path.lexists", return_value=True):
                with self.assertRaisesRegex(ValueError, "account-home-already-exists"):
                    ACCOUNT["prepare"](directory)
            path = directory / ACCOUNT["FILENAME"]
            path.write_text("unrelated")
            with mock.patch("os.path.lexists", return_value=False):
                with self.assertRaises(FileExistsError):
                    ACCOUNT["prepare"](directory)
            self.assertEqual(path.read_text(), "unrelated")
            ACCOUNT_GLOBALS["command"].assert_not_called()

    def test_cleanup_rejects_changed_account_identity(self):
        with tempfile.TemporaryDirectory() as temporary, mock.patch.dict(ACCOUNT_GLOBALS, {
            "account_identity": mock.Mock(return_value={"uid": 503, "generated_uid": "other"}),
            "command": mock.Mock(),
        }):
            directory = Path(temporary)
            path = directory / ACCOUNT["FILENAME"]
            path.write_text(json.dumps({"marker": ACCOUNT["MARKER"], "username": ACCOUNT["ACCOUNT"],
                                       "owner_uid": os.getuid(), "uid": 502, "generated_uid": "created"}))
            path.chmod(0o600)
            with self.assertRaisesRegex(ValueError, "cleanup-identity-mismatch"):
                ACCOUNT["cleanup"](directory)
            ACCOUNT_GLOBALS["command"].assert_not_called()
            self.assertTrue(path.exists())

    def test_preparation_records_verified_identity_without_password_in_argv(self):
        password = "generated-private-password-1234567890"
        command = mock.Mock(return_value=subprocess.CompletedProcess([], 0, "user is a member of the group\n", ""))
        with tempfile.TemporaryDirectory() as temporary, mock.patch.dict(ACCOUNT_GLOBALS, {
            "account_identity": mock.Mock(side_effect=[None, {"uid": 502, "generated_uid": "created"}]),
            "command": command, "verify_authentication": mock.Mock(),
        }), mock.patch("secrets.token_urlsafe", return_value=password), mock.patch("os.path.lexists", return_value=False):
            directory = Path(temporary)
            ACCOUNT["prepare"](directory)
            record, info = ACCOUNT["read_record"](directory)
            self.assertIs(record["verified"], True)
            self.assertEqual(record["uid"], 502)
            self.assertEqual(info.st_mode & 0o777, 0o600)
            creation = command.call_args_list[0]
            self.assertNotIn(password, repr(creation.args))
            self.assertEqual(creation.kwargs["input_text"], password + "\n")
            ACCOUNT_GLOBALS["verify_authentication"].assert_called_once_with(password)

    def test_cleanup_deletes_only_matching_created_identity_and_file(self):
        identity = {"uid": 502, "generated_uid": "created"}
        with tempfile.TemporaryDirectory() as temporary, mock.patch.dict(ACCOUNT_GLOBALS, {
            "account_identity": mock.Mock(side_effect=[identity, None]), "command": mock.Mock(),
        }):
            directory = Path(temporary)
            path = directory / ACCOUNT["FILENAME"]
            path.write_text(json.dumps({"marker": ACCOUNT["MARKER"], "username": ACCOUNT["ACCOUNT"],
                                       "owner_uid": os.getuid(), **identity}))
            path.chmod(0o600)
            ACCOUNT["cleanup"](directory)
            ACCOUNT_GLOBALS["command"].assert_called_once_with(
                ["/usr/bin/sudo", "-n", "/usr/sbin/sysadminctl", "-deleteUser", "jarvisacceptance"],
                stage="account-deletion")
            self.assertFalse(path.exists())

    def test_secret_symlink_is_not_followed(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            target = directory / "unrelated"
            target.write_text("private")
            (directory / ACCOUNT["FILENAME"]).symlink_to(target)
            with self.assertRaises(OSError):
                ACCOUNT["read_record"](directory)
            self.assertEqual(target.read_text(), "private")

    def test_authentication_secret_uses_stdin_and_checks_negative_control(self):
        password = "secret-never-in-argv-or-errors"
        results = [subprocess.CompletedProcess([], 1, "failed", ""),
                   subprocess.CompletedProcess([], 0, "", "")]
        with mock.patch("subprocess.run", side_effect=results) as run:
            ACCOUNT["verify_authentication"](password)
            self.assertEqual(run.call_count, 2)
            for call in run.call_args_list:
                self.assertNotIn(password, repr(call.args))
            self.assertIn(password, run.call_args.kwargs["input"])
        with mock.patch("subprocess.run", return_value=subprocess.CompletedProcess([], 0, "", "")):
            with self.assertRaisesRegex(ValueError, "^account-authentication$"):
                ACCOUNT["verify_authentication"](password)

    def test_subprocess_failures_do_not_expose_output_or_input(self):
        secret = "private-test-credential"
        with mock.patch("subprocess.run", side_effect=subprocess.TimeoutExpired(["tool"], 1, output=secret)):
            with self.assertRaises(ValueError) as error:
                ACCOUNT["command"](["tool"], stage="account-creation", input_text=secret)
            self.assertEqual(str(error.exception), "account-creation")


if __name__ == "__main__":
    unittest.main()
