#!/usr/bin/env bash
# hooks/script-refresh.sh: the installed plan collector and status-line tap
# update themselves from the gateway (AIO-904). Every check below is on the
# files in a temporary ~/.aionas/agent/tools and on the requests the fake curl
# recorded, never on internal variables.
. "$(dirname "$0")/../lib/harness.sh"

HOOK="$T_PLUGIN/hooks/script-refresh.sh"
ROUTER="$T_REPO/tests/fixtures/script-refresh/route-curl.sh"
STUB="$T_REPO/tests/fixtures/script-refresh/stub-gateway.py"
T0=1792490400 # 2026-10-20T10:00:00Z
DAY=86400
NAMES="aionas-plan-usage.sh aionas-statusline-tap.sh aionas-plan-usage.ps1 aionas-statusline-tap.ps1"

# sha FILE: an independent sha256 (not the plugin's resolver).
sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
inode() { stat -c %i "$1" 2>/dev/null || stat -f %i "$1"; }
hook() { printf '{"session_id":"s1","hook_event_name":"SessionStart"}' | bash "$HOOK"; }
tools() { echo "$HOME/.aionas/agent/tools"; }
listing() { ls -A "$(tools)" | LC_ALL=C sort | tr '\n' ' '; }
# tick: the clock moves to the next UTC day (a new one each call).
tick() { TICK=$((${TICK:-0} + 1)); export AIONAS_NOW=$((T0 + DAY * TICK)); }
day_file() { echo "$(aionas_savings_dir)/script-refresh.day"; }

# body NAME STAMP: the bytes of a script. .ps1 files are CRLF, like the ones
# the installer writes on Windows.
body() {
  case "$1" in
    *.sh) printf '#!/bin/bash\nAIONAS_RELEASE=%s\necho %s %s\n' "'$2'" "$1" "$2" ;;
    *) printf '$AIONAS_RELEASE = %s\r\nWrite-Output %s\r\n' "'$2'" "$1-$2" ;;
  esac
}

# install_v1: the four scripts the one install leaves, mode 700.
install_v1() {
  mkdir -p "$(tools)"
  local n
  for n in $NAMES; do
    body "$n" V1 >"$(tools)/$n"
    chmod 700 "$(tools)/$n"
  done
}

# serve STAMP [NAME...]: the gateway's copies (default: all four) and a manifest
# that names them with the right hashes.
serve() {
  local stamp=$1; shift
  [ $# -eq 0 ] && set -- $NAMES
  SR_SERVE=${SR_SERVE:-$(mktemp -d "$T_ROOT/serve.XXXXXX")}; export SR_SERVE
  local n first=1 json='{"release":"R","scripts":['
  for n in "$@"; do
    body "$n" "$stamp" >"$SR_SERVE/$n"
    [ $first -eq 1 ] || json="$json,"
    first=0
    json="$json{\"name\":\"$n\",\"version\":\"$stamp\",\"sha256\":\"$(sha "$SR_SERVE/$n")\"}"
  done
  printf '%s]}\n' "$json" >"$SR_SERVE/manifest.json"
}

# prepare: enrolled computer, V1 installed, V2 served, router as curl, clock pinned.
prepare() {
  t_enroll
  install_v1
  serve V2
  export AIONAS_CURL="$ROUTER" AIONAS_NOW=$T0
  unset SR_MANIFEST_STATUS SR_SCRIPT_STATUS
}

# calls_to PATTERN: how many recorded requests have a URL containing PATTERN.
calls_to() {
  local i n=0 c; c=$(t_calls)
  for ((i = 1; i <= c; i++)); do
    case "$(t_call "$i" url)" in *"$1"*) n=$((n + 1)) ;; esac
  done
  echo "$n"
}

