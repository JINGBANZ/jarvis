#!/usr/bin/env python3

import hashlib
import struct
import sys
from pathlib import Path

from ds_store import DSStore
from mac_alias import Alias


APP_NAME = "Jarvis.app"
APPLICATIONS_NAME = "Applications"
EXPECTED_BACKGROUND_SHA256 = "a0b620ebf085f7bfd975b5cbbf25f3245afd95cef598f4ac80e05a5672e18290"
EXPECTED_ICON_LOCATIONS = {
    APP_NAME: (140, 120),
    APPLICATIONS_NAME: (500, 120),
}
EXPECTED_WINDOW_BOUNDS = "{{100, 100}, {640, 280}}"


def fail(message: str) -> None:
    raise SystemExit(f"error: {message}")


def record(store: DSStore, filename: str, code: str):
    try:
        return store[filename][code]
    except KeyError:
        fail(f"disk image Finder metadata is missing {filename!r} {code!r}")


def require_equal(actual, expected, description: str) -> None:
    if actual != expected:
        fail(f"{description} is {actual!r}; expected {expected!r}")


def alias_text(value):
    return value.decode("utf-8") if isinstance(value, bytes) else value


def verify_background_alias(alias_data, background_path: Path) -> None:
    if not isinstance(alias_data, (bytes, bytearray)):
        fail("Finder background alias is not binary Alias data")

    try:
        actual = Alias.from_bytes(bytes(alias_data))
    except (OverflowError, TypeError, UnicodeError, ValueError, struct.error):
        fail("Finder background alias is malformed")

    if actual.volume is None or actual.target is None:
        fail("Finder background alias has no target identity")

    try:
        expected = Alias.for_file(str(background_path))
    except OSError:
        fail("could not read the mounted arrow background identity")

    identity_fields = (
        ("volume name", alias_text(actual.volume.name), alias_text(expected.volume.name)),
        ("volume creation date", actual.volume.creation_date, expected.volume.creation_date),
        ("volume filesystem", actual.volume.fs_type, expected.volume.fs_type),
        ("volume disk type", actual.volume.disk_type, expected.volume.disk_type),
        ("volume filesystem id", actual.volume.fs_id, expected.volume.fs_id),
        ("target kind", actual.target.kind, expected.target.kind),
        (
            "target filename",
            alias_text(actual.target.filename),
            alias_text(expected.target.filename),
        ),
        ("target folder id", actual.target.folder_cnid, expected.target.folder_cnid),
        ("target catalog id", actual.target.cnid, expected.target.cnid),
        ("target creation date", actual.target.creation_date, expected.target.creation_date),
        ("target Carbon path", actual.target.carbon_path, expected.target.carbon_path),
        (
            "target POSIX path",
            alias_text(actual.target.posix_path),
            alias_text(expected.target.posix_path),
        ),
    )
    for field, actual_value, expected_value in identity_fields:
        require_equal(actual_value, expected_value, f"Finder background alias {field}")


def main() -> None:
    if len(sys.argv) != 2:
        fail(f"usage: {Path(sys.argv[0]).name} /path/to/mounted/Jarvis")

    mount_point = Path(sys.argv[1])
    if mount_point.is_symlink() or not mount_point.is_dir():
        fail("disk image mount point must be a regular directory")

    ds_store_path = mount_point / ".DS_Store"
    background_path = mount_point / ".background.tiff"
    if ds_store_path.is_symlink() or not ds_store_path.is_file():
        fail("disk image is missing its regular .DS_Store layout metadata")
    if background_path.is_symlink() or not background_path.is_file():
        fail("disk image is missing its regular arrow background")

    background_digest = hashlib.sha256(background_path.read_bytes()).hexdigest()
    require_equal(background_digest, EXPECTED_BACKGROUND_SHA256, "arrow background digest")

    with DSStore.open(str(ds_store_path), "r") as store:
        require_equal(
            record(store, ".", "icvl"),
            (b"type", b"icnv"),
            "default Finder view",
        )

        browser_settings = record(store, ".", "bwsp")
        require_equal(
            browser_settings.get("WindowBounds"),
            EXPECTED_WINDOW_BOUNDS,
            "Finder window bounds",
        )
        for key in ("ShowStatusBar", "ShowTabView", "ShowToolbar", "ShowPathbar", "ShowSidebar"):
            require_equal(browser_settings.get(key), False, f"Finder setting {key}")

        icon_settings = record(store, ".", "icvp")
        require_equal(icon_settings.get("backgroundType"), 2, "Finder background type")
        background_alias = icon_settings.get("backgroundImageAlias")
        if not background_alias:
            fail("Finder metadata does not point to the arrow background")
        verify_background_alias(background_alias, background_path)
        require_equal(icon_settings.get("arrangeBy"), "none", "Finder icon arrangement")
        require_equal(icon_settings.get("labelOnBottom"), True, "Finder icon label position")
        require_equal(icon_settings.get("textSize"), 16.0, "Finder label size")
        require_equal(icon_settings.get("iconSize"), 128.0, "Finder icon size")

        for filename, expected_location in EXPECTED_ICON_LOCATIONS.items():
            require_equal(
                record(store, filename, "Iloc"),
                expected_location,
                f"Finder position for {filename}",
            )

    print("Disk image Finder layout passed.")


if __name__ == "__main__":
    main()
