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

# _pr_uuid VALUE: VALUE when it matches ^[0-9a-fA-F-]{8,64}$, else nothing.
_pr_uuid() {
  case "$1" in '' | *[!0-9a-fA-F-]*) return 0 ;; esac
  if [ ${#1} -ge 8 ] && [ ${#1} -le 64 ]; then printf '%s' "$1"; fi
  return 0
}

# _pr_clean_name: stdin is the raw JSON text of a string (escapes kept). Prints
# the same kind of text with the control characters (C0, DEL, C1) and the bidi
# characters (U+061C, U+200E/F, U+202A-202E, U+2066-2069) removed, whether they
# are written as UTF-8 or as \uXXXX / \n / \t ..., spaces trimmed at both ends
# and cut to 128 characters. Byte-wise (LC_ALL=C), so it is the same in every awk.
_pr_clean_name() {
  LC_ALL=C awk '
    BEGIN { for (i = 1; i < 256; i++) ord[sprintf("%c", i)] = i; max = 128 }
    function hex4(h,   i, c, v) {
      if (h !~ /^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$/) return -1
      v = 0
      for (i = 1; i <= 4; i++) { c = index("0123456789abcdef", tolower(substr(h, i, 1))); v = v * 16 + c - 1 }
      return v
    }
    function bad(v) {
      return v < 32 || (v >= 127 && v <= 159) || v == 1564 || v == 8206 || v == 8207 ||
        (v >= 8234 && v <= 8238) || (v >= 8294 && v <= 8297)
    }
    function add(t) { tok[++nt] = t }
    { s = $0; n = length(s); i = 1
      while (i <= n) {
        c = substr(s, i, 1); b = ord[c] + 0
        if (c == "\\") {
          d = substr(s, i + 1, 1)
          if (d == "u") {
            v = hex4(substr(s, i + 2, 4))
            if (v < 0) { i += 2; continue }
            if (v >= 55296 && v <= 56319 && substr(s, i + 6, 2) == "\\u") {
              w = hex4(substr(s, i + 8, 4))
              if (w >= 56320 && w <= 57343) { add(substr(s, i, 12)); i += 12; continue }
            }
            if (v >= 55296 && v <= 57343) { i += 6; continue }
            if (!bad(v)) add(substr(s, i, 6))
            i += 6; continue
          }
          if (d == "\"" || d == "\\" || d == "/") add(c d)
          i += 2; continue
        }
        if (b < 32 || b == 127) { i++; continue }
        if (b < 128) { add(c); i++; continue }
        if (b >= 194 && b <= 223) l = 2; else if (b >= 224 && b <= 239) l = 3; else if (b >= 240 && b <= 244) l = 4; else l = 0
        if (l == 0 || i + l - 1 > n) { i++; continue }
        ok = 1
        for (k = 1; k < l; k++) { x = ord[substr(s, i + k, 1)] + 0; if (x < 128 || x > 191) ok = 0 }
        if (!ok) { i++; continue }
        b2 = ord[substr(s, i + 1, 1)] + 0; b3 = ord[substr(s, i + 2, 1)] + 0
        if (b == 194 && b2 <= 159) { i += l; continue }
        if (b == 216 && b2 == 156) { i += l; continue }
        if (b == 226 && b2 == 128 && (b3 == 142 || b3 == 143 || (b3 >= 170 && b3 <= 174))) { i += l; continue }
        if (b == 226 && b2 == 129 && b3 >= 166 && b3 <= 169) { i += l; continue }
        add(substr(s, i, l)); i += l
      }
    }
    END {
      lo = 1; hi = nt
      while (lo <= hi && tok[lo] == " ") lo++
      while (hi >= lo && tok[hi] == " ") hi--
      if (hi - lo + 1 > max) hi = lo + max - 1
      o = ""
      for (k = lo; k <= hi; k++) o = o tok[k]
      printf "%s", o
    }'
}

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
