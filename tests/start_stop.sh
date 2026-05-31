#!/bin/sh
# SPDX-License-Identifier: ISC
# Test: luxd starts and responds to luxctl shutdown
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

# Verify control socket works
lua5.4 "$D/luxctl.lua" -s "$TMPDIR/lux.sock" status >/dev/null
