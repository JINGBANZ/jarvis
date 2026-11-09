#!/usr/bin/env python3
"""Check fail-closed result accounting without launching apps or touching TCC."""

from pathlib import Path
import contextlib
from datetime import datetime, timezone
import io
import hashlib
import http.client
import json
import os
import plistlib
import runpy
import subprocess
import ssl
import sys
import tarfile
import tempfile
import unittest
import urllib.error
from unittest import mock


PROBE = runpy.run_path(str(Path(__file__).with_name("probe-release-ui.py")))
ACCOUNT = runpy.run_path(str(Path(__file__).with_name("prepare-release-ui-account.py")))
ACCOUNT_GLOBALS = ACCOUNT["prepare"].__globals__
INPUT = runpy.run_path(str(Path(__file__).with_name("release-input-fixture.py")))
INPUT_GLOBALS = INPUT["teardown"].__globals__
SERVICE = runpy.run_path(str(Path(__file__).resolve().parent.parent / "Tests/ReleaseReadiness/AudioServiceEvidence.py"))
SERVICE_GLOBALS = SERVICE["collect"].__globals__


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


class InputFixtureDownloadTests(unittest.TestCase):
    payload = b"pinned public dependency"

    def setUp(self):
        self.exporter = mock.Mock()
        patch = mock.patch.dict(INPUT_GLOBALS, receipt=self.exporter)
        patch.start()
        self.addCleanup(patch.stop)

    def response(self, data=None, length=None):
        value = mock.MagicMock()
        value.__enter__.return_value = value
        value.read.return_value = self.payload if data is None else data
        value.getheader.return_value = str(len(value.read.return_value)) if length is None else length
        return value

    def fetch(self):
        return INPUT["download"](INPUT["FFMPEG_URL"], hashlib.sha256(self.payload).hexdigest())

    def test_known_transient_transport_failures_retry_then_verify(self):
        errors = [urllib.error.URLError(ConnectionResetError(54, "reset")), TimeoutError(),
                  http.client.IncompleteRead(b""), http.client.RemoteDisconnected(),
                  ssl.SSLEOFError(), *[urllib.error.HTTPError("url", code, "transient", None, None)
                                     for code in (408, 429, 503)]]
        for error in errors:
            with self.subTest(error=type(error).__name__), \
                 mock.patch.object(INPUT["urllib"].request, "urlopen", side_effect=[error, self.response()]) as opened, \
                 mock.patch.object(INPUT["time"], "sleep") as delay:
                self.assertEqual(self.fetch(), self.payload)
                self.assertEqual(opened.call_count, 2)
                delay.assert_called_once_with(1)

    def test_three_failed_attempts_exhaust_fixed_bound_without_raw_error(self):
        with mock.patch.object(INPUT["urllib"].request, "urlopen", side_effect=ConnectionResetError("private detail")) as opened, \
             mock.patch.object(INPUT["time"], "sleep") as delay:
            with self.assertRaisesRegex(RuntimeError, "^Pinned fixture dependency download failed$"):
                self.fetch()
            self.assertEqual(opened.call_count, 3)
            self.assertEqual(delay.call_args_list, [mock.call(1), mock.call(2)])
            self.assertEqual(self.exporter.call_args.args[1], {
                "schemaVersion": 1, "dependency": "ffmpeg", "attemptCount": 3, "category": "connection-reset"})
            self.assertNotIn("private", json.dumps(self.exporter.call_args.args[1]))

    def test_download_failure_exports_only_closed_transport_metadata(self):
        cases = [(urllib.error.HTTPError("private-url", 403, "private message", None, None),
                  {"category": "http", "httpStatus": 403}),
                 (urllib.error.URLError(ConnectionResetError(54, "private detail")),
                  {"category": "connection-reset", "errno": 54})]
        for error, fields in cases:
            with mock.patch.object(INPUT["urllib"].request, "urlopen", side_effect=error), \
                    mock.patch.object(INPUT["time"], "sleep"):
                with self.assertRaises(RuntimeError):
                    self.fetch()
            result = self.exporter.call_args.args[1]
            self.assertEqual(result, {"schemaVersion": 1, "dependency": "ffmpeg",
                                      "attemptCount": 1 if fields["category"] == "http" else 3, **fields})
            self.assertNotIn("private", json.dumps(result))

    def test_certificate_and_not_found_never_retry(self):
        for error in (urllib.error.HTTPError("url", 404, "missing", None, None),
                      urllib.error.URLError(ssl.SSLCertVerificationError("untrusted"))):
            with mock.patch.object(INPUT["urllib"].request, "urlopen", side_effect=error) as opened, \
                 mock.patch.object(INPUT["time"], "sleep") as delay:
                with self.assertRaises(RuntimeError):
                    self.fetch()
                self.assertEqual(opened.call_count, 1)
                delay.assert_not_called()

    def test_short_transport_retries_but_checksum_or_size_failure_does_not(self):
        with mock.patch.object(INPUT["urllib"].request, "urlopen",
                               side_effect=[self.response(b"short", str(len(self.payload))), self.response()]) as opened, \
             mock.patch.object(INPUT["time"], "sleep"):
            self.assertEqual(self.fetch(), self.payload)
            self.assertEqual(opened.call_count, 2)
        for response in (self.response(b"wrong bytes"), self.response(length="30000001"), self.response(length="invalid")):
            with mock.patch.object(INPUT["urllib"].request, "urlopen", return_value=response) as opened, \
                 mock.patch.object(INPUT["time"], "sleep") as delay:
                with self.assertRaises(ValueError):
                    self.fetch()
                self.assertEqual(opened.call_count, 1)
                delay.assert_not_called()
        self.exporter.assert_not_called()


