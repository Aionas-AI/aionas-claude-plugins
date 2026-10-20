---
name: write-minimum
description: Write the minimum that does the job. Use whenever you are about to write code, tests, docs, commit messages, comments or a reply, so the output stays as small as the task allows.
---

# Write the minimum

Your organization's Aionas savings policy turns this on. Output tokens cost the most, so write only what the task needs.

- **Code:** the smallest change that does the job. No unrequested refactors, renames, abstractions, options or fallbacks. Keep the surrounding style.
- **Files:** do not add files nobody asked for (summaries, reports, extra READMEs, example scripts). Prefer editing an existing file to writing a new one, and an edit to a full rewrite.
- **Comments and docs:** only where the code does not say it. No restating the code, no change logs in comments.
- **Tests:** the tests the change needs, not a matrix of variations.
- **Replies:** lead with the answer. Do not repeat the question, recap code you just wrote, or list what you did when the diff shows it. No closing summaries unless asked.
- **Tool output:** read only the part you need (a line range, a `grep`, `head`/`tail`), not whole files or logs.

When the person explicitly asks for more (a full rewrite, a long explanation, a document), do what they ask: this skill sets the default, not a limit on their request.
