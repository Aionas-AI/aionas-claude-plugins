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

# transcript TOKENS [FILE]: a transcript whose last answer used TOKENS of context.
transcript() {
  local f=${2:-$HOME/proj/$SID.jsonl}
  mkdir -p "$(dirname "$f")"
  {
    printf '{"type":"user","message":{"role":"user","content":"%s \\"usage\\": \\"input_tokens\\":999999"}}\n' "$SECRET1"
    printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"%s"}],"usage":{"input_tokens":5,"cache_creation_input_tokens":1000,"cache_read_input_tokens":%d,"output_tokens":10}}}\n' "$SECRET2" "$(($1 - 1005))"
  } >"$f"
  echo "$f"
}

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
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","hook_event_name":"Stop","stop_hook_active":false%s}' "$SID" "$1" "$HOME/proj" "$bg"
}

# run_stop SCRIPT TRANSCRIPT [BG]: start the Stop hook in the background; OUT/ERR/RC files.
run_stop() {
  local n; n=$(mktemp -d "$T_ROOT/run.XXXXXX")
  stop_input "$2" "${3:-}" >"$n/in"
  (AIONAS_HANDOFF_IDLE_SECONDS=${IDLE:-2} AIONAS_HANDOFF_POLL_SECONDS=1 AIONAS_HANDOFF_BUSY_SECONDS=${BUSY:-3} \
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
  t_contains "$msg" "$(hdir)/opener-$SID.sh"
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

t_main "$@"