class AudioServiceEvidenceTests(unittest.TestCase):
    start = 1_800_000_000
    end = start + 60

    def report(self, **changes):
        body = {"procName": "coreaudiod", "procPath": "/usr/sbin/coreaudiod",
                "captureTime": datetime.fromtimestamp(self.start + 10, timezone.utc).isoformat(),
                "exception": {"type": "EXC_BAD_ACCESS", "signal": "SIGSEGV", "private": "secret"},
                "faultingThread": 0,
                "usedImages": [{"path": "/Library/Audio/Plug-Ins/HAL/roc_vad.driver/Contents/MacOS/roc_vad"}],
                "threads": [{"frames": [{"imageIndex": 0, "symbol": "roc::RingBuffer::read(private-secret)"},
                                        {"imageIndex": 0, "symbol": "roc::RequestHandler::OnReadClientInput"},
                                        {"imageIndex": 0, "symbol": "std::__1::fill_n"}]}],
                "privatePath": "/Users/private-person/secret"}
        body.update(changes)
        return json.dumps({"bug_type": "309", "private": "secret"}).encode() + b"\n" + json.dumps(body).encode()

    def summarize(self, raw):
        return SERVICE["summarize_report"](raw, self.start, self.end)

    def baseline(self):
        return {"schemaVersion": 1, "wallTime": self.start, "reportIDs": [],
                "inventoryUnavailable": False, "daemonUnavailable": False,
                "daemon": {"pid": 42, "start": [self.start - 10, 1]}}

    def test_only_closed_crashed_thread_categories_leave_report_parser(self):
        result = self.summarize(self.report())
        self.assertEqual(result, {"rocImageLoaded": True, "rocFrameCount": 3, "ringBufferFrame": True,
                                  "requestHandlerFrame": True, "memoryFillCopyFrame": True,
                                  "exception": "EXC_BAD_ACCESS", "signal": "SIGSEGV"})
        self.assertNotIn("secret", json.dumps(result))
        self.assertNotIn("/", json.dumps(result))
        unknown = self.summarize(self.report(exception={"type": "secret", "signal": "private"}))
        self.assertEqual((unknown["exception"], unknown["signal"]), ("other", "other"))

    def test_wrong_process_report_type_or_time_window_cannot_match(self):
        for changes in ({"procName": "unrelated"}, {"procPath": "/private/coreaudiod"},
                        {"captureTime": datetime.fromtimestamp(self.start - 1, timezone.utc).isoformat()},
                        {"captureTime": datetime.fromtimestamp(self.end + 1, timezone.utc).isoformat()},
                        {"captureTime": "2027-01-01T00:00:00"}):
            self.assertIsNone(self.summarize(self.report(**changes)))
        self.assertIsNone(self.summarize(self.report().replace(b'"309"', b'"288"', 1)))

    def test_malformed_oversize_and_invalid_frame_indexes_refuse(self):
        for raw in (b"private malformed", self.report() + b"trailing-private-data",
                    b"x" * (SERVICE["MAX_REPORT_BYTES"] + 1), self.report(faultingThread=True),
                    self.report(threads=[{"frames": [{"imageIndex": 12, "symbol": "secret"}]}])):
            with self.assertRaises((ValueError, KeyError, TypeError)):
                self.summarize(raw)

    def test_report_symlink_fifo_and_oversize_are_never_read(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            target = directory / "private"
            target.write_bytes(self.report())
            path = directory / "coreaudiod.ips"
            path.symlink_to(target)
            with self.assertRaises(OSError):
                SERVICE["read_report"](path)
            path.unlink()
            os.mkfifo(path, 0o600)
            with self.assertRaises(ValueError):
                SERVICE["read_report"](path)
            path.unlink()
            with path.open("wb") as output:
                output.truncate(SERVICE["MAX_REPORT_BYTES"] + 1)
            with self.assertRaises(ValueError):
                SERVICE["read_report"](path)

    def test_only_new_reports_are_collected_and_daemon_birth_change_is_explicit(self):
        before = self.baseline()
        before["reportIDs"] = ["a" * 64]
        after = {**before, "wallTime": self.end, "daemon": {"pid": 43, "start": [self.start + 20, 2]}}
        reports = {"a" * 64: Path("old"), "b" * 64: Path("new")}
        with mock.patch.dict(SERVICE_GLOBALS, snapshot=mock.Mock(return_value=after),
                             inventory=mock.Mock(return_value=(reports, False)),
                             read_report=mock.Mock(return_value=self.report())) as values:
            result = SERVICE["collect"](before)
            values["read_report"].assert_called_once_with(Path("new"))
        self.assertIs(result["daemonChanged"], True)
        self.assertEqual(len(result["matchedReports"]), 1)
        with mock.patch.dict(SERVICE_GLOBALS, snapshot=mock.Mock(return_value=after),
                             inventory=mock.Mock(return_value=(reports, True)),
                             read_report=mock.Mock(side_effect=PermissionError("private detail"))):
            unavailable = SERVICE["collect"](before)
        self.assertIs(unavailable["reportCollectionUnavailable"], True)
        self.assertEqual(unavailable["unreadableReports"], 1)
        self.assertNotIn("private", json.dumps(unavailable))

    def test_baseline_and_export_schema_reject_private_extra_data(self):
        for changes in ({"daemon": {"pid": 1, "start": [1, 0], "secret": "private"}},
                        {"wallTime": float("nan")}, {"reportIDs": ["private-path"]}, {"unknown": "private"}):
            with self.assertRaises(ValueError):
                SERVICE["validate_snapshot"]({**self.baseline(), **changes})

    def test_diagnostic_failure_cannot_replace_original_ui_cleanup_failure(self):
        with tempfile.TemporaryDirectory() as temporary, \
             mock.patch.dict(PROBE["export_audio_service_evidence"].__globals__,
                             audio_service_evidence=mock.Mock(side_effect=ValueError("private report"))):
            evidence = Path(temporary)
            with self.assertRaisesRegex(ValueError, "original cleanup failure"):
                try:
                    raise ValueError("original cleanup failure")
                finally:
                    PROBE["export_audio_service_evidence"](evidence, self.baseline())
            self.assertEqual(json.loads((evidence / "audio-service.json").read_text()),
                             {"schemaVersion": 1, "collectionUnavailable": True})


class InputFixtureArchiveTests(unittest.TestCase):
    payload = b"pinned public dependency"

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name).resolve() / "archives"
        self.digest = hashlib.sha256(self.payload).hexdigest()
        patch = mock.patch.dict(INPUT_GLOBALS, ARCHIVES=self.directory, FFMPEG_SHA=self.digest)
        patch.start()
        self.addCleanup(patch.stop)
        self.path = self.directory / "ffmpeg-8.0.1.tar.xz"

    def fetch(self):
        return INPUT["cached_archive"](INPUT["FFMPEG_URL"], self.digest)

    def seed(self, data=None):
        self.directory.mkdir(mode=0o700)
        INPUT["create"](self.path, self.payload if data is None else data)

    def test_miss_downloads_once_and_hit_rehashes_without_network(self):
        with mock.patch.dict(INPUT_GLOBALS, download=mock.Mock(return_value=self.payload)):
            self.assertEqual(self.fetch(), self.payload)
            self.assertEqual(self.fetch(), self.payload)
            INPUT_GLOBALS["download"].assert_called_once_with(INPUT["FFMPEG_URL"], self.digest)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual(list(self.directory.iterdir()), [self.path])
        self.path.write_bytes(b"substituted after a successful hit")
        with mock.patch.dict(INPUT_GLOBALS, download=mock.Mock()) as values:
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                self.fetch()
            values["download"].assert_not_called()

    def test_corrupt_restored_bytes_never_fall_back_to_download(self):
        self.seed(b"private corrupted contents")
        with mock.patch.dict(INPUT_GLOBALS, download=mock.Mock()) as values:
            with self.assertRaisesRegex(ValueError, "^Cached fixture archive checksum mismatch$"):
                self.fetch()
            values["download"].assert_not_called()

    def test_symlinks_hardlinks_fifo_permissions_and_oversize_refuse(self):
        self.directory.mkdir(mode=0o700)
        target = self.directory / "private-unrelated"
        INPUT["create"](target, self.payload)
        variants = [lambda: self.path.symlink_to(target), lambda: os.link(target, self.path),
                    lambda: os.mkfifo(self.path, 0o600), lambda: self.path.mkdir(),
                    lambda: INPUT["create"](self.path, self.payload, 0o644)]
        for variant in variants:
            with self.subTest(variant=variant), mock.patch.dict(INPUT_GLOBALS, download=mock.Mock()) as values:
                variant()
                with self.assertRaises((ValueError, OSError)):
                    self.fetch()
                values["download"].assert_not_called()
                self.path.rmdir() if self.path.is_dir() else self.path.unlink()
        with self.path.open("wb") as output:
            output.truncate(30_000_001)
        self.path.chmod(0o600)
        with self.assertRaisesRegex(ValueError, "bounded private regular file"):
            self.fetch()

    def test_cache_directory_and_unpinned_request_refuse(self):
        self.seed()
        self.directory.chmod(0o755)
        with self.assertRaisesRegex(ValueError, "owned and private"):
            self.fetch()
        with self.assertRaisesRegex(ValueError, "pinned dependency checksum"):
            INPUT["cached_archive"](INPUT["FFMPEG_URL"], "0" * 64)

    def test_cached_archive_still_requires_safe_extraction(self):
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode="w:xz") as output:
            member = tarfile.TarInfo("ffmpeg-8.0.1/private-link")
            member.type = tarfile.SYMTYPE
            member.linkname = "/private-unrelated"
            output.addfile(member)
        data = archive.getvalue()
        self.seed(data)
        with mock.patch.dict(INPUT_GLOBALS, FFMPEG_SHA=hashlib.sha256(data).hexdigest(), run=mock.Mock()) as values:
            with self.assertRaisesRegex(ValueError, "Unexpected FFmpeg source archive contents"):
                INPUT["build_ffmpeg"]()
            values["run"].assert_not_called()


