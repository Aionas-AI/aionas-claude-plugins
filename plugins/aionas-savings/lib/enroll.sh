# aionas-savings: this computer's enrollment, written by the one install
# (~/.aionas/agent/credential holds the alias, enrollment.json the gateway).
# The alias is never printed, logged or put on a command line: it only goes
# into a private header file that curl reads with -H @FILE.

# aionas_enroll_gateway: print the gateway base URL (no trailing slash).
# Exit 1 when the computer is not enrolled or the URL is not plain http(s).
aionas_enroll_gateway() {
  _eg_f="$(aionas_agent_dir)/enrollment.json"
  [ -r "$_eg_f" ] || return 1
  _eg_u=$(aionas_json_flatten "$_eg_f" 2>/dev/null | aionas_json_get gateway) || return 1
  _eg_u=${_eg_u%/}
  printf '%s\n' "$_eg_u" | grep -Eq '^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$' || return 1
  printf '%s\n' "$_eg_u"
}

# aionas_enroll_has_alias: exit 0 when a well-formed alias is stored.
aionas_enroll_has_alias() {
  _ea_f="$(aionas_agent_dir)/credential"
  [ -r "$_ea_f" ] || return 1
  # ^aen-[A-Za-z0-9]{16,256}$ (BSD grep caps repetitions at 255, so by hand)
  _ea_v=$(tr -d '\r\n' <"$_ea_f")
  case "$_ea_v" in aen-*) ;; *) return 1 ;; esac
  _ea_v=${_ea_v#aen-}
  case "$_ea_v" in '' | *[!A-Za-z0-9]*) return 1 ;; esac
  [ ${#_ea_v} -ge 16 ] && [ ${#_ea_v} -le 256 ]
}

# aionas_enroll_auth_header_file FILE: write "Authorization: Bearer <alias>"
# to FILE (mode 0600). Exit 1, writing nothing, when there is no valid alias.
aionas_enroll_auth_header_file() {
  aionas_enroll_has_alias || return 1
  (umask 077 && { printf 'Authorization: Bearer '; tr -d '\r\n' <"$(aionas_agent_dir)/credential"; printf '\n'; } >"$1")
}
