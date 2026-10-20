#!/usr/bin/env bash
# The aionas mod's privacy gate (wave-24 mod spec §7, W24-4), checkable:
# `claude plugin validate` must list module calls within ALLOWED_CALLS and env
# reads within ALLOWED_ENV; any $.http.fetch or $.session.messages fails.
# The gate's own logic always runs (against recorded reports); the real
# 2.1.299 report runs when AIONAS_CC_BIN names the claude binary (or a command
# such as "npx -y @anthropic-ai/claude-code@2.1.299"), in a temporary
# CLAUDE_CONFIG_DIR.
. "$(dirname "$0")/../lib/harness.sh"

ALLOWED_CALLS='$.command.register $.command.run $.session.id $.env.get $.env.set $.process.run $.clock.every $.ui.resolve $.ui.invalidate $.ui.toast'
ALLOWED_ENV='CLAUDE_CODE_GIT_BASH_PATH CLAUDE_CODE_EXTRA_BODY ANTHROPIC_BASE_URL'

# gate REPORT_JSON: exit 0 when the report's module calls and env reads are
# within the allowed sets; prints each offender.
gate() {
  local flat calls envs bad=0 x
  flat=$(aionas_json_flatten "$1") || { echo "not a validate report"; return 1; }
  calls=$(printf '%s\n' "$flat" | awk -F '\t' '$1 ~ /^contents\.[0-9]+\.notes\.[0-9]+$/ && $3 ~ /^\.\/mod\.tsx calls: / { sub(/^\.\/mod\.tsx calls: /, "", $3); print $3 }')
  envs=$(printf '%s\n' "$flat" | awk -F '\t' '$1 ~ /^contents\.[0-9]+\.notes\.[0-9]+$/ && $3 ~ /^\.\/mod\.tsx env reads: / { sub(/^\.\/mod\.tsx env reads: /, "", $3); print $3 }')
  [ -n "$calls" ] || { echo "no calls line: the module was not read"; return 1; }
  for x in $(printf '%s\n' "$calls" | sed 's/ ([^)]*)//g; s/,/ /g'); do
    case " $ALLOWED_CALLS " in *" $x "*) ;; *) echo "call not allowed: $x"; bad=1 ;; esac
  done
  for x in $(printf '%s\n' "$envs" | sed 's/,/ /g'); do
    case " $ALLOWED_ENV " in *" $x "*) ;; *) echo "env read not allowed: $x"; bad=1 ;; esac
  done
  return $bad
}

report() { # CALLS ENV_READS -> a validate --json report as 2.1.299 writes it
  local f; f=$(mktemp "$T_ROOT/report.XXXXXX")
  printf '{"success":true,"contents":[{"type":"hooks","notes":["./mod.tsx hooks: session.start","./mod.tsx calls: %s","./mod.tsx env reads: %s"]}]}' "$1" "$2" >"$f"
  echo "$f"
}

test_gate_passes_the_allowed_set() {
  t_ok gate "$(report '$.clock.every, $.command.register, $.command.run (via compactNow), $.env.get, $.env.set, $.process.run (via run), $.session.id, $.ui.invalidate, $.ui.resolve (via drawBand), $.ui.toast (via press)' 'ANTHROPIC_BASE_URL, CLAUDE_CODE_EXTRA_BODY, CLAUDE_CODE_GIT_BASH_PATH')" >/dev/null
}

test_gate_fails_http_fetch_session_messages_usage_and_fs() {
  local out
  out=$(gate "$(report '$.command.register, $.http.fetch (via send)' 'CLAUDE_CODE_GIT_BASH_PATH')")
  t_eq 1 $?
  t_contains "$out" 'call not allowed: $.http.fetch'
  t_not gate "$(report '$.session.messages' '')" >/dev/null
  t_not gate "$(report '$.session.usage' '')" >/dev/null
  t_not gate "$(report '$.fs.read' '')" >/dev/null
  t_not gate "$(report '$.session.append' '')" >/dev/null
}

test_gate_fails_other_env_reads() {
  local out; out=$(gate "$(report '$.env.get' 'ANTHROPIC_API_KEY, CLAUDE_CODE_GIT_BASH_PATH')")
  t_eq 1 $?
  t_contains "$out" "env read not allowed: ANTHROPIC_API_KEY"
}

test_band_source_never_names_content_or_credential_paths() {
  # Code lines only (comments say what the module never does).
  local src; src=$(cat "$T_PLUGIN/hooks/mod.tsx" "$T_PLUGIN/hooks/band.tsx" | grep -v '^[[:space:]]*//')
  t_lacks "$src" '$.http'
  t_lacks "$src" 'session.messages'
  t_lacks "$src" 'session.append'
  t_lacks "$src" '$.fs.'
  t_lacks "$src" '.claude/projects'
  t_lacks "$src" 'credential'
  t_lacks "$src" 'import('
}

test_real_validate_report_on_the_pinned_claude_code() {
  [ -n "${AIONAS_CC_BIN:-}" ] || { echo "    (skipped: set AIONAS_CC_BIN)"; return 0; }
  local cfg out f
  cfg=$(mktemp -d "$T_ROOT/cc.XXXXXX")
  f=$(mktemp "$T_ROOT/validate.XXXXXX")
  # shellcheck disable=SC2086
  CLAUDE_CONFIG_DIR=$cfg $AIONAS_CC_BIN plugin validate --json "$T_PLUGIN" >"$f" 2>/dev/null
  t_eq 0 $? "claude plugin validate passes"
  out=$(gate "$f")
  t_eq 0 $? "privacy gate: $out"
  t_contains "$(cat "$f")" "session.measure"
  t_contains "$(cat "$f")" "ui.render{component=AbovePrompt}"
}

t_main "$@"
