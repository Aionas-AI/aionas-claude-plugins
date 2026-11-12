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
  t_eq "{\"session_id\":\"$SID\",\"branch\":\"feat/billing-export\",\"head_sha\":\"$sha\",\"observed_at\":\"2026-10-20T10:00:00Z\",\"root_sha\":\"$sha\"}" "$(t_call 1 body)"
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
  t_lacks "$(t_call 1 body)" "https://" "the remote URL never leaves"
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


# owner_of REMOTE-URL [UPSTREAM-URL]: runs the hook on a repo with those remotes; prints the body.
owner_body() {
  local d
  d=$(repo main)
  [ -n "$1" ] && git -C "$d" remote add origin "$1"
  [ -n "${2:-}" ] && git -C "$d" remote add upstream "$2"
  hook "$d" >/dev/null
  t_call "$(t_calls)" body
}
# t_owner REMOTE-URL EXPECTED: the repo_owner the hook sends for that origin ("" = none).
t_owner() {
  t_enroll; export AIONAS_NOW=$T0
  local b
  b=$(owner_body "$1")
  if [ -n "$2" ]; then
    t_contains "$b" "\"repo_owner\":\"$2\"" "origin $1"
  else
    t_lacks "$b" repo_owner "origin $1 sends no owner"
  fi
}

test_repo_owner_is_host_and_owner_lower_cased() {
  t_owner "https://github.com/Acme/gateway.git" github.com/acme
  t_owner "git@github.com:acme/gateway.git" github.com/acme
  t_owner "git@github-work:acme/x.git" github-work/acme
  t_owner "https://gitlab.company.com/group/sub/repo.git" gitlab.company.com/group/sub
  t_owner "ssh://git@host:2222/acme/x.git" host/acme
  t_owner "https://GitHub.com/ACME/Repo/" github.com/acme
}

test_repo_owner_never_carries_a_credential_or_a_port() {
  t_enroll; export AIONAS_NOW=$T0
  local b
  b=$(owner_body "https://dana:SECRET-TOKEN@github.com/acme/gateway.git")
  t_contains "$b" '"repo_owner":"github.com/acme"'
  t_lacks "$b" SECRET-TOKEN "a token in the URL never leaves"
  t_lacks "$b" dana "the user in the URL never leaves"
  b=$(owner_body "https://ghp_ABC123@github.com/acme/gateway.git")
  t_lacks "$b" ghp_ABC123 "a token-only user never leaves"
  t_contains "$b" '"repo_owner":"github.com/acme"'
  b=$(owner_body "ssh://git@host:2222/acme/x.git")
  t_lacks "$b" 2222 "the port never leaves"
}

test_repo_owner_is_absent_for_a_local_or_unparsable_remote() {
  t_owner "/srv/git/acme/x.git" ""
  t_owner "file:///srv/git/acme/x.git" ""
  t_owner "../acme/x" ""
  t_owner "C:/work/x" ""
  t_owner "https://github.com/x.git" ""
  t_owner "https://github.com" ""
}

test_repo_owner_uses_the_first_remote_when_there_is_no_origin() {
  t_enroll; export AIONAS_NOW=$T0
  local d
  d=$(repo main)
  git -C "$d" remote add github "git@github.com:Acme/billing.git"
  hook "$d"
  t_contains "$(t_call 1 body)" '"repo_owner":"github.com/acme"'
}

test_upstream_owner_only_when_an_upstream_remote_exists() {
  t_enroll; export AIONAS_NOW=$T0
  local b
  b=$(owner_body "https://github.com/dana/gateway.git")
  t_lacks "$b" upstream_owner "no upstream, no field"
  b=$(owner_body "https://github.com/dana/gateway.git" "https://tok:SECRET2@github.com/Acme/gateway.git")
  t_contains "$b" '"repo_owner":"github.com/dana"'
  t_contains "$b" '"upstream_owner":"github.com/acme"'
  t_lacks "$b" SECRET2 "an upstream token never leaves"
}

test_root_sha_is_the_first_commit_even_with_no_remote() {
  t_enroll; export AIONAS_NOW=$T0
  local d root
  d=$(repo main)
  root=$(git -C "$d" rev-parse HEAD)
  git -C "$d" -c user.name=t -c user.email=t@example.test commit -q --allow-empty -m next
  hook "$d"
  t_contains "$(t_call 1 body)" "\"root_sha\":\"$root\""
  t_lacks "$(t_call 1 body)" repo_owner
  t_lacks "$(t_call 1 body)" '"repo"'
}

