#!/usr/bin/env bash
# The handoff hooks (AIO-858): Stop arms an idle timer above the context threshold,
# the timer wakes the same session once, a prompt cancels it, running work holds
# it back, nothing is compacted, and nothing but numbers and names is kept.
# Thresholds are lowered with policy params and the test seams (2 s idle, 1 s poll).
. "$(dirname "$0")/../lib/harness.sh"
HOOKS="$T_PLUGIN/hooks"
SID=sess-abc123
SECRET1="SECRET-PROMPT-TEXT-91"
SECRET2="SECRET-REPLY-TEXT-77"

PROMPT=p-0001  # the prompt_id of the turn that just ended (Claude Code puts it on that turn's user line)

# user_line [PROMPT_ID]: the user line that starts a turn. assistant_line TOKENS [STOP_REASON]: an answer.
user_line() { printf '{"type":"user","promptId":"%s","message":{"role":"user","content":"%s \\"usage\\": \\"input_tokens\\":999999"}}\n' "${1:-$PROMPT}" "$SECRET1"; }
assistant_line() {
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"%s"}],"stop_reason":"%s","usage":{"input_tokens":5,"cache_creation_input_tokens":1000,"cache_read_input_tokens":%d,"output_tokens":10}}}\n' "$SECRET2" "${2:-end_turn}" "$(($1 - 1005))"
}

# transcript TOKENS [FILE]: a transcript whose last answer used TOKENS of context.
transcript() {
  local f=${2:-$HOME/proj/$SID.jsonl}
  mkdir -p "$(dirname "$f")"
  { user_line; assistant_line "$1"; } >"$f"
  echo "$f"
}

# append_later SECONDS FILE LINE...: Claude Code writes the turn's answer to the
# transcript a little after the Stop hook starts (its write queue drains on a timer).
append_later() { local s=$1 f=$2; shift 2; (sleep "$s"; printf '%s' "$@" >>"$f") & }

# policy PARAMS_ROWS...: a cached policy with handoff on (rows are extra P lines).
policy() {
  mkdir -p "$(aionas_savings_dir)"
  { printf 'V\t1\nF\t1\nM\thandoff\ton\t0\t1\t1\t0\n'; for r in "$@"; do printf 'P\thandoff\t%s\n' "$r"; done; } >"$(aionas_savings_dir)/policy.cache"
}
policy_low() { policy "$(printf 'threshold_tokens\tn\t20000')" "$(printf 'idle_minutes\tn\t2')"; }

# stop_input TRANSCRIPT [BACKGROUND_STATUS]: the Stop hook input.
stop_input() {
  local bg=''
  [ -n "${2:-}" ] && bg=",\"background_tasks\":[{\"id\":\"t1\",\"type\":\"local_agent\",\"status\":\"$2\",\"description\":\"d\"}]"
  local pid=''
  [ -n "$PROMPT" ] && pid=",\"prompt_id\":\"$PROMPT\""
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s"%s,"hook_event_name":"Stop","stop_hook_active":false%s}' "$SID" "$1" "$HOME/proj" "$pid" "$bg"
}

