#!/usr/bin/env bash
# lib/platform.sh, lib/enroll.sh, lib/catalog.sh
. "$(dirname "$0")/../lib/harness.sh"

test_os_detection() {
  local u
  u=$(mktemp "$T_ROOT/uname.XXXXXX"); chmod 755 "$u"
  for pair in Darwin:darwin Linux:linux MINGW64_NT-10.0-19045:windows MSYS_NT-10.0:windows CYGWIN_NT-10.0:windows SunOS:other; do
    printf '#!/bin/sh\necho %s\n' "${pair%%:*}" >"$u"
    t_eq "${pair##*:}" "$(AIONAS_UNAME=$u aionas_os)"
  done
}

test_state_dirs_follow_home() {
  t_eq "$HOME/.aionas/agent" "$(aionas_agent_dir)"
  t_eq "$HOME/.aionas/agent/savings" "$(aionas_savings_dir)"
  t_eq /x/s "$(AIONAS_SAVINGS_DIR=/x/s aionas_savings_dir)"
}

test_write_atomic_is_private_and_leaves_no_temp() {
  aionas_mkdir "$HOME/d"
  printf 'one\n' | aionas_write_atomic "$HOME/d/f"
  t_eq one "$(cat "$HOME/d/f")"
  t_eq "$HOME/d/f" "$(ls -d "$HOME"/d/*)"
  t_eq 600 "$(t_mode "$HOME/d/f")"
}

test_lock_try_excludes_and_breaks_stale() {
  export AIONAS_NOW=1000
  t_ok aionas_lock_try x 60
  t_not aionas_lock_try x 60
  AIONAS_NOW=1061 t_ok aionas_lock_try x 60
  aionas_lock_release x
  t_ok aionas_lock_try x 60
}

test_catalog_closed_lists() {
  t_ok aionas_is_method noisy_guard
  t_ok aionas_is_method output_store
  t_not aionas_is_method long_output_store
  t_not aionas_is_method ''
  t_ok aionas_is_required cache_guard
  t_not aionas_is_required handoff
  t_ok aionas_is_counter bypass
  t_not aionas_is_counter prompt
}

test_enroll_reads_alias_and_gateway() {
  t_not aionas_enroll_has_alias
  t_not aionas_enroll_gateway
  t_enroll https://gw.example.test/
  t_ok aionas_enroll_has_alias
  t_eq https://gw.example.test "$(aionas_enroll_gateway)"
  aionas_enroll_auth_header_file "$HOME/h"
  t_eq "Authorization: Bearer $T_ALIAS" "$(cat "$HOME/h")"
  t_eq 600 "$(t_mode "$HOME/h")"
}

test_enroll_refuses_bad_alias_and_gateway() {
  t_enroll
  printf 'sk-ant-raw-key\n' >"$HOME/.aionas/agent/credential"
  t_not aionas_enroll_has_alias
  t_not aionas_enroll_auth_header_file "$HOME/h"
  t_ok test ! -e "$HOME/h"
  printf 'aen-%s\n' "$(printf 'a%.0s' $(seq 1 257))" >"$HOME/.aionas/agent/credential"
  t_not aionas_enroll_has_alias
  printf 'aen-short\n' >"$HOME/.aionas/agent/credential"
  t_not aionas_enroll_has_alias
  printf 'aen-%s\r\n' "$(printf 'a%.0s' $(seq 1 256))" >"$HOME/.aionas/agent/credential"
  t_ok aionas_enroll_has_alias
  printf '{"gateway":"https://evil.test\\" -H x"}' >"$HOME/.aionas/agent/enrollment.json"
  t_not aionas_enroll_gateway
  printf '{"gateway":"file:///etc/passwd"}' >"$HOME/.aionas/agent/enrollment.json"
  t_not aionas_enroll_gateway
}

t_main "$@"
