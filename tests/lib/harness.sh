# aionas-claude-plugins test harness (bash). A test file defines test_*
# functions and ends with: t_main "$@"
# Every test runs in its own subshell with a fresh temporary HOME, so nothing
# touches the real ~/.claude or ~/.aionas. Temporary folders are made with
# mktemp and left for the OS to clean (no recursive deletes).
set -u
T_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
T_PLUGIN="$T_REPO/plugins/aionas-savings"
T_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/aionas-test.XXXXXX")
T_ALIAS="aen-TESTALIAS0123456789abcdef"

# t_fresh: a new HOME and a clean environment for one test.
t_fresh() {
  HOME=$(mktemp -d "$T_ROOT/home.XXXXXX"); export HOME
  unset AIONAS_AGENT_DIR AIONAS_SAVINGS_DIR AIONAS_NOW AIONAS_UNAME CLAUDE_CONFIG_DIR
  export AIONAS_LIB="$T_PLUGIN/lib"
  export AIONAS_PLUGIN_ROOT="$T_PLUGIN"
  export AIONAS_CURL="$T_REPO/tests/lib/fake-curl.sh"
  FAKE_CURL_LOG=$(mktemp -d "$T_ROOT/curl.XXXXXX"); export FAKE_CURL_LOG
  unset FAKE_CURL_STATUS FAKE_CURL_BODY FAKE_CURL_EXIT FAKE_CURL_SLEEP
  # shellcheck disable=SC1091
  . "$T_PLUGIN/lib/aionas.sh"
}

# t_enroll [GATEWAY]: what the one install leaves on an enrolled computer.
t_enroll() {
  mkdir -p "$HOME/.aionas/agent"
  printf '%s\n' "$T_ALIAS" >"$HOME/.aionas/agent/credential"
  chmod 600 "$HOME/.aionas/agent/credential"
  printf '{"gateway":"%s","enrollment_id":"enr-TEST0001","machine_id":"m1","os":"darwin","installer_version":1}\n' \
    "${1:-https://gw.example.test}" >"$HOME/.aionas/agent/enrollment.json"
}

# t_calls: number of fake-curl calls so far. t_call N FIELD: one recorded field.
t_calls() { find "$FAKE_CURL_LOG" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' '; }
t_call() { cat "$FAKE_CURL_LOG/$1/$2"; }

# t_mode FILE: permission bits in octal (GNU stat, else BSD stat).
t_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

t_fail() { printf '    FAIL: %s\n' "$*" >&2; exit 1; }
t_eq() { [ "$1" = "$2" ] || t_fail "${3:-values differ}: expected [$1] got [$2]"; }
t_ok() { "$@" || t_fail "expected success: $*"; }
t_not() { if "$@"; then t_fail "expected failure: $*"; fi; }
t_rc() { local want=$1; shift; "$@"; local got=$?; [ "$got" = "$want" ] || t_fail "expected exit $want got $got: $*"; }
t_contains() { case "$1" in *"$2"*) ;; *) t_fail "${3:-missing} [$2] in [$1]" ;; esac; }
t_lacks() { case "$1" in *"$2"*) t_fail "${3:-unexpected} [$2] in [$1]" ;; esac; }

t_main() {
  local pass=0 fail=0 name only=${1:-}
  for name in $(declare -F | awk '{ print $3 }' | grep '^test_'); do
    [ -n "$only" ] && [ "$name" != "$only" ] && continue
    if (t_fresh && "$name"); then
      pass=$((pass + 1)); printf '  ok   %s\n' "$name"
    else
      fail=$((fail + 1)); printf '  FAIL %s\n' "$name"
    fi
  done
  printf '  %s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
  [ "$fail" -eq 0 ]
}
