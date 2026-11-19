# aionas-savings per-request records (AIO-1004, wave 31; AIO-1073).
#
# Each method that acted on a prompt (subagent_sonnet, handoff) is reported
# once per prompt to POST /enroll/v1/savings/requests, so the server can tie
# the day's applied figure to a request. The record is ids, the method name, a
# time, the plugin version and, where the plugin measured it, a token count.
# No prompt text, file path, command or tool output is ever queued or sent.
# The gateway prices the record; this plugin sends no cost. The gateway keeps
# one record per prompt and method, so a repeated send changes nothing.
#
# How it flows (AIO-1073):
#   aionas_request_prompt SID PROMPT_ID
#       the UserPromptSubmit hook says which prompt the session is on now:
#       Claude Code's prompt_id, set for each prompt before that hook runs and
#       carried by every later hook until the next prompt (the Stop's too).
#   aionas_request_mark SID METHOD [PROMPT_ID] [TOKENS]
#       a hook or the mod says "METHOD acted now". Without a prompt id (the
#       mod's sub-agent start) the mark takes the session's prompt at that
#       moment; a session with none drops the mark: a record that cannot be
#       tied to its prompt is never guessed. Each mark is a spool file of its
#       own, written whole and renamed into place, so no write races a flush.
#   aionas_requests_flush [START_EPOCH]
#       sends the spool, one POST per prompt per method, each send started
#       only while it can end inside the Stop hook's 10 s. A spool file is
#       removed only once every record in it was accepted or refused
#       (400/413), so a flush stopped or killed half way leaves the rest for
#       the next one.
#
# Files under $(aionas_savings_dir)/requests:
#   prompt.<sid>    the session's current prompt id (kept two days)
#   spool/*.ev      one mark each: sid, prompt id, method, epoch, tokens
#   last_failed     epoch of the last failed send (retry no sooner than 5 min)
#   dropped         rows the server refused, summed

AIONAS_REQUESTS_METHODS="subagent_sonnet handoff"
AIONAS_REQUESTS_MAX_QUEUE=${AIONAS_REQUESTS_MAX_QUEUE:-200}
# The gateway refuses a record older than 45 days; keep two days.
AIONAS_REQUESTS_MAX_AGE=${AIONAS_REQUESTS_MAX_AGE:-172800}
AIONAS_REQUESTS_RETRY=${AIONAS_REQUESTS_RETRY:-300}
AIONAS_REQUESTS_MAX_TOKENS=1000000000
# One deadline for the whole Stop flush (AIO-1073): the hook is stopped at
# 10 s and a send takes at most 5 s (lib/http.sh), so no send starts later
# than 3 whole seconds after the hook started (3, +1 rounding, +5 < 10).
AIONAS_FLUSH_SEND_BY=${AIONAS_FLUSH_SEND_BY:-3}

aionas_requests_dir() { echo "$(aionas_savings_dir)/requests"; }

# aionas_flush_may_send [START]: exit 0 while a send started now still ends
# inside the hook's limit (START, else AIONAS_FLUSH_START; neither: no limit).
aionas_flush_may_send() {
  _fm_s=${1:-${AIONAS_FLUSH_START:-}}
  aionas_is_uint "$_fm_s" || return 0
  [ $(($(aionas_now) - _fm_s)) -le "$AIONAS_FLUSH_SEND_BY" ]
}

# aionas_spool_put DIR LINE: LINE as a new file DIR/<epoch>.<pid>.<n>.ev,
# written under a temporary name and renamed into place: a reader sees the
# whole line or no file.
aionas_spool_put() {
  aionas_mkdir "$1" || return 1
  printf '%s\n' "$2" | aionas_write_atomic "$1/$(aionas_now).$$.${RANDOM:-0}${RANDOM:-0}.ev"
}

# aionas_spool_list DIR: the names of DIR's spool files.
aionas_spool_list() {
  (cd "$1" 2>/dev/null && ls -1 2>/dev/null) | grep -E '^[A-Za-z0-9_-][A-Za-z0-9._-]*\.ev$'
}

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