test_aio904_both_collector_and_tap_pairs_are_replaced_atomically() {
  prepare
  local n
  for n in $NAMES; do inode "$(tools)/$n" >"$HOME/ino.$n"; done
  out=$(hook); t_rc 0 hook
  t_eq "" "$out" "the async hook prints nothing"
  for n in $NAMES; do
    t_eq "$(sha "$SR_SERVE/$n")" "$(sha "$(tools)/$n")" "$n is byte-identical to the served copy"
    cmp -s "$SR_SERVE/$n" "$(tools)/$n" || t_fail "$n differs from served"
    t_eq "$(body "$n" V1)" "$(cat "$(tools)/$n.prev")" "$n.prev holds V1"
    t_eq 700 "$(t_mode "$(tools)/$n")" "mode of $n"
    [ "$(inode "$(tools)/$n")" != "$(cat "$HOME/ino.$n")" ] || t_fail "$n was written in place, not renamed over"
  done
  t_eq "aionas-plan-usage.ps1 aionas-plan-usage.ps1.prev aionas-plan-usage.sh aionas-plan-usage.sh.prev aionas-statusline-tap.ps1 aionas-statusline-tap.ps1.prev aionas-statusline-tap.sh aionas-statusline-tap.sh.prev " "$(listing)" "no temp file is left"
  # CRLF of the .ps1 copies survives byte for byte.
  t_contains "$(od -c "$(tools)/aionas-plan-usage.ps1" | head -3)" '\r'
}

test_aio904_the_manifest_call_carries_the_alias_the_downloads_do_not() {
  prepare; hook
  t_eq 5 "$(t_calls)" "one manifest request and four downloads"
  t_eq GET "$(t_call 1 method)"
  t_eq "https://gw.example.test/enroll/v1/scripts/manifest" "$(t_call 1 url)"
  t_contains "$(t_call 1 headers)" "Authorization: Bearer $T_ALIAS"
  local i
  for i in 2 3 4 5; do
    t_contains "$(t_call $i url)" "https://gw.example.test/api/aionas/onboarding/scripts/aionas-"
    t_lacks "$(t_call $i headers)" "Authorization" "download $i sends no auth header"
    t_lacks "$(t_call $i headers)" "$T_ALIAS" "download $i sends no alias"
    t_lacks "$(t_call $i args)" "$T_ALIAS" "no alias on the command line of download $i"
    t_lacks "$(t_call $i args)" "Authorization" "no Authorization in download $i"
    t_lacks "$(t_call $i args)" "-L" "a redirect is never followed"
    t_contains "$(t_call $i args)" "--max-filesize" "download $i is size-capped"
  done
}

test_aio904_a_second_session_start_the_same_day_makes_no_request() {
  prepare; hook
  local c; c=$(t_calls)
  hook; hook
  t_eq "$c" "$(t_calls)" "no manifest request on a second start"
  t_eq 2026-10-20 "$(cat "$(day_file)")"
}

test_aio904_a_held_lock_means_no_request() {
  prepare
  aionas_lock_try script-refresh 120 || t_fail "could not take the lock"
  hook
  t_eq 0 "$(t_calls)"
  t_eq V1 "$(sed -n "s/^AIONAS_RELEASE='\(.*\)'$/\1/p" "$(tools)/aionas-plan-usage.sh")"
}

test_aio904_a_sha256_mismatch_keeps_v1_and_the_next_day_retries() {
  prepare
  # the manifest names a wrong hash for the first script only
  local good; good=$(sha "$SR_SERVE/aionas-plan-usage.sh")
  sed "s/$good/$(printf '0%.0s' $(seq 64))/" "$SR_SERVE/manifest.json" >"$SR_SERVE/m2" && mv "$SR_SERVE/m2" "$SR_SERVE/manifest.json"
  hook
  t_eq "$(body aionas-plan-usage.sh V1)" "$(cat "$(tools)/aionas-plan-usage.sh")" "V1 stays"
  t_eq "$(sha "$SR_SERVE/aionas-statusline-tap.sh")" "$(sha "$(tools)/aionas-statusline-tap.sh")" "the others are judged on their own and replaced"
  t_eq "aionas-plan-usage.ps1 aionas-plan-usage.ps1.prev aionas-plan-usage.sh aionas-statusline-tap.ps1 aionas-statusline-tap.ps1.prev aionas-statusline-tap.sh aionas-statusline-tap.sh.prev " "$(listing)" "no temp file and no .prev for the refused one"
}

