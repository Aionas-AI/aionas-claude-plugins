#!/usr/bin/env bash
# aionas-savings hook: handoff-cancel (UserPromptSubmit). Owner: AIO-858.
# A new prompt cancels the handoff timer. The work is in handoff-wake.sh.
# Claude Code only (AIO-1077): under Cursor it exits 0 at once. The payload
# read by lib/aionas.sh is put back on stdin for handoff-wake.sh.
. "$(dirname "$0")/../lib/aionas.sh" 2>/dev/null || { cat >/dev/null 2>&1; exit 0; }
aionas_claude_code_only
exec bash "$(dirname "$0")/handoff-wake.sh" cancel
