# aionas-savings policy cache (AIO-855, W24-1/W24-2/W24-P2).
#
# Files under $(aionas_savings_dir):
#   policy.cache          the last good policy (see policy.awk for the format)
#   policy.json           the raw last good answer (numbers and names only)
#   sessions/<sid>.cache  the policy a session was started with (its pin)
#   local-overrides.tsv   bypasses made on this computer: method status from until
#   sync.status           "<epoch> <http status>" of the last sync attempt
#
# A session reads its pin, so a policy change applies from the next session
# only. With nothing cached every method is on (output_trim off, AIO-883) and
# self-override and self-release are allowed (W24-1, W24-2). Required methods are always on and
# can never be overridden or released.

# aionas_policy_sync: fetch the person's policy in one try (3 s connect, 5 s
# total) and replace the cache only with a valid answer. Exit 0 on a new
# cache; 1 when it kept the old one (network, status, invalid body); 3 when
# the computer is not enrolled; 4 when another sync holds the lock.
aionas_policy_sync() {
  _ps_dir=$(aionas_savings_dir)
  aionas_mkdir "$_ps_dir" || return 1
  aionas_lock_try policy-sync 30 || return 4
  _ps_resp="$_ps_dir/.policy.resp.$$"
  _ps_code=$(aionas_http GET /enroll/v1/savings/policy - "$_ps_resp")
  _ps_rc=$?
  printf '%s %s\n' "$(aionas_now)" "$_ps_code" | aionas_write_atomic "$_ps_dir/sync.status"
  if [ $_ps_rc -eq 0 ] &&
    aionas_json_flatten "$_ps_resp" 2>/dev/null |
    awk -v now="$(aionas_now)" -v methods="$AIONAS_METHODS" -f "$AIONAS_LIB/time.awk" -f "$AIONAS_LIB/policy.awk" >"$_ps_dir/.policy.cache.$$" &&
    mv -f "$_ps_dir/.policy.cache.$$" "$_ps_dir/policy.cache"; then
    mv -f "$_ps_resp" "$_ps_dir/policy.json"
    aionas_lock_release policy-sync
    return 0
  fi
  rm -f "$_ps_resp" "$_ps_dir/.policy.cache.$$"
  aionas_lock_release policy-sync
  [ $_ps_rc -eq 3 ] && return 3
  return 1
}

# aionas_policy_pin SESSION_ID: pin the current cache to a session. An
# existing pin is kept (a resumed or compacted session keeps its policy).
# With nothing cached the pin says "defaults". At most 200 pins are kept.
aionas_policy_pin() {
  _aionas_sid_ok "$1" || return 2
  _pp_dir="$(aionas_savings_dir)/sessions"
  aionas_mkdir "$_pp_dir" || return 1
  [ -f "$_pp_dir/$1.cache" ] && return 0
  if [ -f "$(aionas_savings_dir)/policy.cache" ]; then
    aionas_write_atomic "$_pp_dir/$1.cache" <"$(aionas_savings_dir)/policy.cache" || return 1
  else
    printf 'V\t1\nD\tdefaults\n' | aionas_write_atomic "$_pp_dir/$1.cache" || return 1
  fi
  # shellcheck disable=SC2012
  ls -1t "$_pp_dir" 2>/dev/null | grep '\.cache$' | sed -n '201,$p' | while IFS= read -r _pp_old; do
    rm -f "$_pp_dir/$_pp_old"
  done
  return 0
}

# aionas_policy_state METHOD [SESSION_ID]: print on or off. Exit 2 for a
# method outside the catalog.
aionas_policy_state() {
  aionas_is_method "$1" || return 2
  if aionas_is_required "$1"; then echo on; return 0; fi
  _st_row=$(_aionas_policy_row "$1" "${2:-}")
  if [ -z "$_st_row" ]; then
    if aionas_is_default_off "$1"; then echo off; else echo on; fi
    return 0
  fi
  set -- $_st_row
  # M method state required self_override self_release released
  if [ "$3" = off ] || [ "$7" = 1 ]; then echo off; else echo on; fi
}

# aionas_policy_self_override_allowed METHOD [SESSION_ID]: exit 0 when the
# person may bypass the method without asking (default yes; required: no).
aionas_policy_self_override_allowed() {
  aionas_is_method "$1" || return 2
  aionas_is_required "$1" && return 1
  _so_row=$(_aionas_policy_row "$1" "${2:-}")
  [ -z "$_so_row" ] && return 0
  set -- $_so_row
  [ "$5" = 1 ]
}

