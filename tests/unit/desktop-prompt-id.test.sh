#!/usr/bin/env bash
# AIO-1099 (W33-13): per-request records in Claude Desktop. Its Code tab gives
# the hooks no prompt_id, so 0.6.1 forgot the session's prompt and dropped
# every mark (0 records on prod). The prompt hook now keeps the transcript, a
# mark takes the transcript's latest "promptId" (the hook runs before the new
# prompt is written there), the Stop path does the same for handoff, and a
# missing field never erases a stored id. Only the id is read from the
# transcript; prompt text, tool output and replies never are.
. "$(dirname "$0")/../lib/harness.sh"
unset CURSOR_VERSION CLAUDECODE
FX="$T_REPO/tests/fixtures/desktop-prompt"
H="$T_PLUGIN/hooks"
SID=00000000-0000-4000-8000-0000000e1099
TERM_PID=00000000-0000-4000-8000-0000000c1099
TURN1=00000000-0000-4000-8000-0000000d0001
TURN2=00000000-0000-4000-8000-0000000d0002
T0=1792490400 # 2026-10-20T10:00:00Z

RD() { echo "$(aionas_savings_dir)/requests"; }
TR() { echo "$HOME/.claude/projects/-Users-member-project/$SID.jsonl"; }
# fill FIXTURE: the fixture with the session id and this test's transcript path.
fill() { sed -e "s|@SID@|$SID|g" -e "s|@TRANSCRIPT@|$(TR)|g" "$FX/$1"; }
# transcript [turn2]: write the Desktop transcript (turn 1; with turn 2 appended).
transcript() {
  mkdir -p "$(dirname "$(TR)")"
  fill transcript.jsonl >"$(TR)"
  [ "${1:-}" = turn2 ] && fill transcript-turn2.jsonl >>"$(TR)"
  return 0
}
# A real Claude Code turn's UserPromptSubmit input, piped to the hook.
submit() { fill "$1" | bash "$H/request-prompt.sh"; }
# What the mod runs after a sub-agent start the policy moved to Sonnet.
moved() { AIONAS_SESSION_ID=$SID bash "$T_PLUGIN/commands/aionas-bypass.sh" --subagent-start moved; }
marks() { cat "$(RD)"/spool/*.ev 2>/dev/null; }
mark_ids() { marks | awk -F '\t' '{ print $3 ":" $2 }'; }
bodies() { local i n; n=$(t_calls); for i in $(seq 1 "$n"); do case "$(t_call "$i" url)" in */savings/requests) t_call "$i" body ;; esac; done; }
policy() {
  mkdir -p "$(aionas_savings_dir)"
  { printf 'V\t1\nF\t1\nM\tsubagent_sonnet\ton\t0\t1\t1\t0\nM\thandoff\ton\t0\t1\t1\t0\n'
    printf 'P\thandoff\tthreshold_tokens\tn\t20000\nP\thandoff\tidle_minutes\tn\t2\n'; } >"$(aionas_savings_dir)/policy.cache"
}
setup() { t_enroll; export AIONAS_NOW=$T0; policy; transcript; }

test_terminal_prompt_id_is_used_as_before() {
  setup
  submit user-prompt-submit-terminal.json
  t_eq "$TERM_PID" "$(cat "$(RD)/prompt.$SID")"
  t_not test -e "$(RD)/transcript.$SID"   # a real prompt_id needs no transcript
  moved
  t_eq "subagent_sonnet:$TERM_PID" "$(mark_ids)"
  t_rc 0 aionas_requests_flush
  t_eq "{\"session_id\":\"$SID\",\"prompt_id\":\"$TERM_PID\",\"method\":\"subagent_sonnet\",\"ts\":\"2026-10-20T10:00:00Z\",\"plugin_version\":\"0.7.0\"}" "$(bodies)"
}

test_desktop_prompt_without_the_field_is_recorded_with_the_transcripts_id() {
  setup
  submit user-prompt-submit-desktop.json
  t_eq "$TURN1" "$(cat "$(RD)/prompt.$SID")" "the transcript's latest promptId, never FAKE-IN-TEXT"
  moved
  t_eq "subagent_sonnet:$TURN1" "$(mark_ids)"
  t_rc 0 aionas_requests_flush
  t_eq "{\"session_id\":\"$SID\",\"prompt_id\":\"$TURN1\",\"method\":\"subagent_sonnet\",\"ts\":\"2026-10-20T10:00:00Z\",\"plugin_version\":\"0.7.0\"}" "$(bodies)"
}

