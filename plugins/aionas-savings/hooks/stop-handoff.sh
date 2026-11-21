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
#
# The wait is off the turn's critical path in Claude Code only: Claude Code
# runs this entry with asyncRewake (hooks.json), so the turn ends at once and
# this process waits in the background. Cursor ignores async/asyncRewake and
# holds the end of its turn until the hook exits, and its transcript never
# holds Claude Code's usage numbers, so the wait always ran its full 15 s
# there (Cursor hooks log, 2026-11-19). Under Cursor this hook exits 0 at once,
# before any wait (AIO-1077).
#
# Cursor branch (AIO-1079, wave 33): no timer, no wait, no sleep. At the end of
# the turn that crosses the policy threshold, the hook answers on stdout with
# {"followup_message": "<the handoff instruction>"}, the one output Cursor's
# stop hook honors (it sends that text as the next message of the same
# conversation; Cursor's hooks reference, "stop": output followup_message,
# input status / loop_count / input_tokens / cache_read_tokens). Once per
# conversation (the .done marker), only for status completed and loop_count 0
# (the follow-up's own stop has loop_count 1). Size: numbers of the stop payload
# only, no transcript is opened. The offer has its own wording
# (aionas_cursor_handoff_instruction, W33-10): Cursor has no aionas band, no
# launcher and no "claude --resume", so it names only what the person can do
# in Cursor: a new chat with the starting prompt; the old one stays in the
# chat history.
. "$(dirname "$0")/handoff-wake.sh"

# aionas_cursor_handoff_instruction SID TOKENS: the follow-up text for Cursor.
# Same handoff document path as Claude Code's (handoff-<sid>.md, the person's
# own local file); no launcher is written.
aionas_cursor_handoff_instruction() {
  local md
  md="$(aionas_handoff_dir)/handoff-$1.md"
  cat <<MSG
[aionas-handoff] This conversation is about $(($2 / 1000))K tokens long, and every new message in it sends all of that again. Do this now, and nothing else:
1. Write a handoff document for a fresh chat to $md (replace that file if it exists: an earlier doc of this chat is out of date). Start it with the line "Previous conversation: $1 (it stays in Cursor's chat history)". Cover: the goal; what is done; what is left, in order; decisions and why; the files and commands that matter; how to check the work; open questions. Leave out secrets and credentials.
2. Print a short starting prompt for the new chat (two or three sentences that point at that file).
3. Tell the developer, in one sentence, what they can do now in Cursor: open a new chat (the + / New Chat button of the chat panel) and paste that starting prompt; this chat stays in the history.
Do not run any command for this and do not change any setting. When these are done, say the handoff is ready and stop.
MSG
}

# aionas_cursor_stop PAYLOAD: the Cursor branch. Prints the follow-up JSON or nothing.
aionas_cursor_stop() {
  local flat sid status loop tok th msg
  flat=$(printf '%s' "$1" | aionas_json_flatten 2>/dev/null)
  sid=$(printf '%s\n' "$flat" | aionas_json_get session_id)
  _aionas_sid_ok "$sid" || sid=$(printf '%s\n' "$flat" | aionas_json_get conversation_id)
  _aionas_sid_ok "$sid" || return 0
  # Policy first: off or released -> nothing; bypassed here -> count once.
  [ "$(aionas_policy_state handoff "$sid")" = on ] || return 0
  if aionas_policy_bypassed handoff "$sid"; then
    aionas_mkdir "$(aionas_handoff_dir)" && ( set -C; : >"$(aionas_handoff_dir)/$sid.bypass" ) 2>/dev/null &&
      aionas_counter_inc handoff bypass >/dev/null 2>&1
    return 0
  fi
  # Only a finished first-level stop (not aborted or errored, not the follow-up's own stop).
  status=$(printf '%s\n' "$flat" | aionas_json_get status)
  loop=$(printf '%s\n' "$flat" | aionas_json_get loop_count)
  [ "$status" = completed ] || return 0
  [ "$loop" = 0 ] || return 0
  # One handoff per conversation.
  [ -f "$(aionas_handoff_dir)/$sid.done" ] && return 0
  tok=$(aionas_cursor_context_tokens "$flat") || return 0
  th=$(aionas_policy_param handoff threshold_tokens "$sid" 2>/dev/null)
  aionas_is_uint "$th" && [ "$th" -ge 1 ] || th=$AIONAS_HANDOFF_DEFAULT_TOKENS
  [ "$tok" -ge "$th" ] || return 0
  aionas_mkdir "$(aionas_handoff_dir)" || return 0
  # Whoever creates the marker wins: exactly one offer.
  ( set -C; : >"$(aionas_handoff_dir)/$sid.done" ) 2>/dev/null || return 0
  if ! msg=$(aionas_cursor_handoff_instruction "$sid" "$tok"); then
    rm -f "$(aionas_handoff_dir)/$sid.done"
    return 0
  fi
  aionas_counter_inc handoff fired >/dev/null 2>&1
  printf '{"followup_message":%s}\n' "$(aionas_json_escape "$msg")"
}

