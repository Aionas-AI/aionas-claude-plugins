#!/usr/bin/env bash
# lib/policy.sh: sync, cache, session pins, lookups, overrides (AIO-855, W24-1/2, W24-P2)
. "$(dirname "$0")/../lib/harness.sh"
FIX="$T_REPO/tests/fixtures"
T0=1792490400 # 2026-10-20T10:00:00Z

sync_ok() { t_enroll; export FAKE_CURL_STATUS=200 FAKE_CURL_BODY="$FIX/policy.json"; t_rc 0 aionas_policy_sync; }

test_sync_calls_policy_route_with_alias_and_limits() {
  sync_ok
  t_eq 1 "$(t_calls)"
  t_eq GET "$(t_call 1 method)"
  t_eq https://gw.example.test/enroll/v1/savings/policy "$(t_call 1 url)"
  t_contains "$(t_call 1 headers)" "Authorization: Bearer $T_ALIAS"
  local args; args=$(t_call 1 args | tr '\n' ' ')
  t_contains "$args" "--connect-timeout 3 "
  t_contains "$args" "--max-time 5 "
  t_contains "$args" "--retry 0 "
  t_lacks "$args" "$T_ALIAS" "alias on the command line"
  t_eq "" "$(ls -A "$(aionas_savings_dir)" | grep '^\.auth' || true)" "header file left behind"
}

test_sync_writes_cache_rows() {
  sync_ok
  local c; c=$(cat "$(aionas_savings_dir)/policy.cache")
  t_contains "$c" "$(printf 'M\thandoff\ton\t0\t1\t1\t0')"
  t_contains "$c" "$(printf 'M\tnoisy_guard\toff\t0\t0\t0\t0')"
  t_contains "$c" "$(printf 'P\thandoff\tthreshold_tokens\tn\t200000')"
  t_contains "$c" "$(printf 'P\thandoff\tnested.x\ts\ty')"
  t_contains "$c" "$(printf 'O\tsubagent_sonnet\tself\t%s\t%s\tovr_1' $T0 $((T0 + 3600)))"
  t_contains "$c" "$(printf 'O\tseat_fit\trequested\t0\t0\tovr_2')"
  t_lacks "$c" not_a_method
  t_lacks "$c" "$(printf 'M\twrite_minimum')" "malformed state row kept"
  t_lacks "$c" "flaky" "reason text in the cache"
  t_ok test -f "$(aionas_savings_dir)/policy.json"
}

test_defaults_when_nothing_cached() {
  local m
  for m in $AIONAS_METHODS; do
    t_eq on "$(aionas_policy_state "$m")" "$m default"
    t_ok aionas_policy_active "$m"
  done
  t_ok aionas_policy_self_override_allowed handoff
  t_ok aionas_policy_self_release_allowed handoff
  t_not aionas_policy_self_override_allowed cache_guard
  t_not aionas_policy_self_release_allowed cache_guard
  t_rc 2 aionas_policy_state long_output_store
}

test_lookups_follow_cache() {
  sync_ok
  t_eq on "$(aionas_policy_state handoff)"
  t_eq off "$(aionas_policy_state noisy_guard)"
  t_eq off "$(aionas_policy_state output_store)" "released means off"
  t_eq on "$(aionas_policy_state cache_guard)" "required stays on"
  t_eq on "$(aionas_policy_state dispatcher)" "absent method is on"
  t_not aionas_policy_self_override_allowed noisy_guard
  t_not aionas_policy_self_override_allowed effort_default
  t_ok aionas_policy_self_release_allowed effort_default
  t_eq 55 "$(aionas_policy_param handoff idle_minutes)"
  t_rc 1 aionas_policy_param handoff missing
}

test_failed_sync_keeps_last_good_cache() {
  sync_ok
  local before; before=$(cat "$(aionas_savings_dir)/policy.cache")
  FAKE_CURL_EXIT=28 t_rc 1 aionas_policy_sync
  t_eq "$before" "$(cat "$(aionas_savings_dir)/policy.cache")" "timeout"
  FAKE_CURL_STATUS=503 t_rc 1 aionas_policy_sync
  FAKE_CURL_STATUS=401 t_rc 1 aionas_policy_sync
  local junk; junk=$(mktemp "$T_ROOT/junk.XXXXXX"); printf '<html>' >"$junk"
  FAKE_CURL_BODY=$junk t_rc 1 aionas_policy_sync
  printf '{"overrides":[]}' >"$junk"
  FAKE_CURL_BODY=$junk t_rc 1 aionas_policy_sync
  t_eq "$before" "$(cat "$(aionas_savings_dir)/policy.cache")" "after bad answers"
  t_eq off "$(aionas_policy_state noisy_guard)"
  t_eq 000 "$( (FAKE_CURL_EXIT=28 aionas_policy_sync); cut -d' ' -f2 "$(aionas_savings_dir)/sync.status")"
}

