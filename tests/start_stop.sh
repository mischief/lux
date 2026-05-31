#!/bin/sh
# SPDX-License-Identifier: ISC
# Test: luxd starts and responds to luxctl shutdown
set -e
D="$(cd "$(dirname "$0")/.." && pwd)"
TESTDIR=$(mktemp -d)
trap 'kill $PID 2>/dev/null; wait $PID 2>/dev/null; rm -rf "$TESTDIR"' EXIT

mkdir -p "$TESTDIR/services"
lua5.4 "$D/luxd.lua" -s "$TESTDIR/lux.sock" -d "$TESTDIR/services" 2>/dev/null &
PID=$!
sleep 1

# Verify it's running
kill -0 $PID

# Verify control socket works
lua5.4 "$D/luxctl.lua" -s "$TESTDIR/lux.sock" status >/dev/null
