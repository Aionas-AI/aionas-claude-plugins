#!/usr/bin/env bash
# commands/aionas-bypass.sh and commands/aionas-xhigh.sh (AIO-855, AIO-859; W24-1, W24-3, W24-4).
. "$(dirname "$0")/../lib/harness.sh"
BYPASS="$T_PLUGIN/commands/aionas-bypass.sh"
XHIGH="$T_PLUGIN/commands/aionas-xhigh.sh"
T0=1792490400 # 2026-10-20T10:00:00Z

answer() { # STATUS JSON_STATUS ID -> fake gateway answer
  local f; f=$(mktemp "$T_ROOT/ans.XXXXXX")
  printf '{"id":"%s","user_id":"u1","method_id":"x","status":"%s"}' "$3" "$2" >"$f"
  export FAKE_CURL_STATUS=$1 FAKE_CURL_BODY=$f
}
blocked_policy() { # cache a policy where self-override is blocked for METHOD
  aionas_mkdir "$(aionas_savings_dir)"
  printf 'V\t1\nM\t%s\ton\t0\t0\t1\t0\n' "$1" >"$(aionas_savings_dir)/policy.cache"
}

test_bypass_self_with_reason_is_stored_and_local() {
  t_enroll; export AIONAS_NOW=$T0; answer 201 self ovr_a
  local out; out=$(bash "$BYPASS" output_trim 1h debugging a flaky test)
  t_eq 0 $?
  t_eq 1 "$(t_calls)"
  t_eq POST "$(t_call 1 method)"
  t_eq https://gw.example.test/enroll/v1/savings/overrides "$(t_call 1 url)"
  t_eq '{"method_id":"output_trim","duration_seconds":3600,"reason":"debugging a flaky test"}' "$(t_call 1 body)"
  t_contains "$out" "output_trim is off for you for 1 hour"
  t_contains "$out" "Reason: debugging a flaky test."
  t_not aionas_policy_active output_trim
  t_ok aionas_policy_bypassed output_trim
  t_contains "$(cat "$(aionas_savings_dir)/counters/queue.tsv")" "$(printf 'output_trim\tbypass\t1')"
}

test_bypass_without_reason_sends_no_reason_and_alias_maps() {
  t_enroll; answer 201 self ovr_b
  local out; out=$(bash "$BYPASS" long_output_store 1h)
  t_eq '{"method_id":"output_trim","duration_seconds":3600}' "$(t_call 1 body)"
  t_lacks "$out" Reason
  t_ok aionas_policy_bypassed output_trim
  # The two ids output_trim replaced (AIO-883) are aliases of it.
  . "$T_PLUGIN/commands/aionas-bypass-lib.sh"
  t_eq output_trim "$(aionas_cmd_method noisy_guard)"
  t_eq output_trim "$(aionas_cmd_method output_store)"
  t_eq output_trim "$(aionas_cmd_method trim)"
}

test_bypass_blocked_prints_sent_for_approval_and_changes_nothing() {
  t_enroll; blocked_policy output_trim; answer 202 requested ovr_c
  local out; out=$(bash "$BYPASS" output_trim 2h why not)
  t_eq 0 $?
  t_contains "$out" "sent for approval"
  t_eq '{"method_id":"output_trim","duration_seconds":7200,"reason":"why not"}' "$(t_call 1 body)"
  t_not test -f "$(aionas_savings_dir)/local-overrides.tsv"
}

test_bypass_required_method_is_refused_without_a_call() {
  t_enroll
  local out; out=$(bash "$BYPASS" cache_guard 1h)
  t_eq 1 $?
  t_contains "$out" "cannot be bypassed"
  t_eq 0 "$(t_calls)"
}

test_bypass_unknown_method_and_usage() {
  t_enroll
  t_rc 2 bash "$BYPASS" nonsense >/dev/null
  t_rc 2 bash "$BYPASS" >/dev/null
  t_eq 0 "$(t_calls)"
}

test_bypass_durations() {
  . "$T_PLUGIN/commands/aionas-bypass-lib.sh"
  t_eq 1800 "$(aionas_cmd_duration 30m)"
  t_eq 1800 "$(aionas_cmd_duration 30)"
  t_eq 7200 "$(aionas_cmd_duration 2h)"
  t_eq 172800 "$(aionas_cmd_duration 2d)"
  t_eq 90 "$(aionas_cmd_duration 90s)"
  t_not aionas_cmd_duration 31d
  t_not aionas_cmd_duration flaky
  t_not aionas_cmd_duration 0m
}

