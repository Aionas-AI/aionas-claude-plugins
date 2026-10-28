#!/usr/bin/env bash
# hooks/plan-report.sh: the Claude plan from ~/.claude.json, sent as one plan
# sample (AIO-888; the rules of the plan collector, AIO-886)
. "$(dirname "$0")/../lib/harness.sh"

HOOK="$T_PLUGIN/hooks/plan-report.sh"
T0=1792490400 # 2026-10-20T10:00:00Z
UUID=66da5747-7dd0-408b-8696-cf496cfb72d1

# claude_json BILLING ORGTYPE TIER [SEAT]: what Claude Code writes, with an
# email and a token-like field that must never leave.
claude_json() {
  local seat=null
  [ -n "${4:-}" ] && seat="\"$4\""
  cat >"$HOME/.claude.json" <<JSON
{"numStartups":3,"userID":"SECRET-USER-ID","oauthAccount":{"accountUuid":"$UUID","emailAddress":"CANARY-EMAIL@example.com","billingType":"$1","organizationType":"$2","organizationRateLimitTier":"$3","seatTier":$seat,"userRateLimitTier":null},"projects":{"/x":{"history":["a } b"]}}}
JSON
}
hook() { printf '{"session_id":"s1","hook_event_name":"SessionStart"}' | bash "$HOOK"; }
sent_plan() { sed -n 's/.*"vendor_plan_id":"\([^"]*\)".*/\1/p' "$FAKE_CURL_LOG/$(t_calls)/body"; }

test_team_premium_is_claude_codes_rule() {
  t_enroll; export AIONAS_NOW=$T0
  claude_json invoice claude_team default_claude_max_5x
  out=$(hook); t_rc 0 hook
  t_eq "" "$out" "the async hook prints nothing"
  t_eq team_premium "$(sent_plan)"
  t_eq POST "$(t_call 1 method)"
  t_eq "https://gw.example.test/cc-quota/v1/samples" "$(t_call 1 url)"
  t_contains "$(t_call 1 headers)" "Authorization: Bearer $T_ALIAS"
  t_lacks "$(t_call 1 args)" "$T_ALIAS" "the alias is never on a command line"
}

test_every_plan_maps_like_the_collector() {
  t_enroll
  local i=0 row
  while IFS='|' read -r bt ot tier seat want; do
    i=$((i + 1)); export AIONAS_NOW=$((T0 + i * 86400))
    claude_json "$bt" "$ot" "$tier" "$seat"
    hook
    t_eq "$want" "$(sent_plan)" "$ot $tier $seat"
  done <<'ROWS'
stripe_subscription|claude_pro|default_claude_ai||pro
stripe_subscription|claude_max|default_claude_max_5x||max_5x
stripe_subscription|claude_max|default_claude_max_20x||max_20x
stripe_subscription|claude_max|default_claude_something_new||max
invoice|claude_team|default_claude_ai||team_standard
invoice|claude_team|default_claude_ai|premium|team_standard
invoice|claude_team|default_claude_max_5x||team_premium
invoice|claude_enterprise|default_claude_ai||enterprise
ROWS
}

test_body_carries_only_the_plan_and_the_account_id() {
  t_enroll; export AIONAS_NOW=$T0
  claude_json invoice claude_team default_claude_max_5x
  hook
  t_eq "{\"tool\":\"claude_code\",\"source\":\"plan_usage\",\"observed_at\":\"2026-10-20T10:00:00Z\",\"account_uuid\":\"$UUID\",\"plan\":{\"vendor_plan_id\":\"team_premium\"},\"windows\":[]}" "$(t_call 1 body)"
  t_lacks "$(t_call 1 body)" CANARY-EMAIL
  t_lacks "$(t_call 1 body)" SECRET-USER-ID
}

test_once_a_day_and_again_when_the_plan_changes() {
  t_enroll; export AIONAS_NOW=$T0
  claude_json invoice claude_team default_claude_ai
  hook; hook
  t_eq 1 "$(t_calls)" "the same plan is sent once a day"
  claude_json invoice claude_team default_claude_max_5x
  hook
  t_eq 2 "$(t_calls)" "a changed plan is sent at once"
  t_eq team_premium "$(sent_plan)"
  export AIONAS_NOW=$((T0 + 86400))
  hook
  t_eq 3 "$(t_calls)" "and again the next UTC day"
}

test_a_failed_send_is_retried_next_session() {
  t_enroll; export AIONAS_NOW=$T0
  claude_json invoice claude_team default_claude_max_5x
  FAKE_CURL_STATUS=503 hook
  t_eq 1 "$(t_calls)"
  hook
  t_eq 2 "$(t_calls)" "not remembered as sent after a 503"
  hook
  t_eq 2 "$(t_calls)" "remembered after a 2xx"
}

test_nothing_sent_without_enrollment_signin_or_plan() {
  claude_json invoice claude_team default_claude_max_5x
  t_rc 0 hook
  t_eq 0 "$(t_calls)" "not enrolled: no network call"
  t_enroll
  rm -f "$HOME/.claude.json"
  t_rc 0 hook
  printf '{"numStartups":1}\n' >"$HOME/.claude.json"; hook
  claude_json api "" ""; hook
  printf 'not json' >"$HOME/.claude.json"; hook
  t_eq 0 "$(t_calls)" "no file, signed out, API key or a broken file: nothing sent"
}

test_a_malformed_account_id_is_left_out() {
  t_enroll; export AIONAS_NOW=$T0
  claude_json invoice claude_team default_claude_ai
  sed -i.bak "s/$UUID/not-an-id!/" "$HOME/.claude.json"
  hook
  t_lacks "$(t_call 1 body)" account_uuid
  t_eq team_standard "$(sent_plan)"
}

test_an_empty_field_does_not_shift_the_others() {
  t_enroll; export AIONAS_NOW=$T0
  claude_json invoice claude_team ""
  hook
  t_eq team_standard "$(sent_plan)"
  t_contains "$(t_call 1 body)" "\"account_uuid\":\"$UUID\""
}

test_claude_config_dir_is_honoured() {
  t_enroll; export AIONAS_NOW=$T0
  export CLAUDE_CONFIG_DIR="$HOME/cfg"; mkdir -p "$CLAUDE_CONFIG_DIR"
  claude_json invoice claude_team default_claude_max_5x
  mv "$HOME/.claude.json" "$CLAUDE_CONFIG_DIR/.claude.json"
  hook
  t_eq team_premium "$(sent_plan)"
}

t_main "$@"
