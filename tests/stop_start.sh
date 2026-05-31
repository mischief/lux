#!/bin/sh
# SPDX-License-Identifier: ISC
set -e
D="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'kill $PID 2>/dev/null; wait $PID 2>/dev/null; rm -rf "$TMPDIR"' EXIT

mkdir -p "$TMPDIR/services"
cat > "$TMPDIR/services/sleeper.lua" << 'EOF'
service "sleeper" {
    cmd = { "sleep", "300" },
    restart = true,
}
EOF

lua5.4 "$D/luxd.lua" -s "$TMPDIR/lux.sock" -d "$TMPDIR/services" 2>/dev/null &
PID=$!
sleep 1

# Stop (async - just sends SIGTERM)
lua5.4 "$D/luxctl.lua" -s "$TMPDIR/lux.sock" stop sleeper
sleep 2

# Verify stopped
OUT=$(lua5.4 "$D/luxctl.lua" -s "$TMPDIR/lux.sock" status)
echo "$OUT" | grep "sleeper" | grep -q "stopped"

# Start again
lua5.4 "$D/luxctl.lua" -s "$TMPDIR/lux.sock" start sleeper
sleep 1

# Verify running
OUT=$(lua5.4 "$D/luxctl.lua" -s "$TMPDIR/lux.sock" status)
echo "$OUT" | grep "sleeper" | grep -q "running"
