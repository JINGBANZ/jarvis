#!/usr/bin/env python3
"""Credential-free installed-app UI feasibility check on disposable GitHub-hosted Macs."""

import json
import math
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


def owned_processes(roots, ownership):
    listing = subprocess.check_output(["/bin/ps", "-axo", "pid=,uid=,comm="], text=True, timeout=5)
    found = []
    for line in listing.splitlines():
        fields = line.split(maxsplit=2)
        if len(fields) != 3:
            raise ValueError("Incomplete process inventory")
        pid, uid = map(int, fields[:2])
        if uid != os.getuid() or not any(Path(fields[2]).is_relative_to(root) for root in roots):
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
        for identity in owned_processes(roots, ownership):
            observed[identity["pid"]] = identity
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
            process.wait(timeout=5)
        remaining = any(ownership["same"](item) for item in observed.values()) or bool(owned_processes(roots, ownership))
        (evidence / "ui-command.json").write_text(json.dumps(status, indent=2) + "\n")
        receipt = {"observedCount": len(observed), "forcedCleanup": forced, "allOwnedProcessesAbsent": not remaining}
        (evidence / "cleanup.json").write_text(json.dumps(receipt, indent=2) + "\n")
        if remaining or forced:
            raise ValueError("Installed-app UI process cleanup did not finish normally")


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


def validate_summary(summary, count=3):
    expected = {"totalTestCount": count, "passedTests": count, "failedTests": 0, "skippedTests": 0}
    for key, value in expected.items():
        if type(summary.get(key)) is not int or summary[key] != value:
            raise ValueError(f"UI probe requires all {count} cases to pass: {key}")


