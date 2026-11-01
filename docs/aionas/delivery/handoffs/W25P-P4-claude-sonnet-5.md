# Work Package Handoff

```yaml
work_package: W25P-P4 (plugin subagent_sonnet fired/skipped counter + catalog-price verdict)
contract_version: AIONAS-24H-v1
builder: claude-sonnet-5
base_commit: ebb3e063ec903189d67bed6b739fc1a2771123d1
branch: w25p/p4-counters
head_commit: ea254be   # last code/docs commit; this file is the next, final commit
status: ready_for_review
started_at: 2026-11-01
completed_at: 2026-11-01
```

## Outcome

Each sub-agent start now adds exactly one `subagent_sonnet` counter row: `fired` while the method is active for the session (`aionas_policy_active`, the same test `effort-window.sh` uses for `effort_default`), else `skipped`. The row rides the existing hourly counters flush. No new hook, no new network call, no version bump. The Sonnet choice itself is untouched.

Price verdict (item 2): **change nothing; the plugin holds no price table.** See "Price verdict".

## Scope and exclusions

- Implemented: `--subagent-start` mode in `commands/aionas-bypass.sh`, `aionas_subagent_count` in `commands/aionas-bypass-lib.sh`, one call in the mod's existing `agent.spawn` handler (`hooks/mod.tsx`), shell and mod tests, one CHANGELOG line under `## Unreleased (0.5.0)`.
- Not touched: `hooks/hooks.json` (a sub-agent start is already seen by the mod's `agent.spawn`; no SubagentStart entry exists or is needed), `lib/counters.sh` (the `--count` helper and `aionas_counter_inc` already existed), `security/egress-manifest.txt` (no call added), version files, any gateway file.

## Contracts

- Consumed: closed counter lists in `lib/catalog.sh` (`subagent_sonnet` is a method id; `fired` and `skipped` are counters) and the existing `POST /enroll/v1/savings/counters` body.
- Produced: queue rows `<day> subagent_sonnet fired|skipped 1`; nothing new on the wire.
- Backward compatibility: `--subagent-model` (the decision) is unchanged and counts nothing; a test pins that.

## Files and commits

| Commit | Type | Files | Purpose |
|---|---|---|---|
| `0237566` | test | `tests/unit/subagent-counters.test.sh`, `plugins/aionas-savings/tests/mod.test.tsx` | RED tests (shell counter behaviour, mod calls the script once per spawn) |
| `8382875` | feat | `commands/aionas-bypass.sh`, `commands/aionas-bypass-lib.sh`, `hooks/mod.tsx` | the count, one per sub-agent start |
| `ea254be` | docs | `CHANGELOG.md` | one line under Unreleased (0.5.0) |
| last | docs | this file | handoff |

## Mapping of the AIO-898 plugin Success line to tests

Success line: "The plugin unit test shows a `subagent_sonnet fired` counter row after a sub-agent start with the method on, and `skipped` with it off."

| Requirement | Test |
|---|---|
| method on -> one `fired` row | `tests/unit/subagent-counters.test.sh` `test_start_with_the_method_on_counts_one_fired` |
| off (bypassed) -> one `skipped` row | `test_start_with_the_method_bypassed_counts_one_skipped` |
| off (by the organization) -> one `skipped` row | `test_start_with_the_method_off_by_the_organization_counts_one_skipped` |
| two starts -> 2, no other row | `test_two_starts_count_two_and_only_for_this_method`, `test_the_state_change_between_starts_is_followed` |
| under `AIONAS_USAGE_PROBE=1` -> nothing (no queue, no counters dir) | `test_usage_probe_child_counts_nothing` |
| next counter flush body carries the rows (E2E step 5: "next flush carries `subagent_sonnet fired`") | `test_the_next_flush_body_carries_the_row` (exact body: fired 2, skipped 1) |
| the mod runs the script once per start, before the model decision, in both states | `mod.test.tsx` "each sub-agent start runs the counting script exactly once..." |
| the model decision counts nothing; no new hook | `test_the_model_decision_itself_counts_nothing`, `test_the_hook_list_has_no_new_entry_and_the_mod_is_the_only_caller` |
| egress manifest still matches the code | `tests/unit/egress-manifest.test.sh` (in `make test`) |

## Price verdict (item 2)

The plugin holds no family price table and no savings formula over prices. Evidence:

- The only money figures the plugin shows (`today_usd`, `since_on_usd`, `could_save_usd`, plus token counts) are read from the `savings` block of the policy answer that `GET /enroll/v1/savings/policy` already serves, and passed through unchanged: `commands/aionas-bypass-lib.sh:281-288` (parse), `hooks/band.tsx:142-150` (display). The gateway therefore already prices them.
- The plugin sends only closed names and whole numbers: `lib/counters.sh:108-117` (`aionas_counters_body`); no cost or price field exists.
- A search of `hooks/`, `lib/`, `commands/`, `rules/` for price, rate, cost, per-million and model-family names found no price data (the only model name is the `sonnet` alias, `lib/catalog.sh:12`). There is no percentage formula either (the only percent handled is the usage probe's weekly figure, sent as read).

So there is nothing to switch to catalog prices; no change made, and no gateway gap: the price-bearing figures already come from the gateway through an existing route.

## RED evidence

```text
command: bash tests/unit/subagent-counters.test.sh   (before the feature commit)
actual result: 2 passed, 8 failed; "Unknown method '--subagent-start'" and "expected [2] got []"
  (the 2 that pass are invariants: the probe guard already stops the script, the decision counts nothing)
command: plugin test with the one-line call removed from mod.tsx
actual result: (fail) subagent_sonnet > each sub-agent start runs the counting script exactly once...
```

## GREEN evidence

```text
command: bash tests/unit/subagent-counters.test.sh  -> 10 passed, 0 failed
command: make test       -> ALL PASSED (every test file, final tree)
command: make validate   -> plugin validate x2 clean; plugin test: 45 pass, 0 fail (Claude Code 2.1.299, temp config dir)
command: shellcheck -S error -s bash over all .sh/.lib -> clean
```

## Security, privacy and reliability evidence

- Privacy: the row is a closed method id, a closed counter name and `1`; nothing from the sub-agent (prompt, name, model) is read or queued.
- Recursion: the script sources `lib/aionas.sh`, whose first code line ends it under `AIONAS_USAGE_PROBE`; a test proves no file is written.
- Not enrolled: nothing is counted (the plugin does nothing without the alias, and queued rows would otherwise be sent under a later enrollment). Flagged below.
- Reliability: exit 0 always, silent; a failed script run in the mod returns an error code that `bypass()` already swallows, and the handler still calls the model decision and `next(e)`. One extra short process per spawn.
- No recursive deletes, no push, no network, no real `claude` model call.

## Flags

- FLAGGED-FOR-RATIFICATION: the count is skipped on a computer that is not enrolled (the spec says count `skipped` whenever the method is not active; an unenrolled computer reports every method off). Chosen to honor "without the one install the plugin does nothing". Reversal is deleting one line in `aionas_subagent_count`.
- Note: "active" follows the policy, as specified. A person who set their own `CLAUDE_CODE_SUBAGENT_MODEL` keeps their value while the method is on; that start still counts `fired`. Counting "Sonnet actually applied" would need a different definition.
- The mod test world mocks `process.run`; the real end-to-end spawn on a live Claude Code was not run (no model calls allowed).

## Unverified

- A real sub-agent start on a live Claude Code session (mod `agent.spawn` is exercised through the test kit only).
- A real flush against a live gateway (fake curl only).
