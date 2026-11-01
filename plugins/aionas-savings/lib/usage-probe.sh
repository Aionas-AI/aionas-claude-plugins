# aionas-savings: the usage probe (AIO-892, W25P-P3). Sourced by
# hooks/usage-probe.sh only (not by aionas.sh). POSIX sh; also bash 3.2 and Git
# Bash. A member who runs Claude Code in Claude Desktop or the VS Code
# extension never renders the status line, so the status-line tap sends no
# weekly figure. This runs Claude Code's own /usage command, once an hour, and
# sends the "Current week (all models)" percent and reset time.
#
# Privacy: Claude Code fetches the figure with its own login; Aionas never reads
# a token. Only the percent and the reset instant are sent: never the text of
# the result, never the zone name, never a prompt.
# The one program run from PATH is claude. The child is started by a plain exec:
# no env, no timeout and no perl, which a project could shadow on PATH.

# The probe runs at most this often per computer (stamp), and is skipped when
# the status-line tap stored a weekly figure this recently.
AIONAS_UP_INTERVAL=3600
# A /usage result larger than this is not read.
AIONAS_UP_MAX_BYTES=65536
# A reset time only counts when it is in the next 8 days.
AIONAS_UP_RESET_WINDOW=691200
# Seconds the child gets (the test seam AIONAS_USAGE_PROBE_TIMEOUT may only lower it).
AIONAS_UP_TIMEOUT=20
# UNVERIFIED (no Claude extension is installed on the machine this was built
# on): the extension roots under the home folder, and where the extension keeps
# its bundled binary relative to the folder anthropic.claude-code-<version>[-<platform>].
# A wrong guess finds nothing, which is safe: no binary means nothing happens.
AIONAS_UP_VSCODE_ROOTS=".vscode/extensions .vscode-insiders/extensions"
AIONAS_UP_VSCODE_REL="resources/native-binary"
AIONAS_UP_ZONEINFO=/usr/share/zoneinfo

_up_pid=""
_up_out=""
_up_body=""
_up_resp=""
_up_lockheld=""

# aionas_up_tap_fresh NOW: exit 0 when the status-line tap stored a figure less
# than an hour ago (state/plan-usage/claude.last is "pct|reset|at").
aionas_up_tap_fresh() {
  _uf_f="$(aionas_agent_dir)/state/plan-usage/claude.last"
  [ -f "$_uf_f" ] || return 1
  _uf_p="" _uf_r="" _uf_at=""
  IFS='|' read -r _uf_p _uf_r _uf_at <"$_uf_f"
  aionas_is_uint "${_uf_at:-x}" || return 1
  _uf_d=$(($1 - _uf_at))
  [ "$_uf_d" -ge 0 ] && [ "$_uf_d" -lt "$AIONAS_UP_INTERVAL" ]
}

# aionas_up_stamp_fresh NOW: exit 0 when a probe started less than an hour ago.
aionas_up_stamp_fresh() {
  _us_t=$(cat "$(aionas_savings_dir)/usage-probe.last" 2>/dev/null)
  aionas_is_uint "${_us_t:-x}" || return 1
  _us_d=$(($1 - _us_t))
  [ "$_us_d" -ge 0 ] && [ "$_us_d" -lt "$AIONAS_UP_INTERVAL" ]
}

