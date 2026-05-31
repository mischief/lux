#!/bin/sh
# SPDX-License-Identifier: ISC
D="$(cd "$(dirname "$0")/.." && pwd)"
TESTDIR="/tmp/lux-test-shutdown-$$"
rm -rf "$TESTDIR"
mkdir -p "$TESTDIR/services"
trap 'kill $PID 2>/dev/null; wait $PID 2>/dev/null; rm -rf "$TESTDIR"' EXIT

lua5.4 "$D/luxd.lua" -s "$TESTDIR/lux.sock" -d "$TESTDIR/services" 2>/dev/null &
PID=$!
sleep 1

kill -0 $PID || exit 1
test -S "$TESTDIR/lux.sock" || exit 1

lua5.4 "$D/luxctl.lua" -s "$TESTDIR/lux.sock" shutdown || exit 1

# Wait for luxd to exit
for i in 1 2 3 4 5; do
    kill -0 $PID 2>/dev/null || exit 0
    sleep 1
done
exit 1
