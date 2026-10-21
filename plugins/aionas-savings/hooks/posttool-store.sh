#!/usr/bin/env bash
# aionas-savings hook: long-output store (PostToolUse). Owner: AIO-860.
#
# For a Bash result only (other tools, and so every file read used for an
# edit, stay untouched):
#   - a sed/grep/cat command (a cap rule of the guard, noisy_guard on) whose
#     output is over cap_tokens is cut to whole lines within the cap, ending
#     with "[aionas-guard: capped <rule> ..."; the command itself is never
#     rewritten (an AIONAS_GUARD= prefix would stop the person's allow rules
#     such as Bash(cat:*) from matching);
#   - any other output over store_tokens (about 4 bytes a token) is kept in
#     full in ~/.aionas/agent/savings/store/ and the model sees its first 40
#     lines, the FAILED/Error lines between, its last 40 lines and one marker:
#     [aionas-store: kept 40+40 of N lines (about F tokens), id=out_<12 hex>. More: aionas-recall out_<12 hex> [--grep PATTERN]. Full: rerun with AIONAS_FULL=1]
# The id is the SHA-256 of the output bytes and the view is a pure function
# of them, so the same output always gives the same bytes (the prompt cache
# holds). Stored outputs never leave this computer and are removed after
# Claude Code's cleanupPeriodDays (default 30).
#
# A failed command is reported through PostToolUseFailure, never here, so a
# failing run always keeps its full output.
#
# Version probe: Claude Code honours a rewritten output only in the tool's
# exact shape ({stdout, stderr, interrupted, isImage} for Bash). Below the
# probed minimum (rules/guard-store.tsv) every output is left untouched, a
# "skipped" counter is queued and store.status says "inactive"
# (aionas-recall --status prints it).
. "$(dirname "$0")/../lib/aionas.sh" || exit 0
. "$(dirname "$0")/pretool-guard.lib" || exit 0

tmp=$(mktemp -d "${TMPDIR:-/tmp}/aionas-store.XXXXXX") || exit 0
trap 'rm -f "$tmp/in" "$tmp/flat" "$tmp/cmd" "$tmp/out" "$tmp/body" "$tmp/view"; rmdir "$tmp" 2>/dev/null' EXIT
cat >"$tmp/in" 2>/dev/null
# Most tool calls are not Bash: leave before parsing a large result.
grep -q '"tool_name" *: *"Bash"' "$tmp/in" 2>/dev/null || exit 0
aionas_json_flatten "$tmp/in" >"$tmp/flat" 2>/dev/null || exit 0
[ "$(aionas_json_get tool_name <"$tmp/flat")" = Bash ] || exit 0
[ "$(aionas_json_type tool_response.stdout <"$tmp/flat")" = s ] || exit 0
[ "$(aionas_json_get tool_response.isImage <"$tmp/flat" 2>/dev/null)" = true ] && exit 0
aionas_json_get tool_response.stdout <"$tmp/flat" >"$tmp/out" || exit 0
aionas_json_get tool_input.command <"$tmp/flat" >"$tmp/cmd" || exit 0
sid=$(aionas_json_get session_id <"$tmp/flat")

bpt=$(aionas_gs_int "$(aionas_gs_setting bytes_per_token 4)" 4)
IFS=$'\037' read -r status rule kind _new _gid prog full < <(aionas_gs_match "$tmp/cmd")

# Which method acts on this output: the guard's cap (a sed/grep/cat rule,
# when noisy_guard is on), or the store.
[ "$prog" = aionas-recall ] && exit 0 # the model asked for exactly this
method=output_store
case "$status" in match | bypass | guarded)
  if [ "$kind" = cap ] && aionas_policy_active noisy_guard "$sid"; then method=noisy_guard; fi ;;
