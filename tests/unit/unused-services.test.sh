#!/usr/bin/env bash
# hooks/unused-services.sh + unused-services-notice.sh: turn off MCP servers,
# connectors and skills with no calls in 30 days, in the person's own settings (AIO-861)
. "$(dirname "$0")/../lib/harness.sh"
. "$T_PLUGIN/lib/unused.sh"

T0=1792490400 # 2026-10-20T10:00:00Z
DAY=86400
HOOK="$T_PLUGIN/hooks/unused-services.sh"
NOTICE="$T_PLUGIN/hooks/unused-services-notice.sh"

iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z; }

# setup: a project folder, a Claude config with three MCP servers.
setup() {
  mkdir -p "$HOME/work/proj" "$HOME/.claude/projects/-work-proj"
  CJ="$HOME/.claude.json"
  PK=$(cd "$HOME/work/proj" && pwd -P)
  HIST="$HOME/.claude/projects/-work-proj/s1.jsonl"
  : >"$HIST"
  cat >"$CJ" <<JSON
{
  "numStartups": 12,
  "mcpServers": {
    "alpha": {"type": "stdio", "command": "a"},
    "beta": {"type": "stdio", "command": "b"},
    "gamma": {"type": "http", "url": "https://g.example.test/mcp"}
  },
  "projects": {
    "$PK": {"allowedTools": [], "disabledMcpServers": []}
  }
}
JSON
  export AIONAS_NOW=$T0
}
# call SECONDS_AGO TOOL: a history line, as Claude Code writes it.
call() {
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_01","name":"%s","input":{"query":"SECRET-PROMPT-TEXT"}}]},"uuid":"u1","timestamp":"%s"}\n' \
    "$2" "$(iso $((${AIONAS_NOW:-$T0} - $1)))" >>"$HIST"
}
slash() { printf '{"type":"user","message":{"role":"user","content":"<command-name>/%s</command-name> SECRET-PROMPT-TEXT"},"timestamp":"%s"}\n' "$2" "$(iso $((T0 - $1)))" >>"$HIST"; }
hook() { printf '{"session_id":"s1","hook_event_name":"SessionStart","cwd":"%s"}' "${1:-$HOME/work/proj}" | bash "$HOOK"; }
disabled() { aionas_unused_j items "$CJ" "" projects "$PK" disabledMcpServers | tr '\n' ' '; }
queue() { cat "$(aionas_savings_dir)/counters/queue.tsv" 2>/dev/null | cut -f2- | sort | uniq -c | sed 's/^ *//' | tr '\n' ';'; }
ud() { echo "$(aionas_savings_dir)/unused"; }

test_turns_off_only_servers_with_no_call_in_30_days() {
  setup
  call $((5 * DAY)) mcp__alpha__search # used 5 days ago
  call $((31 * DAY)) mcp__beta__read   # unused 31 days
  call $((45 * DAY)) mcp__gamma__list  # unused 45 days
  call $((2 * DAY)) mcp__alpha__other
  out=$(hook); t_rc 0 hook
  t_eq "" "$out" "the async hook prints nothing"
  t_eq "beta gamma " "$(disabled)"
  # the rest of the config is untouched
  t_eq 3 "$(aionas_unused_j members "$CJ" "" mcpServers | wc -l | tr -d ' ')"
  t_contains "$(cat "$CJ")" '"numStartups": 12'
  t_contains "$(cat "$CJ")" '"allowedTools": []'
  # one counter per turn-off, numbers only
  t_eq 2 "$(awk -F '\t' '$2 == "unused_services" && $3 == "fired" { n += $4 } END { print n }' "$(aionas_savings_dir)/counters/queue.tsv")"
}

test_notice_is_one_line_shown_once_in_the_next_session() {
  setup
  call $((31 * DAY)) mcp__beta__read
  call $((45 * DAY)) mcp__gamma__list
  call 1 mcp__alpha__x
  hook
  out=$(bash "$NOTICE" </dev/null)
  t_eq 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
  t_contains "$out" '"systemMessage"'
  t_contains "$out" 'beta, gamma'
  t_contains "$out" '30 days'
  t_contains "$out" '/mcp'
  t_lacks "$out" alpha
  t_eq "" "$(bash "$NOTICE" </dev/null)" "shown once"
  t_rc 0 bash "$NOTICE" </dev/null
}

