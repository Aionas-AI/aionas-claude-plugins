#!/usr/bin/env bash
# aionas-savings hook: noisy-guard (PreToolUse Bash). Owner: AIO-860.
# The entry hooks.json registers; the guard itself is pretool-guard.sh.
exec bash "$(dirname "$0")/pretool-guard.sh"
