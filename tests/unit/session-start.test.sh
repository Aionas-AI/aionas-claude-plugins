#!/usr/bin/env bash
# The SessionStart and Stop hooks of lane p1-core: policy-sync.sh, effort-window.sh,
# daily-scan.sh, counters-flush.sh (AIO-855, AIO-859; W24-P2, W24-3).
. "$(dirname "$0")/../lib/harness.sh"
FIX="$T_REPO/tests/fixtures"
H="$T_PLUGIN/hooks"
T0=1792490400 # 2026-10-20T10:00:00Z
START='{"session_id":"sess-1","hook_event_name":"SessionStart","source":"startup","cwd":"/tmp"}'

hook() { printf '%s' "${2:-$START}" | bash "$H/$1"; }

test_policy_sync_pins_old_policy_then_fetches_new_one() {
  t_enroll; export FAKE_CURL_STATUS=200 FAKE_CURL_BODY="$FIX/policy.json"
  local out; out=$(hook policy-sync.sh)
  t_eq "" "$out"
  t_eq "$(printf 'V\t1\nD\tdefaults')" "$(cat "$(aionas_savings_dir)/sessions/sess-1.cache")" "the starting session keeps what it started with"
  t_eq on "$(aionas_policy_state noisy_guard sess-1)"
  t_eq off "$(aionas_policy_state noisy_guard)" "the next session gets the new policy"
  hook policy-sync.sh '{"session_id":"sess-2"}' >/dev/null
  t_eq off "$(aionas_policy_state noisy_guard sess-2)"
  t_eq on "$(aionas_policy_state noisy_guard sess-1)" "a running session did not change"
  t_eq GET "$(t_call 1 method)"
  t_eq https://gw.example.test/enroll/v1/savings/policy "$(t_call 1 url)"
}

test_policy_sync_unreachable_keeps_cache_makes_one_call_and_exits_0() {
  t_enroll; export FAKE_CURL_STATUS=200 FAKE_CURL_BODY="$FIX/policy.json"
  hook policy-sync.sh >/dev/null
  local before; before=$(cat "$(aionas_savings_dir)/policy.cache")
  mkdir -p "$(aionas_savings_dir)/counters"; printf '2026-10-20\thandoff\tfired\t3\n' >"$(aionas_savings_dir)/counters/queue.tsv"
  export FAKE_CURL_EXIT=28
  local n; n=$(t_calls)
  t_rc 0 hook policy-sync.sh '{"session_id":"sess-3"}'
  t_eq $((n + 1)) "$(t_calls)" "only the policy fetch was tried"
  t_eq "$before" "$(cat "$(aionas_savings_dir)/policy.cache")"
  t_eq off "$(aionas_policy_state noisy_guard sess-3)"
}

test_policy_sync_sends_counters_and_pending_overrides_when_reachable() {
  t_enroll; export FAKE_CURL_STATUS=200 FAKE_CURL_BODY="$FIX/policy.json"
  mkdir -p "$(aionas_savings_dir)/counters" "$(aionas_savings_dir)/pending-overrides"
  printf '2026-10-20\thandoff\tfired\t3\n' >"$(aionas_savings_dir)/counters/queue.tsv"
  printf '{"method_id":"handoff","duration_seconds":60}\n' >"$(aionas_savings_dir)/pending-overrides/1.1.json"
  hook policy-sync.sh >/dev/null
  t_eq 3 "$(t_calls)"
  t_eq https://gw.example.test/enroll/v1/savings/overrides "$(t_call 2 url)"
  t_eq https://gw.example.test/enroll/v1/savings/counters "$(t_call 3 url)"
  t_contains "$(t_call 3 body)" '"method_id":"handoff","counter":"fired","value":3'
  t_eq 0 "$(ls "$(aionas_savings_dir)/pending-overrides" | grep -c json)"
}

test_policy_sync_not_enrolled_makes_no_call() {
  t_rc 0 hook policy-sync.sh
  t_eq 0 "$(t_calls)"
  t_ok test -f "$(aionas_savings_dir)/sessions/sess-1.cache"
}

