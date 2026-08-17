from pathlib import Path


APP_NAME = "Jarvis.app"

try:
    application = Path(defines["app"])  # type: ignore[name-defined]
except (KeyError, NameError) as error:
    raise ValueError("dmgbuild requires -D app=/absolute/path/to/Jarvis.app") from error

if not application.is_absolute():
    raise ValueError("the Jarvis.app path must be absolute")
if application.name != APP_NAME or application.is_symlink() or not application.is_dir():
    raise ValueError("the DMG source must be a regular Jarvis.app bundle")

# Keep the visible surface to the two conventional drag-install targets. dmgbuild writes the
# Finder metadata and bundled arrow directly, so this layout is deterministic without a GUI session.
files = [(str(application), APP_NAME)]
symlinks = {"Applications": "/Applications"}
hide_extensions = [APP_NAME]

format = "UDZO"
filesystem = "HFS+"

background = "builtin-arrow"
window_rect = ((100, 100), (640, 280))
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"

arrange_by = None
label_pos = "bottom"
text_size = 16
icon_size = 128
icon_locations = {
    APP_NAME: (140, 120),
    "Applications": (500, 120),
}
include_icon_view_settings = True
include_list_view_settings = False
