# aionas-savings: the limit guard (AIO-1083, wave 33). POSIX sh; also bash
# 3.2 and Git Bash. Sourced after lib/aionas.sh (tests), or run by the mod by
# argument vector (no shell parses anything the person typed):
#
#   bash lib/limit-guard.sh state [SESSION_ID]
#       One line for the mod, names and numbers only:
#         limit <level> <source> <pct> <reset epoch>
#       level  off         the guard does not act: the gateway does not know
#                          limit_guard yet (no "limit_guard" capability), or
#                          the method is off, released or bypassed for this
#                          person
#              unmeasured  no fresh reading (F10): no warning, no switch
#              ok          below the warn line
#              warn        at or above the warn line (80 %): the band warns,
#                          sub-agents run on Sonnet, effort stays at high
#              suggest     at or above 90 %: also ONE suggestion of
#                          /model sonnet; the main model is never changed
#                          (Tal, 19.11.2026)
#              full        at 100 %
#       source five_hour (Claude's 5-hour window) | fable_week (Fable's
#              weekly cap) | -; the more severe of the two is shown.
#       Prints nothing on a computer the one install never enrolled, and
#       nothing under Cursor (its status line and /usage are Claude Code's).
#   printf '%s' "$usage_text" | bash lib/limit-guard.sh fable-record
#       Keep the Fable weekly figure of a /usage result text (see
#       aionas_lg_fable_record). Prints nothing.
#
# What it reads, all local (it never calls the gateway for a reading):
#   ~/.aionas/agent/state/plan-usage/claude5h.last   "<pct>|<reset>|<at>",
#       written by the gateway's status-line tap (AIO-1082) with the latest
#       rate_limits.five_hour of Claude Code's status-line input
#   <savings dir>/usage-probe-fable.last             the same shape, from the
#       "Current week (Fable):" line of the plugin's own /usage probe
# A reading whose window is already over (reset <= now), that was taken
# before its window began or in the future, or that does not parse is "not
# measured": nothing is shown, nothing switches, nothing is counted.
#
# What it counts (method limit_guard, numbers only, only while the gateway's
# policy lists the limit_guard capability):
#   fired           once per window the guard acted on (the warn line crossed)
#   skipped         once per window that crossed the line while the method was
#                   off, released or bypassed for this person
#   window_reached  once per watched window that reached 100 %
#   window_reset    once per watched window that ended below 100 %
# Its own state: <savings dir>/limit-guard.tsv, one row per watched window:
#   source reset acted reached skipped

AIONAS_LG_SUGGEST=90
AIONAS_LG_FIVE_SPAN=18000
AIONAS_LG_WEEK_SPAN=604800
# A reset time this close to the watched one is the same window.
AIONAS_LG_SLACK=600

# aionas_lg_warn: the warn line, 80 %. AIONAS_LIMIT_GUARD_WARN_PCT (1-89) sets
# a lower test line (the acceptance run on staging); anything else is ignored.
aionas_lg_warn() {
  _lw=${AIONAS_LIMIT_GUARD_WARN_PCT:-}
  if aionas_is_uint "$_lw" && [ "$_lw" -ge 1 ] && [ "$_lw" -le 89 ]; then echo "$_lw"; else echo 80; fi
}

aionas_lg_five_file() { echo "$(aionas_agent_dir)/state/plan-usage/claude5h.last"; }
aionas_lg_fable_file() { echo "$(aionas_savings_dir)/usage-probe-fable.last"; }

# aionas_lg_read FILE SPAN NOW: print "<whole pct> <reset>" for a fresh
# reading of a window SPAN seconds long; exit 1 for anything else (F10).
aionas_lg_read() {
  [ -f "$1" ] || return 1
  awk -F '|' -v span="$2" -v now="$3" -v slack="$AIONAS_LG_SLACK" '
    NR == 1 {
      if (NF != 3 || $1 !~ /^[0-9]+(\.[0-9]+)?$/ || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/) exit 1
      if (length($1) > 8 || length($2) > 12 || length($3) > 12) exit 1
      r = $2 + 0; at = $3 + 0
      if (r <= now) exit 1                  # the window it describes is over
      if (r > now + span + slack) exit 1    # further ahead than one window
      if (at > now + 300) exit 1            # read in the future
      if (at < r - span - slack) exit 1     # read before this window began
      printf "%d %d\n", int($1), r
      ok = 1
      exit 0
    }
    END { exit ok ? 0 : 1 }' "$1" 2>/dev/null
}

