#!/usr/bin/env bash
# subagent_sonnet's fired/skipped counter (W25P-P4, AIO-898 item 7).
# The mod's agent.spawn hook runs `aionas-bypass.sh --subagent-start` once per
# sub-agent start; the script counts fired when the method is active for the
# session (the test effort-window.sh uses for effort_default), else skipped.
. "$(dirname "$0")/../lib/harness.sh"
BYPASS="$T_PLUGIN/commands/aionas-bypass.sh"
T0=1792490400 # 2026-10-20T10:00:00Z
Q() { echo "$(aionas_savings_dir)/counters/queue.tsv"; }
rows() { { grep -c "$(printf 'subagent_sonnet\t%s\t' "$1")" "$(Q)" 2>/dev/null || true; } | head -1; }
start() { AIONAS_SESSION_ID=s1 bash "$BYPASS" --subagent-start; }

test_start_with_the_method_on_counts_one_fired() {
  t_enroll; export AIONAS_NOW=$T0
  local out; out=$(start)
  t_eq 0 $? "exit 0"
  t_eq "" "$out" "silent"
  t_eq "$(printf '2026-10-20\tsubagent_sonnet\tfired\t1')" "$(cat "$(Q)")"
}

test_start_with_the_method_bypassed_counts_one_skipped() {
  t_enroll; export AIONAS_NOW=$T0
  aionas_override_local_add subagent_sonnet 3600
  t_eq "" "$(start)"
  t_eq "$(printf '2026-10-20\tsubagent_sonnet\tskipped\t1')" "$(cat "$(Q)")"
}

test_start_with_the_method_off_by_the_organization_counts_one_skipped() {
  t_enroll; export AIONAS_NOW=$T0
  aionas_mkdir "$(aionas_savings_dir)"
  printf 'V\t1\nM\tsubagent_sonnet\toff\t0\t0\t1\t0\n' >"$(aionas_savings_dir)/policy.cache"
  t_rc 0 start
  t_eq "$(printf '2026-10-20\tsubagent_sonnet\tskipped\t1')" "$(cat "$(Q)")"
}

test_two_starts_count_two_and_only_for_this_method() {
  t_enroll; export AIONAS_NOW=$T0
  start; start
  t_eq 2 "$(rows fired)"
  t_eq 0 "$(rows skipped)"
  t_eq 2 "$(wc -l <"$(Q)" | tr -d ' ')" "exactly one row per start, no other method"
}

test_the_state_change_between_starts_is_followed() {
  t_enroll; export AIONAS_NOW=$T0
  start
  aionas_override_local_add subagent_sonnet 3600
  start
  t_eq 1 "$(rows fired)"
  t_eq 1 "$(rows skipped)"
}

test_the_model_decision_itself_counts_nothing() {
  t_enroll; export AIONAS_NOW=$T0
  t_eq sonnet "$(bash "$BYPASS" --subagent-model '')"
  t_eq opus "$(AIONAS_SESSION_ID=s1 bash "$BYPASS" --subagent-model opus)"
  t_not test -e "$(Q)"
}

test_usage_probe_child_counts_nothing() {
  t_enroll; export AIONAS_NOW=$T0
  local out; out=$(AIONAS_USAGE_PROBE=1 AIONAS_SESSION_ID=s1 bash "$BYPASS" --subagent-start 2>&1)
  t_eq 0 $?
  t_eq "" "$out"
  t_not test -e "$(Q)"
  t_not test -d "$(aionas_savings_dir)/counters"
}

test_not_enrolled_counts_nothing() {
  t_unenroll; export AIONAS_NOW=$T0
  t_eq "" "$(start)"
  t_eq 0 $?
  t_not test -e "$(Q)"
}

test_the_next_flush_body_carries_the_row() {
  t_enroll; export AIONAS_NOW=$T0
  start; start
  aionas_override_local_add subagent_sonnet 3600
  start
  t_rc 0 aionas_counters_flush
  t_eq 1 "$(t_calls)"
  t_eq POST "$(t_call 1 method)"
  t_eq https://gw.example.test/enroll/v1/savings/counters "$(t_call 1 url)"
  t_eq '{"plugin_version":"0.5.0","counters":[{"day":"2026-10-20","method_id":"subagent_sonnet","counter":"fired","value":2},{"day":"2026-10-20","method_id":"subagent_sonnet","counter":"skipped","value":1}]}' "$(t_call 1 body)"
}

test_the_hook_list_has_no_new_entry_and_the_mod_is_the_only_caller() {
  # No new hook: the count rides the mod's existing agent.spawn handler.
  t_lacks "$(cat "$T_PLUGIN/hooks/hooks.json")" SubagentStart
  t_contains "$(cat "$T_PLUGIN/hooks/mod.tsx")" "--subagent-start"
}

t_main "$@"
