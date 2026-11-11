#!/usr/bin/env bash
# hooks/branch-report.sh: the git branch of the folder the member prompted
# from, sent once per change per session (AIO-1019)
. "$(dirname "$0")/../lib/harness.sh"

HOOK="$T_PLUGIN/hooks/branch-report.sh"
T0=1792490400 # 2026-10-20T10:00:00Z
SID=1f0e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b

# repo BRANCH: a fresh git repository on BRANCH with one commit; prints its path.
repo() {
  local d
  d=$(mktemp -d "$T_ROOT/repo.XXXXXX")
  git -C "$d" init -q -b "$1" 2>/dev/null || { git -C "$d" init -q && git -C "$d" checkout -q -b "$1"; }
  git -C "$d" -c user.name=t -c user.email=t@example.test commit -q --allow-empty -m init
  printf '%s' "$d"
}
# hook CWD [SID]: one UserPromptSubmit input, with a prompt that must never leave.
hook() {
  printf '{"session_id":"%s","cwd":"%s","hook_event_name":"UserPromptSubmit","prompt":"CANARY-PROMPT book me a flight"}' \
    "${2:-$SID}" "$1" | bash "$HOOK"
}

test_sends_the_branch_and_commit_only() {
  t_enroll; export AIONAS_NOW=$T0
  local d sha out
  d=$(repo feat/billing-export)
  sha=$(git -C "$d" rev-parse HEAD)
  out=$(hook "$d"); t_rc 0 hook "$d"
  t_eq "" "$out" "the async hook prints nothing"
  t_eq 1 "$(t_calls)"
  t_eq POST "$(t_call 1 method)"
  t_eq "https://gw.example.test/enroll/v1/cc-session-git" "$(t_call 1 url)"
  t_contains "$(t_call 1 headers)" "Authorization: Bearer $T_ALIAS"
  t_eq "{\"session_id\":\"$SID\",\"branch\":\"feat/billing-export\",\"head_sha\":\"$sha\",\"observed_at\":\"2026-10-20T10:00:00Z\"}" "$(t_call 1 body)"
  t_lacks "$(t_call 1 body)" CANARY-PROMPT "the prompt never leaves"
  t_lacks "$(t_call 1 body)" "$d" "the folder path never leaves"
  t_lacks "$(t_call 1 args)" "$T_ALIAS" "the alias is never on a command line"
}

test_once_per_state_and_again_on_a_new_branch() {
  t_enroll; export AIONAS_NOW=$T0
  local d
  d=$(repo main)
  hook "$d"; hook "$d"
  t_eq 1 "$(t_calls)" "the same branch and commit are sent once"
  git -C "$d" checkout -q -b fix/login
  hook "$d"
  t_eq 2 "$(t_calls)" "a new branch is sent"
  t_contains "$(t_call 2 body)" '"branch":"fix/login"'
  git -C "$d" -c user.name=t -c user.email=t@example.test commit -q --allow-empty -m next
  hook "$d"
  t_eq 3 "$(t_calls)" "a new commit is sent"
}

test_a_failed_send_is_retried_on_the_next_prompt() {
  t_enroll; export AIONAS_NOW=$T0
  local d
  d=$(repo main)
  FAKE_CURL_STATUS=503 hook "$d"
  hook "$d"
  t_eq 2 "$(t_calls)"
}

test_nothing_outside_a_repository_or_on_a_detached_head() {
  t_enroll; export AIONAS_NOW=$T0
  local plain d
  plain=$(mktemp -d "$T_ROOT/plain.XXXXXX")
  hook "$plain"
  hook "$T_ROOT/no-such-folder"
  d=$(repo main)
  git -C "$d" checkout -q --detach
  hook "$d"
  t_eq 0 "$(t_calls)"
}

test_nothing_when_not_enrolled_or_the_session_is_not_an_id() {
  local d
  d=$(repo main)
  t_unenroll
  hook "$d"
  t_enroll
  hook "$d" "not-a-session"
  t_eq 0 "$(t_calls)"
}

test_sends_the_repository_name_never_the_remote_url() {
  t_enroll; export AIONAS_NOW=$T0
  local d
  d=$(repo main)
  git -C "$d" remote add origin "https://dana:SECRET-TOKEN@github.com/acme/gateway.git"
  hook "$d"
  t_contains "$(t_call 1 body)" '"repo":"gateway"'
  t_lacks "$(t_call 1 body)" SECRET-TOKEN "a token in the remote URL never leaves"
  t_lacks "$(t_call 1 body)" github.com "the remote URL never leaves"
  local d2
  d2=$(repo main)
  git -C "$d2" remote add origin "git@github.com:acme/ui.git"
  hook "$d2" 2f0e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b
  t_contains "$(t_call 2 body)" '"repo":"ui"'
}

test_no_remote_sends_no_repository() {
  t_enroll; export AIONAS_NOW=$T0
  local d
  d=$(repo main)
  hook "$d"
  t_lacks "$(t_call 1 body)" '"repo"'
}

test_a_session_id_with_path_characters_is_ignored() {
  t_enroll; export AIONAS_NOW=$T0
  local d
  d=$(repo main)
  hook "$d" "12345678-../../x-a-b-c"
  hook "$d" "12345678-1234-1234-1234-12345678901/"
  t_eq 0 "$(t_calls)"
  t_eq "" "$(find "$T_ROOT" -name 'x-a-b-c' 2>/dev/null)" "no file outside the state folder"
}

test_a_remote_not_named_origin_still_names_the_repository() {
  t_enroll; export AIONAS_NOW=$T0
  local d
  d=$(repo main)
  git -C "$d" remote add github "git@github.com:acme/billing.git"
  hook "$d"
  t_contains "$(t_call 1 body)" '"repo":"billing"'
}

test_an_inherited_git_dir_never_points_at_another_repository() {
  t_enroll; export AIONAS_NOW=$T0
  local d other
  d=$(repo feat/mine)
  other=$(repo feat/other)
  GIT_DIR="$other/.git" hook "$d"
  t_contains "$(t_call 1 body)" '"branch":"feat/mine"'
}

t_main "$@"
