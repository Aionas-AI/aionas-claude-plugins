#!/usr/bin/env bash
# hooks/session-event.sh (SessionStart) and hooks/precompact-event.sh
# (PreCompact): one metadata event each to POST /enroll/v1/sessions/events
# (AIO-925, wave 27). Field names checked against
# https://code.claude.com/docs/en/hooks on 2026-11-03: SessionStart input has
# session_id and source (startup|resume|clear|compact|fork); PreCompact input
# has session_id, trigger (manual|auto) and custom_instructions (never sent).
. "$(dirname "$0")/../lib/harness.sh"
H="$T_PLUGIN/hooks"
T0=1792490400 # 2026-10-20T10:00:00Z
SESSION=3a1f6c52-0b9e-4c43-9d57-6f2d1e8b7a90
SECRET="SECRET-INSTRUCTIONS-TEXT"

start_in() { printf '{"session_id":"%s","transcript_path":"/Users/x/.claude/secret-project.jsonl","cwd":"/Users/x/secret-project","hook_event_name":"SessionStart","source":"%s","model":"claude-opus-5"}' "$SESSION" "${1:-startup}"; }
compact_in() { printf '{"session_id":"%s","transcript_path":"/Users/x/.claude/secret-project.jsonl","cwd":"/Users/x/secret-project","hook_event_name":"PreCompact","trigger":"%s","custom_instructions":%s}' "$SESSION" "${1:-manual}" "${2:-null}"; }
run() { printf '%s' "$2" | bash "$H/$1"; }

test_session_start_sends_the_exact_body() {
  t_enroll; export AIONAS_NOW=$T0
  t_eq "" "$(run session-event.sh "$(start_in resume)")" "silent"
  t_eq 1 "$(t_calls)"
  t_eq POST "$(t_call 1 method)"
  t_eq https://gw.example.test/enroll/v1/sessions/events "$(t_call 1 url)"
  t_contains "$(t_call 1 headers)" "Authorization: Bearer $T_ALIAS"
  t_contains "$(t_call 1 headers)" "Content-Type: application/json"
  t_eq "{\"session_id\":\"$SESSION\",\"event\":\"session_start\",\"source\":\"resume\",\"ts\":\"2026-10-20T10:00:00Z\",\"plugin_version\":\"$(aionas_plugin_version)\"}" "$(t_call 1 body)"
}

test_every_session_start_source_is_sent_and_others_are_not() {
  t_enroll; export AIONAS_NOW=$T0
  local s
  for s in startup resume clear compact fork; do
    t_rc 0 run session-event.sh "$(start_in $s)"
  done
  t_eq 5 "$(t_calls)"
  t_contains "$(t_call 4 body)" '"source":"compact"'
  t_contains "$(t_call 5 body)" '"source":"fork"'
  t_rc 0 run session-event.sh "$(start_in 'weird"x')"
  t_rc 0 run session-event.sh '{"session_id":"'$SESSION'","hook_event_name":"SessionStart"}'
  t_eq 5 "$(t_calls)" "an unknown or missing source is not sent"
}

test_pre_compact_sends_the_exact_body_and_never_the_instructions() {
  t_enroll; export AIONAS_NOW=$T0
  t_eq "" "$(run precompact-event.sh "$(compact_in manual "\"$SECRET\"")")"
  t_eq 1 "$(t_calls)"
  t_eq https://gw.example.test/enroll/v1/sessions/events "$(t_call 1 url)"
  t_eq "{\"session_id\":\"$SESSION\",\"event\":\"pre_compact\",\"trigger\":\"manual\",\"ts\":\"2026-10-20T10:00:00Z\",\"plugin_version\":\"$(aionas_plugin_version)\"}" "$(t_call 1 body)"
  t_rc 0 run precompact-event.sh "$(compact_in auto)"
  t_contains "$(t_call 2 body)" '"trigger":"auto"'
  t_rc 0 run precompact-event.sh "$(compact_in sometimes)"
  t_eq 2 "$(t_calls)" "an unknown trigger is not sent"
}

# The body holds only the fields the server accepts; anything else is a 400.
test_body_has_only_the_listed_fields_and_no_content() {
  t_enroll; export AIONAS_NOW=$T0
  run session-event.sh "$(start_in startup)"
  run precompact-event.sh "$(compact_in manual "\"$SECRET\"")"
  local n k body
  for n in 1 2; do
    body=$(t_call $n body)
    for k in $(aionas_json_flatten <<<"$body" | cut -f1); do
      case "$k" in session_id | event | source | trigger | ts | plugin_version) ;; *) t_fail "call $n: unexpected field $k" ;; esac
    done
    t_lacks "$body" secret-project "no path"
    t_lacks "$body" "$SECRET" "no instructions"
    t_lacks "$body" claude-opus "no model"
    t_lacks "$body" "$T_ALIAS" "no alias"
  done
  t_lacks "$(cat "$FAKE_CURL_LOG"/*/args)" "$T_ALIAS" "the alias is never on a command line"
}

test_one_try_and_no_retry() {
  t_enroll
  run session-event.sh "$(start_in)"
  t_contains "$(t_call 1 args | tr "\n" " ")" "--retry 0 "
  FAKE_CURL_STATUS=503 run precompact-event.sh "$(compact_in)"
  t_eq 2 "$(t_calls)" "a refusal or a failure is not retried"
}

test_unreachable_gateway_exits_0() {
  t_enroll
  export FAKE_CURL_EXIT=28
  t_rc 0 run session-event.sh "$(start_in)"
  t_rc 0 run precompact-event.sh "$(compact_in)"
  t_eq 2 "$(t_calls)" "one try each"
}

test_not_enrolled_sends_nothing() {
  t_unenroll
  t_rc 0 run session-event.sh "$(start_in)"
  t_rc 0 run precompact-event.sh "$(compact_in)"
  t_eq 0 "$(t_calls)"
}

test_no_session_id_or_a_bad_one_sends_nothing() {
  t_enroll
  t_rc 0 run session-event.sh '{"hook_event_name":"SessionStart","source":"startup"}'
  t_rc 0 run session-event.sh '{"session_id":"a b/../c","source":"startup"}'
  t_rc 0 run precompact-event.sh '{"trigger":"manual"}'
  t_rc 0 run precompact-event.sh ''
  t_eq 0 "$(t_calls)"
}

# W25-e: the usage probe's child runs every hook again; each one ends at once.
test_the_usage_probe_child_does_nothing() {
  t_enroll
  local out
  out=$(printf '%s' "$(start_in)" | AIONAS_USAGE_PROBE=1 bash "$H/session-event.sh" 2>&1); t_eq "" "$out"
  out=$(printf '%s' "$(compact_in)" | AIONAS_USAGE_PROBE=1 bash "$H/precompact-event.sh" 2>&1); t_eq "" "$out"
  t_eq 0 "$(t_calls)"
  t_ok test ! -e "$(aionas_savings_dir)"
}

t_main "$@"
