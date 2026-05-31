-- SPDX-License-Identifier: ISC
-- net/log.lua - OpenBSD-style logging (syslog vs stderr)
local syslog = require("posix.syslog")

local M = {}

local debug_mode = false
local verbose = false
local procname = "netd"

M.LOG_DAEMON = syslog.LOG_DAEMON

function M.init(is_debug, facility)
	debug_mode = is_debug
	verbose = is_debug
	if not debug_mode then
		syslog.openlog(procname, syslog.LOG_PID + syslog.LOG_NDELAY, facility)
	end
end

function M.procinit(name)
	procname = name
end

function M.setverbose(v)
	verbose = v
end

local function logit(pri, msg)
	if debug_mode then
		io.stderr:write(msg .. "\n")
		io.stderr:flush()
	else
		syslog.syslog(pri, msg)
	end
end

function M.fatal(msg)
	if msg then
		logit(syslog.LOG_CRIT, string.format("fatal in %s: %s", procname, msg))
	else
		logit(syslog.LOG_CRIT, string.format("fatal in %s", procname))
	end
	os.exit(1)
end

function M.warn(msg)
	logit(syslog.LOG_ERR, msg)
end

function M.info(msg)
	logit(syslog.LOG_INFO, msg)
end

function M.debug(msg)
	if verbose then
		logit(syslog.LOG_DEBUG, msg)
	end
end

return M
