# SPDX-License-Identifier: ISC

net_sys_src = {
  'linux':   'sys_linux.c',
  'openbsd': 'sys_openbsd.c',
}.get(host_machine.system(), 'sys_linux.c')

shared_library('sys', net_sys_src,
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
