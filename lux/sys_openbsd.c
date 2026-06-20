/*
 * SPDX-License-Identifier: ISC
 * sys_openbsd.c - Lua module for syscalls not in luaposix (OpenBSD)
 */
#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/resource.h>
#include <sys/ioctl.h>

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

/* lux.sys.mount(source, target, fstype[, flags]) -> true or nil, errmsg
 * source is ignored on OpenBSD; fstype-specific data is not supported */
static int l_mount(lua_State *L) {
	/* arg 1 (source) ignored — OpenBSD mount(2) has no source */
	const char *target = luaL_checkstring(L, 2);
	const char *fstype = luaL_checkstring(L, 3);
	int flags = luaL_optinteger(L, 4, 0);
	if (mount(fstype, target, flags, NULL) == -1) {
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
	if (unmount(target, 0) == -1) {
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

/* lux.sys.set_ctty(fd) -> true or nil, errmsg */
static int l_set_ctty(lua_State *L) {
	int fd = luaL_checkinteger(L, 1);
	if (ioctl(fd, TIOCSCTTY, 0) == -1) {
		lua_pushnil(L);
		lua_pushstring(L, strerror(errno));
		return 2;
	}
	lua_pushboolean(L, 1);
	return 1;
}

static const luaL_Reg sys_funcs[] = {
	{"setsid", l_setsid},
	{"set_ctty", l_set_ctty},
	{"mount", l_mount},
	{"umount", l_umount},
	{"reboot", l_reboot},
	{"sethostname", l_sethostname},
	{"setrlimit", l_setrlimit},
	{"getrlimit", l_getrlimit},
	{NULL, NULL}
};

int luaopen_lux_sys(lua_State *L) {
	luaL_newlib(L, sys_funcs);
	/* mount flags */
	lua_pushinteger(L, MNT_RDONLY); lua_setfield(L, -2, "MS_RDONLY");
	lua_pushinteger(L, MNT_NOSUID); lua_setfield(L, -2, "MS_NOSUID");
	lua_pushinteger(L, MNT_NODEV); lua_setfield(L, -2, "MS_NODEV");
	lua_pushinteger(L, MNT_NOEXEC); lua_setfield(L, -2, "MS_NOEXEC");
	lua_pushinteger(L, MNT_UPDATE); lua_setfield(L, -2, "MS_REMOUNT");
	/* reboot commands */
	lua_pushinteger(L, RB_AUTOBOOT); lua_setfield(L, -2, "RB_AUTOBOOT");
	lua_pushinteger(L, RB_HALT); lua_setfield(L, -2, "RB_HALT_SYSTEM");
	lua_pushinteger(L, RB_POWERDOWN); lua_setfield(L, -2, "RB_POWER_OFF");
	/* rlimit resources */
	lua_pushinteger(L, RLIMIT_NOFILE); lua_setfield(L, -2, "RLIMIT_NOFILE");
	lua_pushinteger(L, RLIMIT_NPROC); lua_setfield(L, -2, "RLIMIT_NPROC");
	lua_pushinteger(L, RLIMIT_CORE); lua_setfield(L, -2, "RLIMIT_CORE");
	lua_pushinteger(L, RLIMIT_CPU); lua_setfield(L, -2, "RLIMIT_CPU");
	return 1;
}
