# aionas-savings helpers for hooks/script-refresh.sh (AIO-904). Sourced by that
# hook only (not by aionas.sh). POSIX sh; also bash 3.2 and Git Bash.
# Nothing here runs a program found on PATH, and nothing here touches the
# network.

# The only files this feature may ever touch in ~/.aionas/agent/tools.
AIONAS_SR_NAMES="aionas-plan-usage.sh aionas-statusline-tap.sh aionas-plan-usage.ps1 aionas-statusline-tap.ps1"

# aionas_sr_name_ok NAME: exit 0 for exactly one of the four names.
aionas_sr_name_ok() {
  case "$1" in
    aionas-plan-usage.sh | aionas-statusline-tap.sh | aionas-plan-usage.ps1 | aionas-statusline-tap.ps1) return 0 ;;
  esac
  return 1
}

# aionas_sr_version_ok VALUE: a stamp that can be told apart and compared.
aionas_sr_version_ok() {
  case "$1" in '__AIONAS_RELEASE__') return 1 ;; esac
  printf '%s\n' "$1" | LC_ALL=C grep -Eq '^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$'
}

# aionas_sr_sha_ok VALUE: 64 lowercase hex digits.
aionas_sr_sha_ok() {
  printf '%s\n' "$1" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$'
}

# aionas_sr_sha256 FILE: print the file's sha256 (lowercase hex, as every tool
# below prints it; an uppercase digest fails aionas_sr_sha_ok, and the digest
# never passes through a PATH tool). The hash tool is looked up at fixed system paths only, never on PATH: a project could put
# its own sha256sum there and have it vouch for a file. Exit 1, printing
# nothing, when there is none (the refresh then installs nothing).
# AIONAS_SHA256_BIN replaces the lookup in tests, as AIONAS_CURL does for curl.
aionas_sr_sha256() {
  _sr_h=""
  if [ -n "${AIONAS_SHA256_BIN:-}" ]; then
    [ -x "$AIONAS_SHA256_BIN" ] || return 1
    _sr_h=$("$AIONAS_SHA256_BIN" "$1" 2>/dev/null)
  elif [ -x /usr/bin/sha256sum ]; then
    _sr_h=$(/usr/bin/sha256sum "$1" 2>/dev/null)
  elif [ -x /sbin/sha256sum ]; then
    _sr_h=$(/sbin/sha256sum "$1" 2>/dev/null)
  elif [ -x /usr/bin/shasum ]; then
    _sr_h=$(/usr/bin/shasum -a 256 "$1" 2>/dev/null)
  elif [ -x /usr/bin/openssl ]; then
    _sr_h=$(/usr/bin/openssl dgst -sha256 -r "$1" 2>/dev/null)
  else
    return 1
  fi
  _sr_h=${_sr_h%% *}
  aionas_sr_sha_ok "$_sr_h" || return 1
  printf '%s\n' "$_sr_h"
}

# aionas_sr_stamp FILE [NAME]: the release stamp inside a script, from its one
# `AIONAS_RELEASE='<stamp>'` line (PowerShell: `$AIONAS_RELEASE = '<stamp>'`).
# The file is only read, never sourced or run. Prints nothing when there is no
# such line. NAME (default FILE) decides the kind by its extension, for a
# downloaded temp file whose own name ends in .tmp.<pid>.
aionas_sr_stamp() {
  case "${2:-$1}" in
    *.ps1) _sr_pat="^[\$]AIONAS_RELEASE = '[^']*'\$" ;;
    *) _sr_pat="^AIONAS_RELEASE='[^']*'\$" ;;
  esac
  tr -d '\r' <"$1" 2>/dev/null | LC_ALL=C grep -a -m 1 -E "$_sr_pat" | sed -e "s/^[^']*'//" -e "s/'\$//"
  return 0
}
