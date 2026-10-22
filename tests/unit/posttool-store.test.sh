#!/usr/bin/env bash
# hooks/posttool-store.sh + bin/aionas-recall: the long-output store, the
# guard's sed/grep/cat cap, the AIONAS_FULL=1 bypass and the version probe
# (AIO-860, W24-P1, W24-4).
. "$(dirname "$0")/../lib/harness.sh"
STORE="$T_PLUGIN/hooks/posttool-store.sh"
GUARD="$T_PLUGIN/hooks/pretool-guard.sh"
RECALL="$T_PLUGIN/bin/aionas-recall"
unset AI_AGENT AIONAS_CC_VERSION AIONAS_FULL

setup() { export AIONAS_CC_VERSION=2.1.299; }

# gen N [WIDTH]: N numbered lines of about WIDTH bytes, no final newline.
gen() {
  awk -v n="$1" -v w="${2:-90}" 'BEGIN {
    pad = ""; while (length(pad) < w) pad = pad "abcdefghij"
    for (i = 1; i <= n; i++) printf "%sline %04d %s", (i > 1 ? "\n" : ""), i, substr(pad, 1, w - 10) }'
}
# post CMD FILE [TOOL] [EVENT]: run the store on a tool result whose stdout is FILE.
post() {
  printf '{"session_id":"s1","transcript_path":"%s/none.jsonl","hook_event_name":"%s","tool_name":"%s","tool_input":{"command":%s},"tool_response":{"stdout":%s,"stderr":"a warning","interrupted":false,"isImage":false},"tool_use_id":"t1"}' \
    "$HOME" "${4:-PostToolUse}" "${3:-Bash}" "$(aionas_json_escape "$1")" "$(aionas_json_escape "$(cat "$2")")" | bash "$STORE"
}
# view OUT: the decoded stdout of the hook's answer.
view() { aionas_json_flatten <<<"$1" | aionas_json_get hookSpecificOutput.updatedToolOutput.stdout | aionas_json_unescape; }
# same_bytes A B: the two files hold the same bytes (no cmp on minimal images).
same_bytes() { [ -f "$2" ] && [ "$(od -An -v -tx1 "$1")" = "$(od -An -v -tx1 "$2")" ]; }
sha12() { (shasum -a 256 "$1" 2>/dev/null || sha256sum "$1") | cut -c1-12; }
queue() { cat "$(aionas_savings_dir)/counters/queue.tsv" 2>/dev/null | cut -f2- | tr '\t' ' '; }
policy() {
  t_enroll
  printf '%s' "$1" >"$HOME/policy.json"
  export FAKE_CURL_STATUS=200 FAKE_CURL_BODY="$HOME/policy.json"
  t_rc 0 aionas_policy_sync
}
store_marker() { printf '[aionas-store: kept 40+40 of %s lines (about %s tokens), id=%s. More: aionas-recall %s [--grep PATTERN]. Full: rerun with AIONAS_FULL=1]' "$1" "$3" "$2" "$2"; }
# ftok FILE: the full output's size in tokens as the markers say it (bytes / 4, rounded down).
ftok() { echo $(( $(wc -c <"$1" | tr -d ' ') / 4 )); }

test_view_is_head_40_tail_40_and_the_fixed_marker_byte_for_byte() {
  setup
  gen 300 >"$HOME/o.txt"
  local id out1 out2 want
  id="out_$(sha12 "$HOME/o.txt")"
  out1=$(post './build.sh' "$HOME/o.txt")
  out2=$(post './build.sh' "$HOME/o.txt")
  t_eq "$out1" "$out2" "same output, different answer"
  want="$(head -n 40 "$HOME/o.txt")"$'\n'"$(tail -n 40 "$HOME/o.txt")"$'\n'"$(store_marker 300 "$id" "$(ftok "$HOME/o.txt")")"
  t_eq "$want" "$(view "$out1")"
  # Byte-for-byte in the JSON that reaches Claude Code, too.
  t_contains "$out1" "\"stdout\":$(aionas_json_escape "$want"),"
  # The fixed marker, as a literal string.
  t_eq "[aionas-store: kept 40+40 of 300 lines (about $(ftok "$HOME/o.txt") tokens), id=$id. More: aionas-recall $id [--grep PATTERN]. Full: rerun with AIONAS_FULL=1]" "$(view "$out1" | tail -n 1)"
  # F is the whole output (not the view): 300 lines of 90 bytes plus 299 newlines = 27299 bytes.
  t_eq 6824 "$(ftok "$HOME/o.txt")"
  case "$id" in out_[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) t_fail "bad id $id" ;; esac
  t_eq "output_store fired 1
output_store fired 1" "$(queue)"
}

