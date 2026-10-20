#!/usr/bin/env bash
# aionas-savings hook: noisy-guard (PreToolUse Bash). Owner: AIO-860.
# Noisy-command guard: quiet forms of known noisy commands; caps for sed, grep and cat.
# STUB (wave-24 skeleton): reads its input, prints nothing, changes nothing, exits 0.
# The owning lane replaces this body. Shared helpers: . "$(dirname "$0")/../lib/aionas.sh"
cat >/dev/null 2>&1 || true
exit 0