# run_stop SCRIPT TRANSCRIPT [BG]: start the Stop hook in the background; OUT/ERR/RC files.
run_stop() {
  local n; n=$(mktemp -d "$T_ROOT/run.XXXXXX")
  stop_input "$2" "${3:-}" >"$n/in"
  (AIONAS_HANDOFF_IDLE_SECONDS=${IDLE:-2} AIONAS_HANDOFF_POLL_SECONDS=1 AIONAS_HANDOFF_BUSY_SECONDS=${BUSY:-3} \
    AIONAS_HANDOFF_SETTLE_SECONDS=${SETTLE:-4} \
    bash "$HOOKS/$1" <"$n/in" >"$n/out" 2>"$n/err"; echo $? >"$n/rc") &
  RUN=$n
}
wait_rc() { local i=0; while [ ! -f "$1/rc" ] && [ $i -lt ${2:-40} ]; do sleep 0.5; i=$((i + 1)); done; [ -f "$1/rc" ] || t_fail "hook still running after $((i / 2)) s"; cat "$1/rc"; }
hdir() { echo "$(aionas_savings_dir)/handoff"; }
cancel_prompt() { printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","prompt":"%s"}' "$SID" "typed text" | bash "$HOOKS/handoff-cancel.sh"; }
queue() { cat "$(aionas_savings_dir)/counters/queue.tsv" 2>/dev/null; }

test_context_tokens_sums_last_answer_only() {
  . "$HOOKS/handoff-wake.sh"
  local f; f=$(transcript 123456)
  t_eq 123456 "$(aionas_handoff_context_tokens "$f")" "input + cache creation + cache read"
  t_rc 1 aionas_handoff_context_tokens "$HOME/none.jsonl"
  printf '{"type":"user","message":{"content":"hi"}}\n' >"$HOME/u.jsonl"
  t_rc 1 aionas_handoff_context_tokens "$HOME/u.jsonl"
}

test_below_threshold_does_nothing() {
  policy_low
  run_stop handoff-arm.sh "$(transcript 15000)"
  t_eq 0 "$(wait_rc "$RUN")"
  t_eq "" "$(cat "$RUN/err")$(cat "$RUN/out")" "silent"
  t_not test -e "$(hdir)/$SID.armed"
  t_eq "" "$(queue)"
}

test_default_threshold_is_200k() {
  run_stop handoff-arm.sh "$(transcript 150000)"
  t_eq 0 "$(wait_rc "$RUN")"
  t_not test -e "$(hdir)/$SID.armed"
}

# The first turn: when the Stop hook starts, the transcript has the prompt but
# not yet the answer. The hook waits for the answer instead of giving up.
test_first_turn_arms_when_the_answer_lands_after_stop() {
  policy_low
  local f="$HOME/proj/$SID.jsonl"; mkdir -p "$HOME/proj"
  user_line >"$f"
  append_later 1 "$f" "$(assistant_line 30000)"
  IDLE=3 run_stop handoff-arm.sh "$f"
  sleep 2
  t_ok test -f "$(hdir)/$SID.armed"
  t_contains "$(cat "$(hdir)/$SID.state" 2>/dev/null)" "$(printf 'armed\t')"
  t_contains "$(cat "$(hdir)/$SID.state" 2>/dev/null)" "$(printf '\t30000')"
  t_eq 2 "$(wait_rc "$RUN")" "the first turn's timer wakes the session"
  t_contains "$(cat "$RUN/err")" "about 30K tokens"
}

# A later turn: the transcript still ends with the previous answer (below the
# threshold) when the hook starts. The size is this turn's answer, not that one.
test_later_turn_reads_this_turns_answer_not_the_previous_one() {
  policy_low
  local f="$HOME/proj/$SID.jsonl"; mkdir -p "$HOME/proj"
  { user_line p-0000; assistant_line 15000; user_line p-0001; } >"$f"
  PROMPT=p-0001
  append_later 1 "$f" "$(assistant_line 30000)"
  IDLE=3 run_stop handoff-arm.sh "$f"
  t_eq 2 "$(wait_rc "$RUN")" "armed on this turn's 30K, not the previous 15K"
  t_contains "$(cat "$RUN/err")" "about 30K tokens"
  # and the other way round: the previous answer was above, this one is below
  t_fresh; policy_low; mkdir -p "$HOME/proj"; f="$HOME/proj/$SID.jsonl"
  { user_line p-0000; assistant_line 30000; user_line p-0001; } >"$f"
  append_later 1 "$f" "$(assistant_line 15000)"
  run_stop handoff-arm.sh "$f"
  t_eq 0 "$(wait_rc "$RUN")"
  t_not test -e "$(hdir)/$SID.armed"
}

# A turn that used a tool: the tool call's line is written, the final answer
# is not yet. The size is the final answer's.
test_tool_turn_waits_for_the_final_answer() {
  policy_low
  local f="$HOME/proj/$SID.jsonl"; mkdir -p "$HOME/proj"
  { user_line; assistant_line 15000 tool_use; printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result"}]}}\n'; } >"$f"
  append_later 1 "$f" "$(assistant_line 30000)"
  IDLE=3 run_stop handoff-arm.sh "$f"
  t_eq 2 "$(wait_rc "$RUN")"
  t_contains "$(cat "$RUN/err")" "about 30K tokens"
}

# No prompt_id (an older Claude Code): the first turn still waits for an answer.
test_first_turn_without_prompt_id_waits_too() {
  policy_low
  PROMPT=''
  local f="$HOME/proj/$SID.jsonl"; mkdir -p "$HOME/proj"
  printf '{"type":"user","message":{"role":"user","content":"hi"}}\n' >"$f"
  append_later 1 "$f" "$(assistant_line 30000)"
  IDLE=3 run_stop handoff-arm.sh "$f"
  t_eq 2 "$(wait_rc "$RUN")"
}

# The developer types again while the hook waits: that turn's Stop owns the
# timer, so this one ends without arming.
test_newer_prompt_during_the_wait_arms_nothing() {
  policy_low
  local f="$HOME/proj/$SID.jsonl"; mkdir -p "$HOME/proj"
  user_line >"$f"
  append_later 1 "$f" "$(user_line p-0002)" "$(assistant_line 30000)"
  run_stop handoff-arm.sh "$f"
  t_eq 0 "$(wait_rc "$RUN")"
  t_not test -e "$(hdir)/$SID.armed"
  t_eq "" "$(cat "$RUN/err")"
}

test_turn_tokens_reads_only_this_turn() {
  . "$HOOKS/handoff-wake.sh"
  local f="$HOME/t.jsonl"
  { user_line p-0000; assistant_line 15000; } >"$f"
  t_rc 2 aionas_handoff_turn_tokens "$f" p-0001
  user_line p-0001 >>"$f"
  t_rc 1 aionas_handoff_turn_tokens "$f" p-0001
  assistant_line 22000 tool_use >>"$f"
  t_eq "22000 0" "$(aionas_handoff_turn_tokens "$f" p-0001)" "a tool call is not the final answer"
  assistant_line 23000 >>"$f"
  t_eq "23000 1" "$(aionas_handoff_turn_tokens "$f" p-0001)"
  t_rc 3 aionas_handoff_turn_tokens "$f" p-0000  # an older turn sees that a newer one started
  user_line p-0002 >>"$f"
  t_rc 3 aionas_handoff_turn_tokens "$f" p-0001
  t_rc 1 aionas_handoff_turn_tokens "$HOME/none.jsonl" p-0001
}

# The answer never lands (a turn that ended in an error): the wait is bounded,
# and the hook ends silently without a timer.
test_no_answer_ends_after_the_settle_wait() {
  policy_low
  local f="$HOME/proj/$SID.jsonl"; mkdir -p "$HOME/proj"
  user_line >"$f"
  local start; start=$(date +%s)
  SETTLE=2 run_stop handoff-arm.sh "$f"
  t_eq 0 "$(wait_rc "$RUN")"
  [ $(($(date +%s) - start)) -le 6 ] || t_fail "the settle wait is not bounded"
  t_not test -e "$(hdir)/$SID.armed"
  t_eq "" "$(cat "$RUN/err")$(cat "$RUN/out")"
}

test_idle_wakes_same_session_once_with_files() {
  policy_low
  local before; before=$(date +%s)
  run_stop handoff-arm.sh "$(transcript 30000)"
  sleep 0.5
  t_ok test -f "$(hdir)/$SID.armed"
  t_contains "$(cat "$(hdir)/$SID.state")" armed
  t_eq 2 "$(wait_rc "$RUN")" "exit 2 wakes the session"
  [ $(($(date +%s) - before)) -ge 2 ] || t_fail "woke before the idle time"
  local msg; msg=$(cat "$RUN/err")
  t_contains "$msg" "[aionas-handoff]"
  t_contains "$msg" "about 30K tokens"
  t_contains "$msg" "$(hdir)/handoff-$SID.md"
  t_lacks "$msg" "opener-$SID" "no launcher to run: the band's button opens the new conversation"
  t_contains "$msg" "Continue in a new conversation"
  t_contains "$msg" "Do not run /compact"
  t_eq "" "$(cat "$RUN/out")" "stdout stays empty"
  t_ok test -f "$(hdir)/$SID.done"
  t_contains "$(cat "$(hdir)/$SID.state")" delivered
  t_ok test -x "$(hdir)/opener-$SID.sh"
  t_contains "$(queue)" "$(printf 'handoff\tfired\t1')"
  # the session ends its turn again: no second instruction, no timer
  run_stop stop-handoff.sh "$(transcript 31000)"
  t_eq 0 "$(wait_rc "$RUN")"
  t_eq "" "$(cat "$RUN/err")"
  t_not test -e "$(hdir)/$SID.armed"
  t_eq 1 "$(queue | grep -c 'handoff	fired')" "exactly one delivery counted"
}

test_opener_starts_a_new_session_with_the_prompt() {
  policy_low
  local cwd="$HOME/it's a dir"; mkdir -p "$cwd"
  mkdir -p "$HOME/bin"
  printf '#!/usr/bin/env bash\npwd >"%s/seen.pwd"\nfor a in "$@"; do printf "%%s\\n" "$a"; done >"%s/seen.args"\n' "$HOME" "$HOME" >"$HOME/bin/claude"
  chmod +x "$HOME/bin/claude"
  . "$HOOKS/handoff-wake.sh"
  local msg; msg=$(bash "$HOOKS/handoff-wake.sh" prepare "$SID" "$cwd")
  t_contains "$msg" "[aionas-handoff] The developer asked for a handoff"
  t_ok bash -n "$(hdir)/opener-$SID.sh"
  PATH="$HOME/bin:$PATH" bash "$(hdir)/opener-$SID.sh"
  t_eq "$(cd "$cwd" && pwd -P)" "$(cd "$(cat "$HOME/seen.pwd")" && pwd -P)" "opens in the project folder"
  local args; args=$(cat "$HOME/seen.args")
  t_contains "$args" "--add-dir"
  t_contains "$args" "$(hdir)"
  t_contains "$args" "handoff-$SID.md"
  t_contains "$args" "Read it fully first"
}

test_prompt_before_deadline_cancels() {
  policy_low
  IDLE=6 run_stop handoff-arm.sh "$(transcript 30000)"
  sleep 1
  t_ok test -f "$(hdir)/$SID.armed"
  cancel_prompt
  t_not test -e "$(hdir)/$SID.armed"
  t_eq 0 "$(wait_rc "$RUN" 30)" "timer quits silently"
  t_eq "" "$(cat "$RUN/err")"
  t_not test -e "$(hdir)/$SID.done"
  t_not test -e "$(hdir)/opener-$SID.sh"
  t_contains "$(queue)" "$(printf 'handoff\tskipped\t1')"
  t_lacks "$(queue)" fired
}

# assistant_cache_line TOKENS KIND: an answer that wrote KIND (1h | 5m) cache entries.
assistant_cache_line() {
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"%s"}],"stop_reason":"end_turn","usage":{"input_tokens":5,"cache_creation_input_tokens":1000,"cache_read_input_tokens":%d,"cache_creation":{"ephemeral_5m_input_tokens":%d,"ephemeral_1h_input_tokens":%d},"output_tokens":10}}}\n' \
    "$SECRET2" "$(($1 - 1005))" "$([ "$2" = 5m ] && echo 1000 || echo 0)" "$([ "$2" = 1h ] && echo 1000 || echo 0)"
}

