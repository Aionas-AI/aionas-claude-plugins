# aionas-savings changelog

Each release is the git tag `aionas-savings-vX.Y.Z`. With auto-update on, Claude Code picks a release up from the marketplace; it applies from the next session.

## Unreleased (0.5.0)

- **Plan detection reads the member's own tier, knows Ultra, and names the Claude organization** (AIO‑899, AIO‑900, AIO‑901): the plan report uses `userRateLimitTier` (else the organization's) so a Team premium seat is `team_premium`; a tier containing `ultra` is `max_20x` (plan ids are unchanged); every sample also carries `organization_uuid` and a cleaned `organization_name` when Claude Code has them.
- **The installed plan collector and status-line tap refresh themselves** (AIO‑904): once a UTC day, at session start, an enrolled computer asks the gateway for the current release of `aionas-plan-usage` and `aionas-statusline-tap` (`.sh` and `.ps1`) and, for a script that is already installed and differs, downloads it from the gateway's public route without sending the enrollment alias. It installs only after the sha256 matches (hash tool at a fixed system path, never `PATH`), a `.sh` starts with `#!`, and the copy is renamed over the old one atomically; the old copy stays one day as `<name>.prev`. Any failed check keeps the old script and tries again the next day. `settings.json` is never written.
- **Weekly plan usage for members who run Claude Code outside the terminal** (AIO-892): Claude Desktop and the VS Code extension never render the status line, so the status-line tap sent them no weekly figure. At session start, at most once every 4 hours per computer, on an enrolled computer signed in with a Claude subscription and only when the status-line tap stored no weekly figure in the last 4 hours (terminal users without the tap included), the plugin runs Claude Code's own `claude -p "/usage" --no-session-persistence --output-format json` (a local command: no model call; `claude` on `PATH`, else the newest Claude Desktop bundle, else the VS Code extension's) and sends the whole text of its result, unparsed, as one `usage_cmd` sample (`usage_raw`, at most 32 KiB; an error result or a larger one is not sent) to the organization's own gateway, which reads the weekly figure out of it. The text includes Claude Code's own "What's contributing" section (local folder names, skill, sub-agent, MCP and plugin names, request counts); prompts and replies never leave. The child runs with `AIONAS_USAGE_PROBE=1`, and every plugin hook ends at once when it sees that variable. The login token is never read.
- **Counts when "Sonnet for sub-agents" acts and when it does not** (AIO‑898): on each sub-agent start the mod's existing `agent.spawn` handler runs `aionas-bypass.sh --subagent-start`, which adds one `subagent_sonnet` `fired` count while the method is active for the session, else one `skipped`. Nothing else changes: no new hook, no new call (the hourly counters send carries the rows), nothing counted on a computer that is not enrolled or inside the usage probe's child, and the Sonnet choice itself is untouched.

## 0.4.1 (2026-11-01)

**Without the one install, the plugin does nothing.** The repository is public, so anyone can install the plugin by hand. On a computer the one install never enrolled (no alias in `~/.aionas/agent/credential`), every method is off, required ones too: no session context, sub-agents keep the person's own model, no handoff, no output trim, and the band draws nothing. Nothing was sent from such a computer before either; now nothing changes on it. An enrolled computer is unchanged: with no policy cached yet, every method is on as before.

## 0.4.0 (2026-10-29)

**Security hardening: this plugin runs on customer computers and updates itself from a public repository.**

- The daily scan runs the scanner only from where the installer puts it (`$AIONAS_SCAN_BIN`, `~/.aionas/agent/tools`, `~/.aionas/agent/bin`), never from `PATH`: a project or package could put its own `aionas-scan` there and have it run detached.
- The gateway address in the enrollment file must be `https://`; plain `http://` is accepted only for `localhost` and `127.0.0.1`.
- The `npm install` rule no longer adds `--no-audit`, so npm's vulnerability audit is never switched off.
- Band names drop C1 control and bidirectional-override characters, so a name from the policy cannot reorder or hide what the band shows.
- `security/egress-manifest.txt` lists every file, hook, network call and gateway endpoint the plugin uses; CI fails when the code and the list disagree.
- The marketplace sets `forceRemoveDeletedPlugins`, so taking the plugin out of the catalog removes it from every computer.

