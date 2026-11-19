#!/usr/bin/env bash
# lib/requests.sh and its hooks: one record per prompt per method that acted,
# to POST /enroll/v1/savings/requests (AIO-1004, wave 31; AIO-1073). Ids,
# method names, a time, the plugin version and token counts only.
. "$(dirname "$0")/../lib/harness.sh"
T0=1792490400 # 2026-10-20T10:00:00Z
STOPHOOK="$T_PLUGIN/hooks/counters-flush.sh"
PROMPTHOOK="$T_PLUGIN/hooks/request-prompt.sh"
BYPASS="$T_PLUGIN/commands/aionas-bypass.sh"
RD() { echo "$(aionas_savings_dir)/requests"; }
spooled() { cat "$(RD)"/spool/*.ev 2>/dev/null | awk 'END { print NR }'; }
# What Claude Code sends to the UserPromptSubmit and Stop hooks.
prompt_in() { printf '{"session_id":"%s","prompt_id":"%s","transcript_path":"/x/y.jsonl","cwd":"/x","hook_event_name":"UserPromptSubmit","prompt":"secret words"}' "$1" "$2"; }
stop_in() { printf '{"session_id":"%s","prompt_id":"%s","transcript_path":"/x/y.jsonl","cwd":"/x","hook_event_name":"Stop","stop_hook_active":false}' "$1" "$2"; }
submit() { prompt_in "$1" "$2" | bash "$PROMPTHOOK"; }
# A sub-agent the policy moved to Sonnet (what the mod runs after the spawn).
moved() { AIONAS_SESSION_ID=$1 bash "$BYPASS" --subagent-start moved; }
# Every request to the gateway carrying a record, as one body per line.
bodies() { local i n; n=$(t_calls); for i in $(seq 1 "$n"); do case "$(t_call "$i" url)" in */savings/requests) t_call "$i" body ;; esac; done; }

test_a_mark_takes_the_sessions_current_prompt_and_is_one_exact_post() {
  t_enroll; export AIONAS_NOW=$T0
  submit sess-1 prompt-9
  aionas_request_mark sess-1 subagent_sonnet
  aionas_request_mark sess-1 subagent_sonnet
  t_rc 0 aionas_requests_flush
  t_eq 1 "$(t_calls)" "two sub-agent starts of one prompt are one record"
  t_eq POST "$(t_call 1 method)"
  t_eq https://gw.example.test/enroll/v1/savings/requests "$(t_call 1 url)"
  t_contains "$(t_call 1 headers)" "Authorization: Bearer $T_ALIAS"
  t_eq '{"session_id":"sess-1","prompt_id":"prompt-9","method":"subagent_sonnet","ts":"2026-10-20T10:00:00Z","plugin_version":"0.7.0"}' "$(t_call 1 body)"
  t_eq 0 "$(spooled)"
}

test_the_prompt_hook_keeps_the_prompt_id_and_never_the_prompt() {
  t_enroll; export AIONAS_NOW=$T0
  local out; out=$(submit sess-1 prompt-9 2>&1)
  t_eq "" "$out" "silent"
  t_eq prompt-9 "$(cat "$(RD)/prompt.sess-1")"
  t_lacks "$(cat "$(RD)"/* 2>/dev/null)" secret
}

test_a_mark_in_a_session_with_no_prompt_is_dropped() {
  t_enroll; export AIONAS_NOW=$T0
  t_rc 0 aionas_request_mark sess-1 subagent_sonnet
  submit sess-2 p2
  # A prompt Claude Code sent without an id forgets the session's last one.
  submit sess-2 ""
  t_rc 0 aionas_request_mark sess-2 subagent_sonnet
  t_eq 0 "$(spooled)"
  t_rc 0 aionas_requests_flush
  t_eq 0 "$(t_calls)"
}

# AIO-1073 acceptance: turn A spawns a sub-agent and is cancelled before its
# Stop; turn B completes. A's mark is A's; B's prompt id carries nothing of A.
test_an_interrupted_turns_mark_never_goes_to_the_next_turn() {
  t_enroll; export AIONAS_NOW=$T0
  submit sess-1 prompt-A
  moved sess-1
  # (cancelled: no Stop for A)
  submit sess-1 prompt-B
  stop_in sess-1 prompt-B | bash "$STOPHOOK"
  t_eq '{"session_id":"sess-1","prompt_id":"prompt-A","method":"subagent_sonnet","ts":"2026-10-20T10:00:00Z","plugin_version":"0.7.0"}' "$(bodies)"
  t_lacks "$(bodies)" prompt-B
}

