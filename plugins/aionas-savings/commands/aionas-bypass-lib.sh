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
    trim | output | long_output_store | noisy | guard | noisy_command_guard | noisy_guard | output_store) _cm=output_trim ;;
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

# --- the aionas mod band (wave-24 mod spec §4, §5) ---------------------------
#
# More files under $(aionas_savings_dir):
#   requests.tsv     overrides this computer sent for approval: method created
#                    (shown as "request pending" until the next policy sync
#                    says otherwise; kept 1 day)
#   local-ends.tsv   bypasses ended here early (the band's chip, --end):
#                    method ended   The server row keeps its own end time (no
#                    route ends it early), so a sync that brings it back is
#                    stripped again from the cache and the pins (kept 30 days).
#
# Privacy (W24-4): the band's facts are numbers and names only; --band and
# --end make no network call, and nothing here reads the alias credential.

# The client methods in the band's chip order (cache_alert, seat_fit and the
# required cache_guard never get a chip).
AIONAS_BAND_METHODS="effort_default subagent_sonnet output_trim handoff unused_services write_minimum"
AIONAS_BAND_NAME_MAX=80
AIONAS_POLICY_SYNC_INTERVAL=${AIONAS_POLICY_SYNC_INTERVAL:-3600}

# aionas_band_tz_offset: the local UTC offset in seconds (+0300 -> 10800).
aionas_band_tz_offset() {
  _tz=$(date +%z 2>/dev/null)
  case "$_tz" in
    [+-][0-9][0-9][0-9][0-9])
      awk -v z="$_tz" 'BEGIN { s = (substr(z, 1, 1) == "-") ? -1 : 1; print s * (substr(z, 2, 2) * 3600 + substr(z, 4, 2) * 60) }' </dev/null
      ;;
    *) echo 0 ;;
  esac
}

# aionas_band_policy FILE: the "me" and "savings" lines from the raw policy
# answer (policy.json). Both blocks are optional: an old server, a missing or
# malformed block prints nothing for it. Strings are JSON-decoded, control
# characters (tabs, newlines) become spaces, and each name is cut at 80
# characters on a UTF-8 boundary; an empty or null name prints "-".
aionas_band_policy() {
  [ -f "$1" ] || return 0
  _bp=$(aionas_json_flatten "$1" 2>/dev/null | LC_ALL=C awk -F '\t' -v max="$AIONAS_BAND_NAME_MAX" '
    BEGIN { for (i = 1; i < 256; i++) ord[sprintf("%c", i)] = i }
    function hex4(h,   i, c, v) {
      if (length(h) < 4) return -1
      v = 0
      for (i = 1; i <= 4; i++) {
        c = index("0123456789abcdef", tolower(substr(h, i, 1)))
        if (c == 0) return -1
        v = v * 16 + c - 1
      }
      return v
    }
    function utf8(v) {
      if (v < 32 || v == 127) return " "
      if (v < 128) return sprintf("%c", v)
      if (v < 2048) return sprintf("%c%c", 192 + int(v / 64), 128 + v % 64)
      if (v < 65536) return sprintf("%c%c%c", 224 + int(v / 4096), 128 + int(v / 64) % 64, 128 + v % 64)
      return sprintf("%c%c%c%c", 240 + int(v / 262144), 128 + int(v / 4096) % 64, 128 + int(v / 64) % 64, 128 + v % 64)
    }
    function decode(s,   o, k, c, v, w) {
      o = ""
      while ((k = index(s, "\\")) > 0) {
        o = o substr(s, 1, k - 1); c = substr(s, k + 1, 1); s = substr(s, k + 2)
        if (c == "u") {
          v = hex4(substr(s, 1, 4))
          if (v < 0) { o = o "?"; continue }
          s = substr(s, 5)
          if (v >= 55296 && v < 56320 && substr(s, 1, 2) == "\\u") {
            w = hex4(substr(s, 3, 4))
            if (w >= 56320 && w < 57344) { s = substr(s, 7); o = o utf8(65536 + (v - 55296) * 1024 + (w - 56320)); continue }
          }
          o = o ((v >= 55296 && v < 57344) ? "?" : utf8(v))
        } else if (c == "n" || c == "t" || c == "r" || c == "b" || c == "f") o = o " "
        else o = o c
      }
      return o s
    }
    function clean(s,   n, i, out, b, chars) {
      gsub(/[\001-\037\177]/, " ", s)
      gsub(/^ +| +$/, "", s)
      n = length(s); out = ""; chars = 0
      for (i = 1; i <= n; i++) {
        b = ord[substr(s, i, 1)]
        if (b < 128 || b >= 192) { chars++; if (chars > max) break }
        out = out substr(s, i, 1)
      }
      sub(/ +$/, "", out)
      return out == "" ? "-" : out
    }
    function name(k) { return (k in ty && ty[k] == "s") ? clean(decode(va[k])) : "-" }
    function num(k) { return (k in ty && ty[k] == "n" && va[k] ~ /^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$/) ? va[k] : "-" }
    function uint(k) { return (k in ty && ty[k] == "n" && va[k] ~ /^[0-9]+$/ && length(va[k]) <= 15) ? va[k] : 0 }
    function sint(k) { return (k in ty && ty[k] == "n" && va[k] ~ /^-?[0-9]+$/ && length(va[k]) <= 16) ? va[k] : "-" }
    $1 ~ /^(me|savings)(\.|$)/ { ty[$1] = $2; va[$1] = $3 }
    END {
      if (ty["me"] == "o" && name("me.display_name") != "-")
        printf "me\t%s\t%s\t%s\t%s\t%s\n", name("me.display_name"), name("me.org_name"), name("me.role"), name("me.lead_name"), name("me.computer_name")
      mk = (ty["savings.money_kind"] == "s") ? va["savings.money_kind"] : ""
      if (ty["savings"] == "o" && (mk == "usd" || mk == "api_value")) {
        d = (ty["savings.since_on_date"] == "s" && va["savings.since_on_date"] ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) ? va["savings.since_on_date"] : "-"
        printf "savings\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", mk, num("savings.today_usd"), num("savings.since_on_usd"), sint("savings.today_tokens"), sint("savings.since_on_tokens"), d, num("savings.could_save_usd"), sint("savings.could_save_tokens"), sint("savings.counted_days"), name("savings.as_of")
      }
    }')
  [ -n "$_bp" ] || return 0
  printf '%s\n' "$_bp" | while IFS= read -r _bp_l; do
    case "$_bp_l" in
      savings"	"*)
        _bp_iso=${_bp_l##*"	"}
        _bp_e=$(awk -v mode=epoch -v iso="$_bp_iso" -f "$AIONAS_LIB/time.awk" </dev/null 2>/dev/null)
        aionas_is_uint "$_bp_e" || _bp_e=0
        printf '%s\t%s\n' "${_bp_l%"	"*}" "$_bp_e"
        ;;
      *) printf '%s\n' "$_bp_l" ;;
    esac
  done
}

