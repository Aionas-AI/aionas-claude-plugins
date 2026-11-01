#!/usr/bin/env bash
# aionas-savings hook: script-refresh (SessionStart, async). Owner: AIO-904.
# The one install puts the plan collector and the status-line tap in
# ~/.aionas/agent/tools. The plugin updates itself, those scripts did not: this
# hook brings them to the release the gateway serves, so a fix reaches every
# computer without a new install.
#
# At most once per UTC day (the day is stamped BEFORE the manifest request, so
# a failed check is retried the next day only), on an enrolled computer only:
#   1. GET <gateway>/enroll/v1/scripts/manifest (enrollment alias, like every
#      /enroll/v1 call). Only a 200 with valid JSON is used.
#   2. For each of the four fixed names that is ALREADY installed as a regular
#      file, and whose AIONAS_RELEASE stamp differs from the manifest version:
#      download it from the PUBLIC route /api/aionas/onboarding/scripts/<name>
#      WITHOUT the alias, from the enrolled gateway only (https, or http for
#      localhost / 127.0.0.1). No URL is ever taken from the manifest.
#   3. Install it only if the sha256 equals the manifest's (hash tool at a
#      fixed system path, never PATH; none found = nothing installed), a .sh
#      starts with "#!", and the stamp inside the bytes equals the version
#      (else it would never converge). The new file is written next to the old
#      one and renamed over it (a running bash reads its script lazily, so an
#      in-place write could break it); the old one is kept as <name>.prev
#      until a later day. Any failed check keeps the old file.
# It never writes settings.json, never adds a file to the tools folder other
# than the temp and .prev of an installed name, and never deletes recursively.
# Prints nothing, always exits 0.
set -u
. "$(dirname "$0")/../lib/aionas.sh" 2>/dev/null || exit 0
. "$AIONAS_LIB/script-refresh.sh" 2>/dev/null || exit 0
cat >/dev/null 2>&1 || true

aionas_enroll_has_alias || exit 0
aionas_enroll_gateway >/dev/null 2>&1 || exit 0
tools="$(aionas_agent_dir)/tools"
# Nothing installed, nothing to refresh (and no request is made for it).
_sr_any=""
for _sr_n in $AIONAS_SR_NAMES; do
  [ -f "$tools/$_sr_n" ] && [ ! -L "$tools/$_sr_n" ] && _sr_any=1
done
[ -n "$_sr_any" ] || exit 0
dir=$(aionas_savings_dir)
aionas_mkdir "$dir" || exit 0
today=$(aionas_day_utc)
[ "$(cat "$dir/script-refresh.day" 2>/dev/null)" = "$today" ] && exit 0
aionas_lock_try script-refresh 120 || exit 0

_sr_tmp=""
_sr_mf="$dir/script-refresh.manifest.$$"
_sr_finish() {
  if [ -n "$_sr_tmp" ]; then rm -f "$_sr_tmp"; fi
  rm -f "$_sr_mf"
  aionas_lock_release script-refresh
}
trap _sr_finish EXIT
trap 'exit 0' HUP INT TERM

[ "$(cat "$dir/script-refresh.day" 2>/dev/null)" = "$today" ] && exit 0
printf '%s\n' "$today" | aionas_write_atomic "$dir/script-refresh.day" || exit 0

# Yesterday's leftovers, removed by exact name (never recursive): temp files
# of a run that was killed, and the .prev copies once their day has passed.
_sr_prevday=$(cat "$dir/script-refresh.prevday" 2>/dev/null)
for _sr_n in $AIONAS_SR_NAMES; do
  for _sr_f in "$tools/$_sr_n".tmp.*; do
    case "${_sr_f##*.tmp.}" in '' | *[!0-9]*) continue ;; esac
    if [ -e "$_sr_f" ] || [ -L "$_sr_f" ]; then rm -f "$_sr_f"; fi
  done
  if [ "$_sr_prevday" != "$today" ]; then rm -f "$tools/$_sr_n.prev"; fi
done
if [ "$_sr_prevday" != "$today" ]; then rm -f "$dir/script-refresh.prevday"; fi
# A killed run's manifest download: removed by exact matched name, one at a time.
for _sr_f in "$dir"/script-refresh.manifest.*; do
  case "${_sr_f##*script-refresh.manifest.}" in '' | *[!0-9]*) continue ;; esac
  if [ -f "$_sr_f" ] || [ -L "$_sr_f" ]; then rm -f -- "$_sr_f"; fi