test_armed_state_says_when_the_doc_is_asked_for() { # AIO-874
  policy_low
  local before; before=$(date +%s)
  IDLE=6 run_stop handoff-arm.sh "$(transcript 30000)"
  sleep 1
  . "$HOOKS/handoff-wake.sh"
  t_eq armed "$(aionas_handoff_state_field "$SID" 1)"
  local due; due=$(aionas_handoff_state_field "$SID" 4)
  [ "$due" -ge $((before + 6)) ] && [ "$due" -le $((before + 9)) ] || t_fail "due $due is not the idle deadline (start $before + 6 s)"
  cancel_prompt
  wait_rc "$RUN" 30 >/dev/null
}

test_cache_ttl_reads_the_answers_cache_kind() { # AIO-874
  . "$HOOKS/handoff-wake.sh"
  local f="$HOME/ttl.jsonl"
  { user_line; assistant_cache_line 30000 5m; } >"$f"
  t_eq 300 "$(aionas_handoff_cache_ttl "$f")" "5-minute entries"
  { user_line; assistant_cache_line 30000 1h; } >"$f"
  t_eq 3600 "$(aionas_handoff_cache_ttl "$f")" "1-hour entries"
  { user_line; assistant_line 30000; } >"$f"
  t_eq 3600 "$(aionas_handoff_cache_ttl "$f")" "no sign: the hour"
  t_eq 3600 "$(aionas_handoff_cache_ttl "$HOME/none.jsonl")"
}

