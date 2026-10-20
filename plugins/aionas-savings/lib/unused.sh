# aionas-savings unused services (AIO-861, W24-1, W24-2, W24-4, W24-P2).
#
# Source it from a hook after aionas.sh:
#   . "$(dirname "$0")/../lib/aionas.sh"; . "$AIONAS_LIB/unused.sh"
#
# What it does. A service (an MCP server, a claude.ai connector, or a skill the
# person keeps in ~/.claude/skills) with no call in `days` days (30 unless the
# policy's unused_services parameter `days` says otherwise) is turned off in the
# PERSON'S OWN Claude Code settings, never in managed settings:
#   - an MCP server or connector: its name goes into disabledMcpServers of this
#     project's entry in ~/.claude.json (exactly what /mcp "disable" writes, so
#     /mcp turns it back on);
#   - a skill: "off" under skillOverrides in ~/.claude/settings.json.
# The change applies from the next session. A service the person turns back on
# is not turned off again for `days` days. Counters: fired = turned off,
# bypass = turned back on by the person. Only names and numbers are kept or
# sent; prompts, tool output and arguments are never read into any file.
#
# Days are whole UTC days: a service last used on the 21st of one month is
# at 30 unused days in the first run on the 21st of the next. Where the days
# of use come from: the local history files, read by name and
# time only (see unused-usage.awk). A service never seen in the history is
# counted from the day this plugin first saw it configured.
#
# State, under $(aionas_savings_dir)/unused/ (TAB separated):
#   seen.tsv        kind name first-seen-epoch   (configured services)
#   disabled.tsv    kind name epoch              (turned off by this plugin)
#   applied.tsv     mcp name project             (where the off switch was set)
#   reenabled.tsv   kind name epoch              (turned back on by the person)
#   notice.pending  kind name days               (shown once, next session)
#   last_run_day    UTC day of the last full check
#
# CLAUDE_CONFIG_DIR is honoured like Claude Code does: the config file is
# $CLAUDE_CONFIG_DIR/.claude.json, else ~/.claude.json.

AIONAS_UNUSED_TAB=$(printf '\t')

# --- Claude Code files ----------------------------------------------------

aionas_unused_claude_dir() {
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then echo "$CLAUDE_CONFIG_DIR"; else echo "$(aionas_home)/.claude"; fi
}
aionas_unused_claude_json() {
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then echo "$CLAUDE_CONFIG_DIR/.claude.json"; else echo "$(aionas_home)/.claude.json"; fi
}
aionas_unused_settings_json() { echo "$(aionas_unused_claude_dir)/settings.json"; }

# aionas_unused_raw STRING: the text of a JSON string literal without quotes.
aionas_unused_raw() {
  _ur_x=$(aionas_json_escape "$1")
  _ur_x=${_ur_x#\"}
  printf '%s' "${_ur_x%\"}"
}

# aionas_unused_j OP FILE VAL [KEY...]: run unused-json.awk (see there). A
# missing FILE reads as an empty object. Keys are raw JSON text.
aionas_unused_j() {
  _uj_op=$1; _uj_file=$2; _uj_val=$3; shift 3
  _uj_path=""
  for _uj_k in "$@"; do _uj_path=${_uj_path:+$_uj_path$AIONAS_UNUSED_TAB}$_uj_k; done
  [ -f "$_uj_file" ] || _uj_file=/dev/null
  AU_OP="$_uj_op" AU_PATH="$_uj_path" AU_VAL="$_uj_val" awk -f "$AIONAS_LIB/unused-json.awk" "$_uj_file"
}

# aionas_unused_jedit FILE OP VAL [KEY...]: an edit op. Rewrites FILE (all or
# nothing, same mode, through a symlink if it is one) only when something
# changes. Exit 0 changed, 10 nothing to change, 2 invalid JSON, 4 the file
# has another kind of value there (left alone).
aionas_unused_jedit() {
  _je_f=$1; _je_op=$2; _je_val=$3; shift 3
  _je_new="$_je_f.aionas-tmp.$$"
  [ -d "$(dirname "$_je_f")" ] || aionas_mkdir "$(dirname "$_je_f")" || return 1
  (umask 077 && aionas_unused_j "$_je_op" "$_je_f" "$_je_val" "$@" >"$_je_new")
  _je_rc=$?
  if [ $_je_rc -ne 0 ]; then rm -f "$_je_new"; return $_je_rc; fi
  _je_mode=$(stat -c %a "$_je_f" 2>/dev/null || stat -f %Lp "$_je_f" 2>/dev/null)
  if [ -L "$_je_f" ]; then
    cat "$_je_new" >"$_je_f" || { rm -f "$_je_new"; return 1; }
    rm -f "$_je_new"
  else
    mv -f "$_je_new" "$_je_f" || { rm -f "$_je_new"; return 1; }
    case "$_je_mode" in [0-7][0-7][0-7]) chmod "$_je_mode" "$_je_f" 2>/dev/null ;; esac
  fi
  return 0
}

