# SPDX-License-Identifier: ISC
project('lux', 'c', meson_version: '>=1.1',
  license: 'ISC',
  version: '0.1.0',
)

lua_name = get_option('lua')
lua_dep = dependency(lua_name)

lua_ver = get_option('lua_version')
if lua_ver == ''
  lua_ver = lua_name.replace('lua', '')
  if lua_ver == '' or lua_ver == '-'
    lua_ver = lua_dep.get_variable(pkgconfig: 'V', default_value: '5.4')
  endif
endif

lua_mod_dir = get_option('datadir') / 'lua' / lua_ver
lua_lib_dir = get_option('libdir') / 'lua' / lua_ver

# Build lux/ modules (sys.so, rpc.lua)
subdir('lux')

# Build net/ modules (netd, sys.so, dhcp.lua, engine.lua, log.lua)
subdir('net')

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
configure_file(
  input: 'luxd.lua',
  output: 'luxd',
  configuration: luxd_conf,
  install: true,
  install_dir: get_option('sbindir'),
  install_mode: 'rwxr-xr-x',
)

install_data('luxctl.lua',
  rename: 'luxctl',
  install_dir: get_option('sbindir'),
  install_mode: 'rwxr-xr-x',
)

install_data('luxd-run.lua',
  rename: 'luxd-run',
  install_dir: get_option('sbindir'),
  install_mode: 'rwxr-xr-x',
)

install_data('logd.lua',
  rename: 'logd',
  install_dir: get_option('sbindir'),
  install_mode: 'rwxr-xr-x',
)

# Default service definitions
install_data(
  'services/console.lua',
  'services/logd.lua',
  'services/netd.lua',
  install_dir: get_option('datadir') / 'lux' / 'services',
)

# Optional: install as /sbin/init
if get_option('as_init')
  install_symlink('init',
    pointing_to: 'luxd',
    install_dir: get_option('sbindir'),
  )
endif

# Tests
sh = find_program('sh')
test_env = environment()
# require("lux.sys") looks for lux/sys.so — needs build/ in cpath
test_env.append('LUA_CPATH', meson.current_build_dir() / '?.so', separator: ';')
# require("lux.rpc") looks for lux/rpc.lua — needs source/ in path
test_env.append('LUA_PATH', meson.current_source_dir() / '?.lua', separator: ';')

tests = [
  'start_stop',
  'status',
  'stop_start',
  'shutdown',
  'oneshot',
  'target',
]

foreach t : tests
  test('lux.' + t, sh,
    args: [meson.current_source_dir() / 'tests' / t + '.sh'],
    env: test_env,
    timeout: 15,
  )
endforeach
