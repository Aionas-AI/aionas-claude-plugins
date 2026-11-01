#!/usr/bin/env bash
# hooks/plan-report.sh: the Claude plan from ~/.claude.json, sent as one plan
# sample (AIO-888; the rules of the plan collector, AIO-886)
. "$(dirname "$0")/../lib/harness.sh"

HOOK="$T_PLUGIN/hooks/plan-report.sh"
T0=1792490400 # 2026-10-20T10:00:00Z
UUID=66da5747-7dd0-408b-8696-cf496cfb72d1

# claude_json BILLING ORGTYPE ORGTIER [SEAT [USERTIER [ORGUUID [ORGNAME_JSON]]]]:
# what Claude Code writes, with an email and a token-like field that must never
# leave. USERTIER: empty = null, "ABSENT" = no such key. ORGUUID / ORGNAME_JSON
# (the raw JSON text between the quotes) are written only when given.
claude_json() {
  local seat=null user=null extra=""
  [ -n "${4:-}" ] && seat="\"$4\""
  [ -n "${5:-}" ] && user="\"$5\""
  [ -n "${6:-}" ] && extra="$extra,\"organizationUuid\":\"$6\""
  [ -n "${7:-}" ] && extra="$extra,\"organizationName\":\"$7\""
  local usertier="\"userRateLimitTier\":$user,"
  [ "${5:-}" = ABSENT ] && usertier=""
  cat >"$HOME/.claude.json" <<JSON
{"numStartups":3,"userID":"SECRET-USER-ID","oauthAccount":{"accountUuid":"$UUID","emailAddress":"CANARY-EMAIL@example.com","billingType":"$1","organizationType":"$2","organizationRateLimitTier":"$3","seatTier":$seat,$usertier"displayName":"x"$extra},"projects":{"/x":{"history":["a } b"]}}}
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

# --- W25P-P1: member tier, Ultra, organization (AIO-899, AIO-900, AIO-901) ---
ORG_A=0a1b2c3d-1111-4222-8333-444455556666
ORG_B=9f8e7d6c-aaaa-4bbb-8ccc-ddddeeeeffff

test_aio899_premium_seat_is_read_from_the_members_own_tier() {
  t_enroll; export AIONAS_NOW=$T0
  # Real Team premium seat: org tier default_raven, member tier max_5x, seat team_tier_1
  claude_json invoice claude_team default_raven team_tier_1 default_claude_max_5x
  hook
  t_eq team_premium "$(sent_plan)" "premium seat"
}

test_aio899_team_without_a_member_tier_is_standard() {
  t_enroll
  export AIONAS_NOW=$T0
  claude_json invoice claude_team default_raven team_tier_1 ""
  hook
  t_eq team_standard "$(sent_plan)" "member tier null"
  export AIONAS_NOW=$((T0 + 86400))
  claude_json invoice claude_team default_raven team_tier_1 ABSENT
  hook
  t_eq 2 "$(t_calls)"
  t_eq team_standard "$(sent_plan)" "member tier absent"
}

test_aio899_max_uses_the_org_tier_when_the_member_tier_is_null() {
  t_enroll
  export AIONAS_NOW=$T0
  claude_json stripe_subscription claude_max default_claude_max_20x "" ""
  hook
  t_eq max_20x "$(sent_plan)" "Max 20x"
  export AIONAS_NOW=$((T0 + 86400))
  claude_json stripe_subscription claude_max default_claude_max_5x "" ""
  hook
  t_eq max_5x "$(sent_plan)" "Max 5x"
}

test_aio899_the_members_tier_wins_over_the_org_tier() {
  t_enroll; export AIONAS_NOW=$T0
  claude_json stripe_subscription claude_max default_claude_max_5x "" default_claude_max_20x
  hook
  t_eq max_20x "$(sent_plan)"
}

test_aio900_an_ultra_tier_string_is_max_20x() {
  t_enroll
  export AIONAS_NOW=$T0
  claude_json stripe_subscription claude_max default_claude_ultra "" ""
  hook
  t_eq max_20x "$(sent_plan)" "ultra in the org tier"
  export AIONAS_NOW=$((T0 + 86400))
  claude_json stripe_subscription claude_max default_claude_max_5x "" default_claude_ultra
  hook
  t_eq max_20x "$(sent_plan)" "ultra in the member tier"
  t_lacks "$(t_call 2 body)" ultra "no ultra plan id on the wire"
}

test_aio901_each_organization_of_one_account_sends_its_own_org() {
  t_enroll; export AIONAS_NOW=$T0
  claude_json invoice claude_team default_raven team_tier_1 "" "$ORG_A" "Acme"
  hook
  t_contains "$(t_call 1 body)" "\"account_uuid\":\"$UUID\",\"organization_uuid\":\"$ORG_A\",\"organization_name\":\"Acme\""
  t_eq team_standard "$(sent_plan)"
  # the same day, the same account, the other organization: sent at once
  claude_json stripe_subscription claude_max default_claude_max_20x "" "" "$ORG_B" "D personal"
  hook
  t_eq 2 "$(t_calls)" "a changed organization is sent at once"
  t_contains "$(t_call 2 body)" "\"organization_uuid\":\"$ORG_B\",\"organization_name\":\"D personal\""
  t_lacks "$(t_call 2 body)" "$ORG_A"
  t_lacks "$(t_call 2 body)" Acme
  t_eq max_20x "$(sent_plan)"
}

test_aio901_the_organization_name_is_cleaned_and_cut() {
  t_enroll
  export AIONAS_NOW=$T0
  # raw bidi override (U+202E) written as UTF-8, a C1 control, a \u escape of a
  # bidi isolate, a tab escape and a control escape, padded with spaces
  claude_json invoice claude_team default_raven "" "" "$ORG_A" "  Ac$(printf '\342\200\256')me\\u2066 Co$(printf '\302\205')rp\\t\\u0001  "
  hook
  t_contains "$(t_call 1 body)" "\"organization_name\":\"Acme Corp\",\"plan\"" "cleaned, in place"
  t_lacks "$(t_call 1 body)" "$(printf '\342\200\256')"
  t_lacks "$(t_call 1 body)" "2066"
  export AIONAS_NOW=$((T0 + 86400))
  local long; long=$(printf 'a%.0s' $(seq 1 200))
  claude_json invoice claude_team default_raven "" "" "$ORG_A" "$long"
  hook
  t_contains "$(t_call 2 body)" "\"organization_name\":\"$(printf 'a%.0s' $(seq 1 128))\""
  t_lacks "$(t_call 2 body)" "$(printf 'a%.0s' $(seq 1 129))"
  export AIONAS_NOW=$((T0 + 2 * 86400))
  claude_json invoice claude_team default_raven "" "" "$ORG_A" "$(printf 'é%.0s' $(seq 1 130))"
  hook
  t_contains "$(t_call 3 body)" "\"organization_name\":\"$(printf 'é%.0s' $(seq 1 128))\"" "128 characters, not bytes"
  t_lacks "$(t_call 3 body)" "$(printf 'é%.0s' $(seq 1 129))"
}

test_aio901_an_empty_name_and_a_malformed_uuid_are_left_out() {
  t_enroll
  export AIONAS_NOW=$T0
  claude_json invoice claude_team default_raven "" "" "not-an-org!" "  $(printf '\342\200\256') "
  hook
  t_lacks "$(t_call 1 body)" organization_uuid
  t_lacks "$(t_call 1 body)" organization_name
  t_eq team_standard "$(sent_plan)"
}

test_aio901_no_organization_fields_leaves_the_body_as_before() {
  t_enroll; export AIONAS_NOW=$T0
  claude_json invoice claude_team default_claude_max_5x
  hook
  t_lacks "$(t_call 1 body)" organization
  t_eq "{\"tool\":\"claude_code\",\"source\":\"plan_usage\",\"observed_at\":\"2026-10-20T10:00:00Z\",\"account_uuid\":\"$UUID\",\"plan\":{\"vendor_plan_id\":\"team_premium\"},\"windows\":[]}" "$(t_call 1 body)"
}

t_main "$@"