# aionas_lg_gate SESSION_ID: 0 when the guard acts for this session; 1 when
# the gateway knows the method but it is not active for this person (off,
# released, bypassed); 2 when it has no place here (not enrolled, Cursor); 3
# when the gateway does not list the limit_guard capability (an older
# gateway, or nothing cached yet: it cannot take the counters or the
# method's switch, so the guard stays off).
aionas_lg_gate() {
  aionas_enroll_has_alias || return 2
  [ "$(aionas_client)" = cursor ] && return 2
  aionas_policy_has_capability limit_guard || return 3
  aionas_policy_active limit_guard "${1:-}" && return 0
  return 1
}

# aionas_lg_state [SESSION_ID]: the one line (see the top), after the window
# bookkeeping and its counts.
aionas_lg_state() {
  aionas_lg_gate "${1:-}"
  _ls_g=$?
  case $_ls_g in
    2) return 0 ;;
    3) printf 'limit\toff\t-\t0\t0\n'; return 0 ;;
  esac
  _ls_now=$(aionas_now)
  _ls_warn=$(aionas_lg_warn)
  _ls_5=$(aionas_lg_read "$(aionas_lg_five_file)" "$AIONAS_LG_FIVE_SPAN" "$_ls_now") || _ls_5=-
  _ls_w=$(aionas_lg_read "$(aionas_lg_fable_file)" "$AIONAS_LG_WEEK_SPAN" "$_ls_now") || _ls_w=-
  # Best effort: a held lock skips the bookkeeping, never the answer.
  if aionas_lock_try limit-guard 30; then
    _aionas_lg_track "$_ls_g" "$_ls_now" "$_ls_warn" "$_ls_5" "$_ls_w"
    aionas_lock_release limit-guard
  fi
  if [ $_ls_g -ne 0 ]; then
    printf 'limit\toff\t-\t0\t0\n'
    return 0
  fi
  printf 'five_hour %s\nfable_week %s\n' "$_ls_5" "$_ls_w" | awk -v warn="$_ls_warn" -v sug="$AIONAS_LG_SUGGEST" '
    $2 == "-" { next }
    {
      p = $2 + 0
      lv = (p >= 100) ? 4 : (p >= sug) ? 3 : (p >= warn) ? 2 : 1
      if (lv > best || (lv == best && p > bp)) { best = lv; bs = $1; bp = p; br = $3 }
    }
    END {
      split("ok warn suggest full", nm, " ")
      if (best == 0) { printf "limit\tunmeasured\t-\t0\t0\n"; exit 0 }
      printf "limit\t%s\t%s\t%d\t%d\n", nm[best], bs, bp, br
    }'
}