test_after_the_doc_each_turn_end_moves_the_cold_time() { # AIO-874
  policy_low
  local f="$HOME/proj/$SID.jsonl"; mkdir -p "$HOME/proj"
  { user_line; assistant_cache_line 30000 5m; } >"$f"
  run_stop handoff-arm.sh "$f"
  t_eq 2 "$(wait_rc "$RUN")"
  . "$HOOKS/handoff-wake.sh"
  t_eq delivered "$(aionas_handoff_state_field "$SID" 1)"
  local now cold; now=$(date +%s); cold=$(aionas_handoff_state_field "$SID" 4)
  [ "$cold" -ge $((now + 290)) ] && [ "$cold" -le $((now + 300)) ] || t_fail "cold $cold is not the wake + 5 min"
  # the doc-writing turn ends later, on 1-hour entries: the cold time moves on
  { user_line; assistant_cache_line 31000 1h; } >"$f"
  run_stop stop-handoff.sh "$f"
  t_eq 0 "$(wait_rc "$RUN")"
  t_eq "" "$(cat "$RUN/err")" "no second instruction"
  now=$(date +%s); cold=$(aionas_handoff_state_field "$SID" 4)
  [ "$cold" -ge $((now + 3590)) ] && [ "$cold" -le $((now + 3600)) ] || t_fail "cold $cold is not the turn end + 1 h"
  t_eq delivered "$(aionas_handoff_state_field "$SID" 1)"
}

