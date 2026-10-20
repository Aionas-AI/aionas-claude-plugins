# aionas-savings: what /aionas-bypass and /aionas-xhigh share (AIO-855, AIO-859).
# Sourced after lib/aionas.sh. POSIX sh plus bash 3.2; awk only, no jq.
#
# Files under $(aionas_savings_dir):
#   pending-overrides/<n>.json  overrides made while Aionas could not be
#                               reached; sent at the next session start
#   effort-window               the open /aionas-xhigh window:
#                               from until level status id   (tab separated)
#   effort-requests.tsv         xhigh windows sent for approval: id level created
#
# Privacy (W24-4): a body holds the method id, a duration, closed-set params
# and the reason the person typed on purpose. Nothing else.

AIONAS_REASON_MAX=280
AIONAS_PENDING_MAX=20

# aionas_cmd_method NAME: print the catalog id for NAME (a few spoken aliases
# are accepted). Exit 2 for a name outside the catalog.
aionas_cmd_method() {
  _cm=$(printf '%s' "$1" | tr 'A-Z-' 'a-z_')
  case "$_cm" in
    long_output_store | output) _cm=output_store ;;
    noisy | guard | noisy_command_guard) _cm=noisy_guard ;;
    effort) _cm=effort_default ;;
    subagent | subagents | subagent_model) _cm=subagent_sonnet ;;
    unused | unused_mcp) _cm=unused_services ;;
    minimum) _cm=write_minimum ;;
  esac
  aionas_is_method "$_cm" || return 2
  printf '%s\n' "$_cm"
}

# aionas_cmd_duration TEXT: 90s, 30m, 1h, 2d, or a plain number of minutes
# -> seconds (1 s to 30 days). Exit 1 when TEXT is not a duration.
aionas_cmd_duration() {
  _cd_n=${1%[smhdSMHD]}
  _cd_u=${1#"$_cd_n"}
  aionas_is_uint "$_cd_n" || return 1
  [ ${#_cd_n} -le 7 ] || return 1
  case "$_cd_u" in
    s | S) _cd_s=$_cd_n ;;
    '' | m | M) _cd_s=$((_cd_n * 60)) ;;
    h | H) _cd_s=$((_cd_n * 3600)) ;;
    d | D) _cd_s=$((_cd_n * 86400)) ;;
    *) return 1 ;;
  esac
  [ "$_cd_s" -ge 1 ] && [ "$_cd_s" -le 2592000 ] || return 1
  echo "$_cd_s"
}

# aionas_cmd_human SECONDS: 600 -> "10 minutes", 3600 -> "1 hour".
aionas_cmd_human() {
  awk -v s="$1" 'BEGIN {
    if (s % 86400 == 0) { n = s / 86400; u = "day" }
    else if (s % 3600 == 0) { n = s / 3600; u = "hour" }
    else if (s % 60 == 0) { n = s / 60; u = "minute" }
    else { n = s; u = "second" }
    printf "%d %s%s\n", n, u, (n == 1 ? "" : "s")
  }'
}

# aionas_cmd_reason TEXT: TEXT with control characters turned to spaces,
# trimmed, and cut to at most 280 bytes on a UTF-8 character boundary (so it
# is at most 280 characters too).
aionas_cmd_reason() {
  printf '%s' "$1" | LC_ALL=C awk -v max="$AIONAS_REASON_MAX" '
    BEGIN { for (i = 1; i < 256; i++) ord[sprintf("%c", i)] = i }
    { s = s (NR > 1 ? " " : "") $0 }
    END {
      gsub(/[\001-\037\177]/, " ", s)
      gsub(/^ +| +$/, "", s)
      if (length(s) > max) {
        s = substr(s, 1, max); i = max
        while (i > 1 && ord[substr(s, i, 1)] >= 128 && ord[substr(s, i, 1)] < 192) i--
        b = ord[substr(s, i, 1)]
        need = (b >= 240) ? 4 : (b >= 224) ? 3 : (b >= 192) ? 2 : 1
        if (max - i + 1 < need) s = substr(s, 1, i - 1)
        sub(/ +$/, "", s)
      }
      printf "%s", s
    }'
}

# aionas_override_body METHOD SECONDS REASON [EFFORT]: the request body of
# POST /enroll/v1/savings/overrides.
aionas_override_body() {
  printf '{"method_id":"%s","duration_seconds":%s' "$1" "$2"
  [ -n "${4:-}" ] && printf ',"params":{"effort":"%s"}' "$4"
  [ -n "$3" ] && printf ',"reason":%s' "$(aionas_json_escape "$3")"
  printf '}\n'
}

