#!/usr/bin/env bash
# aionas-savings handoff: shared functions and the delivery step. Owner: AIO-858.
#
# Source it (stop-handoff.sh does), or run it:
#   handoff-wake.sh cancel                 UserPromptSubmit: a prompt cancels the timer (reads the hook input)
#   handoff-wake.sh prepare SESSION [CWD]  print the handoff instruction and write the launcher (/aionas-handoff)
#   handoff-wake.sh end SESSION            "Done with this chat" (/aionas-done): no handoff doc for this session
#   handoff-wake.sh prompt SESSION         print the starting prompt of the new conversation (exit 1: no doc yet)
#   handoff-wake.sh open-app URL           open a new desktop-app session (claude://code/new?... only)
#
# State, under $(aionas_savings_dir)/handoff/ (numbers and names only, never content):
#   <sid>.armed   the token of the one live timer; a timer whose token differs, or whose file is gone, quits
#   <sid>.done    exists once the instruction was delivered: one handoff per session
#   <sid>.state   "<status><TAB><epoch><TAB><context tokens><TAB><until>"; status armed | cancelled |
#                 delivered | ended. until: armed, when the doc is asked for; delivered, when the
#                 prompt cache goes cold (the last turn's end + its cache TTL); else 0. The band
#                 counts down to it (AIO-874). ended: the person said done; a new prompt undoes it.
#   <sid>.bypass  the bypass counter was taken for this session
#   handoff-<sid>.md        the handoff document, written by the same session when asked
#   opener-<sid>.sh / .cmd  one file that opens a new Claude Code session with the starting prompt
#
# No compaction ever happens here, and idleCompaction is never read or changed.

if [ -z "${AIONAS_LIB:-}" ]; then
  AIONAS_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)
fi
. "$AIONAS_LIB/aionas.sh"

AIONAS_HANDOFF_DEFAULT_TOKENS=200000
AIONAS_HANDOFF_DEFAULT_IDLE_MINUTES=55
# The Stop hook entry has a 3600 s timeout (hooks.json): the wait must end before it.
AIONAS_HANDOFF_MAX_IDLE_SECONDS=3480

aionas_handoff_dir() { echo "$(aionas_savings_dir)/handoff"; }

# aionas_handoff_status SID STATUS [TOKENS] [UNTIL]: record the status for the band.
aionas_handoff_status() {
  printf '%s\t%s\t%s\t%s\n' "$2" "$(aionas_now)" "${3:-0}" "${4:-0}" | aionas_write_atomic "$(aionas_handoff_dir)/$1.state"
}

# aionas_handoff_state_field SID N: field N of the session's state line.
aionas_handoff_state_field() {
  awk -F '\t' -v n="$2" 'NR == 1 { print $n; exit }' "$(aionas_handoff_dir)/$1.state" 2>/dev/null
}

# aionas_handoff_cache_ttl TRANSCRIPT: the prompt-cache lifetime this session
# writes with, in seconds: 3600 when its recent answers wrote 1-hour cache
# entries, 300 when they wrote only 5-minute ones; 3600 with no sign either
# way (the idle timer assumes the hour too). Reads two numbers per answer.
# Test seam: AIONAS_HANDOFF_TTL_SECONDS.
aionas_handoff_cache_ttl() {
  if [ -n "${AIONAS_HANDOFF_TTL_SECONDS:-}" ] && aionas_is_uint "$AIONAS_HANDOFF_TTL_SECONDS"; then
    echo "$AIONAS_HANDOFF_TTL_SECONDS"; return 0
  fi
  [ -f "$1" ] || { echo 3600; return 0; }
  tail -c 4000000 "$1" 2>/dev/null | grep -E '"(type|role)":"assistant"' | grep '"ephemeral_' | tail -n 50 | awk '
    function num(k,   s) { if (!match($0, "\"" k "\":[0-9]+")) return 0; s = substr($0, RSTART, RLENGTH); sub(/.*:/, "", s); return s + 0 }
    { if (num("ephemeral_1h_input_tokens") > 0) h = 1; else if (num("ephemeral_5m_input_tokens") > 0) h = 0; else next; seen = 1 }
    END { print (seen && !h) ? 300 : 3600 }'
}

