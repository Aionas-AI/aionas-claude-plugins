#!/usr/bin/env bash
# lib/requests.sh and the Stop hook: one record per prompt per method that
# acted, to POST /enroll/v1/savings/requests (AIO-1004, wave 31). Ids, method
# names, a time, the plugin version and token counts only; nothing else.
. "$(dirname "$0")/../lib/harness.sh"
T0=1792490400 # 2026-10-20T10:00:00Z
STOPHOOK="$T_PLUGIN/hooks/counters-flush.sh"
BYPASS="$T_PLUGIN/commands/aionas-bypass.sh"
RD() { echo "$(aionas_savings_dir)/requests"; }
# The hook's own Stop input (what Claude Code sends).
stop_in() { printf '{"session_id":"%s","prompt_id":"%s","transcript_path":"/x/y.jsonl","cwd":"/x","hook_event_name":"Stop","stop_hook_active":false}' "$1" "$2"; }
# Every request to the gateway carrying a record, as one body per line.
bodies() { local i n; n=$(t_calls); for i in $(seq 1 "$n"); do case "$(t_call "$i" url)" in */savings/requests) t_call "$i" body ;; esac; done; }

test_a_mark_settled_by_the_stop_is_one_exact_post() {
  t_enroll; export AIONAS_NOW=$T0
  aionas_request_mark sess-1 subagent_sonnet
  aionas_request_mark sess-1 subagent_sonnet
  t_rc 0 aionas_request_settle sess-1 prompt-9
  t_rc 0 aionas_requests_flush
  t_eq 1 "$(t_calls)" "two sub-agent starts of one prompt are one record"
  t_eq POST "$(t_call 1 method)"
  t_eq https://gw.example.test/enroll/v1/savings/requests "$(t_call 1 url)"
  t_contains "$(t_call 1 headers)" "Authorization: Bearer $T_ALIAS"
  t_eq '{"session_id":"sess-1","prompt_id":"prompt-9","method":"subagent_sonnet","ts":"2026-10-20T10:00:00Z","plugin_version":"0.6.0"}' "$(t_call 1 body)"
  t_not test -s "$(RD)/queue.tsv"
}

test_tokens_are_summed_per_method_and_each_method_is_its_own_post() {
  t_enroll; export AIONAS_NOW=$T0
  aionas_request_mark sess-1 output_trim "" 1200
  aionas_request_mark sess-1 output_trim "" 300
  aionas_request_mark sess-1 subagent_sonnet
  aionas_request_settle sess-1 p1
  t_rc 0 aionas_requests_flush
  t_eq 2 "$(t_calls)"
  t_eq '{"session_id":"sess-1","prompt_id":"p1","method":"output_trim","ts":"2026-10-20T10:00:00Z","plugin_version":"0.6.0","tokens":1500}' "$(bodies | sed -n 1p)"
  t_eq '{"session_id":"sess-1","prompt_id":"p1","method":"subagent_sonnet","ts":"2026-10-20T10:00:00Z","plugin_version":"0.6.0"}' "$(bodies | sed -n 2p)"
}

test_a_handoff_mark_with_its_prompt_goes_straight_to_the_queue() {
  t_enroll; export AIONAS_NOW=$T0
  aionas_request_mark sess-1 handoff p7 210000
  t_rc 0 aionas_requests_flush
  t_eq '{"session_id":"sess-1","prompt_id":"p7","method":"handoff","ts":"2026-10-20T10:00:00Z","plugin_version":"0.6.0","tokens":210000}' "$(bodies)"
}

test_two_prompts_are_two_records() {
  t_enroll; export AIONAS_NOW=$T0
  aionas_request_mark sess-1 subagent_sonnet; aionas_request_settle sess-1 p1
  aionas_request_mark sess-1 subagent_sonnet; aionas_request_settle sess-1 p2
  t_rc 0 aionas_requests_flush
  t_contains "$(bodies | sed -n 1p)" '"prompt_id":"p1"'
  t_contains "$(bodies | sed -n 2p)" '"prompt_id":"p2"'
}

test_a_computer_that_is_not_enrolled_queues_and_sends_nothing() {
  t_unenroll; export AIONAS_NOW=$T0
  t_rc 0 aionas_request_mark sess-1 subagent_sonnet
  t_not test -e "$(RD)/open.sess-1"
  t_rc 0 aionas_requests_flush
  t_eq 0 "$(t_calls)"
}