test_person_turns_one_back_on_and_it_stays_on_for_30_days() {
  setup
  call $((31 * DAY)) mcp__beta__read
  call $((45 * DAY)) mcp__gamma__list
  hook
  t_eq "beta gamma " "$(disabled)"
  # the developer runs /mcp and re-enables beta (what /mcp writes)
  aionas_unused_jedit "$CJ" del-item beta projects "$PK" disabledMcpServers
  t_eq "gamma " "$(disabled)"
  # next sessions on later days: beta is not turned off again
  AIONAS_NOW=$((T0 + DAY)) hook
  t_eq "gamma " "$(disabled)"
  t_eq "mcp	beta	$((T0 + DAY))" "$(cat "$(ud)/reenabled.tsv")" "the turn-on is recorded"
  t_eq 1 "$(awk -F '\t' '$2 == "unused_services" && $3 == "bypass" { n += $4 } END { print n + 0 }' "$(aionas_savings_dir)/counters/queue.tsv")" "the turn-on is counted"
  AIONAS_NOW=$((T0 + 20 * DAY)) call 1 mcp__alpha__x
  AIONAS_NOW=$((T0 + 20 * DAY)) hook
  t_eq "gamma " "$(disabled)"
  AIONAS_NOW=$((T0 + 30 * DAY)) call 1 mcp__alpha__x
  AIONAS_NOW=$((T0 + 30 * DAY)) hook
  t_eq "gamma " "$(disabled)" "still inside 30 days of the re-enable"
  # 30 days after the re-enable, still unused: turned off again that day
  AIONAS_NOW=$((T0 + 31 * DAY)) call 1 mcp__alpha__x
  AIONAS_NOW=$((T0 + 31 * DAY)) hook
  t_eq "gamma beta " "$(disabled)"
}

test_a_server_reaching_30_days_later_is_turned_off_that_day() {
  setup
  call $((29 * DAY)) mcp__alpha__x
  call 1 mcp__beta__y
  hook
  t_eq "" "$(disabled)" "29 unused days"
  AIONAS_NOW=$((T0 + DAY)) hook
  t_eq "alpha " "$(disabled)" "alpha crossed 30 days on this day's run"
}

test_a_server_never_called_is_counted_from_when_it_was_first_seen() {
  setup
  call 1 mcp__alpha__x
  hook
  t_eq "" "$(disabled)" "gamma and beta have never been called, but were first seen today"
  t_contains "$(cat "$(ud)/seen.tsv")" "mcp	gamma	$T0"
  AIONAS_NOW=$((T0 + 29 * DAY)) call 1 mcp__alpha__x
  AIONAS_NOW=$((T0 + 29 * DAY)) hook
  t_eq "" "$(disabled)"
  AIONAS_NOW=$((T0 + 30 * DAY)) call 1 mcp__alpha__x
  AIONAS_NOW=$((T0 + 30 * DAY)) hook
  t_eq "beta gamma " "$(disabled)"
}

test_runs_once_per_utc_day() {
  setup
  call $((40 * DAY)) mcp__beta__x
  hook
  t_eq "beta " "$(disabled)"
  t_eq 1 "$(wc -l <"$(aionas_savings_dir)/counters/queue.tsv" | tr -d ' ')"
  t_eq "$(aionas_day_utc)" "$(cat "$(ud)/last_run_day")"
  # a second session the same day does not scan again
  call $((40 * DAY)) mcp__gamma__x
  AIONAS_NOW=$((T0 + 3600)) hook
  t_eq "beta " "$(disabled)"
  AIONAS_NOW=$((T0 + DAY)) hook
  t_eq "beta gamma " "$(disabled)"
}

test_only_tool_use_lines_count_as_calls() {
  setup
  # beta is only mentioned in text (a tool result quoting an earlier name)
  printf '{"type":"user","message":{"content":[{"type":"tool_result","content":"{\\"name\\":\\"mcp__beta__x\\"}"}]},"timestamp":"%s"}\n' "$(iso $((T0 - 60)))" >>"$HIST"
  call $((40 * DAY)) mcp__beta__x
  hook
  t_eq "beta " "$(disabled)"
}

test_servers_of_the_aionas_product_and_plugin_are_never_touched() {
  setup
  aionas_unused_jedit "$CJ" set-str 0 numStartups >/dev/null 2>&1
  cat >"$CJ" <<JSON
{"mcpServers": {"aionas": {"type": "http", "url": "https://x"}, "Aionas-Gateway": {"type": "http", "url": "https://y"}, "beta": {"type": "stdio", "command": "b"}},
 "projects": {"$PK": {}}}
JSON
  call $((90 * DAY)) mcp__aionas__x
  call $((90 * DAY)) mcp__Aionas-Gateway__x
  call $((90 * DAY)) mcp__beta__x
  hook
  t_eq "beta " "$(disabled)"
}

