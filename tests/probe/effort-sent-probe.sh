#!/usr/bin/env bash
# AIO-868 probe: the effort each main-loop request CARRIES, with the real
# plugin loaded (--plugin-dir), on the pinned Claude Code, against the local
# stub (tests/e2e/stub.py: no model, nothing billable), in a temporary HOME
# and CLAUDE_CONFIG_DIR (never the person's own ~/.claude or ~/.aionas).
#
#   bash tests/probe/effort-sent-probe.sh      (CC_BIN=<claude binary> to skip npx)
#
# The window allows and never sets a level: a session opened in it sends its
# usual level until the person picks xhigh or max (/effort, or the app's
# picker: --effort at launch, Extra mid-session as apply_flag_settings, the way
# the desktop app sends it). Outside a window the settings cap
# (maxEffortLevel=high) answers. A mid-session Max in the picker stays at the
# cap: Claude Code drops max from the flag setting, so the plugin cannot see it.
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
PLUGIN="$REPO/plugins/aionas-savings"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/aionas-effort-probe.XXXXXX")
if [ -n "${CC_BIN:-}" ]; then CC=("$CC_BIN"); else CC=(npx -y "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION:-2.1.299}"); fi
fail=0
port=$((21000 + RANDOM % 20000)); log="$ROOT/stub.log"; pol="$ROOT/policy.json"
printf '{"methods":[],"overrides":[]}\n' >"$pol"
python3 -I "$REPO/tests/e2e/stub.py" $port "$log" "$pol" &
stub=$!
trap 'kill $stub 2>/dev/null' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null "http://127.0.0.1:$port/" && break; sleep 0.3; done

# home SETTINGS WINDOW(0|1): a fresh HOME with these Claude settings and, with
# 1, an open window (opened 30 s ago, 9:30 left).
home() {
  local h now
  h=$(mktemp -d "$ROOT/home.XXXXXX"); mkdir -p "$h/.claude" "$h/.aionas/agent/savings"
  printf '%s\n' "$1" >"$h/.claude/settings.json"
  now=$(date +%s)
  [ "$2" = 1 ] && printf '%s\t%s\txhigh\tself\t-\n' $((now - 30)) $((now + 570)) >"$h/.aionas/agent/savings/effort-window"
  echo "$h"
}
# sent HOME ARGS... -- MESSAGES...: one session, stream-json input (one line
# per message; "@picker LEVEL" is the app's mid-session picker), prints the
# effort of each main-loop request, space-separated.
sent() {
  local h=$1; shift
  local args=() msgs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do args+=("$1"); shift; done
  shift
  msgs=("$@")
  : >"$log"
  {
    for m in "${msgs[@]}"; do
      case "$m" in
        "@picker "*)
          printf '{"type":"control_request","request_id":"p%s","request":{"subtype":"apply_flag_settings","settings":{"effortLevel":"%s"}}}\n' $RANDOM "${m#@picker }"
          sleep 2 ;;
        *)
          printf '{"type":"user","message":{"role":"user","content":"%s"}}\n' "$m"
          sleep 6 ;;
      esac
    done
  } | (cd "$ROOT" && env -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDE_CODE_EFFORT_LEVEL -u CLAUDE_CODE_EXTRA_BODY -u CLAUDE_CONFIG_DIR \
    HOME="$h" ANTHROPIC_BASE_URL="http://127.0.0.1:$port" ANTHROPIC_API_KEY=sk-ant-local-stub-not-a-key \
    perl -e 'alarm 120; exec @ARGV' "${CC[@]}" -p --plugin-dir "$PLUGIN" --model claude-opus-5-5 \
    --input-format stream-json --output-format stream-json --verbose "${args[@]}" >"$ROOT/out.jsonl" 2>&1)
  grep '"stream": true' "$log" | sed -n 's/.*"output_config": {"effort": "\([a-z]*\)"}.*/\1/p' | tr '\n' ' ' | sed 's/ $//'
}
check() { # LABEL WANT GOT
  if [ "$2" = "$3" ]; then printf 'PASS %-58s sent: %s\n' "$1" "$3"; else printf 'FAIL %-58s sent: %s (want %s)\n' "$1" "$3" "$2"; fail=1; fi
}

NEW='{"effortLevel":"medium","maxEffortLevel":"high"}'
OLD='{"effortLevel":"high","maxEffortLevel":"high","env":{"CLAUDE_CODE_EFFORT_LEVEL":"high"}}'

check "no window: a new session" "medium" "$(sent "$(home "$NEW" 0)" -- hi)"
check "no window: the app's picker max is capped" "high" "$(sent "$(home "$NEW" 0)" --effort=max -- hi)"
check "no window: /effort xhigh is capped" "high" "$(sent "$(home "$NEW" 0)" -- '/effort xhigh' hi)"
check "window: a new session starts at its usual level" "medium" "$(sent "$(home "$NEW" 1)" -- hi)"
check "window: /effort max, then /effort xhigh, then /effort high" "max xhigh high" \
  "$(sent "$(home "$NEW" 1)" -- '/effort max' hi '/effort xhigh' hi '/effort high' hi)"
check "window: the app launched at Max" "max" "$(sent "$(home "$NEW" 1)" --effort=max -- hi)"
check "window: picker Extra mid-session, then Low" "medium xhigh low" \
  "$(sent "$(home "$NEW" 1)" -- hi '@picker xhigh' hi '@picker low' hi)"
check "window: picker Max mid-session stays at the cap" "medium high" \
  "$(sent "$(home "$NEW" 1)" -- hi '@picker max' hi)"
check "no window: the app launched at Max, picker Extra" "high high" \
  "$(sent "$(home "$NEW" 0)" --effort=max -- hi '@picker xhigh' hi)"
check "window, older install pin high: starts at high, /effort max" "high max" \
  "$(sent "$(home "$OLD" 1)" -- hi '/effort max' hi)"

[ $fail -eq 0 ] && echo "PROBE PASSED" || echo "PROBE FAILED"
exit $fail