# --- policy ---------------------------------------------------------------

# aionas_unused_days [SESSION_ID]: the number of unused days (1 to 365; 30).
aionas_unused_days() {
  _ud_v=$(aionas_policy_param unused_services days "${1:-}" 2>/dev/null) ||
    _ud_v=$(aionas_policy_param unused_services unused_days "${1:-}" 2>/dev/null) || _ud_v=""
  if aionas_is_uint "$_ud_v" && [ "$_ud_v" -ge 1 ] && [ "$_ud_v" -le 365 ]; then
    echo "$_ud_v"
  else
    echo 30
  fi
}

# --- the project key ------------------------------------------------------

# aionas_unused_project_key CONFIG_FILE CWD: the raw JSON key of this
# project in ~/.claude.json. Claude Code keys projects by the real path of the
# working directory (symlinks resolved). An existing entry wins.
aionas_unused_project_key() {
  _pk_phys=$(cd "$2" 2>/dev/null && pwd -P)
  _pk_cwd=$2
  if [ "$(aionas_os)" = windows ]; then
    # Claude Code writes Windows project paths with forward slashes.
    _pk_phys=""
    _pk_cwd=$(printf '%s' "$2" | tr '\\' '/')
  fi
  _pk_keys=$(aionas_unused_j members "$1" "" projects | cut -f1)
  for _pk_c in "$_pk_phys" "$_pk_cwd" "$2"; do
    [ -n "$_pk_c" ] || continue
    _pk_r=$(aionas_unused_raw "$_pk_c")
    if printf '%s\n' "$_pk_keys" | grep -Fxq -- "$_pk_r"; then printf '%s\n' "$_pk_r"; return 0; fi
  done
  aionas_unused_raw "${_pk_phys:-$_pk_cwd}"
  echo
}

# --- small state tables ---------------------------------------------------

