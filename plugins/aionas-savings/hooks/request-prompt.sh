#!/usr/bin/env bash
# aionas-savings hook: request-prompt (UserPromptSubmit). Owner: AIO-1073.
# Keeps the id of the prompt this session is on (Claude Code's prompt_id), so
# a method that acts later in the turn (the mod's sub-agent start) is
# recorded for that prompt and no other (lib/requests.sh). The prompt itself
# is never read into a file. Prints nothing, exits 0.
# Runs under Cursor too (AIO-1077): Cursor's beforeSubmitPrompt has no
# prompt_id, so its generation_id (one per prompt) is the prompt id there, and
# the marks of that turn go to Cursor's spool (lib/requests.sh).
set -u
. "$(dirname "$0")/../lib/aionas.sh" 2>/dev/null || exit 0
_in=$(cat 2>/dev/null) || _in=''
_flat=$(printf '%s' "$_in" | aionas_json_flatten 2>/dev/null)
_key=prompt_id
[ "$(aionas_client)" = cursor ] && _key=generation_id
aionas_request_prompt "$(printf '%s\n' "$_flat" | aionas_json_get session_id)" \
  "$(printf '%s\n' "$_flat" | aionas_json_get "$_key")" >/dev/null 2>&1
exit 0