# aionas_band_methods SESSION_ID: one "method" line per band method, then
# "window" and "compact_at", in one awk pass over the session's pin (else the
# last good cache), the last good cache (requests), local-overrides.tsv,
# requests.tsv, the effort window and today's counters:
#   method <id> <on|off> <active> <self_override> <released> <bypass_until|0> <request_pending> <fired_today>
#   window <xhigh|max|-> <until|0> <session grant|->
#   compact_at <tokens> <idle minutes>
# Mirrors lib/policy.sh: no row = on, self-override allowed; a released method
# is off; a self or approved override in force (server or local) bypasses it.
aionas_band_methods() {
  _bm_dir=$(aionas_savings_dir)
  _bm_pin=$(_aionas_policy_file "$1" 2>/dev/null) || _bm_pin=""
  _bm_grant=-
  if _aionas_sid_ok "$1" && [ -f "$_bm_dir/sessions/$1.effort" ]; then
    _bm_grant=$(cat "$_bm_dir/sessions/$1.effort" 2>/dev/null)
    case "$_bm_grant" in high | xhigh | max | free) ;; *) _bm_grant=- ;; esac
  fi
  set --
  for _bm_f in "$_bm_dir/counters/queue.tsv" "$_bm_dir/counters/pending.tsv" "$_bm_dir"/counters/batch.*; do
    [ -f "$_bm_f" ] && set -- "$@" "$_bm_f"
  done
  awk -F '\t' -v now="$(aionas_now)" -v today="$(aionas_day_utc)" -v methods="$AIONAS_BAND_METHODS" \
    -v defoff="$AIONAS_DEFAULT_OFF_METHODS" -v pin="$_bm_pin" -v cache="$_bm_dir/policy.cache" -v local="$_bm_dir/local-overrides.tsv" \
    -v req="$_bm_dir/requests.tsv" -v win="$_bm_dir/effort-window" -v grant="$_bm_grant" '
    function rows(f, kind,   l, a) {
      if (f == "") return
      while ((getline l < f) > 0) {
        split(l, a, "\t")
        if (kind == "pin") {
          if (a[1] == "M") { row[a[2]] = 1; st[a[2]] = a[3]; so[a[2]] = a[5]; rl[a[2]] = a[7] }
          else if (a[1] == "O" && (a[3] == "self" || a[3] == "approved") && a[4] <= now && (a[5] == 0 || a[5] > now)) {
            byp[a[2]] = 1
            if (a[5] == 0) open[a[2]] = 1; else if (a[5] > until[a[2]]) until[a[2]] = a[5]
          } else if (a[1] == "P" && a[2] == "handoff" && a[3] == "threshold_tokens" && a[5] ~ /^[0-9]+$/) th = a[5]
          else if (a[1] == "P" && a[2] == "handoff" && a[3] == "idle_minutes" && a[5] ~ /^[0-9]+$/) idle = a[5]
        } else if (kind == "cache") {
          if (a[1] == "F") fetched = a[2] + 0
          else if (a[1] == "O" && a[3] == "requested") pend[a[2]] = 1
        } else if (kind == "local") {
          if ((a[2] == "self" || a[2] == "approved") && a[3] <= now && a[4] > now) {
            byp[a[1]] = 1; if (a[4] > until[a[1]]) until[a[1]] = a[4]
          }
        } else if (kind == "req") {
          if (a[2] ~ /^[0-9]+$/) { if (a[2] > lastreq[a[1]]) lastreq[a[1]] = a[2] }
        } else if (kind == "win") {
          if (a[1] ~ /^[0-9]+$/ && a[2] ~ /^[0-9]+$/ && a[1] <= now && a[2] > now && (a[3] == "xhigh" || a[3] == "max")) { wl = a[3]; wu = a[2] }
        }
      }
      close(f)
    }
    BEGIN {
      th = 200000; idle = 55; wl = "-"; wu = 0; fetched = 0
      rows(pin, "pin"); rows(cache, "cache"); rows(local, "local"); rows(req, "req"); rows(win, "win")
      for (m in lastreq) if (lastreq[m] > fetched && now - lastreq[m] < 86400) pend[m] = 1
    }
    NF == 4 && $1 == today && $3 == "fired" && $4 ~ /^[0-9]+$/ { fired[$2] += $4 }
    END {
      n = split(methods, ml, " ")
      nd = split(defoff, dl, " "); for (k = 1; k <= nd; k++) off0[dl[k]] = 1
      for (k = 1; k <= n; k++) {
        m = ml[k]
        s = (m in off0) ? "off" : "on"; o = 1; r = 0
        if (m in row) { r = (rl[m] == 1); o = (so[m] == 1); s = (st[m] == "off" || r) ? "off" : "on" }
        a = (s == "on" && !(m in byp))
        u = ((m in byp) && !(m in open)) ? until[m] : 0
        printf "method\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\n", m, s, a, o, r, u, (m in pend) ? 1 : 0, fired[m] + 0
      }
      printf "window\t%s\t%d\t%s\n", wl, wu, grant
      printf "compact_at\t%s\t%s\n", th, idle
    }' "$@" </dev/null
}

