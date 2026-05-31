-- SPDX-License-Identifier: ISC
-- net/dhcp.lua - DHCP packet encode/decode (RFC 2131)

local M = {}

-- DHCP message types
M.DISCOVER = 1
M.OFFER    = 2
M.REQUEST  = 3
M.DECLINE  = 4
M.ACK      = 5
M.NAK      = 6
M.RELEASE  = 7
M.INFORM   = 8

-- DHCP option codes
M.OPT_SUBNET_MASK     = 1
M.OPT_ROUTER          = 3
M.OPT_DNS             = 6
M.OPT_HOSTNAME        = 12
M.OPT_DOMAIN          = 15
M.OPT_NTP             = 42
M.OPT_BROADCAST       = 28
M.OPT_REQUESTED_IP    = 50
M.OPT_LEASE_TIME      = 51
M.OPT_MSG_TYPE        = 53
M.OPT_SERVER_ID       = 54
M.OPT_PARAM_LIST      = 55
M.OPT_RENEWAL_TIME    = 58
M.OPT_REBINDING_TIME  = 59
M.OPT_END             = 255

local COOKIE = "\x63\x82\x53\x63"
local BOOTREQUEST = 1
local BOOTREPLY = 2
local HTYPE_ETHER = 1

-- Format an IPv4 address from 4 bytes
local function bytes_to_ip(s, offset)
	return string.format("%d.%d.%d.%d",
		string.byte(s, offset),
		string.byte(s, offset + 1),
		string.byte(s, offset + 2),
		string.byte(s, offset + 3))
end

-- Convert dotted-quad to 4 bytes
local function ip_to_bytes(ip)
	local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	return string.char(tonumber(a), tonumber(b), tonumber(c), tonumber(d))
end

-- Convert MAC string "aa:bb:cc:dd:ee:ff" to 6 bytes
function M.mac_to_bytes(mac)
	local bytes = {}
	for hex in mac:gmatch("%x%x") do
		bytes[#bytes + 1] = string.char(tonumber(hex, 16))
	end
	return table.concat(bytes)
end

-- Build a DHCP packet
-- opts: {xid, mac, ciaddr, msg_type, requested_ip, server_id, hostname}
function M.encode(opts)
	local mac_bytes = M.mac_to_bytes(opts.mac)
	local chaddr = mac_bytes .. string.rep("\0", 16 - #mac_bytes)
	local ciaddr = ip_to_bytes(opts.ciaddr or "0.0.0.0")

	-- Fixed header (236 bytes)
	local pkt = string.pack(">BBBB I4 I2 I2",
		BOOTREQUEST,  -- op
		HTYPE_ETHER,  -- htype
		6,            -- hlen
		0,            -- hops
		opts.xid,     -- xid
		0,            -- secs
		0x8000        -- flags (broadcast)
	)
	.. ciaddr                    -- ciaddr (4)
	.. "\0\0\0\0"               -- yiaddr (4)
	.. "\0\0\0\0"               -- siaddr (4)
	.. "\0\0\0\0"               -- giaddr (4)
	.. chaddr                    -- chaddr (16)
	.. string.rep("\0", 64)     -- sname (64)
	.. string.rep("\0", 128)    -- file (128)
	.. COOKIE                    -- magic cookie

	-- Options
	-- Message type (required)
	pkt = pkt .. string.char(M.OPT_MSG_TYPE, 1, opts.msg_type)

	-- Requested IP
	if opts.requested_ip then
		pkt = pkt .. string.char(M.OPT_REQUESTED_IP, 4) .. ip_to_bytes(opts.requested_ip)
	end

	-- Server identifier
	if opts.server_id then
		pkt = pkt .. string.char(M.OPT_SERVER_ID, 4) .. ip_to_bytes(opts.server_id)
	end

	-- Hostname
	if opts.hostname then
		pkt = pkt .. string.char(M.OPT_HOSTNAME, #opts.hostname) .. opts.hostname
	end

	-- Parameter request list
	pkt = pkt .. string.char(M.OPT_PARAM_LIST, 5,
		M.OPT_SUBNET_MASK, M.OPT_ROUTER, M.OPT_DNS, M.OPT_DOMAIN, M.OPT_NTP)

	-- End
	pkt = pkt .. string.char(M.OPT_END)

	-- Pad to minimum BOOTP size (300 bytes)
	if #pkt < 300 then
		pkt = pkt .. string.rep("\0", 300 - #pkt)
	end

	return pkt
end

-- Parse a DHCP reply packet
-- Returns table with: msg_type, yiaddr, siaddr, options (subnet, router, dns, domain, lease_time, server_id, etc.)
function M.decode(pkt)
	if #pkt < 240 then return nil, "packet too short" end

	local op = string.byte(pkt, 1)
	if op ~= BOOTREPLY then return nil, "not a BOOTREPLY" end

	local xid = string.unpack(">I4", pkt, 5)
	local yiaddr = bytes_to_ip(pkt, 17)
	local siaddr = bytes_to_ip(pkt, 21)

	-- Verify magic cookie at offset 237
	if pkt:sub(237, 240) ~= COOKIE then
		return nil, "bad magic cookie"
	end

	local result = {
		xid = xid,
		yiaddr = yiaddr,
		siaddr = siaddr,
		dns = {},
	}

	-- Parse options starting at byte 241
	local pos = 241
	while pos <= #pkt do
		local code = string.byte(pkt, pos)
		if code == M.OPT_END then break end
		if code == 0 then -- pad
			pos = pos + 1
		else
			if pos + 1 > #pkt then break end
			local len = string.byte(pkt, pos + 1)
			local data = pkt:sub(pos + 2, pos + 1 + len)
			pos = pos + 2 + len

			if code == M.OPT_MSG_TYPE and len == 1 then
				result.msg_type = string.byte(data, 1)
			elseif code == M.OPT_SUBNET_MASK and len == 4 then
				result.subnet_mask = bytes_to_ip(data, 1)
			elseif code == M.OPT_ROUTER and len >= 4 then
				result.router = bytes_to_ip(data, 1)
			elseif code == M.OPT_DNS then
				for i = 1, len, 4 do
					if i + 3 <= len then
						result.dns[#result.dns + 1] = bytes_to_ip(data, i)
					end
				end
			elseif code == M.OPT_NTP then
				result.ntp = result.ntp or {}
				for i = 1, len, 4 do
					if i + 3 <= len then
						result.ntp[#result.ntp + 1] = bytes_to_ip(data, i)
					end
				end
			elseif code == M.OPT_DOMAIN then
				result.domain = data
			elseif code == M.OPT_LEASE_TIME and len == 4 then
				result.lease_time = string.unpack(">I4", data)
			elseif code == M.OPT_SERVER_ID and len == 4 then
				result.server_id = bytes_to_ip(data, 1)
			elseif code == M.OPT_RENEWAL_TIME and len == 4 then
				result.renewal_time = string.unpack(">I4", data)
			elseif code == M.OPT_REBINDING_TIME and len == 4 then
				result.rebinding_time = string.unpack(">I4", data)
			end
		end
	end

	return result
end

return M
