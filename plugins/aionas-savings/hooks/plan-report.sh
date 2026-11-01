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
# W25P-P1: the tier is the member's own (userRateLimitTier, else the
# organization's: AIO-899); a tier containing "ultra" is max_20x (AIO-900);
# the sample also names the Claude organization it came from, its id and its
# cleaned name (AIO-901).
set -u
. "$(dirname "$0")/../lib/aionas.sh" 2>/dev/null || exit 0
cat >/dev/null 2>&1

# _pr_uuid and _pr_clean_name live in lib/claude-account.sh (shared with usage-probe).
. "$AIONAS_LIB/claude-account.sh" 2>/dev/null || exit 0

aionas_enroll_has_alias || exit 0
cj="${CLAUDE_CONFIG_DIR:-$(aionas_home)}/.claude.json"
[ -f "$cj" ] || exit 0

flat=$(aionas_json_flatten "$cj" 2>/dev/null) || exit 0
fields=$(printf '%s\n' "$flat" | awk -F '\t' '
  $1 == "oauthAccount.billingType" { bt = $3 }
  $1 == "oauthAccount.organizationType" { ot = $3 }
  $1 == "oauthAccount.organizationRateLimitTier" { otier = $3 }
  $1 == "oauthAccount.userRateLimitTier" && $2 == "s" { utier = $3 }
  $1 == "oauthAccount.accountUuid" { u = $3 }
  $1 == "oauthAccount.organizationUuid" && $2 == "s" { ou = $3 }
  END { printf "%s\037%s\037%s\037%s\037%s\037%s\n", bt, ot, otier, utier, u, ou }') || exit 0
# \037, not a tab: a tab is IFS whitespace, so an empty field would shift the rest.
IFS="$(printf '\037')" read -r bt ot otier utier acct org <<EOF
$fields
EOF
# The member's own tier, else the organization's. Claude Code's rateLimitTier
# is the member's own; a Team organization's own tier is default_raven.
tier=$otier
[ -n "$utier" ] && tier=$utier

case "$bt" in api | none) exit 0 ;; esac
# The same rules as the plan collector (aionas-plan-usage.sh, AIO-886). Team
# premium is Claude Code's own rule (isTeamPremiumSubscriber): a Team account
# whose own tier is Max 5x; seatTier is not used. Ultra (the renamed Max 20x)
# keeps the plan id max_20x.
case "$ot" in
  claude_max)
    case "$tier" in *ultra* | *20x*) plan=max_20x ;; *5x*) plan=max_5x ;; *) plan=max ;; esac ;;
  claude_pro) plan=pro ;;
  claude_team)
    if [ "$tier" = default_claude_max_5x ]; then plan=team_premium; else plan=team_standard; fi ;;
  claude_enterprise) plan=enterprise ;;
  *) exit 0 ;;
esac
# An id only when it looks like one (the gateway's own check).
acct=$(_pr_uuid "$acct")
org=$(_pr_uuid "$org")
# The organization's name: control and bidi characters dropped, trimmed, cut to
# 128 characters (the gateway's own rule); left out when nothing is left.
orgname=$(printf '%s\n' "$flat" | awk -F '\t' '$1 == "oauthAccount.organizationName" && $2 == "s" { print $3; exit }' | _pr_clean_name)

dir=$(aionas_savings_dir)
aionas_mkdir "$dir" || exit 0
last="$dir/plan-report.last"
day=$(aionas_day_utc)
# The organization is part of the key: the same account signing in to another
# organization is a different sample, sent at once.
key="$plan|$acct|$org|$orgname"
if [ -f "$last" ] && [ "$(cat "$last" 2>/dev/null)" = "$key|$day" ]; then exit 0; fi
aionas_lock_try plan-report 30 || exit 0

t=$(aionas_now)
observed=$(date -u -r "$t" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$t" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
account=""
[ -n "$acct" ] && account=",\"account_uuid\":\"$acct\""
[ -n "$org" ] && account="$account,\"organization_uuid\":\"$org\""
[ -n "$orgname" ] && account="$account,\"organization_name\":\"$orgname\""
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