test_aio904_a_failed_check_is_retried_only_the_next_day() {
  prepare
  local good; good=$(sha "$SR_SERVE/aionas-plan-usage.sh")
  cp "$SR_SERVE/manifest.json" "$SR_SERVE/manifest.good"
  sed "s/$good/$(printf '0%.0s' $(seq 64))/" "$SR_SERVE/manifest.json" >"$SR_SERVE/manifest.bad"
  cp "$SR_SERVE/manifest.bad" "$SR_SERVE/manifest.json"
  hook
  local c; c=$(t_calls)
  # fixed on the gateway the same day: still nothing until tomorrow
  cp "$SR_SERVE/manifest.good" "$SR_SERVE/manifest.json"
  hook
  t_eq "$c" "$(t_calls)" "the same day: no retry"
  t_eq V1 "$(sed -n "s/^AIONAS_RELEASE='\(.*\)'$/\1/p" "$(tools)/aionas-plan-usage.sh")"
  export AIONAS_NOW=$((T0 + DAY))
  hook
  t_eq "$(sha "$SR_SERVE/aionas-plan-usage.sh")" "$(sha "$(tools)/aionas-plan-usage.sh")" "the next day it succeeds"
  t_eq 2026-10-21 "$(cat "$(day_file)")"
}

test_aio904_a_non_localhost_http_gateway_makes_no_request() {
  prepare
  t_enroll "http://evil.example:8080"
  hook
  t_eq 0 "$(t_calls)"
  t_enroll "http://localhost.evil.example"
  hook
  t_eq 0 "$(t_calls)"
  t_eq "$(body aionas-plan-usage.sh V1)" "$(cat "$(tools)/aionas-plan-usage.sh")"
}

test_aio904_a_localhost_http_gateway_is_allowed() {
  prepare
  t_enroll "http://127.0.0.1:8700"
  hook
  t_eq 5 "$(t_calls)"
  t_eq "http://127.0.0.1:8700/api/aionas/onboarding/scripts/aionas-plan-usage.sh" "$(t_call 2 url)"
}

