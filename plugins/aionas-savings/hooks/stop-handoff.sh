#!/usr/bin/env bash
# aionas-savings hook: stop-handoff (Stop, asyncRewake). Owner: AIO-858.
#
# After each turn: read the context size from the usage numbers of this turn's
# answer in the transcript (the Stop input has no size; the answer may land a
# moment after this hook starts, so it waits for it). At or above the threshold (policy param threshold_tokens, default
# 200000) with nothing running, this process stays alive as the idle timer.
# After idle_minutes (default 55) with no new prompt and no sub-agent activity
# it exits 2 with the handoff instruction: Claude Code wakes the SAME session
# with it. A new prompt (handoff-cancel.sh), a newer Stop (this script again)
# or a drop below the threshold ends the timer silently. Nothing is compacted.
#
# Reads only numbers from the transcript; never prints or sends content.
# Test seams: AIONAS_HANDOFF_IDLE_SECONDS, AIONAS_HANDOFF_POLL_SECONDS (default 20),
# AIONAS_HANDOFF_BUSY_SECONDS (a sub-agent written this recently is running; default 180),
# AIONAS_HANDOFF_SETTLE_SECONDS (longest wait for this turn's answer; default 15).
. "$(dirname "$0")/handoff-wake.sh"

_in=$(cat 2>/dev/null)
_flat=$(printf '%s' "$_in" | aionas_json_flatten 2>/dev/null)
_sid=$(printf '%s\n' "$_flat" | aionas_json_get session_id)
_aionas_sid_ok "$_sid" || exit 0
_tr=$(printf '%s\n' "$_flat" | aionas_json_get transcript_path)
_cwd=$(printf '%s\n' "$_flat" | aionas_json_get cwd)
_pid=$(printf '%s\n' "$_flat" | aionas_json_get prompt_id)
_aionas_sid_ok "$_pid" || _pid=''

# Policy: off or released -> nothing; bypassed on this computer -> count once.
if [ "$(aionas_policy_state handoff "$_sid")" != on ]; then
  aionas_handoff_disarm "$_sid" >/dev/null
  exit 0
fi
if aionas_policy_bypassed handoff "$_sid"; then
  aionas_handoff_disarm "$_sid" >/dev/null
  aionas_mkdir "$(aionas_handoff_dir)" && ( set -C; : >"$(aionas_handoff_dir)/$_sid.bypass" ) 2>/dev/null &&
    aionas_counter_inc handoff bypass >/dev/null 2>&1
  exit 0
fi

# One handoff per session.
[ -f "$(aionas_handoff_dir)/$_sid.done" ] && exit 0

_th=$(aionas_policy_param handoff threshold_tokens "$_sid" 2>/dev/null)
aionas_is_uint "$_th" && [ "$_th" -ge 1 ] || _th=$AIONAS_HANDOFF_DEFAULT_TOKENS
_idle=$(aionas_policy_param handoff idle_minutes "$_sid" 2>/dev/null)
aionas_is_uint "$_idle" && [ "$_idle" -ge 1 ] || _idle=$AIONAS_HANDOFF_DEFAULT_IDLE_MINUTES
_idle_s=$((_idle * 60))
if [ -n "${AIONAS_HANDOFF_IDLE_SECONDS:-}" ] && aionas_is_uint "$AIONAS_HANDOFF_IDLE_SECONDS" && [ "$AIONAS_HANDOFF_IDLE_SECONDS" -ge 1 ]; then
  _idle_s=$AIONAS_HANDOFF_IDLE_SECONDS
fi
[ "$_idle_s" -gt "$AIONAS_HANDOFF_MAX_IDLE_SECONDS" ] && _idle_s=$AIONAS_HANDOFF_MAX_IDLE_SECONDS
_poll=${AIONAS_HANDOFF_POLL_SECONDS:-20}
aionas_is_uint "$_poll" && [ "$_poll" -ge 1 ] || _poll=20
_busy=${AIONAS_HANDOFF_BUSY_SECONDS:-180}
aionas_is_uint "$_busy" || _busy=180
_settle=${AIONAS_HANDOFF_SETTLE_SECONDS:-15}
aionas_is_uint "$_settle" || _settle=15

# Context size of this turn's answer: below the threshold ends any older timer.
_tok=$(aionas_handoff_wait_tokens "$_tr" "$_pid" "$_settle") || { aionas_handoff_disarm "$_sid" >/dev/null; exit 0; }
if [ "$_tok" -lt "$_th" ]; then
  aionas_handoff_disarm "$_sid" >/dev/null
  exit 0
fi

# Anything still running (sub-agents, background tasks): no timer now. When it
# finishes, Claude Code runs a turn, and the Stop after it arms the timer.
_running=$(printf '%s\n' "$_flat" | awk -F '\t' '$1 ~ /^background_tasks\.[0-9]+\.status$/ && ($3 == "running" || $3 == "pending") { n++ } END { print n + 0 }')
if [ "$_running" -gt 0 ]; then
  aionas_handoff_disarm "$_sid" >/dev/null
  exit 0
fi

_token=$(aionas_handoff_arm "$_sid") || exit 0
aionas_handoff_status "$_sid" armed "$_tok"
_ppid=$PPID
_start=$(date +%s)
_deadline=$((_start + _idle_s))

while :; do
  aionas_handoff_still_armed "$_sid" "$_token" || exit 0
  # The session is gone when the process that started this hook is.
  kill -0 "$_ppid" 2>/dev/null || exit 0
  [ -z "$_tr" ] || [ -f "$_tr" ] || exit 0
  _now=$(date +%s)
  if [ "$_now" -ge "$_deadline" ] && ! aionas_handoff_subagents_busy "$_tr" "$_sid" "$_busy"; then
    aionas_handoff_deliver "$_sid" "$_cwd" "$_token" "$_tok" $(((_idle_s + 59) / 60))
    exit $?
  fi
  _s=$_poll
  _rem=$((_deadline - _now))
  [ "$_rem" -gt 0 ] && [ "$_rem" -lt "$_s" ] && _s=$_rem
  sleep "$_s"
done
