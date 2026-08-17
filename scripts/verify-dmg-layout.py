#!/usr/bin/env python3

import hashlib
import subprocess
import sys
from pathlib import Path

from ds_store import DSStore


APP_NAME = "Jarvis.app"
APPLICATIONS_NAME = "Applications"
EXPECTED_BACKGROUND_SHA256 = "a0b620ebf085f7bfd975b5cbbf25f3245afd95cef598f4ac80e05a5672e18290"
EXPECTED_ICON_LOCATIONS = {
    APP_NAME: (140, 120),
    APPLICATIONS_NAME: (500, 120),
}
EXPECTED_WINDOW_BOUNDS = "{{100, 100}, {640, 280}}"
FINDER_EXTENSION_HIDDEN = 0x0010


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
        if not icon_settings.get("backgroundImageAlias"):
            fail("Finder metadata does not point to the arrow background")
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

    try:
        finder_info_hex = subprocess.check_output(
            ["/usr/bin/xattr", "-px", "com.apple.FinderInfo", mount_point / APP_NAME],
            stderr=subprocess.DEVNULL,
            text=True,
        )
        finder_info = bytes.fromhex(finder_info_hex)
    except (OSError, subprocess.CalledProcessError, ValueError):
        fail("Jarvis.app is missing its Finder presentation metadata")
    if len(finder_info) < 10:
        fail("Jarvis.app has incomplete Finder presentation metadata")
    finder_flags = int.from_bytes(finder_info[8:10], byteorder="big")
    if finder_flags & FINDER_EXTENSION_HIDDEN == 0:
        fail("Finder metadata must display the application as Jarvis without the .app extension")

    print("Disk image Finder layout passed.")


if __name__ == "__main__":
    main()
