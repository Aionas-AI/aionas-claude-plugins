#!/usr/bin/env bash
# hooks/usage-probe.sh: the weekly figure from Claude Code's own /usage for a
# member who never renders the status line (AIO-892). Every test builds its own
# PATH (a stub claude, then /usr/bin:/bin) and its own HOME, so a real claude
# login is never run. The stub never calls a model.
. "$(dirname "$0")/../lib/harness.sh"

HOOK="$T_PLUGIN/hooks/usage-probe.sh"
FIX="$T_REPO/tests/fixtures/usage-probe"
UUID=66da5747-7dd0-408b-8696-cf496cfb72d1
ORGUUID=11111111-2222-3333-4444-555555555555
epoch_of() { awk -v mode=epoch -v iso="$1" -f "$T_PLUGIN/lib/time.awk"; }
NOW0=$(epoch_of 2026-11-01T00:00:00Z)

# up_setup: an enrolled computer with a Claude login file, a private PATH that
# holds only the stub claude (and tripwires for env, timeout and perl, which
# the probe must never run from PATH), a pinned clock and the real 2.1.311 capture.
up_setup() {
  t_enroll
  STUB=$(mktemp -d "$T_ROOT/stub.XXXXXX"); STUB_LOG=$(mktemp -d "$T_ROOT/stublog.XXXXXX")
  export STUB STUB_LOG
  export PATH="$STUB:/usr/bin:/bin"
  export AIONAS_NOW=$NOW0
  export STUB_OUTPUT="$FIX/usage-2.1.311-real-capture.json"
  unset STUB_MODE STUB_DELAY STUB_HOOK_LIST AIONAS_USAGE_PROBE AIONAS_USAGE_PROBE_TIMEOUT
  export TZ=UTC
  install_stub "$STUB/claude"
  local t
  for t in env timeout perl; do
    printf '#!/bin/bash\necho "$0" >>"%s/forbidden"\nexit 127\n' "$STUB_LOG" >"$STUB/$t"
    chmod +x "$STUB/$t"
  done
  claude_json invoice
}
install_stub() { mkdir -p "$(dirname "$1")"; cp "$FIX/stub-claude.sh" "$1"; chmod +x "$1"; }
claude_json() {
  cat >"$HOME/.claude.json" <<JSON
{"userID":"SECRET-USER-ID","oauthAccount":{"accountUuid":"$UUID","emailAddress":"CANARY-EMAIL@example.com","billingType":"$1","organizationType":"claude_team","organizationRateLimitTier":"default_claude_ai","organizationUuid":"$ORGUUID","organizationName":"Example Org"}}
JSON
}
hook() { printf '{"session_id":"s1","hook_event_name":"SessionStart","source":"startup"}' | bash "$HOOK"; }
runs() { find "$STUB_LOG" -mindepth 1 -maxdepth 1 -type d -name 'run.*' | wc -l | tr -d ' '; }
agent() { aionas_agent_dir; }
pdir() { echo "$(agent)/state/usage-probe"; }
stamp() { echo "$(aionas_savings_dir)/usage-probe.last"; }
counter() { cat "$(aionas_savings_dir)/counters/usage_probe_too_large" 2>/dev/null || echo 0; }
body() { t_call "$(t_calls)" body; }
body_file() { echo "$FAKE_CURL_LOG/$(t_calls)/body"; }
# usage_out RESULT_TEXT [LOCAL_COMMAND [IS_ERROR]]: the stub prints a /usage JSON
# whose result is RESULT_TEXT (already JSON-escaped, \n for a new line).
usage_out() {
  local f; f=$(mktemp "$T_ROOT/usage.XXXXXX")
  printf '{"type":"result","subtype":"success","is_error":%s,"result":"%s","local_command":"%s","total_cost_usd":0}\n' "${3:-false}" "$1" "${2:-usage}" >"$f"
  export STUB_OUTPUT=$f
}
# raw_of FILE: the JSON-escaped text of "result" in a /usage JSON file (sed only).
raw_of() { sed -En 's/.*"result":"(([^"\\]|\\.)*)".*/\1/p' "$1"; }
# same_text FIXTURE_JSON BODY_FILE: python decodes both JSON documents; the
# result and the usage_raw must be the same string, byte for byte (UTF-8).
# Skipped (returns 0) where python3 is missing.
same_text() {
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$1" "$2" <<'PY'
import json, sys
a = json.load(open(sys.argv[1], encoding="utf-8"))["result"].encode("utf-8")
b = json.load(open(sys.argv[2], encoding="utf-8"))["usage_raw"].encode("utf-8")
sys.exit(0 if a == b else 1)
PY
}
fresh_hour() { rm -f "$(stamp)"; }
# alive PID
alive() { kill -0 "$1" 2>/dev/null; }

test_second_session_within_4_hours_does_not_probe_again() {
  up_setup
  hook; hook
  t_eq 1 "$(runs)" "stub invocation count"
  t_eq 1 "$(t_calls)"
  export AIONAS_NOW=$((NOW0 + 14399)); hook
  t_eq 1 "$(runs)" "3 h 59 min 59 s later"
  export AIONAS_NOW=$((NOW0 + 14400)); hook
  t_eq 2 "$(runs)" "4 hours later it probes again"
  t_eq 2 "$(t_calls)"
}

