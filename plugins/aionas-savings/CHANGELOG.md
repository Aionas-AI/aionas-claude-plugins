# aionas-savings changelog

Each release is the git tag `aionas-savings-vX.Y.Z`. With auto-update on, Claude Code picks a release up from the marketplace; it applies from the next session.

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
