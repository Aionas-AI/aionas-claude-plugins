# aionas-savings shared library. Source it from a hook:
#   . "$(dirname "$0")/../lib/aionas.sh"
# POSIX sh (bash 3.2 on macOS, dash, Git Bash on Windows); needs only awk,
# grep, tr, date, mkdir, mv, rm and curl. Nothing here prints content: the
# only network calls are the policy fetch and the counters send.
if [ -z "${AIONAS_LIB:-}" ]; then
  if [ -n "${BASH_SOURCE:-}" ]; then
    AIONAS_LIB=$(cd "$(dirname "${BASH_SOURCE}")" && pwd)
  elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    AIONAS_LIB="$CLAUDE_PLUGIN_ROOT/lib"
  fi
fi
AIONAS_PLUGIN_ROOT=${AIONAS_PLUGIN_ROOT:-$(dirname "$AIONAS_LIB")}
. "$AIONAS_LIB/platform.sh"
. "$AIONAS_LIB/json.sh"
. "$AIONAS_LIB/catalog.sh"
. "$AIONAS_LIB/enroll.sh"
. "$AIONAS_LIB/http.sh"
. "$AIONAS_LIB/policy.sh"
. "$AIONAS_LIB/counters.sh"

# aionas_plugin_version: the version in .claude-plugin/plugin.json.
aionas_plugin_version() {
  aionas_json_flatten "$AIONAS_PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null | aionas_json_get version
}