# aionas_handoff_context_tokens TRANSCRIPT: the context size of the last
# model answer: input + cache-read + cache-creation tokens. Reads three
# numbers from the last assistant line; nothing else is kept or printed.
# Exit 1 when there is no usage yet.
aionas_handoff_context_tokens() {
  [ -f "$1" ] || return 1
  _ct_line=$(tail -c 4000000 "$1" 2>/dev/null | grep -E '"(type|role)":"assistant"' | grep '"input_tokens":' | tail -n 1)
  [ -n "$_ct_line" ] || return 1
  _ct_sum=0
  for _ct_key in input_tokens cache_creation_input_tokens cache_read_input_tokens; do
    _ct_v=$(printf '%s' "$_ct_line" | grep -o "\"$_ct_key\":[0-9]*" | head -n 1 | cut -d: -f2)
    aionas_is_uint "$_ct_v" || _ct_v=0
    _ct_sum=$((_ct_sum + _ct_v))
  done
  [ "$_ct_sum" -gt 0 ] || return 1
  echo "$_ct_sum"
}

# aionas_handoff_turn_tokens TRANSCRIPT PROMPT_ID: the context size of the
# answer to the turn PROMPT_ID started (Claude Code puts "promptId" on that
# turn's user line; the Stop input carries it as prompt_id). Prints
# "<tokens> <final>", final 0 when that answer is a tool call (the final
# answer is still to be written). Exit 1: no answer to this turn yet; 2: the
# turn's user line is not in the transcript; 3: a newer turn started. Reads
# the same three numbers as aionas_handoff_context_tokens and nothing else.
aionas_handoff_turn_tokens() {
  [ -f "$1" ] || return 1
  tail -c 4000000 "$1" 2>/dev/null | awk -v pid="$2" '
    function num(k,   s) { if (!match(line, "\"" k "\":[0-9]+")) return 0; s = substr(line, RSTART, RLENGTH); sub(/.*:/, "", s); return s + 0 }
    !seen { if (index($0, "\"promptId\":\"" pid "\"")) seen = 1; next }
    /"promptId":"/ && !index($0, "\"promptId\":\"" pid "\"") { newer = 1; exit }
    /"(type|role)":"assistant"/ && /"input_tokens":/ { line = $0 }
    END {
      if (!seen) exit 2
      if (newer) exit 3
      if (line == "") exit 1
      sum = num("input_tokens") + num("cache_creation_input_tokens") + num("cache_read_input_tokens")
      if (sum < 1) exit 1
      print sum, (line ~ /"stop_reason":"tool_use"/ ? 0 : 1)
    }'
}

# aionas_handoff_wait_tokens TRANSCRIPT PROMPT_ID SECONDS: the context size of
# this turn's answer, waiting up to SECONDS for it. The Stop hook starts before
# Claude Code has written the turn's last lines to the transcript (its write
# queue drains on a timer), so on the first turn there is no answer yet and on
# later turns the last answer is the previous turn's. Exit 1 when there is no
# size to use, or a newer turn started meanwhile. Without PROMPT_ID (an older
# Claude Code) it waits for any answer, which covers the first turn.
aionas_handoff_wait_tokens() {
  [ -f "$1" ] || return 1
  _wt_end=$(($(date +%s) + $3))
  _wt_last=''
  while :; do
    if [ -n "$2" ]; then
      _wt_r=$(aionas_handoff_turn_tokens "$1" "$2")
      _wt_rc=$?
      [ "$_wt_rc" -eq 3 ] && return 1
      if [ "$_wt_rc" -eq 0 ]; then
        _wt_last=${_wt_r% *}
        [ "${_wt_r#* }" = 1 ] && { echo "$_wt_last"; return 0; }
      fi
    else
      aionas_handoff_context_tokens "$1" && return 0
      _wt_rc=1
    fi
    [ "$(date +%s)" -lt "$_wt_end" ] || break
    sleep 0.25 2>/dev/null || sleep 1
  done
  # A tool call's size is close enough; with the turn's user line out of reach, the last answer.
  [ -n "$_wt_last" ] && { echo "$_wt_last"; return 0; }
  [ "$_wt_rc" -eq 2 ] && { aionas_handoff_context_tokens "$1"; return $?; }
  return 1
}

# aionas_handoff_arm SID: take the timer. Prints the new token.
aionas_handoff_arm() {
  aionas_mkdir "$(aionas_handoff_dir)" || return 1
  _ar_tok="$$-$(date +%s)-${RANDOM:-0}"
  echo "$_ar_tok" | aionas_write_atomic "$(aionas_handoff_dir)/$1.armed" || return 1
  echo "$_ar_tok"
}

# aionas_handoff_disarm SID: stop any live timer. Exit 0 when one was armed.
aionas_handoff_disarm() {
  [ -f "$(aionas_handoff_dir)/$1.armed" ] || return 1
  rm -f "$(aionas_handoff_dir)/$1.armed"
  return 0
}

# aionas_handoff_still_armed SID TOKEN
aionas_handoff_still_armed() {
  [ "$(cat "$(aionas_handoff_dir)/$1.armed" 2>/dev/null)" = "$2" ]
}

