#!/usr/bin/env bash
# AIO-1077 (wave 33): the plugin under Cursor. Cursor's Third-Party Imports
# runs this plugin's hooks with its own payloads (tests/fixtures/cursor/,
# recorded 2026-11-19). One client detection (aionas_client), only the hooks
# that fit Cursor run there, the Stop hook no longer holds a Cursor turn for
# 15 s, and what is counted under Cursor goes to queues of its own that are
# sent, tagged "client":"cursor", only to a gateway whose policy lists the
# capability. Claude Code's wire stays the 0.6.1 one byte for byte.
. "$(dirname "$0")/../lib/harness.sh"
unset CURSOR_VERSION CLAUDECODE
FIX="$T_REPO/tests/fixtures/cursor"
H="$T_PLUGIN/hooks"
T0=1792490400 # 2026-10-20T10:00:00Z
CSID=00000000-0000-4000-8000-0000000c0001 # session id in the recorded payloads
CGEN=00000000-0000-4000-8000-0000000c0002 # generation id of the recorded prompt
CC_START='{"session_id":"cc-1","hook_event_name":"SessionStart","source":"startup","cwd":"/tmp"}'
UUID=66da5747-7dd0-408b-8696-cf496cfb72d1

# cursor_start [EXTRA_JSON]: the recorded sessionStart, plus top-level keys.
cursor_start() { sed "s|\"transcript_path\": null|\"transcript_path\": null${1:+, $1}|" "$FIX/session-start.json"; }
# cursor_stop TRANSCRIPT: the recorded stop, with a transcript path.
cursor_stop() { sed "s|__TRANSCRIPT__|$1|" "$FIX/stop.json"; }
# ms: wall clock in milliseconds.
ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time() * 1000'; }
# caps NAME...: a cached policy (handoff on) listing these gateway capabilities.
caps() {
  mkdir -p "$(aionas_savings_dir)"
  { printf 'V\t1\nF\t1\nM\thandoff\ton\t0\t1\t1\t0\n'; for c in "$@"; do printf 'C\t%s\n' "$c"; done; } >"$(aionas_savings_dir)/policy.cache"
}
CD() { echo "$(aionas_savings_dir)/counters"; }
RD() { echo "$(aionas_savings_dir)/requests"; }
claude_login() {
  printf '{"oauthAccount":{"accountUuid":"%s","billingType":"invoice","organizationType":"claude_team","organizationRateLimitTier":"default_claude_max_5x"}}\n' "$UUID" >"$HOME/.claude.json"
}

# --- detection --------------------------------------------------------------

test_client_is_cursor_for_every_recorded_cursor_payload() {
  local f
  for f in session-start.json before-submit-prompt.json stop.json; do
    t_eq cursor "$(aionas_client_of "$(cat "$FIX/$f")")" "$f"
  done
}

test_client_camelcase_event_alone_is_cursor() {
  t_eq cursor "$(aionas_client_of '{"session_id":"x","hook_event_name":"stop"}')"
  t_eq cursor "$(aionas_client_of '{"hook_event_name": "beforeSubmitPrompt"}')"
  t_eq cursor "$(aionas_client_of '{"session_id":"x","cursor_version":"3.23.23","hook_event_name":"Stop"}')" "cursor_version wins"
}

test_client_claude_code_payload_wins_over_cursor_environment() {
  t_eq claude_code "$(aionas_client_of "$CC_START")"
  export CURSOR_VERSION=3.23.23
  t_eq claude_code "$(aionas_client_of "$CC_START")" "Claude Code started in a Cursor terminal"
  t_eq claude_code "$(aionas_client_of '{"session_id":"x","hook_event_name":"UserPromptSubmit","prompt":"see \"cursor_version\": \"1\", \"hook_event_name\": \"stop\""}')" \
    "a prompt quoting Cursor's keys is not a Cursor payload"
  t_eq claude_code "$(aionas_client_of '{}')" "a payload that cannot tell: claude_code"
  t_eq claude_code "$(aionas_client_of 'not json "cursor_version"')"
}

test_client_environment_is_the_fallback_only_without_a_payload() {
  t_eq claude_code "$(aionas_client_of '')"
  t_eq claude_code "$(aionas_client)"
  t_eq cursor "$(CURSOR_VERSION=3.23.23 aionas_client_of '')"
  t_eq claude_code "$(CURSOR_VERSION=3.23.23 CLAUDECODE=1 aionas_client_of '')"
}

# --- which hooks run under Cursor --------------------------------------------

test_cursor_skips_plan_report_claude_code_sends() {
  t_enroll; export AIONAS_NOW=$T0; claude_login
  t_eq "" "$(cursor_start | bash "$H/plan-report.sh")"
  t_eq 0 "$(t_calls)" "no plan sample under Cursor"
  printf '%s' "$CC_START" | bash "$H/plan-report.sh"
  t_eq 1 "$(t_calls)" "Claude Code still sends its plan"
}