# aionas_band_gateway_host: the enrolled gateway's host[:port], or "-".
aionas_band_gateway_host() {
  _gh=$(aionas_enroll_gateway 2>/dev/null) || { echo -; return 0; }
  _gh=${_gh#*://}
  echo "${_gh%%/*}" | tr 'A-Z' 'a-z'
}

# aionas_band_handoff SESSION_ID: "handoff <status|-> <due|0> <cold_at|0>
# <doc 0|1> <since|0>" from the session's handoff state (hooks/handoff-wake.sh);
# since = when the status was written (the band dates an older timer's
# deadline from it).
aionas_band_handoff() {
  _bh_dir="$(aionas_savings_dir)/handoff"
  if ! _aionas_sid_ok "$1" || [ ! -f "$_bh_dir/$1.state" ]; then
    printf 'handoff\t-\t0\t0\t0\t0\n'
    return 0
  fi
  _bh_doc=0
  [ -s "$_bh_dir/handoff-$1.md" ] && _bh_doc=1
  awk -F '\t' -v doc="$_bh_doc" 'NR == 1 {
      s = ($1 == "armed" || $1 == "delivered" || $1 == "ended") ? $1 : "-"
      u = ($4 ~ /^[0-9]+$/) ? $4 : 0
      printf "handoff\t%s\t%s\t%s\t%s\t%s\n", s, (s == "armed") ? u : 0, (s == "delivered") ? u : 0, doc, ($2 ~ /^[0-9]+$/) ? $2 : 0
      exit
    }' "$_bh_dir/$1.state"
}

# aionas_band SESSION_ID: everything the band draws (mod spec §5, --band),
# tab separated, numbers and names only. Leads with "clock <now> <utc offset
# seconds>" so the band shows local times the way this computer does.
aionas_band() {
  aionas_bypass_apply_ends "$1" >/dev/null 2>&1
  printf 'clock\t%s\t%s\n' "$(aionas_now)" "$(aionas_band_tz_offset)"
  aionas_band_policy "$(aionas_savings_dir)/policy.json"
  aionas_band_methods "$1"
  aionas_band_handoff "$1"
  printf 'gateway_host\t%s\n' "$(aionas_band_gateway_host)"
}