esac
if [ "$method" = noisy_guard ]; then
  tokens=$(aionas_gs_int "$(aionas_policy_param noisy_guard cap_tokens "$sid" 2>/dev/null)" "$(aionas_gs_int "$(aionas_gs_setting cap_tokens 1500)" 1500)")
else
  tokens=$(aionas_gs_int "$(aionas_policy_param output_store threshold_tokens "$sid" 2>/dev/null)" "$(aionas_gs_int "$(aionas_gs_setting store_tokens 2000)" 2000)")
fi
limit=$((tokens * bpt))

# The escaped text is never shorter than the bytes it stands for.
[ "$(LC_ALL=C awk '{ n += length($0) } END { print n + 0 }' "$tmp/out")" -gt "$limit" ] || exit 0

aionas_policy_active "$method" "$sid" || exit 0

note=""
if [ "$full" = 1 ]; then
  if aionas_policy_self_override_allowed "$method" "$sid"; then
    # One bypass, one counter: pretool-guard.sh already counted a quiet rule.
    [ "$status" = bypass ] && [ "$kind" = quiet ] || aionas_counter_inc "$method" bypass
    exit 0
  fi
  note="AIONAS_FULL=1 is not available for $method: the organization blocked self-override. To ask for it, run /aionas-bypass $method [reason]; the request goes for approval."
fi

if ! aionas_gs_store_active "$(aionas_json_get transcript_path <"$tmp/flat")"; then
  aionas_counter_inc "$method" skipped
  exit 0
fi

LC_ALL=C awk -v mode=decode -v body="$tmp/body" -f "$AIONAS_GS_HOOKS/posttool-store.awk" "$tmp/out" || exit 0
size=$(wc -c <"$tmp/body" | tr -d ' ')
[ "$size" -gt "$limit" ] || exit 0
id="out_$(aionas_gs_hash "$tmp/body")"
case "$id" in out_[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) exit 0 ;; esac

keep=$(aionas_gs_int "$(aionas_gs_setting keep_lines_max 40)" 40)
if [ "$method" = noisy_guard ]; then
  LC_ALL=C awk -v mode=cap -v full="$size" -v id="$id" -v rule="$rule" -v budget="$limit" -v tokens="$tokens" -v keep="$keep" \
    -f "$AIONAS_GS_HOOKS/posttool-store.awk" "$tmp/out" >"$tmp/view" || exit 0
else
  LC_ALL=C awk -v mode=store -v full="$size" -v id="$id" -v keep="$keep" \
    -v head="$(aionas_gs_int "$(aionas_gs_setting store_head 40)" 40)" \
    -v tail="$(aionas_gs_int "$(aionas_gs_setting store_tail 40)" 40)" \
    -f "$AIONAS_GS_HOOKS/posttool-store.awk" "$tmp/out" >"$tmp/view" || exit 0
fi
[ -s "$tmp/view" ] || exit 0

# Keep the full output first: a view must never point at a missing id.
store=$(aionas_gs_store_dir)
aionas_mkdir "$store" || exit 0
if [ ! -f "$store/$id.txt" ]; then
  aionas_write_atomic "$store/$id.txt" <"$tmp/body" || exit 0
else
  touch "$store/$id.txt" 2>/dev/null
fi
aionas_gs_prune

# The exact Bash shape: stdout replaced, stderr and interrupted as they came.
stderr_v=$(aionas_json_get tool_response.stderr <"$tmp/flat" 2>/dev/null)
intr=$(aionas_json_get tool_response.interrupted <"$tmp/flat" 2>/dev/null)
[ "$intr" = true ] || intr=false
ctx=""
[ -n "$note" ] && ctx=",\"additionalContext\":$(aionas_json_escape "$note")"
{
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","updatedToolOutput":{"stdout":"'
  cat "$tmp/view"
  printf '","stderr":"%s","interrupted":%s,"isImage":false}%s}}\n' "$stderr_v" "$intr" "$ctx"
}
aionas_counter_inc "$method" fired
exit 0
