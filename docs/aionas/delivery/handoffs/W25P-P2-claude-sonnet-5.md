# Work Package Handoff

```yaml
work_package: W25P-P2
contract_version: AIONAS-24H-v1
builder: claude-sonnet-5
base_commit: b32961fb15501398b8a147ea837b034c6f7d7b2e
branch: w25p/p2-refresh
head_commit: see "Files and commits" (the handoff commit is the last one on the branch)
status: ready_for_review
started_at: 2026-11-01T01:10:00Z
completed_at: 2026-11-01T02:10:00Z
```

## Outcome

A new SessionStart hook, `hooks/script-refresh.sh` (AIO‑904), brings the four scripts the one install leaves in `~/.aionas/agent/tools` (`aionas-plan-usage.sh`, `aionas-statusline-tap.sh`, `aionas-plan-usage.ps1`, `aionas-statusline-tap.ps1`) to the release the gateway serves, without a new install.

Flow, once per UTC day on an enrolled computer: `GET /enroll/v1/scripts/manifest` (with the alias, via `aionas_http`) -> for each of the four names that is already an installed regular file and whose `AIONAS_RELEASE` stamp differs from the manifest version -> download from the PUBLIC `GET /api/aionas/onboarding/scripts/<name>` without the alias (new `aionas_http_public`) -> verify -> write a temp file next to the old one, copy the old one to `<name>.prev`, rename the temp over the name.

Observed: every assertion is on files in a temporary tools folder and on the requests the fake curl (and, in one test, the real curl against a local stub) recorded.

## Scope and exclusions

