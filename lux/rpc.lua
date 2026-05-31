-- SPDX-License-Identifier: ISC
-- lux/rpc.lua - shared IPC protocol between luxd and luxctl
local unistd = require("posix.unistd")
local socket = require("posix.sys.socket")
local imsg = require("imsg")

local M = {}

-- Message types
M.START    = 1
M.STOP     = 2
M.RESTART  = 3
M.STATUS   = 4
M.SHUTDOWN = 5
M.ACK      = 6

-- Default socket path
M.SOCK_PATH = "/run/lux.sock"

-- Server: accept one connection, read one message
-- Returns ibuf, msg_type, msg_data, client_fd
function M.accept(srv_fd)
	local client_fd = socket.accept(srv_fd)
	if not client_fd then return nil end
	local ibuf = imsg.new(client_fd)
	ibuf:read()
	local msg = ibuf:get()
	if not msg then
		unistd.close(client_fd)
		return nil
	end
	-- Extract data before any further ibuf operations
	local msg_type = msg:type()
	local msg_data = msg:len() > 0 and msg:data() or ""
	return ibuf, msg_type, msg_data, client_fd
end

-- Server: send reply
function M.reply(ibuf, client_fd, payload)
	ibuf:compose(M.ACK, 0, 0, -1, payload or "")
	pcall(ibuf.flush, ibuf)
end

-- Client: connect, send a message, receive reply, close
function M.call(sock_path, msg_type, payload)
	local fd = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM, 0)
	local ok, err = socket.connect(fd, { family = socket.AF_UNIX, path = sock_path })
	if not ok then
		return nil, "cannot connect: " .. (err or "unknown error")
	end
	local ibuf = imsg.new(fd)
	ibuf:compose(msg_type, 0, 0, -1, payload or "")
	ibuf:flush()
	ibuf:read()
	local msg = ibuf:get()
	unistd.close(fd)
	if msg then
		return msg:len() > 0 and msg:data() or ""
	end
	return nil, "no response"
end

return M
