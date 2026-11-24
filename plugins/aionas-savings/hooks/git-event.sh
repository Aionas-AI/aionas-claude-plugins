#!/usr/bin/env bash
# aionas-savings hook: git-event (PostToolUse, async). Owner: AIO-1088 (W33-16).
# Tells Aionas that a commit, a pull request or a push happened in this
# session, so a Work Item can show them. Runs after a Bash (Claude Code) or
# Shell (Cursor) tool call that SUCCEEDED and whose command starts with
# "git commit", "gh pr create" or "git push".
#
# What leaves the computer (W33-1): the session id, the event name, the branch,
# the commit sha, the pull request number, the repository's bare name, the
# time and the app (cursor or claude_code). Never a command, its arguments, a
# commit message, a diff, the tool's output, a prompt or a path.
#
# What this hook reads of the payload: only the fields in the allow list below.
# The tool's stdout, stderr and output text are dropped by that filter and are
# never put in a variable. The command text is read into ONE local variable of
# the classifier, only to pick the event name; it is never written anywhere or
# passed to another process. Prints nothing, never decides anything, exits 0.
set -u
. "$(dirname "$0")/../lib/aionas.sh" 2>/dev/null || exit 0

aionas_enroll_has_alias || exit 0
# An older gateway lists no such capability: nothing is sent or queued.
aionas_policy_has_capability session_git_events || exit 0
command -v git >/dev/null 2>&1 || exit 0

# _ge_classify: the command on stdin -> event names (commit, pr, push), one
# per line. A segment (split on && || ; and newline outside quotes) counts only
# when its leading words are the command; env assignments and "git -C <dir>"
# may come first. Anything else, in doubt: no event.
_ge_classify() {
  local c="" i=0 n ch nx q="" seg="" segs=() s words rest tok k
  IFS= read -r -d '' c || true
  n=${#c}
  while [ "$i" -lt "$n" ]; do
    ch=${c:$i:1}
    nx=${c:$((i + 1)):1}
    if [ -n "$q" ]; then
      [ "$ch" = "$q" ] && q=""
      seg+=$ch
    else
      case "$ch" in
        '"' | "'") q=$ch; seg+=$ch ;;
        '\') seg+=$ch$nx; i=$((i + 1)) ;;
        ';' | $'\n') segs+=("$seg"); seg="" ;;
        '&') if [ "$nx" = '&' ]; then segs+=("$seg"); seg=""; i=$((i + 1)); else seg+=$ch; fi ;;
        '|') if [ "$nx" = '|' ]; then segs+=("$seg"); seg=""; i=$((i + 1)); else seg+=$ch; fi ;;
        *) seg+=$ch ;;
      esac
    fi
    i=$((i + 1))
  done
  c=""
  # An unterminated quote: the text after it is not a command start. Nothing.
  [ -z "$q" ] || return 0
  segs+=("$seg")
  for s in ${segs[@]+"${segs[@]}"}; do
    rest=$s
    # leading env assignments (NAME=simple-value)
    while :; do
      rest=${rest#"${rest%%[![:space:]]*}"}
      tok=${rest%%[[:space:]]*}
      case "$tok" in
        [A-Za-z_]*=*)
          case "${tok%%=*}" in *[!A-Za-z0-9_]*) break ;; esac
          case "${tok#*=}" in *[!A-Za-z0-9_./:@%+,-]*) break ;; esac
          rest=${rest#"$tok"} ;;
        *) break ;;
      esac
    done
    read -r -a words <<<"$rest"
    k=1
    if [ "${words[0]:-}" = git ]; then
      if [ "${words[1]:-}" = -C ]; then
        case "${words[2]:-}" in "" | *[!A-Za-z0-9_./~-]*) continue ;; esac
        k=3
      fi
      case "${words[$k]:-}" in commit | push) printf '%s\n' "${words[$k]}" ;; esac
    elif [ "${words[0]:-}" = gh ] && [ "${words[1]:-}" = pr ] && [ "${words[2]:-}" = create ]; then
      printf 'pr\n'
    fi
  done
}

# Only these fields are taken from the payload; everything else (the tool's
# stdout, stderr, output) is dropped here.
flat=$(aionas_json_flatten 2>/dev/null | awk -F '\t' '
  $1 == "session_id" || $1 == "cwd" || $1 == "hook_event_name" || $1 == "tool_name" || $1 == "cursor_version" ||
  $1 == "tool_input.command" || $1 == "tool_input.working_directory" || $1 == "workspace_roots.0" ||
  $1 == "interrupted" || $1 == "is_error" || $1 == "exit_code" ||
  $1 == "tool_response.interrupted" || $1 == "tool_response.is_error" || $1 == "tool_response.isError" ||
  $1 == "tool_response.exit_code" || $1 == "tool_response.exitCode" { print }') || exit 0
[ -n "$flat" ] || exit 0

tool=$(printf '%s\n' "$flat" | aionas_json_get tool_name 2>/dev/null)
evname=$(printf '%s\n' "$flat" | aionas_json_get hook_event_name 2>/dev/null)
# The app: p1's aionas_client, from the two fields that tell it.
cv=$(printf '%s\n' "$flat" | aionas_json_get cursor_version 2>/dev/null)
probe="{\"hook_event_name\":$(aionas_json_escape "$evname")"
[ -n "$cv" ] && probe="$probe,\"cursor_version\":$(aionas_json_escape "$cv")"
client=$(aionas_client "$probe}")
case "$client:$tool" in
  claude_code:Bash | cursor:Shell) ;;
  *) exit 0 ;;