test_answer_is_the_exact_bash_shape() {
  setup
  gen 300 >"$HOME/o.txt"
  local out f
  out=$(post './build.sh' "$HOME/o.txt")
  f=$(aionas_json_flatten <<<"$out") || t_fail "not JSON"
  t_eq "PostToolUse" "$(aionas_json_get hookSpecificOutput.hookEventName <<<"$f")"
  t_eq "stdout stderr interrupted isImage" "$(awk -F '\t' '$1 ~ /^hookSpecificOutput\.updatedToolOutput\.[^.]+$/ { sub(/.*\./, "", $1); printf "%s%s", (n++ ? " " : ""), $1 }' <<<"$f")"
  t_eq "a warning" "$(aionas_json_get hookSpecificOutput.updatedToolOutput.stderr <<<"$f")"
  t_eq false "$(aionas_json_get hookSpecificOutput.updatedToolOutput.interrupted <<<"$f")"
  t_eq false "$(aionas_json_get hookSpecificOutput.updatedToolOutput.isImage <<<"$f")"
}

test_failed_and_error_lines_stay_in_view() {
  setup
  gen 300 | awk 'NR == 100 { print "FAILED tests/test_a.py::test_x - assert 1 == 2"; next }
                 NR == 150 { print "E   ValueError: bad"; next }
                 NR == 200 { print "ERROR collecting tests/test_b.py"; next } { print }' >"$HOME/o.txt"
  local v
  v=$(view "$(post 'make check' "$HOME/o.txt")")
  t_eq "$(head -n 40 "$HOME/o.txt")
FAILED tests/test_a.py::test_x - assert 1 == 2
E   ValueError: bad
ERROR collecting tests/test_b.py
$(tail -n 40 "$HOME/o.txt")" "$(sed '$d' <<<"$v")"
  t_lacks "$v" "line 0120 "
}

test_full_output_is_kept_locally_byte_for_byte() {
  setup
  # Quotes, backslashes, tabs, a CR and UTF-8 (raw, as Claude Code sends it).
  { gen 120; printf '\nq "x" \\ back\\slash \\n not-a-newline\ttab\r\ncaf\303\251 \342\234\223 \360\237\230\200'; gen 50 | sed 's/^/ /'; } >"$HOME/o.txt"
  local out id
  out=$(post './build.sh' "$HOME/o.txt")
  t_contains "$(view "$out")" "[aionas-store: kept 40+40 of"
  id="out_$(sha12 "$HOME/o.txt")"
  t_ok same_bytes "$HOME/o.txt" "$(aionas_savings_dir)/store/$id.txt"
  t_eq 600 "$(t_mode "$(aionas_savings_dir)/store/$id.txt")"
  t_eq 700 "$(t_mode "$(aionas_savings_dir)/store")"
  # \u escapes (with a surrogate pair) decode to the same bytes.
  printf '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"./b"},"tool_response":{"stdout":"%scaf\\u00e9 \\u2713 \\ud83d\\ude00","stderr":"","interrupted":false,"isImage":false}}' "$(gen 100 | awk '{ printf "%s\\n", $0 }')" | bash "$STORE" >/dev/null
  { gen 100; printf '\ncaf\303\251 \342\234\223 \360\237\230\200'; } >"$HOME/u.txt"
  t_ok same_bytes "$HOME/u.txt" "$(aionas_savings_dir)/store/out_$(sha12 "$HOME/u.txt").txt"
}

test_small_or_short_outputs_and_other_tools_are_untouched() {
  setup
  gen 70 >"$HOME/small.txt"     # under 2,000 tokens
  t_eq "" "$(post './build.sh' "$HOME/small.txt")"
  gen 80 200 >"$HOME/wide.txt"  # over 2,000 tokens but nothing between 40+40
  t_eq "" "$(post './build.sh' "$HOME/wide.txt")"
  gen 300 >"$HOME/o.txt"
  t_eq "" "$(post './build.sh' "$HOME/o.txt" Read)" "a file read must stay untouched"
  t_eq "" "$(post './build.sh' "$HOME/o.txt" Grep)"
  t_eq "" "$(printf '{"tool_name":"Bash","tool_input":{"command":"x"},"tool_response":{"stdout":"aGk=","stderr":"","interrupted":false,"isImage":true}}' | bash "$STORE")"
  t_eq "" "$(printf 'not json' | bash "$STORE")"
  t_rc 0 bash "$STORE" </dev/null
  t_eq "" "$(queue)"
}

