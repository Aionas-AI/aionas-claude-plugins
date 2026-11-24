#!/usr/bin/env bash
# aionas-savings hook: precompact-event (PreCompact, async). Owner: AIO-925 (wave 27).
# Sends one pre_compact event to POST /enroll/v1/sessions/events: the
# session_id and the trigger (manual or auto) from the hook input, the time and
# the plugin version. custom_instructions (what the person typed after
# /compact) is never read, stored or sent. Never blocks a compaction.
# One try, no retry; prints nothing, exits 0.
set -u
. "$(dirname "$0")/../lib/aionas.sh" 2>/dev/null || exit 0
input=$(cat 2>/dev/null) || input=""
flat=$(printf '%s' "$input" | aionas_json_flatten 2>/dev/null) || exit 0
sid=$(printf '%s\n' "$flat" | aionas_json_get session_id 2>/dev/null) || sid=""
trigger=$(printf '%s\n' "$flat" | aionas_json_get trigger 2>/dev/null) || trigger=""
aionas_event_pre_compact "$sid" "$trigger" >/dev/null 2>&1
exit 0
