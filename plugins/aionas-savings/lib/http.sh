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

# aionas_http_public GET PATH OUT_FILE: call a PUBLIC route of the enrolled
# gateway WITHOUT the enrollment alias (AIO-904: the script download is public,
# and the alias must stay out of its access log). Same gateway check as
# aionas_http (https, or http only for localhost / 127.0.0.1), same 3 s / 5 s
# limits, and a 1 MB size cap. No -L: a redirect answers 3xx, never 200.
# Prints the HTTP status ("000" when nothing came back); exits 0 only for 2xx.
# Exits 3 without any network call when the computer has no valid gateway.
aionas_http_public() {
  _hp_gw=$(aionas_enroll_gateway) || { echo 000; return 3; }
  _hp_code=$(${AIONAS_CURL:-curl} -sS --connect-timeout 3 --max-time 5 --retry 0 --max-filesize 1048576 \
    -X "$1" -H 'Accept: */*' -o "$3" -w '%{http_code}' "$_hp_gw$2" 2>/dev/null)
  case "$_hp_code" in [0-9][0-9][0-9]) ;; *) _hp_code=000 ;; esac
  echo "$_hp_code"
  case "$_hp_code" in 2??) return 0 ;; esac
  return 1
}
