# Work Package Handoff

```yaml
work_package: W25P-P3B (plugin usage probe sends the full /usage text, AIO-892 plugin half)
contract_version: AIONAS-24H-v1
builder: claude-sonnet-5
base_commit: 6d7c4ddf8eacfb71748cbf77ef38f4759006fa53
branch: w25p/p3b-usage-raw
head_commit: 777ea8d   # last code/docs commit; this file is the next, final commit
status: ready_for_review
started_at: 2026-11-01
completed_at: 2026-11-01
```

## Outcome

The usage probe (at most once every 4 hours) no longer parses anything. It still runs Claude Code's own `/usage` (same binary lookup, 4-hour stamp, fresh-tap skip, no-account skip, recursion guard, process-group kill, 20 s timeout, 64 KiB output cap), and when the JSON it prints has `local_command == "usage"`, `is_error == false` and a string `result`, it sends that `result` unchanged as `usage_raw` in one `usage_cmd` sample. The gateway (lane e1) reads the weekly figure and keeps the raw text when its parse fails. A result over 32 KiB (decoded, in bytes) is not sent and is counted locally as `usage_probe_too_large`. Observed against a stub `claude` only (no real login, no model call): the sanitized real 2.1.311 capture produces one POST whose `usage_raw` is the `result` byte for byte (checked by decoding both JSON documents with an independent JSON parser, and by comparing the escaped text to the body string).

## Body shape for the gateway lane e1 (exact)

```json
{"tool":"claude_code","source":"usage_cmd","observed_at":"<ISO UTC, to the second>",
 "account_uuid":"<uuid, when the login file has one>","organization_uuid":"<uuid, optional>","organization_name":"<cleaned, optional>",
 "claude_version":"<X.Y.Z, only when the binary's folder names it; else absent>",
 "windows":[{"kind":"weekly_all","window_minutes":10080}],
 "usage_raw":"<the result text, JSON-escaped exactly as Claude Code wrote it>"}
```

- Sent as one line, in that key order, to `POST /cc-quota/v1/samples` with the enrollment alias (existing `aionas_http`).
- There is no `utilization`, `used_percent` or `resets_at` anywhere in the body.
- `usage_raw` is at most 32768 bytes of decoded UTF-8 text; the plugin never sends more (the JSON-escaped form on the wire can be longer).
- FLAGGED-FOR-RATIFICATION (placement): the task text lists `kind`, `usage_raw` and `claude_version` flat next to `source`. The existing gateway decoder reads `kind` from `windows[]`, so `kind` (and `window_minutes`) stay in `windows[0]` as today, and `usage_raw` / `claude_version` are top-level fields next to the account and organization fields. Lane e1 must accept exactly this, or tell the orchestrator to move them.
- `claude_version`: no extra run is made. The value comes from the path only: Claude Desktop's `.../claude-code/<X.Y.Z>/...` folder or the VS Code extension's `anthropic.claude-code-<X.Y.Z>[-<platform>]` folder. A `claude` found on `PATH` names no version, so the field is absent for it. There is no `collector_version` in the plugin today, so none is sent.

## Scope and exclusions