test_root_sha_is_the_smallest_of_several_roots() {
  t_enroll; export AIONAS_NOW=$T0
  local d a b c want
  d=$(repo main)
  a=$(git -C "$d" rev-parse HEAD)
  # two more root commits (orphan branches), then merge them so HEAD sees all roots
  git -C "$d" checkout -q --orphan o1
  git -C "$d" -c user.name=t -c user.email=t@example.test commit -q --allow-empty -m o1
  b=$(git -C "$d" rev-parse HEAD)
  git -C "$d" checkout -q --orphan o2
  GIT_COMMITTER_DATE="2001-01-01T00:00:00Z" git -C "$d" -c user.name=t -c user.email=t@example.test commit -q --allow-empty -m o2
  c=$(git -C "$d" rev-parse HEAD)
  git -C "$d" checkout -q main
  git -C "$d" -c user.name=t -c user.email=t@example.test merge -q --allow-unrelated-histories --no-edit o1 >/dev/null 2>&1
  git -C "$d" -c user.name=t -c user.email=t@example.test merge -q --allow-unrelated-histories --no-edit o2 >/dev/null 2>&1
  t_eq 3 "$(git -C "$d" rev-list --max-parents=0 HEAD | wc -l | tr -d ' ')" "three roots reach HEAD"
  want=$(printf '%s\n%s\n%s\n' "$a" "$b" "$c" | LC_ALL=C sort | head -n 1)
  hook "$d"
  t_contains "$(t_call 1 body)" "\"root_sha\":\"$want\""
}

test_a_changed_remote_owner_is_sent_again() {
  t_enroll; export AIONAS_NOW=$T0
  local d
  d=$(repo main)
  git -C "$d" remote add origin "https://github.com/dana/x.git"
  hook "$d"; hook "$d"
  t_eq 1 "$(t_calls)"
  git -C "$d" remote set-url origin "https://github.com/acme/x.git"
  hook "$d"
  t_eq 2 "$(t_calls)"
  t_contains "$(t_call 2 body)" '"repo_owner":"github.com/acme"'
}


# fake_ssh: a PATH-first `ssh` whose -G answer maps the alias github-work to
# ssh.github.com and says a lot more than the hostname (which must not leave).
fake_ssh() {
  local b
  b=$(mktemp -d "$T_ROOT/bin.XXXXXX")
  cat >"$b/ssh" <<'SH'
#!/bin/sh
for a in "$@"; do h=$a; done
echo "user git"
echo "identityfile /home/SECRET-KEY-PATH/id_ed25519"
case "$h" in
  github-work) echo "hostname ssh.github.com" ;;
  gl) echo "hostname gitlab.company.com" ;;
  broken) exit 1 ;;
  *) echo "hostname $h" ;;
esac
SH
  chmod +x "$b/ssh"
  printf '%s' "$b"
}

test_an_ssh_alias_resolves_to_the_real_host() {
  t_enroll; export AIONAS_NOW=$T0
  local b
  PATH="$(fake_ssh):$PATH"
  b=$(owner_body "git@github-work:acme/x.git")
  t_contains "$b" '"repo_owner":"github.com/acme"'
  t_lacks "$b" SECRET-KEY-PATH "nothing but the hostname is taken from ssh -G"
  b=$(owner_body "ssh://git@gl:2222/grp/sub/x.git")
  t_contains "$b" '"repo_owner":"gitlab.company.com/grp/sub"'
  b=$(owner_body "git@broken:acme/x.git")
  t_contains "$b" '"repo_owner":"broken/acme"' "a failing ssh -G keeps the alias"
  b=$(owner_body "git@ssh.github.com:Acme/x.git")
  t_contains "$b" '"repo_owner":"github.com/acme"' "ssh.github.com is github.com"
  b=$(owner_body "https://github-work/acme/x.git")
  t_contains "$b" '"repo_owner":"github-work/acme"' "an https host is not an ssh alias"
}

test_instead_of_is_applied_before_parsing() {
  t_enroll; export AIONAS_NOW=$T0
  local d
  d=$(repo main)
  git -C "$d" config url."https://github.com/".insteadOf "gh:"
  git -C "$d" remote add origin "gh:Acme/x.git"
  hook "$d"
  t_contains "$(t_call 1 body)" '"repo_owner":"github.com/acme"'
}

test_upstream_falls_back_to_another_remote_with_a_different_owner() {
  t_enroll; export AIONAS_NOW=$T0
  local d b
  d=$(repo main)
  git -C "$d" remote add origin "https://github.com/dana/x.git"
  git -C "$d" remote add backup "https://github.com/dana/x-mirror.git"
  git -C "$d" remote add company "https://github.com/Acme/x.git"
  hook "$d"
  b=$(t_call 1 body)
  t_contains "$b" '"repo_owner":"github.com/dana"'
  t_contains "$b" '"upstream_owner":"github.com/acme"' "the company remote counts, same-owner remotes do not"
  b=$(owner_body "https://github.com/dana/x.git" "https://github.com/acme/x.git")
  t_contains "$b" '"upstream_owner":"github.com/acme"' "a remote named upstream still wins"
}