# _uu_has FILE FIELD...: exit 0 when a row starts with those fields.
_uu_has() {
  _uh_f=$1; shift
  [ -f "$_uh_f" ] || return 1
  _uh_pat=""
  for _uh_x in "$@"; do _uh_pat=${_uh_pat:+$_uh_pat$AIONAS_UNUSED_TAB}$_uh_x; done
  AU_ROW="$_uh_pat" awk -F '\t' 'BEGIN { n = split(ENVIRON["AU_ROW"], w, "\t") }
    { for (i = 1; i <= n; i++) if ($i != w[i]) next; f = 1; exit } END { exit f ? 0 : 1 }' "$_uh_f"
}
# _uu_get FILE KIND NAME: the third column of the first row for kind+name.
_uu_get() {
  [ -f "$1" ] || return 1
  AU_K="$2" AU_N="$3" awk -F '\t' '$1 == ENVIRON["AU_K"] && $2 == ENVIRON["AU_N"] { print $3; f = 1; exit } END { exit f ? 0 : 1 }' "$1"
}
# _uu_drop FILE KIND NAME: remove every row for kind+name.
_uu_drop() {
  [ -f "$1" ] || return 0
  AU_K="$2" AU_N="$3" awk -F '\t' '!($1 == ENVIRON["AU_K"] && $2 == ENVIRON["AU_N"])' "$1" | aionas_write_atomic "$1"
}
# _uu_row FILE FIELD...: append a row.
_uu_row() {
  _ur_f=$1; shift
  _ur_line=""
  for _ur_x in "$@"; do _ur_line=${_ur_line:+$_ur_line$AIONAS_UNUSED_TAB}$_ur_x; done
  printf '%s\n' "$_ur_line" >>"$_ur_f"
}
# _uu_safe NAME: a name made only of characters that need no JSON escaping
# and cannot break a table row.
_uu_safe() {
  case "$1" in '' | *[!A-Za-z0-9\ ._:@/+-]*) return 1 ;; esac
  [ ${#1} -le 128 ]
}

# --- what is configured, and what was used ---------------------------------

# aionas_unused_configured_mcp CONFIG_FILE PROJECT_KEY: names of MCP servers
# and claude.ai connectors a person can turn off: user-scope servers, this
# project's local-scope servers, and connectors that ever connected.
aionas_unused_configured_mcp() {
  {
    aionas_unused_j members "$1" "" mcpServers | cut -f1
    [ -n "$2" ] && aionas_unused_j members "$1" "" projects "$2" mcpServers | cut -f1
    aionas_unused_j items "$1" "" claudeAiMcpEverConnected
  } | while IFS= read -r _cm_n; do
    _uu_safe "$_cm_n" && printf '%s\n' "$_cm_n"
  done | awk '!seen[$0]++'
}

# aionas_unused_configured_skills: the skills in ~/.claude/skills (the
# frontmatter name, else the folder name).
aionas_unused_configured_skills() {
  for _cs_d in "$(aionas_unused_claude_dir)"/skills/*/; do
    [ -f "${_cs_d}SKILL.md" ] || continue
    _cs_n=$(awk 'NR == 1 && $0 !~ /^---[ \r]*$/ { exit }
      NR > 1 && /^---[ \r]*$/ { exit }
      /^name:[ \t]*/ { v = $0; sub(/^name:[ \t]*/, "", v); gsub(/["\047\r]/, "", v); sub(/[ \t]+$/, "", v); print v; exit }' "${_cs_d}SKILL.md")
    [ -n "$_cs_n" ] || { _cs_n=${_cs_d%/}; _cs_n=${_cs_n##*/}; }
    _uu_safe "$_cs_n" && printf '%s\n' "$_cs_n"
  done
}

# aionas_unused_normalize NAME: how Claude Code spells a server in a tool
# name (mcp__<this>__<tool>): everything but letters, digits, _ and - is _.
aionas_unused_normalize() { printf '%s' "$1" | tr -c 'A-Za-z0-9_\n-' '_'; }

# aionas_unused_usage: "kind<TAB>name<TAB>epoch" for each service seen in the
# history. Reads names and times only.
aionas_unused_usage() {
  _us_d="$(aionas_unused_claude_dir)/projects"
  [ -d "$_us_d" ] || return 0
  _us_nice=""
  command -v nice >/dev/null 2>&1 && _us_nice="nice -n 19"
  # shellcheck disable=SC2086
  find "$_us_d" -name '*.jsonl' -type f -exec $_us_nice env LC_ALL=C grep -a -h -E '"name":"(mcp__|Skill")|<command-name>' {} + 2>/dev/null |
    LC_ALL=C awk -f "$AIONAS_LIB/time.awk" -f "$AIONAS_LIB/unused-usage.awk"
}

# --- the daily check --------------------------------------------------------

# aionas_unused_run SESSION_ID CWD: one SessionStart. Exit 0 when done or not
# needed, 4 when another run holds the lock.
aionas_unused_run() {
  [ -n "${2:-}" ] || return 0
  aionas_policy_active unused_services "${1:-}" || return 0
  aionas_lock_try unused 120 || return 4
  _uu_dir="$(aionas_savings_dir)/unused"
  aionas_mkdir "$_uu_dir" || { aionas_lock_release unused; return 1; }
  _uu_days=$(aionas_unused_days "${1:-}")
  _uu_now=$(aionas_now)
  _uu_cj=$(aionas_unused_claude_json)
  _uu_sj=$(aionas_unused_settings_json)
  _uu_pk=$(aionas_unused_project_key "$_uu_cj" "$2")
  aionas_unused_reconcile
  _uu_today=$(aionas_day_utc)
  if [ "$(cat "$_uu_dir/last_run_day" 2>/dev/null)" != "$_uu_today" ]; then
    if aionas_unused_decide; then printf '%s\n' "$_uu_today" | aionas_write_atomic "$_uu_dir/last_run_day"; fi
  fi
  aionas_lock_release unused
  return 0
}

# aionas_unused_reenabled KIND NAME: the person turned it back on.
aionas_unused_reenabled() {
  _uu_row "$_uu_dir/reenabled.tsv" "$1" "$2" "$_uu_now"
  _uu_drop "$_uu_dir/disabled.tsv" "$1" "$2"
  _uu_drop "$_uu_dir/applied.tsv" "$1" "$2"
  aionas_counter_inc unused_services bypass
}

# Every session: notice what the person turned back on, and carry the off
# switch into this project when it is not there yet.
aionas_unused_reconcile() {
  [ -s "$_uu_dir/disabled.tsv" ] || return 0
  _rc_list=$(aionas_unused_j items "$_uu_cj" "" projects "$_uu_pk" disabledMcpServers)
  _rc_ov=$(aionas_unused_j members "$_uu_sj" "" skillOverrides)
  _rc_rows=$(cat "$_uu_dir/disabled.tsv")
  printf '%s\n' "$_rc_rows" | while IFS="$AIONAS_UNUSED_TAB" read -r _rc_kind _rc_name _rc_t; do
    case "$_rc_kind" in
      mcp)
        _rc_in=0
        printf '%s\n' "$_rc_list" | grep -Fxq -- "$_rc_name" && _rc_in=1
        if _uu_has "$_uu_dir/applied.tsv" mcp "$_rc_name" "$_uu_pk"; then
          [ $_rc_in -eq 1 ] || aionas_unused_reenabled mcp "$_rc_name"
        elif [ $_rc_in -eq 1 ]; then
          _uu_row "$_uu_dir/applied.tsv" mcp "$_rc_name" "$_uu_pk"
        else
          # Not set in this project yet (a new project, or the project was
          # unknown when it was turned off): carry the off switch here. Not a
          # re-enable.
          if aionas_unused_jedit "$_uu_cj" add-item "$_rc_name" projects "$_uu_pk" disabledMcpServers; then
            _uu_row "$_uu_dir/applied.tsv" mcp "$_rc_name" "$_uu_pk"
          fi
        fi
        ;;
      skill)
        _rc_cur=$(printf '%s\n' "$_rc_ov" | AU_N="$_rc_name" awk -F '\t' '$1 == ENVIRON["AU_N"] && $2 == "s" { print $3; exit }')
        [ "$_rc_cur" = off ] || aionas_unused_reenabled skill "$_rc_name"
        ;;
    esac
  done
}

# Once a day: which configured services crossed the line.
aionas_unused_decide() {
  _dc_grace=$((_uu_days * 86400)) # only for pruning the re-enable table
  _dc_mcp=$(aionas_unused_configured_mcp "$_uu_cj" "$_uu_pk")
  _dc_skills=$(aionas_unused_configured_skills)
  _dc_usage=$(aionas_unused_usage)
  _dc_pl=$(aionas_unused_j items "$_uu_cj" "" projects "$_uu_pk" disabledMcpServers)
  _dc_ov=$(aionas_unused_j members "$_uu_sj" "" skillOverrides)

  # first-seen table: keep what is still configured, add what is new
  _dc_seen_new="$_uu_dir/.seen.$$"
  : >"$_dc_seen_new"
  _dc_all=$(
    printf '%s\n' "$_dc_mcp" | while IFS= read -r _x; do [ -n "$_x" ] && printf 'mcp\t%s\n' "$_x"; done
    printf '%s\n' "$_dc_skills" | while IFS= read -r _x; do [ -n "$_x" ] && printf 'skill\t%s\n' "$_x"; done
  )
  printf '%s\n' "$_dc_all" | while IFS="$AIONAS_UNUSED_TAB" read -r _dc_kind _dc_name; do
    [ -n "$_dc_name" ] || continue
    _dc_first=$(_uu_get "$_uu_dir/seen.tsv" "$_dc_kind" "$_dc_name") || _dc_first=$_uu_now
    _uu_row "$_dc_seen_new" "$_dc_kind" "$_dc_name" "$_dc_first"
  done
  mv -f "$_dc_seen_new" "$_uu_dir/seen.tsv"

  # people who turned something back on long ago are no longer in grace
  if [ -f "$_uu_dir/reenabled.tsv" ]; then
    AU_NOW="$_uu_now" AU_G="$_dc_grace" awk -F '\t' '$3 + ENVIRON["AU_G"] > ENVIRON["AU_NOW"]' "$_uu_dir/reenabled.tsv" |
      aionas_write_atomic "$_uu_dir/reenabled.tsv"
  fi

  printf '%s\n' "$_dc_all" | while IFS="$AIONAS_UNUSED_TAB" read -r _dc_kind _dc_name; do
    [ -n "$_dc_name" ] || continue
    case "$(printf '%s' "$_dc_name" | tr 'A-Z' 'a-z')" in *aionas*) continue ;; esac
    _uu_has "$_uu_dir/disabled.tsv" "$_dc_kind" "$_dc_name" && continue
    if _dc_re=$(_uu_get "$_uu_dir/reenabled.tsv" "$_dc_kind" "$_dc_name") && aionas_is_uint "$_dc_re" &&
      [ $((_uu_now / 86400 - _dc_re / 86400)) -lt "$_uu_days" ]; then
      continue
    fi
    case "$_dc_kind" in
      mcp) printf '%s\n' "$_dc_pl" | grep -Fxq -- "$_dc_name" && continue ;; # the person's own choice
      skill) # any value but "on" is the person's own choice (name-only, off, ...)
        printf '%s\n' "$_dc_ov" | AU_N="$_dc_name" awk -F '\t' '$1 == ENVIRON["AU_N"] && !($2 == "s" && $3 == "on") { f = 1 } END { exit f ? 0 : 1 }' && continue ;;
    esac
    _dc_key=$_dc_name
    [ "$_dc_kind" = mcp ] && _dc_key=$(aionas_unused_normalize "$_dc_name")
    _dc_last=$(_uu_get_usage "$_dc_kind" "$_dc_key") || _dc_last=""
    if ! aionas_is_uint "$_dc_last"; then
      _dc_last=$(_uu_get "$_uu_dir/seen.tsv" "$_dc_kind" "$_dc_name") || _dc_last=$_uu_now
    fi
    # whole UTC days since the last call (or since first seen)
    [ $((_uu_now / 86400 - _dc_last / 86400)) -ge "$_uu_days" ] || continue
    case "$_dc_kind" in
      mcp) aionas_unused_jedit "$_uu_cj" add-item "$_dc_name" projects "$_uu_pk" disabledMcpServers ;;
      skill) aionas_unused_jedit "$_uu_sj" set-str off skillOverrides "$_dc_name" ;;
    esac
    case $? in 0 | 10) ;; *) continue ;; esac
    _uu_row "$_uu_dir/disabled.tsv" "$_dc_kind" "$_dc_name" "$_uu_now"
    [ "$_dc_kind" = mcp ] && _uu_row "$_uu_dir/applied.tsv" mcp "$_dc_name" "$_uu_pk"
    _uu_row "$_uu_dir/notice.pending" "$_dc_kind" "$_dc_name" "$_uu_days"
    aionas_counter_inc unused_services fired
  done
  return 0
}