test_the_stamp_is_written_before_the_probe_and_a_failed_send_waits_4_hours() {
  up_setup
  FAKE_CURL_STATUS=500 hook; t_eq 0 $? "exit 0 on a failed send"
  t_eq "$NOW0" "$(cat "$(stamp)")"
  hook
  t_eq 1 "$(runs)" "a failed send does not re-probe within 4 hours"
  t_eq 1 "$(t_calls)"
}

test_the_child_gets_the_variable_and_exactly_the_documented_command() {
  up_setup
  hook
  local d="$STUB_LOG/run.1"
  t_eq 1 "$(cat "$d/probe_env")" "AIONAS_USAGE_PROBE in the child"
  t_eq "-p
/usage
--no-session-persistence
--output-format
json" "$(cat "$d/argv")"
  t_lacks "$(cat "$d/argv")" "--bare"
  t_eq eof "$(cat "$d/stdin")" "the child's stdin is /dev/null"
  t_eq "$(cd "$(pdir)" && pwd -P)" "$(cd "$(cat "$d/cwd")" && pwd -P)" "cwd = the fixed private dir"
  t_eq "$STUB/claude" "$(cat "$d/argv0")"
}

test_the_state_dir_is_private_and_nothing_is_left_in_it() {
  up_setup
  mkdir -p "$(pdir)"; : >"$(pdir)/out.99999"
  hook
  t_eq 700 "$(t_mode "$(pdir)")"
  t_eq "" "$(find "$(pdir)" -mindepth 1)" "output files removed by name"
  t_not test -d "$(aionas_savings_dir)/locks/usage-probe.lock"
  t_eq "" "$(cat "$STUB_LOG/forbidden" 2>/dev/null)" "env, timeout and perl are never run from PATH"
}

test_a_symlinked_state_dir_is_refused() {
  up_setup
  mkdir -p "$(agent)/state" "$T_ROOT/elsewhere"
  ln -s "$T_ROOT/elsewhere" "$(pdir)"
  hook; t_eq 0 $? "exit 0"
  t_eq 0 "$(runs)"
  t_eq 0 "$(t_calls)"
}

test_every_hook_does_nothing_inside_the_probe_child() {
  up_setup
  export CLAUDE_PLUGIN_ROOT="$T_PLUGIN"
  local list="$T_ROOT/hooklist" s
  : >"$list"
  for s in $(aionas_json_flatten "$T_PLUGIN/hooks/hooks.json" | awk -F '\t' '$1 ~ /\.command$/ { print $3 }' | sed -n 's/.*hooks\/\([A-Za-z0-9._-]*\.sh\).*/\1/p'); do
    printf '%s\n' "$T_PLUGIN/hooks/$s" >>"$list"
  done
  t_ok grep -q 'plan-report.sh' "$list"
  t_ok grep -q 'usage-probe.sh' "$list"
  t_ok test "$(wc -l <"$list" | tr -d ' ')" -ge 14
  export STUB_HOOK_LIST=$list
  hook
  local d="$STUB_LOG/run.1"
  t_eq same "$(cat "$d/hooks_changed")" "no hook wrote a file inside the child"
  t_eq "$(wc -l <"$list" | tr -d ' ')" "$(grep -c '^0$' "$d/hook_rc")" "every hook exits 0"
  t_eq "" "$(cat "$d/hook_out" 2>/dev/null)" "no hook printed"
  t_eq 1 "$(runs)" "the probe hook itself did not start a second child"
  t_eq 1 "$(t_calls)" "only the probe's own sample, no request from a hook in the child"
}

test_the_same_hooks_do_work_without_the_variable() {
  up_setup
  export CLAUDE_PLUGIN_ROOT="$T_PLUGIN"
  local s
  for s in policy-sync plan-report script-refresh daily-scan effort-window unused-services write-minimum; do
    printf '{"session_id":"s1","hook_event_name":"SessionStart"}' | AIONAS_USAGE_PROBE=1 bash "$T_PLUGIN/hooks/$s.sh"
    t_eq 0 $? "$s exits 0 under the variable"
  done
  t_eq 0 "$(t_calls)" "the variable stops every request"
  for s in policy-sync plan-report; do
    printf '{"session_id":"s1","hook_event_name":"SessionStart"}' | bash "$T_PLUGIN/hooks/$s.sh"
  done
  t_ok test "$(t_calls)" -ge 1
}

test_aionas_sh_exits_the_sourcing_shell_on_the_variable() {
  up_setup
  local out
  out=$(AIONAS_USAGE_PROBE=1 bash -c '. "$1/lib/aionas.sh"; echo after' _ "$T_PLUGIN")
  t_eq "" "$out" "nothing runs after the source"
  out=$(AIONAS_USAGE_PROBE= bash -c '. "$1/lib/aionas.sh"; echo after' _ "$T_PLUGIN")
  t_eq after "$out" "an empty variable does not stop anything"
  t_eq 1 "$(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$T_PLUGIN/lib/aionas.sh" | grep -n 'AIONAS_USAGE_PROBE' | head -1 | cut -d: -f1)" "the guard is the first code line of aionas.sh"
}

