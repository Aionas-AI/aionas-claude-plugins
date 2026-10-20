#!/usr/bin/env bash
# Scripted `claude -p` checks of the plugin on the pinned Claude Code, against
# a LOCAL stub (tests/e2e/stub.py) that plays both the Messages API (answers
# "ok": no model, nothing billable) and the Aionas machine routes. Everything
# runs in a fresh temporary HOME and CLAUDE_CONFIG_DIR: the person's own
# ~/.claude and ~/.aionas are never read or written.
#
#   bash tests/e2e/claude-p.sh        (needs npx, python3, the npm registry)
#
# Checks: the slash commands run without a model turn and record overrides
# (reason / no reason / sent for approval); an /aionas-xhigh window makes the
# NEXT session's requests carry xhigh/max while the settings stay at high; an
# ended window gives the default again; the policy sync calls the gateway;
# the plugin adds at most a few seconds to `claude -p` with the gateway
# black-holed (W24-P2).
set -u
CC_VERSION=${CLAUDE_CODE_VERSION:-2.1.299}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
PLUGIN="$REPO/plugins/aionas-savings"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/aionas-e2e.XXXXXX")
fail=0
pass() { printf 'PASS %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

port=$((21000 + RANDOM % 20000))
LOG="$ROOT/stub.log"; : >"$LOG"
POLICY="$ROOT/policy.json"
printf '{"methods":[{"method_id":"noisy_guard","state":"on","required":false,"self_override_allowed":true,"self_release_allowed":true}],"overrides":[]}\n' >"$POLICY"
python3 -I "$REPO/tests/e2e/stub.py" "$port" "$LOG" "$POLICY" &
stub=$!
trap 'kill $stub $hole 2>/dev/null' EXIT
hole=""
for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null "http://127.0.0.1:$port/" && break; sleep 0.3; done

export HOME="$ROOT/home"; mkdir -p "$HOME/.claude" "$HOME/.aionas/agent"
export CLAUDE_CONFIG_DIR="$HOME/.claude"
printf '{"effortLevel":"high","maxEffortLevel":"high"}\n' >"$CLAUDE_CONFIG_DIR/settings.json"
printf 'aen-E2ETESTALIAS0123456789\n' >"$HOME/.aionas/agent/credential"
chmod 600 "$HOME/.aionas/agent/credential"
enroll() { printf '{"gateway":"%s","enrollment_id":"enr-E2E","machine_id":"m1","os":"darwin","installer_version":3}\n' "$1" >"$HOME/.aionas/agent/enrollment.json"; }
enroll "http://127.0.0.1:$port"
work="$ROOT/work"; mkdir -p "$work"
unset ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_EXTRA_BODY AIONAS_NOW
export ANTHROPIC_BASE_URL="http://127.0.0.1:$port" ANTHROPIC_API_KEY="sk-ant-local-stub-not-a-key"

cc() { # [--no-plugin] PROMPT -> stdout
  local args=(-p --model claude-opus-5-5)
  if [ "$1" = --no-plugin ]; then shift; else args+=(--plugin-dir "$PLUGIN"); fi
  (cd "$work" && perl -e 'alarm 120; exec @ARGV' npx -y "@anthropic-ai/claude-code@$CC_VERSION" "${args[@]}" "$1" </dev/null 2>"$ROOT/err")
}
efforts() { grep '"/v1/messages' "$LOG" | grep '"stream": true' | sed -n 's/.*"output_config": {"effort": "\([a-z]*\)"}.*/\1/p'; }
mark() { wc -l <"$LOG" | tr -d ' '; }
since() { sed -n "$(($1 + 1)),\$p" "$LOG"; }

# 1. /aionas-bypass with a reason, then without, then blocked.
m=$(mark)
out=$(cc "/aionas-bypass noisy_guard 1h debugging a flaky test")
case "$out" in *"noisy_guard is off for you for 1 hour"*) pass "bypass prints its line" ;; *) bad "bypass output: $out $(head -c 300 "$ROOT/err")" ;; esac
since "$m" | grep -q '"path": "/enroll/v1/savings/overrides".*"reason": "debugging a flaky test"' && pass "override stored with its reason" || bad "no override with reason in $(since "$m")"
since "$m" | grep -q '"path": "/v1/messages' && bad "a model request was made for a slash command" || pass "no model turn for /aionas-bypass"
m=$(mark)
cc "/aionas-bypass long_output_store 1h" >/dev/null
since "$m" | grep '"/enroll/v1/savings/overrides' | grep -q '"method_id": "output_store", "duration_seconds": 3600}' && pass "second override has no reason" || bad "second override: $(since "$m")"
printf '{"methods":[{"method_id":"handoff","state":"on","required":false,"self_override_allowed":false,"self_release_allowed":true}],"overrides":[],"x_blocked":["handoff"]}\n' >"$POLICY"
out=$(cc "/aionas-bypass handoff 2h")
case "$out" in *"sent for approval"*) pass "blocked override is sent for approval" ;; *) bad "blocked: $out" ;; esac
grep -q '"/enroll/v1/savings/policy' "$LOG" && pass "policy sync called GET /enroll/v1/savings/policy" || bad "no policy sync seen"

