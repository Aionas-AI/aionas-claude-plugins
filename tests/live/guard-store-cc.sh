#!/usr/bin/env bash
# Live check of the guard and store hooks inside a real Claude Code
# (AIO-860): Claude Code 2.1.299 runs "claude -p" against a scripted local
# stand-in for the Messages API (tests/live/fake-anthropic.py, 127.0.0.1
# only), so no model and no account are used. Everything lives in fresh
# mktemp folders (HOME and CLAUDE_CONFIG_DIR too): the real ~/.claude is never
# touched. Prints the bytes of each tool result that reached the model, then
# checks them. Not part of "make test" (needs npx, node and python3).
#
#   bash tests/live/guard-store-cc.sh            # npx @anthropic-ai/claude-code@2.1.299
#   CLAUDE_BIN=/path/to/claude bash tests/live/guard-store-cc.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$here/../.." && pwd)
plugin_src="$repo_root/plugins/aionas-savings"
W=$(mktemp -d "${TMPDIR:-/tmp}/aionas-cc-live.XXXXXX")
echo "work dir: $W"
mkdir -p "$W/home" "$W/cfg" "$W/repo"

# The plugin as it would ship, with hooks.json naming this lane's two hooks.
cp -R "$plugin_src" "$W/plugin"
cat >"$W/plugin/hooks/hooks.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/pretool-guard.sh\"", "timeout": 10}]}],
    "PostToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/posttool-store.sh\"", "timeout": 30}]}]
  }
}
EOF

# The test repo: a big log, a passing and a failing noisy script, a long git log.
cd "$W/repo" || exit 1
awk 'BEGIN { for (i = 1; i <= 300; i++) printf "%s 2026-10-20T10:%02d:00Z worker-%d handled request %d in %d ms\n", (i % 97 == 0 ? "ERROR" : "INFO "), i % 60, i % 7, i, i * 3 }' >big.log
printf '#!/bin/sh\nawk '"'"'BEGIN { for (i = 1; i <= 300; i++) printf "test_case_%%03d PASSED  some padding to make it long enough to count\\n", i }'"'"'\n' >gen.sh
printf '#!/bin/sh\nawk '"'"'BEGIN { for (i = 1; i <= 300; i++) printf "step %%03d ok padding padding padding padding padding\\n", i; print "Error: step 301 broke" }'"'"'\nexit 1\n' >fail.sh
chmod +x gen.sh fail.sh
git init -q . && git config user.email t@example.test && git config user.name t
for i in $(seq 1 60); do echo "$i" >n.txt; git add n.txt && git commit -q -m "commit number $i with a fairly long subject line to make the log noisy"; done

cat >"$W/steps.txt" <<'EOF'
cat big.log
aionas-recall {id} --grep ERROR
./gen.sh
AIONAS_FULL=1 ./gen.sh
git log
./fail.sh
AIONAS_FULL=1 git log
EOF
FAKE_DUMP="$W/requests.jsonl" python3 "$here/fake-anthropic.py" "$W/port" "$W/log.jsonl" "$W/steps.txt" &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
for _ in $(seq 1 50); do [ -s "$W/port" ] && break; sleep 0.1; done
port=$(cat "$W/port")

unset AI_AGENT AIONAS_CC_VERSION AIONAS_FULL CLAUDECODE CLAUDE_CODE_ENTRYPOINT
HOME="$W/home" CLAUDE_CONFIG_DIR="$W/cfg" \
  ANTHROPIC_BASE_URL="http://127.0.0.1:$port" ANTHROPIC_API_KEY=sk-fake-local-only \
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1 DISABLE_TELEMETRY=1 \
  ${CLAUDE_BIN:-npx -y @anthropic-ai/claude-code@2.1.299} -p "run the scripted steps" \
  --plugin-dir "$W/plugin" --permission-mode "${CC_PERMISSION_MODE:-bypassPermissions}" --output-format json >"$W/result.json" 2>"$W/stderr.txt"
echo "claude exit: $?"

python3 "$here/guard-store-check.py" "$W/requests.jsonl" "$W/repo"
rc=$?
echo "--- counters queued on this computer:"
cat "$W/home/.aionas/agent/savings/counters/queue.tsv" 2>/dev/null
echo "--- store status: $(cat "$W/home/.aionas/agent/savings/store.status" 2>/dev/null)"
exit $rc
