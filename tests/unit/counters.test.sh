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
  t_eq '{"plugin_version":"0.6.0","counters":[{"day":"2026-10-20","method_id":"output_trim","counter":"fired","value":3},{"day":"2026-10-20","method_id":"output_trim","counter":"bypass","value":1},{"day":"2026-10-19","method_id":"output_trim","counter":"fired","value":1}]}' "$(t_call 1 body)"
  # The day's running total stays (it is what the next send repeats); the older day is pruned once confirmed.
  t_eq "$(printf '2026-10-20\toutput_trim\tfired\t3\n2026-10-20\toutput_trim\tbypass\t1')" "$(cat "$(CD)/pending.tsv")"
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
  t_eq '{"plugin_version":"0.6.0","counters":[]}' "$(printf '%s' "$rest" | tr -d ',' | sed 's/"0.6.0"/"0.6.0",/')"
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
  t_eq "" "$(ls "$(CD)" | grep -E '^(batch|\.)' || true)"
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
  t_contains "$(t_call 1 body)$(t_call 2 body)" '"value":11' # the total, so the increment made during the flush is in it
}

# AIO-1023: compact_pressed (handoff only) goes in a request of its own.
test_compact_pressed_is_handoff_only() {
  t_rc 0 aionas_counter_inc handoff compact_pressed
  t_rc 2 aionas_counter_inc output_trim compact_pressed
  t_rc 2 aionas_counter_inc subagent_sonnet compact_pressed 2
}

test_compact_pressed_travels_alone_and_sums_per_day() {
  t_enroll
  export AIONAS_NOW=$T0
  aionas_counter_inc handoff fired
  aionas_counter_inc handoff compact_pressed
  aionas_counter_inc handoff compact_pressed
  t_rc 0 aionas_counters_flush
  t_eq 2 "$(t_calls)"
  t_eq '{"plugin_version":"0.6.0","counters":[{"day":"2026-10-20","method_id":"handoff","counter":"fired","value":1}]}' "$(t_call 1 body)"
  t_eq '{"plugin_version":"0.6.0","counters":[{"day":"2026-10-20","method_id":"handoff","counter":"compact_pressed","value":2}]}' "$(t_call 2 body)"
  t_eq "$(printf '2026-10-20\thandoff\tfired\t1')" "$(cat "$(CD)/pending.tsv")"
  t_eq "$(printf '2026-10-20\thandoff\tcompact_pressed\t2')" "$(cat "$(CD)/compact.tsv")"
}

