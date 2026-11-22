# git-event payloads (AIO-1088)

PostToolUse payloads of the shapes Claude Code documents (Bash: `tool_input.command`,
`tool_response.{stdout,stderr,interrupted}`; a failed call arrives as
`PostToolUseFailure` with `error`) and Cursor 3.23.x sends (`postToolUse`, tool
`Shell`, `tool_input.command`, `tool_output` text, `cursor_version`, camelCase
event name; the session/conversation ids are the same placeholders as
`../cursor`). The Cursor Shell payload was NOT recorded from a live Cursor: it is
built from Cursor's hook docs and the recorded neighbours, and is a live proof
item. `__CWD__` and `__TRANSCRIPT__` are replaced by the tests. The CANARY and
"secret message" strings must never appear in anything the hook sends or writes.
