#!/usr/bin/env python3
"""Basic signed-app journeys on disposable GitHub-hosted Macs; all raw evidence stays private."""

import json
import argparse
import hashlib
import shutil
import stat
import os
from pathlib import Path
import plistlib
import pwd
import re
import runpy
import signal
import subprocess
import sys
import time
import uuid


ROOT = Path(__file__).resolve().parent.parent

AUTHORIZATION_STAGES = {
    "input", "accessibility", "owner", "form", "fields", "fill", "submit", "dismiss", "complete",
    "revalidate-owner", "revalidate-form", "revalidate-controls", "field-owner", "focus-read",
    "focus-settable", "focus-set", "focus-press", "focus-verify", "field-owner-query",
}
AUTHORIZATION_COUNTS = {"processCount", "formCount", "usernameCount", "secureCount", "modifySettingsCount"}
AUTHORIZATION_FLAGS = {"uiElementsEnabled", "recognizedHeading", "recognizedText"}
FOCUS_OWNER_FLAGS = {"focusOwnerIsAuthenticationAgent", "focusOwnerIsSystemSettings", "focusOwnerIsSecurityPrivacyExtension"}
FOCUS_FLAGS = {"focusAvailable", "focusIsSecureField"} | FOCUS_OWNER_FLAGS
USERNAME_OWNER_FLAGS = {"usernameOwnerIsAuthenticationAgent", "usernameOwnerIsSystemSettings", "usernameOwnerIsSecurityPrivacyExtension"}
FOCUS_PIDS = {"focusOwnerPID", "usernameOwnerPID"}
FOCUS_ERRORS = {0, *range(-25214, -25199)}


def validate_authorization_receipt(output):
    try:
        receipt = json.loads(output)
    except (ValueError, TypeError):
        raise ValueError("Invalid native-authorization receipt") from None
    if (not isinstance(receipt, dict) or set(receipt) != {"authorized", "stage", "diagnostics"}
            or type(receipt["authorized"]) is not bool or not isinstance(receipt["stage"], str)
            or receipt["stage"] not in AUTHORIZATION_STAGES
            or not isinstance(receipt["diagnostics"], dict)):
        raise ValueError("Invalid native-authorization receipt")
    diagnostics = receipt["diagnostics"]
    if set(diagnostics) != (AUTHORIZATION_COUNTS | AUTHORIZATION_FLAGS | FOCUS_FLAGS | USERNAME_OWNER_FLAGS | FOCUS_PIDS | {"focusError"}):
        raise ValueError("Invalid native-authorization diagnostics")
    if any(type(diagnostics[key]) is not int or not 0 <= diagnostics[key] <= 256
           for key in AUTHORIZATION_COUNTS):
        raise ValueError("Invalid native-authorization counts")
    if any(type(diagnostics[key]) is not bool for key in AUTHORIZATION_FLAGS | FOCUS_FLAGS | USERNAME_OWNER_FLAGS):
        raise ValueError("Invalid native-authorization flags")
    if (any(type(diagnostics[key]) is not int or not 0 <= diagnostics[key] <= 2_147_483_647 for key in FOCUS_PIDS)
            or type(diagnostics["focusError"]) is not int or diagnostics["focusError"] not in FOCUS_ERRORS):
        raise ValueError("Invalid native-authorization focus metadata")
    if receipt["authorized"] != (receipt["stage"] == "complete"):
        raise ValueError("Inconsistent native-authorization receipt")
    if receipt["authorized"] and (
            not all(diagnostics[key] for key in AUTHORIZATION_FLAGS)
            or any(diagnostics[key] != 1 for key in AUTHORIZATION_COUNTS)
            or not diagnostics["focusAvailable"] or not diagnostics["focusIsSecureField"]
            or diagnostics["focusOwnerPID"] == 0 or diagnostics["usernameOwnerPID"] == 0
            or sum(diagnostics[key] for key in FOCUS_OWNER_FLAGS) != 1
            or sum(diagnostics[key] for key in USERNAME_OWNER_FLAGS) != 1):
        raise ValueError("Native-authorization completion lacks form proof")
    return receipt


