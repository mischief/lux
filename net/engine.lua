-- SPDX-License-Identifier: ISC
-- net/engine.lua - DHCP state machine (runs unprivileged)
--
-- States: INIT -> SELECTING -> REQUESTING -> BOUND -> RENEWING -> REBINDING
-- Receives UDP socket fd from main via imsg. Requests MAC via imsg.

local unistd = require("posix.unistd")
local socket = require("posix.sys.socket")
local poll = require("posix.poll")
local time = require("posix.time")
local syslog = require("posix.syslog")
local imsg = require("imsg")
local log = require("net.log")
local dhcp = require("net.dhcp")
local rpc = require("net.rpc")

local M = {}

-- imsg types (must match netd.lua)

-- DHCP states
local STATE_INIT       = "INIT"
local STATE_SELECTING  = "SELECTING"
local STATE_REQUESTING = "REQUESTING"
local STATE_BOUND      = "BOUND"
local STATE_RENEWING   = "RENEWING"
local STATE_REBINDING  = "REBINDING"

local DISCOVER_TIMEOUT = 4
local REQUEST_TIMEOUT  = 4
local MAX_RETRIES      = 5

local BROADCAST = {family = socket.AF_INET, addr = "255.255.255.255", port = 67}

local function now()
	local ts = time.clock_gettime(time.CLOCK_MONOTONIC)
	return ts.tv_sec
end

