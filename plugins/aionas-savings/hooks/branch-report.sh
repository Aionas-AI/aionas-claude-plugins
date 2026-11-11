#!/usr/bin/env bash
# aionas-savings hook: branch-report (UserPromptSubmit, async). Owner: AIO-1019.
# Sends the git branch and commit of the folder the member prompted from, so
# Aionas can group the session's requests into Work Items (one person's repo +
# branch). Sent only when the branch or commit changed for this session.
#
# Reads two fields of the hook input: session_id and cwd. The prompt is never
# read, kept or sent, and neither is the folder path: the body is the session
# id, the branch name, the commit, the repository's bare name (worked out
# here from the origin remote, never the URL) and the time. Not a git folder, a detached
# HEAD, no git, not enrolled: nothing is sent. Prints nothing, exits 0.
set -u
. "$(dirname "$0")/../lib/aionas.sh" 2>/dev/null || exit 0

input=$(cat 2>/dev/null) || exit 0
aionas_enroll_has_alias || exit 0
command -v git >/dev/null 2>&1 || exit 0

flat=$(printf '%s' "$input" | aionas_json_flatten 2>/dev/null) || exit 0
sid=$(printf '%s\n' "$flat" | aionas_json_get session_id 2>/dev/null) || exit 0
cwd=$(printf '%s\n' "$flat" | aionas_json_get cwd 2>/dev/null | aionas_json_unescape) || exit 0
input="" flat=""

# A session id is a UUID (the gateway's own check). It names the state file,
# so nothing but hex digits and four dashes in the UUID places gets through.
h4='[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]'
# shellcheck disable=SC2254
case "$sid" in
  $h4$h4-$h4-$h4-$h4-$h4$h4$h4) ;;
  *) exit 0 ;;
esac
[ -n "$cwd" ] && [ -d "$cwd" ] || exit 0
# Only the folder decides: a GIT_DIR or GIT_WORK_TREE inherited from the
# session's environment must not point git at another repository.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE

branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null) || exit 0
sha=$(git -C "$cwd" rev-parse HEAD 2>/dev/null) || exit 0
case "$branch" in "" | HEAD) exit 0 ;; esac
case "$sha" in *[!0-9a-f]* | "") exit 0 ;; esac
# The repository's bare NAME, worked out here so the remote URL (which can
# carry a user or a token) never leaves this computer: the last part of the
# origin remote (else the first remote), without ".git". No remote: no
# repository is sent.
remote=origin
git -C "$cwd" remote get-url origin >/dev/null 2>&1 || remote=$(git -C "$cwd" remote 2>/dev/null | head -n 1)
repo=""
[ -n "$remote" ] && repo=$(git -C "$cwd" remote get-url "$remote" 2>/dev/null)
repo=${repo%/}
repo=${repo##*/}
repo=${repo##*:}
repo=${repo%.git}
case "$repo" in *[!A-Za-z0-9._-]*) repo="" ;; esac

dir="$(aionas_savings_dir)/branch-report"
aionas_mkdir "$dir" || exit 0
last="$dir/$sid"
state="$branch|$sha|$repo"
if [ -f "$last" ] && [ "$(cat "$last" 2>/dev/null)" = "$state" ]; then exit 0; fi
aionas_lock_try "branch-report-$sid" 10 || exit 0

t=$(aionas_now)
observed=$(date -u -r "$t" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$t" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
body="$dir/.body.$$"
out="$dir/.out.$$"
repo_field=""
[ -n "$repo" ] && repo_field=",\"repo\":\"$repo\""
printf '{"session_id":"%s","branch":%s,"head_sha":"%s","observed_at":"%s"%s}' \
  "$sid" "$(aionas_json_escape "$branch")" "$sha" "$observed" "$repo_field" >"$body"
if aionas_http POST /enroll/v1/cc-session-git "$body" "$out" >/dev/null 2>&1; then
  printf '%s\n' "$state" | aionas_write_atomic "$last"
fi
rm -f "$body" "$out"
aionas_lock_release "branch-report-$sid"
# Sessions older than a week need no state.
find "$dir" -type f -mtime +7 -delete 2>/dev/null
exit 0
