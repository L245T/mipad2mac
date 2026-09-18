"""Finder layout for the MiPad2Mac drag-install image (dmgbuild settings)."""
from pathlib import Path
content = Path(defines['content'])
files = [str(content / 'MiPad2Mac.app'), str(content / '安装说明.txt')]
symlinks = {'Applications': '/Applications'}
background = str(content / 'background.tiff')
format = 'UDZO'
filesystem = 'HFS+'
window_rect = ((200, 160), (660, 500))
default_view = 'icon-view'
show_toolbar = False
show_sidebar = False
show_status_bar = False
show_pathbar = False
show_tab_view = False
icon_size = 96
text_size = 13
label_pos = 'bottom'
arrange_by = None
icon_locations = {'MiPad2Mac.app': (170, 204), 'Applications': (490, 204), '安装说明.txt': (330, 325)}
# Do not add FinderInfo to the signed app bundle; it invalidates strict verification.
hide_extensions = []
