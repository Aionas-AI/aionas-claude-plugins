# Security

This plugin runs on the computers of Aionas customers. Please report a
vulnerability privately through **Security → Report a vulnerability** on this
repository. Do not open a public issue.

How a change reaches customer computers:

- `main` accepts changes only through a reviewed pull request (ruleset
  `main-protected`: a code-owner approval from someone other than the last
  pusher, the `ci` checks, no force push, no deletion).
- What the plugin runs and sends is listed in `security/egress-manifest.txt`;
  CI fails when the code and that list disagree.
- Release tags `aionas-savings-v*` cannot be moved or deleted.

What leaves the computer, beyond numbers and names: at most once every 4 hours,
on a session start on an enrolled computer signed in with a Claude subscription,
when the status-line tap has no figure from the last 4 hours (this includes
terminal users without the tap), the plugin sends the full text of Claude Code's own `/usage` result (at most 32 KiB) to the
organization's own gateway, by the owner's ruling, so the gateway can read the
weekly figure and keep the text when it cannot. Besides the usage lines, that
text has Claude Code's "What's contributing" section: local folder names,
skill, sub-agent, MCP and plugin names (the "Top plugins:" line), and request counts. Prompts and model replies
never leave. The plugin does not parse the text and never reads a login token.

Two samples go to `POST /cc-quota/v1/samples` on the organization's own gateway (AIO‑1072, field by field):

- **Plan report** (once a day, or at once when the plan or organization changes): `tool` (`claude_code`), `source` (`plan_usage`), `observed_at`, `plan.vendor_plan_id`, and from Claude's login file, when present: `account_uuid`, `organization_uuid` and `organization_name` (the Claude organization's id and name; control and bidi characters dropped, at most 128 characters).
- **Usage probe** (at most every 4 hours): `tool`, `source` (`usage_cmd`), `observed_at`, the same `account_uuid`, `organization_uuid` and `organization_name`, `claude_version` (only when the install folder names it), `windows` (`weekly_all`, 10080 minutes), and `usage_raw`: the **full text** of Claude Code's own `/usage` result, at most 32 KiB. That text includes Claude Code's "What's contributing" section: local folder names, skill, sub-agent, MCP and plugin names, and request counts.