test_done_stops_the_timer_and_a_new_prompt_takes_it_back() { # AIO-874
  policy_low
  IDLE=4 run_stop handoff-arm.sh "$(transcript 30000)"
  sleep 1
  local msg; msg=$(bash "$HOOKS/handoff-wake.sh" end "$SID")
  t_contains "$msg" "no handoff doc will be written"
  t_eq 0 "$(wait_rc "$RUN" 30)" "the timer quits silently"
  t_eq "" "$(cat "$RUN/err")"
  . "$HOOKS/handoff-wake.sh"
  t_eq ended "$(aionas_handoff_state_field "$SID" 1)"
  t_not test -e "$(hdir)/handoff-$SID.md"
  t_not test -e "$(hdir)/opener-$SID.sh"
  # a later turn's end arms nothing while done
  run_stop stop-handoff.sh "$(transcript 31000)"
  t_eq 0 "$(wait_rc "$RUN")"
  t_not test -e "$(hdir)/$SID.armed"
  t_lacks "$(queue)" fired
  # the person goes on with the chat: done is taken back, the timer may arm again
  cancel_prompt
  t_eq cancelled "$(aionas_handoff_state_field "$SID" 1)"
  t_not test -e "$(hdir)/$SID.done"
  IDLE=2 run_stop stop-handoff.sh "$(transcript 32000)"
  t_eq 2 "$(wait_rc "$RUN")" "armed and delivered again"
}

