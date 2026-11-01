#!/bin/bash
# A stand-in for the claude binary (tests/unit/usage-probe.test.sh). It never
# calls a model or the network. Each run logs under $STUB_LOG/run.<n>/:
#   argv0 argv cwd probe_env stdin env pid [hooks] [hook_rc] [hooks_changed]
# and then behaves as STUB_MODE says:
#   ok (default)       print the file $STUB_OUTPUT
#   exit1              print it, exit 1
#   hang               sleep 30 (TERM stops it)
#   hang-ignore-term   ignore TERM and loop until KILLed
# STUB_DELAY=<s> sleeps before printing. STUB_HOOK_LIST=<file> runs every script
# named in the file (one path per line) with this process's environment first.
log=${STUB_LOG:?}
n=1
while ! mkdir "$log/run.$n" 2>/dev/null; do n=$((n + 1)); done
d="$log/run.$n"
printf '%s\n' "$0" >"$d/argv0"
printf '%s\n' "$@" >"$d/argv"
pwd >"$d/cwd"
printf '%s' "${AIONAS_USAGE_PROBE-UNSET}" >"$d/probe_env"
/usr/bin/env | grep '^AIONAS_' | sort >"$d/env"
echo $$ >"$d/pid"
if IFS= read -r -t 1 _l; then
  echo data >"$d/stdin"
else
  if [ $? -gt 128 ]; then echo timeout >"$d/stdin"; else echo eof >"$d/stdin"; fi
fi

snap() {
  {
    ls "$FAKE_CURL_LOG" 2>/dev/null | wc -l
    find "$HOME/.aionas" -type f 2>/dev/null | sort | while IFS= read -r f; do
      printf '%s %s\n' "$f" "$(wc -c <"$f")"
    done
  } | cksum
}
if [ -n "${STUB_HOOK_LIST:-}" ]; then
  before=$(snap)
  : >"$d/hooks"
  : >"$d/hook_rc"
  while IFS= read -r h; do
    printf '%s\n' "$h" >>"$d/hooks"
    printf '{"session_id":"s1","hook_event_name":"SessionStart","source":"startup"}' | bash "$h" >>"$d/hook_out" 2>&1
    echo $? >>"$d/hook_rc"
  done <"$STUB_HOOK_LIST"
  after=$(snap)
  if [ "$before" = "$after" ]; then echo same >"$d/hooks_changed"; else echo changed >"$d/hooks_changed"; fi
fi

[ -n "${STUB_DELAY:-}" ] && sleep "$STUB_DELAY"
case "${STUB_MODE:-ok}" in
  hang) sleep 30 ;;
  hang-ignore-term)
    trap '' TERM
    while :; do sleep 1; done ;;
  exit1) cat "${STUB_OUTPUT:?}"; exit 1 ;;
  *) cat "${STUB_OUTPUT:?}" ;;
esac
exit 0
