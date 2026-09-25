"""Finder layout for the public Mac download. Consumed by dmgbuild."""
from pathlib import Path

app = Path(defines['app']).resolve()
files = [str(app)]
symlinks = {'Applications': '/Applications'}
icon = str(app / 'Contents/Resources/Juicebar.icns')
background = str(Path(defines['background']).resolve())
format = 'UDZO'
filesystem = 'HFS+'
window_rect = ((180, 180), (640, 400))
icon_locations = {'Juicebar.app': (170, 200), 'Applications': (470, 200)}
icon_size = 96
text_size = 13
# Do not change FinderInfo on the signed app bundle.
hide_extensions = []
grid_spacing = 90
default_view = 'icon-view'
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False
