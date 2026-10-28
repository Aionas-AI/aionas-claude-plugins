#!/usr/bin/env bash
# hooks/write-minimum.sh: the lab's "code paragraph", exactly as tested, at
# SessionStart (AIO-889; lab/methods/write-minimum-code, verdict 28.10)
. "$(dirname "$0")/../lib/harness.sh"

HOOK="$T_PLUGIN/hooks/write-minimum.sh"
CTX="$T_PLUGIN/hooks/write-minimum-context.json"
# sha256 of lab/methods/write-minimum-code/plugin/hooks/additional-context.json
LAB_SHA=899536584e94f0fe5ae279ce470c8ab31e629b557473103c7e0a7f2bbf911fcc
PARAGRAPH="Write the minimum code that does the job: only make the changes the task needs. Don't add helpers, abstractions, configuration or error handling for scenarios that can't happen. If you find a pre-existing bug or behavior the task doesn't mention, don't fix or extend it unless the requested behavior cannot work without it; mention it in your summary instead."

hook() { printf '{"session_id":"s1","hook_event_name":"SessionStart","source":"%s"}' "${1:-startup}" | bash "$HOOK"; }
cache() { # policy cache lines (tab separated) -> policy.cache and the s1 pin
  aionas_mkdir "$(aionas_savings_dir)/sessions"
  printf '%b' "$1" >"$(aionas_savings_dir)/policy.cache"
  cp "$(aionas_savings_dir)/policy.cache" "$(aionas_savings_dir)/sessions/s1.cache"
}
sha() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1 || sha256sum "$1" | cut -d' ' -f1; }
queue() { cut -f2- "$(aionas_savings_dir)/counters/queue.tsv" 2>/dev/null | tr '\t\n' ' ;'; }

test_the_shipped_file_is_the_labs_byte_for_byte() {
  t_eq "$LAB_SHA" "$(sha "$CTX")"
  t_eq "SessionStart" "$(aionas_json_flatten "$CTX" | aionas_json_get hookSpecificOutput.hookEventName)"
  t_eq "$PARAGRAPH" "$(aionas_json_flatten "$CTX" | aionas_json_get hookSpecificOutput.additionalContext | aionas_json_unescape)"
}

test_on_prints_the_file_exactly_for_every_source() {
  local src
  for src in startup resume clear compact; do
    t_eq "$(cat "$CTX")" "$(hook "$src")" "source $src"
  done
  t_eq "write_minimum fired 1;write_minimum fired 1;write_minimum fired 1;write_minimum fired 1;" "$(queue)"
}

test_off_released_or_bypassed_prints_nothing() {
  cache 'V\t1\nM\twrite_minimum\toff\t0\t1\t1\t0\n'
  t_eq "" "$(hook)" "off"
  cache 'V\t1\nM\twrite_minimum\ton\t0\t1\t1\t1\n'
  t_eq "" "$(hook)" "released"
  cache "V\t1\nM\twrite_minimum\ton\t0\t1\t1\t0\nO\twrite_minimum\tself\t0\t0\tovr_1\n"
  t_eq "" "$(hook)" "bypassed"
  t_eq "write_minimum skipped 1;write_minimum skipped 1;write_minimum skipped 1;" "$(queue)"
}

test_registered_once_on_session_start_without_matcher_or_async() {
  local hj="$T_PLUGIN/hooks/hooks.json"
  t_eq 1 "$(grep -c 'write-minimum.sh' "$hj")"
  t_lacks "$(cat "$hj")" '"matcher": "write'
  t_not test -e "$T_PLUGIN/skills/write-minimum/SKILL.md"
}

t_main "$@"
