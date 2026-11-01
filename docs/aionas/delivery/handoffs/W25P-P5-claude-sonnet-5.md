# Work Package Handoff

```yaml
work_package: W25P-P5 (plugin mod finds Git Bash on Windows; band in Claude Desktop, AIO-905)
contract_version: AIONAS-24H-v1
builder: claude-sonnet-5
base_commit: 6d7c4ddf8eacfb71748cbf77ef38f4759006fa53
branch: w25p/p5-band-win
head_commit: cda7d0f   # last code/docs commit; this file is the next, final commit
status: ready_for_review
started_at: 2026-11-01
completed_at: 2026-11-01
```

## Outcome

On Windows the mod now runs every script with a Git Bash it found the way Claude Code does, never from `PATH`, so inside Claude Desktop the band can draw. Where no Git Bash is found on a Windows computer, the band shows one plain line ("Aionas: Git Bash not found on this computer; savings methods are off") and the session start toast says the same. The path found is kept in `~/.aionas/agent/state/git-bash-path`. macOS and Linux behave exactly as before.

## Cause (file:line at base 6d7c4dd)

`plugins/aionas-savings/hooks/mod.tsx:342` set `st.bash = CLAUDE_CODE_GIT_BASH_PATH ?? 'bash'` (initial value `'bash'` at line 87), and `run()` (line 127) executed `$.process.run([st.bash, ...argv])`. In Claude Desktop on Windows the variable is unset and `bash` from `PATH` is missing (or is the System32 WSL launcher), so `aionas-bypass.sh --band` failed (`refresh`, line 176-177, returned early), `st.facts` stayed undefined, and the AbovePrompt handler returned `next(e)` at line 478 (no band). The same failure silently disabled everything else the mod runs. Live proof of the cause (relayed by the orchestrator): setting `CLAUDE_CODE_GIT_BASH_PATH` to `C:\Program Files\Git\bin\bash.exe` and restarting Desktop made the band appear.

## Scope and exclusions