test_done_never_overwrites_a_delivery_in_progress() { # AIO-874
  mkdir -p "$(hdir)"; : >"$(hdir)/$SID.done"
  printf 'armed\t1\t30000\t2\n' >"$(hdir)/$SID.state"
  t_contains "$(bash "$HOOKS/handoff-wake.sh" end "$SID")" "already being written"
  . "$HOOKS/handoff-wake.sh"
  t_eq armed "$(aionas_handoff_state_field "$SID" 1)"
  t_ok test -f "$(hdir)/$SID.done"
}

test_typed_aionas_done_is_not_a_new_message() { # AIO-874
  policy_low
  bash "$HOOKS/handoff-wake.sh" end "$SID" >/dev/null
  printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","prompt":"/aionas-done"}' "$SID" | bash "$HOOKS/handoff-cancel.sh"
  . "$HOOKS/handoff-wake.sh"
  t_eq ended "$(aionas_handoff_state_field "$SID" 1)" "the command keeps done"
  t_ok test -f "$(hdir)/$SID.done"
  cancel_prompt
  t_eq cancelled "$(aionas_handoff_state_field "$SID" 1)" "a real message takes it back"
}

test_going_on_after_the_doc_passes_it_over_and_the_next_idle_asks_again() { # AIO-874, Tal 2026-10-22
  policy_low
  run_stop handoff-arm.sh "$(transcript 30000)"
  t_eq 2 "$(wait_rc "$RUN")"
  mkdir -p "$(hdir)"; printf 'old doc\n' >"$(hdir)/handoff-$SID.md"
  . "$HOOKS/handoff-wake.sh"
  # the instruction itself, should it come in as a prompt, changes nothing
  printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","prompt":"[aionas-handoff] This conversation is about"}' "$SID" | bash "$HOOKS/handoff-cancel.sh"
  t_eq delivered "$(aionas_handoff_state_field "$SID" 1)"
  # the person goes on with the chat: the handoff is passed over
  cancel_prompt
  t_eq cancelled "$(aionas_handoff_state_field "$SID" 1)" "the band shows no doc row"
  t_not test -e "$(hdir)/$SID.done"
  # idle again: a new instruction, for the same doc path (it is written over)
  run_stop stop-handoff.sh "$(transcript 32000)"
  t_eq 2 "$(wait_rc "$RUN")" "asked again"
  t_contains "$(cat "$RUN/err")" "$(hdir)/handoff-$SID.md"
  t_eq 2 "$(queue | grep -c 'handoff	fired')" "two deliveries counted"
}

test_done_after_the_doc_changes_nothing() { # AIO-874
  policy_low
  run_stop handoff-arm.sh "$(transcript 30000)"
  t_eq 2 "$(wait_rc "$RUN")"
  t_contains "$(bash "$HOOKS/handoff-wake.sh" end "$SID")" "already written"
  . "$HOOKS/handoff-wake.sh"
  t_eq delivered "$(aionas_handoff_state_field "$SID" 1)"
  t_rc 1 bash "$HOOKS/handoff-wake.sh" end "bad id;"
}

test_start_prompt_needs_the_doc() { # AIO-874
  t_rc 1 bash "$HOOKS/handoff-wake.sh" prompt "$SID"
  mkdir -p "$(hdir)"; printf '# doc\n' >"$(hdir)/handoff-$SID.md"
  local p; p=$(bash "$HOOKS/handoff-wake.sh" prompt "$SID")
  t_contains "$p" "$(hdir)/handoff-$SID.md"
  t_contains "$p" "Read it fully first"
  t_rc 1 bash "$HOOKS/handoff-wake.sh" prompt "../x"
}

