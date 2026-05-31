#!/usr/bin/env lua5.4
-- SPDX-License-Identifier: ISC
-- luxd - service supervisor
local a = arg or { [0] = "luxd" }
local src = a[0]:match("(.+/)") or "./"
package.path = src .. "?.lua;" .. src .. "?/init.lua;" .. package.path
package.cpath = src .. "?.so;" .. package.cpath

local unistd = require("posix.unistd")
local wait = require("posix.sys.wait")
local ptime = require("posix.time")
local signal = require("posix.signal")
local stat = require("posix.sys.stat")
local stdlib = require("posix.stdlib")
local socket = require("posix.sys.socket")
local dirent = require("posix.dirent")
local imsg = require("imsg")
local rpc = require("lux.rpc")
local sys = require("lux.sys")

-- Defaults
local sock_path = "/run/lux.sock"
local svc_dir = "/etc/lux/services"
local boot_script = "/etc/lux/boot"
local do_mount = false

-- Parse options
local optind = 1
for opt, optarg, oi in unistd.getopt(a, "s:d:b:mh") do
	if opt == "s" then sock_path = optarg
	elseif opt == "d" then svc_dir = optarg
	elseif opt == "b" then boot_script = optarg
	elseif opt == "m" then do_mount = true
	elseif opt == "h" then
		unistd.write(1, "usage: luxd [-s sock_path] [-d services_dir] [-b boot_script] [-m]\n")
		os.exit(0)
	end
	optind = oi
end

-- State
local services = {} -- name -> {def, pid, state}
local running = true
local shutdown_requested = false

-- Logging
local function log(fmt, ...)
	unistd.write(2, "luxd: " .. string.format(fmt, ...) .. "\n")
end

-- Mount essential filesystems (only when -m, i.e. running as real init)
local function mount_fs()
	local function mnt(s, t, fs)
		pcall(stat.mkdir, t, tonumber("755", 8))
		sys.mount(s, t, fs)
	end
	mnt("proc", "/proc", "proc")
	mnt("sysfs", "/sys", "sysfs")
	mnt("devtmpfs", "/dev", "devtmpfs")
	mnt("tmpfs", "/tmp", "tmpfs")
	mnt("tmpfs", "/run", "tmpfs")
	pcall(stat.mkdir, "/dev/pts", tonumber("755", 8))
	mnt("devpts", "/dev/pts", "devpts")
end