# aionas_request_prompt SID PROMPT_ID: the session is on PROMPT_ID from now.
# Without a usable prompt id the session's prompt is forgotten, so later
# marks are dropped rather than given to an earlier prompt. Prints nothing.
aionas_request_prompt() {
  aionas_enroll_has_alias || return 0
  aionas_request_id_ok "${1:-}" || return 0
  _rp_dir=$(aionas_requests_dir)
  if aionas_request_id_ok "${2:-}"; then
    aionas_mkdir "$_rp_dir" || return 1
    printf '%s\n' "$2" | aionas_write_atomic "$_rp_dir/prompt.$1"
  else
    rm -f "$_rp_dir/prompt.$1"
  fi
  return 0
}

# aionas_request_mark SID METHOD [PROMPT_ID] [TOKENS]: exit 2, queueing
# nothing, for a method outside the list, an id outside the grammar or a bad
# token count; 0 otherwise (also, doing nothing, on a computer that is not
# enrolled or for a session with no current prompt). Prints nothing.
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
  if [ -z "$_rm_pid" ]; then
    _rm_pid=$(cat "$_rm_dir/prompt.$_rm_sid" 2>/dev/null)
    aionas_request_id_ok "$_rm_pid" || return 0
  fi
  aionas_spool_put "$_rm_dir/spool" "$(printf '%s\t%s\t%s\t%s\t%s' "$_rm_sid" "$_rm_pid" "$_rm_m" "$(aionas_now)" "$_rm_tok")"
}

# aionas_requests_body SID PROMPT METHOD EPOCH TOKENS: the request body.
# Every value was checked against its grammar before it was queued; this
# checks again, so a hand-edited spool line never reaches the server.
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

# _aionas_requests_adopt DIR: rows an earlier 0.6.1 build left outside the
# spool (queue.tsv, a flush's .batch.* and .left.*) become spool files; its
# open.<sid> marks name no prompt and are dropped.
_aionas_requests_adopt() {
  for _ra_f in "$1"/queue.tsv "$1"/.batch.* "$1"/.left.*; do
    [ -f "$_ra_f" ] || continue
    aionas_mkdir "$1/spool" && mv -f "$_ra_f" "$1/spool/0.$$.${RANDOM:-0}${RANDOM:-0}.ev"
  done
  for _ra_f in "$1"/open.*; do [ -f "$_ra_f" ] && rm -f "$_ra_f"; done
  return 0
}

