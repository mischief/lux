/*
 * SPDX-License-Identifier: ISC
 * sys.c - Lua module for syscalls not in luaposix
 */
#define _GNU_SOURCE
#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/resource.h>
#include <sys/prctl.h>

#include <lua.h>
#include <lauxlib.h>

/* lux.sys.setsid() -> pid or nil, errmsg */
static int l_setsid(lua_State *L) {
	pid_t sid = setsid();
	if (sid == -1) {
		lua_pushnil(L);
		lua_pushstring(L, strerror(errno));
		return 2;
	}
	lua_pushinteger(L, sid);
	return 1;
}

/* lux.sys.mount(source, target, fstype[, flags[, data]]) -> true or nil, errmsg */
static int l_mount(lua_State *L) {
	const char *source = luaL_checkstring(L, 1);
	const char *target = luaL_checkstring(L, 2);
	const char *fstype = luaL_checkstring(L, 3);
	unsigned long flags = luaL_optinteger(L, 4, 0);
	const char *data = luaL_optstring(L, 5, NULL);
	if (mount(source, target, fstype, flags, data) == -1) {
		lua_pushnil(L);
		lua_pushstring(L, strerror(errno));
		return 2;
	}
	lua_pushboolean(L, 1);
	return 1;
}

/* lux.sys.umount(target) -> true or nil, errmsg */
static int l_umount(lua_State *L) {
	const char *target = luaL_checkstring(L, 1);
	if (umount(target) == -1) {
		lua_pushnil(L);
		lua_pushstring(L, strerror(errno));
		return 2;
	}
	lua_pushboolean(L, 1);
	return 1;
}

/* lux.sys.reboot(cmd) -> does not return on success, or nil, errmsg */
static int l_reboot(lua_State *L) {
	int cmd = luaL_checkinteger(L, 1);
	sync();
	if (reboot(cmd) == -1) {
		lua_pushnil(L);
		lua_pushstring(L, strerror(errno));
		return 2;
	}
	return 0;
}

/* lux.sys.sethostname(name) -> true or nil, errmsg */
static int l_sethostname(lua_State *L) {
	size_t len;
	const char *name = luaL_checklstring(L, 1, &len);
	if (sethostname(name, len) == -1) {
		lua_pushnil(L);
		lua_pushstring(L, strerror(errno));
		return 2;
	}
	lua_pushboolean(L, 1);
	return 1;
}

/* lux.sys.setrlimit(resource, soft, hard) -> true or nil, errmsg */
static int l_setrlimit(lua_State *L) {
	int resource = luaL_checkinteger(L, 1);
	struct rlimit rl;
	rl.rlim_cur = luaL_checkinteger(L, 2);
	rl.rlim_max = luaL_checkinteger(L, 3);
	if (setrlimit(resource, &rl) == -1) {
		lua_pushnil(L);
		lua_pushstring(L, strerror(errno));
		return 2;
	}
	lua_pushboolean(L, 1);
	return 1;
}

/* lux.sys.getrlimit(resource) -> soft, hard or nil, errmsg */
static int l_getrlimit(lua_State *L) {
	int resource = luaL_checkinteger(L, 1);
	struct rlimit rl;
	if (getrlimit(resource, &rl) == -1) {
		lua_pushnil(L);
		lua_pushstring(L, strerror(errno));
		return 2;
	}
	lua_pushinteger(L, rl.rlim_cur);
	lua_pushinteger(L, rl.rlim_max);
	return 2;
}

/* lux.sys.prctl(option, ...) -> result or nil, errmsg */
static int l_prctl(lua_State *L) {
	int option = luaL_checkinteger(L, 1);
	unsigned long a2 = luaL_optinteger(L, 2, 0);
	unsigned long a3 = luaL_optinteger(L, 3, 0);
	unsigned long a4 = luaL_optinteger(L, 4, 0);
	unsigned long a5 = luaL_optinteger(L, 5, 0);
	int r = prctl(option, a2, a3, a4, a5);
	if (r == -1) {
		lua_pushnil(L);
		lua_pushstring(L, strerror(errno));
		return 2;
	}
	lua_pushinteger(L, r);
	return 1;
}

static const luaL_Reg sys_funcs[] = {
	{"setsid", l_setsid},
	{"mount", l_mount},
	{"umount", l_umount},
	{"reboot", l_reboot},
	{"sethostname", l_sethostname},
	{"setrlimit", l_setrlimit},
	{"getrlimit", l_getrlimit},
	{"prctl", l_prctl},
	{NULL, NULL}
};

int luaopen_lux_sys(lua_State *L) {
	luaL_newlib(L, sys_funcs);
	/* mount flags */
	lua_pushinteger(L, MS_RDONLY); lua_setfield(L, -2, "MS_RDONLY");
	lua_pushinteger(L, MS_NOSUID); lua_setfield(L, -2, "MS_NOSUID");
	lua_pushinteger(L, MS_NODEV); lua_setfield(L, -2, "MS_NODEV");
	lua_pushinteger(L, MS_NOEXEC); lua_setfield(L, -2, "MS_NOEXEC");
	lua_pushinteger(L, MS_REMOUNT); lua_setfield(L, -2, "MS_REMOUNT");
	/* reboot commands */
	lua_pushinteger(L, RB_AUTOBOOT); lua_setfield(L, -2, "RB_AUTOBOOT");
	lua_pushinteger(L, RB_HALT_SYSTEM); lua_setfield(L, -2, "RB_HALT_SYSTEM");
	lua_pushinteger(L, RB_POWER_OFF); lua_setfield(L, -2, "RB_POWER_OFF");
	/* rlimit resources */
	lua_pushinteger(L, RLIMIT_NOFILE); lua_setfield(L, -2, "RLIMIT_NOFILE");
	lua_pushinteger(L, RLIMIT_NPROC); lua_setfield(L, -2, "RLIMIT_NPROC");
	lua_pushinteger(L, RLIMIT_AS); lua_setfield(L, -2, "RLIMIT_AS");
	lua_pushinteger(L, RLIMIT_CORE); lua_setfield(L, -2, "RLIMIT_CORE");
	lua_pushinteger(L, RLIMIT_CPU); lua_setfield(L, -2, "RLIMIT_CPU");
	/* prctl options */
	lua_pushinteger(L, PR_SET_NAME); lua_setfield(L, -2, "PR_SET_NAME");
	lua_pushinteger(L, PR_GET_NAME); lua_setfield(L, -2, "PR_GET_NAME");
	lua_pushinteger(L, PR_SET_PDEATHSIG); lua_setfield(L, -2, "PR_SET_PDEATHSIG");
	return 1;
}
