#!/usr/bin/env bash
# aionas-savings hook: usage-probe (SessionStart, async). Owner: AIO-892.
# A member who runs Claude Code in Claude Desktop or the VS Code extension never
# renders the status line, so the status-line tap sends no weekly figure. Once
# an hour at most, on an enrolled computer, when the tap has stored no weekly
# figure in the last hour, this runs Claude Code's own /usage command as a child
# (claude -p "/usage" --no-session-persistence --output-format json, 20 s, from
# ~/.aionas/agent/state/usage-probe, AIONAS_USAGE_PROBE=1 in its environment)
# and sends the weekly percent and reset time as one usage_cmd sample.
# The child starts every plugin hook again: lib/aionas.sh ends any hook that
# sources it while AIONAS_USAGE_PROBE is set (including this one), so nothing
# runs twice. Not enrolled, no claude binary, an API-key login, or a result it
# cannot read: nothing is sent (an unreadable result is counted locally). Prints
# nothing, always exits 0. Details and the path evidence: lib/usage-probe.sh.
set -u
. "$(dirname "$0")/../lib/aionas.sh" 2>/dev/null || exit 0
. "$AIONAS_LIB/usage-probe.sh" 2>/dev/null || exit 0
# A shell job that is killed prints a message on stderr; Claude Code ignores
# hook stderr, so drop it here and keep the hook silent.
exec 2>/dev/null
cat >/dev/null 2>&1 || true
aionas_up_run
exit 0
