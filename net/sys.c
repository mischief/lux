/*
 * SPDX-License-Identifier: ISC
 * net/sys.c - Lua module for netd privileged operations
 *
 * Provides: privsep (chroot, setgroups, setresgid, setresuid),
 *           socket options (SO_BINDTODEVICE),
 *           interface config (ioctl SIOCSIFADDR, SIOCSIFNETMASK, SIOCSIFFLAGS),
 *           routing (SIOCADDRT, SIOCDELRT),
 *           resolv.conf writing.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <grp.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <sys/time.h>
#include <net/if.h>
#include <net/route.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#include <lua.h>
#include <lauxlib.h>

static int pusherr(lua_State *L) {
	lua_pushnil(L);
	lua_pushstring(L, strerror(errno));
	lua_pushinteger(L, errno);
	return 3;
}

/* net.sys.chroot(path) -> true or nil, errmsg, errno */
static int l_chroot(lua_State *L) {
	const char *path = luaL_checkstring(L, 1);
	if (chroot(path) == -1)
		return pusherr(L);
	lua_pushboolean(L, 1);
	return 1;
}

/* net.sys.setgroups(gid) or net.sys.setgroups({gid, ...}) -> true or nil, errmsg, errno */
static int l_setgroups(lua_State *L) {
	if (lua_isinteger(L, 1)) {
		gid_t gid = lua_tointeger(L, 1);
		if (setgroups(1, &gid) == -1)
			return pusherr(L);
	} else {
		luaL_checktype(L, 1, LUA_TTABLE);
		int n = luaL_len(L, 1);
		gid_t groups[64];
		if (n > 64)
			return luaL_error(L, "too many groups");
		for (int i = 1; i <= n; i++) {
			lua_geti(L, 1, i);
			groups[i-1] = lua_tointeger(L, -1);
			lua_pop(L, 1);
		}
		if (setgroups(n, groups) == -1)
			return pusherr(L);
	}
	lua_pushboolean(L, 1);
	return 1;
}

/* net.sys.setresgid(rgid, egid, sgid) -> true or nil, errmsg, errno */
static int l_setresgid(lua_State *L) {
	gid_t r = luaL_checkinteger(L, 1);
	gid_t e = luaL_checkinteger(L, 2);
	gid_t s = luaL_checkinteger(L, 3);
	if (setresgid(r, e, s) == -1)
		return pusherr(L);
	lua_pushboolean(L, 1);
	return 1;
}

/* net.sys.setresuid(ruid, euid, suid) -> true or nil, errmsg, errno */
static int l_setresuid(lua_State *L) {
	uid_t r = luaL_checkinteger(L, 1);
	uid_t e = luaL_checkinteger(L, 2);
	uid_t s = luaL_checkinteger(L, 3);
	if (setresuid(r, e, s) == -1)
		return pusherr(L);
	lua_pushboolean(L, 1);
	return 1;
}

/* net.sys.bindtodevice(fd, ifname) -> true or nil, errmsg, errno */
static int l_bindtodevice(lua_State *L) {
	int fd = luaL_checkinteger(L, 1);
	const char *ifname = luaL_checkstring(L, 2);
	if (setsockopt(fd, SOL_SOCKET, SO_BINDTODEVICE, ifname, strlen(ifname)) == -1)
		return pusherr(L);
	lua_pushboolean(L, 1);
	return 1;
}

/* helper: fill sockaddr_in from dotted-quad string */
static void fill_sin(struct sockaddr_in *sin, const char *addr) {
	memset(sin, 0, sizeof(*sin));
	sin->sin_family = AF_INET;
	inet_pton(AF_INET, addr, &sin->sin_addr);
}

/* net.sys.if_setaddr(ifname, addr) -> true or nil, errmsg, errno */
static int l_if_setaddr(lua_State *L) {
	const char *ifname = luaL_checkstring(L, 1);
	const char *addr = luaL_checkstring(L, 2);
	struct ifreq ifr;
	memset(&ifr, 0, sizeof(ifr));
	strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
	fill_sin((struct sockaddr_in *)&ifr.ifr_addr, addr);
	int fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd == -1)
		return pusherr(L);
	if (ioctl(fd, SIOCSIFADDR, &ifr) == -1) {
		int e = errno;
		close(fd);
		errno = e;
		return pusherr(L);
	}
	close(fd);
	lua_pushboolean(L, 1);
	return 1;
}

