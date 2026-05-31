# SPDX-License-Identifier: ISC

shared_library('sys', 'sys.c',
  dependencies: lua_dep,
  name_prefix: '',
  install: true,
  install_dir: lua_lib_dir / 'lux',
)

install_data('rpc.lua',
  install_dir: lua_mod_dir / 'lux',
)