# _aionas_lg_track GATE NOW WARN FIVE WEEK: end the watched windows that are
# over (window_reset when the guard acted and 100 % was not reached), start
# watching a window that crossed the warn line, and count fired /
# window_reached (acting) or skipped (not active). The state file is written
# before the counts, so a crash in between loses a count, never doubles one.
_aionas_lg_track() {
  _lt_f="$(aionas_savings_dir)/limit-guard.tsv"
  _lt_in=$_lt_f
  [ -f "$_lt_in" ] || _lt_in=/dev/null
  _lt_out=$(awk -F '\t' -v gate="$1" -v now="$2" -v warn="$3" -v r5="$4" -v rw="$5" -v slack="$AIONAS_LG_SLACK" '
    BEGIN {
      if (r5 != "-") { split(r5, a, " "); have["five_hour"] = 1; pct["five_hour"] = a[1] + 0; rs["five_hour"] = a[2] + 0 }
      if (rw != "-") { split(rw, a, " "); have["fable_week"] = 1; pct["fable_week"] = a[1] + 0; rs["fable_week"] = a[2] + 0 }
    }
    NF == 5 && ($1 == "five_hour" || $1 == "fable_week") && $2 ~ /^[0-9]+$/ && !($1 in row) {
      s = $1; r = $2 + 0
      d = (s in have) ? rs[s] - r : 0
      if (d < 0) d = -d
      if (now >= r || d > slack) {
        if ($3 == 1 && $4 != 1) print "C\twindow_reset"
        next
      }
      row[s] = 1; rr[s] = r; ac[s] = ($3 == 1); re[s] = ($4 == 1); sk[s] = ($5 == 1)
    }
    END {
      for (s in have) {
        if (pct[s] < warn) continue
        if (!(s in row)) { row[s] = 1; rr[s] = rs[s]; ac[s] = 0; re[s] = 0; sk[s] = 0 }
        if (gate == 0) {
          if (!ac[s]) { ac[s] = 1; print "C\tfired" }
          if (pct[s] >= 100 && !re[s]) { re[s] = 1; print "C\twindow_reached" }
        } else if (!ac[s] && !sk[s]) { sk[s] = 1; print "C\tskipped" }
      }
      for (s in row) printf "T\t%s\t%d\t%d\t%d\t%d\n", s, rr[s], ac[s], re[s], sk[s]
    }' "$_lt_in" </dev/null 2>/dev/null) || return 0
  if [ -f "$_lt_f" ] || printf '%s\n' "$_lt_out" | grep -q '^T'; then
    aionas_mkdir "$(aionas_savings_dir)" || return 0
    printf '%s\n' "$_lt_out" | awk -F '\t' '$1 == "T" { print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 }' | aionas_write_atomic "$_lt_f" || return 0
  fi
  for _lt_c in $(printf '%s\n' "$_lt_out" | awk -F '\t' '$1 == "C" { print $2 }'); do
    aionas_counter_inc limit_guard "$_lt_c" >/dev/null 2>&1
  done
  return 0
}

# --- Fable's weekly figure ------------------------------------------------

# _aionas_lg_tzoff ZONE EPOCH: ZONE's UTC offset in seconds at EPOCH.
_aionas_lg_tzoff() {
  _tz=$(TZ="$1" date -r "$2" +%z 2>/dev/null || TZ="$1" date -d "@$2" +%z 2>/dev/null)
  case "$_tz" in
    [+-][0-9][0-9][0-9][0-9]) ;;
    *) return 1 ;;
  esac
  # The digits may lead with 0 (an octal look-alike): compute from the parts.
  _tz_h=${_tz#?}; _tz_m=${_tz_h#??}; _tz_h=${_tz_h%??}
  _tz_s=$(((${_tz_h#0} + 0) * 3600 + (${_tz_m#0} + 0) * 60))
  case "$_tz" in -*) _tz_s=$((0 - _tz_s)) ;; esac
  echo "$_tz_s"
}

# _aionas_lg_epoch YYYY-MM-DD H M: that wall-clock time read as UTC, in epoch
# seconds (lib/time.awk).
_aionas_lg_epoch() {
  awk -v mode=epoch -v iso="$(printf '%sT%02d:%02d:00Z' "$1" "$2" "$3")" -f "$AIONAS_LIB/time.awk" </dev/null 2>/dev/null
}

# aionas_lg_fable_record: the /usage result text on stdin (decoded) ->
# usage-probe-fable.last "<pct>|<reset>|<now>". Only the one line
#   Current week (Fable): 81% used · resets Oct 23 at 3:30pm (Asia/Jerusalem)
# is read (the line the gateway's usage-text-v2 parser reads); nothing else of
# the text is kept anywhere. Exit 1, writing nothing, when there is no such
# line (or more than one), or it does not read: the last figure stays, and
# goes stale by itself once its week is over.
aionas_lg_fable_record() {
  _fr_now=$(aionas_now)
  _fr=$(LC_ALL=C awk '
    function month(s,   i) {
      if (s !~ /^[a-z][a-z][a-z]/) return 0
      i = index("janfebmaraprmayjunjulaugsepoctnovdec", substr(s, 1, 3))
      return (i == 0 || (i - 1) % 3 != 0) ? 0 : (i + 2) / 3
    }
    { sub(/\r$/, ""); l = $0; sub(/^[ \t]+/, "", l); sub(/[ \t]+$/, "", l) }
    index(l, "Current week (Fable):") == 1 { n++; line = l }
    END {
      if (n != 1) exit 1
      rest = substr(line, 22)
      if (!match(rest, /^[ \t]*[0-9]+(\.[0-9]+)?%[ \t]+used/)) exit 1
      pct = rest; sub(/^[ \t]*/, "", pct); sub(/%.*/, "", pct)
      if (length(pct) > 8) exit 1
      i = index(rest, " resets ")
      if (i == 0) exit 1
      t = substr(rest, i + 8)
      if (!match(t, /\([^() \t]+\)$/)) exit 1
      zone = substr(t, RSTART + 1, RLENGTH - 2)
      t = tolower(substr(t, 1, RSTART - 1))
      gsub(/,/, " ", t); gsub(/ at /, " ", t); gsub(/[ \t]+/, " ", t); sub(/^ /, "", t); sub(/ $/, "", t)
      k = split(t, w, " ")
      mon = 0; day = 0
      if (k == 3) {
        mon = month(w[1]); day = w[2]; tm = w[3]
        if (!mon || day !~ /^[0-9][0-9]?$/ || day + 0 < 1 || day + 0 > 31) exit 1
      } else if (k == 1) tm = w[1]
      else exit 1
      if (tm ~ /^[0-9][0-9]?(:[0-9][0-9])?(am|pm)$/) {
        ap = substr(tm, length(tm) - 1); tm = substr(tm, 1, length(tm) - 2)
        h = tm; mi = 0
        if (index(tm, ":") > 0) { h = substr(tm, 1, index(tm, ":") - 1); mi = substr(tm, index(tm, ":") + 1) }
        h += 0; mi += 0
        if (h < 1 || h > 12) exit 1
        if (ap == "am") h = (h == 12) ? 0 : h; else h = (h == 12) ? 12 : h + 12
      } else if (tm ~ /^[0-9][0-9]?:[0-9][0-9]$/) {
        h = substr(tm, 1, index(tm, ":") - 1) + 0; mi = substr(tm, index(tm, ":") + 1) + 0
        if (h > 23) exit 1
      } else exit 1
      if (mi > 59) exit 1
      printf "%s %d %d %d %d %s\n", pct, mon, day + 0, h, mi, zone
    }') || return 1
  # Split with read (no glob: the zone comes from the text).
  _fr_x=""
  read -r _fr_pct _fr_mon _fr_day _fr_h _fr_mi _fr_zone _fr_x <<AIONAS_LG_FR
$_fr
AIONAS_LG_FR
  [ -n "$_fr_zone" ] && [ -z "$_fr_x" ] || return 1
  case "$_fr_zone" in '' | *[!A-Za-z0-9_+/-]* | *..* | /*) return 1 ;; esac
  [ ${#_fr_zone} -le 64 ] || return 1
  case "$_fr_zone" in
    UTC | GMT | Z | Etc/UTC | Etc/GMT) _fr_zone=UTC ;;
    *) if [ -d /usr/share/zoneinfo ] && [ ! -f "/usr/share/zoneinfo/$_fr_zone" ]; then return 1; fi ;;
  esac
  _fr_off=$(_aionas_lg_tzoff "$_fr_zone" "$_fr_now") || return 1
  # The wall-clock reset read as UTC, in the year (or, for a time with no
  # date, on the day) that puts it between a day ago and eight days ahead.
  _fr_lday=$(aionas_day_utc $((_fr_now + _fr_off))) || return 1
  _fr_y=${_fr_lday%%-*}
  _fr_naive=""
  if [ "$_fr_mon" = 0 ]; then
    _fr_naive=$(_aionas_lg_epoch "${_fr_lday}" "$_fr_h" "$_fr_mi") || return 1
    [ $((_fr_naive - _fr_off)) -ge $((_fr_now - 3600)) ] || _fr_naive=$((_fr_naive + 86400))
  else
    for _fr_yy in $((_fr_y - 1)) "$_fr_y" $((_fr_y + 1)); do
      _fr_c=$(_aionas_lg_epoch "$(printf '%04d-%02d-%02d' "$_fr_yy" "$_fr_mon" "$_fr_day")" "$_fr_h" "$_fr_mi") || continue
      _fr_c=$((_fr_c - _fr_off))
      if [ "$_fr_c" -ge $((_fr_now - 86400)) ] && [ "$_fr_c" -le $((_fr_now + 8 * 86400)) ]; then
        _fr_naive=$((_fr_c + _fr_off))
        break
      fi
    done
  fi
  aionas_is_uint "$_fr_naive" || return 1
  # The offset on the reset day itself (a change of summer time in between).
  _fr_off=$(_aionas_lg_tzoff "$_fr_zone" $((_fr_naive - _fr_off))) || return 1
  _fr_reset=$((_fr_naive - _fr_off))
  [ "$_fr_reset" -gt "$_fr_now" ] || return 1
  aionas_mkdir "$(aionas_savings_dir)" || return 1
  printf '%s|%s|%s' "$_fr_pct" "$_fr_reset" "$_fr_now" | aionas_write_atomic "$(aionas_lg_fable_file)"
}

# Run by the mod (or a hook) as a script: load the library, then the verb.
case "${0##*/}" in
  limit-guard.sh)
    set -u
    . "$(dirname "$0")/aionas.sh" || exit 0
    case "${1:-}" in
      state) aionas_lg_state "${2:-}" ;;
      fable-record) aionas_lg_fable_record >/dev/null 2>&1 ;;
      *) exit 2 ;;
    esac
    exit 0
    ;;
esac
