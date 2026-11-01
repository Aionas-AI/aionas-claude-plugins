# Work Package Handoff

```yaml
work_package: W25P-P3 (plugin usage-probe, AIO-892 plugin half)
contract_version: AIONAS-24H-v1
builder: claude-sonnet-5
base_commit: 7c8408308568078510920cfc605ce46ecd9b2557
branch: w25p/p3-usage
head_commit: d1ac310   # last code/docs commit; this file is the next, final commit
status: ready_for_review
started_at: 2026-11-01
completed_at: 2026-11-01
```

## Outcome

On an enrolled computer, a new async SessionStart hook `usage-probe.sh` runs Claude Code's own `/usage` command at most once every 4 hours (and only when the status-line tap stored no weekly figure in the last 4 hours), reads the `Current week (all models)` line and sends one `usage_cmd` sample (`kind: weekly_all`, `used_percent`, `resets_at` when it can be computed reliably) to `POST /cc-quota/v1/samples`. Observed behaviour, all against a stub `claude` (no real login, no model call, `make test`): the 41% fixture produces exactly one POST whose body is the expected string; a second start within 4 hours makes no second probe; the child sees `AIONAS_USAGE_PROBE=1`; every hook in `hooks.json` run inside the child does nothing and sends nothing; an unreadable result sends nothing and counts locally.

## Scope and exclusions

- Implemented: hook + lib (`hooks/usage-probe.sh`, `lib/usage-probe.sh`, `lib/usage-probe.awk`), the recursion guard (first code line of `lib/aionas.sh`), binary lookup (PATH, Desktop bundle, VS Code extension), parser, reset-time conversion, sample body, local unparsed counter, timeout / TERM handling, tests, fixture, README / CHANGELOG / egress-manifest.
- Explicitly not implemented: gateway side (AIO-892 Success 5 and 6, option C), DB-row E2E, version bump, release; `mod.tsx` unchanged.
- Deferred: a live run of a real `/usage` (not allowed in this package); Windows paths; the gateway counter name (see Flags).

## Contracts

- Consumed: gateway sample contract from the foundation commit `9562b9c31` (`source: "usage_cmd"`, `windows[].kind = weekly_all`, `used_percent`, `resets_at`, optional `organization_uuid` / `organization_name`); `/cc-quota/v1/samples` is already in `security/egress-manifest.txt`. Rules W25-c, W25-d, W25-e (kickoff section 2), W16-D5 (no session/five_hour line is sent).
- Produced: the sample body `{"tool":"claude_code","source":"usage_cmd","observed_at":ISO[,"account_uuid"][,"organization_uuid"][,"organization_name"],"windows":[{"kind":"weekly_all","window_minutes":10080,"used_percent":N[,"resets_at":ISO]}]}`. The wire key is `used_percent` (not `utilization`, which is the column).
- Contract changes requested: see Flags (gateway counter list; `resets_at` omitted row).
- Backward compatibility: all existing hooks behave the same without the variable (the full suite passes); `plan-report.sh` now sources two helpers from `lib/claude-account.sh` (moved verbatim, `plan-report.test.sh` untouched and green).

## Files and commits

| Commit | Type | Files | Purpose |
|---|---|---|---|
| `c03844a` | test | `tests/unit/usage-probe.test.sh`, `tests/fixtures/usage-probe/*`, `skeleton.test.sh`, `not-enrolled.test.sh` | RED tests, stub claude, reconstructed 2.1.311 fixture |
| `2eb09bc` | feat | `lib/aionas.sh`, `lib/usage-probe.{sh,awk}`, `lib/claude-account.sh`, `hooks/usage-probe.sh`, `hooks/hooks.json`, `hooks/plan-report.sh` | guard, probe, parser, shared account helpers |
| `d1ac310` | docs | `README.md`, `CHANGELOG.md`, `security/egress-manifest.txt` | tables, one changelog bullet, regenerated manifest |
| last | docs | this file | handoff |

## RED evidence

```text
command: bash tests/unit/usage-probe.test.sh   (before the feature commit)
expected failure: hooks/usage-probe.sh missing
actual result: 5 passed, 42 failed (the 5 that pass are invariants: no --bare in code, catalog.sh stays closed, ...)
           e.g. "the variable stops every request: expected [0] got [2]" (no guard yet)
```

## GREEN evidence

