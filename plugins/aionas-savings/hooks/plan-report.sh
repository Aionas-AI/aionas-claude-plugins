#!/usr/bin/env bash
# aionas-savings hook: plan-report (SessionStart, async). Owner: AIO-888.
# Reads which Claude plan this computer is signed in to from Claude Code's
# own ~/.claude.json (billing type, organization type, rate-limit tier and the
# opaque account id, nothing else) and sends it to Aionas as one plan sample,
# the same body the one install's plan collector sends. The plugin updates
# itself, so a detection fix reaches every computer without a new install
# (Tal 2026-10-28).
# Sent when the plan or the account changed, else at most once a UTC day; a
# failed send is retried at the next session start. Not enrolled, signed out
# or an API key: nothing is sent. Prints nothing, exits 0.
set -u
. "$(dirname "$0")/../lib/aionas.sh" 2>/dev/null || exit 0
cat >/dev/null 2>&1

aionas_enroll_has_alias || exit 0
cj="${CLAUDE_CONFIG_DIR:-$(aionas_home)}/.claude.json"
[ -f "$cj" ] || exit 0

fields=$(aionas_json_flatten "$cj" 2>/dev/null | awk -F '\t' '
  $1 == "oauthAccount.billingType" { bt = $3 }
  $1 == "oauthAccount.organizationType" { ot = $3 }
  $1 == "oauthAccount.organizationRateLimitTier" { tier = $3 }
  $1 == "oauthAccount.accountUuid" { u = $3 }
  END { printf "%s\037%s\037%s\037%s\n", bt, ot, tier, u }') || exit 0
# \037, not a tab: a tab is IFS whitespace, so an empty field would shift the rest.
IFS="$(printf '\037')" read -r bt ot tier acct <<EOF
$fields
EOF

case "$bt" in api | none) exit 0 ;; esac
# The same rules as the plan collector (aionas-plan-usage.sh, AIO-886). Team
# premium is Claude Code's own rule (isTeamPremiumSubscriber): a Team account
# on the Max 5x rate-limit tier; seatTier is Enterprise-only.
case "$ot" in
  claude_max)
    case "$tier" in *20x*) plan=max_20x ;; *5x*) plan=max_5x ;; *) plan=max ;; esac ;;
  claude_pro) plan=pro ;;
  claude_team)
    if [ "$tier" = default_claude_max_5x ]; then plan=team_premium; else plan=team_standard; fi ;;
  claude_enterprise) plan=enterprise ;;
  *) exit 0 ;;
esac
# The account id only when it looks like one (the gateway's own check).
case "$acct" in '' | *[!0-9a-fA-F-]*) acct="" ;; esac
if [ ${#acct} -lt 8 ] || [ ${#acct} -gt 64 ]; then acct=""; fi

dir=$(aionas_savings_dir)
aionas_mkdir "$dir" || exit 0
last="$dir/plan-report.last"
day=$(aionas_day_utc)
key="$plan|$acct"
if [ -f "$last" ] && [ "$(cat "$last" 2>/dev/null)" = "$key|$day" ]; then exit 0; fi
aionas_lock_try plan-report 30 || exit 0

t=$(aionas_now)
observed=$(date -u -r "$t" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$t" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
account=""
[ -n "$acct" ] && account=",\"account_uuid\":\"$acct\""
body="$dir/.plan-report.$$"
out="$dir/.plan-report.out.$$"
printf '{"tool":"claude_code","source":"plan_usage","observed_at":"%s"%s,"plan":{"vendor_plan_id":"%s"},"windows":[]}' \
  "$observed" "$account" "$plan" >"$body"
if aionas_http POST /cc-quota/v1/samples "$body" "$out" >/dev/null 2>&1; then
  printf '%s\n' "$key|$day" | aionas_write_atomic "$last"
fi
rm -f "$body" "$out"
aionas_lock_release plan-report
exit 0
