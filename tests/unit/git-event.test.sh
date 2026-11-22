#!/usr/bin/env bash
# hooks/git-event.sh: a commit, a pull request or a push in this session, sent
# as metadata only after a tool call that succeeded (AIO-1088, W33-1/16/17)
. "$(dirname "$0")/../lib/harness.sh"

HOOK="$T_PLUGIN/hooks/git-event.sh"
FIX="$T_REPO/tests/fixtures/git-event"
T0=1792490400 # 2026-10-20T10:00:00Z
SID=2c9d7b1e-5a4f-4e3d-9c8b-1a2b3c4d5e6f
# Commits are dated at T0, the hook's clock, so they count as just made.
G=(env GIT_AUTHOR_DATE=@$T0 GIT_COMMITTER_DATE=@$T0 git -c user.name=t -c user.email=t@example.test)

capable() { printf 'V\t1\nC\tsession_git_events\n' >"$(aionas_savings_dir)/policy.cache"; }
setup() { t_enroll; export AIONAS_NOW=$T0; mkdir -p "$(aionas_savings_dir)"; capable; }
# repo BRANCH: a git repository on BRANCH with one commit and an origin remote.
repo() {
  local d
  d=$(mktemp -d "$T_ROOT/repo.XXXXXX")
  git -C "$d" init -q -b "$1" 2>/dev/null || { git -C "$d" init -q && git -C "$d" checkout -q -b "$1"; }
  "${G[@]}" -C "$d" commit -q --allow-empty -m init
  git -C "$d" remote add origin https://user:TOKEN@example.test/acme/billing-api.git
  printf '%s' "$d"
}
# run FIXTURE CWD: the recorded payload with the folder filled in, on stdin.
run() { sed -e "s|__CWD__|$2|g" -e "s|__TRANSCRIPT__|$T_ROOT/t.jsonl|g" "$FIX/$1.json" | bash "$HOOK"; }
fake_gh() { # prints N for "pr view"
  local b; b=$(mktemp -d "$T_ROOT/bin.XXXXXX")
  printf '#!/bin/sh\n[ "$1 $2" = "pr view" ] && echo %s\n' "$1" >"$b/gh"
  chmod +x "$b/gh"; printf '%s' "$b"
}
body() { t_call "$1" body; }

test_a_commit_sends_the_event_with_client_claude_code() {
  setup
  local d sha out
  d=$(repo feat/billing-export); sha=$(git -C "$d" rev-parse HEAD)
  out=$(run cc-commit "$d"); t_rc 0 run cc-commit "$d"
  t_eq "" "$out" "prints nothing"
  t_eq 1 "$(t_calls)"
  t_eq POST "$(t_call 1 method)"
  t_eq "https://gw.example.test/enroll/v1/cc-session-git" "$(t_call 1 url)"
  t_eq "{\"session_id\":\"$SID\",\"event\":\"commit\",\"branch\":\"feat/billing-export\",\"head_sha\":\"$sha\",\"observed_at\":\"2026-10-20T10:00:00Z\",\"repo\":\"billing-api\",\"client\":\"claude_code\"}" "$(body 1)"
}

test_a_failed_commit_on_an_old_head_is_not_reported_as_the_first_event() {
  setup
  local d
  d=$(repo main)
  # HEAD is an hour old: a "git commit" that made nothing (even if the app
  # reported the call as a success) must not send it.
  AIONAS_NOW=$((T0 + 3600)) run cc-commit "$d"
  t_eq 0 "$(t_calls)"
  AIONAS_NOW=$((T0 + 300)) run cc-commit "$d"
  t_eq 1 "$(t_calls)" "within ten minutes it is the commit just made"
}

test_the_same_commit_is_sent_once_and_a_new_one_again() {
  setup
  local d
  d=$(repo main)
  run cc-commit "$d"; run cc-commit "$d"
  t_eq 1 "$(t_calls)" "nothing to commit leaves HEAD: sent once"
  "${G[@]}" -C "$d" commit -q --allow-empty -m next
  run cc-commit "$d"
  t_eq 2 "$(t_calls)"
}

test_a_failed_send_is_not_retried_but_the_next_event_carries_the_state() {
  setup
  local d
  d=$(repo main)
  FAKE_CURL_STATUS=503 run cc-commit "$d"
  t_eq 1 "$(t_calls)"
  run cc-commit "$d"
  t_eq 2 "$(t_calls)" "no state was written, so the next commit event sends the current HEAD"
}

