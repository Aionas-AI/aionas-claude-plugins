# aionas-savings counters queue (AIO-855, W24-4, W24-P2).
#
# Hooks count with aionas_counter_inc; aionas_counters_flush sends the sums at
# most once an hour to POST /enroll/v1/savings/counters, with the same limits
# as the policy sync (3 s connect, 5 s total, no retry). Only closed-list
# names and whole numbers are ever queued or sent: never content.
#
# Files under $(aionas_savings_dir)/counters:
#   queue.tsv        appended by hooks: day method counter value
#   batch.*          queue files taken by a flush
#   pending.tsv      the summed rows not yet accepted by the server
#   last_attempt     epoch of the last send attempt (the hourly clock)
#   last_sent        epoch of the last accepted send
#   dropped          rows the server refused (400/413), summed

AIONAS_COUNTERS_INTERVAL=${AIONAS_COUNTERS_INTERVAL:-3600}

# aionas_counter_inc METHOD COUNTER [N]: add N (default 1) for today (UTC).
# Exit 2, queueing nothing, for a name outside the closed lists or a bad N.
aionas_counter_inc() {
  aionas_is_method "$1" || return 2
  aionas_is_counter "$2" || return 2
  # The band's /compact count (AIO-1023) belongs to the handoff method.
  { [ "$2" != compact_pressed ] || [ "$1" = handoff ]; } || return 2
  _ci_n=${3:-1}
  aionas_is_uint "$_ci_n" || return 2
  [ "$_ci_n" -ge 1 ] && [ "$_ci_n" -le 1000000 ] || return 2
  _ci_dir="$(aionas_savings_dir)/counters"
  aionas_mkdir "$_ci_dir" || return 1
  # One short line per write: appends of this size are atomic.
  printf '%s\t%s\t%s\t%s\n' "$(aionas_day_utc)" "$1" "$2" "$_ci_n" >>"$_ci_dir/queue.tsv"
}

# aionas_counters_due: exit 0 when an hour has passed since the last attempt.
aionas_counters_due() {
  _cd_t=$(cat "$(aionas_savings_dir)/counters/last_attempt" 2>/dev/null)
  aionas_is_uint "$_cd_t" || return 0
  [ $(($(aionas_now) - _cd_t)) -ge "$AIONAS_COUNTERS_INTERVAL" ]
}