test_a_failing_run_keeps_its_full_output_for_every_rule() {
  setup
  gen 300 >"$HOME/o.txt"
  local c
  # Claude Code reports a non-zero exit as PostToolUseFailure (an error, no
  # tool_response): neither hook ever changes it.
  for c in 'AIONAS_GUARD=pytest pytest -q' 'AIONAS_GUARD=npm_install npm install --no-audit --no-fund --no-progress' \
    'AIONAS_GUARD=git_log git log -n 30 --oneline' 'AIONAS_GUARD=cat_cap cat big.log' \
    'AIONAS_GUARD=grep_cap grep -rn x .' 'AIONAS_GUARD=sed_cap sed -n 1,900p f' './build.sh'; do
    t_eq "" "$(printf '{"session_id":"s1","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":%s},"tool_use_id":"t1","error":%s}' \
      "$(aionas_json_escape "$c")" "$(aionas_json_escape "Exit code 1
$(cat "$HOME/o.txt")")" | bash "$STORE")" "failure changed for [$c]"
  done
  # hooks.json has no PostToolUseFailure entry for these scripts.
  t_lacks "$(cat "$T_PLUGIN/hooks/hooks.json")" PostToolUseFailure
  t_eq "" "$(queue)"
}

test_guard_caps_sed_grep_cat_at_1500_tokens() {
  setup
  gen 100 >"$HOME/o.txt" # ~9,100 bytes: over the 6,000-byte cap
  local out v id kept c rule
  for c in 'cat_cap:cat big.log' 'grep_cap:grep -n line big.log' 'sed_cap:sed -n 1,100p big.log' 'cat_cap:AIONAS_GUARD=cat_cap cat big.log'; do
    rule=${c%%:*}; c=${c#*:}
    out=$(post "$c" "$HOME/o.txt")
    v=$(view "$out")
    id="out_$(sha12 "$HOME/o.txt")"
    kept=$(sed '$d' <<<"$v" | wc -l | tr -d ' ')
    t_eq "$(head -n "$kept" "$HOME/o.txt")" "$(sed '$d' <<<"$v")"
    t_ok test "$(sed '$d' <<<"$v" | wc -c | tr -d ' ')" -le 6000
    t_ok test "$kept" -ge 50
    t_eq "$out" "$(post "$c" "$HOME/o.txt")" "same output, different answer"
    t_eq "[aionas-guard: capped $rule at about 1500 tokens: kept $kept of 100 lines (about $(ftok "$HOME/o.txt") tokens), id=$id. More: aionas-recall $id [--grep PATTERN]. Full: rerun with AIONAS_FULL=1]" "$(tail -n 1 <<<"$v")"
  done
  t_ok same_bytes "$HOME/o.txt" "$(aionas_savings_dir)/store/$id.txt"
  t_eq "noisy_guard fired 8" "$(queue | sort | uniq -c | awk '{ print $2, $3, $1 }')"
  # Under the cap: untouched.
  gen 60 >"$HOME/s.txt"
  t_eq "" "$(post 'cat s' "$HOME/s.txt")"
  # sed -i is not a cap rule, and with noisy_guard off a cat is not capped:
  # both fall to the store (2,000 tokens).
  t_contains "$(view "$(post 'sed -i s/a/b/ f' "$HOME/o.txt")" | tail -n 1)" "[aionas-store: kept 40+40 of 100 lines (about "
  policy '{"methods":[{"method_id":"noisy_guard","state":"off","required":false,"self_override_allowed":true,"self_release_allowed":true}],"overrides":[]}'
  t_contains "$(view "$(post 'cat big.log' "$HOME/o.txt")" | tail -n 1)" "[aionas-store: kept 40+40 of 100 lines (about "
}

test_cap_marker_names_the_rule() {
  setup
  gen 100 >"$HOME/o.txt"
  t_contains "$(view "$(post 'grep -n line big.log' "$HOME/o.txt")" | tail -n 1)" "[aionas-guard: capped grep_cap at about 1500 tokens: kept "
}

test_bypass_passes_output_unchanged_and_counts_once() {
  setup
  gen 300 >"$HOME/o.txt"
  t_eq "" "$(post 'AIONAS_FULL=1 ./build.sh' "$HOME/o.txt")"
  t_eq "output_store bypass 1" "$(queue)"
  # A guard command: the guard counts it, the store does not count it again.
  : >"$(aionas_savings_dir)/counters/queue.tsv"
  t_eq "" "$(printf '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"AIONAS_FULL=1 git log"}}' | bash "$GUARD")"
  t_eq "" "$(post 'AIONAS_FULL=1 git log' "$HOME/o.txt")"
  t_eq "noisy_guard bypass 1" "$(queue)"
  # A cap rule: only the post-tool hook counts it.
  : >"$(aionas_savings_dir)/counters/queue.tsv"
  t_eq "" "$(printf '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"AIONAS_FULL=1 cat big.log"}}' | bash "$GUARD")"
  t_eq "" "$(post 'AIONAS_FULL=1 cat big.log' "$HOME/o.txt")"
  t_eq "noisy_guard bypass 1" "$(queue)"
  t_eq "" "$(ls "$(aionas_savings_dir)/store" 2>/dev/null)" "a bypass stored the output"
}

test_blocked_self_override_still_stores_and_points_to_a_request() {
  setup
  policy '{"methods":[{"method_id":"output_store","state":"on","required":false,"self_override_allowed":false,"self_release_allowed":true}],"overrides":[]}'
  gen 300 >"$HOME/o.txt"
  local out
  out=$(post 'AIONAS_FULL=1 ./build.sh' "$HOME/o.txt")
  t_contains "$(view "$out")" "[aionas-store: kept 40+40 of 300 lines"
  t_contains "$(aionas_json_flatten <<<"$out" | aionas_json_get hookSpecificOutput.additionalContext)" "/aionas-bypass output_store"
  t_eq "output_store fired 1" "$(queue)"
}

test_method_off_leaves_output_untouched() {
  setup
  policy '{"methods":[{"method_id":"output_store","state":"off","required":false,"self_override_allowed":true,"self_release_allowed":true}],"overrides":[]}'
  gen 300 >"$HOME/o.txt"
  t_eq "" "$(post './build.sh' "$HOME/o.txt")"
  t_eq "" "$(queue)"
}

test_below_the_probed_minimum_outputs_are_untouched_and_store_inactive() {
  gen 300 >"$HOME/o.txt"
  export AIONAS_CC_VERSION=2.1.298
  t_eq "" "$(post './build.sh' "$HOME/o.txt")"
  t_eq "output_store skipped 1" "$(queue)"
  t_contains "$(bash "$RECALL" --status)" "store inactive"
  t_eq "" "$(ls "$(aionas_savings_dir)/store" 2>/dev/null)"
  # Unknown version (no env, no transcript): inactive too.
  unset AIONAS_CC_VERSION
  t_eq "" "$(post './build.sh' "$HOME/o.txt")"
  t_contains "$(bash "$RECALL" --status)" "store inactive (Claude Code unknown"
  # The version from AI_AGENT, then from the transcript.
  export AI_AGENT=claude-code_2-1-300_harness
  t_contains "$(post './build.sh' "$HOME/o.txt")" "updatedToolOutput"
  t_contains "$(bash "$RECALL" --status)" "store active (Claude Code 2.1.300, minimum 2.1.299)"
  unset AI_AGENT
  printf '{"type":"user","version":"2.1.299","message":{}}\n' >"$HOME/none.jsonl"
  t_contains "$(post './build.sh' "$HOME/o.txt")" "updatedToolOutput"
}

test_recall_grep_lines_and_missing_ids() {
  setup
  printf '%s' "$(gen 300 | awk 'NR == 77 || NR == 222 { print "ERROR at " NR; next } { print }')" >"$HOME/o.txt"
  post './build.sh' "$HOME/o.txt" >/dev/null
  local id; id="out_$(sha12 "$HOME/o.txt")"
  t_eq "77:ERROR at 77
222:ERROR at 222" "$(bash "$RECALL" "$id" --grep ERROR)"
  t_eq "$(sed -n 2,3p "$HOME/o.txt" | awk '{ print NR + 1 ":" $0 }')" "$(bash "$RECALL" "$id" --lines 2-3)"
  t_eq "$(cat "$HOME/o.txt")" "$(bash "$RECALL" "$id")"
  t_rc 1 bash "$RECALL" "$id" --grep NOPE_NOT_THERE
  t_rc 1 bash "$RECALL" out_000000000000 2>/dev/null
  t_rc 2 bash "$RECALL" 'out_../../etc' 2>/dev/null
  t_rc 2 bash "$RECALL" 2>/dev/null
  # Reading a stored output back is never stored again.
  t_eq "" "$(post "aionas-recall $id" "$HOME/o.txt")"
}

test_old_outputs_follow_cleanup_period_days() {
  setup
  mkdir -p "$HOME/.claude"
  printf '{"cleanupPeriodDays": 5}\n' >"$HOME/.claude/settings.json"
  local d; d=$(aionas_savings_dir)/store
  mkdir -p "$d"
  : >"$d/out_aaaaaaaaaaaa.txt"; touch -t 202001010000 "$d/out_aaaaaaaaaaaa.txt"
  : >"$d/out_bbbbbbbbbbbb.txt"
  gen 300 >"$HOME/o.txt"
  post './build.sh' "$HOME/o.txt" >/dev/null
  t_not test -f "$d/out_aaaaaaaaaaaa.txt"
  t_ok test -f "$d/out_bbbbbbbbbbbb.txt"
  t_ok test -f "$d/out_$(sha12 "$HOME/o.txt").txt"
}

test_only_counts_reach_the_server() {
  setup
  t_enroll
  gen 300 | sed 's/line/SECRET-PROMPT-TEXT line/' >"$HOME/o.txt"
  post './deploy.sh --token=hunter2' "$HOME/o.txt" >/dev/null
  post 'cat secrets.env' "$HOME/o.txt" >/dev/null
  post 'AIONAS_FULL=1 ./run --password=hunter2' "$HOME/o.txt" >/dev/null
  printf '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"git log --grep=hunter2"}}' | bash "$GUARD" >/dev/null
  export AIONAS_CC_VERSION=1.0.0
  post './x' "$HOME/o.txt" >/dev/null
  t_rc 0 aionas_counters_flush --force
  local body all n
  body=$(t_call 1 body)
  t_eq "https://gw.example.test/enroll/v1/savings/counters" "$(t_call 1 url)"
  rest=$(printf '%s' "$body" | sed -E 's/\{"day":"[0-9]{4}-[0-9]{2}-[0-9]{2}","method_id":"(noisy_guard|output_store)","counter":"(fired|skipped|bypass)","value":[0-9]+\}//g')
  t_eq '{"plugin_version":"0.1.4","counters":[,,,]}' "$rest"
  all=$(cat "$FAKE_CURL_LOG"/*/* 2>/dev/null)
  for n in SECRET hunter2 deploy secrets.env build line; do t_lacks "$all" "$n" "content sent"; done
}

# shipped EVENT: the decoded command hooks/hooks.json registers for EVENT
# (PreToolUse: its Bash matcher), the way Claude Code runs the plugin.
shipped() {
  aionas_json_flatten "$T_PLUGIN/hooks/hooks.json" | awk -F '\t' -v ev="$1" '
    $1 ~ ("^hooks\\." ev "\\.[0-9]+\\.matcher$") { m[substr($1, 1, length($1) - 8)] = $3 }
    $1 ~ ("^hooks\\." ev "\\.[0-9]+\\.hooks\\.[0-9]+\\.command$") { c[++n] = $1; v[$1] = $3 }
    END { for (i = 1; i <= n; i++) { g = c[i]; sub(/\.hooks\.[0-9]+\.command$/, "", g)
          if (ev != "PreToolUse" || m[g] == "Bash") { print v[c[i]]; exit } } }' | aionas_json_unescape
}

test_shipped_hooks_json_reaches_the_real_guard_and_store() {
  setup
  export CLAUDE_PLUGIN_ROOT="$T_PLUGIN"
  local pre_cmd post_cmd out id
  pre_cmd=$(shipped PreToolUse); post_cmd=$(shipped PostToolUse)
  t_contains "$pre_cmd" '/hooks/' "no PreToolUse Bash command"
  t_contains "$post_cmd" '/hooks/' "no PostToolUse command"
  # The guard: git log becomes its quiet form.
  out=$(printf '{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git log"},"tool_use_id":"t1"}' | bash -c "$pre_cmd")
  t_eq "AIONAS_GUARD=git_log git log -n 30 --oneline" "$(aionas_json_flatten <<<"$out" | aionas_json_get hookSpecificOutput.updatedInput.command | aionas_json_unescape)"
  # The store: a long output becomes head + tail + the fixed marker.
  gen 300 >"$HOME/o.txt"
  id="out_$(sha12 "$HOME/o.txt")"
  out=$(printf '{"session_id":"s1","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"./build.sh"},"tool_response":{"stdout":%s,"stderr":"","interrupted":false,"isImage":false},"tool_use_id":"t1"}' \
    "$(aionas_json_escape "$(cat "$HOME/o.txt")")" | bash -c "$post_cmd")
  t_eq "$(store_marker 300 "$id" "$(ftok "$HOME/o.txt")")" "$(view "$out" | tail -n 1)"
}

t_main "$@"
