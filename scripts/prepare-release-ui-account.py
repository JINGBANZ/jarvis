#!/usr/bin/env python3
"""Own one temporary administrator on a disposable GitHub-hosted Mac."""

import json
import os
from pathlib import Path
import plistlib
import pwd
import secrets
import stat
import subprocess
import sys


ACCOUNT = "jarvisacceptance"
ACCOUNT_HOME = f"/Users/{ACCOUNT}"
FILENAME = "jarvis-ui-authorization.json"
MARKER = "jarvis-release-ui-authorization-v1"


def hosted_directory():
    user = pwd.getpwuid(os.getuid())
    if (sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true"
            or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted"
            or user.pw_name != "runner" or user.pw_dir != "/Users/runner"):
        raise ValueError("host-guard")
    directory = Path(os.environ.get("RUNNER_TEMP", ""))
    if not directory.is_absolute() or directory.resolve(strict=True) != directory:
        raise ValueError("temporary-directory")
    info = directory.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise ValueError("temporary-directory")
    return directory


def command(arguments, *, stage, input_text=None):
    try:
        result = subprocess.run(arguments, input=input_text, text=True, capture_output=True, timeout=45)
    except (OSError, subprocess.SubprocessError):
        raise ValueError(stage) from None
    if result.returncode:
        raise ValueError(stage)
    return result


def account_identity():
    try:
        account = pwd.getpwnam(ACCOUNT)
    except KeyError:
        return None
    if account.pw_dir != ACCOUNT_HOME:
        raise ValueError("account-home")
    result = command(["/usr/bin/dscl", "-plist", ".", "-read", f"/Users/{ACCOUNT}", "GeneratedUID"],
                     stage="account-identity")
    try:
        values = plistlib.loads(result.stdout.encode())
        generated_uid = values["dsAttrTypeStandard:GeneratedUID"]
        if len(generated_uid) != 1 or not isinstance(generated_uid[0], str) or account.pw_uid < 501:
            raise ValueError
        return {"uid": account.pw_uid, "generated_uid": generated_uid[0]}
    except (ValueError, KeyError, TypeError, plistlib.InvalidFileException):
        raise ValueError("account-identity") from None


def write_record(fd, record):
    encoded = (json.dumps(record) + "\n").encode()
    os.lseek(fd, 0, os.SEEK_SET)
    os.ftruncate(fd, 0)
    with os.fdopen(os.dup(fd), "wb") as output:
        output.write(encoded)
        output.flush()
        os.fsync(output.fileno())


def read_record(directory):
    descriptor = os.open(directory / FILENAME, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as source:
        info = os.fstat(source.fileno())
        if (not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600
                or info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_size > 4096):
            raise ValueError("credential-file-ownership")
        try:
            record = json.load(source)
        except (ValueError, UnicodeError):
            raise ValueError("credential-file-format") from None
    if (not isinstance(record, dict) or record.get("marker") != MARKER
            or record.get("username") != ACCOUNT or record.get("owner_uid") != os.getuid()):
        raise ValueError("credential-file-marker")
    return record, info


def verify_authentication(password):
    # dscl's documented interactive authonly command keeps the password out of argv.
    for value, should_succeed in [(secrets.token_urlsafe(32), False), (password, True)]:
        try:
            result = subprocess.run(["/usr/bin/dscl", "-q", "."],
                                    input=f"authonly {ACCOUNT} {value}\nquit\n", text=True,
                                    capture_output=True, timeout=15)
        except (OSError, subprocess.SubprocessError):
            raise ValueError("account-authentication") from None
        succeeded = result.returncode == 0 and not result.stdout.strip() and not result.stderr.strip()
        if succeeded != should_succeed:
            raise ValueError("account-authentication")


def prepare(directory):
    if account_identity() is not None:
        raise ValueError("account-already-exists")
    if os.path.lexists(ACCOUNT_HOME):
        raise ValueError("account-home-already-exists")
    descriptor = os.open(directory / FILENAME, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    record = {"marker": MARKER, "username": ACCOUNT, "owner_uid": os.getuid(),
              "password": secrets.token_urlsafe(32), "verified": False}
    try:
        write_record(descriptor, record)
        creation_error = None
        try:
            command(["/usr/bin/sudo", "-n", "/usr/sbin/sysadminctl", "-addUser", ACCOUNT,
                     "-fullName", "Jarvis Release Acceptance", "-home", ACCOUNT_HOME,
                     "-password", "-", "-admin"],
                    stage="account-creation", input_text=record["password"] + "\n")
        except ValueError as error:
            creation_error = error
        identity = account_identity()
        if identity is not None:
            record.update(identity)
            write_record(descriptor, record)
        if creation_error is not None:
            raise creation_error
        if identity is None:
            raise ValueError("account-creation")
        membership = command(["/usr/bin/dsmemberutil", "checkmembership", "-U", ACCOUNT, "-G", "admin"],
                             stage="account-membership")
        if membership.stdout.strip() != "user is a member of the group":
            raise ValueError("account-membership")
        verify_authentication(record["password"])
        record["verified"] = True
        write_record(descriptor, record)
    finally:
        os.close(descriptor)


def cleanup(directory):
    try:
        record, original = read_record(directory)
    except FileNotFoundError:
        return
    identity = account_identity()
    if identity is not None:
        if identity != {"uid": record.get("uid"), "generated_uid": record.get("generated_uid")}:
            raise ValueError("cleanup-identity-mismatch")
        command(["/usr/bin/sudo", "-n", "/usr/sbin/sysadminctl", "-deleteUser", ACCOUNT],
                stage="account-deletion")
        if account_identity() is not None:
            raise ValueError("account-deletion")
    current = os.lstat(directory / FILENAME)
    if (current.st_dev, current.st_ino) != (original.st_dev, original.st_ino):
        raise ValueError("cleanup-file-replaced")
    os.unlink(directory / FILENAME)


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in {"prepare", "cleanup"}:
        raise ValueError("usage-prepare-or-cleanup")
    os.umask(0o077)
    directory = hosted_directory()
    {"prepare": prepare, "cleanup": cleanup}[sys.argv[1]](directory)
    print(f"Temporary release UI account {sys.argv[1]} completed.")


if __name__ == "__main__":
    try:
        main()
    except ValueError as error:
        print(f"Temporary release UI account failed: {error}", file=sys.stderr)
        raise SystemExit(1)
    except OSError:
        print("Temporary release UI account failed: filesystem-or-directory-service", file=sys.stderr)
        raise SystemExit(1)