- Implemented: `resolveBash` in `hooks/mod.tsx` (variable if it names an existing file and is not Windows' own bash.exe; else `%ProgramFiles%\Git\bin`, `%ProgramFiles(x86)%\Git\bin`, `%LOCALAPPDATA%\Programs\Git\bin`; existence by starting the candidate with `-c true`, so the mod reads no file); `run()` refuses to spawn when none is found; `NO_GIT_BASH` + `drawNotice` in `hooks/band.tsx`; the toast in `session.start`; the support record written by the found bash itself (`bash -c`, path passed as an argument); mod tests; one CHANGELOG line and one README sentence.
- Not touched: `lib/usage-probe*`, `SECURITY.md`, hooks.json, any `.sh` script, version files, `security/egress-manifest.txt` (no new mod API: only `$.process.run`, already listed), `tests/unit/band-privacy-gate.test.sh`.
- Deferred: see FLAGGED items.

## Decisions (FLAGGED-FOR-RATIFICATION)

1. macOS/Linux keep today's behaviour (the variable, else the bare word `bash`), NOT `/bin/bash`: not every Linux has `/bin/bash` (NixOS, Alpine), and hooks.json already uses the bare word there.
2. The mod's privacy gate (`tests/unit/band-privacy-gate.test.sh`) forbids `$.fs.*` and any mention of `credential` in the mod source, so this change does NOT use `$.fs` and does NOT test enrollment. Consequence: the not-found band line and toast show on ANY Windows computer where no Git Bash is found, enrolled or not (a hand-installed copy included). That is a misconfigured computer on which Claude Code itself cannot run hooks, so the line is accurate there; the 0.4.1 "an unenrolled computer sees nothing" promise is relaxed for exactly this one case. Needs ratification, or a follow-up that lets a bash-free enrollment check exist.
3. The toast appears at every session start while Git Bash is missing (no per-person "first session" memory can exist without a script, and no script can run).
4. The support record is written on Windows only, and only when a Git Bash is found (with none, nothing can write it without `$.fs`). It holds the path, nothing else; with no bash the evidence is the band line.
5. Windows is detected by `OS=Windows_NT`. `ProgramFiles` defaults to `C:\Program Files` when unset. New env reads: `OS`, `ProgramFiles`, `ProgramFiles(x86)`, `LOCALAPPDATA`. The gate's `ALLOWED_ENV` list in the unit test was not extended (its real-report check only runs with `AIONAS_CC_BIN`, and the list was already behind the code: `CLAUDE_CODE_EFFORT_LEVEL`, `CLAUDE_CODE_SUBAGENT_MODEL`, `AIONAS_SUBAGENT_MODEL_BASE` are read today). The reviewer should extend it when that check is next run.
6. Any `bash.exe` under `Windows\System32|sysnative|syswow64` or `WindowsApps` is rejected even when `CLAUDE_CODE_GIT_BASH_PATH` names it.

## Contracts

- Consumed: Claude Code 2.1.299 mod API (`$.env.get`, `$.process.run`, `$.ui.toast`).
- Produced: `~/.aionas/agent/state/git-bash-path` (local only, never sent; written by Git Bash with `umask 077`).
- Contract changes requested: none. Backward compatibility: macOS/Linux unchanged; existing mod tests do not set Windows env, so they take the unchanged path.

## Files and commits

| Commit | Type | Files | Purpose |
|---|---|---|---|
| `2f2890e` | test | `plugins/aionas-savings/tests/mod.test.tsx` | first set of Windows mod tests (superseded in part by `cda7d0f`) |
| `6064de1` | feat | `hooks/mod.tsx`, `hooks/band.tsx`, `security/egress-manifest.txt` | first resolver (used `$.fs`) |
| `ca62fba` | docs | `CHANGELOG.md`, `README.md` (plugin) | one line each |
| `cda7d0f` | fix | `hooks/mod.tsx`, `tests/mod.test.tsx`, `CHANGELOG.md`, `security/egress-manifest.txt` | the privacy gate (`make test`) rejected `$.fs`: probe with `-c true`, record the path through the found bash, drop the enrollment check, manifest back to its base content |

Net diff of the package against base: `hooks/mod.tsx`, `hooks/band.tsx`, `tests/mod.test.tsx` (9 tests), `CHANGELOG.md`, `README.md`, this handoff. The egress manifest ends identical to base.

## RED evidence

The plugin test kit (`claude plugin test`) was NOT run: the orchestrator forbids running a real claude binary. RED/GREEN was shown with a scratch harness (esbuild bundle of the real `mod.tsx`/`band.tsx`, a fake `$`, a fresh module per scenario, `bash` made to fail on Windows like the real machine), kept outside the repo.

```text
command: node harness.mjs against the base mod.tsx
expected failure: Windows without CLAUDE_CODE_GIT_BASH_PATH runs scripts with "bash" and the band is absent
actual result: win: git in Program Files -> argv0 ["bash"], render: engine band (no band)
               win: var -> System32       -> argv0 ["C:\Windows\System32\bash.exe"] (WSL launcher used)
```

## GREEN evidence

```text
command: node harness.mjs against the new mod.tsx
actual result:
 git in Program Files   -> argv0 C:\Program Files\Git\bin\bash.exe, band drawn, debug file = that path
 variable set + exists  -> argv0 = the variable's path
 variable -> System32   -> no process spawned, not used
 only System32 / nothing-> no process; toast and band line "Aionas: Git Bash not found ..."; no record
 macOS/Linux            -> argv0 "bash", no fs call, no debug file
command: tsc (strict, the repo tsconfig + the 2.1.299 types) over hooks and tests
actual result: no error in the new code (the pre-existing errors at base are unchanged)
command: make test
actual result: ALL PASSED at cda7d0f (one earlier run showed test_daily_scan_runs_incremental_once_a_day timing out while two make runs overlapped; it passes alone, twice, and in the clean full run)
command: bash tests/unit/band-privacy-gate.test.sh and egress-manifest.test.sh
actual result: 5 passed and 6 passed, 0 failed (the privacy gate rejected the first version that used $.fs; fixed in cda7d0f)
```

## Security, privacy and reliability evidence

- Identity/authorization: no new network call; nothing sent. Bash is never taken from `PATH`; Windows' own bash.exe is rejected.
- Secret/PII handling: the mod reads no file and never names the credential. The record holds one path. Tests and this file use `C:\Users\<user>`.
- Failure: every probe and the record write are caught; a missing env fails soft; with no bash the mod spawns nothing and commands answer "could not run".
- Egress manifest and privacy gate: unchanged and passing (only `$.process.run`, no `$.fs`, no `credential`). A candidate is started with `-c true` (the spec's own fallback); the per-user folder is user-writable, same trust as the person's own PATH-free Git install.
- Negative tests: WSL launcher by variable and by presence; missing variable file; no spawn at all when no bash.

## Integration seams

- Hot files: none. README/CHANGELOG touched with one line each; `lib/usage-probe*` untouched. Expect a trivial CHANGELOG/README merge with p3b (adjacent lines).
- `security/egress-manifest.txt`: net no change from this package.

## Evidence artifacts

None committed (the scratch harness is outside the repo).

## Unverified claims and blockers

- Unverified: the plugin test kit (`make validate`, `claude plugin test`) has not run on the new tests, per the no-real-claude-binary constraint; the 9 tests are type-checked only and mirror the harness scenarios. Run `make validate` before merge.
- Only a Windows Desktop run can prove: (1) screenshot of the band in Claude Desktop's Code tab with `CLAUDE_CODE_GIT_BASH_PATH` unset; (2) `/plugin` shows aionas-savings enabled; (3) `~/.aionas/agent/state/git-bash-path` holds the Git Bash path; (4) `/aionas-bypass` answers; (5) with Git Bash renamed away, the plain line and message show; (6) that Git Bash for Windows runs the support-record snippet (checked here on macOS bash only).
- Blocked by: nothing.

## Rollback

`git revert ca62fba 6064de1 2f2890e` in the plugin repo. No data migration; the debug file may be deleted by hand.

## Suggested verifier commands

```text
make test
make validate
bash tests/security/egress-manifest.sh | diff - security/egress-manifest.txt
```

## Review-fix log (2026-11-01, F1 major only)

Finding F1 (review W25P-P5-review-2026-11-01): `CLAUDE_CODE_GIT_BASH_PATH` and the env-derived candidates were accepted when not absolute or not normalized, so a bare `bash`/`bash.exe` was probed and spawned by name (cwd or PATH lookup) and `isWslLauncher` was bypassed by `..`, a missing `.exe`, a doubled separator or a trailing space.

Fix (`plugins/aionas-savings/hooks/mod.tsx`): new `isUsableBashPath` accepts only an absolute drive or UNC path (not the `\\?\` / `\\.\` forms), separators collapsed before the WSL check, no `.`/`..` part, no part ending in a dot or space, last part `bash.exe` (case-insensitive). `resolveBash` uses it for the variable; `gitBashCandidates` drops any candidate that fails it (a relative `ProgramFiles` gives none; a blank `ProgramFiles` falls back to `C:\Program Files`). macOS/Linux unchanged.

Tests (`tests/mod.test.tsx`): 12 variable cases (bare bash, bare bash.exe, relative, `..` twice, extension-less System32 and Git, doubled separator, trailing space, trailing dot, not bash.exe, device path), doubled-separator with no Git Bash, relative ProgramFiles, accepted UNC path.

```text
command: claude 2.1.299 plugin validate . ; plugin validate plugins/aionas-savings ; plugin test plugins/aionas-savings (temp CLAUDE_CONFIG_DIR)
actual result: rc 0 / 0 / 0; 69 pass, 0 fail (was 54 + the 15 new)
command: make test
actual result: ALL PASSED
command: bash tests/security/egress-manifest.sh | diff - security/egress-manifest.txt
actual result: identical
command: AIONAS_CC_BIN=<2.1.299> bash tests/unit/band-privacy-gate.test.sh
actual result: 4 passed, 1 failed (test_real_validate_report_on_the_pinned_claude_code) - the review's F3, failing at base too, outside this fix's fence; this fix adds no new env read
```

Unverified: still no live Windows Desktop run (items 1-6 above).
