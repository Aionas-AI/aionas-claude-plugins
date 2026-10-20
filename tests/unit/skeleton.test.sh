#!/usr/bin/env bash
# The marketplace, the plugin manifest, hooks.json and the hook stubs (AIO-855).
. "$(dirname "$0")/../lib/harness.sh"

flat() { aionas_json_flatten "$1"; }

test_manifests_parse_and_agree() {
  local mk pj
  mk=$(flat "$T_REPO/.claude-plugin/marketplace.json") || t_fail "marketplace.json invalid"
  pj=$(flat "$T_PLUGIN/.claude-plugin/plugin.json") || t_fail "plugin.json invalid"
  t_eq aionas "$(aionas_json_get name <<<"$mk")"
  t_eq aionas-savings "$(aionas_json_get plugins.0.name <<<"$mk")"
  t_eq ./plugins/aionas-savings "$(aionas_json_get plugins.0.source <<<"$mk")"
  t_eq aionas-savings "$(aionas_json_get name <<<"$pj")"
  t_eq "$(aionas_json_get version <<<"$pj")" "$(aionas_json_get plugins.0.version <<<"$mk")" "versions differ"
  t_rc 1 aionas_json_get hooks <<<"$pj" # hooks/hooks.json loads by convention
}

# Every hook entry: event, matcher, command, async, asyncRewake (\037 separated:
# tabs would collapse empty fields in read).
entries() {
  flat "$T_PLUGIN/hooks/hooks.json" | awk -F '\t' '
    { v[$1] = $3; if ($1 ~ /^hooks\.[A-Za-z]+\.[0-9]+\.hooks\.[0-9]+$/) order[++n] = $1 }
    END {
      for (i = 1; i <= n; i++) {
        p = order[i]; split(p, s, "."); g = s[1] "." s[2] "." s[3]
        printf "%s\037%s\037%s\037%s\037%s\n", s[2], v[g ".matcher"], v[p ".command"], v[p ".async"], v[p ".asyncRewake"]
      }
    }'
}

test_hooks_json_registers_every_lane_entry() {
  local got
  got=$(entries | awk -F '\037' '{ c = $3; sub(/.*\/hooks\//, "", c); sub(/\\".*/, "", c); print $1 "/" $2 "/" c }' | sort | tr '\n' ' ')
  t_eq "PostToolUse//output-store.sh PreToolUse/Bash/noisy-guard.sh SessionStart//daily-scan.sh SessionStart//effort-window.sh SessionStart//policy-sync.sh SessionStart//unused-services.sh Stop//counters-flush.sh Stop//handoff-arm.sh UserPromptSubmit//handoff-cancel.sh " "$got"
}

test_hook_commands_point_at_executable_scripts() {
  local ev m cmd a r script
  while IFS=$'\037' read -r ev m cmd a r; do
    case "$cmd" in
      'bash \"${CLAUDE_PLUGIN_ROOT}/hooks/'*'.sh\"') ;;
      *) t_fail "$ev command is not bash \"\${CLAUDE_PLUGIN_ROOT}/hooks/<name>.sh\": $cmd" ;;
    esac
    script=${cmd#*hooks/}; script=${script%\\\"}
    t_ok test -x "$T_PLUGIN/hooks/$script"
  done < <(entries)
}

test_session_start_never_blocks() {
  local ev m cmd a r
  while IFS=$'\037' read -r ev m cmd a r; do
    [ "$ev" = SessionStart ] && t_eq true "$a" "SessionStart entry not async: $cmd"
  done < <(entries)
  return 0
}

test_stubs_exit_0_print_nothing_change_nothing() {
  local f out before after
  export CLAUDE_PLUGIN_ROOT="$T_PLUGIN"
  t_enroll
  before=$(cd "$HOME" && find . | sort)
  for f in "$T_PLUGIN"/hooks/*.sh; do
    out=$(printf '{"session_id":"s1","hook_event_name":"X","tool_name":"Bash","tool_input":{"command":"ls"}}' | bash "$f")
    t_rc 0 bash "$f" </dev/null
    t_eq "" "$out" "$(basename "$f") printed something"
  done
  after=$(cd "$HOME" && find . | sort)
  t_eq "$before" "$after" "a stub changed files"
  t_eq 0 "$(t_calls)"
}

t_main "$@"
