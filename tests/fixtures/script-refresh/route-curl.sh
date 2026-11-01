#!/usr/bin/env bash
# AIONAS_CURL for tests/unit/script-refresh.test.sh: picks the answer by URL,
# then hands over to tests/lib/fake-curl.sh, which records the call.
#   SR_SERVE   folder that holds manifest.json and the served scripts
#   SR_MANIFEST_STATUS (default 200), SR_SCRIPT_STATUS (default 200)
# A script that is not in SR_SERVE answers 404.
set -u
url=""
for a in "$@"; do
  case "$a" in http://* | https://*) url=$a ;; esac
done
unset FAKE_CURL_BODY FAKE_CURL_STATUS
case "$url" in
  */enroll/v1/scripts/manifest)
    FAKE_CURL_BODY="$SR_SERVE/manifest.json" FAKE_CURL_STATUS="${SR_MANIFEST_STATUS:-200}" ;;
  */api/aionas/onboarding/scripts/*)
    n=${url##*/}
    if [ -f "$SR_SERVE/$n" ]; then
      FAKE_CURL_BODY="$SR_SERVE/$n" FAKE_CURL_STATUS="${SR_SCRIPT_STATUS:-200}"
    else
      FAKE_CURL_STATUS=404
    fi ;;
  *) FAKE_CURL_STATUS=404 ;;
esac
export FAKE_CURL_BODY FAKE_CURL_STATUS
exec "$(dirname "$0")/../../lib/fake-curl.sh" "$@"
