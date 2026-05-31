#!/usr/bin/env lua5.4
-- SPDX-License-Identifier: ISC
-- netd - network daemon with privilege separation
--
-- Three-process model (re-exec, like OpenBSD dhcpleased):
--   netd [-dv] <iface>      → main (root)
--   netd -E [-dv] <iface>   → engine (unprivileged): DHCP
--   netd -N [-dv] <iface>   → ntpd (unprivileged): SNTP time sync
--
-- Main opens privileged sockets, re-execs children with IPC fds.
-- Engine gets fd 3, ntpd gets fd 4.

local unistd = require("posix.unistd")
local socket = require("posix.sys.socket")
local wait = require("posix.sys.wait")
local signal = require("posix.signal")
local pwd = require("posix.pwd")
local poll = require("posix.poll")
local fcntl = require("posix.fcntl")
local syslog = require("posix.syslog")
local imsg = require("imsg")
local log = require("net.log")
local sys = require("net.sys")
local rpc = require("net.rpc")
local engine = require("net.engine")
local ntpd = require("net.ntpd")

local NETD_USER = "nobody"
local RESOLV_CONF = "/etc/resolv.conf"
local ENGINE_FD = 3
local NTPD_FD = 4

local debug_mode = false
local verbose = false
local engine_mode = false
local ntpd_mode = false
local ifname = nil

local function usage()
	io.stderr:write("usage: netd [-dv] <interface>\n")
	os.exit(1)
end

local function parse_args()
	local optind = 1
	for opt, optarg, oi in unistd.getopt(arg, "dvEN") do
		if opt == "?" then usage() end
		if opt == "d" then debug_mode = true end
		if opt == "v" then verbose = true end
		if opt == "E" then engine_mode = true end
		if opt == "N" then ntpd_mode = true end
		optind = oi
	end
	ifname = arg[optind]
	if not ifname then usage() end
end

-- Write /etc/resolv.conf
local function write_resolv_conf(nameservers, domain)
	local tmp = RESOLV_CONF .. ".tmp"
	local f = io.open(tmp, "w")
	if not f then
		log.warn("cannot write " .. tmp)
		return
	end
	if domain and domain ~= "" then
		f:write(string.format("search %s\n", domain))
	end
	for _, ns in ipairs(nameservers) do
		f:write(string.format("nameserver %s\n", ns))
	end
	f:close()
	os.rename(tmp, RESOLV_CONF)
	log.info("wrote " .. RESOLV_CONF)
end

-- Apply interface configuration
local function configure_interface(data)
	local msg = rpc.decode(data)
	local addr = msg.addr
	local mask = msg.mask
	local router = msg.router
	local domain = msg.domain
	local dns = type(msg.dns) == "table" and msg.dns or (msg.dns and {msg.dns} or {})

	local ok, err

	ok, err = sys.if_setaddr(ifname, addr)
	if not ok then
		log.warn(string.format("if_setaddr %s %s: %s", ifname, addr, err))
		return
	end

	ok, err = sys.if_setmask(ifname, mask)
	if not ok then
		log.warn(string.format("if_setmask %s %s: %s", ifname, mask, err))
		return
	end

	ok, err = sys.if_up(ifname)
	if not ok then
		log.warn(string.format("if_up %s: %s", ifname, err))
		return
	end

	log.info(string.format("configured %s: %s/%s", ifname, addr, mask))

	if router and router ~= "" then
		ok, err = sys.route_add("0.0.0.0", router, "0.0.0.0", ifname)
		if not ok then
			log.warn(string.format("route_add default via %s: %s", router, err))
		else
			log.info(string.format("default route via %s", router))
		end
	end

	if #dns > 0 then
		write_resolv_conf(dns, domain)
	end

	-- Return NTP servers for forwarding to ntpd
	local ntp = type(msg.ntp) == "table" and msg.ntp or (msg.ntp and {msg.ntp} or {})
	return ntp
end

-- Deconfigure interface
local function deconfigure_interface()
	sys.route_del("0.0.0.0", "0.0.0.0", "0.0.0.0")
	sys.if_setaddr(ifname, "0.0.0.0")
	log.info(string.format("deconfigured %s", ifname))
end

-- Read MAC from /sys
local function read_mac()
	local f = io.open("/sys/class/net/" .. ifname .. "/address", "r")
	if not f then return nil end
	local mac = f:read("l")
	f:close()
	return mac
end

-- Engine process: entered via netd -E
local function run_engine()
	log.procinit("engine")
	log.init(debug_mode, syslog.LOG_DAEMON)
	if verbose then log.setverbose(true) end

	-- IPC fd is ENGINE_FD (inherited from parent)
	local pw = pwd.getpwnam(NETD_USER)
	if not pw then
		log.fatal("unknown user: " .. NETD_USER)
	end

	-- Drop privileges
	local r, e
	r, e = sys.chroot("/var/empty")
	if not r then log.fatal("chroot: " .. e) end
	unistd.chdir("/")
	r, e = sys.setgroups(pw.pw_gid)
	if not r then log.fatal("setgroups: " .. e) end
	r, e = sys.setresgid(pw.pw_gid, pw.pw_gid, pw.pw_gid)
	if not r then log.fatal("setresgid: " .. e) end
	r, e = sys.setresuid(pw.pw_uid, pw.pw_uid, pw.pw_uid)
	if not r then log.fatal("setresuid: " .. e) end

	log.debug("privileges dropped")

	engine.run(ENGINE_FD, ifname, debug_mode, verbose)
