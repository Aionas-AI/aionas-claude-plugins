#!/usr/bin/env bash
# aionas-savings hook: unused-services-notice (SessionStart, NOT async). Owner: AIO-861.
# Prints the one-line notice of what unused-services.sh turned off since the
# last session (a SessionStart "systemMessage"), once. Prints nothing when
# there is nothing to say. Local files only: no network, never blocks.
. "$(dirname "$0")/../lib/aionas.sh" 2>/dev/null || { cat >/dev/null 2>&1; exit 0; }
. "$AIONAS_LIB/unused.sh" 2>/dev/null || { cat >/dev/null 2>&1; exit 0; }
cat >/dev/null 2>&1
aionas_unused_notice 2>/dev/null
exit 0
