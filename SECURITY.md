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