test_reason_is_trimmed_escaped_and_capped_at_280_on_a_char_boundary() {
  . "$T_PLUGIN/commands/aionas-bypass-lib.sh"
  t_eq 'a "b" \c' "$(aionas_cmd_reason '  a "b" \c  ')"
  local long; long=$(printf 'é%.0s' $(seq 1 200)) # 400 bytes
  local cut; cut=$(aionas_cmd_reason "$long")
  t_eq 280 "$(printf '%s' "$cut" | LC_ALL=C wc -c | tr -d ' ')"
  t_eq 140 "$(printf '%s' "$cut" | awk '{ print gsub(/é/, "") }')"
  long="x$(printf 'é%.0s' $(seq 1 200))"
  cut=$(aionas_cmd_reason "$long")
  t_eq 279 "$(printf '%s' "$cut" | LC_ALL=C wc -c | tr -d ' ')" "a split character was kept"
  t_eq '{"method_id":"handoff","duration_seconds":60,"reason":"say \"hi\""}' "$(aionas_override_body handoff 60 'say "hi"')"
}

test_bypass_offline_allowed_bypasses_now_and_queues_then_sends_at_next_start() {
  t_enroll; export FAKE_CURL_EXIT=28
  local out; out=$(bash "$BYPASS" handoff 30m stuck)
  t_eq 0 $?
  t_contains "$out" "handoff is off for you for 30 minutes"
  t_contains "$out" "recorded at your next session start"
  t_ok aionas_policy_bypassed handoff
  t_eq 1 "$(ls "$(aionas_savings_dir)/pending-overrides" | grep -c json)"
  unset FAKE_CURL_EXIT; answer 201 self ovr_q
  . "$T_PLUGIN/commands/aionas-bypass-lib.sh"
  t_ok aionas_override_flush_pending
  t_eq '{"method_id":"handoff","duration_seconds":1800,"reason":"stuck"}' "$(t_call 2 body)"
  t_eq 0 "$(ls "$(aionas_savings_dir)/pending-overrides" | grep -c json)"
}

test_bypass_offline_blocked_queues_the_request() {
  t_enroll; blocked_policy handoff; export FAKE_CURL_EXIT=7
  local out; out=$(bash "$BYPASS" handoff)
  t_contains "$out" "sent for approval at your next session start"
  t_not aionas_policy_bypassed handoff
}

test_bypass_not_enrolled_is_local_only_without_network() {
  local out; out=$(bash "$BYPASS" handoff 1h)
  t_eq 0 $?
  t_contains "$out" "not enrolled"
  t_eq 0 "$(t_calls)"
  t_ok aionas_policy_bypassed handoff
}

test_bypass_400_changes_nothing() {
  t_enroll; answer 400 - -
  local out; out=$(bash "$BYPASS" handoff 1h)
  t_eq 1 $?
  t_contains "$out" "refused"
  t_not test -f "$(aionas_savings_dir)/local-overrides.tsv"
}

test_list_rows_for_the_band() {
  t_enroll
  local out; out=$(bash "$BYPASS" --list)
  t_contains "$out" "$(printf 'output_trim\toff\t0\t1')" "off by default (AIO-883)"
  t_contains "$out" "$(printf 'compact_at\t200000')"
  t_lacks "$out" cache_guard
  blocked_policy output_trim
  out=$(bash "$BYPASS" --list)
  t_contains "$out" "$(printf 'output_trim\ton\t1\t0')"
}

test_count_entrypoint_takes_closed_names_only() {
  t_rc 0 bash "$BYPASS" --count write_minimum fired
  t_rc 2 bash "$BYPASS" --count write_minimum prompt_text
  t_eq 1 "$(wc -l <"$(aionas_savings_dir)/counters/queue.tsv" | tr -d ' ')"
}

test_xhigh_self_opens_a_10_minute_window_with_reason() {
  t_enroll; export AIONAS_NOW=$T0; answer 201 self ovr_x
  local out; out=$(bash "$XHIGH" big refactor)
  t_eq 0 $?
  t_contains "$out" "Higher effort is allowed for 10 minutes: sessions you open now start at their usual level, and you may raise them to xhigh (Extra) or max with /effort."
  t_contains "$out" "This session stays as it is."
  t_lacks "$out" "start at xhigh"
  t_eq '{"method_id":"effort_default","duration_seconds":600,"params":{"effort":"xhigh"},"reason":"big refactor"}' "$(t_call 1 body)"
  t_eq "$(printf '%s\t%s\txhigh\tself\tovr_x' $T0 $((T0 + 600)))" "$(cat "$(aionas_savings_dir)/effort-window")"
}

