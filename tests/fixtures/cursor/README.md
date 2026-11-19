# Cursor hook payloads (AIO-1077)

Recorded from Cursor 3.23.23's hooks log on 2026-11-19 (the live Cursor test
of the aionas-savings plugin through Cursor's Third-Party Imports, hooks of
source `claude-plugin`), one payload per step the plugin's hooks receive:

- `session-start.json`: step `sessionStart` (what every SessionStart hook got)
- `before-submit-prompt.json`: step `beforeSubmitPrompt` (UserPromptSubmit)
- `stop.json`: step `stop` (Stop)

Kept as recorded (keys, key order, numbers, model names, `cursor_version`,
the camelCase `hook_event_name`). Changed before committing, because this
repository is public: the conversation/session and generation ids are fixed
placeholders, `user_email` is `member@example.test`, the prompt text is
removed, and `transcript_path` is the placeholder `__TRANSCRIPT__` (the tests
put a path there). One recorded stop payload repeats `conversation_id` and
`generation_id`; the duplicate keys are not kept.

`transcript.jsonl` has the shape of Cursor's agent transcript (role and
message lines, no usage numbers), with the text removed.
