# aionas-savings counters queue (AIO-855, W24-4, W24-P2; AIO-1073).
#
# Hooks count with aionas_counter_inc; aionas_counters_flush sends the sums at
# most once an hour to POST /enroll/v1/savings/counters, with the same limits
# as the policy sync (3 s connect, 5 s total, no retry). Only closed-list
# names and whole numbers are ever queued or sent: never content.
#
# The server stores a counter's value as this computer's RUNNING TOTAL for
# that UTC day and replaces it on each send (it never lowers it), so what is
# sent is always the total, never an increment (AIO-1004, W31-30).
#
# AIO-1073: each increment is a spool file of its own, written whole and
# renamed into place (no append can race a flush). Under the counters lock a
# flush folds the spool files into totals.tsv, which holds the running totals
# per day, method and counter AND the names of the spool files they include,
# written in one rename; the spool files are removed only after that rename
# succeeded. A flush that dies in between leaves files the next flush finds
# in the list and removes without counting them again; a write that fails
# keeps everything as it was.
#
# Files under $(aionas_savings_dir)/counters:
#   spool/*.ev       one increment each: day method counter value
#   totals.tsv       the running totals (day method counter total) and
#                    "consumed <spool file>" lines; today's totals stay after
#                    a send, past days are pruned once confirmed
#   pending.tsv      what is sent: the totals, without compact_pressed
#   compact.tsv      compact_pressed's totals (sent in a request of their own)
#   *.tsv.ok         a copy of the totals the server last accepted (an
#                    unchanged total is not sent again)
#   last_attempt     epoch of the last send attempt (the hourly clock)
#   last_sent        epoch of the last accepted send
#   dropped          rows the server refused (400/413), summed
#   cursor/          the same files for what was counted under Cursor
#                    (AIO-1077): a queue of its own, never mixed into Claude
#                    Code's. Its rows are sent, each with "client":"cursor",
#                    only when the gateway's policy lists counters_client;
#                    until then they stay here (not sent, not dropped; days
#                    older than 30 are pruned like Claude Code's). Claude
#                    Code's rows never carry "client" (an older gateway
#                    refuses an unknown field), so their body is the 0.6.1
#                    one byte for byte.

AIONAS_COUNTERS_INTERVAL=${AIONAS_COUNTERS_INTERVAL:-3600}

# aionas_counter_inc METHOD COUNTER [N]: add N (default 1) for today (UTC),
# to Cursor's queue when this hook runs under Cursor (aionas_client).
# Exit 2, queueing nothing, for a name outside the closed lists or a bad N.
aionas_counter_inc() {
  aionas_is_method "$1" || return 2
  aionas_is_counter "$2" || return 2
  # The band's /compact count (AIO-1023) belongs to the handoff method.
  { [ "$2" != compact_pressed ] || [ "$1" = handoff ]; } || return 2
  # The 5-hour window outcomes (AIO-1083) belong to limit_guard; the gateway
  # pins them to that method and refuses them under any other.
  case $2 in window_reset | window_reached) [ "$1" = limit_guard ] || return 2 ;; esac
  _ci_n=${3:-1}
  aionas_is_uint "$_ci_n" || return 2
  [ "$_ci_n" -ge 1 ] && [ "$_ci_n" -le 1000000 ] || return 2
  _ci_dir="$(aionas_savings_dir)/counters"
  [ "$(aionas_client)" = cursor ] && _ci_dir="$_ci_dir/cursor"
  aionas_spool_put "$_ci_dir/spool" "$(printf '%s\t%s\t%s\t%s' "$(aionas_day_utc)" "$1" "$2" "$_ci_n")"
}

# aionas_counters_due: exit 0 when an hour has passed since the last attempt.
aionas_counters_due() {
  _cd_t=$(cat "$(aionas_savings_dir)/counters/last_attempt" 2>/dev/null)
  aionas_is_uint "$_cd_t" || return 0
  [ $(($(aionas_now) - _cd_t)) -ge "$AIONAS_COUNTERS_INTERVAL" ]
}