def validate_audio_receipt(receipt, mode, phase, *, require_pass=True):
    common = {"schemaVersion", "check", "mode", "phase", "stage", "passed", "outputFrames",
              "rawMic", "globalTap", "defaultsRestored", "resourcesReleased"}
    rtp = mode == "emit" and phase in {"mic", "mic-quiet"}
    specific = {"authorize": {"microphoneAuthorized", "tapCreated", "ioStarted", "nativeConsentAcknowledged", "captureGrantProven"},
                "capture": {"micUID", "systemUID", "sampleRate", "micChannels", "measurementStartUptime", "measurementEndUptime"},
                "emit": {"emitterUID", "sampleRate", "senderStartUptime", "senderEndUptime"}}[mode]
    if rtp:
        specific |= {"micChannels", "transport", "wireSampleRate", "outputDurationSeconds", "sourceDurationSeconds",
                     "senderElapsedSeconds", "senderExitCode", "senderReaped"}
    timing = {"microphoneRequestUptime", "microphoneFinishedUptime", "microphoneAuthorizationStatus",
              "microphoneCallbackReceived", "microphoneCompletionUptime"} if mode == "authorize" else set()
    io_timing = {"ioStartRequestedUptime", "ioStartReturnedUptime"} if mode == "authorize" else set()
    failure_stages = {"authorizationFailureStage"} if mode == "authorize" else set()
    failures = {"failureStage", "failureReason", "failureOSStatus"}
    capture_diagnostics = {"finalDefaultInputMatchesRequested", "finalDefaultOutputMatchesRequested",
                           "invalidBufferReason", "invalidBufferCount", "invalidBufferIndex",
                           "invalidBufferChannels", "invalidBufferByteSize", "invalidBufferHasData",
                           "invalidBufferUptime", "beforeIOState", "failureState"} if mode == "capture" else set()
    checks = {"authorize": "fixture-capture-consent-bootstrap", "capture": "production-aggregate-route-isolation",
              "emit": "synthetic-microphone-rtp" if rtp else "virtual-device-tone-emission"}
    if (not isinstance(receipt, dict) or not common <= receipt.keys()
            or receipt.keys() - common - specific - timing - io_timing - failure_stages - failures - capture_diagnostics - {"error"}
            or type(receipt["schemaVersion"]) is not int or receipt["schemaVersion"] != 1
            or receipt["mode"] != mode or receipt["phase"] != phase or receipt["check"] != checks[mode]
            or receipt["stage"] != "complete"):
        raise ValueError("Invalid audio fixture receipt identity")
    for key in {"passed", "defaultsRestored", "resourcesReleased"} | (specific if mode == "authorize" else set()):
        if key in receipt and type(receipt[key]) is not bool:
            raise ValueError("Invalid audio fixture flags")
    metrics = {"frames", "rms", "micToneAmplitude", "systemToneAmplitude", "micToneFraction", "systemToneFraction"}
    for route in ("rawMic", "globalTap"):
        value = receipt[route]
        if not isinstance(value, dict) or value.keys() != metrics:
            raise ValueError("Invalid route metric shape")
        if type(value["frames"]) is not int or not 0 <= value["frames"] <= 10_000_000:
            raise ValueError("Invalid route frame count")
        if any(type(value[key]) not in (int, float) or not math.isfinite(value[key]) or not 0 <= value[key] <= 10
               for key in metrics - {"frames"}):
            raise ValueError("Invalid route energy")
    if type(receipt["outputFrames"]) is not int or not 0 <= receipt["outputFrames"] <= 10_000_000:
        raise ValueError("Invalid emitter frame count")
    if "sampleRate" in receipt and (type(receipt["sampleRate"]) not in (int, float)
                                    or not math.isfinite(receipt["sampleRate"]) or not 8_000 <= receipt["sampleRate"] <= 192_000):
        raise ValueError("Invalid audio sample rate")
    if "micChannels" in receipt and (type(receipt["micChannels"]) is not int or receipt["micChannels"] != 2):
        raise ValueError("Unexpected microphone fixture format")
    if "sampleRate" in receipt and receipt["sampleRate"] != 48_000:
        raise ValueError("Unexpected hosted audio sample rate")
    identities = {"micUID": "com.jarvis.release-input", "systemUID": "BlackHole2ch_UID",
                  "emitterUID": "com.jarvis.release-input" if rtp else "BlackHole2ch_UID"}
    if any(key in receipt and receipt[key] != value for key, value in identities.items()):
        raise ValueError("Audio fixture route identity mismatch")
    if rtp:
        for key in {"outputDurationSeconds", "sourceDurationSeconds", "senderElapsedSeconds"} & receipt.keys():
            if type(receipt[key]) not in (int, float) or not math.isfinite(receipt[key]) or not 0 <= receipt[key] <= 60:
                raise ValueError("Invalid synthetic microphone duration")
        if ("transport" in receipt and receipt["transport"] != "rtp"
                or "wireSampleRate" in receipt and (type(receipt["wireSampleRate"]) is not int or receipt["wireSampleRate"] != 44_100)
                or "senderReaped" in receipt and type(receipt["senderReaped"]) is not bool
                or "senderExitCode" in receipt and (type(receipt["senderExitCode"]) is not int or not -128 <= receipt["senderExitCode"] <= 255)):
            raise ValueError("Invalid synthetic microphone transport evidence")
    interval = {"capture": ("measurementStartUptime", "measurementEndUptime"),
                "emit": ("senderStartUptime", "senderEndUptime")}.get(mode)
    if interval:
        for key in set(interval) & receipt.keys():
            if type(receipt[key]) not in (int, float) or not math.isfinite(receipt[key]) or not 0 < receipt[key] < 10_000_000_000:
                raise ValueError("Invalid audio interval time")
        if interval[1] in receipt and (interval[0] not in receipt or receipt[interval[1]] < receipt[interval[0]]
                or receipt[interval[1]] == receipt[interval[0]] and (require_pass or receipt["passed"] is not False)):
            raise ValueError("Invalid audio interval order")
    if "error" in receipt and (not isinstance(receipt["error"], str) or len(receipt["error"]) > 1_024):
        raise ValueError("Invalid audio failure metadata")
    failure_values = {
        "failureStage": {"arguments", "paths", "operation", "device-selection", "formats", "defaults", "tap",
                         "aggregate", "io-proc", "phase-start", "io-start", "capture", "final-defaults", "score", "cleanup", "final-quit",
                         "sender-setup", "sender-start", "sender-progress", "sender-exit", "sender-duration"},
        "failureReason": {"validation", "os-status", "interrupted", "invalid-buffers", "timeout", "defaults-changed",
                          "intended-tone-missing", "tone-leak", "unexpected-energy", "unexpected-tone", "cleanup", "other",
                          "child-exit", "duration-mismatch"},
        "invalidBufferReason": {"count", "channels", "bytes", "missing-data", "non-finite"},
    }
    for key, values in failure_values.items():
        if key in receipt and (type(receipt[key]) is not str or receipt[key] not in values):
            raise ValueError("Unknown audio failure category")
    if failures & receipt.keys() and (not {"failureStage", "failureReason"} <= receipt.keys() or receipt["passed"] is not False):
        raise ValueError("Audio failure diagnostics require a failed receipt")
    if "failureOSStatus" in receipt and (type(receipt["failureOSStatus"]) is not int
            or not -(2 ** 31) <= receipt["failureOSStatus"] < 2 ** 31):
        raise ValueError("Invalid audio failure status")
    for key in {"finalDefaultInputMatchesRequested", "finalDefaultOutputMatchesRequested", "invalidBufferHasData"} & receipt.keys():
        if type(receipt[key]) is not bool:
            raise ValueError("Invalid capture diagnostic flag")
    for key in {"invalidBufferCount", "invalidBufferChannels", "invalidBufferByteSize", "invalidBufferIndex"} & receipt.keys():
        maximum = 1 if key == "invalidBufferIndex" else 2 ** 32 - 1
        if type(receipt[key]) is not int or not 0 <= receipt[key] <= maximum:
            raise ValueError("Invalid capture buffer metadata")
    if "invalidBufferUptime" in receipt and (type(receipt["invalidBufferUptime"]) not in (int, float)
            or not math.isfinite(receipt["invalidBufferUptime"]) or not 0 < receipt["invalidBufferUptime"] < 10_000_000_000):
        raise ValueError("Invalid buffer observation time")
    layout = {key for key in capture_diagnostics if key.startswith("invalidBuffer")}
    if layout & receipt.keys() and (not {"invalidBufferReason", "invalidBufferCount"} <= receipt.keys()
            or receipt["passed"] is not False
            or receipt["invalidBufferReason"] != "count" and not layout <= receipt.keys()):
        raise ValueError("Incomplete failed capture layout")
    snapshot_flags = {"micEnumerated", "micAlive", "micObjectMatchesRequested", "aggregateMicActive",
                      "aggregateTapMatchesRequested", "defaultInputMatchesRequested", "defaultInputMatchesAggregate"}
    snapshot_counts = {"aggregateActiveSubdeviceCount", "aggregateActiveTapCount"}
    for key in {"beforeIOState", "failureState"} & receipt.keys():
        state = receipt[key]
        if (not isinstance(state, dict) or not {"uptime", "queryFailed"} <= state.keys()
                or state.keys() - snapshot_flags - snapshot_counts - {"uptime", "queryFailed", "queryOSStatus"}
                or type(state["queryFailed"]) is not bool
                or type(state["uptime"]) not in (int, float) or not math.isfinite(state["uptime"])
                or not 0 < state["uptime"] < 10_000_000_000
                or key == "failureState" and receipt["passed"] is not False):
            raise ValueError("Invalid capture device snapshot")
        if not state["queryFailed"] and (not (snapshot_flags | snapshot_counts) <= state.keys() or "queryOSStatus" in state):
            raise ValueError("Incomplete successful device query")
        if any(type(state[name]) is not bool for name in snapshot_flags & state.keys()):
            raise ValueError("Invalid capture device flag")
        if any(type(state[name]) is not int or not 0 <= state[name] <= 4096 for name in snapshot_counts & state.keys()):
            raise ValueError("Invalid capture device count")
        if "queryOSStatus" in state and (type(state["queryOSStatus"]) is not int or not -(2 ** 31) <= state["queryOSStatus"] < 2 ** 31):
            raise ValueError("Invalid capture device query status")
    if timing & receipt.keys():
        if not timing - {"microphoneCompletionUptime"} <= receipt.keys():
            raise ValueError("Incomplete microphone timing")
        if (type(receipt["microphoneCallbackReceived"]) is not bool
                or type(receipt["microphoneAuthorizationStatus"]) is not int
                or receipt["microphoneAuthorizationStatus"] not in range(4)
                or receipt["microphoneCallbackReceived"] != ("microphoneCompletionUptime" in receipt)):
            raise ValueError("Invalid microphone callback metadata")
        for key in timing & receipt.keys() - {"microphoneCallbackReceived", "microphoneAuthorizationStatus"}:
            if type(receipt[key]) not in (int, float) or not math.isfinite(receipt[key]) or not 0 < receipt[key] < 10_000_000_000:
                raise ValueError("Invalid microphone monotonic time")
        start, end = receipt["microphoneRequestUptime"], receipt["microphoneFinishedUptime"]
        if end < start or not start <= receipt.get("microphoneCompletionUptime", start) <= end:
            raise ValueError("Invalid microphone timing order")
    if "authorizationFailureStage" in receipt and (not isinstance(receipt["authorizationFailureStage"], str)
            or receipt["authorizationFailureStage"] not in {
                "paths", "microphone", "tap", "aggregate", "io-proc", "io-start", "acknowledgement", "cleanup"}):
        raise ValueError("Unknown authorization failure stage")
    for key in io_timing & receipt.keys():
        if type(receipt[key]) not in (int, float) or not math.isfinite(receipt[key]) or not 0 < receipt[key] < 10_000_000_000:
            raise ValueError("Invalid recording-start time")
    if "ioStartReturnedUptime" in receipt and (
            "ioStartRequestedUptime" not in receipt
            or receipt["ioStartReturnedUptime"] < receipt["ioStartRequestedUptime"]):
        raise ValueError("Invalid recording-start order")
    safe = {key: value for key, value in receipt.items() if key != "error"}
    safe["errorPresent"] = "error" in receipt
    if not require_pass:
        return safe
    if (not specific <= receipt.keys() or receipt["passed"] is not True or "error" in receipt
            or receipt["defaultsRestored"] is not True or receipt["resourcesReleased"] is not True):
        raise ValueError("Audio fixture phase or cleanup did not pass")
    if mode == "authorize":
        if (receipt["captureGrantProven"] is not False
                or not all(receipt[key] for key in ("microphoneAuthorized", "tapCreated", "ioStarted", "nativeConsentAcknowledged"))
                or receipt.get("microphoneCallbackReceived") is not True or receipt.get("microphoneAuthorizationStatus") != 3
                or "authorizationFailureStage" in receipt or not io_timing <= receipt.keys()
                or receipt.get("ioStartRequestedUptime", 0) < receipt.get("microphoneFinishedUptime", float("inf"))):
            raise ValueError("Fixture consent bootstrap lacks observed acknowledgement")
    elif mode == "emit":
        if rtp:
            if (receipt["outputFrames"] != 0 or receipt["sourceDurationSeconds"] != 8
                    or not 8 <= receipt["outputDurationSeconds"] <= 8.1 or not 7 <= receipt["senderElapsedSeconds"] <= 13
                    or receipt["senderExitCode"] != 0 or receipt["senderReaped"] is not True):
                raise ValueError("Synthetic microphone sender did not complete and reap its finite input")
        elif receipt["outputFrames"] < 8 * receipt["sampleRate"]:
            raise ValueError("Emitter did not complete its finite tone")
    else:
        if any(receipt.get(key, True) is not True for key in (
                "finalDefaultInputMatchesRequested", "finalDefaultOutputMatchesRequested")):
            raise ValueError("Capture defaults changed before completion")
        mic, tap = receipt["rawMic"], receipt["globalTap"]
        if min(mic["frames"], tap["frames"]) < 4 * receipt["sampleRate"]:
            raise ValueError("Both capture routes require the complete measurement")
        intended, inactive = (mic, tap) if phase == "mic-only" else (tap, mic)
        tone = "micTone" if phase == "mic-only" else "systemTone"
        other = "systemTone" if phase == "mic-only" else "micTone"
        amplitude = intended[tone + "Amplitude"]
        if intended["rms"] <= 0.02 or amplitude <= 0.02 or intended[tone + "Fraction"] <= 0.8:
            raise ValueError("Intended route tone is missing")
        if (inactive[tone + "Amplitude"] >= 0.001 or inactive[tone + "Amplitude"] >= amplitude * 0.01
                or inactive["rms"] >= 0.001 or inactive["rms"] >= intended["rms"] * 0.01
                or mic[other + "Amplitude"] >= 0.001 or tap[other + "Amplitude"] >= 0.001):
            raise ValueError("Synthetic audio routes are not independent")
    return safe


