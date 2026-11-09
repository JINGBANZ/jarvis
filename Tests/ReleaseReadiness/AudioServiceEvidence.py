"""Read-only, scalar crash evidence for the disposable hosted audio fixture."""

from datetime import datetime
import fnmatch
import hashlib
import json
import math
import os
from pathlib import Path
import pwd
import runpy
import stat
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
DIRECTORIES = (Path("/Library/Logs/DiagnosticReports"),
               Path("/Users/runner/Library/Logs/DiagnosticReports"))
MAX_REPORT_BYTES = 4 * 1024 * 1024
EXCEPTIONS = {"EXC_BAD_ACCESS", "EXC_CRASH", "EXC_RESOURCE", "EXC_GUARD",
              "EXC_BAD_INSTRUCTION", "EXC_BREAKPOINT", "EXC_ARITHMETIC", "EXC_SOFTWARE"}
SIGNALS = {"SIGSEGV", "SIGBUS", "SIGABRT", "SIGKILL", "SIGTRAP", "SIGILL", "SIGFPE", "SIGTERM"}


def hosted():
    runner = pwd.getpwnam("runner")
    if (sys.platform != "darwin" or os.getuid() != 0 or runner.pw_dir != "/Users/runner"
            or os.environ.get("SUDO_UID") != str(runner.pw_uid)
            or os.environ.get("SUDO_USER") != "runner"
            or os.environ.get("GITHUB_ACTIONS") != "true"
            or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted"
            or Path(os.environ.get("GITHUB_WORKSPACE", "")).resolve() != ROOT
            or ROOT.stat().st_uid != runner.pw_uid):
        raise ValueError("Audio evidence requires the disposable hosted runner")


def inventory():
    found, unavailable = {}, False
    for directory in DIRECTORIES:
        try:
            if directory.resolve(strict=True) != directory or not directory.is_dir():
                raise ValueError
            with os.scandir(directory) as entries:
                for count, entry in enumerate(entries):
                    if count >= 4096:
                        raise ValueError
                    if not fnmatch.fnmatchcase(entry.name, "coreaudiod*.ips"):
                        continue
                    info = entry.stat(follow_symlinks=False)
                    identity = f"{info.st_dev}:{info.st_ino}:{info.st_mtime_ns}:{info.st_size}"
                    found[hashlib.sha256(identity.encode()).hexdigest()] = Path(entry.path)
                    if len(found) > 32:
                        raise ValueError
        except FileNotFoundError:
            continue
        except (OSError, ValueError):
            unavailable = True
    return dict(list(found.items())[:32]), unavailable


def daemon_identity():
    ownership = runpy.run_path(str(ROOT / "scripts/test-display/supervisor.py"))
    listing = subprocess.check_output(["/bin/ps", "-axo", "pid=,comm="], text=True, timeout=3)
    result = []
    for line in listing.splitlines():
        fields = line.split(maxsplit=1)
        if len(fields) != 2 or fields[1] != "/usr/sbin/coreaudiod":
            continue
        pid = int(fields[0])
        first = ownership["process"](pid)
        if (first is None or ownership["executable"](pid, missing_ok=True) != "/usr/sbin/coreaudiod"
                or not ownership["same"](first)):
            raise ValueError("Audio daemon identity unavailable")
        result.append({"pid": pid, "start": first["start"]})
    if len(result) != 1:
        raise ValueError("Audio daemon identity is not unique")
    return result[0]


def snapshot():
    reports, failed = inventory()
    value = {"schemaVersion": 1, "wallTime": time.time(), "reportIDs": sorted(reports),
             "inventoryUnavailable": failed, "daemonUnavailable": False}
    try:
        value["daemon"] = daemon_identity()
    except Exception:
        value["daemonUnavailable"] = True
    return value