test_cursor_skips_daily_scan_claude_code_scans() {
  t_enroll; export AIONAS_NOW=$T0
  local bin; bin=$(mktemp -d "$T_ROOT/scan.XXXXXX")/aionas-scan
  printf '#!/bin/sh\nexit 0\n' >"$bin"; chmod +x "$bin"; export AIONAS_SCAN_BIN=$bin
  t_eq "" "$(cursor_start | bash "$H/daily-scan.sh")"
  t_not test -f "$(aionas_savings_dir)/scan.day"
  printf '%s' "$CC_START" | bash "$H/daily-scan.sh"
  t_ok test -f "$(aionas_savings_dir)/scan.day"
}

test_cursor_skips_effort_window_claude_code_cleans_up() {
  mkdir -p "$(aionas_savings_dir)"
  printf '1\t2\txhigh\n' >"$(aionas_savings_dir)/effort-window"
  t_eq "" "$(cursor_start | bash "$H/effort-window.sh")"
  t_ok test -f "$(aionas_savings_dir)/effort-window"
  printf '%s' "$CC_START" | bash "$H/effort-window.sh"
  t_not test -f "$(aionas_savings_dir)/effort-window"
}

test_cursor_skips_unused_services_and_its_notice() {
  t_eq "" "$(cursor_start '"cwd": "/tmp"' | bash "$H/unused-services.sh")"
  t_not test -d "$(aionas_savings_dir)/unused" # Claude Code settings are never touched under Cursor
  printf '%s' "$CC_START" | bash "$H/unused-services.sh"
  t_ok test -d "$(aionas_savings_dir)/unused"
  printf 'mcp\tsrv1\t30\n' >"$(aionas_savings_dir)/unused/notice.pending"
  t_eq "" "$(cursor_start | bash "$H/unused-services-notice.sh")"
  t_ok test -s "$(aionas_savings_dir)/unused/notice.pending"
  t_contains "$(printf '%s' "$CC_START" | bash "$H/unused-services-notice.sh")" systemMessage
}

test_cursor_skips_usage_probe_claude_code_runs_it() {
  t_enroll; export AIONAS_NOW=$T0 TZ=UTC; claude_login
  mkdir -p "$HOME/.local/bin"
  printf '#!/bin/sh\n: >"%s/claude-ran"\n' "$HOME" >"$HOME/.local/bin/claude"; chmod +x "$HOME/.local/bin/claude"
  t_eq "" "$(cursor_start | bash "$H/usage-probe.sh")"
  t_not test -f "$HOME/claude-ran" # claude -p /usage is never started under Cursor
  printf '%s' "$CC_START" | bash "$H/usage-probe.sh"
  t_ok test -f "$HOME/claude-ran"
}

test_cursor_skips_handoff_cancel_claude_code_cancels() {
  mkdir -p "$(aionas_savings_dir)/handoff"
  echo tok >"$(aionas_savings_dir)/handoff/$CSID.armed"
  t_eq "" "$(bash "$H/handoff-cancel.sh" <"$FIX/before-submit-prompt.json")"
  t_ok test -f "$(aionas_savings_dir)/handoff/$CSID.armed"
  printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","prompt":"x"}' "$CSID" | bash "$H/handoff-cancel.sh"
  t_not test -f "$(aionas_savings_dir)/handoff/$CSID.armed"
}

# The 15 s stall (Cursor hooks log 2026-11-19: stop 09:39:40.205 -> 09:39:55.244):
# Cursor holds its turn until handoff-arm.sh exits, and its transcript never
# has Claude Code's usage numbers, so the settle wait ran out every turn.
test_cursor_stop_ends_under_one_second_with_the_default_settle_wait() {
  caps
  unset AIONAS_HANDOFF_SETTLE_SECONDS
  local tr="$HOME/cursor-transcript.jsonl" in t1 t2 out
  cp "$FIX/transcript.jsonl" "$tr"
  in=$(cursor_stop "$tr")
  t1=$(ms); out=$(printf '%s' "$in" | bash "$H/handoff-arm.sh"); local rc=$?; t2=$(ms)
  t_eq 0 "$rc"
  t_eq "" "$out"
  [ $((t2 - t1)) -lt 1000 ] || t_fail "the stop step took $((t2 - t1)) ms"
  t_not test -e "$(aionas_savings_dir)/handoff/$CSID.state"
}

