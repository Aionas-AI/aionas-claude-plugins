# aionas-savings per-request records (AIO-1004, wave 31).
#
# Each method that acted on a prompt (subagent_sonnet, output_trim, handoff)
# is reported once per prompt to POST /enroll/v1/savings/requests, so the
# server can tie the day's applied figure to a request. The record is ids,
# the method name, a time, the plugin version and, where the plugin measured
# it, a token count. No prompt text, file path, command or tool output is ever
# queued or sent. The gateway prices the record; this plugin sends no cost.
#
# How it flows:
#   aionas_request_mark SID METHOD [PROMPT_ID] [TOKENS]
#       a hook or the mod says "METHOD acted now". Without a prompt id (a
#       sub-agent start or a tool result: the hook input has none) the mark
#       waits in requests/open.<sid>.
#   aionas_request_settle SID PROMPT_ID
#       the Stop hook of the turn (its input carries prompt_id) turns the
#       session's open marks into queue rows for that prompt.
#   aionas_requests_flush [START_EPOCH]
#       sends the queue, one POST per prompt per method, within a small time
#       budget (the Stop hook has 10 s); a row that could not be sent stays
#       for the next turn, a row the server refuses (400/413) is dropped.
#
# Files under $(aionas_savings_dir)/requests:
#   open.<sid>      appended by marks: method, epoch, tokens (tab separated)
#   queue.tsv       sid, prompt id, method, epoch, tokens
#   last_failed     epoch of the last failed send (retry no sooner than 5 min)
#   dropped         rows the server refused, summed

AIONAS_REQUESTS_METHODS="subagent_sonnet output_trim handoff"
AIONAS_REQUESTS_MAX_QUEUE=${AIONAS_REQUESTS_MAX_QUEUE:-200}
# The gateway refuses a record older than 45 days; keep two days.
AIONAS_REQUESTS_MAX_AGE=${AIONAS_REQUESTS_MAX_AGE:-172800}
# Start no new send after this many seconds into the hook (each send is at
# most 5 s; the hook's own limit is 10 s).
AIONAS_REQUESTS_BUDGET=${AIONAS_REQUESTS_BUDGET:-4}
AIONAS_REQUESTS_RETRY=${AIONAS_REQUESTS_RETRY:-300}
AIONAS_REQUESTS_MAX_TOKENS=1000000000

aionas_requests_dir() { echo "$(aionas_savings_dir)/requests"; }

