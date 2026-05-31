#!/bin/sh
# SPDX-License-Identifier: ISC
set -e
D="$(cd "$(dirname "$0")/.." && pwd)"
TESTDIR=$(mktemp -d)
trap 'kill $PID 2>/dev/null; wait $PID 2>/dev/null; rm -rf "$TESTDIR"' EXIT

mkdir -p "$TESTDIR/services"
cat > "$TESTDIR/services/sleeper.lua" << 'EOF'
service "sleeper" {
    cmd = { "sleep", "300" },
    restart = true,
}
EOF

lua5.4 "$D/luxd.lua" -s "$TESTDIR/lux.sock" -d "$TESTDIR/services" 2>/dev/null &
PID=$!
sleep 1

# Stop (async - just sends SIGTERM)
lua5.4 "$D/luxctl.lua" -s "$TESTDIR/lux.sock" stop sleeper
sleep 2

# Verify stopped
OUT=$(lua5.4 "$D/luxctl.lua" -s "$TESTDIR/lux.sock" status)
echo "$OUT" | grep "sleeper" | grep -q "stopped"

# Start again
lua5.4 "$D/luxctl.lua" -s "$TESTDIR/lux.sock" start sleeper
sleep 1

# Verify running
OUT=$(lua5.4 "$D/luxctl.lua" -s "$TESTDIR/lux.sock" status)
echo "$OUT" | grep "sleeper" | grep -q "running"
