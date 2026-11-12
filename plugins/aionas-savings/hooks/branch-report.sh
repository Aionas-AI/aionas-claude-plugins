#!/usr/bin/env bash
# aionas-savings hook: branch-report (UserPromptSubmit, async). Owner: AIO-1019.
# Sends the git branch and commit of the folder the member prompted from, so
# Aionas can group the session's requests into Work Items (one person's repo +
# branch). Sent only when the branch or commit changed for this session.
#
# Reads two fields of the hook input: session_id and cwd. The prompt is never
# read, kept or sent, and neither is the folder path: the body is the session
# id, the branch name, the commit, the repository's bare name (worked out
# here from the origin remote, never the URL), "<host>/<owner>" of the origin
# and of an upstream remote, the first commit's sha (all three optional,
# AIO-1035) and the time. Not a git folder, a detached
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

# aionas_remote_owner URL: "<host>/<owner>", lower-cased, worked out here from a
# remote URL; prints nothing for a local path or anything unparsable. The user
# and token part of a URL, the port and the repository name are dropped, so
# none of them can leave. The owner is every path segment but the last.
aionas_remote_owner() {
  local u=$1 rest auth host path owner
  case "$u" in "" | /* | . | .* | ~* | file:* | *\\*) return 0 ;; esac
  case "$u" in
    *://*)
      rest=${u#*://}
      case "$rest" in */*) ;; *) return 0 ;; esac
      auth=${rest%%/*}
      path=${rest#*/}
      auth=${auth##*@}
      host=${auth%%:*}
      ;;
    *:*)
      auth=${u%%:*}
      case "$auth" in */*) return 0 ;; esac
      host=${auth##*@}
      path=${u#*:}
      ;;
    *) return 0 ;;
  esac
  path=${path#/}
  path=${path%/}
  path=${path%.git}
  case "$path" in */*) owner=${path%/*} ;; *) return 0 ;; esac
  # A one-letter host is a Windows drive ("C:/x"), not a server.
  [ "${#host}" -ge 2 ] || return 0
  case "$host" in *[!A-Za-z0-9._-]*) return 0 ;; esac
  case "$owner" in "" | /* | */ | *//* | *[!A-Za-z0-9._/~-]*) return 0 ;; esac
  printf '%s/%s' "$host" "$owner" | tr 'A-Z' 'a-z'
}

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
# Who owns the repository, so Aionas can tell a company repo from a personal one:
# "<host>/<owner>" of the same remote, and of a remote named upstream (a fork's
# source). Worked out here; no URL, user, token or port leaves. root_sha is the
# first commit (the smallest when there are several): a project id that needs
# no remote.
owner=""
[ -n "$remote" ] && owner=$(aionas_remote_owner "$(git -C "$cwd" remote get-url "$remote" 2>/dev/null)")
upstream=$(aionas_remote_owner "$(git -C "$cwd" remote get-url upstream 2>/dev/null)")
root=$(git -C "$cwd" rev-list --max-parents=0 HEAD 2>/dev/null | LC_ALL=C sort | head -n 1)
case "$root" in *[!0-9a-f]* | "") root="" ;; esac
[ "${#root}" -eq 40 ] || root=""

dir="$(aionas_savings_dir)/branch-report"
aionas_mkdir "$dir" || exit 0
last="$dir/$sid"
state="$branch|$sha|$repo|$owner|$upstream|$root"
if [ -f "$last" ] && [ "$(cat "$last" 2>/dev/null)" = "$state" ]; then exit 0; fi
aionas_lock_try "branch-report-$sid" 10 || exit 0

t=$(aionas_now)
observed=$(date -u -r "$t" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$t" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
body="$dir/.body.$$"
out="$dir/.out.$$"
repo_field=""
[ -n "$repo" ] && repo_field=",\"repo\":\"$repo\""
extra=""
[ -n "$owner" ] && extra="$extra,\"repo_owner\":\"$owner\""
[ -n "$upstream" ] && extra="$extra,\"upstream_owner\":\"$upstream\""
[ -n "$root" ] && extra="$extra,\"root_sha\":\"$root\""
printf '{"session_id":"%s","branch":%s,"head_sha":"%s","observed_at":"%s"%s%s}' \
  "$sid" "$(aionas_json_escape "$branch")" "$sha" "$observed" "$repo_field" "$extra" >"$body"
if aionas_http POST /enroll/v1/cc-session-git "$body" "$out" >/dev/null 2>&1; then
  printf '%s\n' "$state" | aionas_write_atomic "$last"
fi
rm -f "$body" "$out"
aionas_lock_release "branch-report-$sid"
# Sessions older than a week need no state.
find "$dir" -type f -mtime +7 -delete 2>/dev/null
exit 0
