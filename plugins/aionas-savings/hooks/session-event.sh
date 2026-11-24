#!/usr/bin/env bash
# aionas-savings hook: session-event (SessionStart, async). Owner: AIO-925 (wave 27).
# Sends one session_start event to POST /enroll/v1/sessions/events: the
# session_id and the source (startup, resume, clear, compact or fork) from the
# hook input, the time and the plugin version. Nothing else from the input
# (model, working directory, transcript path) is read or sent.
# One try, no retry; prints nothing, exits 0. Runs async
# (hooks.json): it never delays the session.
set -u
. "$(dirname "$0")/../lib/aionas.sh" 2>/dev/null || exit 0
input=$(cat 2>/dev/null) || input=""
flat=$(printf '%s' "$input" | aionas_json_flatten 2>/dev/null) || exit 0
sid=$(printf '%s\n' "$flat" | aionas_json_get session_id 2>/dev/null) || sid=""
source=$(printf '%s\n' "$flat" | aionas_json_get source 2>/dev/null) || source=""
aionas_event_session_start "$sid" "$source" >/dev/null 2>&1
exit 0