test_aio904_names_outside_the_four_or_not_installed_write_nothing() {
  prepare
  rm -f "$(tools)/aionas-statusline-tap.ps1"               # not installed
  printf 'KEEP\n' >"$(tools)/aionas-scan"                  # installed, but not one of the four
  # Files that a hostile name would resolve to if the name were used as a path.
  mkdir -p "$HOME/.aionas/savings"
  printf 'KEEP\n' >"$HOME/.aionas/agent/x"                 # tools/../x
  printf 'KEEP\n' >"$HOME/.aionas/savings/pwn"             # tools/../../savings/pwn
  local before; before=$(listing)
  local n b c0
  for n in evil.sh ../x ../../savings/pwn aionas-scan 'aionas-plan-usage.sh/../evil' aionas-statusline-tap.ps1 ''; do
    # The gateway serves valid bytes for the last path segment of the URL the
    # hook would build, with the matching sha and version: only the name check
    # (not a 404, a hash mismatch or a stamp mismatch) can stop the write.
    b=${n##*/}; [ -n "$b" ] || b=aionas-scan
    body evil.sh V2 >"$SR_SERVE/$b"
    printf '{"release":"R","scripts":[{"name":"%s","version":"V2","sha256":"%s"}]}\n' "$n" "$(sha "$SR_SERVE/$b")" >"$SR_SERVE/manifest.json"
    tick
    c0=$(t_calls)
    hook
    t_eq "$before" "$(listing)" "tools listing identical for name [$n]"
    t_eq $((c0 + 1)) "$(t_calls)" "only the manifest was requested for name [$n]: no download is attempted"
    t_eq KEEP "$(cat "$(tools)/aionas-scan")" "aionas-scan untouched for name [$n]"
    t_eq KEEP "$(cat "$HOME/.aionas/agent/x")" "tools/../x untouched for name [$n]"
    t_eq KEEP "$(cat "$HOME/.aionas/savings/pwn")" "savings/pwn untouched for name [$n]"
  done
  [ ! -e "$HOME/.aionas/x" ] || t_fail "something was written outside tools"
}

test_aio904_an_installed_name_is_replaced_even_when_the_manifest_lists_others() {
  prepare
  rm -f "$(tools)/aionas-statusline-tap.ps1"
  hook
  t_eq "$(sha "$SR_SERVE/aionas-plan-usage.sh")" "$(sha "$(tools)/aionas-plan-usage.sh")"
  [ ! -e "$(tools)/aionas-statusline-tap.ps1" ] || t_fail "a not-installed script was created"
  t_eq 4 "$(t_calls)" "no download for the not-installed one"
}

test_aio904_a_symlink_in_tools_is_not_followed_or_replaced() {
  prepare
  printf 'TARGET\n' >"$HOME/target"
  rm -f "$(tools)/aionas-plan-usage.sh"
  ln -s "$HOME/target" "$(tools)/aionas-plan-usage.sh"
  hook
  t_eq TARGET "$(cat "$HOME/target")"
  [ -L "$(tools)/aionas-plan-usage.sh" ] || t_fail "the symlink was replaced"
  [ ! -e "$(tools)/aionas-plan-usage.sh.prev" ] || t_fail "a .prev was made from a symlink"
}

test_aio904_settings_json_is_byte_identical() {
  prepare
  mkdir -p "$HOME/.claude"
  printf '{"permissions":{"allow":["Bash(ls)"]},"x":1}\n' >"$HOME/.claude/settings.json"
  cp "$HOME/.claude/settings.json" "$HOME/settings.before"
  hook
  cmp "$HOME/.claude/settings.json" "$HOME/settings.before" || t_fail "settings.json changed"
  [ "$(find "$HOME/.claude" -type f | wc -l | tr -d ' ')" = 1 ] || t_fail "a file appeared in ~/.claude"
}

test_aio904_a_script_already_at_the_manifest_version_is_not_downloaded() {
  prepare
  body aionas-plan-usage.sh V2 >"$(tools)/aionas-plan-usage.sh"; chmod 700 "$(tools)/aionas-plan-usage.sh"
  body aionas-statusline-tap.ps1 V2 >"$(tools)/aionas-statusline-tap.ps1"; chmod 700 "$(tools)/aionas-statusline-tap.ps1"
  hook
  t_eq 3 "$(t_calls)" "manifest and the two that differ"
  t_eq 0 "$(calls_to scripts/aionas-plan-usage.sh)"
  [ ! -e "$(tools)/aionas-plan-usage.sh.prev" ] || t_fail ".prev for an unchanged file"
}

test_aio904_a_file_without_a_stamp_is_unknown_and_replaced() {
  prepare
  printf '#!/bin/bash\necho old\n' >"$(tools)/aionas-plan-usage.sh"
  printf '#!/bin/bash\nAIONAS_RELEASE=%s\n' "'__AIONAS_RELEASE__'" >"$(tools)/aionas-statusline-tap.sh"
  hook
  t_eq "$(sha "$SR_SERVE/aionas-plan-usage.sh")" "$(sha "$(tools)/aionas-plan-usage.sh")"
  t_eq "$(sha "$SR_SERVE/aionas-statusline-tap.sh")" "$(sha "$(tools)/aionas-statusline-tap.sh")"
  t_eq "$(printf '#!/bin/bash\necho old\n')" "$(cat "$(tools)/aionas-plan-usage.sh.prev")"
}

test_aio904_an_empty_or_placeholder_version_is_skipped_without_a_download() {
  prepare
  local n
  for n in "" "__AIONAS_RELEASE__" "has space" "a;b" "-lead" "$(printf 'x%.0s' $(seq 70))"; do
    printf '{"release":"R","scripts":[{"name":"aionas-plan-usage.sh","version":"%s","sha256":"%s"}]}\n' \
      "$n" "$(sha "$SR_SERVE/aionas-plan-usage.sh")" >"$SR_SERVE/manifest.json"
    tick
    hook
    t_eq 0 "$(calls_to /api/aionas/onboarding/scripts/)" "no download for version [$n]"
    t_eq "$(body aionas-plan-usage.sh V1)" "$(cat "$(tools)/aionas-plan-usage.sh")"
  done
}

test_aio904_a_malformed_sha256_is_skipped_without_a_download() {
  prepare
  local h
  for h in "" "ABCDEF" "$(printf 'A%.0s' $(seq 64))" "$(printf 'g%.0s' $(seq 64))" "$(printf 'a%.0s' $(seq 63))"; do
    printf '{"release":"R","scripts":[{"name":"aionas-plan-usage.sh","version":"V2","sha256":"%s"}]}\n' "$h" >"$SR_SERVE/manifest.json"
    tick
    hook
    t_eq 0 "$(calls_to /api/aionas/onboarding/scripts/)" "no download for sha [$h]"
  done
}

test_aio904_served_bytes_whose_stamp_differs_from_the_manifest_are_not_installed() {
  prepare
  body aionas-plan-usage.sh V3 >"$SR_SERVE/aionas-plan-usage.sh"  # manifest hash is for V3 bytes: make the version lie
  printf '{"release":"R","scripts":[{"name":"aionas-plan-usage.sh","version":"V2","sha256":"%s"}]}\n' "$(sha "$SR_SERVE/aionas-plan-usage.sh")" >"$SR_SERVE/manifest.json"
  hook
  t_eq "$(body aionas-plan-usage.sh V1)" "$(cat "$(tools)/aionas-plan-usage.sh")" "never converges, so never installed"
  t_eq "aionas-plan-usage.ps1 aionas-plan-usage.sh aionas-statusline-tap.ps1 aionas-statusline-tap.sh " "$(listing)"
}

test_aio904_a_shell_script_must_start_with_a_shebang() {
  prepare
  printf 'AIONAS_RELEASE=%s\necho no shebang\n' "'V2'" >"$SR_SERVE/aionas-plan-usage.sh"
  printf '{"release":"R","scripts":[{"name":"aionas-plan-usage.sh","version":"V2","sha256":"%s"}]}\n' "$(sha "$SR_SERVE/aionas-plan-usage.sh")" >"$SR_SERVE/manifest.json"
  hook
  t_eq "$(body aionas-plan-usage.sh V1)" "$(cat "$(tools)/aionas-plan-usage.sh")"
  t_eq "aionas-plan-usage.ps1 aionas-plan-usage.sh aionas-statusline-tap.ps1 aionas-statusline-tap.sh " "$(listing)"
}

test_aio904_not_enrolled_makes_no_request_and_writes_nothing() {
  prepare
  t_unenroll
  out=$(hook); t_rc 0 hook
  t_eq "" "$out"
  t_eq 0 "$(t_calls)"
  [ ! -e "$(day_file)" ] || t_fail "a day stamp on a computer that is not enrolled"
}

test_aio904_a_manifest_the_gateway_does_not_know_is_a_quiet_no_op() {
  prepare
  local s
  for s in 404 500 000 301 204; do
    export SR_MANIFEST_STATUS=$s; tick
    out=$(hook); t_rc 0 hook
    t_eq "" "$out" "status $s"
    t_eq "$(body aionas-plan-usage.sh V1)" "$(cat "$(tools)/aionas-plan-usage.sh")" "status $s"
  done
  t_eq 0 "$(calls_to /api/aionas/onboarding/scripts/)" "no download after a failed manifest"
  t_eq "aionas-plan-usage.ps1 aionas-plan-usage.sh aionas-statusline-tap.ps1 aionas-statusline-tap.sh " "$(listing)"
}

test_aio904_a_failing_curl_is_a_quiet_no_op() {
  prepare
  export FAKE_CURL_EXIT=28
  out=$(hook); t_rc 0 hook
  t_eq "" "$out"
  t_eq "$(body aionas-plan-usage.sh V1)" "$(cat "$(tools)/aionas-plan-usage.sh")"
}

test_aio904_an_invalid_manifest_body_changes_nothing() {
  prepare
  local b
  for b in 'not json' '{"scripts":' '[]' '{"release":"R"}' '{"scripts":"x"}'; do
    printf '%s' "$b" >"$SR_SERVE/manifest.json"
    tick
    hook; t_rc 0 hook
    t_eq 0 "$(calls_to /api/aionas/onboarding/scripts/)" "body [$b]"
  done
}

test_aio904_a_download_that_is_not_a_200_changes_nothing() {
  prepare
  export SR_SCRIPT_STATUS=206
  hook
  t_eq "$(body aionas-plan-usage.sh V1)" "$(cat "$(tools)/aionas-plan-usage.sh")"
  t_eq "aionas-plan-usage.ps1 aionas-plan-usage.sh aionas-statusline-tap.ps1 aionas-statusline-tap.sh " "$(listing)"
}

test_aio904_a_hash_tool_planted_on_path_is_never_used() {
  prepare
  local bin="$HOME/evil"; mkdir -p "$bin"
  local t
  for t in sha256sum shasum openssl; do
    printf '#!/bin/sh\ntouch "%s/ran-%s"\necho 0000000000000000000000000000000000000000000000000000000000000000 x\n' "$HOME" "$t" >"$bin/$t"
    chmod +x "$bin/$t"
  done
  PATH="$bin:$PATH" hook
  [ ! -e "$HOME/ran-sha256sum" ] && [ ! -e "$HOME/ran-shasum" ] && [ ! -e "$HOME/ran-openssl" ] || t_fail "a hash tool from PATH ran"
  t_eq "$(sha "$SR_SERVE/aionas-plan-usage.sh")" "$(sha "$(tools)/aionas-plan-usage.sh")" "the real hash was still checked, and matched"
}

test_aio904_without_any_hash_tool_it_fails_closed() {
  prepare
  AIONAS_SHA256_BIN=/nonexistent/sha256sum hook
  t_eq "$(body aionas-plan-usage.sh V1)" "$(cat "$(tools)/aionas-plan-usage.sh")" "nothing installed unverified"
  t_eq "aionas-plan-usage.ps1 aionas-plan-usage.sh aionas-statusline-tap.ps1 aionas-statusline-tap.sh " "$(listing)"
}

test_aio904_the_prev_copies_are_removed_by_name_on_a_later_day() {
  prepare; hook
  printf 'x' >"$(tools)/aionas-plan-usage.sh.tmp.9999"        # a killed run's leftover
  printf 'KEEP\n' >"$(tools)/aionas-scan"
  mkdir -p "$(tools)/dir" && printf 'KEEP\n' >"$(tools)/dir/file"
  # same day is not reached (one run a day); the next day cleans .prev and temp
  export AIONAS_NOW=$((T0 + DAY))
  serve V2   # nothing to update: same stamps
  hook
  t_eq "aionas-plan-usage.ps1 aionas-plan-usage.sh aionas-scan aionas-statusline-tap.ps1 aionas-statusline-tap.sh dir " "$(listing)"
  t_eq KEEP "$(cat "$(tools)/dir/file")"
  t_eq KEEP "$(cat "$(tools)/aionas-scan")"
}

# A manifest whose `scripts` is not an array is read as nothing, even when the
# flattened paths look like array entries. The gateway serves sha-matching
# bytes, so only the shape check can stop the write.
test_aio904_a_scripts_member_that_is_not_an_array_installs_nothing() {
  prepare
  local n sha1 shape before
  sha1=$(sha "$SR_SERVE/aionas-plan-usage.sh")
  before=$(listing)
  for shape in object dotted; do
    case "$shape" in
      object) printf '{"scripts":{"0":{"name":"aionas-plan-usage.sh","version":"V2","sha256":"%s"}}}\n' "$sha1" >"$SR_SERVE/manifest.json" ;;
      dotted) printf '{"scripts.0.name":"aionas-plan-usage.sh","scripts.0.version":"V2","scripts.0.sha256":"%s"}\n' "$sha1" >"$SR_SERVE/manifest.json" ;;
    esac
    tick
    out=$(hook); t_rc 0 hook
    t_eq "" "$out" "quiet for shape $shape"
    t_eq 0 "$(calls_to /api/aionas/onboarding/scripts/)" "no download for shape $shape"
    t_eq "$before" "$(listing)" "tools listing unchanged for shape $shape"
    for n in $NAMES; do
      t_eq "$(body "$n" V1)" "$(cat "$(tools)/$n")" "$n unchanged for shape $shape"
    done
  done
}

