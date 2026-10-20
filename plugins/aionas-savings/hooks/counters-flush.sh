#!/usr/bin/env bash
# aionas-savings hook: counters-flush (Stop, async). Owner: AIO-855.
# Hourly counters send (no-op until an hour has passed since the last attempt).
# STUB (wave-24 skeleton): reads its input, prints nothing, changes nothing, exits 0.
# The owning lane replaces this body. Shared helpers: . "$(dirname "$0")/../lib/aionas.sh"
cat >/dev/null 2>&1 || true
exit 0
