#!/usr/bin/env bash
# aionas-savings hook: handoff-cancel (UserPromptSubmit). Owner: AIO-858.
# A new prompt cancels the handoff timer. The work is in handoff-wake.sh.
exec bash "$(dirname "$0")/handoff-wake.sh" cancel