test_aio904_a_manifest_over_64_kb_is_rejected_quietly() {
  prepare
  local pad; pad=$(head -c 70000 /dev/zero | tr '\0' 'a')
  printf '{"release":"R","pad":"%s","scripts":[{"name":"aionas-plan-usage.sh","version":"V2","sha256":"%s"}]}\n' \
    "$pad" "$(sha "$SR_SERVE/aionas-plan-usage.sh")" >"$SR_SERVE/manifest.json"
  out=$(hook); t_rc 0 hook
  t_eq "" "$out"
  t_eq 0 "$(calls_to /api/aionas/onboarding/scripts/)" "no download"
  t_eq "$(body aionas-plan-usage.sh V1)" "$(cat "$(tools)/aionas-plan-usage.sh")"
}

test_aio904_leftover_manifest_files_are_removed_by_exact_name_on_a_later_day() {
  prepare; hook
  local d; d=$(aionas_savings_dir)
  printf 'x' >"$d/script-refresh.manifest.4242"     # a killed run's leftover
  printf 'KEEP\n' >"$d/script-refresh.manifest.old" # not all digits
  printf 'KEEP\n' >"$d/script-refresh.manifest"     # no suffix
  export AIONAS_NOW=$((T0 + DAY))
  hook
  [ ! -e "$d/script-refresh.manifest.4242" ] || t_fail "digit-suffixed leftover was not removed"
  t_eq KEEP "$(cat "$d/script-refresh.manifest.old")" "non-digit lookalike stays"
  t_eq KEEP "$(cat "$d/script-refresh.manifest")" "unsuffixed lookalike stays"
}