# AIO-1073 acceptance: A's async Stop runs late, after B's marks.
test_a_late_stop_never_claims_a_later_turns_marks() {
  t_enroll; export AIONAS_NOW=$T0
  submit sess-1 prompt-A
  submit sess-1 prompt-B
  moved sess-1
  stop_in sess-1 prompt-A | bash "$STOPHOOK"
  t_eq 1 "$(bodies | wc -l | tr -d ' ')"
  t_contains "$(bodies)" '"prompt_id":"prompt-B"'
  t_lacks "$(bodies)" prompt-A
}

test_tokens_are_kept_and_each_method_is_its_own_post() {
  t_enroll; export AIONAS_NOW=$T0
  submit sess-1 p1
  aionas_request_mark sess-1 handoff p1 1500
  aionas_request_mark sess-1 subagent_sonnet
  t_rc 0 aionas_requests_flush
  t_eq 2 "$(t_calls)"
  t_eq '{"session_id":"sess-1","prompt_id":"p1","method":"handoff","ts":"2026-10-20T10:00:00Z","plugin_version":"0.7.0","tokens":1500}' "$(bodies | grep handoff)"
  t_eq '{"session_id":"sess-1","prompt_id":"p1","method":"subagent_sonnet","ts":"2026-10-20T10:00:00Z","plugin_version":"0.7.0"}' "$(bodies | grep subagent_sonnet)"
}

test_two_prompts_are_two_records() {
  t_enroll; export AIONAS_NOW=$T0
  submit sess-1 p1; aionas_request_mark sess-1 subagent_sonnet
  AIONAS_NOW=$((T0 + 1)) submit sess-1 p2; AIONAS_NOW=$((T0 + 1)) aionas_request_mark sess-1 subagent_sonnet
  t_rc 0 aionas_requests_flush
  t_contains "$(bodies | sed -n 1p)" '"prompt_id":"p1"'
  t_contains "$(bodies | sed -n 2p)" '"prompt_id":"p2"'
}

test_a_computer_that_is_not_enrolled_queues_and_sends_nothing() {
  t_unenroll; export AIONAS_NOW=$T0
  submit sess-1 p1
  t_rc 0 aionas_request_mark sess-1 subagent_sonnet
  t_rc 0 aionas_request_mark sess-1 handoff p1
  t_not test -e "$(RD)"
  t_rc 0 aionas_requests_flush
  t_eq 0 "$(t_calls)"
}

test_marks_outside_the_closed_lists_are_refused() {
  t_enroll; export AIONAS_NOW=$T0
  t_rc 2 aionas_request_mark sess-1 seat_fit
  t_rc 2 aionas_request_mark sess-1 write_minimum
  t_rc 2 aionas_request_mark sess-1 output_trim p1
  t_rc 2 aionas_request_mark ../etc subagent_sonnet
  t_rc 2 aionas_request_mark 'a b' subagent_sonnet
  t_rc 2 aionas_request_mark sess-1 handoff 'p"x'
  t_rc 2 aionas_request_mark sess-1 handoff p1 -5
  t_rc 2 aionas_request_mark sess-1 handoff p1 'rm -rf'
  t_rc 2 aionas_request_mark sess-1 handoff p1 99999999999
  t_eq "" "$(ls "$(RD)" 2>/dev/null)"
}

test_the_body_is_only_the_gateways_fields_whatever_the_spool_holds() {
  t_enroll; export AIONAS_NOW=$T0
  mkdir -p "$(RD)/spool"
  {
    printf 'sess-1\tp1\thandoff\t%s\t300\n' "$T0"
    printf 'sess-1\tp2\thandoff\t%s\t300\tSECRET PROMPT\n' "$T0"
    printf 'sess-1\tSECRET PROMPT\thandoff\t%s\t1\n' "$T0"
    printf 'sess-1\tp3\tprompt_text\t%s\t1\n' "$T0"
    printf 'sess-1\tp4\thandoff\tSECRET\t1\n'
    printf 'sess-1\tp5\thandoff\t%s\tSECRET\n' "$T0"
  } >"$(RD)/spool/1.1.1.ev"
  t_rc 0 aionas_requests_flush
  local all; all=$(bodies)
  t_lacks "$all" SECRET
  t_eq 1 "$(printf '%s\n' "$all" | wc -l | tr -d ' ')"
  local rest
  rest=$(printf '%s' "$all" | sed -E 's/"(session_id|prompt_id|method|ts|plugin_version)":"[A-Za-z0-9._:-]+"//g; s/"tokens":[0-9]+//g')
  t_eq '{,,,,,}' "$rest" "only the allowed keys"
  t_eq 0 "$(spooled)"
}

