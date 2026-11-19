#!/usr/bin/env bash
# AIO-1083 (wave 33, plugin half): the guard on the Claude 5-hour window and
# Fable's weekly cap (lib/limit-guard.sh). It reads only local state: the
# status-line tap's claude5h.last ("<pct>|<reset>|<at>", gateway step A) and
# the Fable figure kept from the plugin's own /usage probe. At the warn line
# (80 %) it warns and moves sub-agents to Sonnet (the mod acts on its answer),
# at 90 % it only SUGGESTS /model sonnet, and it counts how each watched
# window ended: window_reset (below 100 %) or window_reached. A stale reading
# is "not measured" (F10); under Cursor, without the gateway's limit_guard
# capability or with the method off it does nothing.
. "$(dirname "$0")/../lib/harness.sh"
unset CURSOR_VERSION CLAUDECODE AIONAS_LIMIT_GUARD_WARN_PCT
# shellcheck disable=SC1091
. "$T_PLUGIN/lib/limit-guard.sh"

T0=1792490400 # 2026-10-20T10:00:00Z
R5=$((T0 + 7200)) # the 5-hour window resets in two hours

# policy [STATE] [CAPS...]: a cached policy with limit_guard in STATE (on) and
# these gateway capabilities (default: limit_guard).
policy() {
  local st=${1:-on}; shift || true
  [ $# -eq 0 ] && set -- limit_guard
  mkdir -p "$(aionas_savings_dir)"
  { printf 'V\t1\nF\t1\nM\tlimit_guard\t%s\t0\t1\t1\t0\n' "$st"; for c in "$@"; do [ "$c" = - ] || printf 'C\t%s\n' "$c"; done; } >"$(aionas_savings_dir)/policy.cache"
}
# five PCT [RESET] [AT]: what the status-line tap writes.
five() {
  mkdir -p "$HOME/.aionas/agent/state/plan-usage"
  printf '%s|%s|%s' "$1" "${2:-$R5}" "${3:-$((T0 - 60))}" >"$HOME/.aionas/agent/state/plan-usage/claude5h.last"
}
# fable PCT RESET [AT]: the Fable weekly figure kept from the /usage probe.
fable() {
  mkdir -p "$(aionas_savings_dir)"
  printf '%s|%s|%s' "$1" "$2" "${3:-$((T0 - 60))}" >"$(aionas_savings_dir)/usage-probe-fable.last"
}
# guard: what the mod runs (argument vector, no stdin), its one line.
guard() { bash "$T_PLUGIN/lib/limit-guard.sh" state s1 </dev/null; }
# counts: the limit_guard increments queued, "counter value" per line.
counts() { t_counters | awk -F '\t' '$2 == "limit_guard" { n[$3] += $4 } END { for (c in n) print c "\t" n[c] }' | sort; }
line() { printf 'limit\t%s\t%s\t%s\t%s' "$@"; }

setup() { t_enroll; export AIONAS_NOW=$T0; policy; }

# --- thresholds ---------------------------------------------------------------

test_79_is_below_the_line_and_counts_nothing() {
  setup; five 79
  t_eq "$(line ok five_hour 79 "$R5")" "$(guard)"
  t_eq "" "$(counts)"
}

test_80_warns_and_fires_once_per_window() {
  setup; five 80
  t_eq "$(line warn five_hour 80 "$R5")" "$(guard)"
  five 84.6
  t_eq "$(line warn five_hour 84 "$R5")" "$(guard)" "the percent is whole"
  t_eq "$(printf 'fired\t1')" "$(counts)" "one fired per window, not per read"
}

test_90_only_suggests() {
  setup; five 90
  t_eq "$(line suggest five_hour 90 "$R5")" "$(guard)"
  five 99.9
  t_eq "$(line suggest five_hour 99 "$R5")" "$(guard)"
  t_eq "$(printf 'fired\t1')" "$(counts)"
}

test_100_is_reached_once() {
  setup; five 81
  guard >/dev/null
  five 100
  t_eq "$(line full five_hour 100 "$R5")" "$(guard)"
  five 100
  guard >/dev/null
  t_eq "$(printf 'fired\t1\nwindow_reached\t1')" "$(counts)"
}

test_a_window_that_jumps_straight_to_100_fires_and_is_reached() {
  setup; five 100
  t_eq "$(line full five_hour 100 "$R5")" "$(guard)"
  t_eq "$(printf 'fired\t1\nwindow_reached\t1')" "$(counts)"
}

test_the_test_warn_line_is_bounded() {
  setup; five 55
  t_eq "$(line warn five_hour 55 "$R5")" "$(AIONAS_LIMIT_GUARD_WARN_PCT=50 guard)"
  t_eq "$(line ok five_hour 55 "$R5")" "$(AIONAS_LIMIT_GUARD_WARN_PCT=95 guard)" "a line above 89 is ignored"
  t_eq "$(line ok five_hour 55 "$R5")" "$(AIONAS_LIMIT_GUARD_WARN_PCT=abc guard)"
}

# --- not measured (F10) -------------------------------------------------------

test_a_stale_file_is_not_measured() {
  setup
  five 95 $((T0 - 1)) $((T0 - 9000)) # the window it describes is over
  t_eq "$(line unmeasured - 0 0)" "$(guard)"
  five 95 "$T0" # resets right now
  t_eq "$(line unmeasured - 0 0)" "$(guard)"
  t_eq "" "$(counts)" "no warning, no count"
}

test_a_missing_or_malformed_file_is_not_measured() {
  setup
  t_eq "$(line unmeasured - 0 0)" "$(guard)"
  mkdir -p "$HOME/.aionas/agent/state/plan-usage"
  for bad in 'x|1|2' '85||2' "85|$R5" "85|$R5|soon" "-5|$R5|$T0" "85|$((T0 + 30 * 86400))|$T0" "85|$R5|$((T0 + 3600))" "85|$R5|$((R5 - 20000))"; do
    printf '%s' "$bad" >"$HOME/.aionas/agent/state/plan-usage/claude5h.last"
    t_eq "$(line unmeasured - 0 0)" "$(guard)" "read [$bad]"
  done
  t_eq "" "$(counts)"
}

# --- the window's outcome -----------------------------------------------------

test_a_watched_window_that_resets_below_100_counts_window_reset_once() {
  setup; five 85
  guard >/dev/null
  # The window is over: the file still holds its last reading (stale).
  t_eq "$(line unmeasured - 0 0)" "$(AIONAS_NOW=$((R5 + 60)) guard)"
  AIONAS_NOW=$((R5 + 120)) guard >/dev/null
  t_eq "$(printf 'fired\t1\nwindow_reset\t1')" "$(counts)"
}

test_a_new_window_in_the_file_ends_the_old_one() {
  setup; five 88
  guard >/dev/null
  # The tap already saw the next window (a new reset time).
  five 3 $((T0 + 18000)) "$T0"
  t_eq "$(line ok five_hour 3 $((T0 + 18000)))" "$(guard)"
  t_eq "$(printf 'fired\t1\nwindow_reset\t1')" "$(counts)"
}

test_a_window_that_reached_100_is_not_also_reset() {
  setup; five 100
  guard >/dev/null
  AIONAS_NOW=$((R5 + 60)) guard >/dev/null
  t_eq "$(printf 'fired\t1\nwindow_reached\t1')" "$(counts)"
}

test_a_window_below_the_line_has_no_outcome() {
  setup; five 40
  guard >/dev/null
  AIONAS_NOW=$((R5 + 60)) guard >/dev/null
  t_eq "" "$(counts)"
}

# --- when the guard does nothing ----------------------------------------------

test_without_the_capability_it_does_nothing_and_counts_nothing() {
  setup; policy on counters_client; five 95
  t_eq "$(line off - 0 0)" "$(guard)"
  policy on -; five 95
  t_eq "$(line off - 0 0)" "$(guard)" "an older gateway lists no capabilities"
  rm -f "$(aionas_savings_dir)/policy.cache"
  t_eq "$(line off - 0 0)" "$(guard)" "nothing cached"
  t_eq "" "$(counts)"
  t_ok test ! -e "$(aionas_savings_dir)/limit-guard.tsv"
}

test_method_off_or_bypassed_is_off_and_counts_skipped_once_per_window() {
  setup; policy off limit_guard; five 92
  t_eq "$(line off - 0 0)" "$(guard)"
  guard >/dev/null
  t_eq "$(printf 'skipped\t1')" "$(counts)"
  # Back on, then bypassed on this computer for an hour.
  policy on limit_guard
  aionas_override_local_add limit_guard 3600 self
  t_eq "$(line off - 0 0)" "$(guard)"
  t_eq "$(printf 'skipped\t1')" "$(counts)" "the same window"
  # Below the line nothing is skipped.
  five 10 $((T0 + 18000)) "$T0"
  guard >/dev/null
  t_eq "$(printf 'skipped\t1')" "$(counts)"
}

test_a_released_method_is_off() {
  setup; five 92
  printf 'V\t1\nF\t1\nM\tlimit_guard\ton\t0\t1\t1\t1\nC\tlimit_guard\n' >"$(aionas_savings_dir)/policy.cache"
  t_eq "$(line off - 0 0)" "$(guard)"
}

test_under_cursor_it_does_nothing() {
  setup; five 95
  t_eq "" "$(CURSOR_VERSION=3.23.23 guard)"
  t_eq "" "$(counts)"
  t_ok test ! -e "$(aionas_savings_dir)/limit-guard.tsv"
  # Claude Code started from a Cursor terminal is still Claude Code.
  t_eq "$(line suggest five_hour 95 "$R5")" "$(CURSOR_VERSION=3.23.23 CLAUDECODE=1 guard)"
}

test_not_enrolled_it_does_nothing() {
  setup; five 95; t_unenroll
  t_eq "" "$(guard)"
  t_eq "" "$(counts)"
}

test_the_guard_never_calls_the_network() {
  setup; five 95
  guard >/dev/null
  AIONAS_NOW=$((R5 + 60)) guard >/dev/null
  t_eq 0 "$(t_calls)"
}

# --- Fable's weekly cap ---------------------------------------------------------

test_fable_weekly_warns_like_the_window() {
  setup; five 40
  local rw=$((T0 + 3 * 86400))
  fable 86 "$rw"
  t_eq "$(line warn fable_week 86 "$rw")" "$(guard)" "the higher of the two"
  five 93
  t_eq "$(line suggest five_hour 93 "$R5")" "$(guard)"
  t_eq "$(printf 'fired\t2')" "$(counts)" "one per watched window"
}

test_fable_record_reads_the_fable_line_of_the_usage_text() {
  setup
  local text out
  text=$(printf 'Current session: 12%% used\nCurrent week (all models): 47%% used \302\267 resets Oct 23 at 3pm (UTC)\nCurrent week (Fable): 81%% used \302\267 resets Oct 23 at 3:30pm (UTC)\nWhat is contributing: /Users/noa/secret-project 40%%\n')
  t_rc 0 aionas_lg_fable_record <<<"$text"
  out=$(cat "$(aionas_savings_dir)/usage-probe-fable.last")
  # 2026-10-23T15:30:00Z
  t_eq "81|1792769400|$T0" "$out"
  t_lacks "$out" secret
  t_eq "$(line warn fable_week 81 1792769400)" "$(guard)"
}

test_fable_record_keeps_nothing_without_a_readable_fable_line() {
  setup
  t_rc 1 aionas_lg_fable_record <<<"$(printf 'Current week (all models): 47%% used \302\267 resets Oct 23 at 3pm (UTC)\n')"
  t_rc 1 aionas_lg_fable_record <<<"$(printf 'Current week (Fable): lots used \302\267 resets Oct 23 at 3pm (UTC)\n')"
  t_rc 1 aionas_lg_fable_record <<<"$(printf 'Current week (Fable): 50%% used \302\267 resets someday (UTC)\n')"
  t_rc 1 aionas_lg_fable_record <<<"$(printf 'Current week (Fable): 50%% used \302\267 resets Oct 23 at 3pm (Not/AZone)\n')"
  t_rc 1 aionas_lg_fable_record <<<"$(printf 'Current week (Fable): 50%% used \302\267 resets Oct 23 at 3pm (*)\n')"
  t_rc 1 aionas_lg_fable_record <<<"$(printf 'Current week (Fable): 50%% used \302\267 resets Oct 23 at 3pm (UTC)\nCurrent week (Fable): 60%% used \302\267 resets Oct 23 at 3pm (UTC)\n')"
  t_ok test ! -e "$(aionas_savings_dir)/usage-probe-fable.last"
}

test_fable_record_converts_the_named_zone() {
  [ -f /usr/share/zoneinfo/Asia/Jerusalem ] || { echo "    (skipped: no zoneinfo)"; return 0; }
  setup
  # 2026-10-23 15:00 in Jerusalem (UTC+3 in October) = 12:00Z = 1792756800.
  t_rc 0 aionas_lg_fable_record <<<"$(printf 'Current week (Fable): 9%% used \302\267 resets Oct 23 at 3pm (Asia/Jerusalem)\n')"
  t_eq "9|1792756800|$T0" "$(cat "$(aionas_savings_dir)/usage-probe-fable.last")"
}

# --- what the line may carry ----------------------------------------------------

test_the_line_carries_only_names_and_numbers() {
  setup; five 91; fable 20 $((T0 + 86400))
  t_ok grep -Eq '^limit	(off|unmeasured|ok|warn|suggest|full)	(-|five_hour|fable_week)	[0-9]+	[0-9]+$' <<<"$(guard)"
}

t_main "$@"
