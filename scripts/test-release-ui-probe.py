#!/usr/bin/env python3
"""Check fail-closed result accounting without launching apps or touching TCC."""

from pathlib import Path
import contextlib
import io
import json
import os
import plistlib
import runpy
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
                self.assertGreater(command_receipt['startedUptime'], 0)
                self.assertGreaterEqual(command_receipt['elapsedSeconds'], 1)
                self.assertIsNone(unrelated.poll())
            finally:
                unrelated.terminate()
                unrelated.wait(timeout=5)

    def test_all_three_mandatory_cases_pass(self):
        PROBE["validate_summary"]({
            "totalTestCount": 3, "passedTests": 3, "failedTests": 0, "skippedTests": 0,
        })

    def test_missing_partial_failed_skipped_or_mistyped_results_are_rejected(self):
        complete = {"totalTestCount": 3, "passedTests": 3, "failedTests": 0, "skippedTests": 0}
        for replacement in ({}, {"totalTestCount": 0}, {"totalTestCount": 2, "passedTests": 2},
                            {"passedTests": 2}, {"failedTests": 1}, {"skippedTests": 1},
                            {"failedTests": False}, {"passedTests": "3"}):
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
        self.assertEqual(target["MaximumTestExecutionTimeAllowance"], 120)
        self.assertEqual(manifest["Metadata"]["EnvironmentVariables"], {"UNRELATED": "value"})


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


class AudioRouteTests(unittest.TestCase):
    def receipt(self, phase="mic-only"):
        empty = {"frames": 192_000, "rms": 0.0, "micToneAmplitude": 0.0, "systemToneAmplitude": 0.0,
                 "micToneFraction": 0.0, "systemToneFraction": 0.0}
        active = {**empty, "rms": 0.071}
        prefix = "micTone" if phase == "mic-only" else "systemTone"
        active.update({prefix + "Amplitude": 0.1, prefix + "Fraction": 0.99})
        return {"schemaVersion": 1, "check": "production-aggregate-route-isolation", "mode": "capture",
                "phase": phase, "stage": "complete", "passed": True, "outputFrames": 0,
                "rawMic": active if phase == "mic-only" else empty,
                "globalTap": empty if phase == "mic-only" else active,
                "micUID": "BlackHole16ch_UID", "systemUID": "BlackHole2ch_UID", "micChannels": 16,
                "sampleRate": 48_000, "defaultsRestored": True, "resourcesReleased": True}

    def test_both_independent_phases_pass(self):
        for phase in ("mic-only", "system-only"):
            PROBE["validate_audio_receipt"](self.receipt(phase), "capture", phase)

    def test_bootstrap_requires_observed_acknowledgement_without_claiming_capture(self):
        receipt = self.receipt()
        for key in ("micUID", "systemUID", "micChannels", "sampleRate"):
            del receipt[key]
        receipt.update(check="fixture-capture-consent-bootstrap", mode="authorize", phase="consent",
                       microphoneAuthorized=True, tapCreated=True, nativeConsentAcknowledged=True, captureGrantProven=False,
                       microphoneRequestUptime=100.0, microphoneFinishedUptime=110.0, microphoneCompletionUptime=109.0,
                       microphoneCallbackReceived=True, microphoneAuthorizationStatus=3,
                       ioStarted=True, ioStartRequestedUptime=111.0, ioStartReturnedUptime=112.0)
        PROBE["validate_audio_receipt"](receipt, "authorize", "consent")
        for key, value in (("nativeConsentAcknowledged", False), ("microphoneAuthorized", False),
                           ("captureGrantProven", True), ("tapCreated", 1), ("ioStarted", False),
                           ("ioStartRequestedUptime", 99.0), ("ioStartReturnedUptime", 110.0),
                           ("authorizationFailureStage", "cleanup")):
            with self.assertRaises(ValueError):
                PROBE["validate_audio_receipt"]({**receipt, key: value}, "authorize", "consent")

    def test_microphone_diagnostics_reject_malformed_status_or_clock(self):
        receipt = self.receipt()
        for key in ("micUID", "systemUID", "micChannels", "sampleRate"):
            del receipt[key]
        receipt.update(check="fixture-capture-consent-bootstrap", mode="authorize", phase="consent", passed=False,
                       microphoneRequestUptime=100.0, microphoneFinishedUptime=130.0,
                       microphoneCallbackReceived=False, microphoneAuthorizationStatus=0)
        PROBE["validate_audio_receipt"](receipt, "authorize", "consent", require_pass=False)
        for key, value in (("microphoneFinishedUptime", 99), ("microphoneRequestUptime", float("nan")),
                           ("microphoneAuthorizationStatus", 4), ("microphoneCallbackReceived", True)):
            with self.assertRaises(ValueError):
                PROBE["validate_audio_receipt"]({**receipt, key: value}, "authorize", "consent", require_pass=False)

    def test_emitter_requires_matching_device_complete_tone_and_cleanup(self):
        receipt = self.receipt()
        for key in ("micUID", "systemUID", "micChannels"):
            del receipt[key]
        receipt.update(check="virtual-device-tone-emission", mode="emit", phase="system",
                       emitterUID="BlackHole2ch_UID", outputFrames=384_000)
        PROBE["validate_audio_receipt"](receipt, "emit", "system")
        for key, value in (("outputFrames", 0), ("emitterUID", "BlackHole16ch_UID"), ("resourcesReleased", False)):
            with self.assertRaises(ValueError):
                PROBE["validate_audio_receipt"]({**receipt, key: value}, "emit", "system")

    def test_phase_cancelled_leak_is_rejected_by_inactive_rms(self):
        for phase in ("mic-only", "system-only"):
            receipt = self.receipt(phase)
            receipt["globalTap" if phase == "mic-only" else "rawMic"]["rms"] = 0.071
            with self.assertRaisesRegex(ValueError, "not independent"):
                PROBE["validate_audio_receipt"](receipt, "capture", phase)

    def test_missing_signal_partial_capture_cleanup_and_nonfinite_values_refuse(self):
        for key, value in (("frames", 1), ("rms", float("nan")), ("micToneAmplitude", 0), ("micToneFraction", 0.1)):
            receipt = self.receipt()
            receipt["rawMic"][key] = value
            with self.assertRaises(ValueError):
                PROBE["validate_audio_receipt"](receipt, "capture", "mic-only")
        for key, value in (("passed", False), ("defaultsRestored", False), ("resourcesReleased", False),
                           ("micUID", "physical-device"), ("mode", "emit"), ("sampleRate", True)):
            receipt = {**self.receipt(), key: value}
            with self.assertRaises(ValueError):
                PROBE["validate_audio_receipt"](receipt, "capture", "mic-only")

    def test_failure_export_retains_only_scalar_metrics_and_presence_of_error(self):
        receipt = {**self.receipt(), "passed": False, "error": "private native diagnostic"}
        safe = PROBE["validate_audio_receipt"](receipt, "capture", "mic-only", require_pass=False)
        self.assertIs(safe["errorPresent"], True)
        self.assertNotIn("error", safe)
        self.assertNotIn("private", json.dumps(safe))
        with self.assertRaises(ValueError):
            PROBE["validate_audio_receipt"]({**receipt, "rawAudio": "untrusted"}, "capture", "mic-only", require_pass=False)


if __name__ == "__main__":
    unittest.main()