test_open_app_opens_only_the_new_session_link() { # AIO-874
  t_rc 2 bash "$HOOKS/handoff-wake.sh" open-app "https://example.com/x"
  t_rc 2 bash "$HOOKS/handoff-wake.sh" open-app "claude://code/continue?session=last"
  t_rc 2 bash "$HOOKS/handoff-wake.sh" open-app ""
  mkdir -p "$HOME/bin"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >"%s/opened"\n' "$HOME" >"$HOME/bin/open"; chmod +x "$HOME/bin/open"
  AIONAS_UNAME="$HOME/bin/darwin" PATH="$HOME/bin:$PATH" bash -c 'printf "#!/usr/bin/env bash\necho Darwin\n" >"$HOME/bin/darwin"; chmod +x "$HOME/bin/darwin"'
  AIONAS_UNAME="$HOME/bin/darwin" PATH="$HOME/bin:$PATH" bash "$HOOKS/handoff-wake.sh" open-app 'claude://code/new?q=a%20b&folder=%2Fx'
  t_eq 'claude://code/new?q=a%20b&folder=%2Fx' "$(cat "$HOME/opened")" "the URL as one argument"
}

test_instruction_names_the_previous_conversation() { # AIO-874
  t_contains "$(bash "$HOOKS/handoff-wake.sh" prepare "$SID" "$HOME")" "Previous conversation: $SID (claude --resume $SID returns to it)"
}

test_newer_stop_replaces_the_timer() {
  policy_low
  IDLE=4 run_stop handoff-arm.sh "$(transcript 30000)"; local first=$RUN
  sleep 1.2
  IDLE=4 run_stop handoff-arm.sh "$(transcript 32000)"; local second=$RUN
  t_eq 0 "$(wait_rc "$first")" "the older timer quits"
  t_eq "" "$(cat "$first/err")"
  t_eq 2 "$(wait_rc "$second" 40)"
  t_eq 1 "$(queue | grep -c 'handoff	fired')"
}

test_running_background_task_holds_it_back() {
  policy_low
  run_stop handoff-arm.sh "$(transcript 30000)" running
  t_eq 0 "$(wait_rc "$RUN")" "no timer while a task runs"
  t_not test -e "$(hdir)/$SID.armed"
  # it finishes; Claude Code runs a turn; the next Stop arms the timer
  run_stop handoff-arm.sh "$(transcript 31000)" completed
  t_eq 2 "$(wait_rc "$RUN")"
}

test_running_subagent_holds_the_wake_until_it_is_quiet() {
  policy_low
  local f; f=$(transcript 30000)
  local sub="$HOME/proj/$SID/subagents"; mkdir -p "$sub"
  local start; start=$(date +%s)
  IDLE=1 BUSY=4 run_stop handoff-arm.sh "$f"
  # the sub-agent keeps writing for 3 s
  local i; for i in 1 2 3; do echo '{"n":1}' >>"$sub/agent-1.jsonl"; sleep 1; done
  [ ! -f "$RUN/rc" ] || t_fail "woke while the sub-agent writes"
  t_eq 2 "$(wait_rc "$RUN" 40)"
  [ $(($(date +%s) - start)) -ge 6 ] || t_fail "woke while the sub-agent was running"
  t_eq 1 "$(queue | grep -c 'handoff	fired')"
}

test_policy_off_released_or_bypassed() {
  mkdir -p "$(aionas_savings_dir)"
  printf 'V\t1\nM\thandoff\toff\t0\t1\t1\t0\nP\thandoff\tthreshold_tokens\tn\t20000\n' >"$(aionas_savings_dir)/policy.cache"
  run_stop handoff-arm.sh "$(transcript 30000)"
  t_eq 0 "$(wait_rc "$RUN")"; t_not test -e "$(hdir)/$SID.armed"
  printf 'V\t1\nM\thandoff\ton\t0\t1\t1\t1\nP\thandoff\tthreshold_tokens\tn\t20000\n' >"$(aionas_savings_dir)/policy.cache"
  run_stop handoff-arm.sh "$(transcript 30000)"
  t_eq 0 "$(wait_rc "$RUN")"; t_not test -e "$(hdir)/$SID.armed"
  policy_low
  aionas_override_local_add handoff 3600
  run_stop handoff-arm.sh "$(transcript 30000)"
  t_eq 0 "$(wait_rc "$RUN")"; t_not test -e "$(hdir)/$SID.armed"
  run_stop handoff-arm.sh "$(transcript 30000)"
  t_eq 0 "$(wait_rc "$RUN")"
  t_eq 1 "$(queue | grep -c 'handoff	bypass')" "bypass counted once per session"
}

