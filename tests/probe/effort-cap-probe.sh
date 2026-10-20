#!/usr/bin/env bash
# AIO-859 probe (W24-3), on the pinned Claude Code, in a temporary
# CLAUDE_CONFIG_DIR (never the person's own ~/.claude), no login and no model:
#  (a) does maxEffortLevel=high in user settings cap /effort?
#  (b) does a RUNNING session pick up a settings change (hot reload)?
#  (c) what reaches the request: effortLevel in settings, --effort under the
#      cap, and CLAUDE_CODE_EXTRA_BODY under the cap (local stub, no model).
#
#   bash tests/probe/effort-cap-probe.sh
#
# Result on 2.1.299 (2026-10-20), which hooks/effort-window.sh is built on:
#  (a) YES: "/effort xhigh" -> "Effort 'xhigh' exceeds the cap ...; set to
#      'high' instead"; with the cap at max, "/effort max" is accepted.
#  (b) YES, it hot-reloads: raising maxEffortLevel to max in a running session
#      lets "/effort xhigh" through at once. So the window must NOT write
#      maxEffortLevel (it would raise open sessions, and restoring high would
#      clamp the window's own sessions).
#  (c) effortLevel in user settings is not applied to `claude -p` (medium is
#      sent for "high" and for "low"); --effort xhigh is clamped to high;
#      CLAUDE_CODE_EXTRA_BODY {"output_config":{"effort":"max"}} is sent as
#      max under maxEffortLevel=high (documented: "not clamped").
set -u
CC="npx -y @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION:-2.1.299}"
REPO=$(cd "$(dirname "$0")/../.." && pwd)
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/aionas-probe.XXXXXX")
clean_env() { env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_BASE_URL -u CLAUDE_CODE_EXTRA_BODY "$@"; }
cfg() { local d; d=$(mktemp -d "$ROOT/cfg.XXXXXX"); printf '%s\n' "$1" >"$d/settings.json"; echo "$d"; }

echo "== (a) maxEffortLevel=high caps /effort"
c=$(cfg '{"effortLevel":"high","maxEffortLevel":"high"}')
(cd "$ROOT" && clean_env CLAUDE_CONFIG_DIR="$c" perl -e 'alarm 90; exec @ARGV' $CC -p "/effort xhigh" </dev/null)
c=$(cfg '{"effortLevel":"high","maxEffortLevel":"max"}')
(cd "$ROOT" && clean_env CLAUDE_CONFIG_DIR="$c" perl -e 'alarm 90; exec @ARGV' $CC -p "/effort max" </dev/null)

echo "== (b) a running session and a settings change"
c=$(cfg '{"effortLevel":"high","maxEffortLevel":"high"}')
fifo="$ROOT/in"; mkfifo "$fifo"
(cd "$ROOT" && clean_env CLAUDE_CONFIG_DIR="$c" $CC -p --input-format stream-json --output-format stream-json --verbose <"$fifo" >"$ROOT/b.jsonl" 2>/dev/null) &
pid=$!
exec 3>"$fifo"
say() { printf '{"type":"user","message":{"role":"user","content":"%s"}}\n' "$1" >&3; sleep 8; }
say "/effort xhigh"
printf '{"effortLevel":"high","maxEffortLevel":"max"}\n' >"$c/settings.json"
sleep 6
say "/effort xhigh"
exec 3>&-
sleep 3; kill $pid 2>/dev/null
grep -o '"result":"[^"]*"' "$ROOT/b.jsonl"

echo "== (c) what the request carries (local stub, no model)"
port=$((21000 + RANDOM % 20000)); log="$ROOT/stub.log"; pol="$ROOT/policy.json"
printf '{"methods":[],"overrides":[]}\n' >"$pol"
python3 -I "$REPO/tests/e2e/stub.py" $port "$log" "$pol" &
stub=$!
sleep 1
one() { # LABEL SETTINGS [env...] -- args
  local label=$1 s=$2; shift 2
  local c; c=$(cfg "$s"); : >"$log"
  (cd "$ROOT" && env -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR="$c" \
    ANTHROPIC_BASE_URL="http://127.0.0.1:$port" ANTHROPIC_API_KEY=sk-ant-local-stub-not-a-key "$@" </dev/null >/dev/null 2>&1)
  printf '%-48s %s\n' "$label" "$(grep '"stream": true' "$log" | grep -o '"effort": "[a-z]*"' | head -1)"
}
one "effortLevel=high (settings)" '{"effortLevel":"high","maxEffortLevel":"high"}' $CC -p --model claude-opus-5-5 hi
one "effortLevel=low (settings)" '{"effortLevel":"low"}' $CC -p --model claude-opus-5-5 hi
one "env CLAUDE_CODE_EFFORT_LEVEL=high" '{"env":{"CLAUDE_CODE_EFFORT_LEVEL":"high"}}' $CC -p --model claude-opus-5-5 hi
one "--effort xhigh, cap high" '{"maxEffortLevel":"high"}' $CC -p --model claude-opus-5-5 --effort xhigh hi
one "EXTRA_BODY max, cap high" '{"maxEffortLevel":"high"}' env CLAUDE_CODE_EXTRA_BODY='{"output_config":{"effort":"max"}}' $CC -p --model claude-opus-5-5 hi
kill $stub 2>/dev/null