test_counters_flush_is_hourly() {
  t_enroll; export FAKE_CURL_STATUS=200 AIONAS_NOW=$T0
  mkdir -p "$(aionas_savings_dir)/counters"
  printf '2026-10-20\tnoisy_guard\tfired\t2\n' >"$(aionas_savings_dir)/counters/queue.tsv"
  t_eq "" "$(hook counters-flush.sh '{}')"
  t_eq 1 "$(t_calls)"
  printf '2026-10-20\tnoisy_guard\tfired\t1\n' >>"$(aionas_savings_dir)/counters/queue.tsv"
  export AIONAS_NOW=$((T0 + 600))
  hook counters-flush.sh '{}'
  t_eq 1 "$(t_calls)" "sent twice within the hour"
  export AIONAS_NOW=$((T0 + 3600))
  hook counters-flush.sh '{}'
  t_eq 2 "$(t_calls)"
}

grant() { AIONAS_NOW=${AIONAS_NOW:-$T0} bash "$H/effort-window.sh" grant "$1"; }

test_grant_is_high_by_default_and_counts_fired_once() {
  t_eq high "$(grant s1)"
  t_eq high "$(grant s1)"
  t_eq 1 "$(grep -c "$(printf 'effort_default\tfired')" "$(aionas_savings_dir)/counters/queue.tsv")"
}

test_window_grants_new_sessions_for_life_and_not_open_ones() {
  export AIONAS_NOW=$T0
  t_eq high "$(grant open-before)"
  aionas_mkdir "$(aionas_savings_dir)"
  printf '%s\t%s\txhigh\tself\tovr_1\n' $T0 $((T0 + 600)) >"$(aionas_savings_dir)/effort-window"
  t_eq high "$(grant open-before)" "a session open before the window changed"
  t_eq xhigh "$(grant in-window)"
  export AIONAS_NOW=$((T0 + 601))
  t_eq xhigh "$(grant in-window)" "the window's session lost its level"
  t_eq high "$(grant after-window)"
}

test_max_window() {
  export AIONAS_NOW=$T0
  aionas_mkdir "$(aionas_savings_dir)"
  printf '%s\t%s\tmax\tself\t-\n' $T0 $((T0 + 600)) >"$(aionas_savings_dir)/effort-window"
  t_eq max "$(grant m1)"
}

test_effort_default_off_or_bypassed_grants_free() {
  export AIONAS_NOW=$T0
  aionas_mkdir "$(aionas_savings_dir)"
  printf 'V\t1\nM\teffort_default\toff\t0\t1\t1\t0\n' >"$(aionas_savings_dir)/policy.cache"
  t_eq free "$(grant f1)"
  printf 'V\t1\n' >"$(aionas_savings_dir)/policy.cache"
  aionas_override_local_add effort_default 3600 self
  t_eq free "$(grant f2)"
  t_contains "$(cat "$(aionas_savings_dir)/counters/queue.tsv")" "$(printf 'effort_default\tskipped')"
}

test_approved_request_opens_the_window_at_the_next_session() {
  export AIONAS_NOW=$T0
  . "$T_PLUGIN/commands/aionas-bypass-lib.sh"
  aionas_effort_request_add ovr_9 max
  t_eq high "$(grant before-approval)"
  printf 'V\t1\nM\teffort_default\ton\t0\t0\t1\t0\nO\teffort_default\tapproved\t%s\t%s\tovr_9\n' $T0 $((T0 + 600)) \
    >"$(aionas_savings_dir)/policy.cache"
  t_eq max "$(grant after-approval)"
  t_eq high "$(grant before-approval)"
}

test_blocked_request_stays_high() {
  export AIONAS_NOW=$T0
  aionas_mkdir "$(aionas_savings_dir)"
  printf 'V\t1\nM\teffort_default\ton\t0\t0\t1\t0\nO\teffort_default\trequested\t0\t0\tovr_r\n' >"$(aionas_savings_dir)/policy.cache"
  t_eq high "$(grant r1)"
}

