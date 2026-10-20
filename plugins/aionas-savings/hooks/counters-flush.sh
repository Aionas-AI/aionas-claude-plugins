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
# Prints nothing, exits 0.
set -u
. "$(dirname "$0")/../lib/aionas.sh" 2>/dev/null || exit 0
. "$AIONAS_PLUGIN_ROOT/commands/aionas-bypass-lib.sh" 2>/dev/null || exit 0
cat >/dev/null 2>&1 || true
if aionas_policy_sync_due; then
  aionas_policy_sync >/dev/null 2>&1
  rc=$?
  if [ $rc -eq 0 ]; then
    aionas_bypass_apply_ends >/dev/null 2>&1
  elif [ $rc -eq 1 ]; then
    exit 0
  fi
fi
aionas_counters_flush >/dev/null 2>&1
exit 0