# _uu_get_usage KIND KEY: the last-use epoch from the history table.
_uu_get_usage() {
  printf '%s\n' "$_dc_usage" | AU_K="$1" AU_N="$2" awk -F '\t' '$1 == ENVIRON["AU_K"] && $2 == ENVIRON["AU_N"] { print $3; f = 1; exit } END { exit f ? 0 : 1 }'
}

# --- the notice -------------------------------------------------------------

# aionas_unused_notice: print the one-line notice of what was turned off since
# the last session, as a Claude Code SessionStart answer, and clear it. Prints
# nothing when there is nothing to say.
aionas_unused_notice() {
  _nt_f="$(aionas_savings_dir)/unused/notice.pending"
  [ -s "$_nt_f" ] || return 0
  _nt_tmp="$_nt_f.read.$$"
  mv -f "$_nt_f" "$_nt_tmp" 2>/dev/null || return 0
  _nt_days=$(awk -F '\t' 'NR == 1 { print $3 }' "$_nt_tmp")
  aionas_is_uint "$_nt_days" || _nt_days=30
  _nt_m=$(awk -F '\t' '$1 == "mcp" { printf "%s%s", (n++ ? ", " : ""), $2 }' "$_nt_tmp")
  _nt_s=$(awk -F '\t' '$1 == "skill" { printf "%s%s", (n++ ? ", " : ""), $2 }' "$_nt_tmp")
  rm -f "$_nt_tmp"
  _nt_msg="Aionas turned off services with no calls in $_nt_days days:"
  [ -n "$_nt_m" ] && _nt_msg="$_nt_msg MCP servers $_nt_m (turn one back on with /mcp)."
  [ -n "$_nt_s" ] && _nt_msg="$_nt_msg skills $_nt_s (turn one back on by removing it from skillOverrides in settings.json)."
  printf '{"systemMessage":%s}\n' "$(aionas_json_escape "$_nt_msg")"
}