- Implemented: the hook, `hooks.json` entry (SessionStart, async, timeout 30), `aionas_http_public` in `lib/http.sh`, helpers in the new `lib/script-refresh.sh` (sourced by the hook only), egress manifest scanner and file, tests, one CHANGELOG entry under `## Unreleased (0.5.0)`, one README hook-table row.
- Not implemented: no `plugin.json` / `marketplace.json` version bump (prompt overrides the issue's "new release"); the gateway side (manifest and public route); the installer; the collector and tap scripts themselves.
- `aionas_http`'s signature is unchanged (policy-sync, plan-report, counters keep using it).

## Contracts

- Consumed: gateway `GET /enroll/v1/scripts/manifest` -> `{"release":"<stamp>","scripts":[{"name","version","sha256"}]}`; public `GET /api/aionas/onboarding/scripts/{name}`; one line `AIONAS_RELEASE='<stamp>'` (PowerShell: `$AIONAS_RELEASE = '<stamp>'`) in each served script (wave 25 foundation contract, sections 4 and 5, as summarised in the prompt file).
- Produced: none for other packages. New files in the plugin's own state folder: `savings/script-refresh.day` (UTC day of the last run) and `savings/script-refresh.prevday` (day the `.prev` copies were made).
- Contract changes requested: none.
- Backward compatibility: an older gateway answers 404 to the manifest; that is a silent no-op (the day is still stamped; retried next day).

## Files and commits

| Commit | Type | Files | Purpose |
|---|---|---|---|
| `c96d1c7` | test | `tests/unit/script-refresh.test.sh`, `tests/fixtures/script-refresh/*`, `tests/unit/{skeleton,not-enrolled,egress-manifest}.test.sh`, `tests/lib/fake-curl.sh` | RED tests (31 in the new file) and the sibling seams |
| `18bcdd2` | feat | `hooks/script-refresh.sh`, `hooks/hooks.json`, `lib/http.sh`, `lib/script-refresh.sh`, `tests/security/egress-manifest.sh`, `security/egress-manifest.txt`, `CHANGELOG.md`, `README.md`, test adjustments | the change |
| (last) | docs | `docs/aionas/delivery/handoffs/W25P-P2-claude-sonnet-5.md` | this handoff |

Seam edits to existing tests (no hot gateway files exist in this repo): `skeleton.test.sh` (exact hook list gains `SessionStart//script-refresh.sh`), `not-enrolled.test.sh` (hook list), `egress-manifest.test.sh` (two planted-call cases), `tests/lib/fake-curl.sh` (`--max-filesize` takes a value, like `--max-time`).

## RED evidence

```text
command: bash tests/run.sh tests/unit/script-refresh.test.sh   (at c96d1c7, hook absent)
result: 12 passed, 19 failed
```
The 12 that passed are "nothing happens" assertions that hold trivially without the hook (for example name-outside-the-four writes nothing, settings.json unchanged, fail-closed without a hash tool). The behaviour tests (replace, `.prev`, inode change, mode 700, one request a day, retry next day, alias absent from downloads, real-curl test, hooks.json entry, not-enrolled no-op) failed.

## GREEN evidence

```text
command: bash tests/run.sh tests/unit/script-refresh.test.sh   (at 18bcdd2)
result: script-refresh.test.sh: 31 passed, 0 failed
command: make test validate
result: make test ALL PASSED; make validate exit 0 (marketplace and plugin manifest validation passed, plugin mod tests 44 pass, 0 fail)
command: find plugins tests -type f ( -name '*.sh' -o -name '*.lib' ) | xargs shellcheck -S error -s bash
result: exit 0
```

## Success lines that name the plugin

| Issue | Success line | Test |
|---|---|---|
| AIO‑904 | both pairs replaced, sha256 equal to served, `.prev` = V1, mode 700, inode changed (S1) | `test_aio904_both_collector_and_tap_pairs_are_replaced_atomically` |
| AIO‑904 | second session start the same day: no new request (S2) | `test_aio904_a_second_session_start_the_same_day_makes_no_request`, `test_aio904_a_held_lock_means_no_request` |
| AIO‑904 | sha256 mismatch keeps V1, no temp left; the next day retries and succeeds (S3) | `test_aio904_a_sha256_mismatch_keeps_v1_and_the_next_day_retries`, `test_aio904_a_failed_check_is_retried_only_the_next_day` |
| AIO‑904 | non-localhost `http://` gateway: no download (S4) | `test_aio904_a_non_localhost_http_gateway_makes_no_request` (and `..._localhost_http_gateway_is_allowed`) |
| AIO‑904 | `evil.sh`, `../x`, not-installed name: nothing written (S5) | `test_aio904_names_outside_the_four_or_not_installed_write_nothing`, `..._an_installed_name_is_replaced_even_when_the_manifest_lists_others`, `..._a_symlink_in_tools_is_not_followed_or_replaced` |
| AIO‑904 | `settings.json` byte-identical (S6) | `test_aio904_settings_json_is_byte_identical` |
| AIO‑904 | the `.ps1` pair is replaced, CRLF kept (S8, plugin side) | the S1 test (all four names, `od -c` shows `\r`), real-curl test (`aionas-statusline-tap.ps1`) |
| AIO‑904 | `egress-manifest.test.sh` passes with the new calls listed (S9) | `egress-manifest.test.sh` (committed manifest matches; planted public call listed) |
| AIO‑904 | the download carries no alias | `test_aio904_the_manifest_call_carries_the_alias_the_downloads_do_not`, `test_aio904_aionas_http_public_sends_no_auth_and_checks_the_gateway`, `test_aio904_with_the_real_curl_...` (alias seen once in the stub's log: the manifest request) |
| AIO‑904 | not enrolled: no request | `test_aio904_not_enrolled_makes_no_request_and_writes_nothing`, `not-enrolled.test.sh` |
| AIO‑904 | old gateway (404) is a quiet no-op | `test_aio904_a_manifest_the_gateway_does_not_know_is_a_quiet_no_op` (404, 500, 000, 301, 204) |
| AIO‑904 | hash tool on PATH is not used | `test_aio904_a_hash_tool_planted_on_path_is_never_used`, `..._without_any_hash_tool_it_fails_closed` |

Success lines that name only the gateway or the Apps column are not in this package (see Unverified).

## Security, privacy and reliability evidence

- Integrity: a manifest name must be one of the four fixed names AND already an installed regular file (a symlink is refused); no URL is ever taken from the manifest (the path is built from the allow-listed name and the enrolled gateway); version must match `^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$` and not be `__AIONAS_RELEASE__`; sha256 must be 64 lowercase hex and equal the downloaded bytes; a `.sh` must start with `#!`; the stamp inside the bytes must equal the manifest version; the response must be exactly 200 (no `-L`, a redirect is 3xx); size cap 1 MB (`--max-filesize`).
- Hash tool: fixed paths only, tried in order `/usr/bin/sha256sum`, `/sbin/sha256sum` (macOS 14+), `/usr/bin/shasum -a 256`, `/usr/bin/openssl dgst -sha256 -r`; none found means nothing is installed (fail closed). New in this package (0.4.0 had no hashing). `AIONAS_SHA256_BIN` replaces the lookup for tests only, like `AIONAS_CURL` and `AIONAS_SCAN_BIN`.
- Alias: the download goes through `aionas_http_public`, which has no auth header at all; the alias stays in the 0600 header file used by the manifest call only.
- Atomicity: temp file `<name>.tmp.<pid>` in the same folder, created with noclobber under umask 077, `chmod 700`, then `mv -f` over the name (a rename, never an in-place write; a running bash reads its script lazily). Bytes are written as received: no line-ending change. Every failure path (and an EXIT/HUP/INT/TERM trap) removes the temp; the old file stays.
- Cleanup: `rm -f` by exact name only (the four `.prev`, and `<name>.tmp.<digits>` leftovers); no recursive delete anywhere (a test greps the source).
- Concurrency: lock `script-refresh` (stale after 120 s).
- Never writes `settings.json` or any path outside the tools folder and the plugin's own `savings` state folder.

## Integration seams

- Hot files touched in separate seam commits: none (repo has none); sibling tests edited as listed.
- hooks.json timeout is 30 (not 10): a 5 s manifest call plus up to 4 downloads of 5 s each.
- Merge order: independent of the gateway merge; against an old gateway the hook is a quiet no-op.

## FLAGGED-FOR-RATIFICATION

1. **Day stamp before the request.** `savings/script-refresh.day` is written before the manifest request, so a failed check (404, sha mismatch, timeout) is retried only on the next UTC day, as the prompt wants. A failure caused by a transient network error also waits a day. Stamping only after success would retry at every session start.
2. **Stamp in the served bytes must equal the manifest version.** Not required by the prompt (the "optional belt"). Without it, a gateway serving bytes whose stamp differs from the manifest would re-download every day and never converge; with it, such bytes are simply never installed (still one download attempt a day, no replacement).
3. **`.prev` lifetime.** Kept until the first run on a later UTC day (the day it was made is in `savings/script-refresh.prevday`), so it can live longer than 24 hours if no session starts for a while. A missing record counts as "not today" and is cleaned.
4. **Nothing installed means no request and no day stamp**: the hook first checks that at least one of the four is an installed regular file.
5. **Entries read:** at most the first 8 manifest entries; the first occurrence of a name wins.

## Unverified claims and blockers

- UNVERIFIED (live only): S7, the gateway's Apps column showing V2 after a sweep.
- UNVERIFIED: a real Windows Git Bash run. A rename over a `.ps1` that PowerShell holds open may fail; the hook then keeps the old file and removes the temp and the `.prev` it just made (the failure branch is written but only a Unix `mv` failure path is reachable in tests). `HOME` versus `USERPROFILE` differences and paths with spaces are not exercised (the paths are quoted everywhere; the tools folder comes from `aionas_agent_dir`, as in the daily scan).
- UNVERIFIED: the pwsh and macOS plan-usage harnesses of the gateway repo.
- UNVERIFIED: behaviour on mawk/gawk or on a Linux host without `/sbin/sha256sum`: tests ran on macOS only (the CI runner has `/usr/bin/sha256sum`, which is first in the lookup).
- Blocked by: nothing.

## Rollback

Revert the feat and test commits. The plugin's own state files `savings/script-refresh.day` and `savings/script-refresh.prevday` are inert once the hook is gone; any `*.prev` left in the tools folder is a copy of the previous script and can be deleted by name.

## Review-fix log (2026-11-01)

Finding 1 [major] S5 test passed without its guard. Fixed in `tests/unit/script-refresh.test.sh`, `test_aio904_names_outside_the_four_or_not_installed_write_nothing`: for every hostile name (`evil.sh`, `../x`, `../../savings/pwn`, `aionas-scan`, `aionas-plan-usage.sh/../evil`, not-installed `.ps1`, empty) the fake gateway now serves valid bytes (matching sha and stamp) under the URL's last segment, and existing files at the resolved targets (`tools/aionas-scan`, `agent/x`, `savings/pwn`) must stay `KEEP`; the test also asserts only the manifest was requested (no download attempted). No hook change.

M9 re-run (replace `aionas_sr_name_ok "$_sr_name" || continue` with `:`): script-refresh.test.sh 30 passed, 1 failed (the S5 test is red). Hook restored; 31/31 green again.

Full evidence re-run: `make test` ALL PASSED; `make validate` 44 pass, 0 fail; `shellcheck -S error -s bash` over plugins and tests exit 0.