test_session_start_drops_an_ended_window_and_never_writes_settings() {
  export AIONAS_NOW=$((T0 + 700))
  aionas_mkdir "$(aionas_savings_dir)"
  mkdir -p "$HOME/.claude"; printf '{"effortLevel":"high","maxEffortLevel":"high"}\n' >"$HOME/.claude/settings.json"
  printf '%s\t%s\txhigh\tself\t-\n' $T0 $((T0 + 600)) >"$(aionas_savings_dir)/effort-window"
  t_eq "" "$(hook effort-window.sh)"
  t_not test -f "$(aionas_savings_dir)/effort-window"
  t_eq '{"effortLevel":"high","maxEffortLevel":"high"}' "$(cat "$HOME/.claude/settings.json")"
  printf '%s\t%s\txhigh\tself\t-\n' $T0 $((T0 + 6000)) >"$(aionas_savings_dir)/effort-window"
  hook effort-window.sh
  t_ok test -f "$(aionas_savings_dir)/effort-window"
}

# fake_scanner [DIR]: a scanner in ~/.aionas/agent/DIR (default bin).
fake_scanner() {
  local d="${1:-bin}"
  mkdir -p "$HOME/.aionas/agent/$d"
  local s="$HOME/.aionas/agent/$d/aionas-scan"
  printf '#!/bin/sh\necho "$@" >>"%s/scan.log"\n' "$HOME" >"$s"
  chmod +x "$s"
}
wait_for() { local i; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$1" ] && return 0; sleep 0.1; done; return 1; }

test_daily_scan_runs_incremental_once_a_day() {
  t_enroll; fake_scanner; export AIONAS_NOW=$T0
  t_eq "" "$(hook daily-scan.sh)"
  t_ok wait_for "$HOME/scan.log"
  t_eq "--incremental" "$(cat "$HOME/scan.log")"
  hook daily-scan.sh; sleep 0.3
  t_eq 1 "$(wc -l <"$HOME/scan.log" | tr -d ' ')" "ran twice the same day"
  export AIONAS_NOW=$((T0 + 86400))
  hook daily-scan.sh
  local i; for i in 1 2 3 4 5 6 7 8 9 10; do [ "$(wc -l <"$HOME/scan.log" | tr -d ' ')" = 2 ] && break; sleep 0.1; done
  t_eq 2 "$(wc -l <"$HOME/scan.log" | tr -d ' ')"
  t_eq 0 "$(t_calls)"
}

test_daily_scan_finds_the_scanner_in_tools_first_then_bin() {
  t_enroll; export AIONAS_NOW=$T0
  fake_scanner tools
  mkdir -p "$HOME/.aionas/agent/bin"
  printf '#!/bin/sh\necho bin >>"%s/scan.log"\n' "$HOME" >"$HOME/.aionas/agent/bin/aionas-scan"
  chmod +x "$HOME/.aionas/agent/bin/aionas-scan"
  hook daily-scan.sh
  t_ok wait_for "$HOME/scan.log"
  t_eq "--incremental" "$(cat "$HOME/scan.log")" "tools/ must win over bin/"
}

test_daily_scan_returns_at_once_while_the_scanner_runs() {
  t_enroll; mkdir -p "$HOME/.aionas/agent/bin"
  printf '#!/bin/sh\nsleep 3\necho done >"%s/slow.log"\n' "$HOME" >"$HOME/.aionas/agent/bin/aionas-scan"
  chmod +x "$HOME/.aionas/agent/bin/aionas-scan"
  local t1 t2; t1=$(date +%s); hook daily-scan.sh; t2=$(date +%s)
  [ $((t2 - t1)) -le 1 ] || t_fail "the hook waited $((t2 - t1)) s for the scanner"
}

test_daily_scan_skips_without_scanner_or_enrollment() {
  t_rc 0 hook daily-scan.sh
  t_not test -f "$(aionas_savings_dir)/scan.day"
  fake_scanner
  t_rc 0 hook daily-scan.sh
  t_not test -f "$(aionas_savings_dir)/scan.day" # not enrolled: no scan
}

test_hooks_are_silent_and_exit_0_on_garbage_input() {
  local f
  for f in policy-sync.sh effort-window.sh daily-scan.sh counters-flush.sh; do
    t_eq "" "$(hook "$f" 'not json')" "$f printed"
    t_rc 0 hook "$f" 'not json'
  done
}

t_main "$@"
