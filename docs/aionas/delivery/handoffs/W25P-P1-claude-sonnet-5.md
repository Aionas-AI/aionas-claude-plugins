# Work Package Handoff

```yaml
work_package: W25P-P1
contract_version: AIONAS-24H-v1
builder: claude-sonnet-5
base_commit: 215346bb7d2067a0d80cbd19fbb2b923aff0983b
branch: w25p/p1-detect
head_commit: see "Files and commits" (the handoff commit is the last one on the branch)
status: ready_for_review
started_at: 2026-11-01T00:30:00Z
completed_at: 2026-11-01T00:55:00Z
```

## Outcome

The plugin's SessionStart plan report (`plan-report.sh`) now:

- reads the member's own rate-limit tier (`userRateLimitTier` when a non-empty string, else `organizationRateLimitTier`): a Team seat whose own tier is `default_claude_max_5x` is sent as `team_premium`; a Team seat with an absent or null own tier is `team_standard`; Max 20x with a null own tier is still `max_20x`;
- sends a tier containing `ultra` as `max_20x` (no new plan id);
- adds the optional `organization_uuid` and `organization_name` to the samples body; with neither present the body is byte-for-byte what it was.

Observed: every assertion below is on the request body captured by the fake curl, not on internal variables.

## Scope and exclusions

- Implemented: the three changes above, in `plan-report.sh` only; tests; one CHANGELOG entry under `## Unreleased (0.5.0)`.
- Explicitly not implemented: the installer's plan collector, the status-line tap, the gateway (other packages); no version bump of `plugin.json` / `marketplace.json`; no change to `hooks.json`, `lib/` or `security/egress-manifest.txt` (no new network call).
- Deferred/stretch: none.

## Contracts

- Consumed contract/version: gateway `POST /cc-quota/v1/samples` new optional fields `organization_uuid` (`^[0-9a-fA-F-]{8,64}$`, else dropped) and `organization_name` (control and bidi characters dropped, trimmed, cut to 128 characters, empty means none), as in the wave 25 foundation contracts commit.
- Produced interfaces/artifacts: the two optional body fields, placed after `account_uuid` and before `plan`.
- Contract changes requested: none.
- Backward compatibility: a computer whose `~/.claude.json` has no organization fields sends the same body as before (test `test_aio901_no_organization_fields_leaves_the_body_as_before`).

## Files and commits

| Commit | Type | Files | Purpose |
|---|---|---|---|
| `578c78f` | test | `tests/unit/plan-report.test.sh` | RED tests: member tier, Ultra, organization fields |
| `b95af97` | feat | `plugins/aionas-savings/hooks/plan-report.sh`, `plugins/aionas-savings/CHANGELOG.md` | the change and the changelog line |
| (last) | docs | `docs/aionas/delivery/handoffs/W25P-P1-claude-sonnet-5.md` | this handoff |

## RED evidence

```text
command: bash tests/unit/plan-report.test.sh   (at 578c78f, script unchanged)
expected failure: the tests that need the new behavior fail
actual result: 13 passed, 5 failed
  FAIL test_aio899_premium_seat_is_read_from_the_members_own_tier      (got team_standard)
  FAIL test_aio899_the_members_tier_wins_over_the_org_tier             (got max_5x)
  FAIL test_aio900_an_ultra_tier_string_is_max_20x                     (got max)
  FAIL test_aio901_each_organization_of_one_account_sends_its_own_org  (no organization fields)
  FAIL test_aio901_the_organization_name_is_cleaned_and_cut            (no organization fields)
```

Four new tests passed before the change by nature (they pin behavior that must not change): `test_aio899_team_without_a_member_tier_is_standard`, `test_aio899_max_uses_the_org_tier_when_the_member_tier_is_null`, `test_aio901_an_empty_name_and_a_malformed_uuid_are_left_out`, `test_aio901_no_organization_fields_leaves_the_body_as_before`. They are regression guards, so the instruction "each new test fails before the change" holds for 5 of 9.

## GREEN evidence

```text
command: bash tests/unit/plan-report.test.sh   (at b95af97)
actual result: plan-report.test.sh: 18 passed, 0 failed
command: make test validate
actual result: exit 0. make test: ALL PASSED. make validate: manifest and plugin validation passed, plugin mod tests 44 pass, 0 fail (run at b95af97; the later commit only adds this file)
```

## Success lines that name the plugin