# The POSTed body for the default account of up_setup, with the usage_raw text
# (JSON-escaped, as in the /usage output) and an optional claude_version.
want_body() {
  printf '{"tool":"claude_code","source":"usage_cmd","observed_at":"2026-11-01T00:00:00Z","account_uuid":"%s","organization_uuid":"%s","organization_name":"Example Org"%s,"windows":[{"kind":"weekly_all","window_minutes":10080}],"usage_raw":"%s"}' \
    "$UUID" "$ORGUUID" "${2:+,\"claude_version\":\"$2\"}" "$1"
}

test_real_2_1_311_capture_sends_the_whole_result_as_usage_raw() {
  up_setup
  local out rc
  out=$(hook 2>&1); rc=$?
  t_eq 0 "$rc" "exit 0"
  t_eq "" "$out" "the async hook prints nothing"
  t_eq 1 "$(runs)" "one probe"
  t_eq 1 "$(t_calls)" "one sample"
  t_eq POST "$(t_call 1 method)"
  t_eq "https://gw.example.test/cc-quota/v1/samples" "$(t_call 1 url)"
  t_contains "$(t_call 1 headers)" "Authorization: Bearer $T_ALIAS"
  t_lacks "$(t_call 1 args)" "$T_ALIAS" "the alias is never on a command line"
  local raw; raw=$(raw_of "$FIX/usage-2.1.311-real-capture.json")
  t_contains "$raw" "example-mcp" "the fixture text was read"
  t_eq "$(want_body "$raw")" "$(body)" "the exact body"
  same_text "$FIX/usage-2.1.311-real-capture.json" "$(body_file)" || t_fail "usage_raw differs from result"
  # the middle dot and the newlines, as the member's computer printed them
  t_contains "$(body)" 'Current week (all models): 47% used · resets Nov 3 at 5:59am (Asia/Jerusalem)\nCurrent week (Fable): 1% used'
  t_contains "$(body)" "Last 24h · 2255 requests · 7 sessions"
  t_contains "$(body)" "~/projects/example-repo"
}