test_marks_outside_the_closed_lists_are_refused() {
  t_enroll; export AIONAS_NOW=$T0
  t_rc 2 aionas_request_mark sess-1 seat_fit
  t_rc 2 aionas_request_mark sess-1 write_minimum
  t_rc 2 aionas_request_mark ../etc subagent_sonnet
  t_rc 2 aionas_request_mark 'a b' subagent_sonnet
  t_rc 2 aionas_request_mark sess-1 output_trim 'p"x'
  t_rc 2 aionas_request_mark sess-1 output_trim p1 -5
  t_rc 2 aionas_request_mark sess-1 output_trim p1 'rm -rf'
  t_rc 2 aionas_request_mark sess-1 output_trim p1 99999999999
  t_not test -e "$(RD)/queue.tsv"
  t_eq "" "$(ls "$(RD)" 2>/dev/null)"
}

test_a_stop_without_a_prompt_id_drops_the_marks_and_invents_nothing() {
  t_enroll; export AIONAS_NOW=$T0
  aionas_request_mark sess-1 subagent_sonnet
  t_rc 0 aionas_request_settle sess-1 ""
  t_not test -e "$(RD)/open.sess-1"
  t_not test -s "$(RD)/queue.tsv"
  t_rc 0 aionas_requests_flush
  t_eq 0 "$(t_calls)"
}

test_the_body_is_only_the_gateways_fields_whatever_the_queue_holds() {
  t_enroll; export AIONAS_NOW=$T0
  mkdir -p "$(RD)"
  {
    printf 'sess-1\tp1\toutput_trim\t%s\t300\n' "$T0"
    printf 'sess-1\tp2\toutput_trim\t%s\t300\tSECRET PROMPT\n' "$T0"
    printf 'sess-1\tSECRET PROMPT\toutput_trim\t%s\t1\n' "$T0"
    printf 'sess-1\tp3\tprompt_text\t%s\t1\n' "$T0"
    printf 'sess-1\tp4\toutput_trim\tSECRET\t1\n' "$T0"
    printf 'sess-1\tp5\toutput_trim\t%s\tSECRET\n' "$T0"
  } >"$(RD)/queue.tsv"
  t_rc 0 aionas_requests_flush
  local all; all=$(bodies)
  t_lacks "$all" SECRET
  t_eq 1 "$(printf '%s\n' "$all" | wc -l | tr -d ' ')"
  local rest
  rest=$(printf '%s' "$all" | sed -E 's/"(session_id|prompt_id|method|ts|plugin_version)":"[A-Za-z0-9._:-]+"//g; s/"tokens":[0-9]+//g')
  t_eq '{,,,,,}' "$rest" "only the allowed keys"
}

test_a_refused_record_is_dropped_and_counted_the_next_is_still_sent() {
  t_enroll; export AIONAS_NOW=$T0
  aionas_request_mark sess-1 output_trim p1; aionas_request_mark sess-1 handoff p1
  FAKE_CURL_STATUS=400 t_rc 0 aionas_requests_flush
  t_not test -s "$(RD)/queue.tsv"
  t_eq 2 "$(cat "$(RD)/dropped")"
}

test_a_failed_send_keeps_the_rows_and_retries_after_five_minutes() {
  t_enroll; export AIONAS_NOW=$T0
  aionas_request_mark sess-1 output_trim p1
  aionas_request_mark sess-1 handoff p1
  FAKE_CURL_STATUS=503 t_rc 1 aionas_requests_flush
  t_eq 1 "$(t_calls)" "stops at the first failure"
  t_eq 2 "$(wc -l <"$(RD)/queue.tsv" | tr -d ' ')" "both rows kept"
  AIONAS_NOW=$((T0 + 299)) t_rc 4 aionas_requests_flush
  t_eq 1 "$(t_calls)"
  AIONAS_NOW=$((T0 + 300)) t_rc 0 aionas_requests_flush
  t_eq 3 "$(t_calls)"
  t_not test -s "$(RD)/queue.tsv"
  t_not test -e "$(RD)/last_failed"
}

test_a_timeout_is_a_failure_too() {
  t_enroll; export AIONAS_NOW=$T0
  aionas_request_mark sess-1 output_trim p1
  FAKE_CURL_EXIT=28 t_rc 1 aionas_requests_flush
  t_eq 1 "$(wc -l <"$(RD)/queue.tsv" | tr -d ' ')"
}

test_no_new_send_starts_after_the_time_budget() {
  t_enroll; export AIONAS_NOW=$T0
  aionas_request_mark sess-1 output_trim p1
  aionas_request_mark sess-1 handoff p1
  AIONAS_NOW=$((T0 + 4)) t_rc 0 aionas_requests_flush "$T0"
  t_eq 0 "$(t_calls)"
  t_eq 2 "$(wc -l <"$(RD)/queue.tsv" | tr -d ' ')" "kept for the next turn"
  t_rc 0 aionas_requests_flush "$T0"
  t_eq 2 "$(t_calls)"
}

