#!/usr/bin/env bash
# aionas-savings hook: handoff-arm (Stop, asyncRewake). Owner: AIO-858.
# The entry hooks.json names; the work is in stop-handoff.sh (which exits 0
# at once under Cursor, AIO-1077).
exec bash "$(dirname "$0")/stop-handoff.sh"
