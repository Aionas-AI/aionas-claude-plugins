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
    cat pending.tsv $_cf_batches 2>/dev/null
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
  mv -f "$_cf_dir/.pending.$$" "$_cf_dir/pending.tsv"
  for _cf_b in $_cf_batches; do rm -f "$_cf_dir/$_cf_b"; done
  if [ ! -s "$_cf_dir/pending.tsv" ]; then
    rm -f "$_cf_dir/pending.tsv"
    aionas_lock_release counters
    return 0
  fi
  _cf_body="$_cf_dir/.body.$$"
  aionas_counters_body <"$_cf_dir/pending.tsv" >"$_cf_body"
  _cf_resp="$_cf_dir/.resp.$$"
  _cf_code=$(aionas_http POST /enroll/v1/savings/counters "$_cf_body" "$_cf_resp")
  _cf_rc=$?
  rm -f "$_cf_body" "$_cf_resp"
  if [ $_cf_rc -eq 0 ]; then
    rm -f "$_cf_dir/pending.tsv"
    echo "$_cf_now" | aionas_write_atomic "$_cf_dir/last_sent"
    aionas_lock_release counters
    return 0
  fi
  case "$_cf_code" in
    400 | 413)
      _cf_d=$(cat "$_cf_dir/dropped" 2>/dev/null)
      aionas_is_uint "$_cf_d" || _cf_d=0
      echo $((_cf_d + $(awk 'END { print NR }' "$_cf_dir/pending.tsv"))) | aionas_write_atomic "$_cf_dir/dropped"
      rm -f "$_cf_dir/pending.tsv"
      aionas_lock_release counters
      return 5
      ;;
  esac
  aionas_lock_release counters
  [ $_cf_rc -eq 3 ] && return 3
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
