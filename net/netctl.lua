#!/usr/bin/env lua5.4
-- SPDX-License-Identifier: ISC
-- netctl - control program for netd
--
-- Usage: netctl [-s socket] <command>
-- Commands: status, renew, release

local unistd = require("posix.unistd")
local socket = require("posix.sys.socket")
local imsg = require("imsg")
local rpc = require("net.rpc")

local sock_path = nil
local command = nil

local function usage()
	io.stderr:write("usage: netctl [-s socket] status|renew|release\n")
	os.exit(1)
end

local optind = 1
for opt, optarg, oi in unistd.getopt(arg, "s:") do
	if opt == "?" then usage() end
	if opt == "s" then sock_path = optarg end
	optind = oi
end

command = arg[optind]
if not command then usage() end

-- Default socket path: /run/netd.<iface>.sock — need interface or explicit -s
if not sock_path then
	-- Try to find a netd socket
	local p = io.popen("ls /run/netd.*.sock 2>/dev/null")
	if p then
		sock_path = p:read("l")
		p:close()
	end
	if not sock_path then
		io.stderr:write("netctl: no socket found, use -s\n")
		os.exit(1)
	end
end

local cmd_types = {
	status  = rpc.CTL_STATUS,
	renew   = rpc.CTL_RENEW,
	release = rpc.CTL_RELEASE,
}

local mtype = cmd_types[command]
if not mtype then
	io.stderr:write(string.format("netctl: unknown command '%s'\n", command))
	usage()
end

-- Connect to netd control socket
local fd = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM, 0)
local ok, err = socket.connect(fd, {family = socket.AF_UNIX, path = sock_path})
if not ok then
	io.stderr:write(string.format("netctl: connect %s: %s\n", sock_path, err))
	os.exit(1)
end

local ibuf = imsg.new(fd)

-- Send command
ibuf:compose(mtype, 0, 0, -1, "")
ibuf:flush()

-- Wait for reply (status gets a reply, renew/release just get ack)
local ret = ibuf:read()
if ret then
	local msg = ibuf:get()
	if msg and msg:type() == rpc.CTL_REPLY and msg:len() > 0 then
		local data = msg:data()
		if command == "status" then
			local info = rpc.decode(data)
			io.write(string.format("interface: %s\n", info.interface or "?"))
			io.write(string.format("state:     %s\n", info.state or "?"))
			io.write(string.format("mac:       %s\n", info.mac or "?"))
			io.write(string.format("address:   %s\n", info.addr or "none"))
			local remaining = tonumber(info.remaining) or 0
			if remaining > 0 then
				io.write(string.format("lease:     %ds remaining\n", remaining))
			end
		else
			io.write(data .. "\n")
		end
	end
end

unistd.close(fd)
