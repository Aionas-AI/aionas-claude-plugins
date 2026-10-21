#!/usr/bin/env bash
# aionas-savings hook: effort-window (SessionStart, async). Owner: AIO-859 (W24-3).
#
#   effort-window.sh              (SessionStart, JSON on stdin) close an ended
#                                 /aionas-xhigh window and prune old grants.
#                                 Prints nothing, exits 0.
#   effort-window.sh grant SID    print this session's effort grant, decided
#                                 at the session's first sight and kept for
#                                 its whole life (resume, reload):
#                                   high   effort_default applies (the
#                                          settings cap, high, holds)
#                                   xhigh  opened in an xhigh window: start at
#                                   max    xhigh / max, may move up to max
#                                   free   effort_default is off, released or
#                                          bypassed: no cap from Aionas
#
# Mechanism, from the probe on Claude Code 2.1.299 (tests/probe/effort-probe.sh):
#  (a) maxEffortLevel=high in user settings caps /effort, --effort and any
#      rewrite of a request's effort (clamped at send time);
#  (b) a running session DOES pick up a change of maxEffortLevel in user
#      settings at once (hot reload).
# So the window never touches settings.json: writing maxEffortLevel=max would
# raise every open session, and restoring high would clamp the window's own
# sessions. Instead the settings stay at effortLevel=high, maxEffortLevel=high
# and env CLAUDE_CODE_EFFORT_LEVEL=high (the install's start-at-high pin: on
# 2.1.299 effortLevel alone loses to a per-model /effort entry), and the mod
# gives a granted session its level per request through
# CLAUDE_CODE_EXTRA_BODY ({"output_config":{"effort":...}}), which Claude Code
# documents as not clamped by maxEffortLevel. "Restores high after expiry" is
# therefore this hook dropping the ended window: new sessions are high again.
set -u
. "$(dirname "$0")/../lib/aionas.sh" 2>/dev/null || exit 0
. "$AIONAS_PLUGIN_ROOT/commands/aionas-bypass-lib.sh" 2>/dev/null || exit 0

# The window, when one is open now: prints "level status id".
effort_window_open() {
  _w="$(aionas_savings_dir)/effort-window"
  [ -f "$_w" ] || return 1
  awk -F '\t' -v now="$(aionas_now)" '
    NF >= 3 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $1 <= now && $2 > now && ($3 == "xhigh" || $3 == "max") {
      print $3, ($4 == "" ? "self" : $4), ($5 == "" ? "-" : $5); f = 1; exit
    }
    END { exit f ? 0 : 1 }' "$_w"
}

# An effort_default override from the server in force now (self from another
# computer, or a request approved since): prints its id.
effort_server_override() {
  _f=$(_aionas_policy_file "$1") || return 1
  awk -F '\t' -v now="$(aionas_now)" '
    $1 == "O" && $2 == "effort_default" && ($3 == "self" || $3 == "approved") && $4 <= now && $5 > now { print $6; f = 1; exit }
    END { exit f ? 0 : 1 }' "$_f"
}

effort_decide() {
  _sid=$1
  if effort_window_open >/dev/null; then
    set -- $(effort_window_open)
    echo "$1"
    return 0
  fi
  if _oid=$(effort_server_override "$_sid"); then
    if [ "$_oid" != - ] && grep -q "^$_oid	" "$(aionas_savings_dir)/effort-requests.tsv" 2>/dev/null; then
      aionas_effort_request_level "$_oid"
      return 0
    fi
  fi
  if aionas_policy_active effort_default "$_sid"; then echo high; else echo free; fi
}

effort_grant() {
  _aionas_sid_ok "$1" || { echo high; return 0; }
  _d="$(aionas_savings_dir)/sessions"
  _p="$_d/$1.effort"
  if [ -f "$_p" ]; then
    _g=$(cat "$_p" 2>/dev/null)
    case "$_g" in high | xhigh | max | free) echo "$_g"; return 0 ;; esac
  fi
  _g=$(effort_decide "$1")
  aionas_mkdir "$_d" && printf '%s\n' "$_g" | aionas_write_atomic "$_p"
  case "$_g" in
    high) aionas_counter_inc effort_default fired >/dev/null 2>&1 ;;
    free) aionas_counter_inc effort_default skipped >/dev/null 2>&1 ;;
  esac
  echo "$_g"
}

effort_cleanup() {
  _dir=$(aionas_savings_dir)
  [ -d "$_dir" ] || return 0
  if [ -f "$_dir/effort-window" ] && ! effort_window_open >/dev/null; then
    rm -f "$_dir/effort-window"
  fi
  [ -d "$_dir/sessions" ] || return 0
  # shellcheck disable=SC2012
  ls -1t "$_dir/sessions" 2>/dev/null | grep '\.effort$' | sed -n '201,$p' | while IFS= read -r _old; do
    rm -f "$_dir/sessions/$_old"
  done
}

case "${1:-}" in
  grant)
    effort_grant "${2:-}"
    exit 0
    ;;
esac
cat >/dev/null 2>&1 || true
effort_cleanup >/dev/null 2>&1
exit 0