# aionas_cursor_context_tokens FLAT: the conversation size from numbers only:
# context_tokens when the payload has it (preCompact's name), else
# input_tokens + cache_read_tokens. Exit 1 with no number.
aionas_cursor_context_tokens() {
  local c i r
  c=$(printf '%s\n' "$1" | aionas_json_get context_tokens)
  if aionas_is_uint "$c" && [ "$c" -gt 0 ]; then echo "$c"; return 0; fi
  i=$(printf '%s\n' "$1" | aionas_json_get input_tokens)
  r=$(printf '%s\n' "$1" | aionas_json_get cache_read_tokens)
  aionas_is_uint "$i" || return 1
  aionas_is_uint "$r" || r=0
  echo $((i + r))
}

if [ "$(aionas_client)" = cursor ]; then
  aionas_cursor_stop "${AIONAS_HOOK_INPUT:-}"
  exit 0
fi

_in=$(cat 2>/dev/null)
_flat=$(printf '%s' "$_in" | aionas_json_flatten 2>/dev/null)
_sid=$(printf '%s\n' "$_flat" | aionas_json_get session_id)
_aionas_sid_ok "$_sid" || exit 0
# The two paths with their JSON escapes decoded (AIO-1072, finding 10).
_tr=$(printf '%s\n' "$_flat" | aionas_json_get_str transcript_path)
_cwd=$(printf '%s\n' "$_flat" | aionas_json_get_str cwd)
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

# One live handoff per session (a prompt after its doc turn passes it over,
# and the next idle asks again). After it, each turn's end moves the time the
# session's prompt cache goes cold (the band counts down to it) and marks the
# doc turn as ended.
if [ -f "$(aionas_handoff_dir)/$_sid.done" ]; then
  if [ "$(aionas_handoff_state_field "$_sid" 1)" = delivered ]; then
    aionas_handoff_status "$_sid" delivered "$(aionas_handoff_state_field "$_sid" 3)" $(($(aionas_now) + $(aionas_handoff_cache_ttl "$_tr"))) 1
  fi
  exit 0
fi

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
_ppid=$PPID
_start=$(date +%s)
_deadline=$((_start + _idle_s))
aionas_handoff_status "$_sid" armed "$_tok" "$_deadline"

while :; do
  aionas_handoff_still_armed "$_sid" "$_token" || exit 0
  # The session is gone when the process that started this hook is.
  kill -0 "$_ppid" 2>/dev/null || exit 0
  [ -z "$_tr" ] || [ -f "$_tr" ] || exit 0
  _now=$(date +%s)
  if [ "$_now" -ge "$_deadline" ] && ! aionas_handoff_subagents_busy "$_tr" "$_sid" "$_busy"; then
    aionas_handoff_deliver "$_sid" "$_cwd" "$_token" "$_tok" $(((_idle_s + 59) / 60)) "$(aionas_handoff_cache_ttl "$_tr")" "$_pid"
    exit $?
  fi
  _s=$_poll
  _rem=$((_deadline - _now))
  [ "$_rem" -gt 0 ] && [ "$_rem" -lt "$_s" ] && _s=$_rem
  sleep "$_s"
done
