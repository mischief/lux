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

lua5.4 "$D/luxctl.lua" -s "$TMPDIR/lux.sock" shutdown
sleep 2

# luxd should have exited
! kill -0 $PID 2>/dev/null
