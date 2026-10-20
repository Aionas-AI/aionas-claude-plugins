#!/usr/bin/env bash
# aionas-savings hook: counters-flush (Stop, async). Owner: AIO-855 (W24-4, W24-P2).
# Sends the summed counters at most once an hour (3 s connect, 5 s total, no
# retry); a failed batch waits for the next hourly send. Numbers and closed
# names only. Prints nothing, exits 0.
set -u
. "$(dirname "$0")/../lib/aionas.sh" 2>/dev/null || exit 0
cat >/dev/null 2>&1 || true
aionas_counters_flush >/dev/null 2>&1
exit 0