# aionas_requests_flush [START_EPOCH]: send the spooled records. Exit 0 when
# sent or nothing to send; 1 when a send failed (files stay; no retry for
# 5 min); 3 when not enrolled; 4 when another flush runs or a retry is not due.
aionas_requests_flush() {
  _rf_dir=$(aionas_requests_dir)
  [ -d "$_rf_dir" ] || return 0
  _rf_start=${1:-${AIONAS_FLUSH_START:-$(aionas_now)}}
  aionas_is_uint "$_rf_start" || _rf_start=$(aionas_now)
  _rf_now=$(aionas_now)
  _rf_t=$(cat "$_rf_dir/last_failed" 2>/dev/null)
  if aionas_is_uint "$_rf_t" && [ $((_rf_now - _rf_t)) -lt "$AIONAS_REQUESTS_RETRY" ] && [ "$_rf_now" -ge "$_rf_t" ]; then
    return 4
  fi
  aionas_lock_try requests 60 || return 4
  _aionas_requests_adopt "$_rf_dir"
  # A session's prompt id is forgotten two days after its last prompt.
  find "$_rf_dir" -maxdepth 1 -type f -name 'prompt.*' -mtime +2 2>/dev/null |
    while IFS= read -r _rf_f; do rm -f "$_rf_f"; done
  _rf_sp="$_rf_dir/spool"
  _rf_files=$(aionas_spool_list "$_rf_sp")
  if [ -z "$_rf_files" ]; then aionas_lock_release requests; return 0; fi
  # The plan: one line per record to send (sid prompt method epoch, the
  # spool files holding it space separated, tokens), oldest first, and a
  # "-" line for each file holding nothing to send (invalid, too old, past
  # the cap).
  _rf_plan="$_rf_dir/.plan.$$"
  _rf_oldest=$((_rf_now - AIONAS_REQUESTS_MAX_AGE))
  # shellcheck disable=SC2086
  if ! (cd "$_rf_sp" && awk -F '\t' -v methods="$AIONAS_REQUESTS_METHODS" -v oldest="$_rf_oldest" -v max="$AIONAS_REQUESTS_MAX_QUEUE" '
    BEGIN { n = split(methods, a, " "); for (i = 1; i <= n; i++) ok[a[i]] = 1 }
    FNR == 1 { file[++nf] = FILENAME }
    NF >= 4 && NF <= 5 && $1 ~ /^[A-Za-z0-9._:-]+$/ && length($1) <= 128 && $2 ~ /^[A-Za-z0-9._:-]+$/ && length($2) <= 128 &&
      ($3 in ok) && $4 ~ /^[0-9]+$/ && $4 + 0 >= oldest && ($5 == "" || $5 ~ /^[0-9]+$/) {
      k = $1 "\t" $2 "\t" $3
      if (!(k in at) || $4 + 0 < at[k]) { if (!(k in at)) key[++nr] = k; at[k] = $4 + 0; tok[k] = $5 }
      if (index(" " fs[k] " ", " " FILENAME " ") == 0) fs[k] = fs[k] (fs[k] == "" ? "" : " ") FILENAME
    }
    END {
      # oldest first (insertion sort: the spool is small)
      for (i = 2; i <= nr; i++) { k = key[i]; for (j = i - 1; j >= 1 && at[key[j]] > at[k]; j--) key[j + 1] = key[j]; key[j + 1] = k }
      s = nr > max ? nr - max + 1 : 1
      for (i = s; i <= nr; i++) { k = key[i]; print k "\t" at[k] "\t" fs[k] "\t" tok[k]; m = split(fs[key[i]], d, " "); for (j = 1; j <= m; j++) keep[d[j]] = 1 }
      for (i = 1; i <= nf; i++) if (!(file[i] in keep)) print "-\t" file[i]
    }' $_rf_files) >"$_rf_plan"; then
    rm -f "$_rf_plan"; aionas_lock_release requests; return 1
  fi
  _rf_body="$_rf_dir/.body.$$"
  _rf_resp="$_rf_dir/.resp.$$"
  _rf_done="$_rf_dir/.done.$$"
  _rf_held="$_rf_dir/.held.$$"
  : >"$_rf_done"; : >"$_rf_held"
  _rf_rc=0 _rf_stop=0
  while IFS="$(printf '\t')" read -r _rf_sid _rf_pid _rf_m _rf_at _rf_fs _rf_tok; do
    if [ "$_rf_sid" = - ]; then printf '%s\n' "$_rf_pid" >>"$_rf_done"; continue; fi
    [ "$_rf_stop" -eq 1 ] || aionas_flush_may_send "$_rf_start" || _rf_stop=1
    if [ "$_rf_stop" -eq 0 ] && aionas_requests_body "$_rf_sid" "$_rf_pid" "$_rf_m" "$_rf_at" "$_rf_tok" >"$_rf_body"; then
      _rf_code=$(aionas_http POST /enroll/v1/savings/requests "$_rf_body" "$_rf_resp")
      _rf_r=$?
      if [ $_rf_r -eq 0 ]; then
        printf '%s\n' $_rf_fs >>"$_rf_done"; continue
      fi
      case "$_rf_code" in
        400 | 413)
          _rf_d=$(cat "$_rf_dir/dropped" 2>/dev/null)
          aionas_is_uint "$_rf_d" || _rf_d=0
          echo $((_rf_d + 1)) | aionas_write_atomic "$_rf_dir/dropped"
          printf '%s\n' $_rf_fs >>"$_rf_done"
          continue
          ;;
      esac
      _rf_stop=1
      [ $_rf_r -eq 3 ] && _rf_rc=3 || _rf_rc=1
    fi
    printf '%s\n' $_rf_fs >>"$_rf_held"
  done <"$_rf_plan"
  # A file goes once nothing in it waits any more.
  for _rf_f in $(awk 'FILENAME == ARGV[1] { held[$0] = 1; next } !($0 in held)' "$_rf_held" "$_rf_done"); do
    case "$_rf_f" in .* | *[!A-Za-z0-9._-]*) continue ;; esac
    rm -f "$_rf_sp/$_rf_f"
  done
  rm -f "$_rf_body" "$_rf_resp" "$_rf_plan" "$_rf_done" "$_rf_held"
  if [ $_rf_rc -ne 0 ]; then
    echo "$_rf_now" | aionas_write_atomic "$_rf_dir/last_failed"
  else
    rm -f "$_rf_dir/last_failed"
  fi
  aionas_lock_release requests
  return $_rf_rc
}
