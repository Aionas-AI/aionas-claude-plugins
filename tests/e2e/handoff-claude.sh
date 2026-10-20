#!/usr/bin/env bash
# Scripted Claude Code 2.1.299 run for AIO-858 (not part of `make test`: needs npx and the npm registry).
#   bash tests/e2e/handoff-claude.sh
# Claude Code runs in a temporary HOME / CLAUDE_CONFIG_DIR against a local mock of the Messages
# API (no real model, no account, no real HOME). The plugin is loaded with --plugin-dir, the policy
# is lowered to 20K tokens / 2 s idle, and one streaming session is kept open. Passes when:
#   - the same session gets exactly one handoff instruction after the idle time (second model call),
#   - the handoff folder holds the opener and the state, and no new session was created by the hook,
#   - a second run with a prompt sent before the deadline gets no instruction.
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
CC=${CLAUDE_CODE_VERSION:-2.1.299}
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/aionas-e2e.XXXXXX")
fail() { echo "FAIL: $*" >&2; exit 1; }

# waitfor FILE PATTERN COUNT SECONDS: wait until PATTERN occurs on COUNT lines of FILE.
waitfor() { local i=0; while [ "$(grep -c -- "$2" "$1" 2>/dev/null)" -lt "$3" ] && [ $i -lt $(($4 * 4)) ]; do sleep 0.25; i=$((i + 1)); done; [ "$(grep -c -- "$2" "$1" 2>/dev/null)" -ge "$3" ]; }

run_case() { # NAME SECOND_PROMPT_DELAY|none IDLE_SECONDS
  local name=$1 delay=$2 idle=$3 d="$ROOT/$1"
  mkdir -p "$d/home" "$d/cfg" "$d/proj" "$d/sav"
  export MOCK_LOG="$d/mock.log" MOCK_PORT_FILE="$d/port"; : >"$MOCK_LOG"
  MOCK_CONTEXT_TOKENS=${CONTEXT:-30000} node "$REPO/tests/e2e/mock-anthropic.js" & local srv=$!
  local i=0; while [ ! -s "$d/port" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  printf 'V\t1\nF\t1\nM\thandoff\ton\t0\t1\t1\t0\nP\thandoff\tthreshold_tokens\tn\t20000\nP\thandoff\tidle_minutes\tn\t2\n' >"$d/sav/policy.cache"
  local first=${FIRST_PROMPT:-first prompt}
  local m1="{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"$first\"}}" m2='{"type":"user","message":{"role":"user","content":"second prompt"}}'
  (
    cd "$d/proj" || exit 1
    export MOCK_CONTEXT_TOKENS=${CONTEXT:-30000}
    export HOME="$d/home" CLAUDE_CONFIG_DIR="$d/cfg" AIONAS_SAVINGS_DIR="$d/sav" AIONAS_AGENT_DIR="$d/home/.aionas/agent" \
      ANTHROPIC_BASE_URL="http://127.0.0.1:$(cat "$d/port")" ANTHROPIC_API_KEY=sk-ant-local-mock-not-a-key \
      DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_TELEMETRY=1 \
      AIONAS_HANDOFF_IDLE_SECONDS=$idle AIONAS_HANDOFF_POLL_SECONDS=1
    { printf '%s\n' "$m1"
      waitfor "$d/out.jsonl" '"type":"result"' 1 90
      if [ "$delay" = none ]; then
        # stay idle: the instruction arrives as a second model call; let it be answered
        waitfor "$d/mock.log" ' 1 1' 1 30 || true
        sleep 2
      else
        # a prompt before the deadline (idle 8 s): the first timer must not fire
        sleep "$delay"; printf '%s\n' "$m2"
        waitfor "$d/out.jsonl" '"type":"result"' 2 60
        sleep 7
      fi
    } | npx -y "@anthropic-ai/claude-code@$CC" -p --input-format stream-json --output-format stream-json --verbose \
        --plugin-dir "$REPO/plugins/aionas-savings" >"$d/out.jsonl" 2>"$d/err.txt"
  )
  kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null
  echo "$d"
}

d=$(run_case idle none 3 | tail -n 1)
echo "--- idle case: mock calls (n instruction stream)"; cat "$d/mock.log"
[ "$(awk '$2 == 1' "$d/mock.log" | wc -l | tr -d ' ')" = 1 ] || fail "expected exactly one handoff instruction"
sids=$(grep -o '"session_id":"[^"]*"' "$d/out.jsonl" | sort -u | wc -l | tr -d ' ')
[ "$sids" = 1 ] || fail "expected one session id, saw $sids"
ls "$d/sav/handoff" | grep -q '^opener-.*\.sh$' || fail "no opener file"
grep -q delivered "$d/sav/handoff/"*.state || fail "state not delivered"
grep -q 'handoff	fired	1' "$d/sav/counters/queue.tsv" || fail "the delivery was not counted"

d=$(run_case prompt 1 8 | tail -n 1)
echo "--- prompt case: mock calls"; cat "$d/mock.log"
[ "$(awk '$2 == 1' "$d/mock.log" | wc -l | tr -d ' ')" = 0 ] || fail "a prompt before the deadline must cancel the timer"
[ "$(grep -c '"type":"result"' "$d/out.jsonl")" = 2 ] || fail "both prompts should have been answered"
grep -q 'handoff	skipped	1' "$d/sav/counters/queue.tsv" || fail "the cancel was not counted"

d=$(FIRST_PROMPT=/aionas-savings:aionas-handoff CONTEXT=1000 run_case command none 3 | tail -n 1)
echo "--- command case: mock calls"; cat "$d/mock.log"
awk '$1 == 1 && $2 == 1' "$d/mock.log" | grep -q . || fail "/aionas-handoff did not put the instruction in the first model call"
ls "$d/sav/handoff" | grep -q '^opener-.*\.sh$' || fail "/aionas-handoff wrote no opener"
[ "$(grep -c '"type":"result"' "$d/out.jsonl")" = 1 ] || fail "the command case should have one answered turn"
echo "PASS (temp dirs under $ROOT)"
