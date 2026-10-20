#!/usr/bin/env bash
# lib/unused-json.awk: read and edit one place in ~/.claude.json or settings.json (AIO-861)
. "$(dirname "$0")/../lib/harness.sh"
. "$T_PLUGIN/lib/unused.sh"

# put NAME CONTENT: write a file in the test HOME and print its path
put() { printf '%s' "$2" >"$HOME/$1"; echo "$HOME/$1"; }
J() { aionas_unused_j "$@"; }

PRETTY='{
  "firstStartTime": "2026-10-20T19:08:05.201Z",
  "mcpServers": {
    "alpha": {
      "type": "stdio",
      "args": ["a", "b\"c"]
    },
    "be.ta": {}
  },
  "projects": {
    "/work/one": {
      "allowedTools": [],
      "disabledMcpServers": ["x", "y", "z"]
    },
    "/work/two.v2": {
      "disabledMcpServers": [],
      "note": "has \"quotes\" and ] and } and , inside"
    },
    "C:/Users/me/proj": {"disabledMcpServers": null}
  },
  "claudeAiMcpEverConnected": ["claude.ai Gmail", "claude.ai Slack"],
  "trailing": 7
}
'

test_reads_members_and_items() {
  local f; f=$(put c.json "$PRETTY")
  t_eq "$(printf 'alpha\to\t\nbe.ta\to\t')" "$(J members "$f" "" mcpServers)"
  t_eq "x
y
z" "$(J items "$f" "" projects /work/one disabledMcpServers)"
  t_eq "claude.ai Gmail
claude.ai Slack" "$(J items "$f" "" claudeAiMcpEverConnected)"
  t_eq "$(printf 'firstStartTime\ts\t2026-10-20T19:08:05.201Z\nmcpServers\to\t\nprojects\to\t\nclaudeAiMcpEverConnected\ta\t\ntrailing\tn\t')" "$(J members "$f" "" "")"
  t_eq "" "$(J items "$f" "" projects /nope disabledMcpServers)"
  t_eq "" "$(J members "$f" "" nope)"
  t_eq "" "$(J items "$f" "" mcpServers)" "an object is not an array"
}

test_add_item_variants_keep_the_rest_byte_for_byte() {
  local f out
  f=$(put c.json "$PRETTY")
  out=$(J add-item "$f" new projects /work/one disabledMcpServers; echo "rc=$?")
  t_contains "$out" '"disabledMcpServers": ["x", "y", "z","new"]'
  t_contains "$out" "rc=0"
  # nothing else changed
  diff <(printf '%s' "$PRETTY") <(AU_OP=add-item AU_PATH="projects	/work/one	disabledMcpServers" AU_VAL=new awk -f "$AIONAS_LIB/unused-json.awk" "$f" | sed 's/,"new"//') >/dev/null || t_fail "edit touched more than the insertion"
  # empty array, null, missing entry, missing projects
  out=$(J add-item "$f" new projects /work/two.v2 disabledMcpServers); t_contains "$out" '"disabledMcpServers": ["new"],'
  out=$(J add-item "$f" new projects C:/Users/me/proj disabledMcpServers); t_contains "$out" '"disabledMcpServers": ["new"]}'
  out=$(J add-item "$f" new projects /work/three disabledMcpServers); t_contains "$out" '"/work/three":{"disabledMcpServers":["new"]}'
  f=$(put d.json '{"a":1}')
  t_eq '{"a":1,"projects":{"/p":{"disabledMcpServers":["n"]}}}' "$(J add-item "$f" n projects /p disabledMcpServers)"
  f=$(put e.json '{}')
  t_eq '{"projects":{"/p":{"disabledMcpServers":["n"]}}}' "$(J add-item "$f" n projects /p disabledMcpServers)"
  # a missing file reads as {}
  t_eq '{"projects":{"/p":{"disabledMcpServers":["n"]}}}' "$(J add-item "$HOME/none.json" n projects /p disabledMcpServers)"
}

test_add_existing_item_changes_nothing() {
  local f; f=$(put c.json "$PRETTY")
  t_rc 10 J add-item "$f" y projects /work/one disabledMcpServers
  t_eq "" "$(J add-item "$f" y projects /work/one disabledMcpServers)"
}

test_del_item_first_middle_last_only() {
  local f
  f=$(put c.json '{"p":{"l":["x", "y", "z"]}}')
  t_eq '{"p":{"l":["y", "z"]}}' "$(J del-item "$f" x p l)"
  t_eq '{"p":{"l":["x", "z"]}}' "$(J del-item "$f" y p l)"
  t_eq '{"p":{"l":["x", "y"]}}' "$(J del-item "$f" z p l)"
  f=$(put d.json '{"p":{"l":["x"]}}')
  t_eq '{"p":{"l":[]}}' "$(J del-item "$f" x p l)"
  t_rc 10 J del-item "$f" nope p l
  t_rc 10 J del-item "$f" x p missing
  t_rc 10 J del-item "$f" x missing l
}