```text
command: bash tests/unit/usage-probe.test.sh   (PATH=/usr/bin:/bin first, so hooks run under /bin/bash 3.2.57)
actual result: 51 passed, 0 failed (after the review-fix commit)
command: make test        -> ALL PASSED (every test file, run with the final tree)
command: make validate    -> 0 fail (plugin validate x2, plugin test: 44 pass); run offline from the npx cache of Claude Code 2.1.299 (npm_config_offline=true), no registry access
command: find plugins tests -type f \( -name '*.sh' -o -name '*.lib' \) -print0 | xargs -0 shellcheck -S error -s bash   -> clean
```

## Step 0: binary paths (record)

| Path | Status | How |
|---|---|---|
| `claude` on PATH (`~/.local/bin/claude` -> `~/.local/share/claude/versions/2.1.311`) | VERIFIED | `command -v`, `--version` = 2.1.311 |
| macOS Desktop bundle: `~/Library/Application Support/Claude/claude-code/<X.Y.Z>/<12 hex>/claude.app/Contents/MacOS/claude` | VERIFIED | `find` on the build Mac (2.1.304, 2.1.308 present; each folder also holds a `.verified` file with a 64-hex digest); `--version` on 2.1.308 = 2.1.308 |
| The issue's layout `<X.Y.Z>/claude` | UNVERIFIED, WRONG on the build Mac | tried second, harmless; the real layout is the first row |
| VS Code extension: `~/.vscode/extensions/anthropic.claude-code-<X.Y.Z>[-<platform>]/resources/native-binary/claude[.exe]` (also `~/.vscode-insiders/extensions`) | UNVERIFIED | no `anthropic.*` extension in `~/.vscode`, `~/.vscode-insiders` or `~/.cursor`; one named constant (`AIONAS_UP_VSCODE_ROOTS`, `AIONAS_UP_VSCODE_REL` in `lib/usage-probe.sh`) |
| Windows Desktop and VS Code | UNVERIFIED | nothing citable: the gateway installer names only the Desktop app `Claude.exe`; Windows looks at PATH (and the VS Code guess) only. On Git Bash `/usr/share/zoneinfo` is probably missing, so `resets_at` is omitted there |

Only `--version` was run, on the two real binaries. `/usage` was never run against a real login.

## Security, privacy and reliability evidence

- Identity/authorization: the sample goes through `aionas_http` (alias in a private header file, never on a command line; test checks the args).
- Organization isolation: n/a (client). Account / organization fields are the plan-report helpers (`_pr_uuid`, `_pr_clean_name`), tested with a hostile name.
- Secret/PII handling: body holds only the percent, the reset instant, observed time and ids. Test asserts it never contains `Current`, `result`, `resets `, the zone, `Fable`, `session`, `five_hour`, `utilization`, the e-mail or user id from the login file. The login token is never read.
- Failure/retry/concurrency: stamp written BEFORE the child starts (a hung or failed run waits the 4 hours); `mkdir` lock (120 s) plus re-check of stamp and tap under the lock; 5 parallel starts make 1 probe; EXIT/HUP/INT/TERM trap stops the child (TERM, 1 s, KILL), removes the output file by name and releases the lock; a child that ignores TERM is killed; the child runs in its own process group (`set -m`) and a timeout, a TERM to the hook or an oversize result stops the whole group (TERM, 1 s, KILL), grandchildren included; partial output is never parsed; output over 64 KB stops the child inside the wait loop (checked every 0.2 s) and is never read; a non-zero exit is "unparsed"; `hooks.json` timeout 45 s (20 + 1 + 5 s + margin; at 10 s Claude Code would kill the hook and orphan the child).
- Recursion (W25-e): first code line of `lib/aionas.sh` is `if [ -n "${AIONAS_USAGE_PROBE:-}" ]; then exit 0; fi`. Every `hooks.json` script reaches that line before any work (direct source; `noisy-guard` / `output-store` exec `pretool-guard.sh` / `posttool-store.sh`, `handoff-arm` execs `stop-handoff.sh`, `handoff-cancel` execs `handoff-wake.sh`, all of which source it first). The test makes the stub run every script named by `hooks.json` inside the child and asserts: exit 0 for all, no output, no file written under `~/.aionas`, no new request, and no second child. A control run without the variable makes requests.
- Durability/recovery: leftover `out.* / body.* / resp.*` of a killed start are removed by exact name (no recursive delete anywhere); the working dir `state/usage-probe` is created 0700 and refused if it is a symlink.
- Negative tests: unknown text; wrong `local_command`; only a model line; only the session line; 101%; negative; non-numeric; no percent sign; label not at line start; not JSON; truncated; `result` not a string; nested keys; exit 1; oversize; tripwire `env` / `timeout` / `perl` on PATH never run; non-enrolled; alias without gateway; API-key and `none` logins; no binary; directory or non-executable named `claude`.
- PATH rule (kickoff gate 2): the only program the plugin starts from PATH that it did not already use is `claude`. The child is started by a plain `exec` (no `env`, `timeout`, `perl`). The usual system tools (awk, grep, sort, date, sleep, kill) are used the way the rest of the plugin uses them.
- Reset conversion (risk 4): zone must match `^[A-Za-z_]+(/[A-Za-z0-9_+-]+){0,2}$` AND exist as a file under `/usr/share/zoneinfo` (an unknown `TZ` silently means UTC); month is the English 3-letter name, 12-hour clock with am/pm, optional minutes, whole line anchored; year from the clock (December to January wraps); the offset is taken from the zone at the result and re-checked (spring-forward gap rejected; a fall-back hour that happens twice is not resolved on purpose: west of UTC, e.g. New York 1:30am on the fall-back day, it gives the first occurrence, east of UTC, e.g. Europe/London 1:30am, the second, so up to one hour off once a year; pinned by a test); seconds are 00; only an instant after now and within 8 days is kept; the computer's own `TZ` does not matter (tested with two other zones). Fixture at 2026-11-01T00:00:00Z gives 2026-11-03T03:59:00Z.

