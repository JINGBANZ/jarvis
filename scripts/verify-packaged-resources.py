#!/usr/bin/env python3
"""Check packaged model and skill bytes against this checkout without launching the app."""

import argparse
import hashlib
from pathlib import Path
import plistlib
import stat
import sys
from xml.parsers.expat import ExpatError


REPOSITORY = Path(__file__).resolve().parent.parent
RESOURCES = (
    ("Jarvis_JarvisApp.bundle", "SileroVAD.mlmodelc", "Sources/JarvisApp/Resources/SileroVAD.mlmodelc"),
    ("Jarvis_JarvisCore.bundle", "Skills", "Sources/JarvisCore/Resources/Skills"),
)


class VerificationError(ValueError):
    pass


def require_directory(path):
    if not stat.S_ISDIR(path.lstat().st_mode):
        raise VerificationError(f"expected a regular directory: {path}")


def require_file(path):
    if not stat.S_ISREG(path.lstat().st_mode):
        raise VerificationError(f"expected a regular file: {path}")


def read_info(path):
    require_file(path)
    try:
        with path.open("rb") as stream:
            info = plistlib.load(stream)
    except (ValueError, plistlib.InvalidFileException, ExpatError) as error:
        raise VerificationError(f"invalid property list: {path}") from error
    if not isinstance(info, dict):
        raise VerificationError(f"expected a property-list dictionary: {path}")
    return info


def resource_directory(bundle, name):
    require_directory(bundle)
    contents = bundle / "Contents"
    if contents.exists() or contents.is_symlink():
        require_directory(contents)
        info = read_info(contents / "Info.plist")
        if info.get("CFBundlePackageType") != "BNDL":
            raise VerificationError(f"expected a resource bundle: {bundle}")
        resources = contents / "Resources"
        require_directory(resources)
        flat = bundle / name
        if flat.exists() or flat.is_symlink():
            raise VerificationError(f"ambiguous resource bundle layout: {bundle}")
        return resources / name
    return bundle / name


def resource_tree(root):
    require_directory(root)
    entries = {}

    def visit(directory):
        for path in sorted(directory.iterdir()):
            relative = path.relative_to(root).as_posix()
            mode = path.lstat().st_mode
            if stat.S_ISDIR(mode):
                entries[relative] = None
                visit(path)
            elif stat.S_ISREG(mode):
                digest = hashlib.sha256()
                with path.open("rb") as stream:
                    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                        digest.update(chunk)
                entries[relative] = digest.hexdigest()
            else:
                raise VerificationError(f"resource is not a regular file or directory: {path}")

    visit(root)
    if not any(value is not None for value in entries.values()):
        raise VerificationError(f"resource tree contains no files: {root}")
    return entries


def verify_app(app, repository=REPOSITORY):
    app = Path(app).absolute()
    require_directory(app)
    if app.suffix != ".app":
        raise VerificationError("expected an application bundle")
    require_directory(app / "Contents")
    info = read_info(app / "Contents/Info.plist")
    if info.get("CFBundleExecutable") != "JarvisApp":
        raise VerificationError("app declares an unexpected executable")
    version = info.get("CFBundleShortVersionString")
    if not isinstance(version, str) or not version:
        raise VerificationError("app has no release version")
    require_directory(app / "Contents/MacOS")
    require_file(app / "Contents/MacOS/JarvisApp")
    resources = app / "Contents/Resources"
    require_directory(resources)
    for bundle, name, source in RESOURCES:
        expected = resource_tree(repository / source)
        actual = resource_tree(resource_directory(resources / bundle, name))
        if actual != expected:
            raise VerificationError(f"packaged resource differs from checkout: {name}")
    return version


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    arguments = parser.parse_args()
    try:
        version = verify_app(arguments.app)
    except (OSError, ValueError) as error:
        print(f"Packaged resource verification failed: {error}", file=sys.stderr)
        return 1
    print(f"Packaged resource verification passed: {version}; model and skills match checkout inputs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
