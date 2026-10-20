#!/usr/bin/env bash
# aionas-savings hook: daily-scan (SessionStart, async). Trigger owner: AIO-855;
# the scanner is AIO-854's.
# At the first session start of each UTC day, starts the installed history
# scanner, `aionas-scan --incremental`, detached at low priority, and returns
# at once. The scanner keeps its own position, cap (20 s) and upload. Nothing
# runs on a computer that is not enrolled or has no scanner installed.
#
# The scanner is looked up as: $AIONAS_SCAN_BIN, then
# ~/.aionas/agent/bin/aionas-scan (aionas-scan.exe on Windows), then PATH.
# Prints nothing, exits 0.
set -u
. "$(dirname "$0")/../lib/aionas.sh" 2>/dev/null || exit 0
cat >/dev/null 2>&1 || true

find_scanner() {
  if [ -n "${AIONAS_SCAN_BIN:-}" ]; then
    [ -x "$AIONAS_SCAN_BIN" ] && { echo "$AIONAS_SCAN_BIN"; return 0; }
    return 1
  fi
  for _b in "$(aionas_agent_dir)/bin/aionas-scan" "$(aionas_agent_dir)/bin/aionas-scan.exe"; do
    [ -f "$_b" ] && [ -x "$_b" ] && { echo "$_b"; return 0; }
  done
  command -v aionas-scan 2>/dev/null
}

aionas_enroll_has_alias || exit 0
aionas_enroll_gateway >/dev/null 2>&1 || exit 0
bin=$(find_scanner) || exit 0
[ -n "$bin" ] || exit 0
dir=$(aionas_savings_dir)
aionas_mkdir "$dir" || exit 0
today=$(aionas_day_utc)
[ "$(cat "$dir/scan.day" 2>/dev/null)" = "$today" ] && exit 0
aionas_lock_try daily-scan 300 || exit 0
if [ "$(cat "$dir/scan.day" 2>/dev/null)" != "$today" ]; then
  printf '%s\n' "$today" | aionas_write_atomic "$dir/scan.day"
  nice_cmd=""
  command -v nice >/dev/null 2>&1 && nice_cmd="nice -n 19"
  # Detached: stdio closed, immune to the session's hangup; this hook returns now.
  # shellcheck disable=SC2086
  (cd "$dir" && exec nohup $nice_cmd "$bin" --incremental </dev/null >/dev/null 2>&1) &
fi
aionas_lock_release daily-scan
exit 0
