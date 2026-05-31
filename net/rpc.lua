-- SPDX-License-Identifier: ISC
-- net/rpc.lua - shared imsg types and payload encoding for netd/netctl

local M = {}

-- internal: main <-> engine
M.UDPSOCK     = 1
M.GETMAC      = 2
M.MAC         = 3
M.CONFIGURE   = 4
M.DECONFIGURE = 5

-- control: netctl <-> main <-> engine
M.CTL_STATUS  = 6
M.CTL_RENEW   = 7
M.CTL_RELEASE = 8
M.CTL_REPLY   = 9

-- ntp: main <-> ntpd child
M.NTP_SERVER  = 10  -- main -> ntpd: NTP server address
M.SETTIME     = 11  -- ntpd -> main: set clock (sec, usec)

-- Encode a table as key=value\n pairs.
-- Repeated keys (tables) emit multiple lines with the same key.
function M.encode(t)
	local parts = {}
	for k, v in pairs(t) do
		if type(v) == "table" then
			for _, item in ipairs(v) do
				parts[#parts + 1] = k .. "=" .. tostring(item)
			end
		else
			parts[#parts + 1] = k .. "=" .. tostring(v)
		end
	end
	return table.concat(parts, "\n")
end

-- Decode key=value\n pairs into a table.
-- Repeated keys become arrays.
function M.decode(s)
	if not s or s == "" then return {} end
	local t = {}
	for line in s:gmatch("[^\n]+") do
		local k, v = line:match("^([^=]+)=(.*)$")
		if k then
			if t[k] then
				if type(t[k]) ~= "table" then t[k] = {t[k]} end
				t[k][#t[k] + 1] = v
			else
				t[k] = v
			end
		end
	end
	return t
end

return M
