#!/bin/sh
# SPDX-License-Identifier: ISC
# What luxd does only as pid 1: it mounts the filesystems an init
# mounts, and it has nowhere to exit to. Both are checked in a user
# namespace, where the mounts it makes go nowhere near this machine.
D="$(cd "$(dirname "$0")/.." && pwd)"
command -v unshare >/dev/null 2>&1 || exit 77
unshare -r -m true 2>/dev/null || exit 77
unshare -r -p -f true 2>/dev/null || exit 77
[ "$IN_NS" = 1 ] || { IN_NS=1 exec unshare -r -m "$0" "$@"; }

# /run is ours and holds everything the test looks at. luxd would mount
# a tmpfs over it, which is the thing being tested.
mount -t tmpfs tmpfs /run || exit 77
: > /run/kept

cat > /run/exit <<EOF
#!/bin/sh
: > /run/exited
EOF
chmod +x /run/exit
mkdir -p /run/services

# pid 1 of its own namespace, so getpid() answers 1
luxd() {
	unshare -p -f lua5.4 "$D/luxd.lua" -s /run/lux.sock \
		-d /run/services -e "$1" 2>/dev/null &
	PID=$!
	n=0
	while [ ! -S /run/lux.sock ]; do
		n=$((n + 1))
		[ "$n" -gt 50 ] && return 1
		sleep 0.1
	done
	return 0
}

luxd /run/exit || exit 1
# the mount it would have made over /run never happened
[ -e /run/kept ] || { echo "luxd mounted over /run"; exit 1; }
lua5.4 "$D/luxctl.lua" -s /run/lux.sock shutdown || exit 1
wait $PID 2>/dev/null
[ -e /run/exited ] || { echo "the exit program did not run"; exit 1; }

# the control: a file that is not executable is not an exit program, so
# nothing of it runs and luxd takes its own path instead
rm -f /run/exited /run/lux.sock
chmod -x /run/exit
luxd /run/exit || exit 1
lua5.4 "$D/luxctl.lua" -s /run/lux.sock shutdown || exit 1
wait $PID 2>/dev/null
[ -e /run/exited ] && { echo "a non-executable exit program ran"; exit 1; }
exit 0
