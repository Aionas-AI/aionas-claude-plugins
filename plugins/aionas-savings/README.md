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

The mod (the band above the prompt, the slash commands, the effort grant) is `hooks/mod.tsx`. The band shows in the terminal and the desktop app, not in VS Code (Claude Code 2.1.299). On Windows the mod runs its scripts with Git Bash found from `CLAUDE_CODE_GIT_BASH_PATH` or the standard Git for Windows folders, never from `PATH` (AIO‑905); where it is missing the band says so, and the path found is in `~/.aionas/agent/state/git-bash-path`.

## Privacy

Apart from the `/usage` text below, only numbers, ids and names leave the computer, and only to the gateway it is enrolled with. Prompts, model replies, tool output and command arguments are never sent.

Two samples go to `POST /cc-quota/v1/samples` on the organization's own gateway (AIO‑1072, field by field):

- **Plan report** (once a day, or at once when the plan or organization changes): `tool` (`claude_code`), `source` (`plan_usage`), `observed_at`, `plan.vendor_plan_id`, and from Claude's login file, when present: `account_uuid`, `organization_uuid` and `organization_name` (the Claude organization's id and name; control and bidi characters dropped, at most 128 characters).
- **Usage probe** (at most every 4 hours): `tool`, `source` (`usage_cmd`), `observed_at`, the same `account_uuid`, `organization_uuid` and `organization_name`, `claude_version` (only when the install folder names it), `windows` (`weekly_all`, 10080 minutes), and `usage_raw`: the **full text** of Claude Code's own `/usage` result, at most 32 KiB. That text includes Claude Code's "What's contributing" section: local folder names, skill, sub-agent, MCP and plugin names, and request counts.

The full list of what the plugin sends is in the [repository README](../../README.md) and `security/egress-manifest.txt`.

## Test

```
make test       # from the repository root: hook unit tests, temporary HOME, no network
make validate   # plugin validate + plugin test on Claude Code 2.1.299
```