def read_report(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as source:
        info = os.fstat(source.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1
                or not 0 < info.st_size <= MAX_REPORT_BYTES):
            raise ValueError("Crash report type or size refused")
        raw = source.read(MAX_REPORT_BYTES + 1)
        if len(raw) != info.st_size:
            raise ValueError("Crash report changed during inspection")
    return raw


def summarize_report(raw, start, end):
    if not 0 < len(raw) <= MAX_REPORT_BYTES:
        raise ValueError("Crash report size refused")
    text = raw.decode("utf-8", errors="strict")
    decoder = json.JSONDecoder()
    metadata, offset = decoder.raw_decode(text)
    offset += len(text[offset:]) - len(text[offset:].lstrip())
    body, finish = decoder.raw_decode(text, offset)
    if text[finish:].strip() or not isinstance(metadata, dict) or not isinstance(body, dict):
        raise ValueError("Malformed crash report")
    if (metadata.get("bug_type") != "309" or body.get("procName") != "coreaudiod"
            or body.get("procPath") != "/usr/sbin/coreaudiod"):
        return None
    captured = datetime.fromisoformat(body["captureTime"])
    if captured.tzinfo is None or not start <= captured.timestamp() <= end:
        return None
    images, threads, index = body["usedImages"], body["threads"], body["faultingThread"]
    if (not isinstance(images, list) or not isinstance(threads, list) or len(images) > 4096
            or len(threads) > 4096 or type(index) is not int or not 0 <= index < len(threads)):
        raise ValueError("Malformed crash image or thread indexes")
    frames = threads[index]["frames"]
    if not isinstance(frames, list) or not 0 < len(frames) <= 512:
        raise ValueError("Malformed crash frames")
    roc = {i for i, image in enumerate(images) if isinstance(image, dict)
           and image.get("path") == "/Library/Audio/Plug-Ins/HAL/roc_vad.driver/Contents/MacOS/roc_vad"}
    result = {"rocImageLoaded": bool(roc), "rocFrameCount": 0, "ringBufferFrame": False,
              "requestHandlerFrame": False, "memoryFillCopyFrame": False}
    for frame in frames:
        if not isinstance(frame, dict) or type(frame.get("imageIndex")) is not int:
            raise ValueError("Malformed crash frame")
        image_index = frame["imageIndex"]
        if not 0 <= image_index < len(images):
            raise ValueError("Invalid crash image index")
        symbol = frame.get("symbol", "")
        if not isinstance(symbol, str) or len(symbol) > 4096:
            raise ValueError("Malformed crash symbol")
        if image_index in roc:
            result["rocFrameCount"] += 1
            result["ringBufferFrame"] |= "RingBuffer" in symbol
            result["requestHandlerFrame"] |= "RequestHandler" in symbol
        result["memoryFillCopyFrame"] |= any(name in symbol for name in
                                              ("memcpy", "memmove", "memset", "std::__1::fill", "std::__1::copy"))
    exception = body.get("exception", {})
    if not isinstance(exception, dict):
        raise ValueError("Malformed crash exception")
    result["exception"] = exception.get("type") if exception.get("type") in EXCEPTIONS else "other"
    result["signal"] = exception.get("signal") if exception.get("signal") in SIGNALS else "other"
    return result


def positive_number(value):
    return type(value) in (int, float) and math.isfinite(value) and value > 0


def validate_identity(value):
    if (not isinstance(value, dict) or set(value) != {"pid", "start"}
            or type(value["pid"]) is not int or not 0 < value["pid"] < 2 ** 31
            or not isinstance(value["start"], list) or len(value["start"]) != 2
            or any(type(item) is not int for item in value["start"])
            or not 0 < value["start"][0] < 2 ** 63 or not 0 <= value["start"][1] < 1_000_000):
        raise ValueError("Invalid daemon identity")


def validate_snapshot(value):
    required = {"schemaVersion", "wallTime", "reportIDs", "inventoryUnavailable", "daemonUnavailable"}
    if (not isinstance(value, dict) or set(value) - {"daemon"} != required
            or type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1
            or not positive_number(value["wallTime"])
            or any(type(value[key]) is not bool for key in ("inventoryUnavailable", "daemonUnavailable"))
            or not isinstance(value["reportIDs"], list) or len(value["reportIDs"]) > 32
            or any(not isinstance(item, str) or len(item) != 64 or any(c not in "0123456789abcdef" for c in item)
                   for item in value["reportIDs"])
            or ("daemon" in value) == value["daemonUnavailable"]):
        raise ValueError("Invalid audio evidence snapshot")
    if "daemon" in value:
        validate_identity(value["daemon"])
    return value


def validate_result(value):
    required = {"schemaVersion", "reportCollectionUnavailable", "daemonBeforeAvailable", "daemonAfterAvailable",
                "matchedReports", "unreadableReports", "unmatchedReports", "windowStart", "windowEnd"}
    optional = {"daemonBefore", "daemonAfter", "daemonChanged"}
    if (not isinstance(value, dict) or set(value) - optional != required
            or type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1
            or any(type(value[key]) is not bool for key in
                   ("reportCollectionUnavailable", "daemonBeforeAvailable", "daemonAfterAvailable"))
            or any(type(value[key]) is not int or not 0 <= value[key] <= 32 for key in
                   ("unreadableReports", "unmatchedReports"))
            or not positive_number(value["windowStart"]) or not positive_number(value["windowEnd"])
            or not 0 <= value["windowEnd"] - value["windowStart"] < 600
            or not isinstance(value["matchedReports"], list) or len(value["matchedReports"]) > 32):
        raise ValueError("Invalid audio evidence result")
    for key in ("daemonBefore", "daemonAfter"):
        if (key in value) != value[key + "Available"]:
            raise ValueError("Invalid daemon availability")
        if key in value:
            validate_identity(value[key])
    both = value["daemonBeforeAvailable"] and value["daemonAfterAvailable"]
    if (("daemonChanged" in value) != both or (both and
            (type(value["daemonChanged"]) is not bool
             or value["daemonChanged"] != (value["daemonBefore"] != value["daemonAfter"])))):
        raise ValueError("Invalid daemon change evidence")
    for report in value["matchedReports"]:
        booleans = {"rocImageLoaded", "ringBufferFrame", "requestHandlerFrame", "memoryFillCopyFrame"}
        if (not isinstance(report, dict) or set(report) != booleans | {"rocFrameCount", "exception", "signal"}
                or any(type(report[key]) is not bool for key in booleans)
                or type(report["rocFrameCount"]) is not int or not 0 <= report["rocFrameCount"] <= 512
                or report["exception"] not in EXCEPTIONS | {"other"} or report["signal"] not in SIGNALS | {"other"}):
            raise ValueError("Invalid scalar crash summary")
    return value


def collect(before):
    validate_snapshot(before)
    after = snapshot()
    result = {"schemaVersion": 1, "reportCollectionUnavailable": before["inventoryUnavailable"] or after["inventoryUnavailable"],
              "daemonBeforeAvailable": not before["daemonUnavailable"], "daemonAfterAvailable": not after["daemonUnavailable"],
              "matchedReports": [], "unreadableReports": 0, "unmatchedReports": 0,
              "windowStart": before["wallTime"], "windowEnd": after["wallTime"]}
    for key, source in (("daemonBefore", before), ("daemonAfter", after)):
        if not source["daemonUnavailable"]:
            result[key] = source["daemon"]
    if "daemonBefore" in result and "daemonAfter" in result:
        result["daemonChanged"] = result["daemonBefore"] != result["daemonAfter"]
    reports, failed = inventory()
    result["reportCollectionUnavailable"] |= failed
    for identity, path in reports.items():
        if identity in before["reportIDs"]:
            continue
        try:
            summary = summarize_report(read_report(path), before["wallTime"], after["wallTime"])
            if summary is None:
                result["unmatchedReports"] += 1
            else:
                result["matchedReports"].append(summary)
        except Exception:
            result["unreadableReports"] += 1
    return validate_result(result)


def main():
    hosted()
    if sys.argv[1:] == ["before"]:
        value = snapshot()
    elif sys.argv[1:] == ["after"]:
        raw = sys.stdin.buffer.read(16385)
        if len(raw) > 16384:
            raise ValueError("Evidence baseline exceeds bound")
        before = validate_snapshot(json.loads(raw))
        if not 0 <= time.time() - before["wallTime"] < 600:
            raise ValueError("Evidence baseline refused")
        value = collect(before)
    else:
        raise ValueError("Invalid audio evidence command")
    print(json.dumps(value, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print('{"schemaVersion":1,"collectionUnavailable":true}')
        sys.exit(1)