# aionas_handoff_mtime FILE: modification time, epoch seconds.
aionas_handoff_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

# aionas_handoff_subagents_busy TRANSCRIPT SID WINDOW: exit 0 when any
# sub-agent transcript of the session was written within WINDOW seconds
# (<project>/<sid>/subagents/*.jsonl).
aionas_handoff_subagents_busy() {
  _sb_d="$(dirname "$1")/$2/subagents"
  [ -d "$_sb_d" ] || return 1
  _sb_now=$(date +%s)
  for _sb_f in "$_sb_d"/*.jsonl; do
    [ -f "$_sb_f" ] || continue
    _sb_m=$(aionas_handoff_mtime "$_sb_f")
    aionas_is_uint "$_sb_m" || continue
    [ $((_sb_now - _sb_m)) -lt "$3" ] && return 0
  done
  return 1
}

# aionas_handoff_prompt FILE: the starting prompt for the new session.
aionas_handoff_prompt() {
  printf 'Continue the work described in the handoff document %s. Read it fully first, then continue from where it stops and ask me if anything in it is unclear.' "$1"
}

# aionas_handoff_write_opener SID CWD: the launcher files. Prints the .sh path.
aionas_handoff_write_opener() {
  _wo_dir=$(aionas_handoff_dir)
  _wo_md="$_wo_dir/handoff-$1.md"
  _wo_sh="$_wo_dir/opener-$1.sh"
  _wo_prompt=$(aionas_handoff_prompt "$_wo_md")
  _wo_q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
  {
    printf '#!/usr/bin/env bash\n'
    printf '# Opens a new Claude Code session with the handoff prompt. Written by aionas-savings.\n'
    printf 'cd %s || exit 1\n' "$(_wo_q "${2:-.}")"
    printf 'exec claude --add-dir %s %s\n' "$(_wo_q "$_wo_dir")" "$(_wo_q "$_wo_prompt")"
  } | aionas_write_atomic "$_wo_sh" || return 1
  chmod 700 "$_wo_sh" 2>/dev/null
  if [ "$(aionas_os)" = windows ]; then
    _wo_cwd=$(cygpath -w "${2:-.}" 2>/dev/null || echo "${2:-.}")
    _wo_wd=$(cygpath -w "$_wo_dir" 2>/dev/null || echo "$_wo_dir")
    _wo_wmd=$(cygpath -w "$_wo_md" 2>/dev/null || echo "$_wo_md")
    {
      printf '@echo off\r\n'
      printf 'cd /d "%s" || exit /b 1\r\n' "$_wo_cwd"
      printf 'claude --add-dir "%s" "%s"\r\n' "$_wo_wd" "$(aionas_handoff_prompt "$_wo_wmd")"
    } | aionas_write_atomic "$_wo_dir/opener-$1.cmd"
  fi
  echo "$_wo_sh"
}

# aionas_handoff_instruction SID CWD TOKENS MINUTES: write the launcher and
# print the instruction for the session. Needs a valid SID.
aionas_handoff_instruction() {
  _in_dir=$(aionas_handoff_dir)
  aionas_mkdir "$_in_dir" || return 1
  _in_op=$(aionas_handoff_write_opener "$1" "$2") || return 1
  _in_md="$_in_dir/handoff-$1.md"
  if [ "${3:-0}" -gt 0 ] 2>/dev/null; then
    _in_lead="This conversation is about $(($3 / 1000))K tokens long"
    [ "${4:-0}" -gt 0 ] 2>/dev/null && _in_lead="$_in_lead and has been idle for $4 minutes, so its prompt cache is about to go cold and the next message would pay to rebuild all of it"
    _in_lead="$_in_lead."
  else
    _in_lead="The developer asked for a handoff to a new conversation."
  fi
  cat <<MSG
[aionas-handoff] $_in_lead Do this now, and nothing else:
1. Write a handoff document for a fresh conversation to $_in_md . Start it with the line "Previous conversation: $1 (claude --resume $1 returns to it)". Cover: the goal; what is done; what is left, in order; decisions and why; the files and commands that matter; how to check the work; open questions. Leave out secrets and credentials.
2. Print a short starting prompt for the new conversation (two or three sentences that point at that file).
Do not give the developer a command or a launcher to run: once this chat is cold, the aionas band above the prompt shows "Continue in a new conversation", which opens one with that prompt.
Do not run /compact and do not change any setting. When both are done, say the handoff is ready and stop.
MSG
}

# aionas_handoff_deliver SID CWD TOKEN TOKENS MINUTES [TTL]: the wake. Exit 2 with
# the instruction on stderr (Claude Code wakes the same session with it) when
# this is the one live timer and nothing was delivered yet; exit 0 and no
# output otherwise.
aionas_handoff_deliver() {
  _dv_dir=$(aionas_handoff_dir)
  aionas_handoff_still_armed "$1" "$3" || return 0
  aionas_policy_active handoff "$1" || return 0
  # Exactly one delivery per session: whoever creates the marker wins.
  ( set -C; : >"$_dv_dir/$1.done" ) 2>/dev/null || return 0
  if ! _dv_msg=$(aionas_handoff_instruction "$1" "$2" "$4" "$5"); then
    rm -f "$_dv_dir/$1.done"
    return 0
  fi
  rm -f "$_dv_dir/$1.armed"
  # The wake is a turn: the cache stays warm for TTL after it (the Stop after
  # the doc is written moves this on).
  aionas_handoff_status "$1" delivered "$4" $(($(aionas_now) + ${6:-3600}))
  aionas_counter_inc handoff fired >/dev/null 2>&1
  printf '%s\n' "$_dv_msg" >&2
  return 2
}

# aionas_handoff_cancel SID: a prompt arrived. It also takes back "done":
# the person went on with the chat.
aionas_handoff_cancel() {
  if aionas_handoff_disarm "$1"; then
    aionas_handoff_status "$1" cancelled 0
    aionas_counter_inc handoff skipped >/dev/null 2>&1
  elif [ "$(aionas_handoff_state_field "$1" 1)" = ended ]; then
    rm -f "$(aionas_handoff_dir)/$1.done"
    aionas_handoff_status "$1" cancelled 0
  fi
  return 0
}

# aionas_handoff_end SID: "Done with this chat": stop the timer and write no
# handoff doc for this session. A session already handed off is left as is.
aionas_handoff_end() {
  _en_dir=$(aionas_handoff_dir)
  aionas_mkdir "$_en_dir" || return 1
  if [ "$(aionas_handoff_state_field "$1" 1)" = delivered ]; then
    echo "The handoff doc of this chat is already written; nothing to stop."
    return 0
  fi
  # The marker taken by the delivery a moment ago wins: never overwrite it.
  if ! ( set -C; : >"$_en_dir/$1.done" ) 2>/dev/null && [ "$(aionas_handoff_state_field "$1" 1)" != ended ]; then
    echo "The handoff doc of this chat is already being written; nothing to stop."
    return 0
  fi
  aionas_handoff_disarm "$1"
  aionas_handoff_status "$1" ended 0
  echo "Done: no handoff doc will be written for this chat. A new message here takes it back."
}

# aionas_handoff_start_prompt SID: the new conversation's starting prompt,
# when the session's doc exists.
aionas_handoff_start_prompt() {
  _sp_md="$(aionas_handoff_dir)/handoff-$1.md"
  [ -s "$_sp_md" ] || return 1
  aionas_handoff_prompt "$_sp_md"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    cancel)
      _in=$(cat 2>/dev/null)
      _flat=$(printf '%s' "$_in" | aionas_json_flatten 2>/dev/null)
      _sid=$(printf '%s\n' "$_flat" | aionas_json_get session_id)
      # /aionas-done itself is no new message: it must not take "done" back.
      case "$(printf '%s\n' "$_flat" | aionas_json_get prompt)" in /aionas-done | "/aionas-done "*) exit 0 ;; esac
      _aionas_sid_ok "$_sid" && aionas_handoff_cancel "$_sid"
      exit 0
      ;;
    prepare)
      _aionas_sid_ok "${2:-}" || { echo "[aionas-handoff] no session id; ask Claude to write a handoff document for a new conversation."; exit 0; }
      aionas_handoff_instruction "$2" "${3:-$PWD}" 0 0
      exit 0
      ;;
    end)
      _aionas_sid_ok "${2:-}" || { echo "No session id: nothing to stop."; exit 1; }
      aionas_handoff_end "$2"
      exit $?
      ;;
    prompt)
      _aionas_sid_ok "${2:-}" || exit 1
      aionas_handoff_start_prompt "$2"
      exit $?
      ;;
    open-app)
      # The desktop app's own link for a new Code session, with its first
      # message (q) and folder; nothing else is opened.
      case "${2:-}" in "claude://code/new?"*) ;; *) exit 2 ;; esac
      case "$(aionas_os)" in
        darwin) open "$2" ;;
        windows) AIONAS_URL="$2" powershell.exe -NoProfile -NonInteractive -Command 'Start-Process $env:AIONAS_URL' ;;
        *) exit 1 ;;
      esac
      exit $?
      ;;
  esac
  exit 0
fi