test_aio904_the_prev_copy_survives_the_day_it_was_made_and_is_replaced_by_a_newer_update() {
  prepare; hook
  export AIONAS_NOW=$((T0 + DAY))
  serve V3
  hook
  t_eq "$(body aionas-plan-usage.sh V2)" "$(cat "$(tools)/aionas-plan-usage.sh.prev")" ".prev now holds V2"
  t_eq "$(sha "$SR_SERVE/aionas-plan-usage.sh")" "$(sha "$(tools)/aionas-plan-usage.sh")"
}

test_aio904_the_hook_has_no_recursive_delete_and_no_network_tool_of_its_own() {
  local src; src=$(grep -vE '^[[:space:]]*#' "$HOOK" "$T_PLUGIN/lib/script-refresh.sh")
  t_lacks "$src" "rm -r" ; t_lacks "$src" "rm -fr"; t_lacks "$src" "rm -rf"; t_lacks "$src" "-delete"
  t_lacks "$src" "curl"
  t_lacks "$src" "settings.json"
  t_lacks "$src" "source "
}

test_aio904_hooks_json_runs_it_async_with_room_for_the_downloads() {
  local flat; flat=$(aionas_json_flatten "$T_PLUGIN/hooks/hooks.json")
  local p
  p=$(printf '%s\n' "$flat" | awk -F '\t' '$3 ~ /script-refresh\.sh/ { print $1 }')
  [ -n "$p" ] || t_fail "script-refresh.sh is not in hooks.json"
  case "$p" in hooks.SessionStart.*) ;; *) t_fail "not a SessionStart entry: $p" ;; esac
  p=${p%.command}
  t_eq true "$(printf '%s\n' "$flat" | aionas_json_get "$p.async")"
  t_eq 30 "$(printf '%s\n' "$flat" | aionas_json_get "$p.timeout")"
  [ -x "$HOOK" ] || t_fail "not executable"
  t_eq '#!/usr/bin/env bash' "$(head -1 "$HOOK")"
  t_contains "$(sed -n 1,12p "$HOOK")" "AIO-904"
  t_contains "$(cat "$HOOK")" "set -u"
  if grep -q $'\r' "$HOOK"; then t_fail "CRLF in the hook"; fi
}