- Changed: `lib/usage-probe.sh` (parser, reset conversion, percent check and the unparsed counter removed; result checks, size check, version-from-path and the new body added), `hooks/usage-probe.sh` (header comment), `lib/usage-probe.awk` deleted, `security/egress-manifest.txt` regenerated, tests, README privacy note and lib table, SECURITY note, CHANGELOG bullet.
- Not touched: the gateway, `catalog.sh` (the closed counter list; `usage_probe_too_large` is a local file counter and never goes through the queue, because the gateway's counter list rejects unknown names for the whole batch), `mod.tsx`, `hooks.json`, `time.awk` (still used by other code), the version, the release.
- Deferred: a live run of a real `/usage`; the gateway side; sending the too-large counter to the server.

## Files and commits

| Commit | Type | Purpose |
|---|---|---|
| `7ad7c66` | test | RED: tests for the new body, the checks, the size limit, the version from the path; parser tests removed. 9 failed, 37 passed before the change |
| `8b0a58f` | feat | `lib/usage-probe.sh`, `hooks/usage-probe.sh`, `usage-probe.awk` removed, egress manifest, one test addition |
| `777ea8d` | docs | README privacy note and lib table, SECURITY note, CHANGELOG bullet |
| last | docs | this file |

## Behaviour in detail

- Sent only when: exit 0, valid JSON, top-level `local_command` is the string `usage`, top-level `is_error` is the boolean `false`, top-level `result` is a non-empty string with no raw control character. Anything else: nothing is sent and nothing is counted (the server decides what a result means; the old local unparsed counter is gone).
- Size: the output cap in the wait loop (64 KiB) and after exit counts as too large; the result text is measured after decoding its escapes (so `\n` is one byte, a middle dot is two) and over 32768 bytes it is too large. Exactly 32768 is sent, 32769 is not. A `\uXXXX` escape above 0x7f is counted as written (6 bytes), which only over-counts.
- The text is never looked at, split, trimmed or re-encoded: the raw JSON string content from the child's output is put between the quotes of `usage_raw`.
- FLAGGED-FOR-RATIFICATION: an empty `result` is not sent (nothing to parse or keep). The task text does not say; the minimal choice was to skip it.
- Counters file: `~/.aionas/agent/savings/counters/usage_probe_too_large` (an integer), replacing `usage_probe_unparsed`. An existing `usage_probe_unparsed` file on a computer is left alone and no longer written.

## RED evidence

```text
command: bash tests/unit/usage-probe.test.sh   (new tests, before the feature commit)
actual result: 37 passed, 9 failed
  e.g. the body still held used_percent and resets_at, and a 32768-byte result was not sent
```

## GREEN evidence

```text
command: bash tests/unit/usage-probe.test.sh   (the hooks run under the system bash 3.2 because the test PATH puts /usr/bin:/bin after the stub)
actual result: 46 passed, 0 failed
command: make test      -> ALL PASSED
command: make validate  -> 45 pass, 0 fail (plugin validate x2 and plugin test), offline from the npx cache of the pinned Claude Code 2.1.299
command: find plugins tests -type f \( -name '*.sh' -o -name '*.lib' \) -print0 | xargs -0 shellcheck -S error -s bash   -> clean
command: bash tests/security/egress-manifest.sh | diff - security/egress-manifest.txt   -> no difference (one line fewer: the awk file)
```

`make test` run on the tree of commit `777ea8d` (the handoff file is the only later change): every test file, ALL PASSED.

## Tests (what each pins)

| Test | Pins |
|---|---|
| `test_real_2_1_311_capture_sends_the_whole_result_as_usage_raw` | the exact body for the real capture (header line, two week lines, the contributing section with a folder, a skill and an MCP name); decoded `usage_raw` equals decoded `result`; middle dot and newlines in the body; alias only in the header file |
| `test_the_body_carries_no_parsed_figure` | no `utilization`, `used_percent`, `resets_at`; the text appears only inside `usage_raw`; no login-file e-mail or user id |
| `test_a_short_result_is_sent_whole_too` | the shorter reconstructed fixture is sent whole as well |
| `test_json_escapes_in_the_result_survive_byte_for_byte` | quote, backslash, slash, tab, `·`, a surrogate pair, a raw middle dot, blank lines; the body is valid JSON and decodes to the same string |
| `test_the_text_is_not_parsed_by_the_plugin` | an unknown shape is sent as it is, no counter |
| `test_only_a_successful_usage_local_command_is_sent` | another `local_command`, `is_error` true / string / null / missing, missing or non-string fields, non-JSON, truncated JSON, nested keys, empty result, raw control character, child exit 1: nothing sent, no counter |
| `test_the_size_limit_is_32_kib_of_decoded_text` | 32768 bytes sent; 32769 and 33 KiB not sent and counted; escapes and multi-byte text measured by decoded bytes; the counter never reaches the queue or `catalog.sh` |
| `test_there_is_no_unparsed_counter_and_no_parser_left` | no `usage_probe_unparsed` file, no `usage-probe.awk`, none of the parser or reset functions or the zone directory in the code |
| `test_claude_version_is_sent_only_when_the_path_already_names_it` | PATH binary: no field and one run per probe; Desktop folder and VS Code folder: the number only |
| `test_output_over_the_cap_stops_the_child_and_sends_nothing` | now also: counted as too large |
| everything of the old item-1 set (4-hour stamp, fresh tap, no account, API-key logins, binary lookup order and symlink rules, `AIONAS_USAGE_PROBE` guard in every hook, process-group kill, timeout, TERM to the hook, five parallel starts, lock) | unchanged and green |

## Security, privacy and reliability

- Privacy change, by the owner's ruling: the full `/usage` text now leaves the computer, to the organization's own gateway only, through the existing `POST /cc-quota/v1/samples` call (already in `security/egress-manifest.txt`; no new network call). That text includes Claude Code's own "What's contributing" section: local folder names, skill, sub-agent and MCP names, request counts. Prompts and model replies never do. README privacy note, SECURITY note and CHANGELOG say so.
- The login token is never read; the alias stays in a private header file and never on a command line (tested).
- Failure and recovery: unchanged from the previous package (stamp before the child starts, lock with re-check, trap on EXIT / HUP / INT / TERM, whole-group stop, leftovers removed by exact name, no recursive delete anywhere).
- Injection: the text is placed in the body only after the JSON reader accepted it as one string, and a raw control character (which is not valid inside a JSON string) stops the send; no value is expanded by the shell or used as a format string (`printf` gets it as an argument).
- The body is written to a file in the private working folder and posted with `--data-binary @file`, so a 32 KiB text never reaches a command line.

## Unverified claims and blockers

- Unverified: a live run of a real `/usage` after this change; the gateway accepting this body (lane e1) and its limits (the server counts bytes of the decoded string; the plugin does the same); the VS Code and Windows paths (as before); that the version in a Desktop or extension folder name is always the binary's `--version` (true for the two Desktop builds checked in the previous package).
- The reconstructed fixture `tests/fixtures/usage-probe/usage-2.1.311.json` is kept (an older fixture, now used only by the shorter-result test); its README text still describes the old parser and is left untouched on purpose.
- Blocked by: nothing.

## Rollback

Revert the feature commit (the previous parser comes back), or remove the `usage-probe.sh` entry from `hooks/hooks.json` (the probe stops at once). State left on a computer: `savings/usage-probe.last`, `savings/counters/usage_probe_too_large` and the empty folder `state/usage-probe`; nothing needs deleting.

## Suggested verifier commands

```text
bash tests/unit/usage-probe.test.sh
make test
make validate            # needs npx and the pinned Claude Code 2.1.299
find plugins tests -type f \( -name '*.sh' -o -name '*.lib' \) -print0 | xargs -0 shellcheck -S error -s bash
bash tests/security/egress-manifest.sh | diff - security/egress-manifest.txt
```