test_claude_ai_connectors_turn_off_like_servers() {
  setup
  cat >"$CJ" <<JSON
{"claudeAiMcpEverConnected": ["claude.ai Gmail", "claude.ai Slack"], "projects": {"$PK": {}}}
JSON
  call $((3 * DAY)) mcp__claude_ai_Slack__post
  call $((50 * DAY)) mcp__claude_ai_Gmail__search
  hook
  t_eq "claude.ai Gmail " "$(disabled)"
}

test_local_scope_servers_of_this_project_count_too() {
  setup
  cat >"$CJ" <<JSON
{"mcpServers": {"alpha": {}}, "projects": {"$PK": {"mcpServers": {"localsrv": {"command": "l"}}}}}
JSON
  call $((60 * DAY)) mcp__localsrv__x
  call $((60 * DAY)) mcp__alpha__x
  hook
  t_eq "alpha localsrv " "$(disabled)"
}

test_skills_unused_are_set_off_in_user_settings() {
  setup
  for s in used-skill slash-skill old-skill kept-skill; do
    mkdir -p "$HOME/.claude/skills/$s"
    printf -- '---\nname: %s\ndescription: d\n---\nbody\n' "$s" >"$HOME/.claude/skills/$s/SKILL.md"
  done
  printf '{"model": "sonnet", "skillOverrides": {"kept-skill": "name-only"}}\n' >"$HOME/.claude/settings.json"
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"Skill","input":{"skill":"used-skill"}}]},"timestamp":"%s"}\n' "$(iso $((T0 - 2 * DAY)))" >>"$HIST"
  slash 3 slash-skill
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"Skill","input":{"skill":"old-skill"}}]},"timestamp":"%s"}\n' "$(iso $((T0 - 40 * DAY)))" >>"$HIST"
  hook
  local ov; ov=$(aionas_unused_j members "$HOME/.claude/settings.json" "" skillOverrides | tr '\t\n' ' ')
  t_eq "kept-skill s name-only old-skill s off " "$ov"
  t_contains "$(cat "$HOME/.claude/settings.json")" '"model": "sonnet"'
  # the notice names it
  t_contains "$(bash "$NOTICE" </dev/null)" "skills old-skill"
}

test_skill_names_come_from_the_frontmatter_else_the_folder() {
  setup
  mkdir -p "$HOME/.claude/skills/dir-a" "$HOME/.claude/skills/dir-b" "$HOME/.claude/skills/no-md"
  printf -- '---\nname: "fm-name"\n---\n' >"$HOME/.claude/skills/dir-a/SKILL.md"
  printf -- 'no frontmatter\nname: ignored\n' >"$HOME/.claude/skills/dir-b/SKILL.md"
  t_eq "fm-name
dir-b" "$(aionas_unused_configured_skills)"
}

test_skill_the_person_turns_back_on_is_left_alone_for_30_days() {
  setup
  mkdir -p "$HOME/.claude/skills/old"
  printf -- '---\nname: old\n---\n' >"$HOME/.claude/skills/old/SKILL.md"
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"Skill","input":{"skill":"old"}}]},"timestamp":"%s"}\n' "$(iso $((T0 - 40 * DAY)))" >>"$HIST"
  hook
  skill_state() { aionas_unused_j members "$HOME/.claude/settings.json" "" skillOverrides | awk -F '\t' '$1 == "old" { print $3 }'; }
  t_eq off "$(skill_state)"
  aionas_unused_jedit "$HOME/.claude/settings.json" set-str on skillOverrides old
  AIONAS_NOW=$((T0 + DAY)) hook
  t_eq on "$(skill_state)"
  t_eq "skill	old	$((T0 + DAY))" "$(cat "$(ud)/reenabled.tsv")"
  AIONAS_NOW=$((T0 + 2 * DAY)) hook
  t_eq on "$(skill_state)"
  AIONAS_NOW=$((T0 + 30 * DAY)) hook
  t_eq on "$(skill_state)" "still inside 30 days"
  AIONAS_NOW=$((T0 + 31 * DAY)) hook
  t_eq off "$(skill_state)" "unused again after the 30 days"
}

