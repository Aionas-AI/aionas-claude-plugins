#!/usr/bin/env bash
# aionas-savings command: /aionas-bypass <method> [duration] [reason]. Owner: AIO-855.
# The plugin's mod (hooks/mod.tsx) registers the slash command and runs this
# script by argument vector (no shell), with AIONAS_SESSION_ID set.
#
#   aionas-bypass.sh <method> [duration] [reason...]
#       Self-override (W24-1): when self-override is allowed the method is off
#       on this computer at once for the duration (default 1h) and the override
#       is stored with status self; when the org admin blocked it, the same
#       command sends a request (status requested) and prints "sent for
#       approval". The reason is optional (at most 280 characters). Required
#       methods cannot be bypassed.
#   aionas-bypass.sh --band      the aionas mod band's facts (mod spec §5), tab
#                                separated, numbers and names only, no network:
#       clock <now> <utc offset seconds>
#       me <display_name> <org_name> <role> <lead_name|-> <computer_name|->
#       savings <usd|api_value> <today_usd|-> <since_on_usd|-> <today_tokens|-> <since_on_tokens|-> <since_on_date|-> <could_save_usd|-> <could_save_tokens|-> <counted_days|-> <as_of_epoch|0>
#                                (AIO-867: amounts may be negative, regressions net; "-" is no data)
#       method <id> <on|off> <active> <self_override> <released> <bypass_until|0> <request_pending> <fired_today>
#       window <xhigh|max|-> <until|0> <session_grant|->
#       compact_at <tokens> <idle_minutes>
#       gateway_host <host|->
#                                me and savings come from the last policy answer
#                                and are left out when it has no such block.
#   aionas-bypass.sh --end <method>
#                                end my bypass of <method> on this computer at
#                                once (the band's chip), with no network call and
#                                no counter: the server row keeps its own end.
#   aionas-bypass.sh --list      the older band rows: method state active
#                                self_override, then compact_at <tokens>
#   aionas-bypass.sh --count METHOD COUNTER
#                                add one to a counter (the mod's counting)
#
# Prints one line for the person. Exit 0 on success, 1 when nothing was done,
# 2 for a usage error.
set -u
. "$(dirname "$0")/../lib/aionas.sh" || exit 1
. "$(dirname "$0")/aionas-bypass-lib.sh" || exit 1

SID=${AIONAS_SESSION_ID:-}
CLIENT_METHODS="handoff effort_default subagent_sonnet unused_services output_trim write_minimum"

usage() {
  echo "Usage: /aionas-bypass <method> [duration] [reason]. Methods: $CLIENT_METHODS. Duration: 30m, 1h, 2d (default 1h)."
}

if [ "${1:-}" = --list ]; then
  for m in $CLIENT_METHODS; do
    st=$(aionas_policy_state "$m" "$SID")
    if aionas_policy_active "$m" "$SID"; then a=1; else a=0; fi
    if aionas_policy_self_override_allowed "$m" "$SID"; then so=1; else so=0; fi
    printf '%s\t%s\t%s\t%s\n' "$m" "$st" "$a" "$so"
  done
  t=$(aionas_policy_param handoff threshold_tokens "$SID" 2>/dev/null)
  aionas_is_uint "$t" || t=200000
  printf 'compact_at\t%s\n' "$t"
  exit 0
fi

if [ "${1:-}" = --band ]; then
  aionas_band "$SID"
  exit 0
fi

if [ "${1:-}" = --end ]; then
  method=$(aionas_cmd_method "${2:-}") || {
    echo "Usage: /aionas-bypass --end <method>. Methods: $CLIENT_METHODS."
    exit 2
  }
  if aionas_is_required "$method"; then
    echo "$method is required by your organization and is never bypassed."
    exit 1
  fi
  aionas_bypass_end "$method"
  case $? in
    0) echo "$method is back on for you on this computer, from now (new and running sessions)."; exit 0 ;;
    1) echo "$method was not bypassed on this computer. It stays on."; exit 0 ;;
  esac
  echo "Could not end the bypass of $method."
  exit 1
fi

if [ "${1:-}" = --count ]; then
  aionas_counter_inc "${2:-}" "${3:-}" >/dev/null 2>&1
  exit $?
fi

[ $# -ge 1 ] && [ -n "$1" ] || { usage; exit 2; }
method=$(aionas_cmd_method "$1") || {
  echo "Unknown method '$1'. Methods: $CLIENT_METHODS."
  exit 2
}
shift
if aionas_is_required "$method"; then
  echo "$method is required by your organization and cannot be bypassed."
  exit 1
fi
# effort_default: a bypass lifts the high cap for sessions opened while it
# lasts (hooks/effort-window.sh grants them "free"); /aionas-xhigh is the
# 10-minute form that also starts them at xhigh or max.
secs=3600
if [ $# -ge 1 ] && d=$(aionas_cmd_duration "$1"); then
  secs=$d
  shift
fi
reason=$(aionas_cmd_reason "$*")
human=$(aionas_cmd_human "$secs")
why=""
[ -n "$reason" ] && why=" Reason: $reason."

dir=$(aionas_savings_dir)
aionas_mkdir "$dir" || { echo "Could not write $dir."; exit 1; }
body="$dir/.bypass.body.$$"
aionas_override_body "$method" "$secs" "$reason" >"$body"
allowed=0
aionas_policy_self_override_allowed "$method" "$SID" && allowed=1

res=$(aionas_override_post "$body")
rc=$?
set -- $res
code=$1 status=$2

if [ $rc -eq 0 ]; then
  rm -f "$body"
  if [ "$status" = requested ]; then
    aionas_request_add "$method" >/dev/null 2>&1
    echo "$method: sent for approval to your org admin or lead.$why It applies from your next session once approved."
    exit 0
  fi
  aionas_override_local_add "$method" "$secs" self
  aionas_counter_inc "$method" bypass >/dev/null 2>&1
  echo "$method is off for you for $human, from now (new and running sessions).$why Recorded with Aionas."
  exit 0
fi

case "$code" in
  400 | 413)
    rm -f "$body"
    echo "Aionas refused this override (HTTP $code). Nothing changed."
    exit 1
    ;;
esac

if [ $rc -eq 3 ]; then
  # Not enrolled: there is nobody to ask, so only the local policy decides.
  rm -f "$body"
  if [ $allowed -eq 1 ]; then
    aionas_override_local_add "$method" "$secs" self
    aionas_counter_inc "$method" bypass >/dev/null 2>&1
    echo "$method is off for you for $human, from now.$why This computer is not enrolled, so it is recorded here only."
    exit 0
  fi
  echo "$method: your organization asks for approval, and this computer is not enrolled. Nothing changed."
  exit 1
fi

# Aionas could not be reached: keep the override for the next session start.
queued=0
aionas_override_queue "$body" && queued=1
rm -f "$body"
if [ $allowed -eq 1 ]; then
  aionas_override_local_add "$method" "$secs" self
  aionas_counter_inc "$method" bypass >/dev/null 2>&1
  if [ $queued -eq 1 ]; then
    echo "$method is off for you for $human, from now.$why Aionas could not be reached; it is recorded at your next session start."
  else
    echo "$method is off for you for $human, from now.$why Aionas could not be reached, and the queue is full, so it is recorded here only."
  fi
  exit 0
fi
if [ $queued -eq 1 ]; then
  aionas_request_add "$method" >/dev/null 2>&1
  echo "$method: your organization asks for approval. Aionas could not be reached; the request is sent for approval at your next session start."
  exit 0
fi
echo "$method: your organization asks for approval, and Aionas could not be reached. Nothing changed; try again later."
exit 1
