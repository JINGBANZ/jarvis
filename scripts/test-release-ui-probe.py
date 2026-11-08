#!/usr/bin/env python3
"""Check fail-closed result accounting without launching apps or touching TCC."""

from pathlib import Path
import json
import os
import plistlib
import runpy
import subprocess
import tempfile
import unittest
from unittest import mock


PROBE = runpy.run_path(str(Path(__file__).with_name("probe-release-ui.py")))
ACCOUNT = runpy.run_path(str(Path(__file__).with_name("prepare-release-ui-account.py")))
ACCOUNT_GLOBALS = ACCOUNT["prepare"].__globals__


class ProbeResultsTests(unittest.TestCase):
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
            "TestBundlePath": "__TESTROOT__/ReleaseAcceptance.xctest",
            "EnvironmentVariables": {"EXISTING": "value"},
        }]}], "Metadata": {"EnvironmentVariables": {"UNRELATED": "value"}}}
        environment = {"JARVIS_ACCEPTANCE_APP_PATH": "/Users/runner/Applications/Jarvis.app"}
        self.assertEqual(PROBE["inject_environment"](manifest, environment), 1)
        target = manifest["TestConfigurations"][0]["TestTargets"][0]
        self.assertEqual(target["EnvironmentVariables"], {"EXISTING": "value", **environment})
        self.assertIs(target["TestTimeoutsEnabled"], True)
        self.assertEqual(target["MaximumTestExecutionTimeAllowance"], 120)
        self.assertEqual(manifest["Metadata"]["EnvironmentVariables"], {"UNRELATED": "value"})


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