# aionas_override_post BODY_FILE: send it once (3 s connect, 5 s total).
# Prints "<http status> <status> <id>" (status self | requested | -, id or -).
# Exit 0 for a 2xx (201 self, 202 requested), 3 when the computer is not enrolled, 1 otherwise.
aionas_override_post() {
  _op_dir=$(aionas_savings_dir)
  aionas_mkdir "$_op_dir" || { echo "000 - -"; return 1; }
  _op_resp="$_op_dir/.override.resp.$$"
  _op_code=$(aionas_http POST /enroll/v1/savings/overrides "$1" "$_op_resp")
  _op_rc=$?
  _op_st=- _op_id=-
  if [ $_op_rc -eq 0 ]; then
    _op_flat=$(aionas_json_flatten "$_op_resp" 2>/dev/null)
    _op_st=$(printf '%s\n' "$_op_flat" | aionas_json_get status 2>/dev/null)
    _op_id=$(printf '%s\n' "$_op_flat" | aionas_json_get id 2>/dev/null)
    case "$_op_st" in self | requested | approved) ;; *) _op_st=- ;; esac
    if [ "$_op_st" = - ]; then
      case "$_op_code" in 202) _op_st=requested ;; *) _op_st=self ;; esac
    fi
    printf '%s\n' "$_op_id" | grep -Eq '^[A-Za-z0-9_.:-]{1,128}$' || _op_id=-
  fi
  rm -f "$_op_resp"
  echo "$_op_code $_op_st $_op_id"
  [ $_op_rc -eq 0 ] && return 0
  [ $_op_rc -eq 3 ] && return 3
  return 1
}

# aionas_override_queue BODY_FILE: keep it for the next session start.
aionas_override_queue() {
  _oq_dir="$(aionas_savings_dir)/pending-overrides"
  aionas_mkdir "$_oq_dir" || return 1
  # shellcheck disable=SC2012
  [ "$(ls -1 "$_oq_dir" 2>/dev/null | grep -c '\.json$')" -lt "$AIONAS_PENDING_MAX" ] || return 1
  aionas_write_atomic "$_oq_dir/$(aionas_now).$$.json" <"$1"
}

# aionas_override_flush_pending [MAX]: send the queued overrides, oldest
# first, at most MAX (default 3) per call; stop at the first one that does not
# get through. A sent xhigh request is remembered by id (effort-requests.tsv)
# so its window can open when it is approved. A refused one (400/413) is
# dropped. Exit 0 when the queue is empty afterwards.
aionas_override_flush_pending() {
  _of_dir="$(aionas_savings_dir)/pending-overrides"
  [ -d "$_of_dir" ] || return 0
  aionas_lock_try pending-overrides 60 || return 1
  _of_n=0
  # shellcheck disable=SC2012
  for _of_f in $(ls -1 "$_of_dir" 2>/dev/null | grep '\.json$' | sort -n); do
    [ "$_of_n" -lt "${1:-3}" ] || break
    _of_n=$((_of_n + 1))
    _of_r=$(aionas_override_post "$_of_dir/$_of_f")
    _of_rc=$?
    set -- "${1:-3}" $_of_r
    if [ $_of_rc -eq 0 ]; then
      _of_eff=$(aionas_json_flatten "$_of_dir/$_of_f" 2>/dev/null | aionas_json_get params.effort 2>/dev/null)
      if [ -n "$_of_eff" ] && [ "$3" = requested ] && [ "$4" != - ]; then
        aionas_effort_request_add "$4" "$_of_eff"
      fi
      rm -f "$_of_dir/$_of_f"
      continue
    fi
    case "$2" in 400 | 413) rm -f "$_of_dir/$_of_f"; continue ;; esac
    break
  done
  aionas_lock_release pending-overrides
  # shellcheck disable=SC2012
  [ -z "$(ls -1 "$_of_dir" 2>/dev/null | grep '\.json$')" ]
}

# aionas_effort_request_add ID LEVEL: remember a request sent for approval.
# Rows older than 7 days are dropped.
aionas_effort_request_add() {
  case "$2" in xhigh | max) ;; *) return 2 ;; esac
  aionas_mkdir "$(aionas_savings_dir)" || return 1
  _er_f="$(aionas_savings_dir)/effort-requests.tsv"
  _er_now=$(aionas_now)
  {
    [ -f "$_er_f" ] && awk -F '\t' -v old=$((_er_now - 604800)) 'NF == 3 && $3 > old' "$_er_f"
    printf '%s\t%s\t%s\n' "$1" "$2" "$_er_now"
  } | aionas_write_atomic "$_er_f"
}

# aionas_effort_request_level ID: the level asked for under ID (xhigh when
# unknown).
aionas_effort_request_level() {
  _rl=$(awk -F '\t' -v id="$1" '$1 == id && ($2 == "xhigh" || $2 == "max") { l = $2 } END { print l }' \
    "$(aionas_savings_dir)/effort-requests.tsv" 2>/dev/null)
  echo "${_rl:-xhigh}"
}