# The hook runs before Claude Code writes the new prompt's line: at that
# moment the transcript's latest id is the previous turn's. The mark (made
# later in the turn) reads the transcript again and takes the new turn's id.
test_desktop_mark_takes_the_turn_written_after_the_hook() {
  setup
  submit user-prompt-submit-desktop.json   # turn 1, as before
  fill transcript-turn2.jsonl >>"$(TR)"    # the prompt hook of turn 2 ran first, then this
  moved
  t_eq "subagent_sonnet:$TURN2" "$(mark_ids)"
  t_eq "$TURN2" "$(cat "$(RD)/prompt.$SID")" "the stored id moves to the newer real one"
  t_lacks "$(mark_ids)" "$TURN1"
}

test_desktop_stop_without_the_field_marks_handoff_with_the_turns_id() {
  setup; transcript turn2
  local n; n=$(mktemp -d "$T_ROOT/run.XXXXXX")
  fill stop-desktop.json >"$n/in"
  AIONAS_HANDOFF_IDLE_SECONDS=1 AIONAS_HANDOFF_POLL_SECONDS=1 AIONAS_HANDOFF_SETTLE_SECONDS=2 \
    bash "$H/handoff-arm.sh" <"$n/in" >"$n/out" 2>"$n/err"
  t_eq 2 "$?" "the idle timer woke the session with the handoff"
  t_contains "$(cat "$n/err")" "about 40K tokens" "the size of this turn's answer (turn 2)"
  t_eq "handoff:$TURN2" "$(mark_ids)"
  t_eq 40005 "$(marks | awk -F '\t' '{ print $5 }')" "the token count is kept"
  t_rc 0 aionas_requests_flush
  t_contains "$(bodies)" "\"prompt_id\":\"$TURN2\",\"method\":\"handoff\""
}

test_a_missing_field_never_erases_a_stored_id() {
  setup
  submit user-prompt-submit-terminal.json
  rm -f "$(TR)"   # Desktop input, but no readable transcript
  submit user-prompt-submit-desktop.json
  t_eq "$TERM_PID" "$(cat "$(RD)/prompt.$SID")"
  # a transcript with no promptId at all changes nothing either
  mkdir -p "$(dirname "$(TR)")"; printf '{"type":"queue-operation","sessionId":"%s"}\n' "$SID" >"$(TR)"
  submit user-prompt-submit-desktop.json
  t_eq "$TERM_PID" "$(cat "$(RD)/prompt.$SID")"
  moved
  t_eq "subagent_sonnet:$TERM_PID" "$(mark_ids)"
}

test_a_real_prompt_id_wins_over_the_transcript_again() {
  setup
  submit user-prompt-submit-desktop.json
  t_ok test -f "$(RD)/transcript.$SID"
  submit user-prompt-submit-terminal.json
  t_not test -e "$(RD)/transcript.$SID"
  moved
  t_eq "subagent_sonnet:$TERM_PID" "$(mark_ids)"
}

test_nothing_but_the_id_is_read_or_kept() {
  setup; transcript turn2
  submit user-prompt-submit-desktop.json
  moved
  t_rc 0 aionas_requests_flush
  local kept; kept=$(cat "$(RD)"/prompt.* "$(RD)"/spool/*.ev 2>/dev/null; bodies)
  local w
  for w in SECRET-PROMPT-TEXT-1099 SECRET-TOOL-OUTPUT SECRET-REPLY-TEXT FAKE-IN-TEXT FAKE-IN-TOOL /Users/member; do
    t_lacks "$kept" "$w"
  done
  t_lacks "$(bodies)" "$HOME" "the transcript path is local only"
  t_eq "$(TR)" "$(cat "$(RD)/transcript.$SID")" "the path is kept on this computer for the marks"
}

test_ids_outside_the_grammar_are_ignored() {
  setup
  printf '{"promptId":"bad id with spaces","type":"user"}\n{"promptId":"%s","type":"user"}\n' "$(printf 'x%.0s' $(seq 1 130))" >"$(TR)"
  submit user-prompt-submit-desktop.json
  t_not test -e "$(RD)/prompt.$SID"
  moved
  t_eq "" "$(marks)"
}

test_under_cursor_the_generation_id_stays_and_no_transcript_is_kept() {
  setup
  bash "$H/request-prompt.sh" <"$T_REPO/tests/fixtures/cursor/before-submit-prompt.json"
  t_eq "" "$(ls "$(RD)" 2>/dev/null | grep '^transcript\.')"
}

t_main "$@"