## Success lines of AIO-892 that name the plugin

| # | Line | Test / status |
|---|---|---|
| 1 | one row `usage_cmd`, 41, parsed `resets_at` | `test_fixture_41_sends_exactly_one_usage_cmd_sample` (POST body); the `cc_quota_samples` row is a gateway E2E, deferred |
| 2 | second start within 4 hours: stub count 1 | `test_second_session_within_the_hour_does_not_probe_again` |
| 3 | child sees `AIONAS_USAGE_PROBE=1`; hook log empty | `test_the_child_gets_the_variable_and_exactly_the_documented_command`, `test_every_hook_does_nothing_inside_the_probe_child`, `test_the_same_hooks_do_work_without_the_variable`, `test_aionas_sh_exits_the_sourcing_shell_on_the_variable` |
| 4 | unknown text: no sample, counter = 1 | `test_unrecognized_text_sends_nothing_and_counts`, `test_only_a_usage_local_command_with_the_all_models_line_is_a_sample` (see Flag 1 for where the counter lives) |
| 5, 6 | plan-check reasons, T unchanged | gateway, not here |
| 7 | live check of a Desktop-only member after the release | UNVERIFIED (live; needs the release) |

Other spec tests: fresh tap -> no probe (`test_a_fresh_status_line_figure_means_no_probe`, stale / unreadable variants); no binary -> no request; PATH first, Desktop newest by version (2.1.100 over 2.1.99 even when 2.1.99 has the newer mtime), a build with a `.verified` file preferred over a newer one without, a symlinked version, build, app or binary path rejected, VS Code last, Desktop macOS-only; argv exact and no `--bare`; timeout (TERM-ignoring stub) and a TERM sent to the hook; not enrolled; egress-manifest test passes with the regenerated manifest.

## Flags (FLAGGED-FOR-RATIFICATION / for the orchestrator)

