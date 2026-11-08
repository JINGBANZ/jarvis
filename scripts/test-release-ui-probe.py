#!/usr/bin/env python3
"""Check fail-closed result accounting without launching apps or touching TCC."""

from pathlib import Path
import runpy
import unittest


PROBE = runpy.run_path(str(Path(__file__).with_name("probe-release-ui.py")))


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


if __name__ == "__main__":
    unittest.main()