def validate_authorization_progress(output):
    if not isinstance(output, str) or len(output.encode("utf-8")) > 65_536:
        raise ValueError("Invalid native-authorization progress size")
    lines = output.splitlines()
    if not 1 <= len(lines) <= 128:
        raise ValueError("Invalid native-authorization progress count")
    receipts = [validate_authorization_receipt(line) for line in lines]
    return receipts[-1]


def stop_authorization(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def start_authorization():
    account = runpy.run_path(str(ROOT / "scripts/prepare-release-ui-account.py"))
    directory = account["hosted_directory"]()
    record, _ = account["read_record"](directory)
    if (record.get("verified") is not True
            or account["account_identity"]() != {"uid": record.get("uid"), "generated_uid": record.get("generated_uid")}
            or not isinstance(record.get("password"), str) or not 32 <= len(record["password"]) <= 128):
        raise ValueError("Unverified native-authorization account")
    process = subprocess.Popen([
        "/usr/bin/osascript", "-l", "JavaScript",
        str(ROOT / "Tests/ReleaseReadiness/AuthorizeRecordingSettings.js"),
    ], cwd=ROOT, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        process.stdin.write(json.dumps({"username": record["username"], "password": record["password"]}))
        process.stdin.close()
        process.stdin = None
    except (OSError, ValueError):
        stop_authorization(process)
        process.communicate(timeout=5)
        raise ValueError("Could not supply native-authorization input") from None
    return process


def collect_authorization(process, evidence, *, required):
    was_running = process.poll() is None
    timed_out = False
    try:
        if not required:
            stop_authorization(process)
        output, errors = process.communicate(timeout=10)
    except subprocess.TimeoutExpired:
        timed_out = True
        stop_authorization(process)
        output, errors = process.communicate(timeout=5)
    status = {"wasRunning": was_running, "returnCode": process.returncode, "timedOut": timed_out,
              "stdoutBytes": len(output.encode("utf-8")), "stderrBytes": len(errors.encode("utf-8"))}
    (evidence / "authorization-process.json").write_text(json.dumps(status, indent=2) + "\n")
    print("Native authorization process: " + json.dumps(status, sort_keys=True), flush=True)
    try:
        receipt = validate_authorization_progress(output)
    except ValueError:
        if required:
            raise
        print("Native-authorization helper produced no valid completion receipt.", flush=True)
        return
    (evidence / "authorization.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print("Native authorization: " + json.dumps(receipt, sort_keys=True), flush=True)
    describe_focus_owner(receipt["diagnostics"]["focusOwnerPID"], evidence)
    describe_focus_owner(receipt["diagnostics"]["usernameOwnerPID"], evidence, filename="authorization-username-owner.json")
    if required and timed_out:
        raise ValueError("Native-authorization helper did not finish")
    if required and (process.returncode != 0 or not receipt["authorized"]):
        raise ValueError("Native recording authorization failed at stage " + receipt["stage"])


def describe_focus_owner(pid, evidence, *, filename="authorization-owner.json"):
    if pid == 0:
        return
    identity = {"pid": pid, "stage": "process", "appleSigned": False,
                "executable": "unavailable", "bundleIdentifier": "unavailable"}
    try:
        result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "comm="],
                                capture_output=True, text=True, timeout=5, check=True)
        path = Path(result.stdout.strip()).resolve(strict=True)
        identity["stage"] = "path"
        if (not any(path.is_relative_to(root) for root in
                    ("/System/Library", "/System/Applications/System Settings.app"))
                or not path.is_file() or path.stat().st_uid != 0):
            raise ValueError
        identity.update(executable=str(path), stage="metadata")
        for bundle in path.parents:
            if bundle.suffix not in {".app", ".bundle", ".xpc", ".appex"}:
                continue
            with (bundle / "Contents/Info.plist").open("rb") as source:
                identifier = plistlib.load(source).get("CFBundleIdentifier")
            if isinstance(identifier, str) and re.fullmatch(r"com\.apple\.[A-Za-z0-9_.-]{1,128}", identifier):
                identity["bundleIdentifier"] = identifier
            break
        identity["stage"] = "signature"
        subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "-R=anchor apple", str(path)],
                       capture_output=True, timeout=5, check=True)
        identity.update(appleSigned=True, stage="complete")
    except (OSError, ValueError, subprocess.SubprocessError, plistlib.InvalidFileException):
        pass
    (evidence / filename).write_text(json.dumps(identity, indent=2) + "\n")
    print("Native authorization owner: " + json.dumps(identity, sort_keys=True), flush=True)


