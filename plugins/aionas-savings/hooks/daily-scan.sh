#!/usr/bin/env bash
# aionas-savings hook: daily-scan (SessionStart, async). Trigger owner: AIO-855;
# the scanner is AIO-854's.
# At the first session start of each UTC day, starts the installed history
# scanner, `aionas-scan --incremental --post`, detached at low priority, and returns
# at once. The scanner keeps its own position, cap (20 s) and upload. Nothing
# runs on a computer that is not enrolled or has no scanner installed.
#
# The scanner is looked up as: $AIONAS_SCAN_BIN, then
# ~/.aionas/agent/tools/aionas-scan (where the installer puts it; aionas-scan.exe
# on Windows), then ~/.aionas/agent/bin/aionas-scan, never PATH: a project or package
# could put its own aionas-scan there and have it run detached. Nothing else is
# run from PATH either: nice is /usr/bin/nice when there is one, and the hangup
# is ignored with trap instead of nohup (AIO-1072).
#
# --post is required: without it the scanner counts, moves its position and
# marks the day as scanned, but sends nothing, and the plan-usage backup then
# skips that day, so the day is lost for good (found 2026-11-24 on Foretellix).
#
# The upload is the scanner's, not this hook's (AIO-1072, finding 7): the line
# below is what it sends, and tests/security/egress-manifest.sh lists it as
# "delegated" in security/egress-manifest.txt, next to the one program this
# hook starts ("run"), so a change to either shows up in review.
AIONAS_SCAN_EGRESS='aionas-scan --incremental --post -> POST /enroll/v1/savings/retro with the enrollment alias: run{source,mode,status,sessions,scanner_version}, totals[]{day,repo,project_path,kind,key,count,sessions,input_tokens,output_tokens,cache_read_tokens,cache_write_5m_tokens,cache_write_1h_tokens,tokens,cost_usd}'
# Prints nothing, exits 0.
set -u
. "$(dirname "$0")/../lib/aionas.sh" 2>/dev/null || exit 0
cat >/dev/null 2>&1 || true

find_scanner() {
  if [ -n "${AIONAS_SCAN_BIN:-}" ]; then
    [ -x "$AIONAS_SCAN_BIN" ] && { echo "$AIONAS_SCAN_BIN"; return 0; }
    return 1
  fi
  for _b in "$(aionas_agent_dir)/tools/aionas-scan" "$(aionas_agent_dir)/tools/aionas-scan.exe" \
    "$(aionas_agent_dir)/bin/aionas-scan" "$(aionas_agent_dir)/bin/aionas-scan.exe"; do
    [ -f "$_b" ] && [ -x "$_b" ] && { echo "$_b"; return 0; }
  done
  return 1
}

aionas_enroll_has_alias || exit 0
gw=$(aionas_enroll_gateway 2>/dev/null) || exit 0
[ -n "$gw" ] || exit 0
bin=$(find_scanner) || exit 0
[ -n "$bin" ] || exit 0
dir=$(aionas_savings_dir)
aionas_mkdir "$dir" || exit 0
today=$(aionas_day_utc)
[ "$(cat "$dir/scan.day" 2>/dev/null)" = "$today" ] && exit 0
aionas_lock_try daily-scan 300 || exit 0
if [ "$(cat "$dir/scan.day" 2>/dev/null)" != "$today" ]; then
  printf '%s\n' "$today" | aionas_write_atomic "$dir/scan.day"
  # Detached: stdio closed, immune to the session's hangup; this hook returns now.
  if [ -x /usr/bin/nice ]; then
    (cd "$dir" && trap '' HUP && exec /usr/bin/nice -n 19 "$bin" --incremental --post --gateway "$gw" </dev/null >/dev/null 2>&1) &
  else
    (cd "$dir" && trap '' HUP && exec "$bin" --incremental --post --gateway "$gw" </dev/null >/dev/null 2>&1) &
  fi
fi
aionas_lock_release daily-scan
exit 0
