# dmgbuild settings for build/Shiftlist.dmg. Paths come in through -D from scripts/dist.sh.
# Icon positions must match the arrow drawn by scripts/make-dmg-background.swift.

stage = defines["stage"]

volume_name = "Shiftlist"
format = "UDZO"
icon = defines["icon"]
files = [f"{stage}/Shiftlist.app", f"{stage}/Beni Oku.txt"]
symlinks = {"Uygulamalar": "/Applications"}

background = defines["background"]
window_rect = ((240, 160), (640, 420))
default_view = "icon-view"
icon_size = 88
text_size = 12
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_locations = {
    "Shiftlist.app": (170, 215),
    "Uygulamalar": (470, 215),
    "Beni Oku.txt": (320, 355),
}