test_aio904_aionas_http_public_sends_no_auth_and_checks_the_gateway() {
  prepare
  export AIONAS_CURL="$T_REPO/tests/lib/fake-curl.sh"
  local out; out=$(mktemp "$T_ROOT/o.XXXXXX")
  export FAKE_CURL_STATUS=200 FAKE_CURL_BODY="$SR_SERVE/manifest.json"
  t_eq 200 "$(aionas_http_public GET /api/aionas/onboarding/scripts/x "$out")"
  t_lacks "$(t_call 1 headers)" "Authorization"
  t_lacks "$(t_call 1 headers)" "$T_ALIAS"
  t_lacks "$(t_call 1 args)" "$T_ALIAS"
  t_enroll "http://evil.example"
  t_rc 3 aionas_http_public GET /x "$out" >/dev/null
  t_eq 1 "$(t_calls)" "no call for a gateway that is neither https nor this computer"
  t_enroll
  (export FAKE_CURL_STATUS=404; t_rc 1 aionas_http_public GET /x "$out" >/dev/null)
  t_eq 000 "$(FAKE_CURL_EXIT=28 aionas_http_public GET /x "$out" || true)"
}

# The real curl against a local stub: the manifest asks with the alias, the
# downloads do not, and a redirect is not followed.
test_aio904_with_the_real_curl_the_download_carries_no_alias_and_a_redirect_is_not_followed() {
  command -v python3 >/dev/null || { echo "    skip: no python3"; return 0; }
  command -v curl >/dev/null || { echo "    skip: no curl"; return 0; }
  prepare
  unset AIONAS_CURL
  local portf log pid port
  portf=$(mktemp "$T_ROOT/port.XXXXXX"); log=$(mktemp "$T_ROOT/log.XXXXXX")
  : >"$portf"
  python3 -I "$STUB" "$portf" "$log" "$SR_SERVE" &
  pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do [ -s "$portf" ] && break; sleep 0.2; done
  port=$(cat "$portf")
  [ -n "$port" ] || { kill "$pid" 2>/dev/null; t_fail "stub did not start"; }
  t_enroll "http://127.0.0.1:$port"
  hook
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  local req; req=$(cat "$log")
  t_contains "$req" "REQUEST GET /enroll/v1/scripts/manifest"
  t_contains "$req" "REQUEST GET /api/aionas/onboarding/scripts/aionas-plan-usage.sh"
  # the alias appears exactly once: in the manifest request
  t_eq 1 "$(grep -c "$T_ALIAS" "$log")" "the alias is sent on the manifest request only"
  t_eq "$(sha "$SR_SERVE/aionas-plan-usage.sh")" "$(sha "$(tools)/aionas-plan-usage.sh")" "a 200 download is installed"
  t_eq "$(sha "$SR_SERVE/aionas-statusline-tap.ps1")" "$(sha "$(tools)/aionas-statusline-tap.ps1")"
  t_eq "$(body aionas-plan-usage.ps1 V1)" "$(cat "$(tools)/aionas-plan-usage.ps1")" "a 302 is not a 200: the .ps1 stays V1"
  t_lacks "$req" "/elsewhere/" "the redirect was not followed"
}

t_main "$@"
