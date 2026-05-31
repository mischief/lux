#!/usr/bin/env lua5.4
-- SPDX-License-Identifier: ISC
-- luxctl - lux service control tool
local a = arg or { [0] = "luxctl" }
local src = a[0]:match("(.+/)") or "./"
package.path = src .. "?.lua;" .. package.path

local rpc = require("lux.rpc")

local sock_path = rpc.SOCK_PATH

-- Parse -s option before command
local i = 1
while i <= #arg do
	if arg[i] == "-s" then
		table.remove(arg, i)
		sock_path = table.remove(arg, i)
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

local function call(msg_type, payload)
	local data, err = rpc.call(sock_path, msg_type, payload)
	if not data then
		io.stderr:write("luxctl: " .. (err or "unknown error") .. "\n")
		os.exit(1)
	end
	if data ~= "" then
		io.write(data)
		if data:sub(-1) ~= "\n" then io.write("\n") end
	end
end

local cmd = arg[1]
if not cmd then usage() end

if cmd == "status" or cmd == "list" then
	call(rpc.STATUS)
elseif cmd == "start" then
	if not arg[2] then usage() end
	call(rpc.START, arg[2])
elseif cmd == "stop" then
	if not arg[2] then usage() end
	call(rpc.STOP, arg[2])
elseif cmd == "restart" then
	if not arg[2] then usage() end
	call(rpc.RESTART, arg[2])
elseif cmd == "shutdown" or cmd == "halt" or cmd == "poweroff" then
	call(rpc.SHUTDOWN)
else
	io.stderr:write("luxctl: unknown command: " .. cmd .. "\n")
	usage()
end