# aionas_request_add METHOD: remember a request sent (or queued) for approval,
# so the band shows "request pending" before the next policy sync.
aionas_request_add() {
  aionas_is_method "$1" || return 2
  aionas_mkdir "$(aionas_savings_dir)" || return 1
  _ra_f="$(aionas_savings_dir)/requests.tsv"
  _ra_now=$(aionas_now)
  {
    [ -f "$_ra_f" ] && awk -F '\t' -v old=$((_ra_now - 86400)) 'NF == 2 && $2 > old' "$_ra_f"
    printf '%s\t%s\n' "$1" "$_ra_now"
  } | aionas_write_atomic "$_ra_f"
}

# aionas_bypass_end METHOD: end my bypass of METHOD on this computer now, with
# no network call: drop its local rows, remember the end (local-ends.tsv) and
# strip the server's in-force row of it from the cache and every session pin.
# Exit 0 when a bypass was in force, 1 when there was none, 2 for a method
# that cannot be bypassed.
aionas_bypass_end() {
  aionas_is_method "$1" || return 2
  aionas_is_required "$1" && return 2
  _be_dir=$(aionas_savings_dir)
  aionas_mkdir "$_be_dir" || return 1
  _be_now=$(aionas_now)
  _be_was=1
  _be_l="$_be_dir/local-overrides.tsv"
  if [ -f "$_be_l" ]; then
    awk -F '\t' -v m="$1" -v now="$_be_now" '$1 == m && ($2 == "self" || $2 == "approved") && $3 <= now && $4 > now { f = 1 } END { exit f ? 0 : 1 }' "$_be_l" && _be_was=0
    awk -F '\t' -v m="$1" -v now="$_be_now" '$1 != m && $4 > now' "$_be_l" | aionas_write_atomic "$_be_l"
  fi
  _be_e="$_be_dir/local-ends.tsv"
  {
    [ -f "$_be_e" ] && awk -F '\t' -v m="$1" -v old=$((_be_now - 2592000)) 'NF == 2 && $1 != m && $2 > old' "$_be_e"
    printf '%s\t%s\n' "$1" "$_be_now"
  } | aionas_write_atomic "$_be_e" || return 1
  aionas_bypass_apply_ends --all && _be_was=0
  return $_be_was
}

# aionas_bypass_apply_ends [SESSION_ID | --all]: strip from the last good
# cache (and the session's pin, or with --all every pin) the server's
# self/approved override rows that began before a local end of their method.
# Exit 0 when a row in force now was stripped. Fast when nothing was ended.
aionas_bypass_apply_ends() {
  _ae_dir=$(aionas_savings_dir)
  _ae_e="$_ae_dir/local-ends.tsv"
  [ -s "$_ae_e" ] || return 1
  set -- "${1:-}" "$_ae_dir/policy.cache"
  if [ "$1" = --all ]; then
    for _ae_p in "$_ae_dir"/sessions/*.cache; do set -- "$@" "$_ae_p"; done
  elif [ -n "$1" ] && _aionas_sid_ok "$1"; then
    set -- "$@" "$_ae_dir/sessions/$1.cache"
  fi
  shift
  _ae_now=$(aionas_now)
  _ae_hit=1
  for _ae_f in "$@"; do
    [ -f "$_ae_f" ] || continue
    grep -q '^O	' "$_ae_f" 2>/dev/null || continue
    _ae_out=$(awk -F '\t' -v ends="$_ae_e" -v now="$_ae_now" '
      BEGIN { while ((getline l < ends) > 0) { split(l, a, "\t"); if (a[2] > end[a[1]]) end[a[1]] = a[2] } }
      $1 == "O" && ($2 in end) && ($3 == "self" || $3 == "approved") && $4 <= end[$2] && ($5 == 0 || $5 > end[$2]) {
        cut = 1; if ($4 <= now && ($5 == 0 || $5 > now)) live = 1; next
      }
      { print }
      END { exit cut ? (live ? 0 : 3) : 1 }' "$_ae_f")
    _ae_rc=$?
    [ $_ae_rc -eq 1 ] && continue
    printf '%s\n' "$_ae_out" | aionas_write_atomic "$_ae_f"
    [ $_ae_rc -eq 0 ] && _ae_hit=0
  done
  return $_ae_hit
}

# aionas_policy_sync_due: exit 0 when the last policy sync attempt (any
# outcome) is older than AIONAS_POLICY_SYNC_INTERVAL (1 hour). With no
# attempt on record it is not due: the SessionStart sync (policy-sync.sh)
# makes the first one.
aionas_policy_sync_due() {
  _sd_t=$(awk '{ print $1; exit }' "$(aionas_savings_dir)/sync.status" 2>/dev/null)
  aionas_is_uint "$_sd_t" || return 1
  [ $(($(aionas_now) - _sd_t)) -ge "$AIONAS_POLICY_SYNC_INTERVAL" ]
}