# aionas_request_id_ok VALUE: the gateway's id grammar ^[A-Za-z0-9._:-]{1,128}$.
aionas_request_id_ok() {
  case "$1" in '' | *[!A-Za-z0-9._:-]*) return 1 ;; esac
  [ ${#1} -le 128 ]
}

# aionas_iso_utc EPOCH: 2026-11-13T10:00:00Z.
aionas_iso_utc() {
  awk -v t="$1" -f "$AIONAS_LIB/time.awk" -v mode=day </dev/null | tr -d '\n'
  printf 'T%02d:%02d:%02dZ\n' $((($1 % 86400) / 3600)) $((($1 % 3600) / 60)) $(($1 % 60))
}

# aionas_request_mark SID METHOD [PROMPT_ID] [TOKENS]: exit 2, queueing
# nothing, for a method outside the three, an id outside the grammar or a bad
# token count; 0 otherwise (also, doing nothing, on a computer that is not
# enrolled). Prints nothing.
aionas_request_mark() {
  aionas_enroll_has_alias || return 0
  _rm_sid=${1:-} _rm_m=${2:-} _rm_pid=${3:-} _rm_tok=${4:-}
  _in_list "$_rm_m" $AIONAS_REQUESTS_METHODS || return 2
  aionas_request_id_ok "$_rm_sid" || return 2
  if [ -n "$_rm_pid" ]; then aionas_request_id_ok "$_rm_pid" || return 2; fi
  if [ -n "$_rm_tok" ]; then
    aionas_is_uint "$_rm_tok" && [ "$_rm_tok" -le "$AIONAS_REQUESTS_MAX_TOKENS" ] || return 2
  fi
  _rm_dir=$(aionas_requests_dir)
  aionas_mkdir "$_rm_dir" || return 1
  if [ -n "$_rm_pid" ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$_rm_sid" "$_rm_pid" "$_rm_m" "$(aionas_now)" "$_rm_tok" >>"$_rm_dir/queue.tsv"
  else
    printf '%s\t%s\t%s\n' "$_rm_m" "$(aionas_now)" "$_rm_tok" >>"$_rm_dir/open.$_rm_sid"
  fi
}

# aionas_request_settle SID PROMPT_ID: the session's open marks become queue
# rows for PROMPT_ID (one per method, tokens summed, the first time). Without
# a usable prompt id (an older Claude Code) the marks are dropped: a record
# without its prompt cannot be tied to anything, and none is invented.
aionas_request_settle() {
  _rs_sid=${1:-} _rs_pid=${2:-}
  aionas_request_id_ok "$_rs_sid" || return 0
  _rs_dir=$(aionas_requests_dir)
  [ -f "$_rs_dir/open.$_rs_sid" ] || return 0
  _rs_tmp="$_rs_dir/.settle.$$"
  mv -f "$_rs_dir/open.$_rs_sid" "$_rs_tmp" 2>/dev/null || return 0
  if aionas_request_id_ok "$_rs_pid"; then
    awk -F '\t' -v sid="$_rs_sid" -v pid="$_rs_pid" -v methods="$AIONAS_REQUESTS_METHODS" -v maxtok="$AIONAS_REQUESTS_MAX_TOKENS" '
      BEGIN { n = split(methods, a, " "); for (i = 1; i <= n; i++) ok[a[i]] = 1 }
      ($1 in ok) && $2 ~ /^[0-9]+$/ {
        if (!($1 in at)) { order[++nk] = $1; at[$1] = $2 }
        if ($3 ~ /^[0-9]+$/) tok[$1] += $3
      }
      END {
        for (i = 1; i <= nk; i++) {
          m = order[i]; t = tok[m]; if (t > maxtok) t = maxtok
          printf "%s\t%s\t%s\t%s\t%s\n", sid, pid, m, at[m], (t > 0 ? sprintf("%d", t) : "")
        }
      }' "$_rs_tmp" >>"$_rs_dir/queue.tsv"
  fi
  rm -f "$_rs_tmp"
  return 0
}

# aionas_requests_body SID PROMPT METHOD EPOCH TOKENS: the request body.
# Every value was checked against its grammar before it was queued; this
# checks again, so a hand-edited queue line never reaches the server.
aionas_requests_body() {
  aionas_request_id_ok "$1" && aionas_request_id_ok "$2" || return 1
  _in_list "$3" $AIONAS_REQUESTS_METHODS || return 1
  aionas_is_uint "$4" || return 1
  _rb_ver=$(aionas_plugin_version 2>/dev/null)
  printf '%s\n' "$_rb_ver" | grep -Eq '^[0-9A-Za-z.+-]{1,32}$' || _rb_ver=''
  printf '{"session_id":"%s","prompt_id":"%s","method":"%s","ts":"%s"' "$1" "$2" "$3" "$(aionas_iso_utc "$4")"
  [ -n "$_rb_ver" ] && printf ',"plugin_version":"%s"' "$_rb_ver"
  if [ -n "${5:-}" ] && aionas_is_uint "$5" && [ "$5" -ge 1 ] && [ "$5" -le "$AIONAS_REQUESTS_MAX_TOKENS" ]; then printf ',"tokens":%s' "$5"; fi
  printf '}\n'
}

# aionas_requests_flush [START_EPOCH]: send the queued rows. Exit 0 when sent
# or nothing to send; 1 when a send failed (rows stay; no retry for 5 min);
# 3 when not enrolled; 4 when another flush runs or a retry is not due yet.
aionas_requests_flush() {
  _rf_dir=$(aionas_requests_dir)
  [ -s "$_rf_dir/queue.tsv" ] || return 0
  _rf_start=${1:-$(aionas_now)}
  aionas_is_uint "$_rf_start" || _rf_start=$(aionas_now)
  _rf_now=$(aionas_now)
  _rf_t=$(cat "$_rf_dir/last_failed" 2>/dev/null)
  if aionas_is_uint "$_rf_t" && [ $((_rf_now - _rf_t)) -lt "$AIONAS_REQUESTS_RETRY" ] && [ "$_rf_now" -ge "$_rf_t" ]; then
    return 4
  fi
  aionas_lock_try requests 60 || return 4
  _rf_batch="$_rf_dir/.batch.$$"
  mv -f "$_rf_dir/queue.tsv" "$_rf_batch" 2>/dev/null || { aionas_lock_release requests; return 0; }
  # Valid, recent, one per prompt per method, the newest MAX_QUEUE.
  _rf_oldest=$((_rf_now - AIONAS_REQUESTS_MAX_AGE))
  awk -F '\t' -v methods="$AIONAS_REQUESTS_METHODS" -v oldest="$_rf_oldest" -v max="$AIONAS_REQUESTS_MAX_QUEUE" '
    BEGIN { n = split(methods, a, " "); for (i = 1; i <= n; i++) ok[a[i]] = 1 }
    NF >= 4 && NF <= 5 && $1 ~ /^[A-Za-z0-9._:-]+$/ && length($1) <= 128 && $2 ~ /^[A-Za-z0-9._:-]+$/ && length($2) <= 128 &&
      ($3 in ok) && $4 ~ /^[0-9]+$/ && $4 + 0 >= oldest && ($5 == "" || $5 ~ /^[0-9]+$/) {
      k = $1 "\t" $2 "\t" $3
      if (k in seen) next
      seen[k] = 1; row[++nr] = $0
    }
    END { s = nr > max ? nr - max + 1 : 1; for (i = s; i <= nr; i++) print row[i] }' "$_rf_batch" >"$_rf_batch.ok"
  rm -f "$_rf_batch"
  _rf_body="$_rf_dir/.body.$$"
  _rf_resp="$_rf_dir/.resp.$$"
  _rf_left="$_rf_dir/.left.$$"
  : >"$_rf_left"
  _rf_rc=0 _rf_stop=0
  while IFS="$(printf '\t')" read -r _rf_sid _rf_pid _rf_m _rf_at _rf_tok; do
    if [ "$_rf_stop" -eq 1 ] || [ $(($(aionas_now) - _rf_start)) -ge "$AIONAS_REQUESTS_BUDGET" ]; then
      _rf_stop=1
      printf '%s\t%s\t%s\t%s\t%s\n' "$_rf_sid" "$_rf_pid" "$_rf_m" "$_rf_at" "$_rf_tok" >>"$_rf_left"
      continue
    fi
    aionas_requests_body "$_rf_sid" "$_rf_pid" "$_rf_m" "$_rf_at" "$_rf_tok" >"$_rf_body" || continue
    _rf_code=$(aionas_http POST /enroll/v1/savings/requests "$_rf_body" "$_rf_resp")
    _rf_r=$?
    if [ $_rf_r -eq 0 ]; then continue; fi
    case "$_rf_code" in
      400 | 413)
        _rf_d=$(cat "$_rf_dir/dropped" 2>/dev/null)
        aionas_is_uint "$_rf_d" || _rf_d=0
        echo $((_rf_d + 1)) | aionas_write_atomic "$_rf_dir/dropped"
        continue
        ;;
    esac
    _rf_stop=1
    [ $_rf_r -eq 3 ] && _rf_rc=3 || _rf_rc=1
    printf '%s\t%s\t%s\t%s\t%s\n' "$_rf_sid" "$_rf_pid" "$_rf_m" "$_rf_at" "$_rf_tok" >>"$_rf_left"
  done <"$_rf_batch.ok"
  rm -f "$_rf_body" "$_rf_resp" "$_rf_batch.ok"
  if [ -s "$_rf_left" ]; then cat "$_rf_left" >>"$_rf_dir/queue.tsv"; fi
  rm -f "$_rf_left"
  if [ $_rf_rc -ne 0 ]; then
    echo "$_rf_now" | aionas_write_atomic "$_rf_dir/last_failed"
  else
    rm -f "$_rf_dir/last_failed"
  fi
  aionas_lock_release requests
  return $_rf_rc
}
