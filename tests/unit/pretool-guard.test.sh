#!/usr/bin/env bash
# hooks/pretool-guard.sh + rules/guard-store.tsv: the noisy-command guard
# (AIO-860, W24-P1).
. "$(dirname "$0")/../lib/harness.sh"
GUARD="$T_PLUGIN/hooks/pretool-guard.sh"
RULES="$T_PLUGIN/rules/guard-store.tsv"
unset AI_AGENT AIONAS_CC_VERSION AIONAS_FULL

# pre CMD: run the guard on a Bash call; prints the hook's answer.
pre() {
  printf '{"session_id":"s1","transcript_path":"%s/none.jsonl","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":%s,"description":"run it","timeout":120000,"run_in_background":false},"tool_use_id":"t1"}' \
    "$HOME" "$(aionas_json_escape "$1")" | bash "$GUARD"
}
# new_cmd CMD: the rewritten command (decoded), or "" when unchanged.
new_cmd() {
  local out; out=$(pre "$1")
  [ -z "$out" ] && return 0
  aionas_json_flatten <<<"$out" | aionas_json_get hookSpecificOutput.updatedInput.command | aionas_json_unescape
}
queue() { cat "$(aionas_savings_dir)/counters/queue.tsv" 2>/dev/null | cut -f2- | tr '\t' ' '; }
# policy JSON: sync a policy answer into the cache.
policy() {
  t_enroll
  printf '%s' "$1" >"$HOME/policy.json"
  export FAKE_CURL_STATUS=200 FAKE_CURL_BODY="$HOME/policy.json"
  t_rc 0 aionas_policy_sync
}
setup() { export AIONAS_CC_VERSION=2.1.299; }

test_rule_file_is_versioned_and_well_formed() {
  t_eq 1 "$(awk -F '\t' '$1 == "version" { print $2 }' "$RULES")"
  t_eq 2.1.299 "$(awk -F '\t' '$1 == "setting" && $2 == "min_claude_code" { print $3 }' "$RULES")"
  t_eq 1500 "$(awk -F '\t' '$1 == "setting" && $2 == "cap_tokens" { print $3 }' "$RULES")"
  t_eq 2000 "$(awk -F '\t' '$1 == "setting" && $2 == "store_tokens" { print $3 }' "$RULES")"
  t_eq "pytest npm_install git_log cat_cap grep_cap sed_cap" "$(awk -F '\t' '$1 == "rule" { printf "%s%s", (n++ ? " " : ""), $2 }' "$RULES")"
  t_eq 0 "$(awk -F '\t' '$1 == "rule" && (NF != 6 || ($3 != "quiet" && $3 != "cap") || $4 ~ /\\/ || $5 ~ /\\/)' "$RULES" | wc -l | tr -d ' ')" "malformed rule rows"
}

test_rewrites_exactly_the_rule_file_commands() {
  setup
  local c want got
  while IFS='~' read -r c want; do
    got=$(new_cmd "$c")
    t_eq "$want" "$got" "rewrite of [$c]"
  done <<'EOF'
pytest~AIONAS_GUARD=pytest pytest -q
pytest tests/unit -k "slow and not db"~AIONAS_GUARD=pytest pytest -q tests/unit -k "slow and not db"
python -m pytest tests~AIONAS_GUARD=pytest python -m pytest -q tests
python3 -m pytest~AIONAS_GUARD=pytest python3 -m pytest -q
npm install~AIONAS_GUARD=npm_install npm install --no-audit --no-fund --no-progress
npm i lodash~AIONAS_GUARD=npm_install npm i --no-audit --no-fund --no-progress lodash
npm ci~AIONAS_GUARD=npm_install npm ci --no-audit --no-fund --no-progress
git log~AIONAS_GUARD=git_log git log -n 30 --oneline
git log --author=tal -- src~AIONAS_GUARD=git_log git log -n 30 --oneline --author=tal -- src
cat big.log~
grep -rn 'foo bar' src~
rg TODO~
sed -n 1,400p main.go~
FOO=1 git log~AIONAS_GUARD=git_log FOO=1 git log -n 30 --oneline
pytest -q~
pytest -v tests~
python -m pytest --verbose~
npm install --silent~
npm i --loglevel=error~
git log -n 5~
git log -5~
git log --oneline~
git log --format=%H~
git log -p~
sed -i s/a/b/ f.txt~
pytester~
catalog list~
git logs~
npm run build~
ls -la~
git status~
git log | head~
cat a.txt > b.txt~
pytest && echo ok~
grep x $(ls)~
cat `ls`~
AIONAS_FULL=1 git log~
AIONAS_GUARD=git_log git log -n 30 --oneline~
EOF
}