def run(arguments, *, timeout, log=None):
    if log is None:
        return subprocess.check_output(arguments, cwd=ROOT, text=True, timeout=timeout)
    try:
        with log.open("w") as output:
            subprocess.run(arguments, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT,
                           check=True, timeout=timeout)
    except subprocess.SubprocessError:
        raise ValueError("Private subprocess failed: " + log.name) from None


def check_system_playback(speech, evidence):
    started = time.monotonic()
    receipt = {"stage": "system-player-before-xctest", "passed": False, "timedOut": False}
    try:
        with (evidence / "private-playback.log").open("w") as output:
            subprocess.run([str(evidence / "derived/readiness-afplay"), str(speech)], check=True, timeout=30,
                           stdout=output, stderr=subprocess.STDOUT)
        receipt["passed"] = True
    except subprocess.TimeoutExpired:
        receipt["timedOut"] = True
        raise ValueError("System playback failed before UI-test startup") from None
    finally:
        receipt["elapsedSeconds"] = round(time.monotonic() - started, 3)
        (evidence / "stage.json").write_text(json.dumps(receipt) + "\n")


def owned_processes(roots, ownership):
    names = {path.name[:15] for root in roots for path in root.rglob("*")}
    # ucomm avoids reading every process's argument memory; exact kernel path and birth still establish ownership.
    listing = subprocess.check_output(["/bin/ps", "-axo", "pid=,uid=,ucomm="], text=True, timeout=5)
    found = []
    for line in listing.splitlines():
        fields = line.split(maxsplit=2)
        if len(fields) != 3:
            raise ValueError("Incomplete process inventory")
        pid, uid = map(int, fields[:2])
        if uid != os.getuid() or fields[2].rstrip()[:15] not in names:
            continue
        identity = ownership["process"](pid)
        if identity is None:
            continue
        executable = ownership["executable"](pid, missing_ok=True)
        if executable is None or not any(Path(executable).is_relative_to(root) for root in roots):
            continue
        if ownership["same"](identity):
            found.append({**identity, "executable": executable})
    return found