/* net.sys.if_setmask(ifname, mask) -> true or nil, errmsg, errno */
static int l_if_setmask(lua_State *L) {
	const char *ifname = luaL_checkstring(L, 1);
	const char *mask = luaL_checkstring(L, 2);
	struct ifreq ifr;
	memset(&ifr, 0, sizeof(ifr));
	strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
	fill_sin((struct sockaddr_in *)&ifr.ifr_netmask, mask);
	int fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd == -1)
		return pusherr(L);
	if (ioctl(fd, SIOCSIFNETMASK, &ifr) == -1) {
		int e = errno;
		close(fd);
		errno = e;
		return pusherr(L);
	}
	close(fd);
	lua_pushboolean(L, 1);
	return 1;
}

/* net.sys.if_up(ifname) -> true or nil, errmsg, errno */
static int l_if_up(lua_State *L) {
	const char *ifname = luaL_checkstring(L, 1);
	struct ifreq ifr;
	memset(&ifr, 0, sizeof(ifr));
	strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
	int fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd == -1)
		return pusherr(L);
	if (ioctl(fd, SIOCGIFFLAGS, &ifr) == -1) {
		int e = errno;
		close(fd);
		errno = e;
		return pusherr(L);
	}
	ifr.ifr_flags |= IFF_UP | IFF_RUNNING;
	if (ioctl(fd, SIOCSIFFLAGS, &ifr) == -1) {
		int e = errno;
		close(fd);
		errno = e;
		return pusherr(L);
	}
	close(fd);
	lua_pushboolean(L, 1);
	return 1;
}

/* net.sys.route_add(dest, gateway, mask, ifname) -> true or nil, errmsg, errno
 * dest "0.0.0.0" for default route */
static int l_route_add(lua_State *L) {
	const char *dest = luaL_checkstring(L, 1);
	const char *gw = luaL_checkstring(L, 2);
	const char *mask = luaL_checkstring(L, 3);
	const char *ifname = luaL_optstring(L, 4, NULL);
	struct rtentry rt;
	memset(&rt, 0, sizeof(rt));
	fill_sin((struct sockaddr_in *)&rt.rt_dst, dest);
	fill_sin((struct sockaddr_in *)&rt.rt_gateway, gw);
	fill_sin((struct sockaddr_in *)&rt.rt_genmask, mask);
	rt.rt_flags = RTF_UP | RTF_GATEWAY;
	if (ifname)
		rt.rt_dev = (char *)ifname;
	int fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd == -1)
		return pusherr(L);
	if (ioctl(fd, SIOCADDRT, &rt) == -1) {
		int e = errno;
		close(fd);
		errno = e;
		return pusherr(L);
	}
	close(fd);
	lua_pushboolean(L, 1);
	return 1;
}

/* net.sys.route_del(dest, gateway, mask) -> true or nil, errmsg, errno */
static int l_route_del(lua_State *L) {
	const char *dest = luaL_checkstring(L, 1);
	const char *gw = luaL_checkstring(L, 2);
	const char *mask = luaL_checkstring(L, 3);
	struct rtentry rt;
	memset(&rt, 0, sizeof(rt));
	fill_sin((struct sockaddr_in *)&rt.rt_dst, dest);
	fill_sin((struct sockaddr_in *)&rt.rt_gateway, gw);
	fill_sin((struct sockaddr_in *)&rt.rt_genmask, mask);
	rt.rt_flags = RTF_UP | RTF_GATEWAY;
	int fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd == -1)
		return pusherr(L);
	if (ioctl(fd, SIOCDELRT, &rt) == -1) {
		int e = errno;
		close(fd);
		errno = e;
		return pusherr(L);
	}
	close(fd);
	lua_pushboolean(L, 1);
	return 1;
}

/* net.sys.settimeofday(sec, usec) -> true or nil, errmsg, errno */
static int l_settimeofday(lua_State *L) {
	struct timeval tv;
	tv.tv_sec = luaL_checkinteger(L, 1);
	tv.tv_usec = luaL_checkinteger(L, 2);
	if (settimeofday(&tv, NULL) == -1)
		return pusherr(L);
	lua_pushboolean(L, 1);
	return 1;
}

static const luaL_Reg sys_funcs[] = {
	/* privsep */
	{"chroot", l_chroot},
	{"setgroups", l_setgroups},
	{"setresgid", l_setresgid},
	{"setresuid", l_setresuid},
	/* socket */
	{"bindtodevice", l_bindtodevice},
	/* interface config */
	{"if_setaddr", l_if_setaddr},
	{"if_setmask", l_if_setmask},
	{"if_up", l_if_up},
	/* routing */
	{"route_add", l_route_add},
	{"route_del", l_route_del},
	/* time */
	{"settimeofday", l_settimeofday},
	{NULL, NULL}
};

int luaopen_net_sys(lua_State *L) {
	luaL_newlib(L, sys_funcs);
	return 1;
}
