#!/usr/bin/env bash
# aionas-savings hook: noisy-command guard (PreToolUse on Bash). Owner: AIO-860.
#
# A simple command that a rule in rules/guard-store.tsv names is rewritten:
#   quiet rules  to the quiet form, e.g. "git log" -> "git log -n 30 --oneline"
#   cap rules    (cat, grep, sed) are left as they are; posttool-store.sh
#                caps a successful run's output at about cap_tokens
# Every rewrite starts with "AIONAS_GUARD=<rule_id> " so the transcript shows
# which rule fired (a cap says it in its "[aionas-guard: capped <rule>" line). A failing run keeps its full output: Claude Code reports a
# failed Bash call through PostToolUseFailure, which nothing here touches.
#
# Part of the output_trim method (AIO-883) with posttool-store.sh: off unless
# the organization turns it on.
#
# Bypass: a command that starts with AIONAS_FULL=1 runs unchanged and one
# "bypass" counter is queued. When the organization blocked self-override of
# output_trim, the guard still applies and tells the model to ask with
# /aionas-bypass (which becomes a request for approval).
#
# Prints nothing and exits 0 whenever it has nothing to change. Only counters
# (numbers) are queued; the command itself is never stored or sent.
. "$(dirname "$0")/../lib/aionas.sh" || exit 0
. "$(dirname "$0")/pretool-guard.lib" || exit 0

tmp=$(mktemp -d "${TMPDIR:-/tmp}/aionas-guard.XXXXXX") || exit 0
trap 'rm -f "$tmp/in" "$tmp/flat" "$tmp/cmd" "$tmp/new"; rmdir "$tmp" 2>/dev/null' EXIT
cat >"$tmp/in" 2>/dev/null
aionas_json_flatten "$tmp/in" >"$tmp/flat" 2>/dev/null || exit 0
[ "$(aionas_json_get tool_name <"$tmp/flat")" = Bash ] || exit 0
aionas_json_get tool_input.command <"$tmp/flat" >"$tmp/cmd" || exit 0
sid=$(aionas_json_get session_id <"$tmp/flat")

IFS=$'\037' read -r status rule kind newcmd _gid _prog _full < <(aionas_gs_match "$tmp/cmd")
case "$status" in match | bypass) ;; *) exit 0 ;; esac

aionas_policy_active output_trim "$sid" || exit 0
# A cap rule never rewrites the command: posttool-store.sh cuts a successful
# run's output and counts it (an AIONAS_GUARD= prefix would stop the person's
# allow rules such as Bash(cat:*) from matching).
[ "$kind" = quiet ] || exit 0

note=""
if [ "$status" = bypass ]; then
  if aionas_policy_self_override_allowed output_trim "$sid"; then
    aionas_counter_inc output_trim bypass
    exit 0
  fi
  note="AIONAS_FULL=1 is not available for output_trim: the organization blocked self-override. To ask for it, run /aionas-bypass output_trim [reason]; the request goes for approval."
fi

printf '%s\n' "$newcmd" >"$tmp/new"
# Rebuild tool_input with only the command replaced (every other field kept
# as it came). A nested field means a shape this hook does not know: no change.
input=$(LC_ALL=C awk -F '\t' '
  FILENAME == ARGV[1] { nc = $0; next }
  $1 ~ /^tool_input\./ {
    k = substr($1, 12)
    if (index(k, ".")) { bad = 1; exit }
    if (k == "command") v = "\"" nc "\""
    else if ($2 == "s") v = "\"" $3 "\""
    else if ($2 == "n" || $2 == "b") v = $3
    else if ($2 == "z") v = "null"
    else { bad = 1; exit }
    o = o (n++ ? "," : "") "\"" k "\":" v
  }
  END { if (bad || !n) exit 1; printf "{%s}", o }' "$tmp/new" "$tmp/flat") || exit 0

ctx=""
[ -n "$note" ] && ctx=",\"additionalContext\":$(aionas_json_escape "$note")"
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":%s%s}}\n' "$input" "$ctx"
aionas_counter_inc output_trim fired
exit 0