test_cursor_shell_sends_client_cursor() {
  setup
  local d
  d=$(repo main)
  run cursor-shell-commit "$d"
  t_eq 1 "$(t_calls)"
  t_contains "$(body 1)" '"event":"commit"'
  t_contains "$(body 1)" '"client":"cursor"'
}

test_gh_pr_create_sends_the_pr_number_only_when_gh_answers() {
  setup
  local d b
  d=$(repo feat/x)
  PATH="$(fake_gh 42):$PATH" run cc-pr-create "$d"
  t_eq 1 "$(t_calls)"
  t_contains "$(body 1)" '"event":"pr"'
  t_contains "$(body 1)" '"pr_number":42,'
  b=$(fake_gh "not-a-number")
  d=$(repo feat/y)
  PATH="$b:$PATH" run cc-pr-create "$d"
  t_eq 1 "$(t_calls)" "a non-number from gh sends nothing"
  b=$(fake_gh 0)
  PATH="$b:$PATH" run cc-pr-create "$d"
  t_eq 1 "$(t_calls)" "zero is not a pull request"
}

test_push_is_sent_only_when_upstream_equals_head() {
  setup
  local d bare
  d=$(repo main); bare=$(mktemp -d "$T_ROOT/bare.XXXXXX")
  git -C "$bare" init -q --bare
  git -C "$d" remote set-url origin "$bare"
  run cc-push "$d"
  t_eq 0 "$(t_calls)" "no upstream: nothing"
  git -C "$d" push -q -u origin main 2>/dev/null
  run cc-push "$d"
  t_eq 1 "$(t_calls)"
  t_contains "$(body 1)" '"event":"push"'
  "${G[@]}" -C "$d" commit -q --allow-empty -m unpushed
  run cc-push "$d"
  t_eq 1 "$(t_calls)" "a push that left a local commit behind sends nothing"
}

test_a_compound_command_sends_the_commit_and_never_its_text() {
  setup
  local d
  d=$(repo main)
  run cc-compound "$d"
  t_eq 1 "$(t_calls)"
  t_contains "$(body 1)" '"event":"commit"'
}

test_env_assignments_and_git_dash_c_before_the_command_count() {
  setup
  local d
  d=$(repo main)
  run cc-env-and-dir "$d"
  t_eq 1 "$(t_calls)"
}

test_a_quoted_or_unrelated_command_is_not_an_event() {
  setup
  local d
  d=$(repo main)
  run cc-quoted-not-a-command "$d"; run cc-non-git "$d"
  t_eq 0 "$(t_calls)"
}

test_a_failed_tool_call_sends_nothing() {
  setup
  local d f
  d=$(repo main)
  for f in cc-commit-failure cc-commit-interrupted cc-commit-exit-code; do
    t_rc 0 run "$f" "$d"
  done
  t_eq 0 "$(t_calls)"
}

test_nothing_outside_a_repository_unenrolled_or_without_the_capability() {
  setup
  local plain d
  plain=$(mktemp -d "$T_ROOT/plain.XXXXXX"); d=$(repo main)
  run cc-commit "$plain"
  t_eq 0 "$(t_calls)" "not a git folder"
  rm -f "$(aionas_savings_dir)/policy.cache"
  run cc-commit "$d"
  t_eq 0 "$(t_calls)" "no policy cached: no capability"
  printf 'V\t1\nC\tcounters_client\n' >"$(aionas_savings_dir)/policy.cache"
  run cc-commit "$d"
  t_eq 0 "$(t_calls)" "a gateway without session_git_events gets nothing new"
  t_eq "" "$(ls "$(aionas_savings_dir)/git-event" 2>/dev/null)" "and nothing is queued"
  capable; t_unenroll
  run cc-commit "$d"
  t_eq 0 "$(t_calls)" "not enrolled"
}

test_a_bad_session_id_or_a_detached_head_sends_nothing() {
  setup
  local d
  d=$(repo main)
  sed -e "s|__CWD__|$d|" -e 's|2c9d7b1e-5a4f-4e3d-9c8b-1a2b3c4d5e6f|../../etc|' "$FIX/cc-commit.json" | bash "$HOOK"
  git -C "$d" checkout -q --detach
  run cc-commit "$d"
  t_eq 0 "$(t_calls)"
}

