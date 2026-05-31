#!/bin/sh
# SPDX-License-Identifier: ISC
set -e
D="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'kill $PID 2>/dev/null; wait $PID 2>/dev/null; rm -rf "$TMPDIR"' EXIT

mkdir -p "$TMPDIR/services"
lua5.4 "$D/luxd.lua" -s "$TMPDIR/lux.sock" -d "$TMPDIR/services" 2>/dev/null &
PID=$!
sleep 1

# Verify it's running
kill -0 $PID

# Verify socket exists
test -S "$TMPDIR/lux.sock"

# Send shutdown via luxctl
lua5.4 "$D/luxctl.lua" -s "$TMPDIR/lux.sock" shutdown >/dev/null 2>&1 || true

# Wait for exit (up to 5s)
for i in 1 2 3 4 5; do
    kill -0 $PID 2>/dev/null || exit 0
    sleep 1
done

# If still alive, fail
exit 1
