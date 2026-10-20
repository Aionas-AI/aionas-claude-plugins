#!/usr/bin/env bash
# A stand-in for curl in the unit tests (AIONAS_CURL). Records every call under
# $FAKE_CURL_LOG/<n>/ (args, method, url, headers, body) and answers with
# FAKE_CURL_STATUS (default 200) and the file FAKE_CURL_BODY, or exits with
# FAKE_CURL_EXIT (e.g. 28, a timeout) printing "000" like curl -w does.
set -u
log=${FAKE_CURL_LOG:?}
mkdir -p "$log"
n=1
while ! mkdir "$log/$n" 2>/dev/null; do n=$((n + 1)); done
d="$log/$n"
printf '%s\n' "$@" >"$d/args"
method=GET out="" wfmt="" url=""
: >"$d/headers"
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method=$2; shift ;;
    -H)
      case "$2" in
        @*) cat "${2#@}" >>"$d/headers" ;;
        *) printf '%s\n' "$2" >>"$d/headers" ;;
      esac
      shift ;;
    --data-binary) case "$2" in @*) cat "${2#@}" >"$d/body" ;; *) printf '%s' "$2" >"$d/body" ;; esac; shift ;;
    -o) out=$2; shift ;;
    -w) wfmt=$2; shift ;;
    --connect-timeout | --max-time | --retry) shift ;;
    -*) ;;
    *) url=$1 ;;
  esac
  shift
done
printf '%s\n' "$method" >"$d/method"
printf '%s\n' "$url" >"$d/url"
if [ -n "${FAKE_CURL_SLEEP:-}" ]; then sleep "$FAKE_CURL_SLEEP"; fi
if [ -n "${FAKE_CURL_EXIT:-}" ]; then
  [ -n "$wfmt" ] && printf '000'
  exit "$FAKE_CURL_EXIT"
fi
if [ -n "$out" ]; then
  if [ -n "${FAKE_CURL_BODY:-}" ]; then cat "$FAKE_CURL_BODY" >"$out"; else : >"$out"; fi
fi
[ -n "$wfmt" ] && printf '%s' "${FAKE_CURL_STATUS:-200}"
exit 0
