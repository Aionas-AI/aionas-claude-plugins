#!/usr/bin/env bash
# Not enrolled (no alias from the one install): this public plugin changes
# nothing on the computer. Every method is off, required ones too, the band
# draws nothing, session start adds no context and no call leaves.
. "$(dirname "$0")/../lib/harness.sh"

start() { printf '{"session_id":"s1","source":"startup"}' | bash "$T_PLUGIN/hooks/$1.sh" 2>&1; }

test_every_method_is_off_and_nothing_is_active() {
  t_unenroll
  local m
  for m in $AIONAS_METHODS; do
    t_eq off "$(aionas_policy_state "$m" s1)" "$m"
    t_not aionas_policy_active "$m" s1
  done
}

test_band_draws_nothing() {
  t_unenroll
  t_eq "" "$(bash "$T_PLUGIN/commands/aionas-bypass.sh" --band)"
}

test_session_start_adds_nothing_and_sends_nothing() {
  t_unenroll
  local h
  for h in policy-sync daily-scan plan-report script-refresh usage-probe effort-window unused-services unused-services-notice write-minimum; do
    t_eq "" "$(start "$h")" "$h"
  done
  t_eq 0 "$(t_calls)"
}

test_subagents_keep_the_persons_own_model() {
  t_unenroll
  t_eq - "$(bash "$T_PLUGIN/commands/aionas-bypass.sh" --subagent-model "")"
  t_eq opus "$(bash "$T_PLUGIN/commands/aionas-bypass.sh" --subagent-model opus)"
}

test_enrolled_with_nothing_cached_is_still_all_on() {
  t_eq on "$(aionas_policy_state write_minimum s1)"
  t_eq sonnet "$(bash "$T_PLUGIN/commands/aionas-bypass.sh" --subagent-model "")"
}

t_main "$@"