test_old_rows_are_dropped_and_the_queue_is_capped() {
  t_enroll; export AIONAS_NOW=$T0
  mkdir -p "$(RD)"
  printf 'sess-1\told\toutput_trim\t%s\t1\n' "$((T0 - 172801))" >"$(RD)/queue.tsv"
  AIONAS_REQUESTS_MAX_QUEUE=2 aionas_request_mark sess-1 output_trim p1
  aionas_request_mark sess-1 output_trim p2; aionas_request_mark sess-1 output_trim p3
  AIONAS_REQUESTS_MAX_QUEUE=2 t_rc 0 aionas_requests_flush
  t_eq 2 "$(t_calls)"
  t_lacks "$(bodies)" '"old"'
  t_lacks "$(bodies)" '"p1"'
}

test_the_stop_hook_settles_this_sessions_marks_with_the_input_prompt_id() {
  t_enroll; export AIONAS_NOW=$T0
  aionas_request_mark sess-1 subagent_sonnet
  aionas_request_mark sess-2 subagent_sonnet
  stop_in sess-1 prompt-A | bash "$STOPHOOK"
  t_eq 1 "$(bodies | wc -l | tr -d ' ')"
  t_contains "$(bodies)" '"session_id":"sess-1","prompt_id":"prompt-A","method":"subagent_sonnet"'
  t_ok test -e "$(RD)/open.sess-2"  # another session's marks wait for its own Stop
}

test_the_stop_hook_still_sends_the_counters_in_the_same_turn() {
  t_enroll; export AIONAS_NOW=$T0
  aionas_counter_inc subagent_sonnet fired
  aionas_request_mark sess-1 subagent_sonnet
  stop_in sess-1 prompt-A | bash "$STOPHOOK"
  local urls=""; for i in $(seq 1 "$(t_calls)"); do urls="$urls $(t_call "$i" url | sed 's|.*/savings/||')"; done
  t_contains "$urls" requests
  t_contains "$urls" counters
}

test_the_stop_hook_on_an_input_without_json_does_not_fail() {
  t_enroll; export AIONAS_NOW=$T0
  printf 'not json' | bash "$STOPHOOK"
  t_eq 0 $?
}

test_a_subagent_start_marks_only_when_the_method_fired() {
  t_enroll; export AIONAS_NOW=$T0
  AIONAS_SESSION_ID=sess-1 bash "$BYPASS" --subagent-start
  t_eq subagent_sonnet "$(cut -f1 "$(RD)/open.sess-1")"
  aionas_override_local_add subagent_sonnet 3600
  AIONAS_SESSION_ID=sess-1 bash "$BYPASS" --subagent-start
  t_eq 1 "$(wc -l <"$(RD)/open.sess-1" | tr -d ' ')" "a skipped start is no record"
}

test_the_store_marks_output_trim_with_the_tokens_it_left_out() {
  t_enroll; export AIONAS_NOW=$T0 AIONAS_CC_VERSION=2.1.299
  aionas_mkdir "$(aionas_savings_dir)"
  printf 'V\t1\nM\toutput_trim\ton\t0\t1\t1\t0\n' >"$(aionas_savings_dir)/policy.cache"
  awk 'BEGIN { for (i = 1; i <= 300; i++) printf "%sline %04d abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghij", (i > 1 ? "\n" : ""), i }' >"$HOME/o.txt"
  printf '{"session_id":"s1","transcript_path":"%s/none.jsonl","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"./build.sh"},"tool_response":{"stdout":%s,"stderr":"","interrupted":false,"isImage":false},"tool_use_id":"t1"}' \
    "$HOME" "$(aionas_json_escape "$(cat "$HOME/o.txt")")" | bash "$T_PLUGIN/hooks/posttool-store.sh" >/dev/null
  local row; row=$(cat "$(RD)/open.s1")
  t_eq output_trim "$(printf '%s' "$row" | cut -f1)"
  local tok; tok=$(printf '%s' "$row" | cut -f3)
  aionas_is_uint "$tok" && [ "$tok" -gt 1000 ] || t_fail "tokens left out: [$tok]"
  # No content in the mark.
  t_lacks "$row" line
}

test_the_handoff_wake_marks_the_prompt_that_armed_it_with_the_context_size() {
  t_enroll; export AIONAS_NOW=$T0
  . "$T_PLUGIN/hooks/handoff-wake.sh"
  aionas_mkdir "$(aionas_savings_dir)"
  printf 'V\t1\nF\t1\nM\thandoff\ton\t0\t1\t1\t0\n' >"$(aionas_savings_dir)/policy.cache"
  local tok; tok=$(aionas_handoff_arm sess-1)
  aionas_handoff_status sess-1 armed 210000 $((T0 + 60))
  aionas_handoff_deliver sess-1 "$HOME" "$tok" 210000 55 3600 prompt-H 2>/dev/null
  t_eq "$(printf 'sess-1\tprompt-H\thandoff\t%s\t210000' "$T0")" "$(cat "$(RD)/queue.tsv")"
}

t_main "$@"
