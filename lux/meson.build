# SPDX-License-Identifier: ISC

sys_src = {
  'linux':   'sys_linux.c',
  'openbsd': 'sys_openbsd.c',
}.get(host_machine.system(), 'sys_linux.c')

shared_library('sys', sys_src,
  dependencies: lua_dep,
  name_prefix: '',
  install: true,
  install_dir: lua_lib_dir / 'lux',
)

install_data('rpc.lua', 'log.lua',
  install_dir: lua_mod_dir / 'lux',
)