# aionas_counters_flush [--force]: when due (or forced), sum everything queued
# and send it in one request. Exit 0 when sent or nothing to send; 1 when it
# failed (the rows stay for the next hourly send); 3 when not enrolled; 4 when
# not due or another flush runs; 5 when the server refused the rows (dropped).
aionas_counters_flush() {
  _cf_dir="$(aionas_savings_dir)/counters"
  [ -d "$_cf_dir" ] || return 0
  if [ "${1:-}" != --force ]; then aionas_counters_due || return 4; fi
  aionas_lock_try counters 60 || return 4
  _cf_now=$(aionas_now)
  echo "$_cf_now" | aionas_write_atomic "$_cf_dir/last_attempt"
  if [ -f "$_cf_dir/queue.tsv" ]; then
    mv -f "$_cf_dir/queue.tsv" "$_cf_dir/batch.$_cf_now.$$"
  fi
  # Sum pending + batches into one pending file, then drop the batches.
  # (A crash between the two steps can count a batch twice, never lose it.)
  _cf_batches=$(cd "$_cf_dir" && ls -1 2>/dev/null | grep '^batch\.' || true)
  _cf_oldest=$(aionas_day_utc $((_cf_now - 30 * 86400)))
  (
    cd "$_cf_dir" || exit 1
    # shellcheck disable=SC2086
    cat pending.tsv compact.tsv $_cf_batches 2>/dev/null
  ) | awk -F '\t' -v methods="$AIONAS_METHODS" -v counters="$AIONAS_COUNTERS" -v oldest="$_cf_oldest" '
      BEGIN {
        n = split(methods, a, " "); for (i = 1; i <= n; i++) okm[a[i]] = 1
        n = split(counters, a, " "); for (i = 1; i <= n; i++) okc[a[i]] = 1
      }
      NF == 4 && $1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ && $1 >= oldest && ($2 in okm) && ($3 in okc) && $4 ~ /^[0-9]+$/ && length($4) <= 12 {
        k = $1 "\t" $2 "\t" $3
        if (!(k in sum)) order[++nk] = k
        sum[k] += $4
      }
      END { for (i = 1; i <= nk; i++) printf "%s\t%d\n", order[i], sum[order[i]] }' >"$_cf_dir/.pending.$$"
  # compact_pressed (AIO-1023) travels in a request of its own, so a gateway
  # that does not know that name yet refuses only those rows, never the
  # day's other counters.
  awk -F '\t' '$3 != "compact_pressed"' "$_cf_dir/.pending.$$" >"$_cf_dir/pending.tsv"
  awk -F '\t' '$3 == "compact_pressed"' "$_cf_dir/.pending.$$" >"$_cf_dir/compact.tsv"
  rm -f "$_cf_dir/.pending.$$"
  for _cf_b in $_cf_batches; do rm -f "$_cf_dir/$_cf_b"; done
  [ -s "$_cf_dir/pending.tsv" ] || rm -f "$_cf_dir/pending.tsv"
  [ -s "$_cf_dir/compact.tsv" ] || rm -f "$_cf_dir/compact.tsv"
  _cf_rc=0
  if [ -f "$_cf_dir/pending.tsv" ]; then
    _aionas_counters_send "$_cf_dir/pending.tsv" "$_cf_dir"
    _cf_rc=$?
    [ $_cf_rc -ne 0 ] || echo "$_cf_now" | aionas_write_atomic "$_cf_dir/last_sent"
  fi
  # Not enrolled, or a send that failed: the compact rows wait with the rest.
  if [ -f "$_cf_dir/compact.tsv" ] && [ $_cf_rc -ne 3 ] && [ $_cf_rc -ne 1 ]; then
    _aionas_counters_send "$_cf_dir/compact.tsv" "$_cf_dir"
    _cf_c=$?
    [ $_cf_c -eq 0 ] || _cf_rc=$_cf_c
  fi
  aionas_lock_release counters
  return $_cf_rc
}

# _aionas_counters_send FILE DIR: one request with the summed rows of FILE. The
# file is removed when the server accepted it (0) or refused it (5, counted in
# dropped); kept for the next hourly send when it failed (1) or the computer is
# not enrolled (3).
_aionas_counters_send() {
  _cs_body="$2/.body.$$"
  aionas_counters_body <"$1" >"$_cs_body"
  _cs_resp="$2/.resp.$$"
  _cs_code=$(aionas_http POST /enroll/v1/savings/counters "$_cs_body" "$_cs_resp")
  _cs_rc=$?
  rm -f "$_cs_body" "$_cs_resp"
  if [ $_cs_rc -eq 0 ]; then
    rm -f "$1"
    return 0
  fi
  case "$_cs_code" in
    400 | 413)
      _cs_d=$(cat "$2/dropped" 2>/dev/null)
      aionas_is_uint "$_cs_d" || _cs_d=0
      echo $((_cs_d + $(awk 'END { print NR }' "$1"))) | aionas_write_atomic "$2/dropped"
      rm -f "$1"
      return 5
      ;;
  esac
  [ $_cs_rc -eq 3 ] && return 3
  return 1
}

# aionas_counters_body: summed rows (day method counter value) on stdin -> the
# request body {"plugin_version":"…","counters":[{day,method_id,counter,value}]}.
aionas_counters_body() {
  awk -F '\t' -v ver="$(aionas_plugin_version 2>/dev/null)" '
    BEGIN { if (ver !~ /^[0-9A-Za-z.+-]+$/) ver = ""; printf "{" ; if (ver != "") printf "\"plugin_version\":\"%s\",", ver; printf "\"counters\":[" }
    NF == 4 { printf "%s{\"day\":\"%s\",\"method_id\":\"%s\",\"counter\":\"%s\",\"value\":%d}", (n++ ? "," : ""), $1, $2, $3, $4 }
    END { printf "]}\n" }'
}
