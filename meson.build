# SPDX-License-Identifier: ISC
project('lux', 'c', meson_version: '>=1.1',
  license: 'ISC',
  version: '0.1.0',
)

lua_name = get_option('lua')
lua_ver = lua_name.replace('lua', '')
lua_dep = dependency(lua_name)
lua_mod_dir = get_option('datadir') / 'lua' / lua_ver

imsg_dep = dependency('imsg', fallback: ['libimsg', 'imsg_dep'])

install_data('luxd.lua',
  rename: 'luxd',
  install_dir: get_option('sbindir'),
  install_mode: 'rwxr-xr-x',
)

install_data('luxctl.lua',
  rename: 'luxctl',
  install_dir: get_option('sbindir'),
  install_mode: 'rwxr-xr-x',
)

install_data('rpc.lua',
  install_dir: lua_mod_dir / 'lux',
)