# _aionas_counters_commit DIR NOW: fold the spool into totals.tsv (see the
# top). Exit 0 when committed or nothing new; 1 when a write failed (nothing
# changed, no input removed).
_aionas_counters_commit() {
  _cc_sp="$1/spool" _cc_tot="$1/totals.tsv"
  # What a 0.6.0 build queued (queue.tsv, a flush's batch.*) joins the spool;
  # its pending.tsv / compact.tsv are the totals until totals.tsv exists.
  for _cc_f in "$1"/queue.tsv "$1"/batch.*; do
    [ -f "$_cc_f" ] || continue
    aionas_mkdir "$_cc_sp" && mv -f "$_cc_f" "$_cc_sp/0.$$.${RANDOM:-0}${RANDOM:-0}.ev" || return 1
  done
  if [ -f "$_cc_tot" ]; then _cc_base=totals.tsv; else _cc_base="pending.tsv compact.tsv"; fi
  # Inputs a committed total already holds are removed, never counted again.
  _cc_was=$(awk -F '\t' 'NF == 2 && $1 == "consumed" && $2 ~ /^[A-Za-z0-9_-][A-Za-z0-9._-]*\.ev$/ { printf "%s ", $2 }' "$_cc_tot" 2>/dev/null)
  _cc_left=""
  for _cc_f in $_cc_was; do
    rm -f "$_cc_sp/$_cc_f"
    [ -e "$_cc_sp/$_cc_f" ] && _cc_left="$_cc_left $_cc_f"
  done
  _cc_new=$(aionas_spool_list "$_cc_sp" | awk -v was=" $_cc_was" 'index(was, " " $0 " ") == 0 { printf "%s ", $0 }')
  [ -z "$_cc_new$_cc_was" ] && [ -f "$_cc_tot" ] && return 0
  _cc_oldest=$(aionas_day_utc $(($2 - 30 * 86400)))
  # shellcheck disable=SC2086
  if ! { (cd "$1" && cat $_cc_base 2>/dev/null </dev/null; [ -z "$_cc_new" ] || { cd "$_cc_sp" && cat $_cc_new; }) |
    awk -F '\t' -v methods="$AIONAS_METHODS" -v counters="$AIONAS_COUNTERS" -v oldest="$_cc_oldest" '
      BEGIN {
        n = split(methods, a, " "); for (i = 1; i <= n; i++) okm[a[i]] = 1
        n = split(counters, a, " "); for (i = 1; i <= n; i++) okc[a[i]] = 1
      }
      NF == 4 && $1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ && $1 >= oldest && ($2 in okm) && ($3 in okc) && $4 ~ /^[0-9]+$/ && length($4) <= 12 {
        k = $1 "\t" $2 "\t" $3
        if (!(k in sum)) order[++nk] = k
        sum[k] += $4
      }
      END { for (i = 1; i <= nk; i++) printf "%s\t%d\n", order[i], sum[order[i]] }' | LC_ALL=C sort &&
    for _cc_f in $_cc_left $_cc_new; do printf 'consumed\t%s\n' "$_cc_f"; done
  } | aionas_write_atomic "$_cc_tot"; then
    return 1
  fi
  for _cc_f in $_cc_new; do rm -f "$_cc_sp/$_cc_f"; done
  return 0
}

# _aionas_counters_keep DIR MODE CLASS: rewrite totals.tsv without CLASS's
# rows (MODE drop) or without its rows of past UTC days (MODE prune). CLASS
# is compact (compact_pressed) or pending (every other counter).
_aionas_counters_keep() {
  awk -F '\t' -v mode="$2" -v cls="$3" -v today="$(aionas_day_utc)" '
    NF != 4 { print; next }
    { mine = ((cls == "compact") == ($3 == "compact_pressed")) }
    mine && (mode == "drop" || $1 < today) { next }
    { print }' "$1/totals.tsv" | aionas_write_atomic "$1/totals.tsv"
}

# _aionas_counters_view DIR CLASS: CLASS's totals into DIR/CLASS.tsv (no file
# when it has none).
_aionas_counters_view() {
  awk -F '\t' -v cls="$2" 'NF == 4 && ((cls == "compact") == ($3 == "compact_pressed"))' "$1/totals.tsv" 2>/dev/null | aionas_write_atomic "$1/$2.tsv"
  [ -s "$1/$2.tsv" ] || rm -f "$1/$2.tsv" "$1/$2.tsv.ok"
}

# aionas_counters_flush [--force]: when due (or forced), fold the spool into
# the totals and send them. Exit 0 when sent or nothing to send; 1 when it
# failed (the totals stay for the next hourly send); 3 when not enrolled; 4
# when not due, another flush runs or the hook's deadline is near; 5 when the
# server refused the rows (dropped).
aionas_counters_flush() {
  _cf_dir="$(aionas_savings_dir)/counters"
  [ -d "$_cf_dir" ] || return 0
  if [ "${1:-}" != --force ]; then aionas_counters_due || return 4; fi
  aionas_flush_may_send || return 4
  aionas_lock_try counters 60 || return 4
  _cf_now=$(aionas_now)
  echo "$_cf_now" | aionas_write_atomic "$_cf_dir/last_attempt"
  if ! _aionas_counters_commit "$_cf_dir" "$_cf_now"; then
    aionas_lock_release counters
    return 1
  fi
  _aionas_counters_flush_dir "$_cf_dir" "$_cf_now" ''
  _cf_rc=$?
  # Cursor's queue (AIO-1077): folded every time, sent only to a gateway
  # that accepts "client", and never after a failed send, not enrolled or
  # the deadline above.
  if [ -d "$_cf_dir/cursor" ] && _aionas_counters_commit "$_cf_dir/cursor" "$_cf_now" &&
    [ $_cf_rc -ne 1 ] && [ $_cf_rc -ne 3 ] && [ $_cf_rc -ne 4 ] && aionas_policy_has_capability counters_client; then
    _aionas_counters_flush_dir "$_cf_dir/cursor" "$_cf_now" cursor
    _cf_c=$?
    [ $_cf_c -eq 0 ] || _cf_rc=$_cf_c
  fi
  aionas_lock_release counters
  return $_cf_rc
}

