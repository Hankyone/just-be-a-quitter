# dmgbuild settings for the drag-to-install disk image.
# Usage: dmgbuild -s scripts/dmg-settings.py -D app=<path to .app> -D background=<tiff> "<volume name>" <output.dmg>
import os

app = defines["app"]  # noqa: F821 (provided by dmgbuild)
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "APFS"
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = [app_name]

background = defines["background"]  # noqa: F821
window_rect = ((200, 120), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {
    app_name: (160, 190),
    "Applications": (480, 190),
}