test_set_str_replaces_creates_and_skips() {
  local f
  f=$(put s.json '{
  "theme": "dark",
  "skillOverrides": {"a": "on", "b": "name-only"}
}')
  t_contains "$(J set-str "$f" off skillOverrides a)" '"skillOverrides": {"a": "off", "b": "name-only"}'
  t_contains "$(J set-str "$f" off skillOverrides c)" '"b": "name-only","c":"off"}'
  t_rc 10 J set-str "$f" name-only skillOverrides b
  f=$(put t.json '{"theme": "dark"}')
  t_eq '{"theme": "dark","skillOverrides":{"s":"off"}}' "$(J set-str "$f" off skillOverrides s)"
  t_eq '{"skillOverrides":{"s":"off"}}' "$(J set-str "$HOME/none.json" off skillOverrides s)"
}

test_compact_single_line_file() {
  local f; f=$(put c.json '{"projects":{"/p":{"disabledMcpServers":["a"],"z":{"q":[1,2,{"k":"]"}]}}},"n":null}')
  t_eq '{"projects":{"/p":{"disabledMcpServers":["a","b"],"z":{"q":[1,2,{"k":"]"}]}}},"n":null}' "$(J add-item "$f" b projects /p disabledMcpServers)"
}

test_wrong_shapes_are_left_alone() {
  local f
  f=$(put c.json '{"projects":{"/p":{"disabledMcpServers":"oops"}}}')
  t_rc 4 J add-item "$f" a projects /p disabledMcpServers
  f=$(put d.json '{"projects":[1]}')
  t_rc 4 J add-item "$f" a projects /p disabledMcpServers
  f=$(put e.json '{"skillOverrides":3}')
  t_rc 4 J set-str "$f" off skillOverrides a
}

test_invalid_json_exits_2_and_jedit_does_not_touch_the_file() {
  local f; f=$(put c.json '{"projects":{"/p":{"d":[}}}')
  t_rc 2 J add-item "$f" a projects /p d
  t_rc 2 aionas_unused_jedit "$f" add-item a projects /p d
  t_eq '{"projects":{"/p":{"d":[}}}' "$(cat "$f")"
  ls "$HOME" | grep -q aionas-tmp && t_fail "temp file left behind"
  return 0
}

test_keys_with_backslashes_and_escapes() {
  local f raw
  f=$(put c.json '{"projects":{"C:\\Users\\me":{"disabledMcpServers":[]}}}')
  raw=$(aionas_unused_raw 'C:\Users\me')
  t_eq 'C:\\Users\\me' "$raw"
  t_eq '{"projects":{"C:\\Users\\me":{"disabledMcpServers":["s"]}}}' "$(J add-item "$f" s projects "$raw" disabledMcpServers)"
}

test_jedit_rewrites_atomically_keeps_mode_and_follows_symlinks() {
  local f real
  f=$(put c.json '{"a":1}')
  chmod 640 "$f"
  t_rc 0 aionas_unused_jedit "$f" add-item n projects /p d
  t_eq '{"a":1,"projects":{"/p":{"d":["n"]}}}' "$(cat "$f")"
  t_eq 640 "$(t_mode "$f")"
  t_rc 10 aionas_unused_jedit "$f" add-item n projects /p d
  real=$(put real.json '{"a":1}')
  ln -s "$real" "$HOME/link.json"
  t_rc 0 aionas_unused_jedit "$HOME/link.json" set-str off skillOverrides s
  t_ok test -L "$HOME/link.json"
  t_eq '{"a":1,"skillOverrides":{"s":"off"}}' "$(cat "$real")"
  # creates the folder of a settings file that does not exist yet
  t_rc 0 aionas_unused_jedit "$HOME/.claude/settings.json" set-str off skillOverrides s
  t_eq '{"skillOverrides":{"s":"off"}}' "$(cat "$HOME/.claude/settings.json")"
}

test_a_big_file_is_fast_enough() {
  local f i
  f="$HOME/big.json"
  { echo '{'; echo '  "projects": {'
    for i in $(seq 1 3000); do
      printf '    "/work/p%s": {\n      "allowedTools": [],\n      "history": [{"display": "a fairly long prompt text number %s that goes on and on with words", "pastedContents": {}}],\n      "mcpServers": {},\n      "disabledMcpServers": []\n    },\n' "$i" "$i"
    done
    echo '    "/work/last": {"disabledMcpServers": []}'; echo '  }'; echo '}'
  } >"$f"
  local s e; s=$(date +%s)
  t_contains "$(J add-item "$f" n projects /work/last disabledMcpServers)" '"/work/last": {"disabledMcpServers": ["n"]}'
  e=$(date +%s)
  [ $((e - s)) -le 4 ] || t_fail "a $(wc -c <"$f") byte file took $((e - s)) s"
}

t_main "$@"