esac
# A failed tool call is another event (PostToolUseFailure / postToolUseFailure).
case "$evname" in PostToolUse | postToolUse) ;; *) exit 0 ;; esac
# Typed success fields, where the payload has them.
for k in interrupted is_error tool_response.interrupted tool_response.is_error tool_response.isError; do
  v=$(printf '%s\n' "$flat" | aionas_json_get "$k" 2>/dev/null) && [ "$v" != false ] && exit 0
done
for k in exit_code tool_response.exit_code tool_response.exitCode; do
  if v=$(printf '%s\n' "$flat" | aionas_json_get "$k" 2>/dev/null); then
    [ "$(printf '%s\n' "$flat" | aionas_json_type "$k")" = n ] && [ "$v" = 0 ] || exit 0
  fi
done

events=$(printf '%s\n' "$flat" | aionas_json_get tool_input.command 2>/dev/null | aionas_json_unescape | _ge_classify)
sid=$(printf '%s\n' "$flat" | aionas_json_get session_id 2>/dev/null)
cwd=$(printf '%s\n' "$flat" | aionas_json_get cwd 2>/dev/null | aionas_json_unescape)
[ -n "$cwd" ] || cwd=$(printf '%s\n' "$flat" | aionas_json_get tool_input.working_directory 2>/dev/null | aionas_json_unescape)
[ -n "$cwd" ] || cwd=$(printf '%s\n' "$flat" | aionas_json_get workspace_roots.0 2>/dev/null | aionas_json_unescape)
flat=""
[ -n "$events" ] || exit 0

h4='[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]'
# shellcheck disable=SC2254
case "$sid" in
  $h4$h4-$h4-$h4-$h4-$h4$h4$h4) ;;
  *) exit 0 ;;
esac
[ -n "$cwd" ] && [ -d "$cwd" ] || exit 0
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE

branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null) || exit 0
sha=$(git -C "$cwd" rev-parse HEAD 2>/dev/null) || exit 0
case "$branch" in "" | HEAD) exit 0 ;; esac
case "$sha" in *[!0-9a-f]* | "") exit 0 ;; esac
case ${#sha} in 40 | 64) ;; *) exit 0 ;; esac

# The repository's bare NAME, as branch-report.sh works it out (never the URL).
remote=origin
git -C "$cwd" remote get-url origin >/dev/null 2>&1 || remote=$(git -C "$cwd" remote 2>/dev/null | head -n 1)
repo=""
[ -n "$remote" ] && repo=$(git -C "$cwd" remote get-url "$remote" 2>/dev/null)
repo=${repo%/}
repo=${repo##*/}
repo=${repo##*:}
repo=${repo%.git}
case "$repo" in *[!A-Za-z0-9._-]*) repo="" ;; esac

dir="$(aionas_savings_dir)/git-event"
aionas_mkdir "$dir" || exit 0
aionas_lock_try "git-event-$sid" 20 || exit 0

for ev in commit pr push; do
  case "
$events
" in *"
$ev
"*) ;; *) continue ;; esac
  last="$dir/$sid.$ev"
  [ -f "$last" ] && [ "$(cat "$last" 2>/dev/null)" = "$sha" ] && continue
  pr_field=""
  case "$ev" in
    commit)
      # A commit that just happened: HEAD's committer time is within 10
      # minutes of now. A failed "git commit" (nothing to commit) leaves an
      # older HEAD, so a session's first event cannot report it.
      ct=$(git -C "$cwd" log -1 --format=%ct HEAD 2>/dev/null) || continue
      case "$ct" in "" | *[!0-9]*) continue ;; esac
      now=$(aionas_now)
      [ $((now - ct)) -le 600 ] && [ $((ct - now)) -le 600 ] || continue
      ;;
    push)
      up=$(git -C "$cwd" rev-parse '@{u}' 2>/dev/null) || continue
      [ "$up" = "$sha" ] || continue
      ;;
    pr)
      command -v gh >/dev/null 2>&1 || continue
      ghout="$dir/.gh.$$"
      (cd "$cwd" && exec gh pr view --json number -q .number) >"$ghout" 2>/dev/null </dev/null &
      gpid=$!
      (sleep 10; kill "$gpid") >/dev/null 2>&1 </dev/null &
      wpid=$!
      wait "$gpid" 2>/dev/null
      kill "$wpid" >/dev/null 2>&1
      num=$(head -n 1 "$ghout" 2>/dev/null)
      rm -f "$ghout"
      case "$num" in "" | *[!0-9]* | 0*) continue ;; esac
      [ ${#num} -le 9 ] || continue
      pr_field=",\"pr_number\":$num"
      ;;
  esac
  t=$(aionas_now)
  observed=$(date -u -r "$t" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$t" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
  repo_field=""
  [ -n "$repo" ] && repo_field=",\"repo\":\"$repo\""
  body="$dir/.body.$$"
  out="$dir/.out.$$"
  printf '{"session_id":"%s","event":"%s","branch":%s,"head_sha":"%s","observed_at":"%s"%s%s,"client":"%s"}' \
    "$sid" "$ev" "$(aionas_json_escape "$branch")" "$sha" "$observed" "$pr_field" "$repo_field" "$client" >"$body"
  # A failed send is not retried: the next event carries the state.
  if aionas_http POST /enroll/v1/cc-session-git "$body" "$out" >/dev/null 2>&1; then
    printf '%s\n' "$sha" | aionas_write_atomic "$last"
  fi
  rm -f "$body" "$out"
done
aionas_lock_release "git-event-$sid"
# State older than a week is not needed.
find "$dir" -maxdepth 1 -type f -mtime +7 -exec rm -f {} + 2>/dev/null
exit 0
