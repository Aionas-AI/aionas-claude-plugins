# aionas-savings shared library. Source it from a hook:
#   . "$(dirname "$0")/../lib/aionas.sh"
# POSIX sh (bash 3.2 on macOS, dash, Git Bash on Windows); needs only awk,
# grep, tr, date, mkdir, mv, rm and curl. Nothing here prints content: the
# only network calls are the policy fetch, the counters send and the
# per-request records (lib/requests.sh).
# Recursion guard (W25-e, AIO-892): the usage probe runs Claude Code as a child
# with AIONAS_USAGE_PROBE set, and that child starts every plugin hook again.
# Every hook sources this file before it does anything, so this one line, the
# first code line of the library, ends any shell that sources it while the
# variable is set: exit 0, no request, no file, no output.
if [ -n "${AIONAS_USAGE_PROBE:-}" ]; then exit 0; fi
if [ -z "${AIONAS_LIB:-}" ]; then
  if [ -n "${BASH_SOURCE:-}" ]; then
    AIONAS_LIB=$(cd "$(dirname "${BASH_SOURCE}")" && pwd)
  elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    AIONAS_LIB="$CLAUDE_PLUGIN_ROOT/lib"
  fi
fi
AIONAS_PLUGIN_ROOT=${AIONAS_PLUGIN_ROOT:-$(dirname "$AIONAS_LIB")}
. "$AIONAS_LIB/platform.sh"
. "$AIONAS_LIB/json.sh"
. "$AIONAS_LIB/catalog.sh"
. "$AIONAS_LIB/enroll.sh"
. "$AIONAS_LIB/http.sh"
. "$AIONAS_LIB/policy.sh"
. "$AIONAS_LIB/counters.sh"
. "$AIONAS_LIB/requests.sh"

# --- Which app runs this hook (AIO-1077, wave 33) -------------------------
# Cursor's "Third-Party Imports" runs this plugin's hooks too (source
# claude-plugin), with its own payload: a top-level "cursor_version" and a
# camelCase "hook_event_name" (sessionStart, beforeSubmitPrompt, stop), where
# Claude Code sends "SessionStart", "UserPromptSubmit", "Stop". The payload
# decides; the environment is only the fallback when a caller has no payload
# at all (CURSOR_VERSION, unless CLAUDECODE says Claude Code started it), so
# Claude Code started in a Cursor terminal stays claude_code. Anything else is
# claude_code. Only the two names ever leave this function.

# aionas_client_of PAYLOAD: print cursor or claude_code for one hook payload.
# A quick look at the text first; a match is confirmed on the parsed top-level
# keys, so a prompt that merely quotes "cursor_version" does not count.
aionas_client_of() {
  case "${1:-}" in
    '')
      if [ -n "${CURSOR_VERSION:-}" ] && [ -z "${CLAUDECODE:-}" ]; then echo cursor; else echo claude_code; fi
      return 0
      ;;
    *'"cursor_version"'* | *'"hook_event_name":"'[a-z]* | *'"hook_event_name": "'[a-z]*) ;;
    *) echo claude_code; return 0 ;;
  esac
  printf '%s' "$1" | aionas_json_flatten 2>/dev/null | awk -F '\t' '
    $1 == "cursor_version" && $2 == "s" && $3 != "" { c = 1 }
    $1 == "hook_event_name" && $2 == "s" { e = $3 }
    END { print (c || e ~ /^[a-z]/) ? "cursor" : "claude_code" }'
}

# aionas_client [PAYLOAD]: cursor or claude_code for this hook: what the hook
# input said (read once below), else PAYLOAD, else the environment.
aionas_client() {
  case "${_AIONAS_CLIENT:-}" in cursor | claude_code) echo "$_AIONAS_CLIENT"; return 0 ;; esac
  aionas_client_of "${1:-}"
}

# aionas_claude_code_only: end a Claude-Code-only hook at once, silently,
# under Cursor (the hook table is in the AIO-1077 commit).
aionas_claude_code_only() {
  [ "$(aionas_client)" = cursor ] && exit 0
  return 0
}

# The hooks only an app starts, always with its JSON payload on stdin (never
# the mod or a command, which pass arguments). For these the payload is read
# here once, the app is decided, and the same bytes are put back on stdin, so
# the hook's own "cat" reads them unchanged (a trailing newline added, which
# "$(cat)" drops). write-minimum.sh is listed so its counters land in the right
# app's queue. AIONAS_HOOK_INPUT keeps the payload for the hook.
AIONAS_PAYLOAD_HOOKS=" usage-probe.sh plan-report.sh effort-window.sh daily-scan.sh unused-services.sh unused-services-notice.sh handoff-cancel.sh stop-handoff.sh request-prompt.sh write-minimum.sh "
if [ -z "${_AIONAS_HOOK_READ:-}" ]; then
  _AIONAS_HOOK_READ=1
  _AIONAS_CLIENT=''
  AIONAS_HOOK_INPUT=''
  case "$AIONAS_PAYLOAD_HOOKS" in
    *" ${0##*/} "*)
      if [ $# -eq 0 ] && [ ! -t 0 ]; then
        AIONAS_HOOK_INPUT=$(cat 2>/dev/null) || AIONAS_HOOK_INPUT=''
        _AIONAS_CLIENT=$(aionas_client_of "$AIONAS_HOOK_INPUT")
        exec 0<<AIONAS_HOOK_INPUT_END
$AIONAS_HOOK_INPUT
AIONAS_HOOK_INPUT_END
      fi
      ;;
  esac
fi

# aionas_plugin_version: the version in .claude-plugin/plugin.json.
aionas_plugin_version() {
  aionas_json_flatten "$AIONAS_PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null | aionas_json_get version
}