1. **Counter name.** `usage_probe_unparsed` is kept as a local integer in `~/.aionas/agent/savings/counters/usage_probe_unparsed`, not through `aionas_counter_inc` / `queue.tsv`. The plugin's closed list (`catalog.sh`, owned by a sibling package) does not accept it, and if it were added there the gateway's counter list (`handlers/aionasenrollretro.go` around line 63; batch rejected at around line 475) does not know it, so the whole batch would get HTTP 400 and `aionas_counters_flush` would then drop every pending row of every method. Nothing sends this number today. To make Success line 4 reach the server, the gateway must accept the name, and then `catalog.sh` and a flush step can send it (a follow-up).
2. **Omitted `resets_at`.** A sample without `resets_at` is stored by the gateway as a `shape_changed` row with a zero reset time. It is sent that way when: the zone is not an installed IANA zone (Git Bash on Windows has no zoneinfo, so always there, UNVERIFIED), the text is not the English 12-hour form (other locales), the date or time is invalid or does not exist in that zone (DST gap), or the instant is not within the next 8 days. The percent is still sent.
3. **Source flapping (risk 7).** `claude.last` is only rewritten when the weekly figure changes, so an idle terminal member whose figure has not moved for 4 hours can get a 4-hourly `usage_cmd` sample that becomes the latest source (AIO-892 Success line 6 says the tap member's source is unchanged). The package follows the spec's rule (tap newer than 4 hours) and does not invent another. The gateway may want to prefer a newer `statusline` sample or a tap `sentmark`.
4. **Phantom activity (risk 7).** The child `claude -p` also runs other plugins' and the member's own hooks, and may emit telemetry session events if the member's settings enable telemetry. Not measured (no real run allowed).
5. **`mod.tsx` in the child.** It is unchanged. Its scripts also source `aionas.sh`, so they exit at once under the variable; whether Claude Code loads the mod at all in a `-p` child is UNVERIFIED live.
6. **Fixture.** `tests/fixtures/usage-probe/usage-2.1.311.json` is reconstructed from the issue text, not a live capture; the session line and the JSON keys around `result` are assumptions. The parser reads only top-level `local_command` and `result`, and only the one line.
7. **No account in the login file.** If `~/.claude.json` is missing, or has no `oauthAccount.accountUuid` (an API-key or gateway-routed member), no child is started. `billingType` `api` or `none` also skips before anything is started (the `/usage` output differs for an API key).
8. **Reset window parsed in the same run.** `AIONAS_USAGE_PROBE_TIMEOUT` is a test seam that can only lower the 20 s limit.
9. **Stdin / Windows.** `kill` of a native `claude.exe` from Git Bash is UNVERIFIED. The process-group kill (`set -m`, `kill -- -PID`) is also UNVERIFIED under Git Bash; the plain-pid kill stays as the fallback.
10. **Claude Code's own call to Anthropic (not in the egress manifest).** The child `claude -p "/usage"` makes Claude Code's own call to Anthropic with the member's own login. Aionas never reads the token, and `security/egress-manifest.txt` cannot list that call because the plugin does not make it: the manifest lists only what the plugin's own code runs and sends. The README privacy note says the same.

## Integration seams

- Hot files touched in separate `seam(...)` commits: none of the gateway's. Shared plugin files changed in the normal commits: `lib/aionas.sh` (guard, one block at the top), `hooks/hooks.json` (one entry), `hooks/plan-report.sh` (two helper functions moved to `lib/claude-account.sh`, behaviour unchanged), `tests/unit/skeleton.test.sh` (hook list), `tests/unit/not-enrolled.test.sh` (loop), `security/egress-manifest.txt` (new files and hook line; no new network call).
- Merge order / dependencies: after p1 and p2 (this branch is on top of both). The sibling package that edits `catalog.sh` is untouched here.
- Known conflicts: `README.md` hook and lib tables, `CHANGELOG.md` Unreleased section, `security/egress-manifest.txt` (regenerate after merging with `bash tests/security/egress-manifest.sh > security/egress-manifest.txt`), `skeleton.test.sh` hook list.

## Evidence artifacts

- `tests/unit/usage-probe.test.sh`, `tests/fixtures/usage-probe/{usage-2.1.311.json,stub-claude.sh,README.txt}`
- `security/egress-manifest.txt`

## Unverified claims and blockers

- Unverified: VS Code extension path; every Windows path; the real `/usage` text and JSON beyond the issue's two quoted lines; a live run; telemetry side effects of the child; CI shellcheck is the command above, run locally (clean).
- Blocked by: nothing.
- Required input: gateway acceptance of the counter name (Flag 1).

## Rollback

Remove the `usage-probe.sh` entry from `hooks/hooks.json` (the probe stops at once; the guard line is harmless), or revert the feature commit. State left on a computer is only `savings/usage-probe.last`, `savings/counters/usage_probe_unparsed` and the empty dir `state/usage-probe`; nothing needs deleting.

## Suggested verifier commands

```text
bash tests/unit/usage-probe.test.sh
make test
make validate            # needs npx and the pinned Claude Code 2.1.299
find plugins tests -type f \( -name '*.sh' -o -name '*.lib' \) -print0 | xargs -0 shellcheck -S error -s bash
bash tests/security/egress-manifest.sh | diff - security/egress-manifest.txt
```
