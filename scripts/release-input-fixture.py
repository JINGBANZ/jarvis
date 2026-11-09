#!/usr/bin/env python3
"""Pinned input-only audio fixture for disposable hosted macOS release checks."""

import argparse
import hashlib
import http.client
import io
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import pwd
import ssl
import stat
import struct
import subprocess
import tarfile
import time
import urllib.error
import urllib.request
import wave

ROOT = Path(__file__).resolve().parent.parent
BASE = ROOT / ".jarvis/release-input-fixture"
UID = "com.jarvis.release-input"
NAME = "Jarvis Synthetic Microphone"
ROC_URL = "https://github.com/roc-streaming/roc-vad/releases/download/v0.0.4/roc-vad.tar.bz2"
ROC_SHA = "efa3ab380092de554160dc02140702d2b4f9aa2ddb503cf2b90618cdbc95e29a"
FFMPEG_URL = "https://ffmpeg.org/releases/ffmpeg-8.0.1.tar.xz"
FFMPEG_SHA = "05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41"
ROC = Path("/usr/local/bin/roc-vad")
DRIVER = Path("/Library/Audio/Plug-Ins/HAL/roc_vad.driver")
OWNERSHIP = {"schemaVersion": 1, "micUID": UID, "name": NAME,
             "type": "receiver", "rocArchiveSHA256": ROC_SHA}


def hosted():
    account = pwd.getpwuid(os.getuid())
    if (platform.system() != "Darwin" or platform.machine() not in {"arm64", "x86_64"}
            or os.environ.get("GITHUB_ACTIONS") != "true"
            or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted"
            or account.pw_name != "runner" or account.pw_dir != "/Users/runner"
            or Path(os.environ.get("GITHUB_WORKSPACE", "")).resolve() != ROOT):
        raise ValueError("Input fixture requires a disposable GitHub-hosted macOS workspace")
    os.umask(0o077)


