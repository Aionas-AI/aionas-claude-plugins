#!/usr/bin/env bash
# aionas-savings hook: handoff-arm (Stop, asyncRewake). Owner: AIO-858.
# The entry hooks.json names; the work is in stop-handoff.sh.
exec bash "$(dirname "$0")/stop-handoff.sh"
