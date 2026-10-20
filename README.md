# Aionas plugins for Claude Code

The Claude Code marketplace `aionas`. It has one plugin, `aionas-savings`.

## aionas-savings

This plugin applies your organization's Aionas savings policy on this computer. It is the client half of the savings methods (wave 24):

- the handoff document,
- starting sessions at high effort, with the `/aionas-xhigh` window,
- the noisy-command guard and the long-output store,
- the "write the minimum" skill.

The one install (`aionas-install.sh` / `.ps1`) registers this marketplace with auto-update, enables the plugin, and writes the settings a plugin cannot carry.

**Privacy.** Only numbers and names leave the computer. The hourly counters send a method, a counter name and a count. The policy sync only downloads. Prompts, model replies, tool output and command arguments are never sent.

### Layout

```
.claude-plugin/marketplace.json          the marketplace (name: aionas)
plugins/aionas-savings/
  .claude-plugin/plugin.json             name, version
  hooks/hooks.json                       every hook entry; each runs one script below
  hooks/*.sh                             one script per entry (owner issue in its header)
  lib/                                   shared helpers (source lib/aionas.sh)
tests/                                   make test
```

### Hook entries

| Event | Script | Runs | Owner |
|---|---|---|---|
| SessionStart | `policy-sync.sh` | async | AIO‑855 |
| SessionStart | `daily-scan.sh` | async | AIO‑854 |
| SessionStart | `effort-window.sh` | async | AIO‑859 |
| SessionStart | `unused-services.sh` | async | AIO‑861 |
| UserPromptSubmit | `handoff-cancel.sh` | 5 s | AIO‑858 |
| PreToolUse (Bash) | `noisy-guard.sh` | 10 s | AIO‑860 |
| PostToolUse | `output-store.sh` | 30 s | AIO‑860 |
| Stop | `handoff-arm.sh` | asyncRewake | AIO‑858 |
| Stop | `counters-flush.sh` | async | AIO‑855 |

Every command has the form `bash "${CLAUDE_PLUGIN_ROOT}/hooks/<name>.sh"`. Claude Code runs it with bash on macOS and Linux, and with Git Bash on Windows. A script must exit 0 and print nothing unless it has something to tell Claude Code. SessionStart scripts never block the session.

### The shared library (`lib/`)

Source it from a hook with `. "$(dirname "$0")/../lib/aionas.sh"`. It is POSIX sh: bash 3.2 on macOS, dash, and Git Bash. It needs only awk, grep, tr, date, mkdir, mv, rm and curl. There is no jq and no Python.

| File | What it gives |
|---|---|
| `platform.sh` | `aionas_os`, `aionas_now`, `aionas_day_utc`, `aionas_savings_dir`, `aionas_write_atomic`, `aionas_lock_try` / `aionas_lock_release` |
| `json.sh`, `json.awk` | `aionas_json_flatten` (JSON → `path<TAB>type<TAB>value` lines), `aionas_json_get`, `aionas_json_escape`, `aionas_json_unescape` |
| `catalog.sh` | the closed lists: method ids, required methods (`cache_guard`), and counters (`fired`, `skipped`, `bypass`) |
| `enroll.sh` | the enrollment alias and gateway from `~/.aionas/agent`. The alias goes only into a private header file, never onto a command line. |
| `http.sh` | `aionas_http`: one try, with a 3 s connect timeout and 5 s in total |
| `policy.sh` | `aionas_policy_sync`, `aionas_policy_pin <session>`, `aionas_policy_state` / `_active` / `_bypassed` / `_param` / `_self_override_allowed` / `_self_release_allowed`, `aionas_override_local_add` |
| `counters.sh` | `aionas_counter_inc <method> <counter> [n]`, `aionas_counters_flush [--force]` (at most hourly) |

**State.** The plugin keeps its state in `~/.aionas/agent/savings/`:

- `policy.cache`: the last good policy.
- `sessions/<id>.cache`: each session's pin. A policy change applies from the next session.
- `local-overrides.tsv`: overrides made on this computer.
- `counters/`: the counters queue.

**Rules the library holds:**

- With no cache, every method is on, and self-override and self-release are allowed.
- A failed sync keeps the last good cache.
- A required method is always on and can never be bypassed.

### Tests

```
make test       # unit tests; temporary HOME only, no network (a fake curl)
make validate   # Claude Code 2.1.299's own manifest check, in a temporary config dir
```

A lane adds its tests as `tests/**/<name>.test.sh`, using `tests/lib/harness.sh`. Each test runs in a fresh temporary HOME. Temporary folders are made with `mktemp` and are never deleted recursively.

### Versions

The version is in `plugin.json` and the marketplace entry (the tests check that they agree). Releases are git tags named `aionas-savings-vX.Y.Z`.