test_a_refused_record_is_dropped_and_counted_the_next_is_still_sent() {
  t_enroll; export AIONAS_NOW=$T0
  submit sess-1 p1
  aionas_request_mark sess-1 subagent_sonnet; aionas_request_mark sess-1 handoff p1
  FAKE_CURL_STATUS=400 t_rc 0 aionas_requests_flush
  t_eq 2 "$(t_calls)"
  t_eq 0 "$(spooled)"
  t_eq 2 "$(cat "$(RD)/dropped")"
}

test_a_failed_send_keeps_the_rows_and_retries_after_five_minutes() {
  t_enroll; export AIONAS_NOW=$T0
  submit sess-1 p1
  aionas_request_mark sess-1 subagent_sonnet
  aionas_request_mark sess-1 handoff p1
  FAKE_CURL_STATUS=503 t_rc 1 aionas_requests_flush
  t_eq 1 "$(t_calls)" "stops at the first failure"
  t_eq 2 "$(spooled)" "both rows kept"
  AIONAS_NOW=$((T0 + 299)) t_rc 4 aionas_requests_flush
  t_eq 1 "$(t_calls)"
  AIONAS_NOW=$((T0 + 300)) t_rc 0 aionas_requests_flush
  t_eq 3 "$(t_calls)"
  t_eq 0 "$(spooled)"
  t_not test -e "$(RD)/last_failed"
}

test_a_timeout_is_a_failure_too() {
  t_enroll; export AIONAS_NOW=$T0
  aionas_request_mark sess-1 handoff p1
  FAKE_CURL_EXIT=28 t_rc 1 aionas_requests_flush
  t_eq 1 "$(spooled)"
}

# AIO-1073 acceptance: a flush stopped at the deadline leaves its records,
# and the next flush sends each exactly once.
test_no_send_starts_past_the_deadline_and_the_next_flush_sends_each_once() {
  t_enroll; export AIONAS_NOW=$T0
  aionas_request_mark sess-1 handoff p1
  aionas_request_mark sess-1 handoff p2
  AIONAS_NOW=$((T0 + 4)) t_rc 0 aionas_requests_flush "$T0"
  t_eq 0 "$(t_calls)"
  t_eq 2 "$(spooled)" "kept for the next turn"
  t_rc 0 aionas_requests_flush "$T0"
  t_eq 2 "$(t_calls)"
  t_rc 0 aionas_requests_flush
  t_eq 2 "$(t_calls)" "nothing sent twice"
  t_eq 1 "$(bodies | grep -c '"prompt_id":"p1"')"
  t_eq 1 "$(bodies | grep -c '"prompt_id":"p2"')"
}

test_a_flush_killed_while_sending_leaves_its_records_for_the_next_one() {
  t_enroll; export AIONAS_NOW=$T0
  aionas_request_mark sess-1 handoff p1
  aionas_request_mark sess-1 handoff p2
  (FAKE_CURL_SLEEP=3 aionas_requests_flush) &
  local pid=$!
  sleep 1
  pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  t_eq 2 "$(spooled)" "nothing lost"
  # The lock of the killed flush is broken after a minute.
  AIONAS_NOW=$((T0 + 61)) t_rc 0 aionas_requests_flush
  t_eq 0 "$(spooled)"
  local sent; sent=$(t_calls)
  AIONAS_NOW=$((T0 + 62)) t_rc 0 aionas_requests_flush
  t_eq "$sent" "$(t_calls)" "nothing sent again"
}

