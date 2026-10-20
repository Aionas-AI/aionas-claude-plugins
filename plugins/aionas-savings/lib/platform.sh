# aionas-savings platform helpers. POSIX sh; also runs under bash 3.2 (macOS)
# and Git Bash (Windows, where Claude Code runs hooks). Sourced via aionas.sh.

# aionas_os: darwin | linux | windows | other.
aionas_os() {
  case "$(${AIONAS_UNAME:-uname} -s 2>/dev/null)" in
    Darwin) echo darwin ;;
    Linux) echo linux ;;
    MINGW* | MSYS* | CYGWIN* | Windows_NT) echo windows ;;
    *) echo other ;;
  esac
}

# aionas_now: seconds since the epoch (AIONAS_NOW pins it in tests).
aionas_now() {
  if [ -n "${AIONAS_NOW:-}" ]; then echo "$AIONAS_NOW"; else date +%s; fi
}

# aionas_day_utc [EPOCH]: YYYY-MM-DD in UTC for now (or for EPOCH).
aionas_day_utc() {
  awk -v t="${1:-$(aionas_now)}" -f "$AIONAS_LIB/time.awk" -v mode=day </dev/null
}

# aionas_home: the user's home directory (HOME; USERPROFILE on Windows when
# HOME is unset).
aionas_home() {
  if [ -n "${HOME:-}" ]; then echo "$HOME"; elif [ -n "${USERPROFILE:-}" ]; then echo "$USERPROFILE"; else return 1; fi
}

# aionas_agent_dir: the one install's per-computer folder (~/.aionas/agent).
aionas_agent_dir() {
  if [ -n "${AIONAS_AGENT_DIR:-}" ]; then echo "$AIONAS_AGENT_DIR"; return 0; fi
  echo "$(aionas_home)/.aionas/agent"
}

# aionas_savings_dir: where the plugin keeps its state (policy cache, session
# pins, local overrides, counters). Fixed so the one install's restore and the
# plan-usage backup scan can find it: ~/.aionas/agent/savings.
aionas_savings_dir() {
  if [ -n "${AIONAS_SAVINGS_DIR:-}" ]; then echo "$AIONAS_SAVINGS_DIR"; return 0; fi
  echo "$(aionas_agent_dir)/savings"
}

# aionas_mkdir DIR: create DIR (and parents) private to the user.
aionas_mkdir() {
  [ -d "$1" ] && return 0
  (umask 077 && mkdir -p "$1")
}

# aionas_write_atomic FILE: stdin -> FILE, all or nothing (temp file + rename).
aionas_write_atomic() {
  _aw_tmp="$1.tmp.$$"
  if (umask 077 && cat >"$_aw_tmp"); then
    mv -f "$_aw_tmp" "$1" && return 0
  fi
  rm -f "$_aw_tmp"
  return 1
}

# aionas_lock_try NAME [STALE_SECONDS]: take a lock without waiting. A lock
# older than STALE_SECONDS (default 60) is broken. Returns 1 when held.
aionas_lock_try() {
  _lk_dir="$(aionas_savings_dir)/locks"
  aionas_mkdir "$_lk_dir" || return 1
  _lk="$_lk_dir/$1.lock"
  if mkdir "$_lk" 2>/dev/null; then
    aionas_now >"$_lk/t"
    return 0
  fi
  _lk_t=$(cat "$_lk/t" 2>/dev/null)
  case "$_lk_t" in '' | *[!0-9]*) _lk_t=0 ;; esac
  if [ $(($(aionas_now) - _lk_t)) -gt "${2:-60}" ]; then
    rm -f "$_lk/t"
    rmdir "$_lk" 2>/dev/null
    if mkdir "$_lk" 2>/dev/null; then
      aionas_now >"$_lk/t"
      return 0
    fi
  fi
  return 1
}

# aionas_lock_release NAME
aionas_lock_release() {
  _lk="$(aionas_savings_dir)/locks/$1.lock"
  rm -f "$_lk/t"
  rmdir "$_lk" 2>/dev/null
  return 0
}

# aionas_is_uint VALUE: a non-negative integer of at most 15 digits.
aionas_is_uint() {
  case "$1" in '' | *[!0-9]*) return 1 ;; esac
  [ ${#1} -le 15 ]
}
