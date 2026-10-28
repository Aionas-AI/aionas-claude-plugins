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

# Every hook entry: event, matcher, command, async, asyncRewake, timeout (\037
# separated: tabs would collapse empty fields in read).
entries() {
  flat "$T_PLUGIN/hooks/hooks.json" | awk -F '\t' '
    { v[$1] = $3; if ($1 ~ /^hooks\.[A-Za-z]+\.[0-9]+\.hooks\.[0-9]+$/) order[++n] = $1 }
    END {
      for (i = 1; i <= n; i++) {
        p = order[i]; split(p, s, "."); g = s[1] "." s[2] "." s[3]
        printf "%s\037%s\037%s\037%s\037%s\037%s\n", s[2], v[g ".matcher"], v[p ".command"], v[p ".async"], v[p ".asyncRewake"], v[p ".timeout"]
      }
    }'
}

test_hooks_json_registers_every_lane_entry() {
  local got
  got=$(entries | awk -F '\037' '{ c = $3; sub(/.*\/hooks\//, "", c); sub(/\\".*/, "", c); print $1 "/" $2 "/" c }' | sort | tr '\n' ' ')
  t_eq "PostToolUse//output-store.sh PreToolUse/Bash/noisy-guard.sh SessionStart//daily-scan.sh SessionStart//effort-window.sh SessionStart//plan-report.sh SessionStart//policy-sync.sh SessionStart//unused-services-notice.sh SessionStart//unused-services.sh SessionStart//write-minimum.sh Stop//counters-flush.sh Stop//handoff-arm.sh UserPromptSubmit//handoff-cancel.sh " "$got"
}

test_hook_commands_point_at_executable_scripts() {
  local ev m cmd a r to script
  while IFS=$'\037' read -r ev m cmd a r to; do
    case "$cmd" in
      'bash \"${CLAUDE_PLUGIN_ROOT}/hooks/'*'.sh\"') ;;
      *) t_fail "$ev command is not bash \"\${CLAUDE_PLUGIN_ROOT}/hooks/<name>.sh\": $cmd" ;;
    esac
    script=${cmd#*hooks/}; script=${script%\\\"}
    t_ok test -x "$T_PLUGIN/hooks/$script"
  done < <(entries)
}

# SessionStart never delays the session: every entry is async, except the one
# unused-services notice, which must print the one-line systemMessage before
# the first prompt. That one reads a local file only, so it stays sync with a
# 5 s timeout and must not touch the network.
test_session_start_never_blocks() {
  local ev m cmd a r to sync=""
  while IFS=$'\037' read -r ev m cmd a r to; do
    [ "$ev" = SessionStart ] || continue
    [ "$a" = true ] && continue
    sync="$sync $(basename "${cmd%\\\"}")"
    t_eq 5 "$to" "a sync SessionStart entry needs timeout 5: $cmd"
  done < <(entries)
  # Only these two print to the session (an async hook's output is not used):
  # the turned-off-services notice and write_minimum's context (AIO-889).
  # Both read local files only.
  t_eq " unused-services-notice.sh write-minimum.sh" "$sync" "the only sync SessionStart entries"
  local f
  for f in unused-services-notice.sh write-minimum.sh; do
    t_lacks "$(cat "$T_PLUGIN/hooks/$f")" "aionas_http" "$f must not use the network"
    t_lacks "$(cat "$T_PLUGIN/hooks/$f")" "curl" "$f must not use the network"
  done
}

# The notice, run the way hooks.json runs it: silent when nothing is pending,
# the systemMessage JSON once when the daily run turned something off, and
# never a network call.
test_unused_notice_entry_prints_once_and_stays_local() {
  local out
  export CLAUDE_PLUGIN_ROOT="$T_PLUGIN"
  t_enroll
  out=$(printf '{"session_id":"s1","hook_event_name":"SessionStart"}' | bash "$T_PLUGIN/hooks/unused-services-notice.sh")
  t_eq "" "$out" "printed with nothing pending"
  mkdir -p "$(aionas_savings_dir)/unused"
  printf 'mcp\tslack\t30\n' >"$(aionas_savings_dir)/unused/notice.pending"
  out=$(printf '{"session_id":"s2","hook_event_name":"SessionStart"}' | bash "$T_PLUGIN/hooks/unused-services-notice.sh")
  t_contains "$out" '{"systemMessage":"Aionas turned off services with no calls in 30 days:' "no notice"
  t_contains "$out" "slack" "notice lacks the server name"
  out=$(printf '{"session_id":"s3","hook_event_name":"SessionStart"}' | bash "$T_PLUGIN/hooks/unused-services-notice.sh")
  t_eq "" "$out" "notice shown twice"
  t_eq 0 "$(t_calls)"
}

# A stub that silently does nothing must not ship. Every hook script hooks.json
# names has to carry real work: no skeleton marker, and at least one code line
# that delegates (exec bash ...) or calls a library function (aionas_...).
test_no_registered_script_is_a_silent_stub() {
  local ev m cmd a r to script
  while IFS=$'\037' read -r ev m cmd a r to; do
    script=${cmd#*hooks/}; script=${script%\\\"}
    t_not grep -q 'STUB (wave-24 skeleton)' "$T_PLUGIN/hooks/$script"
    t_ok grep -Eq '^[[:space:]]*(exec[[:space:]]+bash|([^#[:space:]][^#]*)?aionas_)' "$T_PLUGIN/hooks/$script"
  done < <(entries)
  # the checker itself: a stub body and a do-nothing body do not pass it
  printf '#!/usr/bin/env bash\n# STUB (wave-24 skeleton)\nexit 0\n' >"$T_ROOT/stub.sh"
  t_not grep -Eq '^[[:space:]]*(exec[[:space:]]+bash|([^#[:space:]][^#]*)?aionas_)' "$T_ROOT/stub.sh"
}

# Scripts must reach a Windows (Git Bash) clone with LF endings, whatever
# core.autocrlf says; only .cmd wants CRLF.
test_gitattributes_forces_lf_on_scripts() {
  local f eol
  t_ok test -f "$T_REPO/.gitattributes"
  for f in plugins/aionas-savings/hooks/noisy-guard.sh plugins/aionas-savings/hooks/pretool-guard.awk \
    plugins/aionas-savings/hooks/pretool-guard.lib plugins/aionas-savings/lib/aionas.sh \
    plugins/aionas-savings/lib/json.awk plugins/aionas-savings/commands/aionas-bypass.sh \
    plugins/aionas-savings/bin/aionas-recall plugins/aionas-savings/rules/guard-store.tsv; do
    eol=$(git -C "$T_REPO" check-attr eol -- "$f" | sed 's/.*: //')
    t_eq lf "$eol" "$f is not forced to LF"
  done
  eol=$(git -C "$T_REPO" check-attr eol -- plugins/aionas-savings/bin/aionas-recall.cmd | sed 's/.*: //')
  t_eq crlf "$eol" "aionas-recall.cmd"
}

t_main "$@"
