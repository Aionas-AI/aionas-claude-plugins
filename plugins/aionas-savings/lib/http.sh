# aionas-savings HTTP to the enrolled gateway, with the wave-24 limits
# (W24-P2): 3 s connect timeout, 5 s in total, no retry. AIONAS_CURL replaces
# curl in tests.

# aionas_http METHOD PATH BODY_FILE|- OUT_FILE: call the gateway with the
# enrollment alias. Prints the HTTP status ("000" when nothing came back) and
# exits 0 only for 2xx. Exits 3 without any network call when the computer is
# not enrolled.
aionas_http() {
  _h_gw=$(aionas_enroll_gateway) || { echo 000; return 3; }
  _h_dir=$(aionas_savings_dir)
  aionas_mkdir "$_h_dir" || { echo 000; return 3; }
  _h_hdr="$_h_dir/.auth.$$"
  aionas_enroll_auth_header_file "$_h_hdr" || { rm -f "$_h_hdr"; echo 000; return 3; }
  if [ "$3" = "-" ]; then
    _h_code=$(${AIONAS_CURL:-curl} -sS --connect-timeout 3 --max-time 5 --retry 0 \
      -X "$1" -H "@$_h_hdr" -H 'Accept: application/json' \
      -o "$4" -w '%{http_code}' "$_h_gw$2" 2>/dev/null)
  else
    _h_code=$(${AIONAS_CURL:-curl} -sS --connect-timeout 3 --max-time 5 --retry 0 \
      -X "$1" -H "@$_h_hdr" -H 'Accept: application/json' -H 'Content-Type: application/json' \
      --data-binary "@$3" -o "$4" -w '%{http_code}' "$_h_gw$2" 2>/dev/null)
  fi
  rm -f "$_h_hdr"
  case "$_h_code" in [0-9][0-9][0-9]) ;; *) _h_code=000 ;; esac
  echo "$_h_code"
  case "$_h_code" in 2??) return 0 ;; esac
  return 1
}
