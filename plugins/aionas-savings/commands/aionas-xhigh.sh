#!/usr/bin/env bash
# aionas-savings command: /aionas-xhigh [max] [reason]. Owner: AIO-859 (W24-3).
# The plugin's mod (hooks/mod.tsx) registers the slash command and runs this
# script by argument vector (no shell).
#
# Opens a 10-minute window: sessions OPENED in it start at xhigh (or at max
# with "max") and may move between xhigh and max with /effort for their whole
# life. Sessions already open do not change. After the window new sessions
# start at high with the cap at high again. The window is a self-override of
# effort_default (reason optional, from/until, params {"effort": level}); when
# the org admin blocked self-override it is sent for approval instead and
# opens at the next session start after it is approved.
#
# The mechanism (probe, Claude Code 2.1.299; see hooks/effort-window.sh): the
# settings keep effortLevel=high and maxEffortLevel=high at all times. Only
# this file's window record changes; the mod reads it once per new session.
set -u
. "$(dirname "$0")/../lib/aionas.sh" || exit 1
. "$(dirname "$0")/aionas-bypass-lib.sh" || exit 1

SID=${AIONAS_SESSION_ID:-}
WINDOW=600
level=xhigh
case "${1:-}" in
  max | MAX) level=max; shift ;;
  xhigh | XHIGH) shift ;;
esac
reason=$(aionas_cmd_reason "$*")
why=""
[ -n "$reason" ] && why=" Reason: $reason."

dir=$(aionas_savings_dir)
aionas_mkdir "$dir" || { echo "Could not write $dir."; exit 1; }

open_window() { # STATUS ID
  _now=$(aionas_now)
  printf '%s\t%s\t%s\t%s\t%s\n' "$_now" $((_now + WINDOW)) "$level" "$1" "${2:--}" |
    aionas_write_atomic "$dir/effort-window" || return 1
  [ "${2:--}" != - ] && aionas_effort_request_add "$2" "$level"
  aionas_counter_inc effort_default bypass >/dev/null 2>&1
  return 0
}
opened() { # SUFFIX
  echo "Sessions you open in the next 10 minutes start at $level (and can go up to max with /effort). This session stays as it is.$why$1"
}

body="$dir/.xhigh.body.$$"
aionas_override_body effort_default "$WINDOW" "$reason" "$level" >"$body"
allowed=0
aionas_policy_self_override_allowed effort_default "$SID" && allowed=1

res=$(aionas_override_post "$body")
rc=$?
set -- $res
code=$1 status=$2 id=$3

if [ $rc -eq 0 ]; then
  rm -f "$body"
  if [ "$status" = requested ]; then
    [ "$id" != - ] && aionas_effort_request_add "$id" "$level"
    echo "effort $level: sent for approval to your org admin or lead.$why New sessions stay at high; once it is approved, your next new session opens the window."
    exit 0
  fi
  open_window self "$id" || { echo "Could not write the window."; exit 1; }
  opened " Recorded with Aionas."
  exit 0
fi

case "$code" in
  400 | 413)
    rm -f "$body"
    echo "Aionas refused the window (HTTP $code). Nothing changed."
    exit 1
    ;;
esac

if [ $rc -eq 3 ]; then
  rm -f "$body"
  if [ $allowed -eq 1 ]; then
    open_window self - || { echo "Could not write the window."; exit 1; }
    opened " This computer is not enrolled, so it is recorded here only."
    exit 0
  fi
  echo "effort $level: your organization asks for approval, and this computer is not enrolled. Nothing changed."
  exit 1
fi

queued=0
aionas_override_queue "$body" && queued=1
rm -f "$body"
if [ $allowed -eq 1 ]; then
  open_window self - || { echo "Could not write the window."; exit 1; }
  if [ $queued -eq 1 ]; then
    opened " Aionas could not be reached; it is recorded at your next session start."
  else
    opened " Aionas could not be reached, and the queue is full, so it is recorded here only."
  fi
  exit 0
fi
if [ $queued -eq 1 ]; then
  echo "effort $level: your organization asks for approval. Aionas could not be reached; the request is sent for approval at your next session start. New sessions stay at high."
  exit 0
fi
echo "effort $level: your organization asks for approval, and Aionas could not be reached. Nothing changed; try again later."
exit 1
