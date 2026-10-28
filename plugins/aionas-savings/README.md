# aionas-savings

The Aionas savings methods for Claude Code: your organization's savings policy, applied on this computer. The full description, the hook table and the shared library are in the [repository README](../../README.md).

## Install

The one install (`aionas-install.sh` / `.ps1`) does this for you. By hand, in a Claude Code session:

```
/plugin marketplace add Aionas-AI/aionas-claude-plugins
/plugin install aionas-savings@aionas
```

It takes effect from the next session.

## What runs

Every hook is `bash "${CLAUDE_PLUGIN_ROOT}/hooks/<name>.sh"` (bash on macOS and Linux, Git Bash on Windows), listed in `hooks/hooks.json`. SessionStart hooks never delay the session: all are async except two that only read local files and print. `unused-services-notice.sh` prints the one-line notice of the MCP servers and skills that were turned off for 30 days without calls (turn one back on with `/mcp`). `write-minimum.sh` prints the "write the minimum" paragraph as session context, byte for byte the lab's tested file (AIO‑889).

The mod (the band above the prompt, the slash commands, the effort grant) is `hooks/mod.tsx`. The band shows in the terminal and the desktop app, not in VS Code (Claude Code 2.1.299).

## Privacy

Only numbers and names leave the computer. Prompts, model replies, tool output and command arguments are never sent.

## Test

```
make test       # from the repository root: hook unit tests, temporary HOME, no network
make validate   # plugin validate + plugin test on Claude Code 2.1.299
```
