#!/usr/bin/env bash
# AIO-1079 (wave 33): the handoff offer under Cursor. Cursor ignores
# asyncRewake, so there is no idle timer: the stop hook of the turn that
# crosses the policy threshold answers {"followup_message": ...} on stdout, once
# per conversation, for status completed and loop_count 0, from numbers only.
. "$(dirname "$0")/../lib/harness.sh"
unset CURSOR_VERSION CLAUDECODE
FX="$T_REPO/tests/fixtures/cursor-handoff"
H="$T_PLUGIN/hooks"
CSID=00000000-0000-4000-8000-0000000c0001
CC_SID=cc-handoff-1

ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time() * 1000'; }
hdir() { echo "$(aionas_savings_dir)/handoff"; }
# policy [THRESHOLD] [STATE] [OVERRIDE]
policy() {
  mkdir -p "$(aionas_savings_dir)"
  { printf 'V\t1\nF\t1\nM\thandoff\t%s\t0\t1\t1\t0\n' "${2:-on}"
    [ -n "${1:-}" ] && printf 'P\thandoff\tthreshold_tokens\tn\t%s\n' "$1"
    [ -n "${3:-}" ] && printf 'O\thandoff\tself\t0\t0\n'
    :; } >"$(aionas_savings_dir)/policy.cache"
}
# stop FIXTURE: run the hook, set OUT / RC / MS.
stop() {
  local t0 t1
  t0=$(ms)
  OUT=$(bash "$H/stop-handoff.sh" <"$FX/$1" 2>"$T_ROOT/err"); RC=$?
  t1=$(ms); MS=$((t1 - t0))
}
fcount() { printf '%s' "$OUT" | grep -c followup_message; }

test_below_threshold_says_nothing() {
  t_enroll; policy 200000
  stop stop-below.json
  t_eq 0 "$RC"; t_eq "" "$OUT"
  t_not test -e "$(hdir)/$CSID.done"
}

test_crossing_turn_returns_followup_message_once() {
  t_enroll; policy 200000
  stop stop-at-threshold.json
  t_eq 0 "$RC"
  t_eq 1 "$(fcount)" "one followup_message"
  t_contains "$OUT" '[aionas-handoff]'
  t_contains "$OUT" "handoff-$CSID.md"
  t_contains "$OUT" '210K tokens' "size = input + cache_read"
  t_ok test -e "$(hdir)/$CSID.done"
  # valid JSON with one key, no other decision
  t_eq "followup_message" "$(printf '%s' "$OUT" | aionas_json_flatten | awk -F "\t" '$1 != "" { print $1 }')"
  # the same conversation's next qualifying stop does not ask again
  stop stop-at-threshold.json
  t_eq "" "$OUT"
  t_eq 1 "$(cat "$(aionas_savings_dir)"/counters/cursor/spool/*.ev | grep -c fired)"
}

test_counter_is_tagged_cursor() {
  t_enroll; policy 200000
  stop stop-at-threshold.json
  t_ok test -n "$(cat "$(aionas_savings_dir)"/counters/cursor/spool/*.ev 2>/dev/null)"
  t_contains "$(cat "$(aionas_savings_dir)"/counters/cursor/spool/*.ev)" "$(printf 'handoff\tfired\t1')"
  t_eq "" "$(t_counters)" "nothing in Claude Code's queue"
}

test_loop_count_one_and_aborted_say_nothing() {
  t_enroll; policy 200000
  stop stop-loop1.json; t_eq "" "$OUT"; t_not test -e "$(hdir)/$CSID.done"
  stop stop-aborted.json; t_eq "" "$OUT"; t_not test -e "$(hdir)/$CSID.done"
}

test_context_tokens_field_wins_when_present() {
  t_enroll; policy 200000
  stop stop-context-tokens.json
  t_contains "$OUT" '230K tokens'
}

test_default_threshold_when_policy_has_none() {
  t_enroll; policy ''
  stop stop-at-threshold.json   # 210000 >= 200000
  t_eq 1 "$(fcount)"
  policy ''; rm -f "$(hdir)/$CSID.done"
  stop stop-below.json; t_eq "" "$OUT"
}

test_returns_fast_and_never_sleeps() {
  t_enroll; policy 1000
  stop stop-at-threshold.json
  [ "$MS" -lt 1000 ] || t_fail "took $MS ms"
  rm -f "$(hdir)/$CSID.done"
  stop stop-below.json
  [ "$MS" -lt 1000 ] || t_fail "below: took $MS ms"
  # no sleep in the Cursor branch
  ! sed -n '/^aionas_cursor_stop/,/^}/p' "$H/stop-handoff.sh" | grep -q 'sleep' || t_fail "sleep in the Cursor branch"
}

test_off_and_bypassed_behave_as_claude_code() {
  t_enroll; policy 1000 off
  stop stop-at-threshold.json; t_eq "" "$OUT"; t_not test -e "$(hdir)/$CSID.done"
  policy 1000 on bypass
  stop stop-at-threshold.json; t_eq "" "$OUT"
  stop stop-at-threshold.json
  t_eq 1 "$(cat "$(aionas_savings_dir)"/counters/cursor/spool/*.ev | grep -c 'handoff	bypass')" "bypass counted once"
}

test_not_enrolled_says_nothing() {
  t_unenroll; policy 1000
  stop stop-at-threshold.json
  t_eq "" "$OUT"
}

test_no_content_is_read_or_kept() {
  t_enroll; policy 1000
  local tr="$HOME/tr.jsonl"; printf '{"role":"user","message":{"content":[{"type":"text","text":"SECRET-PROMPT-TEXT"}]}}\n' >"$tr"
  sed "s|\"transcript_path\": null|\"transcript_path\": \"$tr\"|" "$FX/stop-at-threshold.json" | bash "$H/stop-handoff.sh" >"$T_ROOT/o" 2>&1
  t_lacks "$(cat "$T_ROOT/o")" SECRET-PROMPT-TEXT
  t_not grep -rq SECRET-PROMPT-TEXT "$HOME/.aionas"
}

test_claude_code_stop_is_unchanged() {
  # Claude Code's payload still takes the timer path: it arms and prints nothing on stdout.
  t_enroll; policy 1000
  local tr="$HOME/cc.jsonl"
  printf '{"type":"assistant","message":{"usage":{"input_tokens":5000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' >"$tr"
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"/tmp","hook_event_name":"Stop"}' "$CC_SID" "$tr" |
    AIONAS_HANDOFF_IDLE_SECONDS=30 AIONAS_HANDOFF_POLL_SECONDS=1 AIONAS_HANDOFF_SETTLE_SECONDS=1 bash "$H/stop-handoff.sh" >"$T_ROOT/o" 2>/dev/null &
  local p=$! i=0
  while [ ! -f "$(hdir)/$CC_SID.state" ] && [ $i -lt 20 ]; do sleep 0.25; i=$((i + 1)); done
  t_eq "" "$(cat "$T_ROOT/o")"
  t_ok test -f "$(hdir)/$CC_SID.state"
  t_eq armed "$(awk -F '\t' '{print $1}' "$(hdir)/$CC_SID.state")"
  rm -f "$(hdir)/$CC_SID.armed"; wait "$p"
}

test_by_hand_handoff_still_works() {
  t_enroll
  local m; m=$(bash "$H/handoff-wake.sh" prepare "$CSID" "$HOME")
  t_contains "$m" '[aionas-handoff] The developer asked for a handoff'
}

t_main "$@"