function M.run(ipc_fd, ifname, debug_mode, verbose)
	log.procinit("netd")
	log.init(debug_mode, syslog.LOG_DAEMON)
	if verbose then log.setverbose(true) end

	-- Set up imsgbuf
	local ibuf = imsg.new(ipc_fd)
	ibuf:allow_fdpass()

	-- Receive UDP socket fd from main
	log.debug("waiting for UDP socket from main")
	ibuf:read()
	local msg = ibuf:get()
	if not msg or msg:type() ~= rpc.UDPSOCK then
		log.fatal("expected UDPSOCK imsg")
	end
	local udp_fd = msg:fd()
	if udp_fd < 0 then
		log.fatal("no fd in UDPSOCK imsg")
	end
	log.debug(string.format("received UDP socket fd %d", udp_fd))

	-- Request MAC from main
	ibuf:compose(rpc.GETMAC, 0, 0, -1, "")
	ibuf:flush()
	ibuf:read()
	msg = ibuf:get()
	if not msg or msg:type() ~= rpc.MAC then
		log.fatal("expected MAC imsg")
	end
	local mac = msg:len() > 0 and msg:data() or "00:00:00:00:00:00"
	log.info(string.format("engine started for %s [%s]", ifname, mac))

	-- Generate xid from MAC
	local mac_bytes = dhcp.mac_to_bytes(mac)
	local xid = string.unpack(">I4", mac_bytes:sub(1, 4))

	local state = STATE_INIT
	local retries = 0
	local lease = nil
	local lease_start = 0
	local next_action = now()

	-- Send CONFIGURE to main via imsg
	local function send_configure(offer)
		local msg = {
			addr = offer.yiaddr,
			mask = offer.subnet_mask or "255.255.255.0",
			router = offer.router or "",
			domain = offer.domain or "",
			dns = offer.dns or {},
			ntp = offer.ntp or {},
		}
		ibuf:compose(rpc.CONFIGURE, 0, 0, -1, rpc.encode(msg))
		ibuf:flush()
	end

	local function send_deconfigure()
		ibuf:compose(rpc.DECONFIGURE, 0, 0, -1, "")
		ibuf:flush()
	end

	local function send_discover()
		xid = xid + 1
		local pkt = dhcp.encode({
			xid = xid,
			mac = mac,
			msg_type = dhcp.DISCOVER,
		})
		local ok, err = socket.sendto(udp_fd, pkt, BROADCAST)
		if not ok then
			log.warn("sendto: " .. tostring(err))
		else
			log.debug("sent DISCOVER")
		end
	end

	local function send_request(server_id, requested_ip)
		local pkt = dhcp.encode({
			xid = xid,
			mac = mac,
			msg_type = dhcp.REQUEST,
			server_id = server_id,
			requested_ip = requested_ip,
		})
		local ok, err = socket.sendto(udp_fd, pkt, BROADCAST)
		if not ok then
			log.warn("sendto: " .. tostring(err))
		else
			log.debug(string.format("sent REQUEST for %s", requested_ip))
		end
	end

	-- Main engine loop
	local fds = {
		[udp_fd] = {events = {IN = true}},
		[ipc_fd] = {events = {IN = true}},
	}

	while true do
		local timeout_ms = math.max(0, (next_action - now())) * 1000
		local ready = poll.poll(fds, math.floor(timeout_ms))

		-- Incoming DHCP packet
		if ready and ready > 0 and fds[udp_fd].revents and fds[udp_fd].revents.IN then
			local pkt = socket.recv(udp_fd, 1500)
			if pkt then
				local reply = dhcp.decode(pkt)
				if reply and reply.xid == xid then
					if state == STATE_SELECTING and reply.msg_type == dhcp.OFFER then
						log.info(string.format("got OFFER: %s from %s",
							reply.yiaddr, reply.server_id or "unknown"))
						send_request(reply.server_id, reply.yiaddr)
						lease = reply
						state = STATE_REQUESTING
						retries = 0
						next_action = now() + REQUEST_TIMEOUT

					elseif state == STATE_REQUESTING and reply.msg_type == dhcp.ACK then
						-- Verify server_id matches the OFFER we accepted
						if lease and reply.server_id and lease.server_id
							and reply.server_id ~= lease.server_id then
							log.warn(string.format("ACK from wrong server %s (expected %s), ignoring",
								reply.server_id, lease.server_id))
						else
							log.info(string.format("got ACK: %s lease %ds",
								reply.yiaddr, reply.lease_time or 0))
							lease = reply
							lease_start = now()
							state = STATE_BOUND
							send_configure(lease)
							local t1 = reply.renewal_time or math.floor((reply.lease_time or 3600) / 2)
							next_action = lease_start + t1
						end

					elseif state == STATE_REQUESTING and reply.msg_type == dhcp.NAK then
						log.warn("got NAK, restarting")
						state = STATE_INIT
						retries = 0
						next_action = now()

					elseif (state == STATE_RENEWING or state == STATE_REBINDING)
						and reply.msg_type == dhcp.ACK then
						-- Only accept from our current server during renewal
						if lease and reply.server_id and lease.server_id
							and reply.server_id ~= lease.server_id then
							log.warn(string.format("renewal ACK from wrong server %s, ignoring",
								reply.server_id))
						else
							log.info(string.format("renewed: %s lease %ds",
								reply.yiaddr, reply.lease_time or 0))
							lease = reply
							lease_start = now()
							state = STATE_BOUND
							send_configure(lease)
							local t1 = reply.renewal_time or math.floor((reply.lease_time or 3600) / 2)
							next_action = lease_start + t1
						end
					end
				end
			end
		end

		-- IPC messages from main (control commands)
		if ready and ready > 0 and fds[ipc_fd].revents and fds[ipc_fd].revents.IN then
			local ret = ibuf:read()
			if not ret then break end -- parent gone
			while true do
				local m = ibuf:get()
				if not m then break end
				local mt = m:type()
				if mt == rpc.CTL_STATUS then
					local info = rpc.encode({
						interface = ifname,
						state = state,
						mac = mac,
						addr = lease and lease.yiaddr or "",
						remaining = lease and (lease.lease_time - (now() - lease_start)) or 0,
					})
					ibuf:compose(rpc.CTL_REPLY, 0, 0, -1, info)
					ibuf:flush()
				elseif mt == rpc.CTL_RENEW then
					log.info("renew requested")
					state = STATE_INIT
					retries = 0
					next_action = now()
					ibuf:compose(rpc.CTL_REPLY, 0, 0, -1, "ok")
					ibuf:flush()
				elseif mt == rpc.CTL_RELEASE then
					log.info("release requested")
					send_deconfigure()
					lease = nil
					lease_start = 0
					state = STATE_INIT
					retries = 0
					next_action = now() + 86400 -- don't re-acquire immediately
					ibuf:compose(rpc.CTL_REPLY, 0, 0, -1, "ok")
					ibuf:flush()
				end
			end
		end

		-- Timer-driven state transitions
		if now() >= next_action then
			if state == STATE_INIT then
				send_discover()
				state = STATE_SELECTING
				retries = 0
				next_action = now() + DISCOVER_TIMEOUT

			elseif state == STATE_SELECTING then
				retries = retries + 1
				if retries >= MAX_RETRIES then
					log.warn("no OFFER received, restarting")
					state = STATE_INIT
					retries = 0
					next_action = now() + DISCOVER_TIMEOUT * 2
				else
					send_discover()
					next_action = now() + DISCOVER_TIMEOUT * math.min(retries + 1, 4)
				end

			elseif state == STATE_REQUESTING then
				retries = retries + 1
				if retries >= MAX_RETRIES then
					log.warn("no ACK received, restarting")
					state = STATE_INIT
					retries = 0
					next_action = now()
				else
					send_request(lease.server_id, lease.yiaddr)
					next_action = now() + REQUEST_TIMEOUT * math.min(retries + 1, 4)
				end

			elseif state == STATE_BOUND then
				log.debug("T1 expired, renewing")
				state = STATE_RENEWING
				send_request(lease.server_id, lease.yiaddr)
				retries = 0
				local t2 = lease.rebinding_time or math.floor((lease.lease_time or 3600) * 7 / 8)
				next_action = lease_start + t2

			elseif state == STATE_RENEWING then
				log.debug("T2 expired, rebinding")
				state = STATE_REBINDING
				send_request(nil, lease.yiaddr)
				retries = 0
				next_action = lease_start + (lease.lease_time or 3600)

			elseif state == STATE_REBINDING then
				log.warn("lease expired")
				send_deconfigure()
				state = STATE_INIT
				retries = 0
				next_action = now()
			end
		end
	end
end

return M