# 2. Effort: default, an xhigh/max window for NEW sessions, then expiry.
m=$(mark); cc "hi" >/dev/null; base=$(since "$m" | grep '"stream": true' | sed -n 's/.*"effort": "\([a-z]*\)".*/\1/p' | head -1)
printf 'INFO default session effort sent: %s\n' "${base:-none}"
case "$base" in xhigh | max) bad "default session above high: $base" ;; *) pass "default session not above high ($base)" ;; esac
out=$(cc "/aionas-xhigh max trying the window")
case "$out" in *"Sessions you open in the next 10 minutes start at max"*) pass "xhigh window opened" ;; *) bad "xhigh: $out" ;; esac
m=$(mark); cc "hi" >/dev/null
e=$(since "$m" | grep '"stream": true' | sed -n 's/.*"effort": "\([a-z]*\)".*/\1/p' | head -1)
[ "$e" = max ] && pass "new session in the window sends max" || bad "new session in the window sent: ${e:-none}"
t=$(cat "$CLAUDE_CONFIG_DIR/settings.json")
[ "$t" = '{"effortLevel":"high","maxEffortLevel":"high"}' ] && pass "settings stay at high/high" || bad "settings changed: $t"
w="$HOME/.aionas/agent/savings/effort-window"
awk -F '\t' 'BEGIN { OFS = "\t" } { $1 = 1; $2 = 2; print }' "$w" >"$w.x" && mv "$w.x" "$w"
m=$(mark); cc "hi" >/dev/null
e=$(since "$m" | grep '"stream": true' | sed -n 's/.*"effort": "\([a-z]*\)".*/\1/p' | head -1)
[ "$e" = "$base" ] && pass "after the window a new session is back to the default ($e)" || bad "after the window: ${e:-none} (default $base)"

# 3. W24-P2: a black-holed gateway costs `claude -p` at most a few seconds.
python3 -I -c '
import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(16); c = []
end = time.time() + 120
s.settimeout(0.5)
while time.time() < end:
    try: c.append(s.accept()[0])
    except socket.timeout: pass
' $((port + 1)) &
hole=$!
enroll "http://127.0.0.1:$((port + 1))"
t1=$(date +%s); cc --no-plugin "hi" >/dev/null; t2=$(date +%s)
cc "hi" >/dev/null; t3=$(date +%s)
printf 'INFO claude -p without the plugin: %s s, with it and the gateway black-holed: %s s\n' $((t2 - t1)) $((t3 - t2))
[ $((t3 - t2 - (t2 - t1))) -le 5 ] && pass "black-holed gateway adds at most 5 s" || bad "black-holed gateway added $((t3 - t2 - (t2 - t1))) s"

[ $fail -eq 0 ] && echo "E2E PASSED" || echo "E2E FAILED"
exit $fail
