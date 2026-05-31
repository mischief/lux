# SPDX-License-Identifier: ISC
project('lux', 'c', meson_version: '>=1.1',
  license: 'ISC',
  version: '0.1.0',
)

lua_name = get_option('lua')
lua_dep = dependency(lua_name)

# Determine lua version for module install paths
lua_ver = get_option('lua_version')
if lua_ver == ''
  # Auto-detect: strip 'lua' prefix from pkg-config name
  lua_ver = lua_name.replace('lua', '')
  # If that gives us nothing useful, try pkg-config variable
  if lua_ver == '' or lua_ver == '-'
    lua_ver = lua_dep.get_variable(pkgconfig: 'V', default_value: '5.4')
  endif
endif

lua_mod_dir = get_option('datadir') / 'lua' / lua_ver
lua_lib_dir = get_option('libdir') / 'lua' / lua_ver

# Native module: lux.sys
shared_library('sys', 'sys.c',
  dependencies: lua_dep,
  name_prefix: '',
  install: true,
  install_dir: lua_lib_dir / 'lux',
)

# Lua modules
install_data('rpc.lua',
  install_dir: lua_mod_dir / 'lux',
)

# Get git version
git = find_program('git', required: false)
if git.found()
  version_str = run_command(git, 'describe', '--always', '--dirty', check: false).stdout().strip()
else
  version_str = meson.project_version()
endif

# Generate luxd with version embedded
luxd_conf = configuration_data()
luxd_conf.set('VERSION', version_str)
luxd_generated = configure_file(
  input: 'luxd.lua',
  output: 'luxd',
  configuration: luxd_conf,
  install: true,
  install_dir: get_option('sbindir'),
  install_mode: 'rwxr-xr-x',
)

# Executables
install_data('luxctl.lua',
  rename: 'luxctl',
  install_dir: get_option('sbindir'),
  install_mode: 'rwxr-xr-x',
)

# Optional: install as init symlink in sbindir
if get_option('as_init')
  install_symlink('init',
    pointing_to: 'luxd',
    install_dir: get_option('sbindir'),
  )
endif
