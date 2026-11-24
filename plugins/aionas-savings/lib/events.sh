# aionas-savings session events (AIO-925, wave 27). Sourced via aionas.sh.
#
#   POST /enroll/v1/sessions/events   one SessionStart or PreCompact firing
#
# Metadata only: the session_id the hook input carries, a closed-list word
# (source or trigger), the time and the plugin version. Never a prompt, a path,
# a working directory, the PreCompact custom_instructions, the alias or an
# enrollment id. The server refuses any other field.
#
# Fire and forget: one try within lib/http.sh's limits (3 s connect, 5 s in
# total, no retry), nothing printed. The hooks run async, so a slow gateway
# never delays a session or a compaction.

AIONAS_EVENT_SOURCES="startup resume clear compact fork"
AIONAS_EVENT_TRIGGERS="manual auto"

# aionas_event_post BODY: send BODY (one JSON line) once. Exit 0 when
# accepted; 3 when not enrolled (no call made); 1 otherwise.
aionas_event_post() {
  _ep_dir=$(aionas_savings_dir)
  aionas_mkdir "$_ep_dir" || return 3
  _ep_body="$_ep_dir/.event.body.$$"
  _ep_resp="$_ep_dir/.event.resp.$$"
  printf '%s\n' "$1" | aionas_write_atomic "$_ep_body" || return 1
  aionas_http POST /enroll/v1/sessions/events "$_ep_body" "$_ep_resp" >/dev/null
  _ep_rc=$?
  rm -f "$_ep_body" "$_ep_resp"
  return $_ep_rc
}

# aionas_event_body SESSION EVENT KEY VALUE: the event's JSON line.
aionas_event_body() {
  _eb_v=$(aionas_plugin_version 2>/dev/null)
  _eb_vf=""
  case "$_eb_v" in '' | *[!0-9A-Za-z.+-]*) ;; *) _eb_vf=",\"plugin_version\":\"$_eb_v\"" ;; esac
  printf '{"session_id":"%s","event":"%s","%s":"%s","ts":"%s"%s}' "$1" "$2" "$3" "$4" "$(aionas_iso_utc "$(aionas_now)")" "$_eb_vf"
}

# aionas_event_session_start SESSION SOURCE: one session_start event. Exit 2,
# sending nothing, for a bad id or a source outside the closed list.
aionas_event_session_start() {
  _aionas_sid_ok "${1:-}" || return 2
  _in_list "${2:-}" $AIONAS_EVENT_SOURCES || return 2
  aionas_enroll_has_alias || return 3
  aionas_event_post "$(aionas_event_body "$1" session_start source "$2")"
}

# aionas_event_pre_compact SESSION TRIGGER: one pre_compact event (manual =
# the person typed /compact, auto = Claude Code compacted on its own).
aionas_event_pre_compact() {
  _aionas_sid_ok "${1:-}" || return 2
  _in_list "${2:-}" $AIONAS_EVENT_TRIGGERS || return 2
  aionas_enroll_has_alias || return 3
  aionas_event_post "$(aionas_event_body "$1" pre_compact trigger "$2")"
}