def run(arguments, *, timeout=30, cwd=None, log=None):
    if log is not None:
        result = subprocess.run(arguments, cwd=cwd, stdin=subprocess.DEVNULL,
                                stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
    else:
        result = subprocess.run(arguments, cwd=cwd, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    if result.returncode:
        raise RuntimeError("Input fixture command failed: " + Path(str(arguments[0])).name)
    return result.stdout.decode("utf-8", errors="strict") if log is None else ""


def private_directory(path):
    if not path.is_absolute() or path.resolve(strict=True) != path:
        raise ValueError("Fixture directory must be absolute and not contain symlinks")
    info = path.stat()
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise ValueError("Fixture directory must be owned and private")


def create(path, data, mode=0o600):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    with os.fdopen(descriptor, "wb") as output:
        output.write(data)
        output.flush()
        os.fsync(output.fileno())


def receipt(path, value):
    create(path, (json.dumps(value, sort_keys=True) + "\n").encode())


def receiver_inventory():
    lines = [line.split(maxsplit=4) for line in run([str(ROC), "device", "list"]).splitlines() if line.strip()]
    if not lines or lines[0] != ["index", "type", "state", "uid", "name"]:
        raise ValueError("Unrecognized Roc device inventory")
    devices = {}
    for fields in lines[1:]:
        if (len(fields) != 5 or not fields[0].isdigit() or int(fields[0]) <= 0
                or fields[1] not in {"sender", "receiver"} or fields[2] not in {"on", "off"}
                or fields[3] in devices):
            raise ValueError("Malformed Roc device inventory")
        devices[fields[3]] = {"type": fields[1], "name": fields[4]}
    return devices


def claim_receiver():
    if UID in receiver_inventory():
        raise ValueError("Refusing to replace a preexisting receiver UID")
    receipt(BASE / "ownership.json", OWNERSHIP)
    descriptor = os.open(BASE, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def remove_owned_receiver():
    private_directory(BASE)
    path = BASE / "ownership.json"
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as source:
        info = os.fstat(source.fileno())
        if (not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600
                or info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_size > 4096
                or json.load(source) != OWNERSHIP):
            raise ValueError("Refusing to remove an unowned receiver")
    device = receiver_inventory().get(UID)
    if device is not None:
        if device != {"type": "receiver", "name": NAME}:
            raise ValueError("Owned receiver identity changed")
        run([str(ROC), "device", "del", "--uid", UID])
    if UID in receiver_inventory():
        raise RuntimeError("Owned receiver remains after cleanup")
    return device is not None


def transient_download_error(error):
    if isinstance(error, urllib.error.HTTPError):
        return error.code in {408, 429} or 500 <= error.code <= 599
    if isinstance(error, urllib.error.URLError):
        error = error.reason
    if isinstance(error, ssl.SSLCertVerificationError):
        return False
    return isinstance(error, (ConnectionResetError, ConnectionAbortedError, BrokenPipeError,
                              TimeoutError, http.client.IncompleteRead,
                              http.client.RemoteDisconnected, ssl.SSLEOFError))


def download(url, expected):
    for attempt in range(3):
        try:
            with urllib.request.urlopen(url, timeout=60) as source:
                length = source.getheader("Content-Length")
                if length is not None:
                    if not length.isdecimal() or int(length) > 30_000_000:
                        raise ValueError("Pinned fixture archive has invalid size metadata")
                    length = int(length)
                data = source.read(30_000_001)
                if length is not None and len(data) < length:
                    raise http.client.IncompleteRead(b"", length - len(data))
        except (OSError, http.client.HTTPException) as error:
            if isinstance(error, urllib.error.HTTPError):
                error.close()
            if attempt == 2 or not transient_download_error(error):
                raise RuntimeError("Pinned fixture dependency download failed") from None
            time.sleep(attempt + 1)
            continue
        if len(data) > 30_000_000 or hashlib.sha256(data).hexdigest() != expected:
            raise ValueError("Pinned fixture archive checksum mismatch")
        return data


def install_roc():
    if DRIVER.exists() or DRIVER.is_symlink() or ROC.exists() or ROC.is_symlink():
        raise ValueError("Refusing to replace an existing Roc installation")
    paths = {
        "/usr/local/bin/roc-vad": (BASE / "roc-vad", 0o755),
        "/Library/Audio/Plug-Ins/HAL/roc_vad.driver/Contents/Info.plist":
            (BASE / "roc_vad.driver/Contents/Info.plist", 0o644),
        "/Library/Audio/Plug-Ins/HAL/roc_vad.driver/Contents/MacOS/roc_vad":
            (BASE / "roc_vad.driver/Contents/MacOS/roc_vad", 0o755),
    }
    with tarfile.open(fileobj=io.BytesIO(download(ROC_URL, ROC_SHA)), mode="r:bz2") as archive:
        files = [entry for entry in archive.getmembers() if not entry.isdir()]
        if {entry.name for entry in files} != paths.keys() or len(files) != len(paths):
            raise ValueError("Unexpected Roc release archive contents")
        for entry in files:
            if not entry.isfile() or entry.size > 40_000_000:
                raise ValueError("Roc archive must contain only expected regular files")
            target, mode = paths[entry.name]
            target.parent.mkdir(parents=True, exist_ok=True)
            create(target, archive.extractfile(entry).read(), mode)
    with (BASE / "roc_vad.driver/Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if (info.get("CFBundleIdentifier") != "org.rocstreaming.rocvad"
            or info.get("DriverSocket") != "127.0.0.1:9712"):
        raise ValueError("Unexpected Roc driver identity or non-loopback control socket")
    for executable in (BASE / "roc-vad", BASE / "roc_vad.driver/Contents/MacOS/roc_vad"):
        run(["/usr/bin/lipo", str(executable), "-verify_arch", "arm64", "x86_64"])
    run(["/usr/bin/sudo", "/bin/mkdir", "-p", str(ROC.parent)])
    run(["/usr/bin/sudo", "/usr/bin/install", "-m", "755", str(BASE / "roc-vad"), str(ROC)])
    run(["/usr/bin/sudo", "/usr/bin/ditto", str(BASE / "roc_vad.driver"), str(DRIVER)])
    run(["/usr/bin/sudo", "/usr/sbin/chown", "-R", "root:wheel", str(DRIVER)])
    run(["/usr/bin/sudo", "/bin/chmod", "-R", "a+rX", str(DRIVER)])
    run(["/usr/bin/sudo", "/usr/bin/killall", "coreaudiod"])
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        try:
            if "driver is loaded" in run([str(ROC), "info"], timeout=3):
                return
        except (RuntimeError, subprocess.TimeoutExpired):
            pass
        time.sleep(0.25)
    raise RuntimeError("Roc driver did not become ready")


def build_ffmpeg():
    with tarfile.open(fileobj=io.BytesIO(download(FFMPEG_URL, FFMPEG_SHA)), mode="r:xz") as archive:
        members = archive.getmembers()
        if any(not Path(entry.name).parts or Path(entry.name).parts[0] != "ffmpeg-8.0.1" or ".." in Path(entry.name).parts
               or not (entry.isdir() or entry.isfile()) for entry in members):
            raise ValueError("Unexpected FFmpeg source archive contents")
        if sum(entry.size for entry in members) > 200_000_000:
            raise ValueError("FFmpeg source archive exceeds bound")
        archive.extractall(BASE, members=members, filter="data")
    source = BASE / "ffmpeg-8.0.1"
    arguments = ["/bin/sh", str(source / "configure"), "--disable-everything", "--disable-autodetect",
                 "--disable-doc", "--disable-debug", "--disable-asm", "--disable-avdevice",
                 "--disable-swscale", "--disable-programs", "--enable-ffmpeg", "--disable-shared",
                 "--enable-static", "--enable-network", "--enable-protocol=file,pipe,rtp,udp",
                 "--enable-demuxer=wav", "--enable-decoder=pcm_s16le", "--enable-encoder=pcm_s16be",
                 "--enable-muxer=rtp", "--enable-filter=aresample,anull,aformat", "--enable-swresample",
                 "--extra-cflags=-mmacosx-version-min=15.0", "--extra-ldflags=-mmacosx-version-min=15.0"]
    with (BASE / "private-build.log").open("xb") as log:
        run(arguments, timeout=180, cwd=source, log=log)
        run(["/usr/bin/make", "-j", "3", "ffmpeg"], timeout=600, cwd=source, log=log)
    create(BASE / "ffmpeg", (source / "ffmpeg").read_bytes(), 0o755)
    run(["/usr/bin/lipo", str(BASE / "ffmpeg"), "-verify_arch", platform.machine()])
    return hashlib.sha256((BASE / "ffmpeg").read_bytes()).hexdigest()


def setup():
    BASE.parent.mkdir(parents=True, exist_ok=True)
    BASE.mkdir(mode=0o700)
    private_directory(BASE)
    executable_sha = build_ffmpeg()
    install_roc()
    claim_receiver()
    try:
        run([str(ROC), "device", "add", "receiver", "--uid", UID, "--name", NAME,
             "--device-rate", "48000", "--device-chans", "stereo"])
        run([str(ROC), "device", "bind", "--uid", UID, "--source", "rtp://127.0.0.1:10001",
             "--control", "rtcp://127.0.0.1:10002"])
        receipt(BASE / "setup.json", {"schemaVersion": 1, "passed": True, "micUID": UID,
                "rocVersion": "0.0.4", "rocArchiveSHA256": ROC_SHA, "ffmpegVersion": "8.0.1",
                "ffmpegSourceSHA256": FFMPEG_SHA, "ffmpegSHA256": executable_sha,
                "architecture": platform.machine(), "deviceSampleRate": 48000, "channels": 2,
                "wireSampleRate": 44100, "payloadType": 10, "loopbackOnly": True})
    except BaseException:
        remove_owned_receiver()
        raise


def prepare(app, directory):
    private_directory(BASE)
    private_directory(directory)
    if (not directory.is_relative_to(ROOT / ".jarvis/release-ui-probe")
            or app != directory / "derived/Jarvis Route Fixture.app"
            or app.resolve(strict=True) != app):
        raise ValueError("Fixture app must belong to this private run")
    manifest = json.loads((BASE / "setup.json").read_text())
    executable = BASE / "ffmpeg"
    if (manifest.get("architecture") != platform.machine() or manifest.get("micUID") != UID
            or manifest.get("rocArchiveSHA256") != ROC_SHA or manifest.get("ffmpegSourceSHA256") != FFMPEG_SHA
            or hashlib.sha256(executable.read_bytes()).hexdigest() != manifest.get("ffmpegSHA256")):
        raise ValueError("Prepared input fixture identity mismatch")
    helper = app / "Contents/Helpers/ffmpeg"
    helper.parent.mkdir(mode=0o700)
    create(helper, executable.read_bytes(), 0o755)
    run(["/usr/bin/codesign", "--force", "--sign", "-", str(helper)])
    for name, active in [("private-mic-input.wav", True), ("private-mic-silence.wav", False)]:
        samples = bytearray()
        for frame in range(8 * 44100):
            value = round(0.1 * 32767 * math.sin(2 * math.pi * 997 * frame / 44100)) if active else 0
            samples.extend(struct.pack("<hh", value, value))
        output = io.BytesIO()
        with wave.open(output, "wb") as audio:
            audio.setnchannels(2)
            audio.setsampwidth(2)
            audio.setframerate(44100)
            audio.writeframes(samples)
        create(directory / name, output.getvalue())
    receipt(directory / "input-fixture.json", {**manifest, "prepared": True,
            "sourceDurationSeconds": 8, "quietSourcePrepared": True})


def teardown():
    path = BASE / "ownership.json"
    if not path.exists() and not path.is_symlink():
        return
    removed = remove_owned_receiver()
    receipt(BASE / "teardown.json", {"schemaVersion": 1, "receiverRemoved": removed,
            "receiverAbsent": True, "micUID": UID})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    subcommands.add_parser("setup")
    command = subcommands.add_parser("prepare")
    command.add_argument("--app", type=Path, required=True)
    command.add_argument("--directory", type=Path, required=True)
    subcommands.add_parser("teardown")
    arguments = parser.parse_args()
    hosted()
    if arguments.command == "setup":
        setup()
    elif arguments.command == "prepare":
        prepare(arguments.app, arguments.directory)
    else:
        teardown()


if __name__ == "__main__":
    main()