def validate_audio_coverage(capture, emitters):
    phases = {"mic-only": {"mic"}, "system-only": {"system", "mic-quiet"}}[capture["phase"]]
    if len(emitters) != len(phases) or {emitter["phase"] for emitter in emitters} != phases:
        raise ValueError("Measurement requires every active and quiet producer")
    for emitter in emitters:
        if (emitter["senderStartUptime"] > capture["measurementStartUptime"]
                or emitter["senderEndUptime"] < capture["measurementEndUptime"]):
            raise ValueError("Synthetic producer did not cover the complete measurement")


def build_ui(evidence, architecture, environment):
    project = ROOT / "Tests/ReleaseReadiness/ReleaseReadiness.xcodeproj"
    derived = evidence / "derived"
    run(["/usr/bin/xcodebuild", "build-for-testing", "-project", str(project),
         "-scheme", "ReleaseReadiness", "-destination", f"platform=macOS,arch={architecture}",
         "-derivedDataPath", str(derived), f"ARCHS={architecture}", "ONLY_ACTIVE_ARCH=YES",
         "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_REQUIRED=NO"], timeout=300, log=evidence / "build.log")
    manifests = list((derived / "Build/Products").glob("*.xctestrun"))
    if len(manifests) != 1:
        raise ValueError("Expected one compiled UI test manifest")
    with manifests[0].open("rb") as source:
        manifest = plistlib.load(source)
    if inject_environment(manifest, {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted",
                                    "RUNNER_OS": "macOS", "GITHUB_WORKSPACE": str(ROOT),
                                    "JARVIS_READINESS_EVIDENCE": str(evidence), **environment}) != 1:
        raise ValueError("Expected one external UI test target")
    configured = manifests[0].with_name("HostedProbe.xctestrun")
    with configured.open("wb") as output:
        plistlib.dump(manifest, output)
    return derived, configured