## 0.3.1 (2026-10-28)

**Turning off "Sonnet for sub-agents" now brings sub-agents back to the person's own setting (AIO-884).**

- Before: the one install wrote `CLAUDE_CODE_SUBAGENT_MODEL=sonnet` into `~/.claude/settings.json`, and the plugin never read the method's state. Turned off with the band's chip, `/aionas-bypass subagent_sonnet` or the organization's policy, sub-agents still ran on Sonnet.
- Now: the plugin sets the variable inside the running session, just before each sub-agent starts, and takes it off again while the method is off, released or bypassed. Its bypass and its end apply from the next sub-agent of a running session; the organization's policy applies from the next session, as for every method.
- The person's own value (in `settings.json`, the shell or a project's settings) is kept whatever the method's state. The Sonnet an older install wrote is recognized by the install's own marker and is taken off too, so members on an older install are fixed by this update alone.
- `settings.json` is never written by the plugin.
- New: `aionas-bypass.sh --subagent-model BASE` (the decision), the mod's `agent.spawn` hook, and `AIONAS_SUBAGENT_MODEL` in `lib/catalog.sh`.
- Proof: real Claude Code 2.1.311 against a local mock of the Messages API, two sub-agents per session (lab `probes/subagent-sonnet-off/midsession`, `run-plugin.sh`). On, then bypassed between them: Sonnet then the default. Install-written Sonnet, then bypassed: Sonnet then the default. The person's own opus: opus both times. Bypassed, then ended: the default then Sonnet. Off by the organization: the default both times. 0.2.0 on the same case: Sonnet both times.
- To follow, in the gateway repo (AIO-885): the one install stops writing the variable and takes back the value an older install wrote. That ships after this release.

## 0.3.0 (2026-10-28)

- The plugin reports which Claude plan this computer is signed in to (plan and account id only), once a UTC day and as soon as it changes, with the installer's rule: Team on rate-limit tier `default_claude_max_5x` is Team premium (AIO-888). A failed send is retried at the next session start, silently.
- "Write the minimum" is one paragraph added at session start, byte for byte the lab's tested `additional-context.json`, instead of a skill; the skill and its mod gate are gone. Each session start counts `fired` (method on) or `skipped` (off, released or bypassed) (AIO-889).

## 0.2.0 (2026-10-27)

- The noisy-command guard and the long-output store are one method, `output_trim`, off unless the organization turns it on (AIO-883). The old ids and `guard`, `store`, `trim` are aliases of it in `/aionas-bypass`; the band shows one "trim" chip.

## 0.1.4 (2026-10-23)

- Going on with a chat after its handoff passes the old doc over; the next idle asks for a new one (AIO-874).

## 0.1.3 (2026-10-22)

- In the desktop app: tip cards, chip state colors, the handoff countdown, "Done with this chat" (`/aionas-done`), and continue opens a session of its own (AIO-874).
- The band refreshes in the desktop app too, reads with the session's own id after a reload, and dates an older timer from its arm time (AIO-874).

## 0.1.2 (2026-10-22)

- The store and guard markers carry the full output size (AIO-873).

## 0.1.1 (2026-10-21)

- The effort window allows xhigh or max and never sets them; a window session honours the app's effort picker (AIO-868).
- The band shows the saving since install (never negative) and the monthly potential (AIO-867), and its hover explains every chip.
- The handoff timer arms on the first turn too (AIO-858).

## 0.1.0 (2026-10-21)

- First release (wave 24): the mod band with per-method chips (AIO-855, AIO-859), the handoff doc (AIO-858), effort capped at high with the `/aionas-xhigh` window (AIO-859), the noisy-command guard and the long-output store with `aionas-recall` (AIO-860), the unused-services notice (AIO-861), and the "write the minimum" skill.