test_every_rewrite_starts_with_the_fixed_prefix() {
  setup
  local id got
  for id in pytest:pytest npm_install:'npm install' git_log:'git log'; do
    got=$(new_cmd "${id#*:}")
    case "$got" in "AIONAS_GUARD=${id%%:*} "*) ;; *) t_fail "no AIONAS_GUARD=${id%%:*} prefix: [$got]" ;; esac
  done
}

test_rewrite_keeps_every_other_input_field() {
  setup
  local out f
  out=$(pre 'git log')
  f=$(aionas_json_flatten <<<"$out") || t_fail "not JSON: $out"
  t_eq PreToolUse "$(aionas_json_get hookSpecificOutput.hookEventName <<<"$f")"
  t_eq "run it" "$(aionas_json_get hookSpecificOutput.updatedInput.description <<<"$f")"
  t_eq 120000 "$(aionas_json_get hookSpecificOutput.updatedInput.timeout <<<"$f")"
  t_eq false "$(aionas_json_get hookSpecificOutput.updatedInput.run_in_background <<<"$f")"
  # It never decides permissions: the person's rules still apply.
  t_rc 1 aionas_json_get hookSpecificOutput.permissionDecision <<<"$f"
  t_rc 1 aionas_json_get hookSpecificOutput.additionalContext <<<"$f"
}

test_quiet_rewrite_counts_fired_a_cap_rule_does_not() {
  setup
  pre 'pytest' >/dev/null
  pre 'cat big.log' >/dev/null
  pre 'ls' >/dev/null
  t_eq "noisy_guard fired 1" "$(queue)"
}

test_bypass_runs_unchanged_and_writes_one_counter() {
  setup
  t_eq "" "$(pre 'AIONAS_FULL=1 git log')"
  t_eq "noisy_guard bypass 1" "$(queue)"
  # A command no rule rewrites is not a guard bypass here (a cap rule's
  # bypass is counted by posttool-store.sh, when there was something to cut).
  t_eq "" "$(pre 'AIONAS_FULL=1 ls')"
  t_eq "" "$(pre 'AIONAS_FULL=1 cat big.log')"
  t_eq 1 "$(queue | wc -l | tr -d ' ')"
}

test_blocked_self_override_keeps_the_guard_and_points_to_a_request() {
  setup
  policy '{"methods":[{"method_id":"noisy_guard","state":"on","required":false,"self_override_allowed":false,"self_release_allowed":true}],"overrides":[]}'
  local out f
  out=$(pre 'AIONAS_FULL=1 git log')
  f=$(aionas_json_flatten <<<"$out") || t_fail "not JSON: $out"
  t_eq "AIONAS_GUARD=git_log AIONAS_FULL=1 git log -n 30 --oneline" "$(aionas_json_get hookSpecificOutput.updatedInput.command <<<"$f")"
  t_contains "$(aionas_json_get hookSpecificOutput.additionalContext <<<"$f")" "/aionas-bypass noisy_guard"
  t_eq "noisy_guard fired 1" "$(queue)"
}

test_method_off_or_bypassed_changes_nothing() {
  setup
  policy '{"methods":[{"method_id":"noisy_guard","state":"off","required":false,"self_override_allowed":true,"self_release_allowed":true}],"overrides":[]}'
  t_eq "" "$(pre 'git log')"
  policy '{"methods":[],"overrides":[]}'
  t_ok aionas_override_local_add noisy_guard 600
  t_eq "" "$(pre 'git log')"
  t_eq "" "$(queue)"
}

test_cap_rules_never_rewrite_and_quiet_rules_need_no_version() {
  # A prefix would stop the person's Bash(cat:*) allow rule from matching.
  local v
  for v in 2.1.100 2.1.299 2.2.0; do
    export AIONAS_CC_VERSION=$v
    t_eq "" "$(pre 'cat big.log')"
    t_eq "" "$(pre 'grep -n x f')"
    t_eq "" "$(pre 'sed -n 1,9p f')"
    t_eq "AIONAS_GUARD=git_log git log -n 30 --oneline" "$(new_cmd 'git log')"
  done
}

test_other_tools_and_bad_input_change_nothing() {
  setup
  t_eq "" "$(printf '{"tool_name":"Read","tool_input":{"file_path":"/x"}}' | bash "$GUARD")"
  t_eq "" "$(printf 'not json' | bash "$GUARD")"
  t_rc 0 bash "$GUARD" </dev/null
  t_eq "" "$(pre "$(printf 'git log\npytest')")"
}

t_main "$@"