test_only_this_computers_user_files_are_written() {
  setup
  call $((60 * DAY)) mcp__beta__x
  mkdir -p "$HOME/managed"
  printf '{"deniedMcpServers": []}\n' >"$HOME/managed/managed-settings.json"
  mkdir -p "$HOME/work/proj/.claude"
  printf '{"permissions": {}}\n' >"$HOME/work/proj/.claude/settings.json"
  printf '{"mcpServers": {"p": {}}}\n' >"$HOME/work/proj/.mcp.json"
  local before after
  before=$(cd "$HOME" && find . -type f ! -path './.aionas/*' ! -name .claude.json -exec cksum {} + | sort)
  hook
  after=$(cd "$HOME" && find . -type f ! -path './.aionas/*' ! -name .claude.json -exec cksum {} + | sort)
  t_eq "$before" "$after" "a file other than ~/.claude.json and user settings changed"
}

test_policy_off_bypassed_or_released_does_nothing() {
  setup
  call $((60 * DAY)) mcp__beta__x
  local sd; sd=$(aionas_savings_dir); mkdir -p "$sd"
  printf 'V\t1\nF\t%s\nM\tunused_services\toff\t0\t1\t1\t0\n' "$T0" >"$sd/policy.cache"
  hook
  t_eq "" "$(disabled)" "method off"
  printf 'V\t1\nF\t%s\nM\tunused_services\ton\t0\t1\t1\t1\n' "$T0" >"$sd/policy.cache"
  hook
  t_eq "" "$(disabled)" "released"
  printf 'V\t1\nF\t%s\nM\tunused_services\ton\t0\t1\t1\t0\nO\tunused_services\tself\t%s\t%s\tovr_1\n' "$T0" "$((T0 - 60))" "$((T0 + 3600))" >"$sd/policy.cache"
  hook
  t_eq "" "$(disabled)" "bypassed"
  printf 'V\t1\nF\t%s\nM\tunused_services\ton\t0\t1\t1\t0\n' "$T0" >"$sd/policy.cache"
  hook
  t_eq "beta " "$(disabled)" "on again"
}

test_days_come_from_the_policy_parameter() {
  setup
  call $((12 * DAY)) mcp__beta__x
  call $((12 * DAY)) mcp__alpha__x
  call $((5 * DAY)) mcp__gamma__x
  local sd; sd=$(aionas_savings_dir); mkdir -p "$sd"
  printf 'V\t1\nF\t%s\nM\tunused_services\ton\t0\t1\t1\t0\nP\tunused_services\tdays\tn\t10\n' "$T0" >"$sd/policy.cache"
  hook
  t_eq "alpha beta " "$(disabled)"
  t_contains "$(bash "$NOTICE" </dev/null)" "10 days"
}

test_bad_days_fall_back_to_30() {
  setup
  local sd; sd=$(aionas_savings_dir); mkdir -p "$sd"
  printf 'V\t1\nF\t%s\nM\tunused_services\ton\t0\t1\t1\t0\nP\tunused_services\tdays\tn\t0\n' "$T0" >"$sd/policy.cache"
  t_eq 30 "$(aionas_unused_days)"
  printf 'V\t1\nF\t%s\nM\tunused_services\ton\t0\t1\t1\t0\nP\tunused_services\tdays\tn\t9999\n' "$T0" >"$sd/policy.cache"
  t_eq 30 "$(aionas_unused_days)"
  printf 'V\t1\nF\t%s\nM\tunused_services\ton\t0\t1\t1\t0\nP\tunused_services\tunused_days\tn\t14\n' "$T0" >"$sd/policy.cache"
  t_eq 14 "$(aionas_unused_days)"
  rm -f "$sd/policy.cache"
  t_eq 30 "$(aionas_unused_days)"
}

test_new_project_gets_the_off_switch_carried_over() {
  setup
  call $((60 * DAY)) mcp__beta__x
  hook
  mkdir -p "$HOME/work/other"
  AIONAS_NOW=$((T0 + 3600)) hook "$HOME/work/other"
  local pk2; pk2=$(cd "$HOME/work/other" && pwd -P)
  t_eq "beta " "$(aionas_unused_j items "$CJ" "" projects "$pk2" disabledMcpServers | tr '\n' ' ')"
  # and that is not mistaken for a re-enable
  t_ok test ! -e "$(ud)/reenabled.tsv"
  t_eq "beta " "$(disabled)"
}

test_project_key_is_the_real_path_and_an_existing_entry_wins() {
  setup
  ln -s "$HOME/work/proj" "$HOME/work/link"
  t_eq "$PK" "$(aionas_unused_project_key "$CJ" "$HOME/work/link")"
  t_eq "$PK" "$(aionas_unused_project_key "$CJ" "$HOME/work/proj")"
  mkdir -p "$HOME/work/new"
  t_eq "$(cd "$HOME/work/new" && pwd -P)" "$(aionas_unused_project_key "$CJ" "$HOME/work/new")"
  # a path with a backslash or quote is escaped for the file
  t_eq 'C:\\x' "$(aionas_unused_raw 'C:\x')"
}

