#!/usr/bin/env bash
# aionas-savings hook: counters-flush (Stop, async). Owner: AIO-855 (W24-4, W24-P2).
# 1. At most once an hour, refreshes the policy cache (aionas_policy_sync: one
#    try, 3 s connect, 5 s total, no retry), so the band's "me" and "saved
#    today" (policy.json) stay fresh in a long session (mod spec §5). Method
#    behaviour still follows the session's pin: a policy change applies from
#    the next session (W24-P2). Bypasses ended here early stay ended.
# 2. Sends the summed counters at most once an hour (same limits); a failed
#    batch waits for the next hourly send. Skipped this time when the policy
#    sync just found the gateway unreachable, so the hook stays within its
#    timeout. Numbers and closed names only.
# 3. Per-request records (AIO-1004): the Stop input carries this turn's
#    prompt_id, so the methods that acted during the turn (marked by the
#    other hooks and the mod) become one record each for that prompt, sent to
#    POST /enroll/v1/savings/requests at the end of every turn (a few seconds
#    at most; what could not be sent waits for the next turn). Ids, method
#    names, a time and token counts only.
# Prints nothing, exits 0.
set -u
. "$(dirname "$0")/../lib/aionas.sh" 2>/dev/null || exit 0
. "$AIONAS_PLUGIN_ROOT/commands/aionas-bypass-lib.sh" 2>/dev/null || exit 0
_start=$(aionas_now)
_in=$(cat 2>/dev/null) || _in=''
_flat=$(printf '%s' "$_in" | aionas_json_flatten 2>/dev/null)
_sid=$(printf '%s\n' "$_flat" | aionas_json_get session_id)
_pid=$(printf '%s\n' "$_flat" | aionas_json_get prompt_id)
aionas_request_settle "$_sid" "$_pid" >/dev/null 2>&1
if aionas_policy_sync_due; then
  aionas_policy_sync >/dev/null 2>&1
  rc=$?
  if [ $rc -eq 0 ]; then
    aionas_bypass_apply_ends >/dev/null 2>&1
  elif [ $rc -eq 1 ]; then
    exit 0
  fi
fi
aionas_requests_flush "$_start" >/dev/null 2>&1
aionas_counters_flush >/dev/null 2>&1
exit 0
