# Cursor stop payloads for the handoff (AIO-1079)

Derived from the recorded `../cursor/stop.json` (Cursor 3.23.23, 2026-11-19):
same keys and order, only `status`, `loop_count` and the token numbers changed;
`transcript_path` is null (the handoff reads no transcript). Ids are the same
placeholders as there.

- `stop-below.json`: 35406 + 12288 tokens (the recorded numbers)
- `stop-at-threshold.json`: 150000 + 60000 = 210000
- `stop-loop1.json`: the stop of the follow-up turn (`loop_count` 1)
- `stop-aborted.json`: `status` aborted
- `stop-context-tokens.json`: carries `context_tokens` 230000 (preCompact's name) beside small input numbers

`followup-message.txt` is the exact `followup_message` text the hook answers
for `stop-at-threshold.json` (W33-10: Cursor's own wording, no band, no
launcher, no `claude --resume`). `@HANDOFF_FILE@` and `@SID@` stand for the
person's local handoff file and the conversation id.