test_the_body_carries_no_parsed_figure() {
  up_setup
  hook
  local b w; b=$(body)
  # outside the text itself nothing but the ids and the fixed fields
  local rest=${b%%\"usage_raw\":*}
  for w in utilization used_percent resets_at percent five_hour CANARY-EMAIL SECRET-USER-ID; do
    t_lacks "$b" "$w"
  done
  t_lacks "$rest" "Current" "the text appears only in usage_raw"
  t_lacks "$(cat "$FAKE_CURL_LOG"/*/args)" "Current week"
}

test_a_short_result_is_sent_whole_too() {
  up_setup
  export STUB_OUTPUT="$FIX/usage-2.1.311.json"
  hook
  t_eq 1 "$(t_calls)"
  t_eq "$(want_body "$(raw_of "$FIX/usage-2.1.311.json")")" "$(body)"
  same_text "$FIX/usage-2.1.311.json" "$(body_file)" || t_fail "usage_raw differs from result"
}

test_json_escapes_in_the_result_survive_byte_for_byte() {
  up_setup
  # a quote, a backslash, a slash, a tab, a unicode-escaped middle dot, an emoji written as a surrogate pair, a raw UTF-8 dot
  usage_out 'say \"hi\" \\ a\/b\tc · 😀 · end\n\nlast'
  hook
  t_eq 1 "$(t_calls)"
  t_eq "$(want_body 'say \"hi\" \\ a\/b\tc · 😀 · end\n\nlast')" "$(body)"
  same_text "$STUB_OUTPUT" "$(body_file)" || t_fail "usage_raw differs from result"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$(body_file)" || t_fail "the body is not valid JSON"
  fi
}

test_the_text_is_not_parsed_by_the_plugin() {
  up_setup
  # not the weekly line, a different language, no percent: all sent as they are
  usage_out 'Something new: 41% of the week\nCurrent session: 3% used · resets 8:00am (UTC)'
  hook
  t_eq 1 "$(t_calls)" "sent whole"
  t_eq "$(want_body 'Something new: 41% of the week\nCurrent session: 3% used · resets 8:00am (UTC)')" "$(body)"
  t_eq 0 "$(counter)"
}

test_only_a_successful_usage_local_command_is_sent() {
  up_setup
  local n=0
  check_nothing() {
    n=$((n + 1)); fresh_hour; hook
    t_eq "$n" "$(runs)" "$1"
    t_eq 0 "$(t_calls)" "$1"
    t_eq 0 "$(counter)" "$1: not a too-large result"
  }
  usage_out 'Current week (all models): 41% used' cost
  check_nothing "local_command is not usage"
  usage_out 'Current week (all models): 41% used' usage true
  check_nothing "is_error true"
  usage_out 'Current week (all models): 41% used' usage '"false"'
  check_nothing "is_error is the string false"
  usage_out 'Current week (all models): 41% used' usage null
  check_nothing "is_error null"
  printf '{"local_command":"usage","result":"Current week (all models): 41%% used"}' >"$T_ROOT/noerr"; export STUB_OUTPUT=$T_ROOT/noerr
  check_nothing "no is_error at all"
  printf '{"is_error":false,"result":"Current week (all models): 41%% used"}' >"$T_ROOT/nolc"; export STUB_OUTPUT=$T_ROOT/nolc
  check_nothing "no local_command"
  printf '{"is_error":false,"local_command":1,"result":"x"}' >"$T_ROOT/lcnum"; export STUB_OUTPUT=$T_ROOT/lcnum
  check_nothing "local_command is not a string"
  printf 'not json at all\n' >"$T_ROOT/notjson"; export STUB_OUTPUT=$T_ROOT/notjson
  check_nothing "not JSON"
  printf '{"is_error":false,"local_command":"usage","result":' >"$T_ROOT/trunc"; export STUB_OUTPUT=$T_ROOT/trunc
  check_nothing "truncated JSON"
  printf '{"is_error":false,"local_command":"usage","result":["Current week (all models): 41%% used"]}' >"$T_ROOT/arr"; export STUB_OUTPUT=$T_ROOT/arr
  check_nothing "result is not a string"
  printf '{"is_error":false,"local_command":"usage"}' >"$T_ROOT/nores"; export STUB_OUTPUT=$T_ROOT/nores
  check_nothing "no result"
  printf '{"nested":{"is_error":false,"local_command":"usage","result":"Current week (all models): 41%% used"}}' >"$T_ROOT/nest"; export STUB_OUTPUT=$T_ROOT/nest
  check_nothing "keys must be top level"
  usage_out ''
  check_nothing "an empty result has nothing to keep"
  printf '{"is_error":false,"local_command":"usage","result":"a\001b"}' >"$T_ROOT/ctl"; export STUB_OUTPUT=$T_ROOT/ctl
  check_nothing "a raw control character is not valid JSON text"
  usage_out 'Current week (all models): 41% used'
  export STUB_MODE=exit1
  check_nothing "the child failed"
  unset STUB_MODE
  # and the same output with success sends
  fresh_hour; hook
  t_eq 1 "$(t_calls)"
}

test_the_size_limit_is_32_kib_of_decoded_text() {
  up_setup
  local f
  # exactly 32768 bytes: sent
  usage_out "$(head -c 32768 /dev/zero | tr '\0' a)"
  hook
  t_eq 1 "$(t_calls)" "32768 bytes is sent"
  t_eq 0 "$(counter)"
  # one byte more: not sent, counted
  fresh_hour; usage_out "$(head -c 32769 /dev/zero | tr '\0' a)"
  hook
  t_eq 1 "$(t_calls)" "32769 bytes is not sent"
  t_eq 1 "$(counter)" "usage_probe_too_large"
  # 33 KiB
  fresh_hour; usage_out "$(head -c 33792 /dev/zero | tr '\0' a)"
  hook
  t_eq 1 "$(t_calls)" "33 KiB is not sent"
  t_eq 2 "$(counter)"
  # escapes count as the text they stand for: 20000 "\n" is 20000 bytes, sent
  fresh_hour; usage_out "$(awk 'BEGIN { for (i = 0; i < 20000; i++) printf "\\n" }')"
  hook
  t_eq 2 "$(t_calls)" "20000 newlines written as escapes are 20000 bytes"
  t_eq 2 "$(counter)"
  # a middle dot is two bytes: 16400 of them are 32800 bytes
  fresh_hour; usage_out "$(awk 'BEGIN { for (i = 0; i < 16400; i++) printf "·" }')"
  hook
  t_eq 2 "$(t_calls)" "multi-byte text is measured in bytes"
  t_eq 3 "$(counter)"
  # never through the gateway's counter list
  t_not test -f "$(aionas_savings_dir)/counters/queue.tsv"
  t_lacks "$(cat "$T_PLUGIN/lib/catalog.sh")" usage_probe "catalog.sh stays closed"
}

test_there_is_no_unparsed_counter_and_no_parser_left() {
  up_setup
  usage_out 'nope' usage true
  hook
  hook
  t_not test -e "$(aionas_savings_dir)/counters/usage_probe_unparsed"
  t_not test -e "$T_PLUGIN/lib/usage-probe.awk"
  t_not grep -rn -e unparsed -e usage-probe.awk -e time.awk -e zoneinfo -e aionas_up_resets -e aionas_up_pct_ok "$T_PLUGIN/lib/usage-probe.sh" "$T_PLUGIN/hooks/usage-probe.sh"
}

test_claude_version_is_sent_only_when_the_path_already_names_it() {
  up_setup
  # claude on PATH: nothing names the version, no extra run to ask
  hook
  t_lacks "$(body)" claude_version
  t_eq 1 "$(runs)" "no --version run"
  # the Desktop bundle: the version folder
  rm -f "$STUB/claude"; as_mac
  install_stub "$(desktop 2.1.308 a93ded4b1b47)"
  fresh_hour; hook
  t_eq 2 "$(runs)" "still one run per probe"
  t_eq "$(want_body "$(raw_of "$FIX/usage-2.1.311-real-capture.json")" 2.1.308)" "$(body)"
  # the VS Code extension: the folder name

  rm -f "$(desktop 2.1.308 a93ded4b1b47)"
  install_stub "$(vscode 2.1.100-darwin-arm64)"
  fresh_hour; hook
  t_contains "$(body)" '"claude_version":"2.1.100",'
  t_lacks "$(body)" "darwin"
  t_eq "" "$(cat "$STUB_LOG/forbidden" 2>/dev/null)"
}

test_no_new_tool_runs_from_path() {
  up_setup
  hook
  t_eq 1 "$(t_calls)"
  t_eq "" "$(cat "$STUB_LOG/forbidden" 2>/dev/null)"
}
test_a_fresh_status_line_figure_means_no_probe() {
  up_setup
  local tap="$(agent)/state/plan-usage/claude.last"
  mkdir -p "$(dirname "$tap")"
  printf '41|%s|%s' $((NOW0 + 86400)) $((NOW0 - 100)) >"$tap"
  hook
  t_eq 0 "$(runs)" "figure 100 s old"
  printf '41|%s|%s' $((NOW0 + 86400)) $((NOW0 - 14399)) >"$tap"
  hook; t_eq 0 "$(runs)" "figure 14399 s old"
  printf '41|%s|%s' $((NOW0 + 86400)) $((NOW0 - 14400)) >"$tap"
  hook; t_eq 1 "$(runs)" "figure exactly 4 hours old"
}

test_the_four_hour_boundary_for_the_stamp_and_for_the_tap() {
  up_setup
  hook; t_eq 1 "$(runs)" "first start probes"
  export AIONAS_NOW=$((NOW0 + 3 * 3600 + 59 * 60)); hook
  t_eq 1 "$(runs)" "last probe 3 h 59 min ago: no probe"
  export AIONAS_NOW=$((NOW0 + 4 * 3600 + 60)); hook
  t_eq 2 "$(runs)" "last probe 4 h 01 min ago: probe"
  local tap="$(agent)/state/plan-usage/claude.last"
  mkdir -p "$(dirname "$tap")"
  fresh_hour; export AIONAS_NOW=$NOW0
  printf '41|%s|%s' $((NOW0 + 86400)) $((NOW0 - (3 * 3600 + 59 * 60))) >"$tap"
  local before; before=$(runs)
  hook; t_eq "$before" "$(runs)" "tap figure 3 h 59 min old: no probe"
}

test_a_stale_or_unreadable_status_line_figure_does_not_stop_the_probe() {
  up_setup
  local tap="$(agent)/state/plan-usage/claude.last" i=0 c
  mkdir -p "$(dirname "$tap")"
  for c in "41|1|$((NOW0 - 90000))" "41|1|$((NOW0 + 500))" "41|1|abc" "41|1|" "41|1" "" "garbage" "41|1|-5" "41|1|99999999999999999999"; do
    i=$((i + 1)); fresh_hour
    printf '%s' "$c" >"$tap"
    hook
    t_eq "$i" "$(runs)" "tap content [$c]"
  done
  rm -f "$tap"; fresh_hour; hook
  t_eq $((i + 1)) "$(runs)" "no tap file"
}

test_no_binary_means_no_request_and_no_stamp() {
  up_setup
  rm -f "$STUB/claude"
  hook; t_eq 0 $? "exit 0"
  t_eq 0 "$(t_calls)"
  t_not test -f "$(stamp)"
  t_not test -d "$(aionas_savings_dir)/locks/usage-probe.lock"
}

test_a_directory_or_non_executable_named_claude_is_not_a_binary() {
  up_setup
  rm -f "$STUB/claude"
  mkdir "$STUB/claude"
  hook; t_eq 0 "$(runs)"; t_eq 0 "$(t_calls)"
  rmdir "$STUB/claude"
  install_stub "$STUB/claude"; chmod -x "$STUB/claude"
  hook; t_eq 0 "$(runs)"; t_eq 0 "$(t_calls)"
}

test_path_claude_wins_over_the_bundled_ones() {
  up_setup
  export AIONAS_UNAME=$STUB/uname; printf '#!/bin/bash\necho Darwin\n' >"$AIONAS_UNAME"; chmod +x "$AIONAS_UNAME"
  install_stub "$HOME/Library/Application Support/Claude/claude-code/2.1.308/a93ded4b1b47/claude.app/Contents/MacOS/claude"
  install_stub "$HOME/.vscode/extensions/anthropic.claude-code-2.1.400-darwin-arm64/resources/native-binary/claude"
  hook
  t_eq "$STUB/claude" "$(cat "$STUB_LOG/run.1/argv0")"
}

desktop() { echo "$HOME/Library/Application Support/Claude/claude-code/$1/$2/claude.app/Contents/MacOS/claude"; }
vscode() { echo "$HOME/.vscode/extensions/anthropic.claude-code-$1/resources/native-binary/claude"; }
as_mac() { export AIONAS_UNAME=$STUB/uname; printf '#!/bin/bash\necho Darwin\n' >"$AIONAS_UNAME"; chmod +x "$AIONAS_UNAME"; }
as_linux() { export AIONAS_UNAME=$STUB/uname; printf '#!/bin/bash\necho Linux\n' >"$AIONAS_UNAME"; chmod +x "$AIONAS_UNAME"; }

test_desktop_bundle_is_found_in_its_real_layout_with_a_space_in_the_path() {
  up_setup; rm -f "$STUB/claude"; as_mac
  install_stub "$(desktop 2.1.308 a93ded4b1b47)"
  hook
  t_eq 1 "$(runs)"
  t_eq "$(desktop 2.1.308 a93ded4b1b47)" "$(cat "$STUB_LOG/run.1/argv0")"
  t_eq 1 "$(t_calls)"
}

test_desktop_newest_version_is_by_version_number_not_by_text_or_mtime() {
  up_setup; rm -f "$STUB/claude"; as_mac
  install_stub "$(desktop 2.1.99 aaaaaaaaaaaa)"
  install_stub "$(desktop 2.1.100 bbbbbbbbbbbb)"
  install_stub "$(desktop 2.0.200 cccccccccccc)"
  install_stub "$(desktop 1.9.999 dddddddddddd)"
  touch -t 203001010000 "$(dirname "$(desktop 2.1.99 aaaaaaaaaaaa)")" "$(desktop 2.1.99 aaaaaaaaaaaa)"
  touch -t 200001010000 "$(desktop 2.1.100 bbbbbbbbbbbb)"
  hook
  t_eq "$(desktop 2.1.100 bbbbbbbbbbbb)" "$(cat "$STUB_LOG/run.1/argv0")"
}

test_desktop_skips_odd_names_and_versions_with_no_executable() {
  up_setup; rm -f "$STUB/claude"; as_mac
  install_stub "$(desktop 2.1.308 a93ded4b1b47)"
  install_stub "$(desktop 2.1.309-beta eeeeeeeeeeee)"
  install_stub "$HOME/Library/Application Support/Claude/claude-code/latest/ffffffffffff/claude.app/Contents/MacOS/claude"
  mkdir -p "$HOME/Library/Application Support/Claude/claude-code/2.1.400/111111111111/claude.app/Contents/MacOS"
  install_stub "$(desktop 2.1.350 222222222222)"; chmod -x "$(desktop 2.1.350 222222222222)"
  hook
  t_eq "$(desktop 2.1.308 a93ded4b1b47)" "$(cat "$STUB_LOG/run.1/argv0")"
}

test_desktop_rejects_a_symlinked_version_dir_or_binary_component() {
  up_setup; rm -f "$STUB/claude"; as_mac
  local base="$HOME/Library/Application Support/Claude/claude-code"
  install_stub "$(desktop 2.1.308 a93ded4b1b47)"
  # a newer version dir that is a symlink to a real tree holding a binary
  install_stub "$T_ROOT/elsewhere/2.1.999/bbbbbbbbbbbb/claude.app/Contents/MacOS/claude"
  ln -s "$T_ROOT/elsewhere/2.1.999" "$base/2.1.400"
  # a newer one whose hex dir is a symlink
  mkdir -p "$base/2.1.500"
  install_stub "$T_ROOT/elsewhere2/cccccccccccc/claude.app/Contents/MacOS/claude"
  ln -s "$T_ROOT/elsewhere2/cccccccccccc" "$base/2.1.500/cccccccccccc"
  # a newer one whose claude.app is a symlink
  install_stub "$T_ROOT/elsewhere3/claude.app/Contents/MacOS/claude"
  mkdir -p "$base/2.1.600/dddddddddddd"
  ln -s "$T_ROOT/elsewhere3/claude.app" "$base/2.1.600/dddddddddddd/claude.app"
  # a newer one whose binary itself is a symlink
  mkdir -p "$base/2.1.700/eeeeeeeeeeee/claude.app/Contents/MacOS"
  ln -s "$STUB/uname" "$base/2.1.700/eeeeeeeeeeee/claude.app/Contents/MacOS/claude"
  hook
  t_eq 1 "$(runs)"
  t_eq "$(desktop 2.1.308 a93ded4b1b47)" "$(cat "$STUB_LOG/run.1/argv0")" "only the real tree counts"
}

test_desktop_prefers_a_version_dir_with_a_verified_file() {
  up_setup; rm -f "$STUB/claude"; as_mac
  install_stub "$(desktop 2.1.100 aaaaaaaaaaaa)"
  install_stub "$(desktop 2.1.308 a93ded4b1b47)"
  : >"$(dirname "$(desktop 2.1.100 aaaaaaaaaaaa)")/../../../.verified"
  hook
  t_eq "$(desktop 2.1.100 aaaaaaaaaaaa)" "$(cat "$STUB_LOG/run.1/argv0")" "older but verified beats newer unverified"
  # two verified: the newest of them
  fresh_hour
  : >"$(dirname "$(desktop 2.1.308 a93ded4b1b47)")/../../../.verified"
  hook
  t_eq "$(desktop 2.1.308 a93ded4b1b47)" "$(cat "$STUB_LOG/run.2/argv0")"
  # none verified: the newest
  fresh_hour
  rm -f "$(dirname "$(desktop 2.1.100 aaaaaaaaaaaa)")/../../../.verified" "$(dirname "$(desktop 2.1.308 a93ded4b1b47)")/../../../.verified"
  hook
  t_eq "$(desktop 2.1.308 a93ded4b1b47)" "$(cat "$STUB_LOG/run.3/argv0")"
}

test_desktop_is_looked_up_on_macos_only() {
  up_setup; rm -f "$STUB/claude"; as_linux
  install_stub "$(desktop 2.1.308 a93ded4b1b47)"
  hook
  t_eq 0 "$(runs)"
}

test_vscode_extension_is_the_last_fallback_and_also_picked_by_version() {
  up_setup; rm -f "$STUB/claude"; as_mac
  install_stub "$(vscode 2.1.99-darwin-arm64)"
  install_stub "$(vscode 2.1.100-darwin-arm64)"
  install_stub "$HOME/.vscode/extensions/other.ext-9.9.9/resources/native-binary/claude"
  touch -t 203001010000 "$(vscode 2.1.99-darwin-arm64)"
  hook
  t_eq "$(vscode 2.1.100-darwin-arm64)" "$(cat "$STUB_LOG/run.1/argv0")"
  # with a Desktop bundle too, Desktop comes first
  fresh_hour
  install_stub "$(desktop 2.1.308 a93ded4b1b47)"
  hook
  t_eq "$(desktop 2.1.308 a93ded4b1b47)" "$(cat "$STUB_LOG/run.2/argv0")"
}

test_vscode_extension_on_linux() {
  up_setup; rm -f "$STUB/claude"; as_linux
  install_stub "$(vscode 2.1.100-linux-x64)"
  hook
  t_eq "$(vscode 2.1.100-linux-x64)" "$(cat "$STUB_LOG/run.1/argv0")"
}

test_not_enrolled_means_nothing_at_all() {
  up_setup; t_unenroll
  hook; t_eq 0 $? "exit 0"
  t_eq 0 "$(runs)"; t_eq 0 "$(t_calls)"
  t_not test -e "$(pdir)"
  t_not test -f "$(stamp)"
}

test_an_alias_without_a_gateway_means_nothing() {
  up_setup; rm -f "$(agent)/enrollment.json"
  hook; t_eq 0 $? "exit 0"
  t_eq 0 "$(runs)"; t_eq 0 "$(t_calls)"
}

test_an_api_key_login_is_not_probed() {
  up_setup
  claude_json api
  hook; t_eq 0 "$(runs)"; t_eq 0 "$(counter)"
  claude_json none
  hook; t_eq 0 "$(runs)"
  claude_json invoice
  hook; t_eq 1 "$(runs)"
}

test_without_an_account_in_the_login_file_nothing_is_started() {
  up_setup
  rm -f "$HOME/.claude.json"
  hook; t_eq 0 $? "exit 0"
  t_eq 0 "$(runs)" "no login file: no child"
  t_eq 0 "$(t_calls)"
  t_not test -f "$(stamp)"
  # a login file with no oauthAccount (API key or gateway-routed member)
  printf '{"userID":"SECRET-USER-ID","numStartups":3}' >"$HOME/.claude.json"
  hook; t_eq 0 "$(runs)" "no oauthAccount: no child"
  # an oauthAccount without accountUuid
  printf '{"oauthAccount":{"billingType":"invoice","organizationUuid":"%s"}}' "$ORGUUID" >"$HOME/.claude.json"
  hook; t_eq 0 "$(runs)" "no accountUuid: no child"
  printf '{"oauthAccount":{"accountUuid":"","billingType":"invoice"}}' >"$HOME/.claude.json"
  hook; t_eq 0 "$(runs)" "empty accountUuid: no child"
  t_eq 0 "$(t_calls)"
  t_eq 0 "$(counter)" "not a failed read"
  claude_json invoice
  hook; t_eq 1 "$(runs)" "with an account it probes"
}

test_account_and_organization_are_taken_like_the_plan_report() {
  up_setup
  mkdir -p "$T_ROOT/cfg"
  export CLAUDE_CONFIG_DIR=$T_ROOT/cfg
  cat >"$T_ROOT/cfg/.claude.json" <<JSON
{"oauthAccount":{"accountUuid":"not a uuid!","billingType":"invoice","organizationUuid":"$ORGUUID","organizationName":"  Evil\\u202eName\\n  "}}
JSON
  hook
  t_lacks "$(body)" account_uuid "a malformed id is dropped"
  t_contains "$(body)" "\"organization_uuid\":\"$ORGUUID\""
  t_contains "$(body)" '"organization_name":"EvilName"'
}

test_a_hung_child_is_stopped_and_nothing_is_sent() {
  up_setup
  export STUB_MODE=hang-ignore-term AIONAS_USAGE_PROBE_TIMEOUT=1
  local t0 t1
  t0=$(date +%s)
  out=$(hook 2>&1); t_eq 0 $? "exit 0"
  t1=$(date +%s)
  t_eq "" "$out" "no shell job message"
  t_ok test $((t1 - t0)) -le 8
  t_eq 1 "$(runs)"
  ! alive "$(cat "$STUB_LOG/run.1/pid")" || t_fail "a child that ignores TERM survived"
  t_eq 0 "$(t_calls)" "never parse partial output"
  t_eq 0 "$(counter)" "a timeout is not a too-large result"
  t_eq "" "$(find "$(pdir)" -mindepth 1)"
  t_not test -d "$(aionas_savings_dir)/locks/usage-probe.lock"
  t_eq "$NOW0" "$(cat "$(stamp)")" "a hung start is not retried before the 4 hours are over"
}

test_a_timeout_kills_the_whole_process_group() {
  up_setup
  export STUB_MODE=grandchild AIONAS_USAGE_PROBE_TIMEOUT=1
  hook; t_eq 0 $? "exit 0"
  local gp; gp=$(cat "$STUB_LOG/run.1/gpid")
  if alive "$gp"; then kill -KILL "$gp" 2>/dev/null; t_fail "the grandchild survived the timeout"; fi
  ! alive "$(cat "$STUB_LOG/run.1/pid")" || t_fail "the child survived"
  t_eq 0 "$(t_calls)"
}

test_output_over_the_cap_stops_the_child_and_sends_nothing() {
  up_setup
  export STUB_MODE=flood AIONAS_USAGE_PROBE_TIMEOUT=5
  local t0 t1
  t0=$(date +%s)
  hook; t_eq 0 $? "exit 0"
  t1=$(date +%s)
  local w; w=$(cat "$STUB_LOG/run.1/written")
  [ "$w" -lt 1048576 ] 2>/dev/null || t_fail "the child wrote [$w] bytes before it was stopped"
  t_ok test $((t1 - t0)) -le 4
  t_eq 0 "$(t_calls)" "nothing is sent"
  t_eq 1 "$(counter)" "counted as too large"
  ! alive "$(cat "$STUB_LOG/run.1/pid")" || t_fail "the child survived"
  t_eq "" "$(find "$(pdir)" -mindepth 1)"
  t_not test -d "$(aionas_savings_dir)/locks/usage-probe.lock"
}

test_a_slow_child_within_the_timeout_still_counts() {
  up_setup
  export STUB_DELAY=2
  hook
  t_eq 1 "$(t_calls)"
}

test_a_term_sent_to_the_hook_takes_the_child_down() {
  up_setup
  export STUB_MODE=hang
  printf '{"session_id":"s1"}' | bash "$HOOK" &
  local hp=$! i=0
  while [ ! -f "$STUB_LOG/run.1/pid" ] && [ $i -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
  t_ok test -f "$STUB_LOG/run.1/pid"
  local cp; cp=$(cat "$STUB_LOG/run.1/pid")
  alive "$cp" || t_fail "child not running"
  kill -TERM "$hp"
  wait "$hp" 2>/dev/null
  i=0; while alive "$cp" && [ $i -lt 20 ]; do sleep 0.2; i=$((i + 1)); done
  ! alive "$cp" || t_fail "the child outlived its hook"
  t_not test -d "$(aionas_savings_dir)/locks/usage-probe.lock"
  t_eq 0 "$(t_calls)"
  t_eq "" "$(find "$(pdir)" -mindepth 1)"
}

test_five_parallel_starts_make_one_probe() {
  up_setup
  export STUB_DELAY=1
  local i
  for i in 1 2 3 4 5; do hook & done
  wait
  t_eq 1 "$(runs)" "one stub invocation"
  t_eq 1 "$(t_calls)" "one sample"
}

test_a_lock_left_by_a_dead_start_is_broken_after_its_time() {
  up_setup
  mkdir -p "$(aionas_savings_dir)/locks/usage-probe.lock"
  echo $((NOW0 - 10)) >"$(aionas_savings_dir)/locks/usage-probe.lock/t"
  hook; t_eq 0 "$(runs)" "a start in progress is respected"
  echo $((NOW0 - 500)) >"$(aionas_savings_dir)/locks/usage-probe.lock/t"
  hook; t_eq 1 "$(runs)" "a lock older than 120 s is broken"
}

test_exit_zero_and_silence_even_when_the_gateway_is_down() {
  up_setup
  FAKE_CURL_EXIT=28 hook; t_eq 0 $? "exit 0"
  out=$(AIONAS_NOW=$((NOW0 + 7200)) FAKE_CURL_STATUS=503 hook 2>&1); t_eq 0 $? "exit 0"
  t_eq "" "$out"
}

test_session_hook_entry_is_async_with_room_for_the_probe() {
  local flat; flat=$(aionas_json_flatten "$T_PLUGIN/hooks/hooks.json")
  local p
  p=$(printf '%s\n' "$flat" | awk -F '\t' '$1 ~ /\.command$/ && $3 ~ /usage-probe\.sh/ { sub(/\.command$/, "", $1); print $1 }')
  [ -n "$p" ] || t_fail "usage-probe.sh is not in hooks.json"
  case "$p" in hooks.SessionStart.*) ;; *) t_fail "not a SessionStart entry: $p" ;; esac
  t_eq true "$(printf '%s\n' "$flat" | aionas_json_get "$p.async")"
  # 20 s probe + 1 s kill grace + 5 s send: a timeout below that orphans the child
  t_ok test "$(printf '%s\n' "$flat" | aionas_json_get "$p.timeout")" -ge 40
}

test_the_api_key_mode_flag_is_never_in_the_code() {
  t_not grep -rn -e '--bare' "$T_PLUGIN/hooks/usage-probe.sh" "$T_PLUGIN/lib/usage-probe.sh"
}

t_main "$@"