test_an_owner_with_a_dot_segment_is_not_sent() {
  t_owner "https://github.com/../x.git" ""
  t_owner "https://github.com/./x.git" ""
  t_owner "https://github.com/a/../b/x.git" ""
  t_owner "https://github.com/a.b/x.git" github.com/a.b
}


test_upstream_owner_lists_all_other_remotes() {
  t_enroll; export AIONAS_NOW=$T0
  local d b i
  d=$(repo main)
  git -C "$d" remote add origin "https://github.com/dana/x.git"
  git -C "$d" remote add alpha "https://github.com/third/x.git"
  git -C "$d" remote add company "https://github.com/Acme/x.git"
  git -C "$d" remote add mirror "https://github.com/dana/x2.git"
  git -C "$d" remote add dup "https://github.com/third/x3.git"
  hook "$d"
  b=$(t_call 1 body)
  t_contains "$b" '"upstream_owner":"github.com/third github.com/acme"' "name order, no duplicate, none equal to repo_owner"
  git -C "$d" remote add upstream "https://github.com/zed/x.git"
  hook "$d"
  t_contains "$(t_call 2 body)" '"upstream_owner":"github.com/zed github.com/third github.com/acme"' "upstream comes first"
  d=$(repo main)
  git -C "$d" remote add origin "https://github.com/dana/x.git"
  for i in 1 2 3 4 5 6 7; do git -C "$d" remote add "r$i" "https://github.com/o$i/x.git"; done
  hook "$d" 2f0e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b
  b=$(t_call 3 body)
  t_contains "$b" 'github.com/o5"' "five owners"
  t_lacks "$b" github.com/o6 "at most 5"
}

# ssh_counter: a PATH-first ssh that logs each call; prints its folder.
counting_ssh() {
  local b
  b=$(mktemp -d "$T_ROOT/cbin.XXXXXX")
  printf '#!/bin/sh\necho call >>"%s/ssh.log"\nfor a in "$@"; do h=$a; done\necho "hostname real-$h"\n' "$b" >"$b/ssh"
  chmod +x "$b/ssh"
  printf '%s' "$b"
}

test_ssh_g_runs_once_per_alias_per_day_not_on_every_prompt() {
  t_enroll; export AIONAS_NOW=$T0
  local b d
  b=$(counting_ssh)
  PATH="$b:$PATH"
  d=$(repo main)
  git -C "$d" remote add origin "git@work:acme/x.git"
  hook "$d"
  t_contains "$(t_call 1 body)" '"repo_owner":"real-work/acme"'
  git -C "$d" -c user.name=t -c user.email=t@example.test commit -q --allow-empty -m next
  hook "$d"
  git -C "$d" -c user.name=t -c user.email=t@example.test commit -q --allow-empty -m next2
  hook "$d"
  t_eq 3 "$(t_calls)"
  t_eq 1 "$(wc -l <"$b/ssh.log" | tr -d ' ')" "ssh -G ran once for the alias"
  export AIONAS_NOW=$((T0 + 86400))
  hook "$d"
  t_eq 2 "$(wc -l <"$b/ssh.log" | tr -d ' ')" "and again the next day"
}

test_ssh_g_never_runs_without_timeout_or_gtimeout() {
  t_enroll; export AIONAS_NOW=$T0
  local b d bin tool p
  b=$(counting_ssh)
  bin=$(mktemp -d "$T_ROOT/min.XXXXXX")
  # a PATH with the tools the hook needs, but no timeout / gtimeout
  for tool in bash sh git sed awk grep head sort tr cat date find mkdir mv rm chmod mktemp dirname basename cut wc uname id ln cp touch env ls tail xargs od hostname sleep stat; do
    p=$(command -v "$tool" 2>/dev/null) || continue
    case "$p" in /*) printf '#!/bin/sh\nexec "%s" "$@"\n' "$p" >"$bin/$tool"; chmod +x "$bin/$tool" ;; esac
  done
  cp "$b/ssh" "$bin/ssh"
  d=$(repo main)
  git -C "$d" remote add origin "git@work:acme/x.git"
  PATH="$bin" hook "$d" 2>/dev/null
  t_eq 1 "$(t_calls)"
  t_contains "$(t_call 1 body)" '"repo_owner":"work/acme"' "the alias is kept"
  t_eq "" "$(cat "$b/ssh.log" 2>/dev/null)" "ssh was not run"
}

t_main "$@"
