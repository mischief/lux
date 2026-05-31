#!/usr/bin/env lua5.4
-- SPDX-License-Identifier: ISC
-- luxctl - lux service control tool
local unistd = require("posix.unistd")
local socket = require("posix.sys.socket")
local imsg = require("imsg")

-- Message types (must match luxd)
local MSG_START    = 1
local MSG_STOP     = 2
local MSG_RESTART  = 3
local MSG_STATUS   = 4
local MSG_SHUTDOWN = 5
local MSG_ACK      = 6

local sock_path = "/run/lux.sock"

-- Parse -s option before command
local i = 1
while i <= #arg do
	if arg[i] == "-s" then
		i = i + 1
		sock_path = arg[i]
		table.remove(arg, i - 1)
		table.remove(arg, i - 1)
		i = i - 1
	else
		break
	end
end

local function usage()
	io.stderr:write([[
usage: luxctl [-s socket] <command> [service]

commands:
  status            show all services
  start <service>   start a service
  stop <service>    stop a service
  restart <service> restart a service
  shutdown          shut down the system
]])
	os.exit(1)
end

local function connect()
	local fd = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM, 0)
	local ok, err = socket.connect(fd, { family = socket.AF_UNIX, path = sock_path })
	if not ok then
		io.stderr:write("luxctl: cannot connect to " .. sock_path .. ": " .. (err or "unknown error") .. "\n")
		os.exit(1)
	end
	return fd
end

local function send_and_recv(msg_type, payload)
	local fd = connect()
	local ibuf = imsg.new(fd)

	ibuf:compose(msg_type, 0, 0, -1, payload or "")
	ibuf:flush()

	ibuf:read()
	local msg = ibuf:get()
	if msg then
		local data = msg:data()
		if data and data ~= "" then
			io.write(data)
			if data:sub(-1) ~= "\n" then io.write("\n") end
		end
	end

	unistd.close(fd)
end

-- Parse command
local cmd = arg[1]
if not cmd then usage() end

if cmd == "status" or cmd == "list" then
	send_and_recv(MSG_STATUS)
elseif cmd == "start" then
	if not arg[2] then usage() end
	send_and_recv(MSG_START, arg[2])
elseif cmd == "stop" then
	if not arg[2] then usage() end
	send_and_recv(MSG_STOP, arg[2])
elseif cmd == "restart" then
	if not arg[2] then usage() end
	send_and_recv(MSG_RESTART, arg[2])
elseif cmd == "shutdown" or cmd == "halt" or cmd == "poweroff" then
	send_and_recv(MSG_SHUTDOWN)
else
	io.stderr:write("luxctl: unknown command: " .. cmd .. "\n")
	usage()
end