# aionas_policy_self_release_allowed METHOD [SESSION_ID]: exit 0 when the
# person may release themself from the method (default yes; required: no).
aionas_policy_self_release_allowed() {
  aionas_is_method "$1" || return 2
  aionas_is_required "$1" && return 1
  _sr_row=$(_aionas_policy_row "$1" "${2:-}")
  [ -z "$_sr_row" ] && return 0
  set -- $_sr_row
  [ "$6" = 1 ]
}

# aionas_policy_param METHOD KEY [SESSION_ID]: print the raw value of a
# method parameter (nested keys joined with "."). Exit 1 when it is not set.
aionas_policy_param() {
  aionas_is_method "$1" || return 2
  _pa_f=$(_aionas_policy_file "${3:-}") || return 1
  awk -F '\t' -v m="$1" -v k="$2" '$1 == "P" && $2 == m && $3 == k { print $5; f = 1; exit } END { exit f ? 0 : 1 }' "$_pa_f"
}

# aionas_policy_bypassed METHOD [SESSION_ID]: exit 0 when an override is in
# force now: a self or approved override from the server (as pinned), or one
# made on this computer since (local-overrides.tsv). Required methods: never.
aionas_policy_bypassed() {
  aionas_is_method "$1" || return 2
  aionas_is_required "$1" && return 1
  _by_now=$(aionas_now)
  _by_f=$(_aionas_policy_file "${2:-}")
  _by_l="$(aionas_savings_dir)/local-overrides.tsv"
  if [ -n "$_by_f" ]; then
    awk -F '\t' -v m="$1" -v now="$_by_now" '
      $1 == "O" && $2 == m && ($3 == "self" || $3 == "approved") && $4 <= now && ($5 == 0 || $5 > now) { f = 1; exit }
      END { exit f ? 0 : 1 }' "$_by_f" && return 0
  fi
  [ -f "$_by_l" ] || return 1
  awk -F '\t' -v m="$1" -v now="$_by_now" '
    $1 == m && ($2 == "self" || $2 == "approved") && $3 <= now && $4 > now { f = 1; exit }
    END { exit f ? 0 : 1 }' "$_by_l"
}

# aionas_policy_active METHOD [SESSION_ID]: exit 0 when the method should act
# now (on, and not bypassed). Required methods are always active.
aionas_policy_active() {
  _ac_s=$(aionas_policy_state "$1" "${2:-}") || return 2
  [ "$_ac_s" = on ] || return 1
  aionas_policy_bypassed "$1" "${2:-}" && return 1
  return 0
}

# aionas_override_local_add METHOD SECONDS [STATUS]: record on this computer
# that METHOD is bypassed for SECONDS (1 s to 30 days) from now, so it takes
# effect at once, before the next policy sync. STATUS is self (default) or
# approved. Expired rows are dropped. Required methods are refused (exit 2).
aionas_override_local_add() {
  aionas_is_method "$1" || return 2
  aionas_is_required "$1" && return 2
  aionas_is_uint "$2" || return 2
  { [ "$2" -ge 1 ] && [ "$2" -le 2592000 ]; } || return 2
  case "${3:-self}" in self | approved) ;; *) return 2 ;; esac
  _lo_dir=$(aionas_savings_dir)
  aionas_mkdir "$_lo_dir" || return 1
  _lo_now=$(aionas_now)
  {
    [ -f "$_lo_dir/local-overrides.tsv" ] &&
      awk -F '\t' -v now="$_lo_now" '$4 > now' "$_lo_dir/local-overrides.tsv"
    printf '%s\t%s\t%s\t%s\n' "$1" "${3:-self}" "$_lo_now" $((_lo_now + $2))
  } | aionas_write_atomic "$_lo_dir/local-overrides.tsv"
}

# --- internal -------------------------------------------------------------

_aionas_sid_ok() {
  case "$1" in '' | *[!A-Za-z0-9_-]*) return 1 ;; esac
  [ ${#1} -le 128 ]
}

# The file a lookup reads: the session's pin, else the last good cache.
# Prints nothing (exit 1) when neither exists: the defaults apply.
_aionas_policy_file() {
  if [ -n "$1" ] && _aionas_sid_ok "$1" && [ -f "$(aionas_savings_dir)/sessions/$1.cache" ]; then
    echo "$(aionas_savings_dir)/sessions/$1.cache"
  elif [ -f "$(aionas_savings_dir)/policy.cache" ]; then
    echo "$(aionas_savings_dir)/policy.cache"
  else
    return 1
  fi
}

_aionas_policy_row() {
  _pr_f=$(_aionas_policy_file "$2") || return 0
  awk -F '\t' -v m="$1" '$1 == "M" && $2 == m { print; exit }' "$_pr_f"
}
