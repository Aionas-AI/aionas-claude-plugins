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

# aionas_ssh_hostname ALIAS: the real host behind an SSH alias, from this
# computer's own ssh configuration (`ssh -G`: reads config, makes no connection).
# Only the hostname line is read; nothing else of ssh's output is kept. Where ssh
# is missing, fails or answers with anything odd, the alias itself is kept (the
# server treats an unresolved alias as undecided).
# ssh.github.com (GitHub's SSH-over-443 host) is github.com.
# `ssh -G` evaluates `Match exec` in the member's ssh config, i.e. it can run the
# member's own commands. That is why it is rare and bounded: an answer (or a
# failure) is cached per alias for the UTC day in $dir/ssh-hosts, so it is not
# run on every prompt; it runs only under `timeout` / `gtimeout` (3 s), and where
# neither exists it does not run at all.
aionas_ssh_hostname() {
  local a=$1 h="" t="" day cache="$dir/ssh-hosts" line
  day=$(($(aionas_now) / 86400))
  if [ -f "$cache" ]; then
    line=$(grep "^$day $a " "$cache" 2>/dev/null | head -n 1)
    if [ -n "$line" ]; then printf '%s' "${line##* }"; return 0; fi
  fi
  if command -v ssh >/dev/null 2>&1; then
    if command -v timeout >/dev/null 2>&1; then t=timeout; elif command -v gtimeout >/dev/null 2>&1; then t=gtimeout; fi
    [ -n "$t" ] || { printf '%s' "$a"; return 0; }
    h=$($t 3 ssh -G -o BatchMode=yes -- "$a" 2>/dev/null | awk '$1 == "hostname" { print $2; exit }')
  else
    printf '%s' "$a"; return 0
  fi
  case "$h" in "" | *[!A-Za-z0-9._-]*) h=$a ;; esac
  case "$h" in [Ss][Ss][Hh].[Gg][Ii][Tt][Hh][Uu][Bb].[Cc][Oo][Mm]) h=github.com ;; esac
  { grep "^$day " "$cache" 2>/dev/null; printf '%s %s %s\n' "$day" "$a" "$h"; } | aionas_write_atomic "$cache" 2>/dev/null
  printf '%s' "$h"
}

# aionas_remote_owner URL: "<host>/<owner>", lower-cased, worked out here from a
# remote URL; prints nothing for a local path or anything unparsable. The user
# and token part of a URL, the port and the repository name are dropped, so
# none of them can leave. The owner is every path segment but the last.
aionas_remote_owner() {
  local u=$1 rest auth host path owner ssh=0
  case "$u" in "" | /* | . | .* | ~* | file:* | *\\*) return 0 ;; esac
  case "$u" in
    *://*)
      rest=${u#*://}
      case "${u%%://*}" in ssh | git+ssh | ssh+git) ssh=1 ;; esac
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
      ssh=1
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
  [ "$ssh" = 1 ] && host=$(aionas_ssh_hostname "$host")
  case "$owner" in "" | /* | */ | *//* | *[!A-Za-z0-9._/~-]*) return 0 ;; esac
  # A "." or ".." segment is never an owner.
  case "/$owner/" in */./* | */../*) return 0 ;; esac
  printf '%s/%s' "$host" "$owner" | tr 'A-Z' 'a-z'
}

dir="$(aionas_savings_dir)/branch-report"
aionas_mkdir "$dir" || exit 0
seen=""
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
# source; else the first other remote with a different owner). Worked out here; no URL, user, token or port leaves. root_sha is the
# first commit (the smallest when there are several): a project id that needs
# no remote.
owner=""
[ -n "$remote" ] && owner=$(aionas_remote_owner "$(git -C "$cwd" remote get-url "$remote" 2>/dev/null)")
# upstream_owner: the owners of ALL the other remotes, "upstream" first, then the
# rest in name order; not the origin's own, no duplicates, none equal to
# repo_owner, at most 5, one space between (a personal fork's company remote can
# have any name).
upstream=""
n=0
for r in upstream $(git -C "$cwd" remote 2>/dev/null | LC_ALL=C sort); do
  [ "$r" = "$remote" ] && continue
  case " $seen " in *" $r "*) continue ;; esac
  seen="$seen $r"
  o=$(aionas_remote_owner "$(git -C "$cwd" remote get-url "$r" 2>/dev/null)")
  [ -n "$o" ] && [ "$o" != "$owner" ] || continue
  case " $upstream " in *" $o "*) continue ;; esac
  upstream="${upstream:+$upstream }$o"
  n=$((n + 1))
  [ "$n" -lt 5 ] || break
done
root=$(git -C "$cwd" rev-list --max-parents=0 HEAD 2>/dev/null | LC_ALL=C sort | head -n 1)
case "$root" in *[!0-9a-f]* | "") root="" ;; esac
[ "${#root}" -eq 40 ] || root=""

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
