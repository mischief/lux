#!/usr/bin/env lua5.4
-- SPDX-License-Identifier: ISC
-- logd - system log daemon
-- Reads from /dev/log (fd 3 via socket activation) and /dev/kmsg
-- Writes to /var/log/messages with rotation
local unistd = require("posix.unistd")
local fcntl = require("posix.fcntl")
local poll = require("posix.poll")
local stat = require("posix.sys.stat")
local signal = require("posix.signal")
local ptime = require("posix.time")

-- Configuration
local log_path = "/var/log/messages"
local max_size = 10 * 1024 * 1024 -- 10MB
local max_files = 10 -- .0 through .9
local rotate_interval = 3600 -- 1 hour

-- State
local log_fd = nil
local log_size = 0
local last_rotate = os.time()
local running = true

signal.signal(signal.SIGTERM, function() running = false end)
signal.signal(signal.SIGINT, function() running = false end)
signal.signal(signal.SIGPIPE, signal.SIG_IGN)

-- Open log file for appending
local function open_log()
	if log_fd then unistd.close(log_fd) end
	pcall(stat.mkdir, "/var/log", tonumber("755", 8))
	log_fd = fcntl.open(log_path, fcntl.O_WRONLY + fcntl.O_CREAT + fcntl.O_APPEND, 420)
	if log_fd then
		local s = stat.stat(log_path)
		log_size = s and s.st_size or 0
	end
end

-- Rotate logs: messages -> messages.0 -> messages.1 ... -> messages.9
local function rotate()
	if log_fd then unistd.close(log_fd); log_fd = nil end
	-- Remove oldest
	os.remove(log_path .. "." .. tostring(max_files - 1))
	-- Shift .N-1 -> .N
	for i = max_files - 2, 0, -1 do
		os.rename(log_path .. "." .. tostring(i), log_path .. "." .. tostring(i + 1))
	end
	-- Current -> .0
	os.rename(log_path, log_path .. ".0")
	-- Open fresh
	open_log()
	last_rotate = os.time()
end

-- Check if rotation is needed
local function check_rotate()
	if log_size >= max_size then rotate(); return end
	if os.time() - last_rotate >= rotate_interval then rotate() end
end

-- Format timestamp
local function timestamp()
	local t = ptime.localtime(ptime.time())
	if not t then return os.date("%b %d %H:%M:%S") end
	local months = {"Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"}
	return string.format("%s %2d %02d:%02d:%02d",
		months[(t.tm_mon or 0) + 1] or "???", t.tm_mday or 0,
		t.tm_hour or 0, t.tm_min or 0, t.tm_sec or 0)
end

-- Parse syslog priority prefix <N> and return facility, severity, message
local function parse_syslog(raw)
	local pri, msg = raw:match("^<(%d+)>(.*)")
	if pri then
		return tonumber(pri), msg
	end
	return nil, raw
end

-- Facility names
local facilities = {
	[0]="kern", [1]="user", [2]="mail", [3]="daemon",
	[4]="auth", [5]="syslog", [6]="lpr", [7]="news",
	[8]="uucp", [9]="cron", [10]="authpriv", [11]="ftp",
	[16]="local0", [17]="local1", [18]="local2", [19]="local3",
	[20]="local4", [21]="local5", [22]="local6", [23]="local7",
}

-- Severity names
local severities = {
	[0]="emerg", [1]="alert", [2]="crit", [3]="err",
	[4]="warning", [5]="notice", [6]="info", [7]="debug",
}

-- Write a log line
local function write_log(line)
	if not log_fd then open_log() end
	if not log_fd then return end
	local out = line .. "\n"
	unistd.write(log_fd, out)
	log_size = log_size + #out
	check_rotate()
end

-- Process a syslog message
local function process_syslog(raw)
	local pri, msg = parse_syslog(raw)
	local ts = timestamp()
	if pri then
		local fac = math.floor(pri / 8)
		local sev = pri % 8
		local fname = facilities[fac] or tostring(fac)
		local sname = severities[sev] or tostring(sev)
		write_log(ts .. " " .. fname .. "." .. sname .. ": " .. msg)
	else
		write_log(ts .. " " .. msg)
	end
end

-- Process a kmsg line (format: priority,sequence,timestamp,-;message)
local function process_kmsg(line)
	local pri, msg = line:match("^(%d+),.-;(.*)")
	if pri and msg then
		local sev = tonumber(pri) % 8
		local ts = timestamp()
		local sname = severities[sev] or tostring(sev)
		write_log(ts .. " kern." .. sname .. ": " .. msg)
	end
end

-- Main
open_log()

-- Get syslog socket from socket activation (fd 3) or open /dev/log
local syslog_fd = nil
if os.getenv("LISTEN_FDS") == "1" then
	syslog_fd = 3
else
	-- Fallback: try to read from existing /dev/log
	local socket = require("posix.sys.socket")
	pcall(os.remove, "/dev/log")
	syslog_fd = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM, 0)
	if syslog_fd then
		socket.bind(syslog_fd, { family = socket.AF_UNIX, path = "/dev/log" })
	end
end

-- Open /dev/kmsg for reading kernel messages
local kmsg_fd = fcntl.open("/dev/kmsg", fcntl.O_RDONLY + fcntl.O_NONBLOCK)

-- Build poll set
local fds = {}
if syslog_fd then fds[syslog_fd] = { events = { IN = true } } end
if kmsg_fd then fds[kmsg_fd] = { events = { IN = true } } end

write_log(timestamp() .. " logd: started")

while running do
	local ready = poll.poll(fds, 1000) -- 1s timeout for rotation checks

	if ready and ready > 0 then
		-- Read syslog messages
		if syslog_fd and fds[syslog_fd].revents and fds[syslog_fd].revents.IN then
			local msg = unistd.read(syslog_fd, 8192)
			if msg and msg ~= "" then
				-- May contain multiple null-terminated messages
				for m in msg:gmatch("[^\0]+") do
					process_syslog(m)
				end
			end
		end
		-- Read kernel messages
		if kmsg_fd and fds[kmsg_fd].revents and fds[kmsg_fd].revents.IN then
			local line = unistd.read(kmsg_fd, 8192)
			if line and line ~= "" then
				for l in line:gmatch("[^\n]+") do
					process_kmsg(l)
				end
			end
		end
	end

	-- Periodic rotation check
	check_rotate()
end

write_log(timestamp() .. " logd: shutting down")
if log_fd then unistd.close(log_fd) end