| Issue | Success line | Test |
|---|---|---|
| AIO‑899 | With the premium fixture the plugin sends `team_premium` (captured body) | `test_aio899_premium_seat_is_read_from_the_members_own_tier` (also `test_team_premium_is_claude_codes_rule`) |
| AIO‑899 | Same fixture with `userRateLimitTier` absent or `null`, org tier `default_raven`: `team_standard` | `test_aio899_team_without_a_member_tier_is_standard` (null and absent) |
| AIO‑899 | Max 20x fixture (`claude_max`, org tier `default_claude_max_20x`, user tier null): `max_20x`; Max 5x: `max_5x` | `test_aio899_max_uses_the_org_tier_when_the_member_tier_is_null` |
| AIO‑899 | `tier = userRateLimitTier` when non-empty, else the org tier | `test_aio899_the_members_tier_wins_over_the_org_tier` |
| AIO‑899 | `make -C <plugin repo> test` (`tests/unit/plan-report.test.sh`) | whole file, 18 passed |
| AIO‑900 | Fixture tier `default_claude_ultra` is detected as `max_20x` by the plugin; plan ids do not change | `test_aio900_an_ultra_tier_string_is_max_20x` (org tier and member tier; asserts no `ultra` on the wire) |
| AIO‑901 | Every captured sample body from the plugin carries the org uuid and name of the fixture in use | `test_aio901_each_organization_of_one_account_sends_its_own_org` |
| AIO‑901 | A name with a bidi-override character or more than 128 characters is cleaned or cut | `test_aio901_the_organization_name_is_cleaned_and_cut` (UTF-8 bidi, escaped bidi, C1, escaped control, spaces, 200 ASCII characters, 130 two-byte characters cut to 128 characters not bytes) |
| AIO‑901 | A sample with no org fields is unchanged (old client shape) | `test_aio901_no_organization_fields_leaves_the_body_as_before` |
| AIO‑901 | Malformed org uuid / empty name: omitted | `test_aio901_an_empty_name_and_a_malformed_uuid_are_left_out` |

Success lines that name only the collector, the tap, the gateway, the UI or live environments are not in this package.

## Security, privacy and reliability evidence

- Identity/authorization: unchanged; same alias-authenticated `aionas_http` call.
- Organization isolation: the organization id and name are read from the signed-in account's own `~/.claude.json` only.
- Secret/PII handling: the body still carries no email, user id or token (existing canary asserts remain green). The organization name is a new value that leaves the computer; it is cleaned of control and bidi characters and cut to 128 characters. The cleaner works byte-wise (`LC_ALL=C`) and never executes the value; the value is emitted only as JSON text with its escapes kept, so the body stays valid JSON.
- Failure/retry/concurrency: unchanged (lock, atomic last-sent file, retry after a failed send).
- Durability/recovery: the sent-marker now includes the organization (see FLAGGED below), so one extra send happens per computer after the plugin updates.
- Negative tests: malformed uuid, empty name, name made only of bidi characters, lone surrogate escapes dropped, no organization fields.

## Integration seams

- Hot files touched in separate `seam(...)` commits: none.
- Route/schema/migration/config registration required: none.
- Merge order/dependencies: the gateway must accept the two fields (foundation contract); older gateways would reject unknown fields only if strict, which the contract says it is not for these names once the foundation is deployed. Order of release is the orchestrator's call.
- Known conflicts with other WPs: none expected (single script, its own test, CHANGELOG top section).

## Evidence artifacts

- `tests/unit/plan-report.test.sh`
- `plugins/aionas-savings/hooks/plan-report.sh`

## FLAGGED-FOR-RATIFICATION

1. **Sent-marker includes the organization.** The key that decides "already sent today" is now `plan|account|organization uuid|organization name`. Reason: without it an account that switches to another organization with the same plan and account the same day would not be re-sent, and the second fixture of the AIO‑901 test would never reach the gateway. Effect: after the plugin updates, each computer sends once more (the old marker no longer matches), which also backfills the organization.
2. **Ultra is recognized inside `claude_max` only.** The spec names `default_claude_ultra` without an organization type; the known Ultra account has `organizationType=claude_max`. A hypothetical `claude_team` with an `ultra` tier stays `team_standard`.
3. **Placement of the new fields** after `account_uuid`, before `plan` (JSON order is not significant to the gateway).

## Unverified claims and blockers

- Unverified: the name cleaner was run only with the awk on this machine (BWK awk 20200816). It uses no gawk-only features and is byte-wise, but mawk and gawk were not available here to confirm.
- Unverified: behavior against a live gateway (no network calls were made).
- `make test validate` passed in full (see GREEN evidence).
- Blocked by: nothing.
- Required user/customer input: none.

## Rollback

Revert the two commits (`578c78f`, `b95af97`); no state outside the plugin's own `plan-report.last` marker is involved, and an old script simply reads a marker it no longer matches and sends once more.