test_xhigh_max_without_reason() {
  t_enroll; answer 201 self ovr_m
  local out; out=$(bash "$XHIGH" max)
  t_contains "$out" "you may raise them to xhigh (Extra) or max with /effort"
  t_lacks "$out" "start at max"
  t_eq '{"method_id":"effort_default","duration_seconds":600,"params":{"effort":"max"}}' "$(t_call 1 body)"
}

test_xhigh_blocked_is_sent_for_approval_and_opens_no_window() {
  t_enroll; blocked_policy effort_default; answer 202 requested ovr_r
  local out; out=$(bash "$XHIGH" max please)
  t_contains "$out" "sent for approval"
  t_contains "$out" "New sessions stay capped at high"
  t_not test -f "$(aionas_savings_dir)/effort-window"
  t_contains "$(cat "$(aionas_savings_dir)/effort-requests.tsv")" "$(printf 'ovr_r\tmax')"
}

test_xhigh_never_touches_claude_settings() {
  t_enroll; answer 201 self ovr_s
  mkdir -p "$HOME/.claude"
  printf '{"effortLevel":"high","maxEffortLevel":"high"}\n' >"$HOME/.claude/settings.json"
  bash "$XHIGH" max >/dev/null
  t_eq '{"effortLevel":"high","maxEffortLevel":"high"}' "$(cat "$HOME/.claude/settings.json")"
}

test_bodies_carry_no_content_beyond_the_typed_reason() {
  t_enroll; answer 201 self ovr_p
  bash "$BYPASS" output_trim 1h a reason >/dev/null
  bash "$XHIGH" >/dev/null
  local b
  b=$(t_call 1 body; t_call 2 body)
  t_lacks "$b" "$HOME"
  t_lacks "$b" "$T_ALIAS"
  t_lacks "$(t_call 1 args; t_call 2 args)" "$T_ALIAS"
}

# subagent_sonnet: the sub-agent model the mod sets before each sub-agent.
install_marker() { # the one install's record that it wrote MODEL
  mkdir -p "$HOME/.aionas/agent/state/backup"
  printf '{"version":1,"keys":{"env.CLAUDE_CODE_SUBAGENT_MODEL":{"ours":"%s"}},"parents":["env"]}' "$1" >"$HOME/.aionas/agent/state/backup/cc-savings.ours"
}

test_subagent_model_on_off_and_back() {
  t_eq sonnet "$(bash "$BYPASS" --subagent-model '')"
  bash "$BYPASS" subagent_sonnet 1h >/dev/null
  t_eq - "$(bash "$BYPASS" --subagent-model '')" "bypassed: back to the default"
  bash "$BYPASS" --end subagent_sonnet >/dev/null
  t_eq sonnet "$(bash "$BYPASS" --subagent-model '')"
  aionas_mkdir "$(aionas_savings_dir)"
  printf 'V\t1\nM\tsubagent_sonnet\toff\t0\t0\t1\t0\n' >"$(aionas_savings_dir)/policy.cache"
  t_eq - "$(bash "$BYPASS" --subagent-model '')" "off by the org: the default"
}

test_subagent_model_keeps_the_persons_own_value() {
  t_eq opus "$(bash "$BYPASS" --subagent-model opus)"
  bash "$BYPASS" subagent_sonnet 1h >/dev/null
  t_eq opus "$(bash "$BYPASS" --subagent-model opus)"
  # Sonnet the person set (no install marker for it) is theirs too.
  t_eq sonnet "$(bash "$BYPASS" --subagent-model sonnet)"
  install_marker haiku
  t_eq sonnet "$(bash "$BYPASS" --subagent-model sonnet)"
}

test_subagent_model_takes_off_the_install_written_value() {
  install_marker sonnet
  t_eq sonnet "$(bash "$BYPASS" --subagent-model sonnet)"
  bash "$BYPASS" subagent_sonnet 1h >/dev/null
  t_eq - "$(bash "$BYPASS" --subagent-model sonnet)" "the install's Sonnet comes off"
}

t_main "$@"
