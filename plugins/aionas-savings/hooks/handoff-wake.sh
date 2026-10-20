#!/usr/bin/env bash
# aionas-savings handoff: shared functions and the delivery step. Owner: AIO-858.
#
# Source it (stop-handoff.sh does), or run it:
#   handoff-wake.sh cancel                 UserPromptSubmit: a prompt cancels the timer (reads the hook input)
#   handoff-wake.sh prepare SESSION [CWD]  print the handoff instruction and write the launcher (/aionas-handoff)
#
# State, under $(aionas_savings_dir)/handoff/ (numbers and names only, never content):
#   <sid>.armed   the token of the one live timer; a timer whose token differs, or whose file is gone, quits
#   <sid>.done    exists once the instruction was delivered: one handoff per session
#   <sid>.state   "<status><TAB><epoch><TAB><context tokens>"; status armed | cancelled | delivered
#                 (the plugin band reads it: delivered -> "Compact recommended")
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

# aionas_handoff_status SID STATUS [TOKENS]: record the status for the band.
aionas_handoff_status() {
  printf '%s\t%s\t%s\n' "$2" "$(aionas_now)" "${3:-0}" | aionas_write_atomic "$(aionas_handoff_dir)/$1.state"
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
1. Write a handoff document for a fresh conversation to $_in_md . Cover: the goal; what is done; what is left, in order; decisions and why; the files and commands that matter; how to check the work; open questions. Leave out secrets and credentials.
2. Print a short starting prompt for the new conversation (two or three sentences that point at that file).
A launcher that opens a new Claude Code session with that prompt is already saved at $_in_op .
Do not run /compact and do not change any setting. When both are done, say the handoff is ready and stop.
MSG
}

# aionas_handoff_deliver SID CWD TOKEN TOKENS MINUTES: the wake. Exit 2 with
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
  aionas_handoff_status "$1" delivered "$4"
  aionas_counter_inc handoff fired >/dev/null 2>&1
  printf '%s\n' "$_dv_msg" >&2
  return 2
}

# aionas_handoff_cancel SID: a prompt arrived.
aionas_handoff_cancel() {
  if aionas_handoff_disarm "$1"; then
    aionas_handoff_status "$1" cancelled 0
    aionas_counter_inc handoff skipped >/dev/null 2>&1
  fi
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    cancel)
      _in=$(cat 2>/dev/null)
      _sid=$(printf '%s' "$_in" | aionas_json_flatten 2>/dev/null | aionas_json_get session_id)
      _aionas_sid_ok "$_sid" && aionas_handoff_cancel "$_sid"
      exit 0
      ;;
    prepare)
      _aionas_sid_ok "${2:-}" || { echo "[aionas-handoff] no session id; ask Claude to write a handoff document for a new conversation."; exit 0; }
      aionas_handoff_instruction "$2" "${3:-$PWD}" 0 0
      exit 0
      ;;
  esac
  exit 0
fi
