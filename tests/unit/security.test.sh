#!/usr/bin/env bash
# AIO-1072: the security findings of the second-model review. curl never reads
# the developer's .curlrc and never leaves the enrolled gateway (finding 1);
# the state folder must be private or the plugin does nothing (finding 5).
. "$(dirname "$0")/../lib/harness.sh"

sav() { aionas_savings_dir; }
start() { printf '{"session_id":"s1","source":"startup"}' | bash "$T_PLUGIN/hooks/$1.sh" >/dev/null 2>&1; }

test_every_curl_call_starts_with_disable_and_allows_https_only() {
  t_enroll https://gw.example.test
  aionas_http GET /enroll/v1/savings/policy - "$HOME/o" >/dev/null
  printf '{}' >"$HOME/b"
  aionas_http POST /enroll/v1/savings/counters "$HOME/b" "$HOME/o" >/dev/null
  aionas_http_public GET /api/aionas/onboarding/scripts/x "$HOME/o" >/dev/null
  t_eq 3 "$(t_calls)"
  local i a
  for i in 1 2 3; do
    a=$(t_call "$i" args)
    t_eq --disable "$(printf '%s\n' "$a" | head -1)" "call $i: --disable is the first argument"
    t_contains "$a" "$(printf -- '--proto\n=https\n')" "call $i"
    t_lacks "$a" "--location" "call $i"
    t_not grep -qx -- '-L' "$FAKE_CURL_LOG/$i/args"
  done
}

test_a_loopback_http_gateway_is_allowed_plain_http_only() {
  t_enroll http://127.0.0.1:8700
  aionas_http GET /enroll/v1/savings/policy - "$HOME/o" >/dev/null
  t_contains "$(t_call 1 args)" "$(printf -- '--proto\n=http\n')"
  t_eq "http://127.0.0.1:8700/enroll/v1/savings/policy" "$(t_call 1 url)"
}

test_a_failed_curl_is_never_a_success_even_with_a_2xx_status() {
  t_enroll
  export FAKE_CURL_RC=23
  t_rc 1 aionas_http GET /enroll/v1/savings/policy - "$HOME/o" >/dev/null
  t_eq 000 "$(aionas_http GET /enroll/v1/savings/policy - "$HOME/o")"
  t_rc 1 aionas_http_public GET /api/aionas/onboarding/scripts/x "$HOME/o" >/dev/null
  t_eq 000 "$(aionas_http_public GET /api/aionas/onboarding/scripts/x "$HOME/o")"
}

test_the_real_curl_never_reads_the_developers_curlrc() {
  command -v curl >/dev/null || { echo "    skip: no curl"; return 0; }
  unset AIONAS_CURL CURL_HOME
  export XDG_CONFIG_HOME="$HOME/.config"
  t_enroll https://127.0.0.1:1
  printf 'location\ntrace-ascii = "%s/trace"\nurl = "https://example.invalid/"\n' "$HOME" >"$HOME/.curlrc"
  aionas_http GET /enroll/v1/savings/policy - "$HOME/o" >/dev/null
  t_not test -e "$HOME/trace"
}

test_the_header_file_has_an_unpredictable_name_and_is_removed() {
  t_enroll
  aionas_http GET /enroll/v1/savings/policy - "$HOME/o" >/dev/null
  local h; h=$(grep '^@' "$FAKE_CURL_LOG/1/args" | head -1); h=${h#@}
  case "${h##*/}" in .auth.[0-9]*) t_fail "predictable header name [$h]" ;; .auth.??????*) ;; *) t_fail "header [$h]" ;; esac
  t_not test -e "$h"
  t_contains "$(t_call 1 headers)" "Authorization: Bearer $T_ALIAS"
}

test_a_world_writable_state_dir_means_nothing_is_written_or_sent() {
  t_enroll
  mkdir -p "$(sav)"; chmod 777 "$(sav)"
  local h
  for h in policy-sync daily-scan plan-report script-refresh usage-probe effort-window unused-services write-minimum counters-flush; do
    start "$h"
  done
  t_eq 0 "$(t_calls)" "nothing sent"
  t_eq "" "$(find "$(sav)" -mindepth 1)" "nothing written"
  t_eq 777 "$(t_mode "$(sav)")" "left as it was"
}

test_a_symlinked_state_dir_means_nothing_is_written_or_sent() {
  t_enroll
  local real; real=$(mktemp -d "$T_ROOT/real.XXXXXX"); chmod 700 "$real"
  mkdir -p "$(dirname "$(sav)")"; ln -s "$real" "$(sav)"
  start policy-sync; start counters-flush
  t_eq 0 "$(t_calls)"
  t_eq "" "$(find "$real" -mindepth 1)"
}

test_a_group_readable_state_dir_of_the_user_is_made_private_and_used() {
  t_enroll
  mkdir -p "$(sav)"; chmod 755 "$(sav)"
  start policy-sync
  t_eq 700 "$(t_mode "$(sav)")"
  t_eq 1 "$(t_calls)"
}

test_a_new_state_dir_is_created_private() {
  t_enroll
  start policy-sync
  t_eq 700 "$(t_mode "$(sav)")"
  t_eq 1 "$(t_calls)"
}

t_main "$@"
