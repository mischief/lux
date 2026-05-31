-- SPDX-License-Identifier: ISC
-- net/ntpd.lua - SNTP time sync (runs unprivileged)
--
-- Queries NTP server periodically, sends SETTIME to main via imsg.
-- RFC 4330 (SNTPv4) - minimal client.

local unistd = require("posix.unistd")
local socket = require("posix.sys.socket")
local poll = require("posix.poll")
local time = require("posix.time")
local imsg = require("imsg")
local log = require("net.log")
local rpc = require("net.rpc")

local M = {}

local IPC_FD = 4  -- fd 3 is engine, fd 4 is ntpd
local NTP_PORT = 123
local NTP_EPOCH = 2208988800  -- seconds between 1900 and 1970
local POLL_INTERVAL = 3600    -- query every hour
local INITIAL_RETRY = 4       -- retry interval on failure

-- Build SNTPv4 request (48 bytes)
local function make_request()
	-- LI=0, VN=4, Mode=3 (client) -> byte 0x23
	local pkt = string.char(0x23) .. string.rep("\0", 47)
	return pkt
end

-- Parse SNTPv4 response, return unix timestamp (seconds + fraction)
local function parse_response(data)
	if #data < 48 then return nil, "short response" end
	-- Transmit timestamp at bytes 41-48
	local sec = string.unpack(">I4", data, 41)
	local frac = string.unpack(">I4", data, 45)
	if sec == 0 then return nil, "no timestamp" end
	local unix_sec = sec - NTP_EPOCH
	local unix_usec = math.floor(frac / 4294.967296)  -- frac * 1e6 / 2^32
	return unix_sec, unix_usec
end

function M.run(ipc_fd, server, debug_mode, verbose)
	log.procinit("ntpd")
	log.init(debug_mode, 0)
	if verbose then log.setverbose(true) end

	local ibuf = imsg.new(ipc_fd)

	-- If no server given, wait for one from main
	if not server then
		server = "pool.ntp.org"
	end

	log.info(string.format("ntpd started, server %s", server))

	local retry = INITIAL_RETRY
	local synced = false

	while true do
		-- Resolve NTP server
		local addrs = socket.getaddrinfo(server, tostring(NTP_PORT), {family = socket.AF_INET, socktype = socket.SOCK_DGRAM})
		if not addrs or #addrs == 0 then
			log.warn("cannot resolve " .. server)
			unistd.sleep(retry)
			retry = math.min(retry * 2, POLL_INTERVAL)
			goto continue
		end

		-- Open UDP socket and query
		local fd = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, 0)
		if not fd then
			log.warn("cannot create socket")
			unistd.sleep(retry)
			goto continue
		end

		local dest = {family = socket.AF_INET, addr = addrs[1].addr, port = NTP_PORT}
		local req = make_request()
		socket.sendto(fd, req, dest)

		-- Wait for response (timeout 5s)
		local fds = {[fd] = {events = {IN = true}}}
		local ready = poll.poll(fds, 5000)
		if ready and ready > 0 then
			local data = socket.recv(fd, 64)
			if data then
				local sec, usec = parse_response(data)
				if sec then
					-- Send SETTIME to main
					local payload = rpc.encode({sec = sec, usec = usec})
					ibuf:compose(rpc.SETTIME, 0, 0, -1, payload)
					ibuf:flush()
					if not synced then
						log.info(string.format("clock set to %d.%06d", sec, usec))
						synced = true
					else
						log.debug(string.format("clock adjusted to %d.%06d", sec, usec))
					end
					retry = INITIAL_RETRY
				else
					log.warn("bad NTP response: " .. tostring(usec))
				end
			end
		else
			log.warn("NTP timeout from " .. server)
		end

		unistd.close(fd)

		-- Sleep until next poll
		unistd.sleep(synced and POLL_INTERVAL or retry)
		if not synced then
			retry = math.min(retry * 2, 64)
		end

		::continue::
	end
end

return M
