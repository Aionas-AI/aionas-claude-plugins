# aionas-savings HTTP to the enrolled gateway, with the wave-24 limits
# (W24-P2): 3 s connect timeout, 5 s in total, no retry. AIONAS_CURL replaces
# curl in tests.
#
# Every curl call (AIO-1072, finding 1): --disable first, so the developer's
# .curlrc is never read (a "location" or "url" line there could send a body or
# the alias elsewhere); --proto limits it to the gateway's own scheme (https,
# or http only for the loopback gateway aionas_enroll_gateway allows); no -L,
# so a redirect is a 3xx, never followed. A call succeeds only when curl exits
# 0 AND the status is 2xx.

# _aionas_http_proto GATEWAY: the one protocol curl may use.
_aionas_http_proto() {
  case "$1" in http://*) echo =http ;; *) echo =https ;; esac
}

# _aionas_http_result CODE RC: print the status ("000" when curl failed or
# nothing came back) and exit 0 only for a 2xx with curl exit 0.
_aionas_http_result() {
  _hr_code=$1
  case "$_hr_code" in [0-9][0-9][0-9]) ;; *) _hr_code=000 ;; esac
  [ "$2" = 0 ] || _hr_code=000
  echo "$_hr_code"
  case "$_hr_code" in 2??) return 0 ;; esac
  return 1
}

# aionas_http METHOD PATH BODY_FILE|- OUT_FILE: call the gateway with the
# enrollment alias. Prints the HTTP status ("000" when nothing came back) and
# exits 0 only for 2xx. Exits 3 without any network call when the computer is
# not enrolled or the state folder is not private.
aionas_http() {
  _h_gw=$(aionas_enroll_gateway) || { echo 000; return 3; }
  _h_dir=$(aionas_savings_dir)
  aionas_mkdir "$_h_dir" || { echo 000; return 3; }
  # A fresh file with a random name (mktemp creates it 0600, never through an
  # existing name or symlink).
  _h_hdr=$(umask 077 && mktemp "$_h_dir/.auth.XXXXXX" 2>/dev/null) || { echo 000; return 3; }
  aionas_enroll_auth_header_file "$_h_hdr" || { rm -f "$_h_hdr"; echo 000; return 3; }
  _h_proto=$(_aionas_http_proto "$_h_gw")
  if [ "$3" = "-" ]; then
    _h_code=$(${AIONAS_CURL:-curl} --disable -sS --proto "$_h_proto" --connect-timeout 3 --max-time 5 --retry 0 \
      -X "$1" -H "@$_h_hdr" -H 'Accept: application/json' \
      -o "$4" -w '%{http_code}' "$_h_gw$2" 2>/dev/null)
  else
    _h_code=$(${AIONAS_CURL:-curl} --disable -sS --proto "$_h_proto" --connect-timeout 3 --max-time 5 --retry 0 \
      -X "$1" -H "@$_h_hdr" -H 'Accept: application/json' -H 'Content-Type: application/json' \
      --data-binary "@$3" -o "$4" -w '%{http_code}' "$_h_gw$2" 2>/dev/null)
  fi
  _h_rc=$?
  rm -f "$_h_hdr"
  _aionas_http_result "$_h_code" "$_h_rc"
}

# aionas_http_public GET PATH OUT_FILE: call a PUBLIC route of the enrolled
# gateway WITHOUT the enrollment alias (AIO-904: the script download is public,
# and the alias must stay out of its access log). Same gateway check as
# aionas_http (https, or http only for localhost / 127.0.0.1), same curl
# options and 3 s / 5 s limits, and a 1 MB size cap. No -L: a redirect answers
# 3xx, never 200. Prints the HTTP status ("000" when nothing came back); exits
# 0 only for 2xx with curl exit 0. Exits 3 without any network call when the
# computer has no valid gateway.
aionas_http_public() {
  _hp_gw=$(aionas_enroll_gateway) || { echo 000; return 3; }
  _hp_code=$(${AIONAS_CURL:-curl} --disable -sS --proto "$(_aionas_http_proto "$_hp_gw")" --connect-timeout 3 --max-time 5 --retry 0 --max-filesize 1048576 \
    -X "$1" -H 'Accept: */*' -o "$3" -w '%{http_code}' "$_hp_gw$2" 2>/dev/null)
  _aionas_http_result "$_hp_code" $?
}
