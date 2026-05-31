# SPDX-License-Identifier: ISC

shared_library('sys', 'sys.c',
  dependencies: lua_dep,
  name_prefix: '',
  install: true,
  install_dir: lua_lib_dir / 'net',
)

install_data('log.lua', 'dhcp.lua', 'engine.lua', 'rpc.lua', 'ntpd.lua',
  install_dir: lua_mod_dir / 'net',
)

install_data('netd.lua',
  rename: 'netd',
  install_dir: get_option('sbindir'),
  install_mode: 'rwxr-xr-x',
)

install_data('netctl.lua',
  rename: 'netctl',
  install_dir: get_option('sbindir'),
  install_mode: 'rwxr-xr-x',
)