# _aionas_counters_flush_dir DIR NOW CLIENT: send DIR's folded totals, one
# request per class. CLIENT is empty for Claude Code (no "client" field) or
# cursor. Exit codes as aionas_counters_flush.
_aionas_counters_flush_dir() {
  # compact_pressed (AIO-1023) travels in a request of its own, so a gateway
  # that does not know that name yet refuses only those rows, never the
  # day's other counters. Not enrolled, a failed send or the deadline: the
  # compact rows wait with the rest.
  _fd_rc=0
  for _fd_cls in pending compact; do
    _aionas_counters_view "$1" "$_fd_cls"
    [ -f "$1/$_fd_cls.tsv" ] || continue
    [ $_fd_rc -ne 1 ] && [ $_fd_rc -ne 3 ] && [ $_fd_rc -ne 4 ] || continue
    if ! aionas_flush_may_send; then _fd_rc=4; continue; fi
    _aionas_counters_send "$1/$_fd_cls.tsv" "$1" "$3"
    _fd_c=$?
    case $_fd_c in
      0)
        _aionas_counters_keep "$1" prune "$_fd_cls" && _aionas_counters_view "$1" "$_fd_cls"
        [ -f "$1/$_fd_cls.tsv" ] && cp -f "$1/$_fd_cls.tsv" "$1/$_fd_cls.tsv.ok"
        [ "$_fd_cls" = compact ] || echo "$2" | aionas_write_atomic "$1/last_sent"
        ;;
      5)
        _aionas_counters_keep "$1" drop "$_fd_cls" && rm -f "$1/$_fd_cls.tsv" "$1/$_fd_cls.tsv.ok"
        _fd_rc=5
        ;;
      *) _fd_rc=$_fd_c ;;
    esac
  done
  return $_fd_rc
}

# _aionas_counters_send FILE DIR [CLIENT]: one request with the running
# totals of FILE (each row tagged with CLIENT when given). 0 when accepted, or when FILE equals the last accepted totals (not
# sent again); 5 when the server refused it (its rows counted in dropped); 1
# when it failed; 3 when the computer is not enrolled.
_aionas_counters_send() {
  if [ -f "$1.ok" ] && cmp -s "$1" "$1.ok"; then return 0; fi
  _cs_body="$2/.body.$$"
  aionas_counters_body "${3:-}" <"$1" >"$_cs_body"
  _cs_resp="$2/.resp.$$"
  _cs_code=$(aionas_http POST /enroll/v1/savings/counters "$_cs_body" "$_cs_resp")
  _cs_rc=$?
  rm -f "$_cs_body" "$_cs_resp"
  [ $_cs_rc -eq 0 ] && return 0
  case "$_cs_code" in
    400 | 413)
      _cs_d=$(cat "$2/dropped" 2>/dev/null)
      aionas_is_uint "$_cs_d" || _cs_d=0
      echo $((_cs_d + $(awk 'END { print NR }' "$1"))) | aionas_write_atomic "$2/dropped"
      return 5
      ;;
  esac
  [ $_cs_rc -eq 3 ] && return 3
  return 1
}

# aionas_counters_body [CLIENT]: summed rows (day method counter value) on
# stdin -> the request body
# {"plugin_version":"…","counters":[{day,method_id,counter,value[,client]}]}.
# CLIENT (cursor) adds "client" to every row; empty or anything else adds
# nothing (the 0.6.1 body).
aionas_counters_body() {
  awk -F '\t' -v ver="$(aionas_plugin_version 2>/dev/null)" -v client="${1:-}" '
    BEGIN { if (ver !~ /^[0-9A-Za-z.+-]+$/) ver = ""; if (client != "cursor") client = ""; printf "{" ; if (ver != "") printf "\"plugin_version\":\"%s\",", ver; printf "\"counters\":[" }
    NF == 4 { printf "%s{\"day\":\"%s\",\"method_id\":\"%s\",\"counter\":\"%s\",\"value\":%d%s}", (n++ ? "," : ""), $1, $2, $3, $4, (client != "" ? ",\"client\":\"" client "\"" : "") }
    END { printf "]}\n" }'
}