test_the_body_is_metadata_only_and_nothing_else_is_written() {
  setup
  local d d2 b k v
  d=$(repo feat/billing-export); d2=$(repo feat/billing-export)
  "${G[@]}" -C "$d2" commit -q --allow-empty -m more
  PATH="$(fake_gh 7):$PATH" run cc-pr-create "$d"
  run cc-compound "$d"; run cursor-shell-commit "$d2"
  t_eq 3 "$(t_calls)"
  for n in 1 2 3; do
    b=$(body "$n")
    # keys: only the allowed ones, in the contract's shapes
    while IFS= read -r k; do
      case "$k" in session_id | event | branch | head_sha | pr_number | observed_at | repo | client) ;; *) t_fail "unexpected key [$k] in $b" ;; esac
    done < <(printf '%s' "$b" | aionas_json_flatten | awk -F '\t' '$1 != "" { print $1 }')
    t_eq "$SID" "$(printf '%s' "$b" | aionas_json_flatten | aionas_json_get session_id)"
    v=$(printf '%s' "$b" | aionas_json_flatten | aionas_json_get event); case "$v" in commit | pr | push) ;; *) t_fail "event [$v]" ;; esac
    v=$(printf '%s' "$b" | aionas_json_flatten | aionas_json_get head_sha); case "$v" in *[!0-9a-f]*) t_fail "sha [$v]" ;; esac; [ ${#v} = 40 ] || t_fail "sha length"
    v=$(printf '%s' "$b" | aionas_json_flatten | aionas_json_get branch); case "$v" in *[!A-Za-z0-9._/-]* | "") t_fail "branch [$v]" ;; esac
    v=$(printf '%s' "$b" | aionas_json_flatten | aionas_json_get observed_at); case "$v" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;; *) t_fail "time [$v]" ;; esac
    v=$(printf '%s' "$b" | aionas_json_flatten | aionas_json_get repo); t_eq billing-api "$v"
    v=$(printf '%s' "$b" | aionas_json_flatten | aionas_json_get client); case "$v" in cursor | claude_code) ;; *) t_fail "client [$v]" ;; esac
    if printf '%s' "$b" | aionas_json_flatten | aionas_json_type pr_number >/dev/null; then
      t_eq n "$(printf '%s' "$b" | aionas_json_flatten | aionas_json_type pr_number)" "pr_number is a JSON integer"
      t_eq 1 "$n" "only the pr event has pr_number"
    fi
    for k in "secret message" "git commit" "git push" "gh pr" STDOUT-CANARY STDERR-CANARY CANARY-DESCRIPTION SECRET-BODY TOKEN "$d" "$d2" "$T_ROOT"; do
      t_lacks "$b" "$k" "body"
      case "$k" in "$T_ROOT") ;; *) t_lacks "$(t_call "$n" args)" "$k" "curl args" ;; esac
    done
  done
  # nothing the hook wrote under the savings dir carries the command, the
  # message, the output or the folder
  local f
  while IFS= read -r f; do
    for k in "secret message" "git commit" STDOUT-CANARY STDERR-CANARY CANARY-DESCRIPTION SECRET-BODY TOKEN "$d" "$d2"; do
      case "$(cat "$f" 2>/dev/null)" in *"$k"*) t_fail "[$k] found in $f" ;; esac
    done
    case "$f" in */git-event/*) ;; */policy.cache) ;; *) ;; esac
  done < <(find "$(aionas_savings_dir)" -type f)
  t_eq "" "$(find "$(aionas_savings_dir)/git-event" -name '.*')" "no temp file is left behind"
}

test_old_state_is_pruned_without_a_recursive_delete() {
  setup
  local d old
  d=$(repo main)
  mkdir -p "$(aionas_savings_dir)/git-event"
  old="$(aionas_savings_dir)/git-event/00000000-0000-4000-8000-000000000000.commit"
  echo deadbeef >"$old"; touch -t 202001010000 "$old"
  run cc-commit "$d"
  t_not test -e "$old"
  t_lacks "$(cat "$HOOK")" "-delete"
  t_lacks "$(cat "$HOOK")" "rm -r"
}

test_the_hook_never_makes_a_decision() {
  setup
  local d out
  d=$(repo main)
  out=$(run cc-commit "$d"; run cursor-shell-commit "$d")
  t_eq "" "$out"
  t_lacks "$(cat "$HOOK")" permission
  t_lacks "$(cat "$HOOK")" decision
}

t_main "$@"