# aionas_up_exec_file PATH: an absolute path to an executable regular file.
aionas_up_exec_file() {
  case "$1" in /*) ;; *) return 1 ;; esac
  [ -f "$1" ] && [ -x "$1" ]
}

# aionas_up_newest_first: names on stdin (each holding a X.Y.Z version), newest
# version first by number (2.1.100 before 2.1.99), never by text or mtime.
aionas_up_newest_first() {
  awk 'match($0, /[0-9]+\.[0-9]+\.[0-9]+/) { split(substr($0, RSTART, RLENGTH), a, "."); printf "%s\t%s\t%s\t%s\n", a[1], a[2], a[3], $0 }' |
    sort -t "$(printf '\t')" -k1,1nr -k2,2nr -k3,3nr -k4,4 | cut -f4
}

# aionas_up_desktop_list: the runnable Claude Desktop bundles, newest version
# first, one per line: "V<TAB>path" when the build folder holds a .verified
# file (Desktop's own mark), else "U<TAB>path". Anything with a symlink on the
# way is left out: the version folder, the build folder (or <X.Y.Z> itself for
# the second layout), claude.app, Contents, MacOS and the binary. A symlink
# there could point the hourly run at a program the member never installed.
aionas_up_desktop_list() {
  _dl_base="$(aionas_home)/Library/Application Support/Claude/claude-code"
  for _dl_v in $(ls -1 "$_dl_base" 2>/dev/null | grep -E '^[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$' | aionas_up_newest_first); do
    [ ! -L "$_dl_base/$_dl_v" ] && [ -d "$_dl_base/$_dl_v" ] || continue
    for _dl_h in "$_dl_base/$_dl_v"/*; do
      [ ! -L "$_dl_h" ] && [ -d "$_dl_h" ] || continue
      _dl_c="$_dl_h/claude.app/Contents/MacOS/claude"
      if [ ! -L "$_dl_h/claude.app" ] && [ ! -L "$_dl_h/claude.app/Contents" ] && [ ! -L "$_dl_h/claude.app/Contents/MacOS" ] &&
        [ ! -L "$_dl_c" ] && aionas_up_exec_file "$_dl_c"; then
        if [ -f "$_dl_h/.verified" ] && [ ! -L "$_dl_h/.verified" ]; then printf 'V\t%s\n' "$_dl_c"; else printf 'U\t%s\n' "$_dl_c"; fi
      fi
    done
    _dl_c="$_dl_base/$_dl_v/claude"
    if [ ! -L "$_dl_c" ] && aionas_up_exec_file "$_dl_c"; then
      if [ -f "$_dl_base/$_dl_v/.verified" ] && [ ! -L "$_dl_base/$_dl_v/.verified" ]; then printf 'V\t%s\n' "$_dl_c"; else printf 'U\t%s\n' "$_dl_c"; fi
    fi
  done
}

# aionas_up_find_bin: print the claude binary to run, else exit 1.
#   1. claude on PATH (an absolute, executable, regular file)
#   2. macOS, Claude Desktop's bundled Claude Code, the newest version that has
#      one: ~/Library/Application Support/Claude/claude-code/<X.Y.Z>/<12 hex>/claude.app/Contents/MacOS/claude
#      (VERIFIED on a Mac with 2.1.304 and 2.1.308). The layout the issue text
#      names, <X.Y.Z>/claude, is tried second (UNVERIFIED, never seen). When
#      any build has a .verified file (Desktop's own mark, in the build folder)
#      the newest verified one wins over a newer unverified one. A path with a
#      symlink on the way is never used (see aionas_up_desktop_list).
#   3. the VS Code extension's bundled binary, newest version (UNVERIFIED path).
# Windows Desktop: no path is cited anywhere, so only PATH is tried there.
aionas_up_find_bin() {
  _fb=$(command -v claude 2>/dev/null)
  if aionas_up_exec_file "$_fb"; then printf '%s\n' "$_fb"; return 0; fi
  if [ "$(aionas_os)" = darwin ]; then
    _fb_list=$(aionas_up_desktop_list)
    _fb=$(printf '%s\n' "$_fb_list" | awk -F '\t' '$1 == "V" { print $2; exit }')
    [ -n "$_fb" ] || _fb=$(printf '%s\n' "$_fb_list" | awk -F '\t' '$1 == "U" { print $2; exit }')
    if [ -n "$_fb" ]; then printf '%s\n' "$_fb"; return 0; fi
  fi
  for _fb_r in $AIONAS_UP_VSCODE_ROOTS; do
    _fb_dir="$(aionas_home)/$_fb_r"
    for _fb_e in $(ls -1 "$_fb_dir" 2>/dev/null | grep -E '^anthropic\.claude-code-[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}(-[A-Za-z0-9._]+)*$' | aionas_up_newest_first); do
      for _fb_n in claude claude.exe; do
        _fb_c="$_fb_dir/$_fb_e/$AIONAS_UP_VSCODE_REL/$_fb_n"
        if aionas_up_exec_file "$_fb_c"; then printf '%s\n' "$_fb_c"; return 0; fi
      done
    done
  done
  return 1
}

# aionas_up_iso EPOCH: RFC 3339 UTC, to the second.
aionas_up_iso() {
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

# aionas_up_offset ZONE EPOCH: the zone's offset from UTC at EPOCH, in seconds
# (east positive). BSD date takes -r EPOCH; GNU date takes -d @EPOCH (its -r
# wants a file, which fails). The caller checks the zone exists first: an
# unknown TZ silently means UTC.
aionas_up_offset() {
  _uo=$(TZ="$1" date -r "$2" +%z 2>/dev/null)
  case "$_uo" in [+-][0-9][0-9][0-9][0-9]) ;; *) _uo=$(TZ="$1" date -d "@$2" +%z 2>/dev/null) ;; esac
  case "$_uo" in [+-][0-9][0-9][0-9][0-9]) ;; *) return 1 ;; esac
  _uo_s=${_uo%????}
  _uo_h=${_uo#?}; _uo_m=${_uo_h#??}; _uo_h=${_uo_h%??}
  _uo_h=${_uo_h#0}; _uo_m=${_uo_m#0}
  _uo_v=$((${_uo_h:-0} * 3600 + ${_uo_m:-0} * 60))
  if [ "$_uo_s" = - ]; then _uo_v=$((0 - _uo_v)); fi
  printf '%s\n' "$_uo_v"
}

# aionas_up_resets ZONE WALL1 WALL2 NOW: print the reset instant as RFC 3339
# UTC, or print nothing (exit 1). A wall time (seconds, as if UTC) becomes an
# instant with the zone's offset, found by iterating and re-checked at the
# result (daylight saving: a time that does not exist is dropped). A wall time
# that happens twice (clocks go back) is NOT resolved on purpose: the first guess
# is the zone's offset at the wall time read as UTC, so zones west of UTC (New
# York 1:30am on the fall-back day) get the first occurrence and zones east of
# UTC (Europe/London 1:30am) get the second, up to one hour apart once a year.
# Only an instant after NOW and within 8 days is kept.
aionas_up_resets() {
  [ -n "$1" ] || return 1
  [ -f "$AIONAS_UP_ZONEINFO/$1" ] || return 1
  for _ur_w in $2 $3; do
    _ur_o0=$(aionas_up_offset "$1" "$_ur_w") || continue
    _ur_o1=$(aionas_up_offset "$1" $((_ur_w - _ur_o0))) || continue
    _ur_e=$((_ur_w - _ur_o1))
    _ur_o2=$(aionas_up_offset "$1" "$_ur_e") || continue
    [ "$_ur_o2" = "$_ur_o1" ] || continue
    [ "$_ur_e" -gt "$4" ] && [ "$_ur_e" -le $(($4 + AIONAS_UP_RESET_WINDOW)) ] || continue
    aionas_up_iso "$_ur_e"
    return 0
  done
  return 1
}

# aionas_up_pct_ok VALUE: the percent as the parser prints it (digits and at
# most one fraction), 0 to 100.
aionas_up_pct_ok() {
  case "$1" in '' | *[!0-9.]* | .* | *. | *.*.*) return 1 ;; esac
  case "$1" in 100 | [0-9] | [0-9][0-9] | [0-9].[0-9]* | [0-9][0-9].[0-9]*) return 0 ;; esac
  return 1
}

# aionas_up_unparsed: count one result nobody could read. A local number under
# savings/counters, NOT the queue: the gateway's counter list does not know this
# name yet and rejects the whole batch (and the flush then drops every pending
# row), so it never goes through aionas_counter_inc.
aionas_up_unparsed() {
  _un_d="$(aionas_savings_dir)/counters"
  aionas_mkdir "$_un_d" || return 0
  _un_n=$(cat "$_un_d/usage_probe_unparsed" 2>/dev/null)
  aionas_is_uint "${_un_n:-x}" || _un_n=0
  [ "$_un_n" -lt 1000000000 ] || return 0
  printf '%s\n' $((_un_n + 1)) | aionas_write_atomic "$_un_d/usage_probe_unparsed"
  return 0
}

# aionas_up_stop_group: stop the child and everything it started. The child
# runs in its own process group (set -m, see aionas_up_run), so TERM goes to the
# whole group, then KILL after a 1 s grace. The plain-pid kill is the fallback
# for a shell that cannot make groups (Git Bash).
aionas_up_stop_group() {
  [ -n "$_up_pid" ] || return 0
  kill -TERM -- "-$_up_pid" 2>/dev/null
  kill -TERM "$_up_pid" 2>/dev/null
  sleep 1
  if kill -0 -- "-$_up_pid" 2>/dev/null || kill -0 "$_up_pid" 2>/dev/null; then
    kill -KILL -- "-$_up_pid" 2>/dev/null
    kill -KILL "$_up_pid" 2>/dev/null
  fi
  wait "$_up_pid" 2>/dev/null
  _up_pid=""
  return 0
}

# aionas_up_cleanup: stop the child group (TERM, 1 s, KILL), remove this run's
# files by name, release the lock. Safe to call twice.
aionas_up_cleanup() {
  aionas_up_stop_group
  if [ -n "$_up_out" ]; then rm -f "$_up_out"; _up_out=""; fi
  if [ -n "$_up_body" ]; then rm -f "$_up_body"; _up_body=""; fi
  if [ -n "$_up_resp" ]; then rm -f "$_up_resp"; _up_resp=""; fi
  if [ -n "$_up_lockheld" ]; then aionas_lock_release usage-probe; _up_lockheld=""; fi
  return 0
}

# aionas_up_run: the whole hook. Always returns 0 and prints nothing.
aionas_up_run() {
  aionas_enroll_has_alias || return 0
  aionas_enroll_gateway >/dev/null 2>&1 || return 0
  _r_dir=$(aionas_savings_dir)
  aionas_mkdir "$_r_dir" || return 0
  _r_now=$(aionas_now)
  aionas_up_stamp_fresh "$_r_now" && return 0
  aionas_up_tap_fresh "$_r_now" && return 0

  # The Claude login file: an API key or no subscription has no plan figure
  # (and /usage would print the cost view), so nothing is started for it. A
  # login file with no oauthAccount.accountUuid (or no login file) is an API-key
  # or gateway-routed member: no child is started.
  _r_acct="" _r_org="" _r_orgname=""
  _r_cj="${CLAUDE_CONFIG_DIR:-$(aionas_home)}/.claude.json"
  [ -f "$_r_cj" ] || return 0
  if [ -f "$_r_cj" ]; then
    _r_flat=$(aionas_json_flatten "$_r_cj" 2>/dev/null) || _r_flat=""
    _r_fields=$(printf '%s\n' "$_r_flat" | awk -F '\t' '
      $1 == "oauthAccount.billingType" { bt = $3 }
      $1 == "oauthAccount.accountUuid" { u = $3 }
      $1 == "oauthAccount.organizationUuid" && $2 == "s" { ou = $3 }
      END { printf "%s\037%s\037%s\n", bt, u, ou }')
    IFS="$(printf '\037')" read -r _r_bt _r_acct _r_org <<EOF
$_r_fields
EOF
    case "$_r_bt" in api | none) return 0 ;; esac
    [ -n "$_r_acct" ] || return 0
    . "$AIONAS_LIB/claude-account.sh" 2>/dev/null || return 0
    _r_acct=$(_pr_uuid "$_r_acct")
    _r_org=$(_pr_uuid "$_r_org")
    _r_orgname=$(printf '%s\n' "$_r_flat" | awk -F '\t' '$1 == "oauthAccount.organizationName" && $2 == "s" { print $3; exit }' | _pr_clean_name)
  fi

  _r_bin=$(aionas_up_find_bin) || return 0

  aionas_lock_try usage-probe 120 || return 0
  _up_lockheld=1
  trap 'aionas_up_cleanup' EXIT
  trap 'aionas_up_cleanup; exit 0' HUP INT TERM
  # Another start may have won the race between the first check and the lock.
  aionas_up_stamp_fresh "$_r_now" && return 0
  aionas_up_tap_fresh "$_r_now" && return 0

  # The fixed private working folder (the child leaves one empty memory/ dir
  # under the projects folder of its cwd, so it always runs from the same place).
  _r_pdir="$(aionas_agent_dir)/state/usage-probe"
  [ ! -L "$_r_pdir" ] || return 0
  aionas_mkdir "$_r_pdir" || return 0
  [ -d "$_r_pdir" ] && [ ! -L "$_r_pdir" ] || return 0
  chmod 700 "$_r_pdir" 2>/dev/null
  # Leftovers of a killed start, by exact name.
  for _r_f in "$_r_pdir"/out.* "$_r_pdir"/body.* "$_r_pdir"/resp.*; do
    case "${_r_f##*.}" in '' | *[!0-9]*) continue ;; esac
    if [ -f "$_r_f" ] || [ -L "$_r_f" ]; then rm -f "$_r_f"; fi
  done

  _up_out="$_r_pdir/out.$$"
  (umask 077; set -C; : >"$_up_out") 2>/dev/null || { _up_out=""; return 0; }

  # The stamp goes down BEFORE the child starts: a hung or failed run is not
  # retried before the hour is over.
  printf '%s\n' "$_r_now" | aionas_write_atomic "$(aionas_savings_dir)/usage-probe.last" || return 0

  # Job control makes the background child the leader of its own process group
  # (pgid = its pid), so a timeout or an oversize result can stop every process
  # it started, not just the first one.
  set -m 2>/dev/null
  ( cd "$_r_pdir" && AIONAS_USAGE_PROBE=1 exec "$_r_bin" -p "/usage" --no-session-persistence --output-format json ) </dev/null >"$_up_out" 2>/dev/null &
  _up_pid=$!
  set +m 2>/dev/null

  _r_limit=$AIONAS_UP_TIMEOUT
  case "${AIONAS_USAGE_PROBE_TIMEOUT:-}" in
    '' | *[!0-9]*) ;;
    *) if [ "$AIONAS_USAGE_PROBE_TIMEOUT" -ge 1 ] && [ "$AIONAS_USAGE_PROBE_TIMEOUT" -le "$AIONAS_UP_TIMEOUT" ]; then _r_limit=$AIONAS_USAGE_PROBE_TIMEOUT; fi ;;
  esac
  _r_t0=$(date +%s)
  while kill -0 "$_up_pid" 2>/dev/null; do
    # Whole seconds: "more than the limit" means at least the limit has passed.
    if [ $(($(date +%s) - _r_t0)) -gt "$_r_limit" ]; then
      # Too slow: stop it and send nothing; partial output is never parsed.
      aionas_up_cleanup
      return 0
    fi
    # Too much output: stop it now, so a flooding child cannot fill the disk
    # before the timeout. Counted like any other unreadable result.
    _r_size=$(wc -c <"$_up_out" 2>/dev/null | tr -d ' ')
    if aionas_is_uint "${_r_size:-x}" && [ "$_r_size" -gt "$AIONAS_UP_MAX_BYTES" ]; then
      aionas_up_cleanup
      aionas_up_unparsed
      return 0
    fi
    sleep 0.2 2>/dev/null || sleep 1
  done
  wait "$_up_pid" 2>/dev/null
  _r_rc=$?
  _up_pid=""

  _r_size=$(wc -c <"$_up_out" 2>/dev/null | tr -d ' ')
  if [ "$_r_rc" != 0 ] || ! aionas_is_uint "${_r_size:-x}" || [ "$_r_size" -gt "$AIONAS_UP_MAX_BYTES" ]; then
    aionas_up_unparsed; return 0
  fi
  _r_flat=$(aionas_json_flatten "$_up_out" 2>/dev/null) || { aionas_up_unparsed; return 0; }
  if [ "$(printf '%s\n' "$_r_flat" | aionas_json_get local_command)" != usage ] ||
    [ "$(printf '%s\n' "$_r_flat" | aionas_json_type local_command)" != s ] ||
    [ "$(printf '%s\n' "$_r_flat" | aionas_json_type result)" != s ]; then
    aionas_up_unparsed; return 0
  fi
  _r_now=$(aionas_now)
  _r_parsed=$(printf '%s\n' "$_r_flat" | aionas_json_get result | aionas_json_unescape |
    awk -v now="$_r_now" -f "$AIONAS_LIB/time.awk" -f "$AIONAS_LIB/usage-probe.awk") || _r_parsed=""
  _r_flat=""
  if [ -z "$_r_parsed" ]; then aionas_up_unparsed; return 0; fi
  IFS="$(printf '\037')" read -r _r_pct _r_zone _r_w1 _r_w2 <<EOF
$_r_parsed
EOF
  aionas_up_pct_ok "$_r_pct" || { aionas_up_unparsed; return 0; }
  _r_reset=$(aionas_up_resets "$_r_zone" "$_r_w1" "$_r_w2" "$_r_now")
  _r_observed=$(aionas_up_iso "$_r_now")
  [ -n "$_r_observed" ] || return 0

  _r_who=""
  [ -n "$_r_acct" ] && _r_who=",\"account_uuid\":\"$_r_acct\""
  [ -n "$_r_org" ] && _r_who="$_r_who,\"organization_uuid\":\"$_r_org\""
  [ -n "$_r_orgname" ] && _r_who="$_r_who,\"organization_name\":\"$_r_orgname\""
  _r_win="\"kind\":\"weekly_all\",\"window_minutes\":10080,\"used_percent\":$_r_pct"
  [ -n "$_r_reset" ] && _r_win="$_r_win,\"resets_at\":\"$_r_reset\""
  _up_body="$_r_pdir/body.$$"
  _up_resp="$_r_pdir/resp.$$"
  printf '{"tool":"claude_code","source":"usage_cmd","observed_at":"%s"%s,"windows":[{%s}]}' \
    "$_r_observed" "$_r_who" "$_r_win" >"$_up_body"
  aionas_http POST /cc-quota/v1/samples "$_up_body" "$_up_resp" >/dev/null 2>&1
  return 0
}