test_failed_sync_without_cache_means_all_on() {
  t_enroll
  FAKE_CURL_EXIT=7 t_rc 1 aionas_policy_sync
  t_ok test ! -e "$(aionas_savings_dir)/policy.cache"
  t_eq on "$(aionas_policy_state noisy_guard)"
}

test_not_enrolled_makes_no_call() {
  t_rc 3 aionas_policy_sync
  t_eq 0 "$(t_calls)"
}

test_sync_lock_skips_second_sync() {
  t_enroll
  aionas_lock_try policy-sync 30
  t_rc 4 aionas_policy_sync
  t_eq 0 "$(t_calls)"
}

test_session_pin_holds_until_next_session() {
  sync_ok
  t_ok aionas_policy_pin sess-A
  local on; on=$(mktemp "$T_ROOT/p.XXXXXX")
  sed 's/"state": "off", "required": false, "self_override_allowed": false/"state": "on", "required": false, "self_override_allowed": true/' "$FIX/policy.json" >"$on"
  FAKE_CURL_BODY=$on t_rc 0 aionas_policy_sync
  t_eq off "$(aionas_policy_state noisy_guard sess-A)" "running session changed"
  t_ok aionas_policy_pin sess-A
  t_eq off "$(aionas_policy_state noisy_guard sess-A)" "re-pin replaced the pin"
  t_ok aionas_policy_pin sess-B
  t_eq on "$(aionas_policy_state noisy_guard sess-B)" "new session missed the change"
  t_eq on "$(aionas_policy_state noisy_guard)"
  t_rc 2 aionas_policy_pin '../x'
}

test_pin_without_cache_stays_on_defaults() {
  t_ok aionas_policy_pin s1
  sync_ok
  t_eq on "$(aionas_policy_state noisy_guard s1)"
  t_eq off "$(aionas_policy_state noisy_guard)"
}

test_pins_are_capped() {
  local i d; d="$(aionas_savings_dir)/sessions"
  for i in $(seq 1 205); do aionas_policy_pin "s$i"; done
  t_eq 200 "$(ls "$d" | wc -l | tr -d ' ')"
}

test_server_overrides_bypass_in_window() {
  sync_ok
  AIONAS_NOW=$((T0 + 60)) t_ok aionas_policy_bypassed subagent_sonnet
  AIONAS_NOW=$((T0 + 60)) t_not aionas_policy_active subagent_sonnet
  AIONAS_NOW=$((T0 + 3600)) t_not aionas_policy_bypassed subagent_sonnet
  AIONAS_NOW=$((T0 - 1)) t_not aionas_policy_bypassed subagent_sonnet
  AIONAS_NOW=$((T0 + 60)) t_ok aionas_policy_bypassed cache_alert
  AIONAS_NOW=$((T0 + 60)) t_not aionas_policy_bypassed seat_fit "a request is not a bypass"
}

test_local_override_applies_at_once_and_expires() {
  sync_ok
  aionas_policy_pin s1
  export AIONAS_NOW=$T0
  t_ok aionas_policy_active handoff s1
  t_ok aionas_override_local_add handoff 3600
  t_not aionas_policy_active handoff s1
  AIONAS_NOW=$((T0 + 3600)) t_ok aionas_policy_active handoff s1
  t_rc 2 aionas_override_local_add cache_guard 60
  t_rc 2 aionas_override_local_add handoff 0
  t_rc 2 aionas_override_local_add handoff 99999999
  t_rc 2 aionas_override_local_add handoff 60 requested
  AIONAS_NOW=$((T0 + 7200)) aionas_override_local_add noisy_guard 60
  t_eq 1 "$(wc -l <"$(aionas_savings_dir)/local-overrides.tsv" | tr -d ' ')" "expired row kept"
}

test_required_method_never_bypassed() {
  sync_ok
  printf 'cache_guard\tself\t0\t9999999999\n' >"$(aionas_savings_dir)/local-overrides.tsv"
  t_ok aionas_policy_active cache_guard
}

t_main "$@"
