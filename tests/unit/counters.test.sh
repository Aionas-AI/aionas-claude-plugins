#!/usr/bin/env bash
# lib/counters.sh: queue, hourly send, privacy (AIO-855, W24-4, W24-P2)
. "$(dirname "$0")/../lib/harness.sh"
T0=1792490400 # 2026-10-20T10:00:00Z
CD() { echo "$(aionas_savings_dir)/counters"; }

test_inc_rejects_names_outside_closed_lists() {
  t_rc 2 aionas_counter_inc long_output_trim fired
  t_rc 2 aionas_counter_inc output_trim prompt_text
  t_rc 2 aionas_counter_inc output_trim fired 0
  t_rc 2 aionas_counter_inc output_trim fired -1
  t_rc 2 aionas_counter_inc output_trim fired 'rm -rf'
  t_rc 2 aionas_counter_inc output_trim fired 1000001
  t_ok test ! -e "$(CD)/queue.tsv"
}

test_flush_sends_summed_numbers_only() {
  t_enroll
  export AIONAS_NOW=$T0
  aionas_counter_inc output_trim fired
  aionas_counter_inc output_trim fired 2
  aionas_counter_inc output_trim bypass
  AIONAS_NOW=$((T0 - 86400)) aionas_counter_inc output_trim fired
  t_rc 0 aionas_counters_flush
  t_eq POST "$(t_call 1 method)"
  t_eq https://gw.example.test/enroll/v1/savings/counters "$(t_call 1 url)"
  t_contains "$(t_call 1 headers)" "Authorization: Bearer $T_ALIAS"
  t_contains "$(t_call 1 headers)" "Content-Type: application/json"
  local args; args=$(t_call 1 args | tr '\n' ' ')
  t_contains "$args" "--connect-timeout 3 "
  t_contains "$args" "--max-time 5 "
  t_eq '{"plugin_version":"0.4.0","counters":[{"day":"2026-10-20","method_id":"output_trim","counter":"fired","value":3},{"day":"2026-10-20","method_id":"output_trim","counter":"bypass","value":1},{"day":"2026-10-19","method_id":"output_trim","counter":"fired","value":1}]}' "$(t_call 1 body)"
  t_ok test ! -e "$(CD)/pending.tsv"
  t_eq "$T0" "$(cat "$(CD)/last_sent")"
}

test_body_is_strictly_names_and_numbers() {
  t_enroll
  export AIONAS_NOW=$T0
  local m c
  for m in $AIONAS_METHODS; do for c in $AIONAS_COUNTERS; do aionas_counter_inc "$m" "$c" 7; done; done
  # a corrupted queue line must never reach the server
  printf '2026-10-20\toutput_trim\tfired\t1\tsecret prompt\n2026-10-20\toutput_trim\tsecret\t1\n' >>"$(CD)/queue.tsv"
  t_rc 0 aionas_counters_flush
  local body; body=$(t_call 1 body)
  t_lacks "$body" secret
  local rest
  rest=$(printf '%s' "$body" | sed -E 's/\{"day":"[0-9]{4}-[0-9]{2}-[0-9]{2}","method_id":"[a-z_]+","counter":"(fired|skipped|bypass)","value":[0-9]+\}//g')
  t_eq '{"plugin_version":"0.4.0","counters":[]}' "$(printf '%s' "$rest" | tr -d ',' | sed 's/"0.4.0"/"0.4.0",/')"
}

test_flush_is_hourly() {
  t_enroll
  export AIONAS_NOW=$T0
  aionas_counter_inc handoff fired
  t_rc 0 aionas_counters_flush
  aionas_counter_inc handoff fired
  AIONAS_NOW=$((T0 + 3599)) t_rc 4 aionas_counters_flush
  t_eq 1 "$(t_calls)"
  AIONAS_NOW=$((T0 + 3600)) t_rc 0 aionas_counters_flush
  t_eq 2 "$(t_calls)"
  aionas_counter_inc handoff fired
  AIONAS_NOW=$((T0 + 3601)) t_rc 0 aionas_counters_flush --force
  t_eq 3 "$(t_calls)"
}

test_failed_send_keeps_rows_for_next_hour() {
  t_enroll
  export AIONAS_NOW=$T0
  aionas_counter_inc handoff fired 4
  FAKE_CURL_EXIT=28 t_rc 1 aionas_counters_flush
  t_eq "$(printf '2026-10-20\thandoff\tfired\t4')" "$(cat "$(CD)/pending.tsv")"
  aionas_counter_inc handoff fired
  AIONAS_NOW=$((T0 + 60)) t_rc 4 aionas_counters_flush
  FAKE_CURL_STATUS=503 AIONAS_NOW=$((T0 + 3600)) t_rc 1 aionas_counters_flush
  t_eq "$(printf '2026-10-20\thandoff\tfired\t5')" "$(cat "$(CD)/pending.tsv")" "no loss, no double count"
  AIONAS_NOW=$((T0 + 7200)) t_rc 0 aionas_counters_flush
  t_contains "$(t_call 3 body)" '"value":5'
  t_eq "" "$(ls "$(CD)" | grep -E '^(batch|pending|\.)' || true)"
}

test_refused_rows_are_dropped_and_counted() {
  t_enroll
  export AIONAS_NOW=$T0
  aionas_counter_inc handoff fired
  aionas_counter_inc handoff skipped
  FAKE_CURL_STATUS=400 t_rc 5 aionas_counters_flush
  t_ok test ! -e "$(CD)/pending.tsv"
  t_eq 2 "$(cat "$(CD)/dropped")"
}

test_rows_older_than_30_days_are_not_sent() {
  t_enroll
  AIONAS_NOW=$((T0 - 31 * 86400)) aionas_counter_inc handoff fired
  AIONAS_NOW=$T0 aionas_counter_inc handoff fired
  AIONAS_NOW=$T0 t_rc 0 aionas_counters_flush
  t_lacks "$(t_call 1 body)" 2026-09-19
}

test_not_enrolled_keeps_rows_without_call() {
  export AIONAS_NOW=$T0
  aionas_counter_inc handoff fired
  t_rc 3 aionas_counters_flush
  t_eq 0 "$(t_calls)"
  t_ok test -s "$(CD)/pending.tsv"
}

test_nothing_queued_sends_nothing() {
  t_enroll
  t_rc 0 aionas_counters_flush
  aionas_mkdir "$(CD)"
  t_rc 0 aionas_counters_flush --force
  t_eq 0 "$(t_calls)"
}

test_inc_during_flush_is_not_lost() {
  t_enroll
  export AIONAS_NOW=$T0
  aionas_counter_inc handoff fired
  FAKE_CURL_SLEEP=1 aionas_counters_flush &
  sleep 0.3
  aionas_counter_inc handoff fired 10
  wait
  AIONAS_NOW=$((T0 + 3600)) t_rc 0 aionas_counters_flush
  t_contains "$(t_call 1 body)$(t_call 2 body)" '"value":10'
}

t_main "$@"
