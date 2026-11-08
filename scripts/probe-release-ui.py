#!/usr/bin/env python3
"""Credential-free installed-app UI feasibility check on disposable GitHub-hosted Macs."""

import json
import os
from pathlib import Path
import plistlib
import pwd
import subprocess
import sys
import uuid


ROOT = Path(__file__).resolve().parent.parent


def run(arguments, *, timeout, log=None):
    if log is None:
        return subprocess.check_output(arguments, cwd=ROOT, text=True, timeout=timeout)
    try:
        with log.open("w") as output:
            subprocess.run(arguments, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT,
                           check=True, timeout=timeout)
    except subprocess.SubprocessError:
        content = log.read_text()
        diagnostics = [line for line in content.splitlines() if "error:" in line]
        print("\n".join(diagnostics[:20])[:8_000], file=sys.stderr, flush=True)
        print(content[-24_000:], file=sys.stderr, flush=True)
        raise


def inject_environment(value, environment):
    count = 0
    if isinstance(value, dict):
        if "TestBundlePath" in value:
            value.setdefault("EnvironmentVariables", {}).update(environment)
            value.update(TestTimeoutsEnabled=True, DefaultTestExecutionTimeAllowance=120,
                         MaximumTestExecutionTimeAllowance=120)
            count += 1
        for child in value.values():
            count += inject_environment(child, environment)
    elif isinstance(value, list):
        for child in value:
            count += inject_environment(child, environment)
    return count


def validate_summary(summary):
    expected = {"totalTestCount": 3, "passedTests": 3, "failedTests": 0, "skippedTests": 0}
    for key, value in expected.items():
        if type(summary.get(key)) is not int or summary[key] != value:
            raise ValueError(f"UI probe requires all three cases to pass: {key}")


def main():
    account = pwd.getpwuid(os.getuid())
    if (sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true"
            or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted"
            or account.pw_name != "runner" or account.pw_dir != "/Users/runner"):
        raise ValueError("This probe may change app preferences only on a disposable hosted runner")
    if len(sys.argv) != 2:
        raise ValueError("usage: probe-release-ui.py /Users/runner/Applications/Jarvis.app")
    app = Path(sys.argv[1])
    allowed = Path(account.pw_dir) / "Applications/Jarvis.app"
    if app != allowed or app.resolve(strict=True) != app or not app.is_dir():
        raise ValueError("Probe must target the installed app at the isolated runner's fixed path")
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if (info.get("CFBundleIdentifier") != "com.jarvis.coach"
            or info.get("CFBundleExecutable") != "JarvisApp"
            or info.get("JarvisDevelopmentBuild")):
        raise ValueError("Probe requires the normal production app identity and executable")
    run(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(app)], timeout=30)

    os.umask(0o077)
    evidence = ROOT / ".jarvis" / "release-ui-probe" / uuid.uuid4().hex
    evidence.mkdir(parents=True, mode=0o700)
    print(f"UI probe evidence: {evidence}", flush=True)
    architecture = run(["/usr/bin/uname", "-m"], timeout=5).strip()
    project = ROOT / "Tests/ReleaseAcceptance/ReleaseAcceptance.xcodeproj"
    derived = evidence / "derived"
    run(["/usr/bin/xcodebuild", "build-for-testing", "-project", str(project),
         "-scheme", "ReleaseAcceptance", "-destination", f"platform=macOS,arch={architecture}",
         "-derivedDataPath", str(derived), f"ARCHS={architecture}", "ONLY_ACTIVE_ARCH=YES",
         "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_REQUIRED=NO"],
        timeout=300, log=evidence / "build.log")
    manifests = list((derived / "Build/Products").glob("*.xctestrun"))
    if len(manifests) != 1:
        raise ValueError("Expected one compiled UI test manifest")
    with manifests[0].open("rb") as source:
        manifest = plistlib.load(source)
    injected = inject_environment(manifest, {
        "GITHUB_ACTIONS": "true",
        "RUNNER_ENVIRONMENT": "github-hosted",
        "RUNNER_TEMP": os.environ["RUNNER_TEMP"],
        "JARVIS_ACCEPTANCE_AUTH_FILE": str(Path(os.environ["RUNNER_TEMP"]) / "jarvis-ui-authorization.json"),
        "JARVIS_ACCEPTANCE_APP_PATH": str(app),
        "JARVIS_ACCEPTANCE_EXPECTED_VERSION": info["CFBundleShortVersionString"],
        "JARVIS_ACCEPTANCE_EVIDENCE": str(evidence),
    })
    if injected != 1:
        raise ValueError("Expected one external UI test target")
    configured = manifests[0].with_name("HostedProbe.xctestrun")
    with configured.open("wb") as output:
        plistlib.dump(manifest, output)
    result = evidence / "result.xcresult"
    run(["/usr/bin/xcodebuild", "test-without-building", "-xctestrun", str(configured),
         "-destination", f"platform=macOS,arch={architecture}", "-resultBundlePath", str(result),
         "-parallel-testing-enabled", "NO", "-maximum-test-execution-time-allowance", "120"],
        timeout=420, log=evidence / "test.log")
    summary = json.loads(run(["/usr/bin/xcrun", "xcresulttool", "get", "test-results", "summary",
                             "--path", str(result)], timeout=30))
    (evidence / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    validate_summary(summary)
    (evidence / "probe.json").write_text(json.dumps({
        "phase": "credential-free-ui-probe", "app": str(app), "architecture": architecture,
        "version": info["CFBundleShortVersionString"], "passedTests": 3,
        "providerAcceptanceProven": False,
    }, indent=2) + "\n")
    print("All three credential-free UI probe cases passed; provider acceptance remains unproven.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"UI probe failed: {error}", file=sys.stderr)
        raise SystemExit(1)