test_a_gateway_that_refuses_compact_pressed_still_gets_the_other_counters() {
  t_enroll
  export AIONAS_NOW=$T0
  aionas_counter_inc handoff fired
  aionas_counter_inc handoff compact_pressed
  # The first request (the day's counters) is accepted; the second (compact_pressed, a name an older gateway does not know) is refused with 400.
  local shim="$HOME/shim.sh"
  cat >"$shim" <<SH
#!/usr/bin/env bash
n=\$(find "$FAKE_CURL_LOG" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
if [ "\$n" -ge 1 ]; then FAKE_CURL_STATUS=400; export FAKE_CURL_STATUS; fi
exec "$T_REPO/tests/lib/fake-curl.sh" "\$@"
SH
  chmod +x "$shim"
  AIONAS_CURL="$shim" t_rc 5 aionas_counters_flush
  t_eq 2 "$(t_calls)"
  t_eq "$(printf '2026-10-20\thandoff\tfired\t1')" "$(cat "$(CD)/pending.tsv")"  # the accepted total stays
  t_ok test ! -e "$(CD)/compact.tsv"  # the refused rows are dropped
  t_eq 1 "$(cat "$(CD)/dropped")"
  t_eq "$T0" "$(cat "$(CD)/last_sent")"
}

test_a_failed_counters_send_keeps_the_compact_rows_for_the_next_hour() {
  t_enroll
  export AIONAS_NOW=$T0
  aionas_counter_inc handoff fired
  aionas_counter_inc handoff compact_pressed
  FAKE_CURL_STATUS=503 t_rc 1 aionas_counters_flush
  t_eq 1 "$(t_calls)"
  t_ok test -s "$(CD)/pending.tsv"
  t_ok test -s "$(CD)/compact.tsv"
  AIONAS_NOW=$((T0 + 3600)) t_rc 0 aionas_counters_flush
  t_eq 3 "$(t_calls)"
}

# AIO-1004 (W31-30): the server keeps a day's value as the computer's running
# total, so the plugin sends totals, never increments.
test_two_sends_on_one_day_send_the_running_total() {
  t_enroll
  export AIONAS_NOW=$T0
  aionas_counter_inc output_trim fired 3
  t_rc 0 aionas_counters_flush
  t_contains "$(t_call 1 body)" '"counter":"fired","value":3}'
  aionas_counter_inc output_trim fired 2
  aionas_counter_inc output_trim bypass
  AIONAS_NOW=$((T0 + 3600)) t_rc 0 aionas_counters_flush
  t_eq 2 "$(t_calls)"
  t_eq '{"plugin_version":"0.6.0","counters":[{"day":"2026-10-20","method_id":"output_trim","counter":"fired","value":5},{"day":"2026-10-20","method_id":"output_trim","counter":"bypass","value":1}]}' "$(t_call 2 body)"
}

test_an_unchanged_total_is_not_sent_again() {
  t_enroll
  export AIONAS_NOW=$T0
  aionas_counter_inc output_trim fired 3
  t_rc 0 aionas_counters_flush
  AIONAS_NOW=$((T0 + 3600)) t_rc 0 aionas_counters_flush
  AIONAS_NOW=$((T0 + 7200)) t_rc 0 aionas_counters_flush
  t_eq 1 "$(t_calls)"
}

test_a_failed_send_does_not_lose_the_total_and_repeats_it() {
  t_enroll
  export AIONAS_NOW=$T0
  aionas_counter_inc output_trim fired 3
  t_rc 0 aionas_counters_flush
  aionas_counter_inc output_trim fired 4
  FAKE_CURL_STATUS=503 AIONAS_NOW=$((T0 + 3600)) t_rc 1 aionas_counters_flush
  AIONAS_NOW=$((T0 + 7200)) t_rc 0 aionas_counters_flush
  t_contains "$(t_call 3 body)" '"value":7'
}

test_utc_day_rollover_sends_each_day_its_own_total_then_prunes_the_old_day() {
  t_enroll
  local d1=$((T0 + 13 * 3600)) # 2026-10-20T23:00Z
  AIONAS_NOW=$d1 aionas_counter_inc output_trim fired 3
  AIONAS_NOW=$((d1 + 3600)) aionas_counter_inc output_trim fired 2   # 2026-10-21T00:00Z
  AIONAS_NOW=$((d1 + 3600)) t_rc 0 aionas_counters_flush
  t_eq '{"plugin_version":"0.6.0","counters":[{"day":"2026-10-20","method_id":"output_trim","counter":"fired","value":3},{"day":"2026-10-21","method_id":"output_trim","counter":"fired","value":2}]}' "$(t_call 1 body)"
  t_eq "$(printf '2026-10-21\toutput_trim\tfired\t2')" "$(cat "$(CD)/pending.tsv")"
  AIONAS_NOW=$((d1 + 7200)) aionas_counter_inc output_trim fired
  AIONAS_NOW=$((d1 + 7200 + 3600)) t_rc 0 aionas_counters_flush
  t_eq '{"plugin_version":"0.6.0","counters":[{"day":"2026-10-21","method_id":"output_trim","counter":"fired","value":3}]}' "$(t_call 2 body)"
}

test_totals_are_kept_per_method_and_counter() {
  t_enroll
  export AIONAS_NOW=$T0
  aionas_counter_inc output_trim fired
  aionas_counter_inc handoff fired 2
  t_rc 0 aionas_counters_flush
  AIONAS_NOW=$((T0 + 3600)) aionas_counter_inc handoff fired
  AIONAS_NOW=$((T0 + 3600)) t_rc 0 aionas_counters_flush
  t_eq '{"plugin_version":"0.6.0","counters":[{"day":"2026-10-20","method_id":"output_trim","counter":"fired","value":1},{"day":"2026-10-20","method_id":"handoff","counter":"fired","value":3}]}' "$(t_call 2 body)"
}

test_concurrent_sessions_add_up() {
  t_enroll
  export AIONAS_NOW=$T0
  local i
  for i in 1 2 3 4 5 6 7 8; do aionas_counter_inc output_trim fired & done
  wait
  t_rc 0 aionas_counters_flush
  t_contains "$(t_call 1 body)" '"value":8'
}

t_main "$@"