-- DSL: service definitions
-- Each .lua file is executed in a sandbox where service("name") { ... } registers a service
local function load_services()
	local entries = dirent.dir(svc_dir)
	if not entries then
		log("cannot read services directory: %s", svc_dir)
		return
	end

	for _, entry in ipairs(entries) do
		if entry:match("%.lua$") then
			local path = svc_dir .. "/" .. entry
			local registered = {}

			local env = setmetatable({
				service = function(name)
					return function(def)
						def.name = name
						registered[#registered + 1] = def
					end
				end,
			}, { __index = _G })

			local fn, err = loadfile(path, "t", env)
			if fn then
				local ok2, err2 = pcall(fn)
				if not ok2 then log("error in %s: %s", path, err2) end
			else
				log("cannot load %s: %s", path, err)
			end

			for _, def in ipairs(registered) do
				if def.name and def.cmd then
					services[def.name] = {
						def = def,
						pid = nil,
						state = "stopped",
					}
				end
			end
		end
	end
end

-- Start a service
local function start_service(name)
	local svc = services[name]
	if not svc then return false, "unknown service: " .. name end
	if svc.state == "running" then return true end

	-- Check dependencies
	if svc.def.depends then
		for _, dep in ipairs(svc.def.depends) do
			if not services[dep] or services[dep].state ~= "running" then
				local ok, err = start_service(dep)
				if not ok then return false, "dependency failed: " .. dep .. ": " .. (err or "") end
			end
		end
	end

	local pid = unistd.fork()
	if pid == 0 then
		-- Child
		sys.setsid()
		signal.signal(signal.SIGINT, signal.SIG_DFL)
		signal.signal(signal.SIGTERM, signal.SIG_DFL)
		signal.signal(signal.SIGPIPE, signal.SIG_DFL)
		-- Attach to tty if specified
		if svc.def.tty then
			local fcntl = require("posix.fcntl")
			local tty_fd = fcntl.open(svc.def.tty, fcntl.O_RDWR)
			if tty_fd then
				unistd.dup2(tty_fd, 0)
				unistd.dup2(tty_fd, 1)
				unistd.dup2(tty_fd, 2)
				if tty_fd > 2 then unistd.close(tty_fd) end
			end
		end
		-- Set environment
		if svc.def.env then
			for k, v in pairs(svc.def.env) do
				stdlib.setenv(k, v, true)
			end
		end
		-- Exec
		local cmd = svc.def.cmd
		unistd.execp(cmd[1], { table.unpack(cmd, 2) })
		os.exit(127)
	end

	svc.pid = pid
	svc.state = "running"
	log("started %s (pid %d)", name, pid)
	return true
end

-- Stop a service
local function stop_service(name)
	local svc = services[name]
	if not svc then return false, "unknown service: " .. name end
	if svc.state ~= "running" then return true end

	signal.kill(svc.pid, signal.SIGTERM)

	-- Wait up to 5 seconds
	for _ = 1, 50 do
		local wpid = wait.wait(svc.pid, wait.WNOHANG)
		if wpid and wpid > 0 then
			svc.state = "stopped"
			svc.pid = nil
			log("stopped %s", name)
			return true
		end
		ptime.nanosleep({tv_sec=0, tv_nsec=100000000}) -- 100ms
	end

	-- Force kill
	signal.kill(svc.pid, signal.SIGKILL)
	wait.wait(svc.pid)
	svc.state = "stopped"
	svc.pid = nil
	log("killed %s", name)
	return true
end

-- Status string
local function status_string()
	local lines = {}
	for name, svc in pairs(services) do
		local pid_str = svc.pid and tostring(svc.pid) or "-"
		lines[#lines + 1] = string.format("%-20s %-10s pid=%-8s %s",
			name, svc.state, pid_str,
			svc.def.cmd and table.concat(svc.def.cmd, " ") or "")
	end
	table.sort(lines)
	return table.concat(lines, "\n") .. "\n"
end

-- Handle control message
local function handle_message(ibuf, typ, data, client_fd)
	if typ == rpc.START then
		local ok, err = start_service(data)
		rpc.reply(ibuf, client_fd, ok and "ok" or ("error: " .. (err or "")))
	elseif typ == rpc.STOP then
		local ok, err = stop_service(data)
		rpc.reply(ibuf, client_fd, ok and "ok" or ("error: " .. (err or "")))
	elseif typ == rpc.RESTART then
		stop_service(data)
		start_service(data)
		rpc.reply(ibuf, client_fd, "ok")
	elseif typ == rpc.STATUS then
		rpc.reply(ibuf, client_fd, status_string())
	elseif typ == rpc.SHUTDOWN then
		shutdown_requested = true
		rpc.reply(ibuf, client_fd, "shutting down")
	else
		unistd.close(client_fd)
	end
end

-- Run boot script
local function run_boot()
	if unistd.access(boot_script, "x") ~= 0 then return end
	log("running %s", boot_script)
	local pid = unistd.fork()
	if pid == 0 then
		unistd.execp("/bin/sh", { "-c", boot_script })
		os.exit(127)
	end
	wait.wait(pid)
end

-- Shutdown
local function shutdown()
	log("shutting down")
	for name, svc in pairs(services) do
		if svc.state == "running" and svc.pid then
			-- Kill the process group (negative pid)
			signal.kill(-svc.pid, signal.SIGTERM)
		end
	end
	-- Wait up to 5 seconds
	for _ = 1, 50 do
		local all_stopped = true
		for _, svc in pairs(services) do
			if svc.state == "running" then all_stopped = false; break end
		end
		if all_stopped then break end
		local wpid = wait.wait(-1, wait.WNOHANG)
		if wpid and wpid > 0 then
			for _, svc in pairs(services) do
				if svc.pid == wpid then svc.state = "stopped"; svc.pid = nil; break end
			end
		end
		ptime.nanosleep({tv_sec=0, tv_nsec=100000000})
	end
	-- Kill stragglers
	for _, svc in pairs(services) do
		if svc.state == "running" and svc.pid then
			signal.kill(-svc.pid, signal.SIGKILL)
			svc.state = "stopped"
			svc.pid = nil
		end
	end
	log("halted")
end

-- Main
signal.signal(signal.SIGPIPE, signal.SIG_IGN)
signal.signal(signal.SIGTERM, function() shutdown_requested = true end)
signal.signal(signal.SIGINT, function() shutdown_requested = true end)

-- Self-pipe for SIGCHLD notification
local chld_r, chld_w = unistd.pipe()
-- Set write end non-blocking so handler never blocks
local fcntl = require("posix.fcntl")
local flags = fcntl.fcntl(chld_w, fcntl.F_GETFL)
fcntl.fcntl(chld_w, fcntl.F_SETFL, flags + fcntl.O_NONBLOCK)

signal.signal(signal.SIGCHLD, function()
	unistd.write(chld_w, "x")
end)

if do_mount then mount_fs() end
run_boot()
load_services()

-- Start all services (non-socket ones)
for name, svc in pairs(services) do
	if not svc.def.socket then
		start_service(name)
	end
end

-- Create listening sockets for socket-activated services
local function create_listen_socket(def)
	local sock_def = def.socket
	local fd
	if sock_def.family == "unix" then
		pcall(os.remove, sock_def.path)
		fd = socket.socket(socket.AF_UNIX, sock_def.type == "dgram" and socket.SOCK_DGRAM or socket.SOCK_STREAM, 0)
		socket.bind(fd, { family = socket.AF_UNIX, path = sock_def.path })
	else
		-- inet
		fd = socket.socket(socket.AF_INET, sock_def.type == "dgram" and socket.SOCK_DGRAM or socket.SOCK_STREAM, 0)
		socket.setsockopt(fd, socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
		socket.bind(fd, { family = socket.AF_INET, addr = sock_def.addr or "0.0.0.0", port = sock_def.port })
	end
	if sock_def.type ~= "dgram" then
		socket.listen(fd, sock_def.backlog or 128)
	end
	return fd
end

for name, svc in pairs(services) do
	if svc.def.socket then
		local ok, fd = pcall(create_listen_socket, svc.def)
		if ok then
			svc.listen_fd = fd
			log("listening for %s on %s", name,
				svc.def.socket.path or ("port " .. tostring(svc.def.socket.port)))
		else
			log("failed to create socket for %s: %s", name, tostring(fd))
		end
	end
end

-- Handle socket activation
local function handle_socket_activation(name, svc)
	local style = svc.def.style or "activate"

	if style == "inetd" then
		-- Accept connection, fork child with stdin/stdout = client fd
		local client_fd = socket.accept(svc.listen_fd)
		if not client_fd then return end
		local pid = unistd.fork()
		if pid == 0 then
			unistd.close(svc.listen_fd)
			unistd.dup2(client_fd, 0)
			unistd.dup2(client_fd, 1)
			unistd.close(client_fd)
			signal.signal(signal.SIGPIPE, signal.SIG_DFL)
			if svc.def.env then
				for k, v in pairs(svc.def.env) do stdlib.setenv(k, v, true) end
			end
			local cmd = svc.def.cmd
			unistd.execp(cmd[1], { table.unpack(cmd, 2) })
			os.exit(127)
		end
		unistd.close(client_fd)
		-- Don't track as the main service pid (multiple can run)
	elseif style == "activate" then
		-- Socket activation: start service, pass listen fd as fd 3
		if svc.state == "running" then return end
		local pid = unistd.fork()
		if pid == 0 then
			-- Move listen fd to fd 3
			if svc.listen_fd ~= 3 then
				unistd.dup2(svc.listen_fd, 3)
				unistd.close(svc.listen_fd)
			end
			unistd.setsid()
			signal.signal(signal.SIGINT, signal.SIG_DFL)
			signal.signal(signal.SIGTERM, signal.SIG_DFL)
			signal.signal(signal.SIGPIPE, signal.SIG_DFL)
			stdlib.setenv("LISTEN_FDS", "1", true)
			stdlib.setenv("LISTEN_PID", tostring(unistd.getpid()), true)
			if svc.def.env then
				for k, v in pairs(svc.def.env) do stdlib.setenv(k, v, true) end
			end
			local cmd = svc.def.cmd
			unistd.execp(cmd[1], { table.unpack(cmd, 2) })
			os.exit(127)
		end
		svc.pid = pid
		svc.state = "running"
		log("activated %s (pid %d)", name, pid)
	end
end

-- Create control socket
pcall(os.remove, sock_path)
pcall(stat.mkdir, sock_path:match("^(.+)/"), tonumber("755", 8))
local srv_fd = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM, 0)
socket.bind(srv_fd, { family = socket.AF_UNIX, path = sock_path })
socket.listen(srv_fd, 5)
log("listening on %s", sock_path)

-- Main loop
local poll = require("posix.poll")

while running do
	local fds = {
		[srv_fd] = { events = { IN = true } },
		[chld_r] = { events = { IN = true } },
	}
	-- Add service listen sockets
	for _, svc in pairs(services) do
		if svc.listen_fd then
			fds[svc.listen_fd] = { events = { IN = true } }
		end
	end

	poll.poll(fds, -1)

	-- Check for control connections
	if fds[srv_fd].revents and fds[srv_fd].revents.IN then
		local ibuf, typ, data, client_fd = rpc.accept(srv_fd)
		if ibuf then
			handle_message(ibuf, typ, data, client_fd)
		end
	end

	-- Check service sockets for activation
	for name, svc in pairs(services) do
		if svc.listen_fd and fds[svc.listen_fd] and fds[svc.listen_fd].revents and fds[svc.listen_fd].revents.IN then
			handle_socket_activation(name, svc)
		end
	end

	-- Check for child exits
	if fds[chld_r].revents and fds[chld_r].revents.IN then
		-- Drain the pipe
		while unistd.read(chld_r, 64) do end

		-- Reap all dead children
		while true do
			local wpid, reason, status = wait.wait(-1, wait.WNOHANG)
			if not wpid or wpid <= 0 then break end
			for name, svc in pairs(services) do
				if svc.pid == wpid then
					log("%s exited (%s %d)", name, reason or "?", status or 0)
					svc.pid = nil
					svc.state = "stopped"
					if not shutdown_requested and svc.def.restart then
						log("restarting %s", name)
						start_service(name)
					end
					break
				end
			end
		end
	end

	if shutdown_requested then
		shutdown()
		running = false
	end
end

os.remove(sock_path)