done

# _sr_one NAME VERSION SHA256: refresh one script; returns 1 when it kept the old one.
_sr_one() {
  _so_f="$tools/$1"
  [ -f "$_so_f" ] && [ ! -L "$_so_f" ] || return 1
  aionas_sr_version_ok "$2" || return 1
  aionas_sr_sha_ok "$3" || return 1
  [ "$(aionas_sr_stamp "$_so_f")" = "$2" ] && return 0
  _sr_tmp="$tools/$1.tmp.$$"
  (umask 077; set -C; : >"$_sr_tmp") 2>/dev/null || { _sr_tmp=""; return 1; }
  _so_code=$(aionas_http_public GET "/api/aionas/onboarding/scripts/$1" "$_sr_tmp" 2>/dev/null)
  if [ "$_so_code" != 200 ] || [ ! -s "$_sr_tmp" ] ||
    [ "$(aionas_sr_sha256 "$_sr_tmp")" != "$3" ] ||
    [ "$(aionas_sr_stamp "$_sr_tmp" "$1")" != "$2" ]; then
    rm -f "$_sr_tmp"; _sr_tmp=""; return 1
  fi
  case "$1" in
    *.sh) [ "$(head -c 2 "$_sr_tmp")" = '#!' ] || { rm -f "$_sr_tmp"; _sr_tmp=""; return 1; } ;;
  esac
  chmod 700 "$_sr_tmp" 2>/dev/null || { rm -f "$_sr_tmp"; _sr_tmp=""; return 1; }
  rm -f "$_so_f.prev"
  if ! (umask 077; cp "$_so_f" "$_so_f.prev") 2>/dev/null; then
    rm -f "$_so_f.prev" "$_sr_tmp"; _sr_tmp=""; return 1
  fi
  chmod 700 "$_so_f.prev" 2>/dev/null
  if ! mv -f "$_sr_tmp" "$_so_f" 2>/dev/null; then
    rm -f "$_so_f.prev" "$_sr_tmp"; _sr_tmp=""; return 1
  fi
  _sr_tmp=""
  printf '%s\n' "$today" | aionas_write_atomic "$dir/script-refresh.prevday"
  return 0
}

_sr_code=$(aionas_http GET /enroll/v1/scripts/manifest - "$_sr_mf" 2>/dev/null)
[ "$_sr_code" = 200 ] || exit 0
[ "$(wc -c <"$_sr_mf" 2>/dev/null | tr -d ' ')" -le 65536 ] 2>/dev/null || exit 0
_sr_flat=$(aionas_json_flatten "$_sr_mf" 2>/dev/null) || exit 0

# Only a real JSON array is read: an object, or top-level keys that merely
# look like "scripts.0.name", are not a manifest.
[ "$(printf '%s\n' "$_sr_flat" | aionas_json_type scripts)" = a ] || exit 0

_sr_seen=" "
_sr_i=0
while [ "$_sr_i" -lt 8 ]; do
  _sr_name=$(printf '%s\n' "$_sr_flat" | aionas_json_get "scripts.$_sr_i.name") || break
  _sr_i=$((_sr_i + 1))
  aionas_sr_name_ok "$_sr_name" || continue
  case "$_sr_seen" in *" $_sr_name "*) continue ;; esac
  _sr_seen="$_sr_seen$_sr_name "
  _sr_k="scripts.$((_sr_i - 1))"
  _sr_ver=$(printf '%s\n' "$_sr_flat" | aionas_json_get "$_sr_k.version") || continue
  _sr_sha=$(printf '%s\n' "$_sr_flat" | aionas_json_get "$_sr_k.sha256") || continue
  [ "$(printf '%s\n' "$_sr_flat" | aionas_json_type "$_sr_k.version")" = s ] || continue
  [ "$(printf '%s\n' "$_sr_flat" | aionas_json_type "$_sr_k.sha256")" = s ] || continue
  _sr_one "$_sr_name" "$_sr_ver" "$_sr_sha" >/dev/null 2>&1
done
exit 0