test_every_skipped_hook_is_silent_and_fast_under_cursor() {
  t_enroll; claude_login
  local f t1 t2 out
  for f in usage-probe.sh plan-report.sh effort-window.sh daily-scan.sh unused-services.sh unused-services-notice.sh; do
    t1=$(ms); out=$(cursor_start | bash "$H/$f" 2>&1); t2=$(ms)
    t_eq "" "$out" "$f prints nothing"
    [ $((t2 - t1)) -lt 1000 ] || t_fail "$f took $((t2 - t1)) ms under Cursor"
  done
  for f in handoff-cancel.sh request-prompt.sh; do
    out=$(bash "$H/$f" <"$FIX/before-submit-prompt.json" 2>&1); t_eq "" "$out" "$f prints nothing"
  done
  t_eq 0 "$(t_calls)" "no request from a skipped hook"
}

test_no_hook_ever_returns_a_permission_decision() {
  local f
  for f in "$H"/*.sh; do
    t_lacks "$(grep -v '^ *#' "$f")" '"permission"' "$(basename "$f")"
    t_lacks "$(grep -v '^ *#' "$f")" 'permissionDecision' "$(basename "$f")"
  done
}

# --- per-prompt records ---------------------------------------------------------

test_request_prompt_takes_cursors_generation_id_and_hands_the_payload_on() {
  bash "$H/request-prompt.sh" <"$FIX/before-submit-prompt.json"
  t_eq "$CGEN" "$(cat "$(RD)/prompt.$CSID")"
  printf '{"session_id":"cc-1","prompt_id":"p-77","hook_event_name":"UserPromptSubmit","prompt":"x"}' | bash "$H/request-prompt.sh"
  t_eq p-77 "$(cat "$(RD)/prompt.cc-1")" "Claude Code unchanged"
}

test_cursor_request_marks_wait_for_requests_client() {
  t_enroll; export AIONAS_NOW=$T0 FAKE_CURL_STATUS=200
  aionas_request_prompt cc-1 p-1
  aionas_request_mark cc-1 handoff "" 4000
  _AIONAS_CLIENT=cursor aionas_request_prompt "$CSID" "$CGEN"
  _AIONAS_CLIENT=cursor aionas_request_mark "$CSID" handoff "" 1234
  t_eq 1 "$(ls "$(RD)/cursor/spool" | grep -c '\.ev$')"
  t_eq 1 "$(ls "$(RD)/spool" | grep -c '\.ev$')"
  caps
  t_rc 0 aionas_requests_flush
  t_eq 1 "$(t_calls)" "only Claude Code's record goes to an older gateway"
  t_eq "{\"session_id\":\"cc-1\",\"prompt_id\":\"p-1\",\"method\":\"handoff\",\"ts\":\"2026-10-20T10:00:00Z\",\"plugin_version\":\"$(aionas_plugin_version)\",\"tokens\":4000}" "$(t_call 1 body)"
  t_eq 1 "$(ls "$(RD)/cursor/spool" | grep -c '\.ev$')" "kept, not sent and not dropped"
  caps requests_client
  t_rc 0 aionas_requests_flush
  t_eq 2 "$(t_calls)"
  t_eq "{\"session_id\":\"$CSID\",\"prompt_id\":\"$CGEN\",\"method\":\"handoff\",\"ts\":\"2026-10-20T10:00:00Z\",\"plugin_version\":\"$(aionas_plugin_version)\",\"tokens\":1234,\"client\":\"cursor\"}" "$(t_call 2 body)"
  t_eq 0 "$(ls "$(RD)/cursor/spool" | grep -c '\.ev$')"
}

# --- counters --------------------------------------------------------------------

test_cursor_counts_go_to_a_queue_of_their_own() {
  # write-minimum.sh runs under Cursor (it fits): its count is Cursor's.
  cursor_start | bash "$H/write-minimum.sh" >/dev/null
  t_eq 0 "$(ls "$(CD)/spool" 2>/dev/null | grep -c '\.ev$')" "nothing in Claude Code's queue"
  t_eq "$(printf 'write_minimum\tfired')" "$(cut -f2,3 "$(CD)"/cursor/spool/*.ev)"
  t_eq 4 "$(awk -F '\t' '{ print NF }' "$(CD)"/cursor/spool/*.ev)" "four fields, like Claude Code's lines"
  printf '%s' "$CC_START" | bash "$H/write-minimum.sh" >/dev/null
  t_eq "$(printf 'write_minimum\tfired')" "$(cut -f2,3 "$(CD)"/spool/*.ev)"
  t_eq 1 "$(ls "$(CD)/cursor/spool" | grep -c '\.ev$')"
}

# An older gateway (no capabilities): the body is the 0.6.1 one, Cursor's rows stay.
test_counters_old_gateway_gets_the_0_6_1_body_and_cursor_rows_are_kept() {
  t_enroll; export AIONAS_NOW=$T0 FAKE_CURL_STATUS=200
  aionas_counter_inc handoff fired 2
  _AIONAS_CLIENT=cursor aionas_counter_inc write_minimum fired 3
  t_rc 0 aionas_counters_flush
  t_eq 1 "$(t_calls)"
  t_eq "{\"plugin_version\":\"$(aionas_plugin_version)\",\"counters\":[{\"day\":\"2026-10-20\",\"method_id\":\"handoff\",\"counter\":\"fired\",\"value\":2}]}" "$(t_call 1 body)"
  t_eq "$(printf '2026-10-20\twrite_minimum\tfired\t3')" "$(awk -F '\t' 'NF == 4' "$(CD)/cursor/totals.tsv")" "kept locally"
  t_not test -f "$(CD)/cursor/dropped"
  t_eq "$(printf '2026-10-20\thandoff\tfired\t2')" "$(awk -F '\t' 'NF == 4' "$(CD)/totals.tsv")" "never mixed into Claude Code's"
  # Only Cursor rows, still an older gateway: no request at all.
  export AIONAS_NOW=$((T0 + 3600))
  _AIONAS_CLIENT=cursor aionas_counter_inc write_minimum fired
  aionas_counters_flush
  t_eq 1 "$(t_calls)"
  t_eq "$(printf '2026-10-20\twrite_minimum\tfired\t4')" "$(awk -F '\t' 'NF == 4' "$(CD)/cursor/totals.tsv")"
}

test_counters_send_cursor_rows_tagged_when_the_gateway_lists_counters_client() {
  t_enroll; export AIONAS_NOW=$T0 FAKE_CURL_STATUS=200
  caps counters_client requests_client limit_guard
  aionas_counter_inc handoff fired 2
  _AIONAS_CLIENT=cursor aionas_counter_inc write_minimum fired 3
  _AIONAS_CLIENT=cursor aionas_counter_inc write_minimum skipped
  t_rc 0 aionas_counters_flush
  t_eq 2 "$(t_calls)"
  t_eq "{\"plugin_version\":\"$(aionas_plugin_version)\",\"counters\":[{\"day\":\"2026-10-20\",\"method_id\":\"handoff\",\"counter\":\"fired\",\"value\":2}]}" "$(t_call 1 body)" "Claude Code's rows carry no client"
  t_eq "{\"plugin_version\":\"$(aionas_plugin_version)\",\"counters\":[{\"day\":\"2026-10-20\",\"method_id\":\"write_minimum\",\"counter\":\"fired\",\"value\":3,\"client\":\"cursor\"},{\"day\":\"2026-10-20\",\"method_id\":\"write_minimum\",\"counter\":\"skipped\",\"value\":1,\"client\":\"cursor\"}]}" "$(t_call 2 body)"
  t_eq https://gw.example.test/enroll/v1/savings/counters "$(t_call 2 url)"
  t_ok cmp -s "$(CD)/cursor/pending.tsv" "$(CD)/cursor/pending.tsv.ok"
}

test_counters_cursor_rows_refused_are_dropped_from_cursors_queue_only() {
  t_enroll; export AIONAS_NOW=$T0
  caps counters_client
  _AIONAS_CLIENT=cursor aionas_counter_inc write_minimum fired
  export FAKE_CURL_STATUS=400
  t_rc 5 aionas_counters_flush
  t_eq 1 "$(cat "$(CD)/cursor/dropped")"
  t_not test -f "$(CD)/dropped"
}

test_counters_no_cursor_send_after_claude_code_send_failed() {
  t_enroll; export AIONAS_NOW=$T0 FAKE_CURL_EXIT=28
  caps counters_client
  aionas_counter_inc handoff fired
  _AIONAS_CLIENT=cursor aionas_counter_inc write_minimum fired
  t_rc 1 aionas_counters_flush
  t_eq 1 "$(t_calls)" "one try, then the rest waits"
}

# --- capabilities in the policy cache ------------------------------------------------

test_policy_cache_keeps_valid_capabilities_only() {
  t_enroll; export FAKE_CURL_STATUS=200 FAKE_CURL_BODY="$FIX/policy-capabilities.json"
  t_rc 0 aionas_policy_sync
  t_eq "$(printf 'C\tcounters_client\nC\trequests_client\nC\tlimit_guard')" "$(grep '^C' "$(aionas_savings_dir)/policy.cache")"
  t_ok aionas_policy_has_capability counters_client
  t_ok aionas_policy_has_capability requests_client
  t_not aionas_policy_has_capability Bad-Name
  t_not aionas_policy_has_capability session_git_events
  t_eq on "$(aionas_policy_state handoff)" "methods read as before"
  export FAKE_CURL_BODY="$T_REPO/tests/fixtures/policy.json"
  t_rc 0 aionas_policy_sync
  t_eq "" "$(grep '^C' "$(aionas_savings_dir)/policy.cache")" "an older gateway lists none"
  t_not aionas_policy_has_capability counters_client
}

t_main "$@"
