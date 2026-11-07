#!/usr/bin/env python3
"""Run the packaged app's fixed, offline installation diagnostic."""

import argparse
import json
from pathlib import Path
import platform
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile


PREFIX = "JARVIS_INSTALLATION_CHECK "
CHECKS = ["speech-model", "speech-inference", "audio-processing", "skills"]


class VerificationError(Exception):
    pass


def native_architecture():
    architecture = platform.machine()
    if architecture not in ("arm64", "x86_64"):
        raise VerificationError("unsupported native Mac architecture")
    if architecture == "x86_64":
        result = subprocess.run(["/usr/sbin/sysctl", "-n", "-i", "sysctl.proc_translated"],
                                check=True, capture_output=True, text=True, timeout=5)
        if result.stdout.strip() not in ("", "0"):
            raise VerificationError("installation verification must run natively, outside Rosetta")
    return architecture


def validate_receipt(output, app, version, architecture):
    lines = [line[len(PREFIX):] for line in output.splitlines() if line.startswith(PREFIX)]
    if len(lines) != 1:
        raise VerificationError("expected exactly one installation diagnostic receipt")
    try:
        receipt = json.loads(lines[0])
    except json.JSONDecodeError as error:
        raise VerificationError("malformed installation diagnostic receipt") from error
    if not isinstance(receipt, dict) or receipt.get("schema") != 1:
        raise VerificationError("unsupported installation diagnostic receipt")
    for name, expected in (("version", version), ("architecture", architecture)):
        if receipt.get(name) != expected:
            raise VerificationError(f"installation receipt does not match {name}")
    bundle_path = receipt.get("bundlePath")
    if not isinstance(bundle_path, str) or not Path(bundle_path).is_absolute():
        raise VerificationError("installation receipt does not match bundlePath")
    try:
        matches_app = Path(bundle_path).resolve(strict=True) == app.resolve(strict=True)
    except (OSError, ValueError, RuntimeError) as error:
        raise VerificationError("installation receipt does not match bundlePath") from error
    if not matches_app:
        raise VerificationError("installation receipt does not match bundlePath")
    if receipt.get("status") != "passed":
        raise VerificationError(f"installation diagnostic failed: {receipt.get('error', 'no reason')}")
    if receipt.get("checks") != CHECKS:
        raise VerificationError("installation diagnostic did not complete every required check")
    skills = receipt.get("skills")
    if (not isinstance(skills, list) or not skills
            or not all(isinstance(name, str) and name for name in skills)
            or skills != sorted(set(skills))):
        raise VerificationError("installation diagnostic did not verify a skill catalog")
    return receipt


def verify_app(app):
    app = Path(app).resolve(strict=True)
    if app.suffix != ".app" or not app.is_dir():
        raise VerificationError("expected an application bundle")
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleExecutable") != "JarvisApp":
        raise VerificationError("app declares an unexpected executable")
    version = info.get("CFBundleShortVersionString")
    if not isinstance(version, str) or not version:
        raise VerificationError("app has no release version")
    binary = app / "Contents/MacOS/JarvisApp"
    if PREFIX.encode() not in binary.read_bytes():
        raise VerificationError("app does not contain the installation diagnostic")
    architecture = native_architecture()
    directory = Path(tempfile.mkdtemp(prefix="jarvis-installation-", dir="/private/tmp"))
    exit_proven = True
    try:
        isolated_app = directory / "Jarvis.app"
        subprocess.run(["/usr/bin/ditto", str(app), str(isolated_app)], check=True, timeout=60)
        output, errors = directory / "stdout.log", directory / "stderr.log"
        command = ["/usr/bin/open", "-n", "-W", "-g", "--arch", architecture,
                   "--stdout", str(output), "--stderr", str(errors), str(isolated_app),
                   "--args", "--verify-installation"]
        try:
            exit_proven = False
            launched = subprocess.run(command, cwd=directory, capture_output=True, text=True, timeout=45)
        except subprocess.TimeoutExpired as error:
            raise VerificationError("installation diagnostic timed out") from error
        if launched.returncode != 0:
            raise VerificationError(f"could not launch installation diagnostic: {launched.stderr.strip()}")
        exit_proven = True
        contents = output.read_text() if output.is_file() else ""
        return validate_receipt(contents, isolated_app, version, architecture)
    finally:
        if exit_proven:
            shutil.rmtree(directory)
        else:
            print(f"Diagnostic exit is unproven; preserving {directory}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    arguments = parser.parse_args()
    def interrupted(number, _frame):
        raise KeyboardInterrupt(f"signal {number}")
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, interrupted)
    try:
        receipt = verify_app(arguments.app)
    except KeyboardInterrupt:
        print("Installation verification interrupted", file=sys.stderr)
        return 130
    except (VerificationError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Installation verification failed: {error}", file=sys.stderr)
        return 1
    print(f"Installation verification passed: {receipt['version']} {receipt['architecture']}; "
          f"{len(receipt['skills'])} bundled skills; model inference and audio processing")
    return 0


if __name__ == "__main__":
    sys.exit(main())
