#!/bin/sh
# SPDX-License-Identifier: ISC
set -e
D="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'kill $PID 2>/dev/null; wait $PID 2>/dev/null; rm -rf "$TMPDIR"' EXIT

mkdir -p "$TMPDIR/services"
cat > "$TMPDIR/services/target.lua" << 'EOF'
service "setup" {
    cmd = { "true" },
}

service "ready" {
    depends = { "setup" },
}
EOF

lua5.4 "$D/luxd.lua" -s "$TMPDIR/lux.sock" -d "$TMPDIR/services" &
PID=$!
sleep 1

OUT=$(lua5.4 "$D/luxctl.lua" -s "$TMPDIR/lux.sock" status)
echo "$OUT" | grep "ready" | grep -q "running"
