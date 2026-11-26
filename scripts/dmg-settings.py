# Layout of the Snowpuff disk image window, for dmgbuild.
# Usage: dmgbuild -s scripts/dmg-settings.py -D app=<Snowpuff.app> -D background=<background.tiff> Snowpuff <output.dmg>
import os.path

app = defines["app"]
background = defines["background"]
icon = "Resources/AppIcon.icns"

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}

# Matches the arrow and the lamp drawn in scripts/make-dmg-background.swift.
icon_locations = {
    os.path.basename(app): (170, 200),
    "Applications": (470, 200),
}
window_rect = ((200, 160), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
icon_size = 112
text_size = 13
arrange_by = None
