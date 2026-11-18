#!/usr/bin/env bash
# subagent_sonnet's fired/skipped counter (W25P-P4, AIO-898 item 7, AIO-1073).
# After a sub-agent start that could take the method (no model of its own, no
# fork, parent not on Sonnet) the mod runs `aionas-bypass.sh --subagent-start
# moved|kept`; the script counts fired (and marks the prompt) when the policy
# moved it and the method is active, skipped when the method is not active.
. "$(dirname "$0")/../lib/harness.sh"
BYPASS="$T_PLUGIN/commands/aionas-bypass.sh"
T0=1792490400 # 2026-10-20T10:00:00Z
# Every counter row queued so far.
Q() { cat "$(aionas_savings_dir)"/counters/spool/*.ev 2>/dev/null; }
rows() { Q | grep -c "$(printf 'subagent_sonnet\t%s\t' "$1")"; }
start() { AIONAS_SESSION_ID=s1 bash "$BYPASS" --subagent-start "${1:-moved}"; }
marks() { cat "$(aionas_savings_dir)"/requests/spool/*.ev 2>/dev/null | awk 'END { print NR }'; }

test_start_with_the_method_on_counts_one_fired() {
  t_enroll; export AIONAS_NOW=$T0
  local out; out=$(start)
  t_eq 0 $? "exit 0"
  t_eq "" "$out" "silent"
  t_eq "$(printf '2026-10-20\tsubagent_sonnet\tfired\t1')" "$(Q)"
}

# AIO-1073: an agent the policy did not move (an explicit model, a parent on
# Sonnet: the mod passes "kept" or runs nothing) is no fired count and no
# record; one it moved is exactly one of each.
test_only_a_start_the_policy_moved_counts_fired_and_marks_the_prompt() {
  t_enroll; export AIONAS_NOW=$T0
  printf '{"session_id":"s1","prompt_id":"p1","hook_event_name":"UserPromptSubmit","prompt":"x"}' | bash "$T_PLUGIN/hooks/request-prompt.sh"
  start kept
  AIONAS_SESSION_ID=s1 bash "$BYPASS" --subagent-start
  t_eq "" "$(Q)" "kept or no outcome: nothing counted"
  t_eq 0 "$(marks)"
  start moved
  t_eq 1 "$(rows fired)"
  t_eq 1 "$(marks)"
  t_contains "$(cat "$(aionas_savings_dir)"/requests/spool/*.ev)" "$(printf 's1\tp1\tsubagent_sonnet\t')"
}

test_start_with_the_method_bypassed_counts_one_skipped() {
  t_enroll; export AIONAS_NOW=$T0
  aionas_override_local_add subagent_sonnet 3600
  t_eq "" "$(start kept)"
  t_eq "$(printf '2026-10-20\tsubagent_sonnet\tskipped\t1')" "$(Q)"
  t_eq 0 "$(marks)"
}

test_start_with_the_method_off_by_the_organization_counts_one_skipped() {
  t_enroll; export AIONAS_NOW=$T0
  aionas_mkdir "$(aionas_savings_dir)"
  printf 'V\t1\nM\tsubagent_sonnet\toff\t0\t0\t1\t0\n' >"$(aionas_savings_dir)/policy.cache"
  t_rc 0 start kept
  t_eq "$(printf '2026-10-20\tsubagent_sonnet\tskipped\t1')" "$(Q)"
}

test_two_starts_count_two_and_only_for_this_method() {
  t_enroll; export AIONAS_NOW=$T0
  start; start
  t_eq 2 "$(rows fired)"
  t_eq 0 "$(rows skipped)"
  t_eq 2 "$(Q | wc -l | tr -d ' ')" "exactly one row per start, no other method"
}

test_the_state_change_between_starts_is_followed() {
  t_enroll; export AIONAS_NOW=$T0
  start
  aionas_override_local_add subagent_sonnet 3600
  start kept
  t_eq 1 "$(rows fired)"
  t_eq 1 "$(rows skipped)"
}

test_the_model_decision_itself_counts_nothing() {
  t_enroll; export AIONAS_NOW=$T0
  t_eq sonnet "$(bash "$BYPASS" --subagent-model '')"
  t_eq opus "$(AIONAS_SESSION_ID=s1 bash "$BYPASS" --subagent-model opus)"
  t_eq "" "$(Q)"
}

test_usage_probe_child_counts_nothing() {
  t_enroll; export AIONAS_NOW=$T0
  local out; out=$(AIONAS_USAGE_PROBE=1 AIONAS_SESSION_ID=s1 bash "$BYPASS" --subagent-start 2>&1)
  t_eq 0 $?
  t_eq "" "$out"
  t_not test -d "$(aionas_savings_dir)/counters"
}

test_not_enrolled_counts_nothing() {
  t_unenroll; export AIONAS_NOW=$T0
  t_eq "" "$(start)"
  t_eq 0 $?
  t_eq "" "$(Q)"
}

test_the_next_flush_body_carries_the_row() {
  t_enroll; export AIONAS_NOW=$T0
  start; start
  aionas_override_local_add subagent_sonnet 3600
  start kept
  t_rc 0 aionas_counters_flush
  t_eq 1 "$(t_calls)"
  t_eq POST "$(t_call 1 method)"
  t_eq https://gw.example.test/enroll/v1/savings/counters "$(t_call 1 url)"
  t_eq '{"plugin_version":"0.6.1","counters":[{"day":"2026-10-20","method_id":"subagent_sonnet","counter":"fired","value":2},{"day":"2026-10-20","method_id":"subagent_sonnet","counter":"skipped","value":1}]}' "$(t_call 1 body)"
}

test_the_hook_list_has_no_new_entry_and_the_mod_is_the_only_caller() {
  # No new hook: the count rides the mod's existing agent.spawn handler.
  t_lacks "$(cat "$T_PLUGIN/hooks/hooks.json")" SubagentStart
  t_contains "$(cat "$T_PLUGIN/hooks/mod.tsx")" "--subagent-start"
}

t_main "$@"