def audio_service_evidence(before=None):
    helper = ROOT / "Tests/ReleaseReadiness/AudioServiceEvidence.py"
    schema = runpy.run_path(str(helper))
    result = subprocess.run(["/usr/bin/sudo", "-n",
                             "--preserve-env=GITHUB_ACTIONS,RUNNER_ENVIRONMENT,GITHUB_WORKSPACE",
                             sys.executable, "-I", str(helper), "before" if before is None else "after"],
                            input="" if before is None else json.dumps(before),
                            capture_output=True, text=True, timeout=20, check=True)
    if len(result.stdout) > 16_384 or result.stderr:
        raise ValueError("Audio service evidence unavailable")
    value = json.loads(result.stdout)
    return schema["validate_snapshot" if before is None else "validate_result"](value)


def export_audio_service_evidence(evidence, before):
    try:
        value = audio_service_evidence(before) if before is not None else {
            "schemaVersion": 1, "collectionUnavailable": True}
        (evidence / "audio-service.json").write_text(json.dumps(value, indent=2) + "\n")
    except Exception:
        try:
            (evidence / "audio-service.json").write_text('{"schemaVersion":1,"collectionUnavailable":true}\n')
        except OSError:
            print("Audio service evidence could not be retained.", flush=True)


def audio_routes(evidence, architecture):
    fixture = evidence / "derived/Jarvis Route Fixture.app"
    executable = fixture / "Contents/MacOS/AudioRouteProbe"
    executable.parent.mkdir(parents=True, mode=0o700)
    with (fixture / "Contents/Info.plist").open("wb") as output:
        plistlib.dump({"CFBundleIdentifier": "com.jarvis.release-route-fixture", "CFBundleExecutable": "AudioRouteProbe",
                      "CFBundleName": "Jarvis Route Fixture", "CFBundleDisplayName": "Jarvis Route Fixture",
                      "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "LSMinimumSystemVersion": "15.0",
                      "LSUIElement": True, "NSMicrophoneUsageDescription": "Measure synthetic microphone routing.",
                      "NSAudioCaptureUsageDescription": "Measure synthetic system playback for route verification."}, output)
    run(["/usr/bin/swiftc", "-swift-version", "6", "-strict-concurrency=complete", "-warnings-as-errors",
         "-parse-as-library", "-target", architecture + "-apple-macos15.0", "-module-cache-path",
         str(evidence / "module-cache"), "-framework", "CoreAudio", "-framework", "AVFoundation", "-framework", "AppKit",
         str(ROOT / "Tests/ReleaseReadiness/AudioRouteProbe.swift"), "-o", str(executable)],
        timeout=120, log=evidence / "audio-build.log")
    run([sys.executable, str(ROOT / "scripts/release-input-fixture.py"), "prepare", "--app", str(fixture),
         "--directory", str(evidence)], timeout=30, log=evidence / "input-prepare.log")
    run(["/usr/bin/codesign", "--force", "--sign", "-", str(fixture)], timeout=30, log=evidence / "audio-sign.log")
    run(["/usr/bin/codesign", "--verify", "--strict", str(fixture)], timeout=30)
    derived, configured = build_ui(evidence, architecture, {"JARVIS_READINESS_AUDIO_FIXTURE": str(fixture)})
    result = evidence / "result.xcresult"
    phases = [("authorize", "consent", "authorize"), ("capture", "mic-only", "mic-capture"),
              ("emit", "mic", "mic-emit"), ("capture", "system-only", "system-capture"),
              ("emit", "mic-quiet", "mic-quiet-emit"), ("emit", "system", "system-emit")]
    try:
        before = audio_service_evidence()
    except Exception:
        before = None
    try:
        run_ui(["/usr/bin/xcodebuild", "test-without-building", "-xctestrun", str(configured),
                "-destination", f"platform=macOS,arch={architecture}", "-resultBundlePath", str(result),
                "-only-testing:ReleaseReadiness/AudioFixtureTests", "-parallel-testing-enabled", "NO",
                "-maximum-test-execution-time-allowance", "120"],
               timeout=240, log=evidence / "test.log", roots=[derived], evidence=evidence)
    finally:
        export_audio_service_evidence(evidence, before)
        for mode, phase, name in phases:
            path = evidence / f"private-{name}.json"
            if path.exists() and 0 < path.stat().st_size <= 8_192:
                try:
                    safe = validate_audio_receipt(json.loads(path.read_text()), mode, phase, require_pass=False)
                    (evidence / f"route-{name}.json").write_text(json.dumps(safe, indent=2) + "\n")
                except (ValueError, OSError):
                    print("Audio fixture receipt absent or malformed: " + name, flush=True)
    summary = json.loads(run(["/usr/bin/xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)], timeout=30))
    validate_summary(summary, count=1)
    receipts = {}
    for mode, phase, name in phases:
        receipts[name] = validate_audio_receipt(json.loads((evidence / f"private-{name}.json").read_text()), mode, phase)
    validate_audio_coverage(receipts["mic-capture"], [receipts["mic-emit"]])
    validate_audio_coverage(receipts["system-capture"], [receipts["system-emit"], receipts["mic-quiet-emit"]])
    observed = json.loads((evidence / "fixture-consents.json").read_text())
    if (not isinstance(observed, dict) or any(type(value) is not bool for value in observed.values())
            or observed != {"microphoneAllowObserved": True, "systemAudioAllowObserved": True, "captureGrantProven": False}):
        raise ValueError("Fixture requires both observed native consent actions")
    (evidence / "audio-summary.json").write_text(json.dumps({"architecture": architecture, "nativeArchitectureProven": True,
        "bothRoutesIndependent": True, "fixtureCaptureGrantProven": True, "jarvisCaptureGrantProven": False,
        "providerAcceptanceProven": False}, indent=2) + "\n")
    print("Both synthetic OS routes passed; Jarvis capture and provider acceptance remain separate.")


def main():
    account = pwd.getpwuid(os.getuid())
    if (sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true"
            or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted"
            or account.pw_name != "runner" or account.pw_dir != "/Users/runner"):
        raise ValueError("This probe may change app preferences only on a disposable hosted runner")
    if len(sys.argv) != 2:
        raise ValueError("usage: probe-release-ui.py /Users/runner/Applications/Jarvis.app | --audio-routes")
    os.umask(0o077)
    evidence = ROOT / ".jarvis" / "release-ui-probe" / uuid.uuid4().hex
    evidence.mkdir(parents=True, mode=0o700)
    architecture = run(["/usr/bin/uname", "-m"], timeout=5).strip()
    if architecture not in {"arm64", "x86_64"}:
        raise ValueError("Unsupported hosted native architecture")
    print(f"UI probe evidence: {evidence}", flush=True)
    if sys.argv[1] == "--audio-routes":
        audio_routes(evidence, architecture)
        return
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

    started = time.monotonic()
    def stage(name):
        receipt = {"phase": "setup-feasibility", "stage": name,
                   "elapsedSeconds": round(time.monotonic() - started, 3)}
        (evidence / "stage.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print("Setup feasibility: " + json.dumps(receipt, sort_keys=True), flush=True)
    stage("build")
    derived, configured = build_ui(evidence, architecture, {
        "JARVIS_READINESS_APP_PATH": str(app),
        "JARVIS_READINESS_EXPECTED_VERSION": info["CFBundleShortVersionString"],
    })
    result = evidence / "result.xcresult"
    authorization = start_authorization()
    stage("permissions")
    try:
        try:
            run_ui(["/usr/bin/xcodebuild", "test-without-building", "-xctestrun", str(configured),
                 "-destination", f"platform=macOS,arch={architecture}", "-resultBundlePath", str(result),
                 "-only-testing:ReleaseReadiness/ReleaseReadinessTests", "-parallel-testing-enabled", "NO",
                 "-maximum-test-execution-time-allowance", "120"],
                timeout=420, log=evidence / "test.log", roots=[app, derived], evidence=evidence)
        except BaseException:
            try:
                collect_authorization(authorization, evidence, required=False)
            except (OSError, ValueError, subprocess.SubprocessError):
                print("Native-authorization completion remains unproven.", flush=True)
            raise
        collect_authorization(authorization, evidence, required=True)
    finally:
        stop_authorization(authorization)
    summary = json.loads(run(["/usr/bin/xcrun", "xcresulttool", "get", "test-results", "summary",
                             "--path", str(result)], timeout=30))
    validate_summary(summary)
    counts = {key: summary[key] for key in ("totalTestCount", "passedTests", "failedTests", "skippedTests")}
    (evidence / "summary.json").write_text(json.dumps(counts, indent=2) + "\n")
    (evidence / "probe.json").write_text(json.dumps({
        "phase": "setup-feasibility", "app": str(app), "architecture": architecture,
        "version": info["CFBundleShortVersionString"], "passedTests": 3,
        "providerAcceptanceProven": False,
    }, indent=2) + "\n")
    stage("complete")
    print("All three credential-free UI probe cases passed; provider acceptance remains unproven.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"UI probe failed: {error}", file=sys.stderr)
        raise SystemExit(1)