def run_ui(arguments, *, timeout, log, roots, evidence):
    ownership = runpy.run_path(str(ROOT / "scripts/test-display/supervisor.py"))
    if owned_processes(roots, ownership):
        raise ValueError("Refusing pre-existing installed-app or UI-runner processes")
    observed = {}
    process = None
    forced = False
    timed_out = False
    phase = "command-start"
    original_failure = {}
    deadline = time.monotonic() + timeout
    try:
        with log.open("w") as output:
            process = subprocess.Popen(arguments, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            phase = "command-identity"
            command = ownership["birth"](process.pid)
            observed[process.pid] = command
            while process.poll() is None:
                phase = "process-monitor"
                for identity in owned_processes(roots, ownership):
                    observed[identity["pid"]] = identity
                phase = "command-deadline"
                if time.monotonic() >= deadline:
                    timed_out = True
                    raise ValueError("Installed-app UI execution exceeded its bound")
                time.sleep(0.25)
            phase = "command-result"
            if process.returncode:
                raise ValueError("Installed-app UI cases failed; raw output remains private")
    except BaseException as error:
        if isinstance(error, subprocess.TimeoutExpired):
            kind = "subprocess-timeout"
        elif isinstance(error, subprocess.CalledProcessError):
            kind = "subprocess-status"
        elif isinstance(error, ownership["Refused"]):
            kind = "ownership-refused"
        elif isinstance(error, ValueError):
            kind = "validation"
        elif isinstance(error, OSError):
            kind = "os-error"
        elif isinstance(error, (KeyboardInterrupt, SystemExit)):
            kind = "interrupted"
        else:
            kind = "other"
        original_failure = {"failurePhase": phase, "failureKind": kind}
        raise
    finally:
        status = {"returnCode": process.poll() if process is not None else None, "timedOut": timed_out,
                  "startedUptime": deadline - timeout, "elapsedSeconds": round(time.monotonic() - (deadline - timeout), 3),
                  **original_failure}
        inventory_failed = False
        try:
            for identity in owned_processes(roots, ownership):
                observed[identity["pid"]] = identity
        except (OSError, ValueError, subprocess.SubprocessError, ownership["Refused"]):
            inventory_failed = True
        settle = time.monotonic() + 5
        while time.monotonic() < settle and any(ownership["same"](item) for item in observed.values()):
            if process is not None:
                process.poll()
            time.sleep(0.1)
        for number in (signal.SIGTERM, signal.SIGKILL):
            for identity in observed.values():
                if ownership["same"](identity):
                    if "executable" in identity and ownership["executable"](identity["pid"], missing_ok=True) != identity["executable"]:
                        raise ValueError("Owned process executable changed before cleanup")
                    forced = True
                    ownership["signal_owned"](identity, number)
            settle = time.monotonic() + 5
            while time.monotonic() < settle and any(ownership["same"](item) for item in observed.values()):
                if process is not None:
                    process.poll()
                time.sleep(0.1)
        if process is not None:
            if process.poll() is None:
                forced = True
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            else:
                process.wait(timeout=5)
        remaining = any(ownership["same"](item) for item in observed.values())
        try:
            remaining = bool(owned_processes(roots, ownership)) or remaining
        except (OSError, ValueError, subprocess.SubprocessError, ownership["Refused"]):
            inventory_failed = True
        (evidence / "ui-command.json").write_text(json.dumps(status, indent=2) + "\n")
        receipt = {"observedCount": len(observed), "forcedCleanup": forced, "allOwnedProcessesAbsent": not remaining and not inventory_failed}
        (evidence / "cleanup.json").write_text(json.dumps(receipt, indent=2) + "\n")
        if remaining or forced or inventory_failed:
            raise ValueError("Installed-app UI process cleanup did not finish normally")


def inject_environment(value, environment):
    if {"OPENAI_API_KEY", "RELEASE_READINESS_OPENAI_API_KEY"} & environment.keys():
        raise ValueError("Provider credentials must never enter the UI test manifest")
    count = 0
    if isinstance(value, dict):
        if "TestBundlePath" in value:
            value.setdefault("EnvironmentVariables", {}).update(environment)
            value.update(TestTimeoutsEnabled=True, DefaultTestExecutionTimeAllowance=1200,
                         MaximumTestExecutionTimeAllowance=1200)
            count += 1
        for child in value.values():
            count += inject_environment(child, environment)
    elif isinstance(value, list):
        for child in value:
            count += inject_environment(child, environment)
    return count


def validate_summary(summary, count=1):
    expected = {"totalTestCount": count, "passedTests": count, "failedTests": 0, "skippedTests": 0}
    for key, value in expected.items():
        if type(summary.get(key)) is not int or summary[key] != value:
            raise ValueError(f"UI probe requires all {count} cases to pass: {key}")


def build_ui(evidence, architecture):
    project = ROOT / "Tests/ReleaseReadiness/ReleaseReadiness.xcodeproj"
    derived = evidence / "derived"
    run(["/usr/bin/xcodebuild", "build-for-testing", "-project", str(project),
         "-scheme", "ReleaseReadiness", "-destination", f"platform=macOS,arch={architecture}",
         "-derivedDataPath", str(derived), f"ARCHS={architecture}", "ONLY_ACTIVE_ARCH=YES",
         "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_REQUIRED=NO"], timeout=300, log=evidence / "build.log")
    manifests = list((derived / "Build/Products").glob("*.xctestrun"))
    if len(manifests) != 1:
        raise ValueError("Expected one compiled UI test manifest")
    player = derived / "readiness-afplay"
    # Keep the Apple player under an owned root so failed UI tests cannot leave playback behind.
    shutil.copy("/usr/bin/afplay", player)
    run(["/usr/bin/codesign", "--verify", "--strict", "-R=anchor apple", str(player)], timeout=30)
    return derived, manifests[0]


def configure_manifest(template, phase, environment):
    with template.open("rb") as source:
        manifest = plistlib.load(source)
    if inject_environment(manifest, {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted",
                                    "RUNNER_OS": "macOS", "GITHUB_WORKSPACE": str(ROOT),
                                    "JARVIS_READINESS_EVIDENCE": str(phase), **environment}) != 1:
        raise ValueError("Expected one external UI test target")
    configured = template.with_name("HostedJourney.xctestrun")
    with configured.open("wb") as output:
        plistlib.dump(manifest, output)
    return configured


def take_key(environment):
    key = environment.pop("RELEASE_READINESS_OPENAI_API_KEY", "")
    environment.pop("OPENAI_API_KEY", None)
    if not isinstance(key, str) or not 20 <= len(key) <= 1024 or any(c.isspace() for c in key):
        raise ValueError("A dedicated protected OpenAI readiness key is required")
    return key.encode("utf-8")


def private_write(path, data):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        output.write(data)


def version_tuple(value):
    if not isinstance(value, str) or not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", value):
        raise ValueError("Expected a stable release version")
    return tuple(map(int, value.split(".")))


def verify_app(path, installed):
    if path == installed or path.resolve(strict=True) != path or not path.is_dir():
        raise ValueError("Candidate and predecessor must be separate verified app bundles")
    with (path / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if (info.get("CFBundleIdentifier") != "com.jarvis.coach"
            or info.get("CFBundleExecutable") != "JarvisApp" or info.get("JarvisDevelopmentBuild")):
        raise ValueError("A normal production app identity is required")
    version = info.get("CFBundleShortVersionString")
    version_tuple(version)
    run(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(path)], timeout=30)
    run(["/usr/sbin/spctl", "--assess", "--type", "execute", str(path)], timeout=30)
    return version


def validate_journey(receipt, phase):
    flags = {"nativeProcessVerified", "normalQuit", "defaultsRestored"}
    if (not isinstance(receipt, dict) or set(receipt) != flags | {"schemaVersion", "phase", "skills", "sessions"}
            or type(receipt["schemaVersion"]) is not int or receipt["schemaVersion"] != 1
            or receipt["phase"] != phase or type(receipt["skills"]) is not int or receipt["skills"] != 5
            or any(receipt[key] is not True for key in flags)):
        raise ValueError("Incomplete basic release journey")
    expected = [("GPT Transcribe", 1)] if phase == "predecessor" else [
        (model, cycle) for model in ("GPT Transcribe", "GPT-4o Transcribe") for cycle in (1, 2)]
    sessions = receipt["sessions"]
    proof = {"fullActive", "freshSession", "stimulusTranscript", "shortcutHint", "stopped", "auditComplete"}
    if not isinstance(sessions, list) or len(sessions) != len(expected):
        raise ValueError("Missing required model or restart journey")
    for session, (model, cycle) in zip(sessions, expected):
        if (not isinstance(session, dict) or set(session) != proof | {"model", "cycle"}
                or session["model"] != model or type(session["cycle"]) is not int or session["cycle"] != cycle
                or any(session[key] is not True for key in proof)):
            raise ValueError("Incomplete model/restart proof")
    return receipt


def profile_snapshot(profile, preferences):
    with preferences.open("rb") as source:
        values = plistlib.load(source)
    selected = {key: value for key, value in values.items()
                if key.startswith(("brain.", "transcription.", "coaching.", "onboarding."))}
    if selected.get("onboarding.completed") is not True:
        raise ValueError("Predecessor must create a genuinely used profile")
    files = [profile / "openai-api-key"]
    sessions = profile / "sessions"
    directories = sorted(path for path in sessions.iterdir() if path.is_dir())
    if not directories:
        raise ValueError("Predecessor must retain a completed real session")
    for directory in directories:
        files.extend([directory / "jarvis-activity.jsonl", directory / "audit-health.json"])
        with (directory / "audit-health.json").open() as source:
            if json.load(source).get("state") != "complete":
                raise ValueError("Predecessor session is incomplete")
    hashes = {}
    for path in files:
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > 8_388_608:
            raise ValueError("Invalid private profile evidence")
        hashes[path.relative_to(profile).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    return selected, hashes


def require_preserved(profile, preferences, snapshot, *, check_preferences):
    selected, hashes = snapshot
    if check_preferences:
        with preferences.open("rb") as source:
            current = plistlib.load(source)
        if any(current.get(key) != value for key, value in selected.items()):
            raise ValueError("Upgrade changed retained user preferences")
    for relative, digest in hashes.items():
        path = profile / relative
        if path.is_symlink() or not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise ValueError("Upgrade changed retained credentials or session history")


def run_phase(name, version, app, evidence, derived, template, speech, architecture, upgrade_profile=None):
    phase = evidence / name
    phase.mkdir(mode=0o700)
    environment = {"JARVIS_READINESS_APP_PATH": str(app), "JARVIS_READINESS_EXPECTED_VERSION": version,
                   "JARVIS_READINESS_PHASE": name, "JARVIS_READINESS_SPEECH_FILE": str(speech),
                   "JARVIS_READINESS_PLAYER": str(derived / "readiness-afplay")}
    if upgrade_profile is not None:
        environment["JARVIS_READINESS_UPGRADE_PROFILE"] = str(upgrade_profile)
    configured = configure_manifest(template, phase, environment)
    result = phase / "result.xcresult"
    authorization = start_authorization()
    try:
        try:
            run_ui(["/usr/bin/xcodebuild", "test-without-building", "-xctestrun", str(configured),
                    "-destination", f"platform=macOS,arch={architecture}", "-resultBundlePath", str(result),
                    "-only-testing:ReleaseReadiness/ReleaseReadinessTests/testInstalledJourney",
                    "-parallel-testing-enabled", "NO", "-maximum-test-execution-time-allowance", "1200"],
                   timeout=1320, log=phase / "test.log", roots=[app, derived], evidence=phase)
        finally:
            collect_authorization(authorization, phase, required=False)
    finally:
        stop_authorization(authorization)
    summary = json.loads(run(["/usr/bin/xcrun", "xcresulttool", "get", "test-results", "summary",
                             "--path", str(result)], timeout=30))
    validate_summary(summary)
    with (phase / "journey.json").open() as source:
        validate_journey(json.load(source), name)
    counts = {key: summary[key] for key in ("totalTestCount", "passedTests", "failedTests", "skippedTests")}
    private_write(phase / "summary.json", (json.dumps(counts) + "\n").encode())


def main():
    key = take_key(os.environ)
    account = pwd.getpwuid(os.getuid())
    if (sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true"
            or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted"
            or account.pw_name != "runner" or account.pw_dir != "/Users/runner"):
        raise ValueError("Release journeys require a disposable GitHub-hosted Mac")
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--candidate", type=Path)
    mode.add_argument("--setup-candidate", type=Path)
    parser.add_argument("--predecessor", type=Path)
    arguments = parser.parse_args()
    setup = arguments.setup_candidate is not None
    if (setup and arguments.predecessor is not None) or (not setup and arguments.predecessor is None):
        raise ValueError("Full readiness requires candidate and predecessor; setup accepts only its candidate")
    candidate = arguments.setup_candidate if setup else arguments.candidate
    os.umask(0o077)
    home = Path(account.pw_dir)
    app = home / "Applications/Jarvis.app"
    profile = home / "Library/Application Support/Jarvis"
    preferences = home / "Library/Preferences/com.jarvis.coach.plist"
    if any(path.exists() or path.is_symlink() for path in (app, profile, preferences)):
        raise ValueError("Refusing an existing installed app or user profile")
    candidate_version = verify_app(candidate, app)
    predecessor_version = None if setup else verify_app(arguments.predecessor, app)
    if not setup and version_tuple(predecessor_version) >= version_tuple(candidate_version):
        raise ValueError("Supported upgrade requires an older predecessor release")
    evidence = ROOT / ".jarvis/release-ui-probe" / uuid.uuid4().hex
    evidence.mkdir(parents=True, mode=0o700)
    architecture = run(["/usr/bin/uname", "-m"], timeout=5).strip()
    if architecture not in {"arm64", "x86_64"}:
        raise ValueError("Unsupported native architecture")
    print(f"Private release journey evidence: {evidence}", flush=True)
    derived, template = build_ui(evidence, architecture)
    speech = evidence / "private-question.aiff"
    run(["/usr/bin/say", "-v", "Samantha", "-r", "135", "-o", str(speech),
         "How does binary search find a number in a sorted list?"], timeout=60, log=evidence / "speech.log")
    speech.chmod(0o600)
    check_system_playback(speech, evidence)
    app.parent.mkdir(exist_ok=True)
    keyfile = profile / "openai-api-key"
    ownership = runpy.run_path(str(ROOT / "scripts/test-display/supervisor.py"))
    try:
        phases = [("fresh", candidate, candidate_version)]
        if not setup:
            phases += [("predecessor", arguments.predecessor, predecessor_version),
                       ("upgrade", candidate, candidate_version)]
        for name, source, version in phases:
            if owned_processes([app, derived], ownership):
                raise ValueError("Cannot replace an app with a live owned process")
            if app.exists():
                shutil.rmtree(app)
            run(["/usr/bin/ditto", str(source), str(app)], timeout=60)
            upgrade_profile = None
            if name == "predecessor":
                run(["/usr/bin/defaults", "delete", "com.jarvis.coach"], timeout=10)
                shutil.rmtree(profile)
            if name != "upgrade":
                profile.mkdir(mode=0o700)
                private_write(keyfile, key)
            else:
                require_preserved(profile, preferences, snapshot, check_preferences=True)
                upgrade_profile = evidence / "private-upgrade-profile.plist"
                private_write(upgrade_profile, plistlib.dumps(snapshot[0]))
            run_phase(name, version, app, evidence, derived, template, speech, architecture, upgrade_profile)
            if name == "predecessor":
                snapshot = profile_snapshot(profile, preferences)
            elif name == "upgrade":
                require_preserved(profile, preferences, snapshot, check_preferences=False)
        if setup:
            receipt = {"schemaVersion": 1, "check": "setup-feasibility", "releaseReady": False,
                       "architecture": architecture, "candidateVersion": candidate_version,
                       "phases": ["fresh"], "passed": True}
            filename = "setup-feasibility.json"
        else:
            receipt = {"schemaVersion": 1, "check": "release-readiness", "releaseReady": True,
                       "architecture": architecture, "candidateVersion": candidate_version,
                       "predecessorVersion": predecessor_version, "phases": ["fresh", "predecessor", "upgrade"],
                       "passed": True, "retainedPreferences": True, "retainedCredential": True, "retainedSessionHistory": True}
            filename = "readiness.json"
        private_write(evidence / filename, (json.dumps(receipt) + "\n").encode())
        print("Completed " + receipt["check"] + "; proof is recorded in " + filename)
    finally:
        if keyfile.exists():
            if keyfile.is_symlink() or keyfile.read_bytes() != key:
                raise ValueError("Refusing changed credential during cleanup")
            keyfile.unlink()


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError):
        print("Release journey failed; private diagnostic files were not published.", file=sys.stderr)
        raise SystemExit(1)
