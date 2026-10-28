#!/usr/bin/env bash
# aionas-savings hook: write-minimum (SessionStart, not async). Owner: AIO-889.
# The lab's tested method, exactly (lab/methods/write-minimum-code, verdict
# lab/verdicts/write-minimum-code.md): one paragraph added once as SessionStart
# additionalContext, so it stays in the cached prefix. The output is
# write-minimum-context.json, byte for byte the lab's additional-context.json.
# write_minimum off, released or bypassed for this person: prints nothing.
set -u
. "$(dirname "$0")/../lib/aionas.sh" 2>/dev/null || exit 0

input=$(cat 2>/dev/null) || input=""
sid=$(printf '%s' "$input" | aionas_json_flatten 2>/dev/null | aionas_json_get session_id 2>/dev/null) || sid=""
if aionas_policy_active write_minimum "$sid"; then
  cat "$AIONAS_PLUGIN_ROOT/hooks/write-minimum-context.json" 2>/dev/null || exit 0
  aionas_counter_inc write_minimum fired >/dev/null 2>&1
else
  aionas_counter_inc write_minimum skipped >/dev/null 2>&1
fi
exit 0
