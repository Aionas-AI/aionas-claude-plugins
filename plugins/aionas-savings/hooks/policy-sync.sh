#!/usr/bin/env bash
# aionas-savings hook: policy-sync (SessionStart, async). Owner: AIO-855 (W24-P2).
# 1. Pins the cached policy to this session, so a policy change applies from
#    the next session only (the session that is starting keeps what it saw).
# 2. Fetches the next policy in one try: 3 s connect, 5 s in total, no retry.
#    A failure keeps the last good cache (or the all-on default when nothing
#    is cached) and the next session start tries again.
# 3. Only when the gateway answered: sends overrides queued while it could not
#    be reached (at most 3) and the hourly counters. So an unreachable gateway
#    costs this background hook at most 5 s, and never the session.
# Prints nothing, exits 0. Runs async (hooks.json): it never delays the session.
set -u
. "$(dirname "$0")/../lib/aionas.sh" 2>/dev/null || exit 0
. "$AIONAS_PLUGIN_ROOT/commands/aionas-bypass-lib.sh" 2>/dev/null || exit 0

input=$(cat 2>/dev/null) || input=""
sid=$(printf '%s' "$input" | aionas_json_flatten 2>/dev/null | aionas_json_get session_id 2>/dev/null) || sid=""
if [ -n "$sid" ]; then
  aionas_policy_pin "$sid" >/dev/null 2>&1
fi
aionas_policy_sync >/dev/null 2>&1
rc=$?
if [ $rc -eq 0 ]; then
  aionas_override_flush_pending 3 >/dev/null 2>&1
  aionas_counters_flush >/dev/null 2>&1
fi
exit 0