class InputFixtureOwnershipTests(unittest.TestCase):
    header = "index type state uid name\n"

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name).resolve()
        self.command = mock.Mock()
        patcher = mock.patch.dict(INPUT_GLOBALS, BASE=self.directory, run=self.command)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.owned = self.header + "1 receiver on com.jarvis.release-input Jarvis Synthetic Microphone\n"

    def claim(self):
        self.command.return_value = self.header
        INPUT["claim_receiver"]()
        self.command.reset_mock()

    def test_no_ownership_never_deletes_and_preexisting_uid_refuses_claim(self):
        INPUT["teardown"]()
        self.command.assert_not_called()
        self.command.return_value = self.owned
        with self.assertRaisesRegex(ValueError, "preexisting"):
            INPUT["claim_receiver"]()
        self.assertFalse((self.directory / "ownership.json").exists())
        self.assertEqual(self.command.call_count, 1)

    def test_cancelled_setup_without_success_receipt_cleans_exact_owned_receiver(self):
        self.claim()
        self.assertFalse((self.directory / "setup.json").exists())
        self.assertEqual((self.directory / "ownership.json").stat().st_mode & 0o777, 0o600)
        self.command.side_effect = [self.owned, "", self.header]
        INPUT["teardown"]()
        self.assertEqual(self.command.call_args_list[1].args[0],
                         [str(INPUT["ROC"]), "device", "del", "--uid", INPUT["UID"]])
        receipt = json.loads((self.directory / "teardown.json").read_text())
        self.assertIs(receipt["receiverRemoved"], True)
        self.assertIs(receipt["receiverAbsent"], True)

    def test_already_absent_owned_receiver_requires_successful_inventory(self):
        self.claim()
        self.command.return_value = self.header
        INPUT["teardown"]()
        self.assertEqual(self.command.call_count, 2)
        receipt = json.loads((self.directory / "teardown.json").read_text())
        self.assertIs(receipt["receiverRemoved"], False)
        self.assertIs(receipt["receiverAbsent"], True)

    def test_changed_receiver_identity_or_inventory_failure_never_implies_absence(self):
        self.claim()
        for output in (self.owned.replace("Jarvis Synthetic Microphone", "Unrelated Receiver"),
                       "not an inventory\n"):
            self.command.reset_mock()
            self.command.return_value = output
            with self.assertRaises(ValueError):
                INPUT["remove_owned_receiver"]()
            self.assertEqual(self.command.call_count, 1)
        self.command.side_effect = RuntimeError("RPC unavailable")
        with self.assertRaisesRegex(RuntimeError, "RPC unavailable"):
            INPUT["remove_owned_receiver"]()
        self.assertFalse((self.directory / "teardown.json").exists())

    def test_post_delete_presence_is_failure(self):
        self.claim()
        self.command.side_effect = [self.owned, "", self.owned]
        with self.assertRaisesRegex(RuntimeError, "remains after cleanup"):
            INPUT["teardown"]()
        self.assertFalse((self.directory / "teardown.json").exists())


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
                "micUID": "com.jarvis.release-input", "systemUID": "BlackHole2ch_UID", "micChannels": 2,
                "sampleRate": 48_000, "defaultsRestored": True, "resourcesReleased": True,
                "measurementStartUptime": 102.0, "measurementEndUptime": 106.0}

    def test_both_independent_phases_pass(self):
        for phase in ("mic-only", "system-only"):
            PROBE["validate_audio_receipt"](self.receipt(phase), "capture", phase)

    def test_bootstrap_requires_observed_acknowledgement_without_claiming_capture(self):
        receipt = self.receipt()
        for key in ("micUID", "systemUID", "micChannels", "sampleRate", "measurementStartUptime", "measurementEndUptime"):
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
        for key in ("micUID", "systemUID", "micChannels", "sampleRate", "measurementStartUptime", "measurementEndUptime"):
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
        for key in ("micUID", "systemUID", "micChannels", "measurementStartUptime", "measurementEndUptime"):
            del receipt[key]
        receipt.update(check="virtual-device-tone-emission", mode="emit", phase="system",
                       emitterUID="BlackHole2ch_UID", outputFrames=384_000, senderStartUptime=100.0, senderEndUptime=108.0)
        PROBE["validate_audio_receipt"](receipt, "emit", "system")
        for key, value in (("outputFrames", 0), ("emitterUID", "BlackHole16ch_UID"), ("resourcesReleased", False)):
            with self.assertRaises(ValueError):
                PROBE["validate_audio_receipt"]({**receipt, key: value}, "emit", "system")

    def test_rtp_active_and_quiet_senders_require_transport_completion_and_exact_reaping(self):
        receipt = self.receipt()
        for key in ("micUID", "systemUID", "micChannels", "measurementStartUptime", "measurementEndUptime"):
            del receipt[key]
        receipt.update(check="synthetic-microphone-rtp", mode="emit", emitterUID="com.jarvis.release-input",
                       micChannels=2, transport="rtp", wireSampleRate=44_100, outputDurationSeconds=8, sourceDurationSeconds=8,
                       senderElapsedSeconds=8.1, senderExitCode=0, senderReaped=True,
                       senderStartUptime=100.0, senderEndUptime=108.1)
        for phase in ("mic", "mic-quiet"):
            receipt["phase"] = phase
            PROBE["validate_audio_receipt"](receipt, "emit", phase)
            for key, value in (("outputDurationSeconds", 0), ("outputDurationSeconds", 8.2), ("outputDurationSeconds", float("nan")),
                               ("sourceDurationSeconds", 7), ("senderExitCode", 1), ("senderExitCode", False),
                               ("senderReaped", False), ("senderElapsedSeconds", 6.9), ("senderElapsedSeconds", 13.1), ("transport", "hal"),
                               ("wireSampleRate", 48_000), ("outputFrames", 384_000)):
                with self.assertRaises(ValueError):
                    PROBE["validate_audio_receipt"]({**receipt, key: value}, "emit", phase)
            for missing in ("senderReaped", "outputDurationSeconds", "senderExitCode"):
                with self.assertRaises(ValueError):
                    PROBE["validate_audio_receipt"]({k: v for k, v in receipt.items() if k != missing}, "emit", phase)

    def test_measurement_requires_all_producers_to_cover_the_scored_interval(self):
        for phase, producers in (("mic-only", ["mic"]), ("system-only", ["system", "mic-quiet"])):
            capture = self.receipt(phase)
            emitters = [{"phase": name, "senderStartUptime": 100.0, "senderEndUptime": 108.0} for name in producers]
            PROBE["validate_audio_coverage"](capture, emitters)
            with self.assertRaisesRegex(ValueError, "every active and quiet producer"):
                PROBE["validate_audio_coverage"](capture, emitters[:-1])
            for index in range(len(emitters)):
                for key, value in (("senderStartUptime", 102.1), ("senderEndUptime", 105.9)):
                    invalid = [dict(emitter) for emitter in emitters]
                    invalid[index][key] = value
                    with self.assertRaisesRegex(ValueError, "complete measurement"):
                        PROBE["validate_audio_coverage"](capture, invalid)

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
                           ("micUID", "physical-device"), ("mode", "emit"), ("sampleRate", True),
                           ("measurementStartUptime", float("nan")), ("measurementEndUptime", 101)):
            receipt = {**self.receipt(), key: value}
            with self.assertRaises(ValueError):
                PROBE["validate_audio_receipt"](receipt, "capture", "mic-only")

    def test_failure_export_retains_only_scalar_metrics_and_presence_of_error(self):
        receipt = {**self.receipt(), "passed": False, "error": "private native diagnostic",
                   "failureStage": "capture", "failureReason": "invalid-buffers",
                   "invalidBufferReason": "bytes", "invalidBufferCount": 2, "invalidBufferIndex": 0,
                   "invalidBufferChannels": 2, "invalidBufferByteSize": 0, "invalidBufferHasData": False,
                   "invalidBufferUptime": 103.5}
        safe = PROBE["validate_audio_receipt"](receipt, "capture", "mic-only", require_pass=False)
        self.assertIs(safe["errorPresent"], True)
        self.assertEqual(safe["failureStage"], "capture")
        self.assertEqual(safe["invalidBufferByteSize"], 0)
        self.assertEqual(safe["rawMic"]["frames"], 192_000)
        self.assertNotIn("error", safe)
        self.assertNotIn("private", json.dumps(safe))
        with self.assertRaises(ValueError):
            PROBE["validate_audio_receipt"]({**receipt, "rawAudio": "untrusted"}, "capture", "mic-only", require_pass=False)

    def test_device_snapshot_retains_only_typed_route_facts(self):
        state = {"uptime": 101.0, "queryFailed": False, "micEnumerated": True, "micAlive": True,
                 "micObjectMatchesRequested": True, "aggregateActiveSubdeviceCount": 1, "aggregateMicActive": True,
                 "aggregateActiveTapCount": 1, "aggregateTapMatchesRequested": True,
                 "defaultInputMatchesRequested": True, "defaultInputMatchesAggregate": False}
        receipt = {**self.receipt(), "beforeIOState": state}
        PROBE["validate_audio_receipt"](receipt, "capture", "mic-only")
        for key, value in (("deviceName", "private"), ("micAlive", 1), ("uptime", float("nan")),
                           ("aggregateActiveTapCount", 4097), ("queryOSStatus", -50)):
            with self.assertRaises(ValueError):
                PROBE["validate_audio_receipt"]({**receipt, "beforeIOState": {**state, key: value}}, "capture", "mic-only")
        failure = {**receipt, "passed": False, "error": "private diagnostic",
                   "failureState": {"uptime": 105.0, "queryFailed": True, "queryOSStatus": -50, "micEnumerated": False}}
        safe = PROBE["validate_audio_receipt"](failure, "capture", "mic-only", require_pass=False)
        self.assertEqual(safe["failureState"]["queryOSStatus"], -50)
        self.assertNotIn("private", json.dumps(safe))
        with self.assertRaises(ValueError):
            PROBE["validate_audio_receipt"]({**receipt, "failureState": failure["failureState"]}, "capture", "mic-only")

    def test_closed_failure_metadata_refuses_unknown_text_types_and_false_success(self):
        receipt = {**self.receipt(), "passed": False, "error": "private native diagnostic",
                   "failureStage": "final-defaults", "failureReason": "os-status", "failureOSStatus": -50,
                   "finalDefaultInputMatchesRequested": True, "finalDefaultOutputMatchesRequested": False}
        PROBE["validate_audio_receipt"](receipt, "capture", "mic-only", require_pass=False)
        for key, value in (("failureStage", "private text"), ("failureReason", "private text"),
                           ("failureOSStatus", True), ("failureOSStatus", 2 ** 31),
                           ("finalDefaultInputMatchesRequested", 1), ("invalidBufferCount", -1),
                           ("invalidBufferIndex", 2), ("invalidBufferByteSize", 2 ** 32),
                           ("invalidBufferReason", "private text"), ("invalidBufferHasData", 1), ("passed", True)):
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                PROBE["validate_audio_receipt"]({**receipt, key: value}, "capture", "mic-only", require_pass=False)
        with self.assertRaisesRegex(ValueError, "defaults changed"):
            PROBE["validate_audio_receipt"]({**self.receipt(), "finalDefaultInputMatchesRequested": False}, "capture", "mic-only")

    def test_single_rtp_progress_observation_exports_failure_but_cannot_pass(self):
        receipt = self.receipt()
        for key in ("micUID", "systemUID", "measurementStartUptime", "measurementEndUptime"):
            del receipt[key]
        receipt.update(check="synthetic-microphone-rtp", mode="emit", phase="mic", passed=False,
                       emitterUID="com.jarvis.release-input", transport="rtp", wireSampleRate=44_100,
                       sourceDurationSeconds=8, senderExitCode=15, senderReaped=True,
                       senderStartUptime=101.0, senderEndUptime=101.0,
                       failureStage="operation", failureReason="validation", error="private progress error")
        safe = PROBE["validate_audio_receipt"](receipt, "emit", "mic", require_pass=False)
        self.assertEqual(safe["senderStartUptime"], safe["senderEndUptime"])
        self.assertIs(safe["errorPresent"], True)
        self.assertNotIn("private", json.dumps(safe))
        with self.assertRaises(ValueError):
            PROBE["validate_audio_receipt"](receipt, "emit", "mic")
        with self.assertRaises(ValueError):
            PROBE["validate_audio_receipt"]({**receipt, "senderEndUptime": 100.0}, "emit", "mic", require_pass=False)


if __name__ == "__main__":
    unittest.main()