# AIO-1073 acceptance: 20 writers and a flush at once lose and duplicate no row.
test_twenty_parallel_marks_and_a_flush_lose_and_duplicate_nothing() {
  t_enroll; export AIONAS_NOW=$T0
  local i
  for i in $(seq 1 20); do aionas_request_mark sess-1 handoff "p$i" & done
  aionas_requests_flush &
  wait
  aionas_requests_flush
  t_eq 20 "$(bodies | wc -l | tr -d ' ')"
  t_eq 20 "$(bodies | sort -u | wc -l | tr -d ' ')"
  for i in $(seq 1 20); do t_eq 1 "$(bodies | grep -c "\"prompt_id\":\"p$i\"")" "p$i once"; done
  t_eq 0 "$(spooled)"
}

test_old_rows_are_dropped_and_the_queue_is_capped() {
  t_enroll; export AIONAS_NOW=$T0
  mkdir -p "$(RD)/spool"
  printf 'sess-1\told\thandoff\t%s\t1\n' "$((T0 - 172801))" >"$(RD)/spool/1.1.1.ev"
  AIONAS_NOW=$((T0 + 1)) aionas_request_mark sess-1 handoff p1
  AIONAS_NOW=$((T0 + 2)) aionas_request_mark sess-1 handoff p2
  AIONAS_NOW=$((T0 + 3)) aionas_request_mark sess-1 handoff p3
  AIONAS_NOW=$((T0 + 3)) AIONAS_REQUESTS_MAX_QUEUE=2 t_rc 0 aionas_requests_flush
  t_eq 2 "$(t_calls)"
  t_lacks "$(bodies)" '"old"'
  t_lacks "$(bodies)" '"p1"'
  t_eq 0 "$(spooled)"
}

test_rows_an_earlier_build_left_are_sent_once_and_session_marks_dropped() {
  t_enroll; export AIONAS_NOW=$T0
  mkdir -p "$(RD)"
  printf 'sess-1\tp1\thandoff\t%s\t\n' "$T0" >"$(RD)/queue.tsv"
  printf 'sess-1\tp2\tsubagent_sonnet\t%s\t\n' "$T0" >"$(RD)/.batch.77.ok"
  printf 'sess-1\tp3\thandoff\t%s\t\n' "$T0" >"$(RD)/.left.78"
  printf 'subagent_sonnet\t%s\t\n' "$T0" >"$(RD)/open.sess-1"
  t_rc 0 aionas_requests_flush
  t_eq 3 "$(t_calls)"
  t_eq "" "$(ls -A "$(RD)" | grep -v -e '^spool$' -e '^dropped$' || true)"
  t_eq 0 "$(spooled)"
}

test_the_stop_hook_sends_every_sessions_records() {
  t_enroll; export AIONAS_NOW=$T0
  submit sess-1 prompt-A; moved sess-1
  submit sess-2 prompt-Z; moved sess-2
  stop_in sess-1 prompt-A | bash "$STOPHOOK"
  t_eq 2 "$(bodies | wc -l | tr -d ' ')"
  t_contains "$(bodies)" '"session_id":"sess-1","prompt_id":"prompt-A","method":"subagent_sonnet"'
  t_contains "$(bodies)" '"session_id":"sess-2","prompt_id":"prompt-Z","method":"subagent_sonnet"'
}

test_the_stop_hook_still_sends_the_counters_in_the_same_turn() {
  t_enroll; export AIONAS_NOW=$T0
  submit sess-1 prompt-A; moved sess-1
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

test_the_handoff_wake_marks_the_prompt_that_armed_it_with_the_context_size() {
  t_enroll; export AIONAS_NOW=$T0
  . "$T_PLUGIN/hooks/handoff-wake.sh"
  aionas_mkdir "$(aionas_savings_dir)"
  printf 'V\t1\nF\t1\nM\thandoff\ton\t0\t1\t1\t0\n' >"$(aionas_savings_dir)/policy.cache"
  local tok; tok=$(aionas_handoff_arm sess-1)
  aionas_handoff_status sess-1 armed 210000 $((T0 + 60))
  aionas_handoff_deliver sess-1 "$HOME" "$tok" 210000 55 3600 prompt-H 2>/dev/null
  t_eq "$(printf 'sess-1\tprompt-H\thandoff\t%s\t210000' "$T0")" "$(cat "$(RD)"/spool/*.ev)"
}

t_main "$@"