end

-- NTP child process: entered via netd -N
local function run_ntpd()
	log.procinit("ntpd")
	log.init(debug_mode, syslog.LOG_DAEMON)
	if verbose then log.setverbose(true) end

	local pw = pwd.getpwnam(NETD_USER)
	if not pw then
		log.fatal("unknown user: " .. NETD_USER)
	end

	-- Drop privileges
	local r, e
	r, e = sys.chroot("/var/empty")
	if not r then log.fatal("chroot: " .. e) end
	unistd.chdir("/")
	r, e = sys.setgroups(pw.pw_gid)
	if not r then log.fatal("setgroups: " .. e) end
	r, e = sys.setresgid(pw.pw_gid, pw.pw_gid, pw.pw_gid)
	if not r then log.fatal("setresgid: " .. e) end
	r, e = sys.setresuid(pw.pw_uid, pw.pw_uid, pw.pw_uid)
	if not r then log.fatal("setresuid: " .. e) end

	log.debug("privileges dropped")

	ntpd.run(NTPD_FD, nil, debug_mode, verbose)
end

-- Main process
local function run_main()
	log.procinit("netd")
	log.init(debug_mode, syslog.LOG_DAEMON)
	if verbose then log.setverbose(true) end

	if unistd.geteuid() ~= 0 then
		log.fatal("need root privileges")
	end

	log.info(string.format("starting on %s", ifname))

	-- Bring interface up (no address) so kernel allows sending
	local ok, err = sys.if_up(ifname)
	if not ok then
		log.fatal(string.format("if_up %s: %s", ifname, err))
	end

	-- Create socketpair for imsg IPC
	local sv = {socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM, 0)}
	if not sv[1] then
		log.fatal("socketpair: " .. tostring(sv[2]))
	end
	local main_fd, engine_fd = sv[1], sv[2]

	-- Open privileged UDP socket for DHCP (port 68)
	local udp_fd = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, 0)
	if not udp_fd then
		log.fatal("socket: cannot create UDP socket")
	end
	socket.setsockopt(udp_fd, socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
	socket.setsockopt(udp_fd, socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
	local ok, err = sys.bindtodevice(udp_fd, ifname)
	if not ok then
		log.fatal(string.format("SO_BINDTODEVICE %s: %s", ifname, err))
	end
	local bret, berr = socket.bind(udp_fd, {family = socket.AF_INET, addr = "0.0.0.0", port = 68})
	if not bret then
		log.fatal("bind port 68: " .. tostring(berr))
	end

	-- Start engine child via re-exec
	local pid = unistd.fork()
	if pid == -1 then
		log.fatal("fork failed")
	end

	if pid == 0 then
		-- Child: set up fd 3 as IPC, close parent's end
		unistd.close(main_fd)
		unistd.close(udp_fd)
		if engine_fd ~= ENGINE_FD then
			unistd.dup2(engine_fd, ENGINE_FD)
			unistd.close(engine_fd)
		end
		-- Clear close-on-exec for fd 3
		fcntl.fcntl(ENGINE_FD, fcntl.F_SETFD, 0)
		-- Re-exec ourselves with -E flag
		local argv = {arg[0], "-E"}
		if debug_mode then argv[#argv + 1] = "-d" end
		if verbose then argv[#argv + 1] = "-v" end
		argv[#argv + 1] = ifname
		unistd.execp(argv[1], {table.unpack(argv, 2)})
		log.fatal("execp failed")
	end

	-- Main parent
	unistd.close(engine_fd)

	log.debug(string.format("engine pid %d", pid))

	-- Set up imsgbuf for IPC with engine
	local ibuf = imsg.new(main_fd)
	ibuf:allow_fdpass()

	-- Send UDP socket fd to engine
	ibuf:compose(rpc.UDPSOCK, 0, 0, udp_fd, "")
	ibuf:flush()
	unistd.close(udp_fd) -- engine owns it now

	-- Start ntpd child via re-exec
	local ntp_sv = {socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM, 0)}
	if not ntp_sv[1] then
		log.fatal("socketpair (ntp): " .. tostring(ntp_sv[2]))
	end
	local ntp_main_fd, ntp_child_fd = ntp_sv[1], ntp_sv[2]

	local ntp_pid = unistd.fork()
	if ntp_pid == -1 then
		log.fatal("fork (ntp) failed")
	end
	if ntp_pid == 0 then
		unistd.close(ntp_main_fd)
		unistd.close(main_fd)
		if ntp_child_fd ~= NTPD_FD then
			unistd.dup2(ntp_child_fd, NTPD_FD)
			unistd.close(ntp_child_fd)
		end
		fcntl.fcntl(NTPD_FD, fcntl.F_SETFD, 0)
		local argv = {arg[0], "-N"}
		if debug_mode then argv[#argv + 1] = "-d" end
		if verbose then argv[#argv + 1] = "-v" end
		argv[#argv + 1] = ifname
		unistd.execp(argv[1], {table.unpack(argv, 2)})
		log.fatal("execp (ntp) failed")
	end
	unistd.close(ntp_child_fd)
	log.debug(string.format("ntpd pid %d", ntp_pid))

	local ntp_ibuf = imsg.new(ntp_main_fd)

	-- Signal handling
	local child_dead = false
	signal.signal(signal.SIGCHLD, function() child_dead = true end)
	signal.signal(signal.SIGTERM, function()
		signal.kill(pid, signal.SIGTERM)
		signal.kill(ntp_pid, signal.SIGTERM)
		child_dead = true
	end)
	signal.signal(signal.SIGPIPE, signal.SIG_IGN)

	-- Control socket
	local NETD_SOCK = "/run/netd." .. ifname .. ".sock"
	os.remove(NETD_SOCK)
	local ctl_fd = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM, 0)
	socket.bind(ctl_fd, {family = socket.AF_UNIX, path = NETD_SOCK})
	socket.listen(ctl_fd, 5)
	log.debug("control socket: " .. NETD_SOCK)

	-- Main loop
	local fds = {
		[main_fd] = {events = {IN = true}},
		[ctl_fd] = {events = {IN = true}},
		[ntp_main_fd] = {events = {IN = true}},
	}
	local configured = false
	local ctl_client = nil

	while not child_dead do
		local ready = poll.poll(fds, -1)

		-- Engine IPC
		if ready and ready > 0 and fds[main_fd].revents and fds[main_fd].revents.IN then
			local ret = ibuf:read()
			if not ret then
				log.debug("engine pipe closed")
				break
			end
			while true do
				local msg = ibuf:get()
				if not msg then break end
				local mtype = msg:type()
				if mtype == rpc.GETMAC then
					local mac = read_mac() or "00:00:00:00:00:00"
					ibuf:compose(rpc.MAC, 0, 0, -1, mac)
					ibuf:flush()
				elseif mtype == rpc.CONFIGURE then
					local data = msg:len() > 0 and msg:data() or ""
					local ntp_servers = configure_interface(data)
					configured = true
					-- Forward NTP server to ntpd child
					if ntp_servers and #ntp_servers > 0 then
						ntp_ibuf:compose(rpc.NTP_SERVER, 0, 0, -1, ntp_servers[1])
						ntp_ibuf:flush()
						log.debug("sent NTP server " .. ntp_servers[1] .. " to ntpd")
					end
				elseif mtype == rpc.DECONFIGURE then
					deconfigure_interface()
					configured = false
				elseif mtype == rpc.CTL_REPLY then
					if ctl_client then
						local data = msg:len() > 0 and msg:data() or ""
						ctl_client:compose(rpc.CTL_REPLY, 0, 0, -1, data)
						pcall(function() ctl_client:flush() end)
						ctl_client = nil
					end
				end
			end
		end

		-- NTP child IPC
		if ready and ready > 0 and fds[ntp_main_fd].revents and fds[ntp_main_fd].revents.IN then
			local ret = ntp_ibuf:read()
			if ret then
				while true do
					local msg = ntp_ibuf:get()
					if not msg then break end
					if msg:type() == rpc.SETTIME and msg:len() > 0 then
						local data = rpc.decode(msg:data())
						local sec = tonumber(data.sec)
						local usec = tonumber(data.usec) or 0
						if sec then
							local ok, err = sys.settimeofday(sec, usec)
							if ok then
								log.info(string.format("clock set to %d.%06d", sec, usec))
							else
								log.warn("settimeofday: " .. tostring(err))
							end
						end
					end
				end
			end
		end

		-- Control socket
		if ready and ready > 0 and fds[ctl_fd].revents and fds[ctl_fd].revents.IN then
			local cfd = socket.accept(ctl_fd)
			if cfd then
				local cbuf = imsg.new(cfd)
				local ret = cbuf:read()
				if ret then
					local msg = cbuf:get()
					if msg then
						local mtype = msg:type()
						if mtype == rpc.CTL_STATUS or mtype == rpc.CTL_RENEW
							or mtype == rpc.CTL_RELEASE then
							ibuf:compose(mtype, 0, 0, -1, "")
							ibuf:flush()
							ctl_client = cbuf
						end
					end
				end
				if not ctl_client then
					unistd.close(cfd)
				end
			end
		end
	end

	-- Cleanup
	if configured then
		deconfigure_interface()
	end
	os.remove(NETD_SOCK)

	wait.wait(pid)
	wait.wait(ntp_pid)
	log.info("exiting")
end

-- Entry point
parse_args()

if engine_mode then
	run_engine()
elseif ntpd_mode then
	run_ntpd()
else
	run_main()
end