test_claude_config_dir_is_honoured() {
  setup
  mkdir -p "$HOME/cc/projects/-w"
  export CLAUDE_CONFIG_DIR="$HOME/cc"
  CJ="$HOME/cc/.claude.json"
  printf '{"mcpServers": {"beta": {}}, "projects": {}}\n' >"$CJ"
  HIST="$HOME/cc/projects/-w/s.jsonl"; : >"$HIST"
  call $((60 * DAY)) mcp__beta__x
  hook
  t_eq "beta " "$(disabled)"
  t_ok test ! -e "$HOME/.claude.json.aionas-tmp.1"
}

test_missing_config_and_history_are_fine() {
  mkdir -p "$HOME/work/proj"
  export AIONAS_NOW=$T0
  hook; t_rc 0 hook
  t_ok test ! -e "$HOME/.claude.json"
  t_eq "" "$(bash "$NOTICE" </dev/null)"
}

test_no_cwd_or_garbage_input_changes_nothing_and_exits_0() {
  setup
  call $((60 * DAY)) mcp__beta__x
  before=$(cksum <"$CJ")
  t_rc 0 bash -c "printf '{\"session_id\":\"s1\"}' | bash '$HOOK'"
  t_rc 0 bash -c "printf 'not json' | bash '$HOOK'"
  t_rc 0 bash "$HOOK" </dev/null
  t_eq "$before" "$(cksum <"$CJ")"
  t_ok test ! -d "$(ud)"
}

test_nothing_but_names_and_numbers_is_stored_or_sent() {
  setup
  t_enroll
  call $((60 * DAY)) mcp__beta__x
  slash 60 something
  hook
  AIONAS_NOW=$((T0 + 7200)) aionas_counters_flush --force
  local all
  all=$(cat "$(ud)"/*.tsv "$(ud)"/notice.pending 2>/dev/null; cat "$(aionas_savings_dir)"/counters/* 2>/dev/null; t_call 1 body 2>/dev/null)
  t_lacks "$all" SECRET-PROMPT-TEXT
  t_contains "$(t_call 1 body)" '"method_id":"unused_services","counter":"fired","value":1'
}

test_a_running_check_blocks_a_second_one() {
  setup
  call $((60 * DAY)) mcp__beta__x
  aionas_lock_try unused 120
  hook
  t_eq "" "$(disabled)"
  aionas_lock_release unused
  hook
  t_eq "beta " "$(disabled)"
}

test_real_claude_code_shows_the_server_as_disabled() {
  # Optional: AIONAS_CC_BIN=/path/to/claude (2.1.299). Skipped without it.
  [ -n "${AIONAS_CC_BIN:-}" ] || { echo "    (skipped: set AIONAS_CC_BIN)"; return 0; }
  export CLAUDE_CONFIG_DIR="$HOME/cc"; mkdir -p "$CLAUDE_CONFIG_DIR/projects/-w"
  (cd "$HOME/work" 2>/dev/null || mkdir -p "$HOME/work/proj")
  mkdir -p "$HOME/work/proj"
  ( cd "$HOME/work/proj" && DISABLE_AUTOUPDATER=1 "$AIONAS_CC_BIN" mcp add -s user beta -- echo hi >/dev/null 2>&1 &&
    DISABLE_AUTOUPDATER=1 "$AIONAS_CC_BIN" mcp add -s user alpha -- echo hi >/dev/null 2>&1 )
  CJ="$CLAUDE_CONFIG_DIR/.claude.json"
  PK=$(cd "$HOME/work/proj" && pwd -P)
  HIST="$CLAUDE_CONFIG_DIR/projects/-w/s.jsonl"; : >"$HIST"
  call $((60 * DAY)) mcp__beta__x
  call $((60 * DAY)) mcp__alpha__x
  call 1 mcp__alpha__x
  export AIONAS_NOW=$T0
  hook
  local out; out=$(cd "$HOME/work/proj" && DISABLE_AUTOUPDATER=1 "$AIONAS_CC_BIN" mcp list 2>&1)
  t_contains "$out" "beta: echo hi - ⊘ Disabled for this project"
  t_lacks "$out" "alpha: echo hi - ⊘ Disabled"
}

t_main "$@"
