#!/usr/bin/env lua
-- SPDX-License-Identifier: ISC
-- luxd-run: execute a service's run function in a clean interpreter
local file = arg[1]
local name = arg[2]

if not file or not name then
	io.stderr:write("usage: luxd-run <service-file> <service-name>\n")
	os.exit(1)
end

local svc_def
service = function(n)
	return function(d)
		if n == name then svc_def = d end
	end
end

local ok, err = pcall(dofile, file)
if not ok then
	io.stderr:write("luxd-run: " .. tostring(err) .. "\n")
	os.exit(1)
end

if not svc_def or not svc_def.run then
	io.stderr:write("luxd-run: no run function for '" .. name .. "' in " .. file .. "\n")
	os.exit(1)
end

local rok, rerr = pcall(svc_def.run)
if not rok then
	io.stderr:write("luxd-run: " .. name .. ": " .. tostring(rerr) .. "\n")
	os.exit(1)
end
