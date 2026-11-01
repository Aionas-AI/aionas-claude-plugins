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
# the probe must never run from PATH), a pinned clock and the 41% fixture.
up_setup() {
  t_enroll
  STUB=$(mktemp -d "$T_ROOT/stub.XXXXXX"); STUB_LOG=$(mktemp -d "$T_ROOT/stublog.XXXXXX")
  export STUB STUB_LOG
  export PATH="$STUB:/usr/bin:/bin"
  export AIONAS_NOW=$NOW0
  export STUB_OUTPUT="$FIX/usage-2.1.311.json"
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
counter() { cat "$(aionas_savings_dir)/counters/usage_probe_unparsed" 2>/dev/null || echo 0; }
body() { t_call "$(t_calls)" body; }
resets_sent() { body | sed -n 's/.*"resets_at":"\([^"]*\)".*/\1/p'; }
# usage_out RESULT_TEXT [LOCAL_COMMAND]: the stub prints a /usage JSON whose
# result is RESULT_TEXT (already JSON-escaped, \n for a new line).
usage_out() {
  local f; f=$(mktemp "$T_ROOT/usage.XXXXXX")
  printf '{"type":"result","subtype":"success","is_error":false,"result":"%s","local_command":"%s","total_cost_usd":0}\n' "$1" "${2:-usage}" >"$f"
  export STUB_OUTPUT=$f
}
fresh_hour() { rm -f "$(stamp)"; }
# alive PID
alive() { kill -0 "$1" 2>/dev/null; }

test_fixture_41_sends_exactly_one_usage_cmd_sample() {
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
  t_eq "{\"tool\":\"claude_code\",\"source\":\"usage_cmd\",\"observed_at\":\"2026-11-01T00:00:00Z\",\"account_uuid\":\"$UUID\",\"organization_uuid\":\"$ORGUUID\",\"organization_name\":\"Example Org\",\"windows\":[{\"kind\":\"weekly_all\",\"window_minutes\":10080,\"used_percent\":41,\"resets_at\":\"2026-11-03T03:59:00Z\"}]}" "$(body)"
}

test_nothing_but_the_numbers_leaves_the_computer() {
  up_setup
  hook
  local b; b=$(body)
  local w
  for w in "Current" "result" "resets " "Jerusalem" "Asia" "used ·" "utilization" "five_hour" "session" "Fable" "CANARY-EMAIL" "SECRET-USER-ID"; do
    t_lacks "$b" "$w"
  done
  t_lacks "$(cat "$FAKE_CURL_LOG"/*/args)" "Current week"
}

test_second_session_within_the_hour_does_not_probe_again() {
  up_setup
  hook; hook
  t_eq 1 "$(runs)" "stub invocation count"
  t_eq 1 "$(t_calls)"
  export AIONAS_NOW=$((NOW0 + 3599)); hook
  t_eq 1 "$(runs)" "59 min 59 s later"
  export AIONAS_NOW=$((NOW0 + 3600)); hook
  t_eq 2 "$(runs)" "an hour later it probes again"
  t_eq 2 "$(t_calls)"
}

test_the_stamp_is_written_before_the_probe_and_a_failed_send_waits_the_hour() {
  up_setup
  FAKE_CURL_STATUS=500 hook; t_eq 0 $? "exit 0 on a failed send"
  t_eq "$NOW0" "$(cat "$(stamp)")"
  hook
  t_eq 1 "$(runs)" "a failed send does not re-probe within the hour"
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

test_unrecognized_text_sends_nothing_and_counts() {
  up_setup
  usage_out 'Something new: 41% of the week'
  hook
  t_eq 1 "$(runs)"
  t_eq 0 "$(t_calls)" "no sample"
  t_eq 1 "$(counter)" "usage_probe_unparsed"
  t_not test -f "$(aionas_savings_dir)/counters/queue.tsv"
  export AIONAS_NOW=$((NOW0 + 3600)); hook
  t_eq 2 "$(counter)"
  t_eq 0 "$(t_calls)"
}

test_the_gateway_counter_list_is_never_touched() {
  up_setup
  usage_out 'nope'
  hook
  t_eq 0 "$(t_calls)"
  t_lacks "$(cat "$T_PLUGIN/lib/catalog.sh")" usage_probe_unparsed "catalog.sh stays closed: the gateway rejects a batch with an unknown counter"
  t_not test -f "$(aionas_savings_dir)/counters/queue.tsv"
}

test_only_a_usage_local_command_with_the_all_models_line_is_a_sample() {
  up_setup
  local n=0
  check_unparsed() {
    n=$((n + 1)); fresh_hour; hook
    t_eq "$n" "$(counter)" "$1"
    t_eq 0 "$(t_calls)" "$1"
  }
  usage_out 'Current week (all models): 41% used · resets Nov 3 at 5:59am (Asia/Jerusalem)' cost
  check_unparsed "local_command is not usage"
  usage_out 'Current week (Fable): 1% used · resets Nov 3 at 5:59am (Asia/Jerusalem)'
  check_unparsed "only a model line"
  usage_out 'Current session: 3% used · resets 8:00am (Asia/Jerusalem)'
  check_unparsed "only the session line"
  usage_out 'Current week (all models): 101% used · resets Nov 3 at 5:59am (Asia/Jerusalem)'
  check_unparsed "over 100"
  usage_out 'Current week (all models): -3% used'
  check_unparsed "negative"
  usage_out 'Current week (all models): 4a% used'
  check_unparsed "not a number"
  usage_out 'Current week (all models): 41 used'
  check_unparsed "no percent sign"
  usage_out 'Current week (all models):41% used'
  check_unparsed "no space"
  usage_out 'prefix Current week (all models): 41% used'
  check_unparsed "line does not start with the label"
  usage_out 'Current week (all models): 1234% used'
  check_unparsed "four digits"
  printf 'not json at all\n' >"$T_ROOT/notjson"; export STUB_OUTPUT=$T_ROOT/notjson
  check_unparsed "not JSON"
  printf '{"local_command":"usage","result":' >"$T_ROOT/trunc"; export STUB_OUTPUT=$T_ROOT/trunc
  check_unparsed "truncated JSON"
  printf '{"local_command":"usage","result":["Current week (all models): 41%% used"]}' >"$T_ROOT/arr"; export STUB_OUTPUT=$T_ROOT/arr
  check_unparsed "result is not a string"
  printf '{"nested":{"local_command":"usage","result":"Current week (all models): 41%% used"}}' >"$T_ROOT/nest"; export STUB_OUTPUT=$T_ROOT/nest
  check_unparsed "keys must be top level"
  usage_out 'Current week (all models): 41% used'
  export STUB_MODE=exit1
  check_unparsed "the child failed"
  unset STUB_MODE
  head -c 200000 /dev/zero | tr '\0' 'x' >"$T_ROOT/big"; export STUB_OUTPUT=$T_ROOT/big
  check_unparsed "output over the size cap"
}

test_the_fable_line_never_stands_in_for_the_all_models_line() {
  up_setup
  usage_out 'Current week (Fable): 7% used · resets Nov 3 at 5:59am (Asia/Jerusalem)\nCurrent week (all models): 41% used · resets Nov 3 at 5:59am (Asia/Jerusalem)'
  hook
  t_eq 1 "$(t_calls)"
  t_contains "$(body)" '"used_percent":41,'
  t_lacks "$(body)" '"used_percent":7'
}

test_percent_forms() {
  up_setup
  usage_out 'Current week (all models): 41.5% used · resets Nov 3 at 5:59am (Asia/Jerusalem)'
  hook; t_contains "$(body)" '"used_percent":41.5,'
  fresh_hour; usage_out 'Current week (all models): 0% used'
  hook; t_contains "$(body)" '"used_percent":0}'
  fresh_hour; usage_out 'Current week (all models): 100% used'
  hook; t_contains "$(body)" '"used_percent":100}'
  fresh_hour; usage_out 'Current week (all models): 007% used'
  hook; t_contains "$(body)" '"used_percent":7}'
  t_eq 4 "$(t_calls)"
  t_lacks "$(body)" "resets_at" "no reset text: a sample without resets_at"
}

test_the_middle_dot_may_be_written_as_a_unicode_escape() {
  up_setup
  usage_out 'Current week (all models): 41% used · resets Nov 3 at 5:59am (Asia/Jerusalem)'
  hook
  t_contains "$(body)" '"used_percent":41,"resets_at":"2026-11-03T03:59:00Z"'
}

# resets_case NOW_ISO RESET_TEXT WANT ("" = a sample without resets_at)
resets_case() {
  fresh_hour
  export AIONAS_NOW; AIONAS_NOW=$(epoch_of "$1")
  usage_out "Current week (all models): 41% used · resets $2"
  local before; before=$(t_calls)
  hook
  t_eq $((before + 1)) "$(t_calls)" "a sample is always sent: $2"
  t_contains "$(body)" '"used_percent":41' "$2"
  t_eq "$3" "$(resets_sent)" "$2 at $1"
}

test_resets_at_is_the_local_wall_time_in_the_named_zone() {
  up_setup
  resets_case 2026-11-01T00:00:00Z 'Nov 3 at 5:59am (Asia/Jerusalem)' 2026-11-03T03:59:00Z
  resets_case 2026-11-01T00:00:00Z 'Nov 3 at 12:00am (America/New_York)' 2026-11-03T05:00:00Z
  resets_case 2026-11-01T00:00:00Z 'Nov 2 at 12:30pm (America/New_York)' 2026-11-02T17:30:00Z
  resets_case 2026-11-01T00:00:00Z 'Nov 3 at 6pm (Asia/Jerusalem)' 2026-11-03T16:00:00Z
  resets_case 2026-11-01T00:00:00Z 'Nov 3 at 9:05PM (Asia/Jerusalem)' 2026-11-03T19:05:00Z
  resets_case 2026-11-01T00:00:00Z 'Nov 2 at 3:00pm (UTC)' 2026-11-02T15:00:00Z
  resets_case 2026-11-01T00:00:00Z 'Nov 3 at 9:00am (America/Argentina/Buenos_Aires)' 2026-11-03T12:00:00Z
  resets_case 2026-11-01T00:00:00Z 'Nov 3 at 5:59am (Etc/GMT+5)' 2026-11-03T10:59:00Z
}

test_resets_at_year_follows_the_clock() {
  up_setup
  resets_case 2026-12-30T00:00:00Z 'Jan 2 at 3:00am (UTC)' 2027-01-02T03:00:00Z
  resets_case 2026-12-30T00:00:00Z 'Dec 31 at 3:00am (UTC)' 2026-12-31T03:00:00Z
  resets_case 2027-01-01T01:00:00Z 'Jan 3 at 3:00am (UTC)' 2027-01-03T03:00:00Z
  resets_case 2028-02-27T00:00:00Z 'Feb 29 at 3:00am (UTC)' 2028-02-29T03:00:00Z
}

test_resets_at_follows_daylight_saving_in_that_zone() {
  up_setup
  # US clocks went back on 2026-11-01 and forward on 2026-03-08.
  resets_case 2026-10-30T00:00:00Z 'Nov 2 at 12:00pm (America/New_York)' 2026-11-02T17:00:00Z
  resets_case 2026-10-30T00:00:00Z 'Oct 31 at 12:00pm (America/New_York)' 2026-10-31T16:00:00Z
  resets_case 2026-03-07T00:00:00Z 'Mar 9 at 3:00am (America/New_York)' 2026-03-09T07:00:00Z
  resets_case 2026-03-07T00:00:00Z 'Mar 8 at 2:30am (America/New_York)' ""
}

test_the_computers_own_timezone_does_not_matter() {
  up_setup
  export TZ=Pacific/Auckland
  resets_case 2026-11-01T00:00:00Z 'Nov 3 at 5:59am (Asia/Jerusalem)' 2026-11-03T03:59:00Z
  export TZ=America/Los_Angeles
  resets_case 2026-11-01T00:00:00Z 'Nov 3 at 5:59am (Asia/Jerusalem)' 2026-11-03T03:59:00Z
}

test_resets_at_is_left_out_when_it_cannot_be_trusted() {
  up_setup
  local z
  # an unknown zone name: date would silently use UTC
  resets_case 2026-11-01T00:00:00Z 'Nov 3 at 5:59am (Mars/Olympus)' ""
  resets_case 2026-11-01T00:00:00Z 'Nov 3 at 5:59am (Asia/Nowhere)' ""
  # not a zone name at all
  for z in '../../etc/passwd' 'UTC; touch x' '' 'Asia/Jerusalem/a/b/c' '$(id)' 'Asia Jerusalem' '/etc/localtime' 'asia//jerusalem'; do
    resets_case 2026-11-01T00:00:00Z "Nov 3 at 5:59am ($z)" ""
  done
  # not the English 12-hour form
  resets_case 2026-11-01T00:00:00Z '3 Nov at 5:59am (Asia/Jerusalem)' ""
  resets_case 2026-11-01T00:00:00Z 'Nov 3 at 17:59 (Asia/Jerusalem)' ""
  resets_case 2026-11-01T00:00:00Z 'Nov 3 at 13:00pm (Asia/Jerusalem)' ""
  resets_case 2026-11-01T00:00:00Z 'Nov 3 at 0:30am (Asia/Jerusalem)' ""
  resets_case 2026-11-01T00:00:00Z 'Nov 3 at 5:75am (Asia/Jerusalem)' ""
  resets_case 2026-11-01T00:00:00Z 'Nov 3 at 5:59am Asia/Jerusalem' ""
  resets_case 2026-11-01T00:00:00Z 'Noz 3 at 5:59am (Asia/Jerusalem)' ""
  resets_case 2026-11-01T00:00:00Z 'soon' ""
  # an impossible date
  resets_case 2026-02-01T00:00:00Z 'Feb 30 at 5:59am (Asia/Jerusalem)' ""
  resets_case 2026-02-01T00:00:00Z 'Feb 29 at 5:59am (Asia/Jerusalem)' ""
  resets_case 2026-11-01T00:00:00Z 'Nov 0 at 5:59am (Asia/Jerusalem)' ""
  resets_case 2026-11-01T00:00:00Z 'Nov 32 at 5:59am (Asia/Jerusalem)' ""
  # not inside the next 8 days: the past, now, and too far ahead
  resets_case 2026-11-01T00:00:00Z 'Oct 31 at 5:59am (Asia/Jerusalem)' ""
  resets_case 2026-11-01T00:00:00Z 'Nov 1 at 2:00am (Asia/Jerusalem)' ""
  resets_case 2026-11-01T00:00:00Z 'Nov 9 at 2:01am (Asia/Jerusalem)' ""
  resets_case 2026-11-01T00:00:00Z 'Dec 20 at 5:59am (Asia/Jerusalem)' ""
}

test_the_reset_window_edges() {
  up_setup
  resets_case 2026-11-01T00:00:00Z 'Nov 1 at 2:00am (UTC)' 2026-11-01T02:00:00Z
  resets_case 2026-11-01T00:00:00Z 'Nov 9 at 12:00am (UTC)' 2026-11-09T00:00:00Z
  resets_case 2026-11-01T00:00:00Z 'Nov 1 at 12:00am (UTC)' ""
}

test_no_new_tool_runs_from_path() {
  up_setup
  resets_case 2026-11-01T00:00:00Z 'Nov 3 at 5:59am (Asia/Jerusalem)' 2026-11-03T03:59:00Z
  t_eq "" "$(cat "$STUB_LOG/forbidden" 2>/dev/null)"
}

test_a_fresh_status_line_figure_means_no_probe() {
  up_setup
  local tap="$(agent)/state/plan-usage/claude.last"
  mkdir -p "$(dirname "$tap")"
  printf '41|%s|%s' $((NOW0 + 86400)) $((NOW0 - 100)) >"$tap"
  hook
  t_eq 0 "$(runs)" "figure 100 s old"
  printf '41|%s|%s' $((NOW0 + 86400)) $((NOW0 - 3599)) >"$tap"
  hook; t_eq 0 "$(runs)" "figure 3599 s old"
  printf '41|%s|%s' $((NOW0 + 86400)) $((NOW0 - 3600)) >"$tap"
  hook; t_eq 1 "$(runs)" "figure exactly an hour old"
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

test_without_a_login_file_it_still_probes_and_sends_no_account() {
  up_setup
  rm -f "$HOME/.claude.json"
  hook
  t_eq 1 "$(t_calls)"
  t_lacks "$(body)" account_uuid
  t_lacks "$(body)" organization
  t_contains "$(body)" '"windows":[{"kind":"weekly_all"'
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
  t_eq 0 "$(counter)" "a timeout is not an unparsed result"
  t_eq "" "$(find "$(pdir)" -mindepth 1)"
  t_not test -d "$(aionas_savings_dir)/locks/usage-probe.lock"
  t_eq "$NOW0" "$(cat "$(stamp)")" "a hung start is not retried before the hour is over"
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
