# Prompt ids without `prompt_id` (AIO-1099, W33-13)

Claude Desktop's Code tab sends its hooks no `prompt_id`. Its transcript still
puts `"promptId"` on each turn's user lines. Tal confirmed this on 22.11: a
terminal session's prompt file held the transcript's latest promptId, and a
Desktop session had none.

- `user-prompt-submit-terminal.json`: the UserPromptSubmit input of a terminal
  `claude` session. It has the documented common fields plus `prompt_id`.
- `user-prompt-submit-desktop.json`: the same input from Claude Desktop, without
  `prompt_id`.
- `stop-desktop.json`: the Stop input from Claude Desktop, without `prompt_id`.
- `transcript.jsonl`: a Desktop transcript (Claude Code 2.1.326, `entrypoint`
  `claude-desktop`). It has the line types and key order of a real one, read from
  a 22.11 session (keys only). Ids, text and paths are replaced. Turn 1 is
  `00000000-0000-4000-8000-0000000d0001`. Its user line carries a prompt text that
  itself spells `"promptId":"FAKE-IN-TEXT"`, as JSON writes it (escaped), so that
  text must never be read as an id. A tool result line of turn 1 follows, then an
  answer.
- `transcript-turn2.jsonl`: the lines Claude Code appends after the next prompt
  (turn 2, `...0d0002`). The UserPromptSubmit hook runs before they are written.

`@TRANSCRIPT@` stands for the transcript's path, and `@SID@` for the session id.
The hook inputs are not byte captures: Claude Code prints no hook input. Their
keys follow the hooks reference. The one difference that matters is that
`prompt_id` is present or absent.
