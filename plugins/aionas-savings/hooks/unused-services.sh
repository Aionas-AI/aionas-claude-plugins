#!/usr/bin/env bash
# aionas-savings hook: unused-services (SessionStart, async). Owner: AIO-861.
# Turns off, in the person's own Claude Code settings, the MCP servers,
# connectors and skills with no calls in the policy's number of days (30), at
# the first session of each UTC day; every session it carries the switch into
# the current project and notices what the person turned back on. The change
# applies from the next session; unused-services-notice.sh tells the person.
# Never blocks, never prints, always exits 0. Method: unused_services.
. "$(dirname "$0")/../lib/aionas.sh" 2>/dev/null || { cat >/dev/null 2>&1; exit 0; }
. "$AIONAS_LIB/unused.sh" 2>/dev/null || { cat >/dev/null 2>&1; exit 0; }
input=$(cat 2>/dev/null)
flat=$(printf '%s' "$input" | aionas_json_flatten 2>/dev/null)
sid=$(printf '%s\n' "$flat" | aionas_json_get session_id 2>/dev/null)
cwd=$(printf '%s\n' "$flat" | aionas_json_get cwd 2>/dev/null | aionas_json_unescape)
aionas_unused_run "$sid" "$cwd" >/dev/null 2>&1
exit 0