test_no_content_is_kept_or_queued() {
  policy_low
  run_stop handoff-arm.sh "$(transcript 30000)"
  t_eq 2 "$(wait_rc "$RUN")"
  local all
  all=$(cat "$RUN/err" "$RUN/out" "$(hdir)"/* "$(aionas_savings_dir)"/counters/* 2>/dev/null)
  t_lacks "$all" "$SECRET1"
  t_lacks "$all" "$SECRET2"
  t_lacks "$all" 999999
  # the only rows queued are closed-list names with whole numbers
  local bad; bad=$(queue | awk -F '\t' 'NF != 4 || $2 != "handoff" || $3 !~ /^(fired|skipped|bypass)$/ || $4 !~ /^[0-9]+$/' | wc -l | tr -d ' ')
  t_eq 0 "$bad"
}

test_nothing_is_compacted_and_settings_untouched() {
  mkdir -p "$HOME/.claude"
  printf '{"idleCompaction":{"enabled":true,"minutes":15}}\n' >"$HOME/.claude/settings.json"
  local sum; sum=$(cksum <"$HOME/.claude/settings.json")
  policy_low
  run_stop handoff-arm.sh "$(transcript 30000)"
  t_eq 2 "$(wait_rc "$RUN")"
  t_eq "$sum" "$(cksum <"$HOME/.claude/settings.json")"
  t_eq "" "$(grep -v '^[[:space:]]*#' "$HOOKS"/stop-handoff.sh "$HOOKS"/handoff-wake.sh "$T_PLUGIN"/commands/aionas-handoff.md | grep -i 'idleCompaction\|settings.json')" "no code touches settings"
}

test_cancel_ignores_bad_input() {
  t_rc 0 bash -c "echo 'not json' | bash '$HOOKS/handoff-cancel.sh'"
  t_rc 0 bash -c "echo '{\"session_id\":\"../x\"}' | bash '$HOOKS/handoff-cancel.sh'"
  t_eq "" "$(echo '{}' | bash "$HOOKS/handoff-cancel.sh")"
}

test_bad_session_id_and_missing_transcript() {
  policy_low
  printf '{"session_id":"../../x","transcript_path":"/none","cwd":"/"}' | bash "$HOOKS/stop-handoff.sh"
  t_eq "" "$(ls "$(hdir)" 2>/dev/null)"
  run_stop stop-handoff.sh "$HOME/none.jsonl"
  t_eq 0 "$(wait_rc "$RUN")"
}

test_command_file_asks_the_same_session() {
  local c; c=$(cat "$T_PLUGIN/commands/aionas-handoff.md")
  t_contains "$c" 'handoff-wake.sh" prepare "${CLAUDE_SESSION_ID}"'
  t_contains "$c" "do not start a new one"
  t_ok grep -q '^description:' "$T_PLUGIN/commands/aionas-handoff.md"
}

test_command_allows_only_the_prepare_call() {
  local f="$T_PLUGIN/commands/aionas-handoff.md" line
  line=$(grep '^allowed-tools:' "$f")
  t_contains "$line" 'handoff-wake.sh" prepare'
  # no bare Bash, no Bash(bash:*), no wildcard that starts with anything but the one script
  t_eq "" "$(printf '%s' "$line" | grep -E 'Bash\(bash:\*\)|Bash\(\*|Bash\(bash \*\)|Bash\(bash:' )" "allowed-tools too wide"
  t_eq "" "$(printf '%s' "$line" | sed 's/^allowed-tools:[[:space:]]*//' | grep -E '(^|,)[[:space:]]*Bash[[:space:]]*(,|$)')" "bare Bash"
  t_eq 1 "$(printf '%s' "$line" | grep -o 'Bash(' | wc -l | tr -d ' ')" "exactly one Bash rule"
}

t_main "$@"
